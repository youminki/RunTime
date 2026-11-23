#!/usr/bin/env python3
"""Pesty(MIT) 소스를 Sources/ClipKit으로 옮겨 온다.

사용법: python3 -I scripts/sync-pesty.py <Pesty 클론 경로>
앱 진입점(Main.swift), App Store용 CloudKit 동기화(Sync), 설정 창(SettingsView)은 RunTime 것을 쓰므로 빼고,
나머지 코드는 고치지 않고 가져온 뒤 아래 기계적인 변환만 한다. RunTime 쪽 코드는 Sources/ClipKit/RunTime에 둔다.
Pesty는 macOS 14의 Observation을 쓰고 RunTime은 macOS 13부터 돌아, @Observable은 ObservableObject로 바꾼다.
옮겨 온 커밋: bf0fbab3d2f06ed405c8c1029d09142469abff86 (2026-11-19)
"""
import os, re, shutil, sys

SKIP_DIRS = {"Sync"}
SKIP_FILES = {"Main.swift", "Settings/SettingsView.swift"}
ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
DST = os.path.join(ROOT, "Sources", "ClipKit")
TESTS = os.path.join(ROOT, "Tests", "ClipKitTests", "Pesty")
KEEP = {"RunTime", "Support.swift", "LICENSE"}
PUBLISHED = {}


def main(src):
    # 지우기 전에 원본을 확인한다. 경로가 틀리면 Sources/ClipKit만 비우고 멈추게 된다
    for need in ("LICENSE", "Sources/Pesty/AppController.swift", "Tests/PestyTests"):
        if not os.path.exists(os.path.join(src, need)):
            sys.exit(f"Pesty 클론이 아니다: {os.path.join(src, need)} 없음")
    for name in os.listdir(DST):
        if name in KEEP:
            continue
        path = os.path.join(DST, name)
        shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)
    base = os.path.join(src, "Sources", "Pesty")
    for root, dirs, files in os.walk(base):
        rel = os.path.relpath(root, base)
        if rel.split(os.sep)[0] in SKIP_DIRS:
            continue
        for f in sorted(files):
            relf = os.path.normpath(os.path.join(rel, f))
            if not f.endswith(".swift") or relf in SKIP_FILES:
                continue
            out = os.path.join(DST, relf)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "w").write(transform(open(os.path.join(root, f)).read(), relf))
    shutil.copy(os.path.join(src, "LICENSE"), os.path.join(DST, "LICENSE"))

    shutil.rmtree(TESTS, ignore_errors=True)
    os.makedirs(TESTS)
    tests = os.path.join(src, "Tests", "PestyTests")
    for f in sorted(os.listdir(tests)):
        if f.endswith(".swift"):
            open(os.path.join(TESTS, f), "w").write(convert_test(open(os.path.join(tests, f)).read()))

    check_strings(os.path.join(src, "packaging", "Resources", "zh-Hans.lproj", "Localizable.strings"))


def transform(s, path):
    s = s.replace("import Observation\n", "")
    s = observable_to_combine(s, path)
    # @Bindable과 계산 프로퍼티로 읽던 공유 객체는 ObservableObject 구독으로 바꾼다
    s = re.sub(r"@Bindable (private )?var (\w+) = (\w+)\.shared", r"@ObservedObject \1var \2 = \3.shared", s)
    s = re.sub(r"(private )?var (\w+): (ClipboardStore|Settings) \{ \3\.shared \}", r"@ObservedObject \1var \2 = \3.shared", s)
    # @State는 macOS 27 SDK에서 매크로라 Command Line Tools로 빌드되지 않는다. ViewState(Support.swift)로 바꾼다
    s = re.sub(r"@State ((?:private )?var \w+: [^=\n]+\?)$", r"@State \1 = nil", s, flags=re.M)
    s = re.sub(r"@State\b", "@ViewState", s)
    # 인자 두 개짜리 onChange는 macOS 14부터 있다. 이전 값을 쓰지 않는 곳만 있어 하나짜리로 바꾼다
    s = re.sub(r"(\.onChange\(of: [^\n]*?\) \{ )_, (\w+) in", r"\1\2 in", s)
    if re.search(r"\.onChange\(of: [^\n]*?\) \{ \w+, \w+ in", s):
        sys.exit(f"{path}: 이전 값을 쓰는 onChange가 있어 직접 옮겨야 한다")
    # macOS 14부터 있는 뷰는 Support.swift의 같은 꼴로
    s = s.replace("ContentUnavailableView(", "UnavailableNotice(")
    # 설정은 RunTime 설정과 섞이지 않게 따로 둔 저장소에
    s = s.replace("UserDefaults.standard", "ClipDefaults.store")
    for old, new in PATCHES:
        if old in s:
            # 같은 줄이 두 군데 생기면 엉뚱한 자리에도 끼어든다. 원본이 바뀐 것이니 멈추고 패치를 고친다
            if s.count(old) > 1 or old in APPLIED:
                sys.exit(f"{path}: 패치가 여러 자리에 맞는다: {old[:60]!r}")
            s = s.replace(old, new)
            APPLIED.add(old)
    if re.search(r"@Observable|@Bindable|@ObservationIgnored|withObservationTracking", s):
        sys.exit(f"{path}: Observation 코드가 남았다")
    return s


def observable_to_combine(s, path):
    """@Observable 클래스를 ObservableObject로 바꾸고, 밖에서 보이는 저장 프로퍼티에 @Published를 붙인다.

    Observation은 읽은 프로퍼티를 저절로 추적하지만 ObservableObject는 @Published만 알린다.
    private 저장 프로퍼티(저장 경로, 작업 핸들)는 화면에 나오지 않아 알리지 않는다.
    """
    lines = s.split("\n")
    out, depth, inside, opened, names = [], 0, False, False, []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "@Observable":
            j = i + 1
            while not lines[j].lstrip().startswith(("final class", "class")):
                j += 1
            lines[j] = re.sub(r"class (\w+) \{", r"class \1: ObservableObject {", lines[j])
            inside, opened, depth = True, False, 0
            i += 1
            continue
        if inside and opened and depth == 1:
            stripped = line.strip()
            ignored = stripped.startswith("@ObservationIgnored ")
            stripped = stripped.replace("@ObservationIgnored ", "")
            line = line.replace("@ObservationIgnored ", "")
            m = re.match(r"(private\(set\) |fileprivate\(set\) )?var (\w+)", stripped)
            if m and not ignored and is_stored(stripped, lines, i):
                line = line.replace(stripped, "@Published " + stripped, 1)
                names.append(m.group(2))
        depth += brace_delta(line)
        if inside and depth > 0:
            opened = True
        elif inside and opened and depth == 0:
            PUBLISHED[path] = names
            inside, names = False, []
        out.append(line)
        i += 1
    return "\n".join(out)


def is_stored(decl, lines, i):
    if "{" not in decl:
        return True
    after = decl.split("{", 1)[1].strip()
    if after:
        return after.startswith(("didSet", "willSet"))
    nxt = next(l.strip() for l in lines[i + 1:] if l.strip())
    return nxt.startswith(("didSet", "willSet"))


def brace_delta(line):
    """문자열과 주석 밖의 중괄호만 센다."""
    code = re.sub(r'"(?:\\.|[^"\\])*"', '""', line.split("//")[0])
    return code.count("{") - code.count("}")


def split_args(text):
    args, depth, cur, quote = [], 0, "", False
    k = 0
    while k < len(text):
        c = text[k]
        if quote:
            cur += c
            if c == "\\":
                cur += text[k + 1]
                k += 1
            elif c == '"':
                quote = False
        elif c == '"':
            quote = True
            cur += c
        elif c in "([{":
            depth += 1
            cur += c
        elif c in ")]}":
            depth -= 1
            cur += c
        elif c == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
        else:
            cur += c
        k += 1
    if cur.strip():
        args.append(cur.strip())
    return args


def call_end(s, start):
    """start의 여는 괄호에 맞는 닫는 괄호 위치."""
    depth, k, quote = 0, start, False
    while k < len(s):
        c = s[k]
        if quote:
            if c == "\\":
                k += 1
            elif c == '"':
                quote = False
        elif c == '"':
            quote = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return k
        k += 1
    raise ValueError("괄호가 닫히지 않았다")


def convert_test(s):
    """Command Line Tools에는 XCTest가 없어 swift-testing으로 바꾼다. Pesty 테스트가 쓰는 단언만 다룬다."""
    s = s.replace("import XCTest\n", "import AppKit\nimport Testing\n")
    s = s.replace("@testable import Pesty", "@testable import ClipKit")
    s = re.sub(r"final class (\w+): XCTestCase \{", r"@Suite struct \1 {", s)
    s = re.sub(r"(\n\s*)func (test\w+)\(\)", r"\1@Test func \2()", s)
    # swift-testing에는 정리 블록이 없다. 테스트마다 임시 폴더에 만든 기록은 시스템이 치운다
    s = re.sub(r"\n\s*addTeardownBlock \{[^\n]*\}", "", s)
    templates = {
        "XCTAssertEqual": lambda a: f"#expect({a[0]} == {a[1]})",
        "XCTAssertNotEqual": lambda a: f"#expect({a[0]} != {a[1]})",
        "XCTAssertTrue": lambda a: f"#expect({a[0]})",
        "XCTAssertFalse": lambda a: f"#expect(!({a[0]}))",
        "XCTAssertNil": lambda a: f"#expect({a[0]} == nil)",
        "XCTAssertNotNil": lambda a: f"#expect({a[0]} != nil)",
        "XCTUnwrap": lambda a: f"#require({a[0]})",
    }
    pattern = re.compile(r"\b(" + "|".join(templates) + r")\(")
    while (m := pattern.search(s)):
        end = call_end(s, m.end() - 1)
        args = split_args(s[m.end():end])
        # 끝의 실패 메시지는 #expect에 주석으로 넘긴다
        need = 2 if m.group(1) in ("XCTAssertEqual", "XCTAssertNotEqual") else 1
        rest = args[need:]
        call = templates[m.group(1)](args)
        if rest and rest[0].startswith('"'):
            call = call[:-1] + f", Comment(rawValue: {rest[0]}))"
        s = s[:m.start()] + call + s[end + 1:]
    if "XCT" in s:
        sys.exit("swift-testing으로 바꾸지 못한 XCTest 코드가 남았다")
    return s


def check_strings(zh):
    """번역표(ko.lproj)에 Pesty 문구가 모두 있는지 본다. 빠진 것은 영어 그대로 보인다."""
    pattern = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=', re.M)
    keys = set(pattern.findall(open(zh).read()))
    ko = os.path.join(DST, "RunTime", "ko.lproj", "Localizable.strings")
    have = set(pattern.findall(open(ko).read())) if os.path.exists(ko) else set()
    missing = sorted(keys - have)
    if missing:
        print(f"번역표에 없는 문구 {len(missing)}개:")
        for key in missing:
            print(f'"{key}" = "";')


APPLIED = set()

# 기계적으로 바꿀 수 없는 몇 군데. 원본이 바뀌어 맞는 줄이 없으면 멈춘다
PATCHES = [
    # RunTime의 다른 단축키(사용량 ⌃⌥U, 창 배치, 펫)도 같은 Carbon 대상에 걸린다. 자기 신호가 아니면 넘긴다
    ("""        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKeyCenter.shared.onTrigger?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)""",
     """        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.signature == 0x50535459 else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { HotKeyCenter.shared.onTrigger?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)"""),
    # 끄면 단축키를 놓는다
    ("    private func unregister() {\n        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }",
     "    func stop() {\n        retryGeneration += 1\n        unregister()\n    }\n\n    var isRegistered: Bool { hotKeyRef != nil }\n"
     "    private var retryGeneration = 0\n\n"
     "    private func unregister() {\n        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }"),
    ("        guard attemptsLeft > 0 else { return }\n        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in\n            guard let self else { return }",
     "        guard attemptsLeft > 0 else { return }\n        let generation = retryGeneration\n"
     "        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in\n            guard let self, generation == self.retryGeneration else { return }"),
    ("    func reload() {\n        let previous = hotKeyRef",
     "    func reload() {\n        retryGeneration += 1\n        guard ClipRuntime.running else { return }\n        let previous = hotKeyRef"),
    # 띠는 활성화하지 않는 창이라 크롬이 ⌘1~9를 탭 이동으로 먼저 가져간다. 띠가 떠 있는 동안만 Carbon으로 잡는다 (RunTime/QuickPasteKeys.swift)
    ("            return self.handleKey(event)\n        }\n    }\n\n    private func stopKeyMonitor() {\n"
     "        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }\n    }",
     "            return self.handleKey(event)\n        }\n        QuickPasteKeys.shared.start()\n    }\n\n    private func stopKeyMonitor() {\n"
     "        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }\n        QuickPasteKeys.shared.stop()\n        CardActions.shared.barClosed()\n    }"),
    # TIFF만 있는 이미지는 PNG 변환(5K 한 장 0.2초)을 뒤 큐에서 한다
    ('        if types.contains(.png) || types.contains(.tiff) {\n            if let data = pngData() {',
     '        if types.contains(.png) || types.contains(.tiff) {\n            // TIFF만 있으면 PNG로 바꾸는 데 5K 한 장에 0.2초 걸려 메인에서 하면 러너가 멈춘다. 바꾸기만 뒤에서 한다\n            if pasteboard.data(forType: .png) == nil, let tiff = pasteboard.data(forType: .tiff) {\n                Self.captureInBackground(tiff: tiff, bundleID: bundleID, appName: appName)\n                return nil\n            }\n            if let data = pngData() {'),
    ('    private static func sha256Hex(_ data: Data) -> String {',
     '    private static let convertQueue = DispatchQueue(label: "RunTime.clip.convert", qos: .userInitiated)\n\n    private static func captureInBackground(tiff: Data, bundleID: String?, appName: String?) {\n        convertQueue.async {\n            guard let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }\n            let hash = sha256Hex(png)\n            DispatchQueue.main.async {\n                MainActor.assumeIsolated {\n                    guard let name = ClipboardStore.shared.storeImageData(png) else { return }\n                    var item = ClipItem(type: .image, imageFileName: name, imageHash: hash)\n                    item.sourceBundleID = bundleID\n                    item.sourceAppName = appName\n                    ClipboardStore.shared.addCaptured(item)\n                }\n            }\n        }\n    }\n\n    private nonisolated static func sha256Hex(_ data: Data) -> String {'),
    # 띠 정리: 보드 여럿 대신 '고정' 하나, 위쪽은 최근·고정·계정 탭, 종류 거르기는 작은 메뉴, 키 안내는 위쪽 줄 (RunTime/BarTabs.swift, BarGuide.swift)
    ('                .help("Show every clip type again")\n            }\n        }\n    }',
     '                .help("Show every clip type again")\n            }\n            if store.searchText.isEmpty, store.sourceItems.isEmpty, store.typeFilter == nil {\n                BarEmptyGuide(paused: AppController.shared.monitor.isPaused)\n            }\n        }\n    }'),
    ('        return String(localized: "Nothing copied yet")',
     '        return mode.tab == .pinned ? "고정한 클립이 없습니다" : String(localized: "Nothing copied yet")'),
    ('    @ObservedObject private var settings = Settings.shared\n\n    private var searchIsActive',
     '    @ObservedObject private var settings = Settings.shared\n    @ObservedObject private var mode = BarMode.shared\n\n    private var searchIsActive'),
    ('                topBar\n                ClipTypeFilterBar()\n                strip\n',
     '                topBar\n                if mode.tab == .accounts {\n                    AccountStrip()\n                } else {\n                    strip\n                }\n'),
    ('            searchIndicator\n            PinboardTabs()\n                .layoutPriority(1)\n            Spacer(minLength: 8)\n',
     '            BarTabs()\n            searchIndicator\n            Spacer(minLength: 8)\n            BarKeyHints()\n'),
    ('                undoButton\n            }\n            moreMenu\n',
     '                undoButton\n            }\n            if mode.tab != .accounts { TypeFilterMenu() }\n            moreMenu\n'),
    ('onMoveSelection: { store.moveSelection(by: $0) }',
     'onMoveSelection: { BarKeys.moveSelection(by: $0) }'),
    ('            Button { store.cycleTypeFilter() } label: {\n                Label("Cycle Type Filter", systemImage: "line.3.horizontal.decrease.circle")\n            }\n            Button { store.clearHistory() } label: {',
     '            Button { CardActions.confirmClearHistory() } label: {'),
    ('        store.source = .history\n        store.prepareForBarPresentation()\n',
     '        store.source = .history\n        BarMode.shared.reset()\n        store.prepareForBarPresentation()\n'),
    ('    private func moveBarSection(by delta: Int) {\n        let sources: [BarSource] = [.history] + store.pinboards.map { .pinboard($0.id) }\n        guard !sources.isEmpty else { return }\n\n        let currentIndex = sources.firstIndex(of: store.source) ?? 0\n        let nextIndex = (currentIndex + delta % sources.count + sources.count) % sources.count\n        store.source = sources[nextIndex]\n        store.selectFirst()\n    }\n',
     '    private func moveBarSection(by delta: Int) {\n        BarKeys.moveTab(by: delta)\n    }\n'),
    ('        if handleBarCommandShortcut(event) { return nil }\n',
     '        if handleBarCommandShortcut(event) { return nil }\n        // ⌘P 고정, ⌘Y 미리보기, 계정 탭의 키. 검색창이 키를 갖고 있어도 ⌘P·⌘Y를 듣게 검색창보다 앞에서 받는다\n        if BarKeys.handle(event, searchOwns: barController?.searchOwnsFirstResponder == true) { return nil }\n'),
    # 띠 사용성: ↩·⇧↩, 여는 단축키 한 번 더 = 맨 앞 서식 없이, 검색어 강조, 링크·색 카드 정리, 비밀번호 같은 클립 가리기 (RunTime/BarGuide.swift)
    ('        HotKeyCenter.shared.onTrigger = { [weak self] in self?.toggleBar() }',
     '        HotKeyCenter.shared.onTrigger = { [weak self] in self?.hotKeyPressed() }'),
    ('    func toggleBar() {',
     '    /// 띠가 떠 있을 때 여는 단축키(⇧⌘V)를 한 번 더 누르면 맨 앞 클립을 서식 없이 붙인다. 크롬·슬랙의 서식 없이 붙여넣기 손버릇을 살린다.\n    private func hotKeyPressed() {\n        // 띠가 떠 있어도 다른 앱에서 일하는 중(키 창이 아님)이면 여닫기만 한다\n        guard let bar = barController, bar.isPresented, bar.window?.isKeyWindow == true, BarGuide.repeatPastesPlain else { toggleBar(); return }\n        // 열리는 중에 빠르게 두 번 누른 것은 붙이지 않는다\n        guard QuickPasteKeys.shared.shownFor > 0.35 else { return }\n        guard let first = store.history.first else { hideBar(); return }\n        pasteItem(first, format: .plainText)\n    }\n\n    func toggleBar() {'),
    ('    func pasteSelected() {\n        pasteItems(store.selectedItems)\n    }',
     '    func pasteSelected() {\n        // 계정 탭이면 계정을 넣는다\n        if BarKeys.submitFromSearch() { return }\n        // ⇧↩는 서식 없이 (⇧⌘1~9와 같은 규칙)\n        let event = NSApp.currentEvent\n        let plain = event?.type == .keyDown && event?.modifierFlags.contains(.shift) == true\n        pasteItems(store.selectedItems, format: plain ? .plainText : .original)\n    }'),
    ('        case .link:\n            VStack(spacing: 10) {\n                Spacer(minLength: 0)\n                Image(systemName: "safari").font(.system(size: 34, weight: .light))\n                    .foregroundStyle(Theme.cardTextTertiary)\n                Spacer(minLength: 0)\n            }\n            .frame(maxWidth: .infinity)\n        default:\n            Text(item.text ?? "")',
     '        case .link:\n            VStack(alignment: .leading, spacing: 6) {\n                Text(item.displayTitle)\n                    .font(.system(size: 15, weight: .semibold))\n                    .foregroundStyle(Theme.cardTextPrimary)\n                    .lineLimit(2)\n                Text(BarGuide.highlighted(metaLeft, query: store.searchText, size: 12))\n                    .font(.system(size: 12))\n                    .foregroundStyle(Theme.cardTextSecondary)\n                    .lineLimit(6)\n            }\n            .frame(maxWidth: .infinity, alignment: .leading)\n        default:\n            Text(BarGuide.cardText(item, query: store.searchText))'),
    ('            if item.type == .link {\n                Text(item.displayTitle)\n                    .font(.system(size: 12, weight: .semibold))\n                    .foregroundStyle(Theme.cardTextPrimary).lineLimit(1)\n            }\n            HStack(alignment: .bottom, spacing: 6) {\n                // A path is worth reading in full, so it wraps rather than\n                // collapsing to an ellipsis; everything else stays one line.\n                Text(metaLeft)',
     '            HStack(alignment: .bottom, spacing: 6) {\n                // A path is worth reading in full, so it wraps rather than\n                // collapsing to an ellipsis; everything else stays one line.\n                Text(footerLeft)'),
    ('    private var metaLeft: String {',
     '    /// 링크 주소와 색 값은 카드 가운데에 이미 크게 있으니 아래에는 다른 정보를 둔다.\n    private var footerLeft: String {\n        switch item.type {\n        case .link: return ""\n        case .color:\n            guard let hex = item.colorHex, let c = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return metaLeft }\n            return "RGB \\(Int((c.redComponent * 255).rounded())), \\(Int((c.greenComponent * 255).rounded())), \\(Int((c.blueComponent * 255).rounded()))"\n        default: return metaLeft\n        }\n    }\n\n    private var metaLeft: String {'),
    ('                    Text(cardTypeLabel)\n',
     '                    HStack(spacing: 5) {\n                        if Pinned.contains(item) {\n                            Image(systemName: "pin.fill").font(.system(size: 11, weight: .bold))\n                        }\n                        Text(cardTypeLabel)\n                    }\n'),
    ('    private var cardTypeLabel: String {\n',
     '    private var cardTypeLabel: String {\n        if CardActions.looksSecret(item) { return "비밀번호" }\n'),
    # 카드에서 바로 하기: 마우스를 올리면 뜨는 단추 줄, 오른쪽 클릭 메뉴 줄이기, 기록 모두 지우기 확인 (RunTime/CardActions.swift)
    ('    /// A copy with its own UUID and its own image file, so no two containers',
     '    /// 고정에서 같은 내용의 카드를 뺀다.\n    func removeFromPinboard(_ item: ClipItem, boardID: UUID) {\n        guard let i = pinboards.firstIndex(where: { $0.id == boardID }),\n              let j = pinboards[i].items.firstIndex(where: { $0.sameContent(as: item) }) else { return }\n        let removed = pinboards[i].items.remove(at: j)\n        deleteImageFile(removed)\n        reconcileMultiSelection()\n        // 보고 있던 고정 탭에서 고른 카드를 빼면 선택이 사라진 카드를 가리킨다\n        if let id = selectedID, !visibleItems.contains(where: { $0.id == id }) { selectFirst() }\n        scheduleSave()\n    }\n\n    /// 기록에서만 조건에 맞는 클립을 되살릴 수 없게 지운다. 비밀번호로 보이는 클립을 기록 파일에 오래 두지 않을 때 쓴다.\n    func removeFromHistory(where match: (ClipItem) -> Bool) {\n        let removed = history.filter(match)\n        guard !removed.isEmpty else { return }\n        history.removeAll(where: match)\n        for gone in removed { deleteImageFile(gone) }\n        reconcileMultiSelection()\n        if let id = selectedID, !visibleItems.contains(where: { $0.id == id }) { selectFirst() }\n        scheduleSave()\n    }\n\n    /// 기록과 고정에서 같은 내용을 모두 지운다. 계정으로 옮긴 비밀번호를 평문으로 남기지 않는다.\n    func purge(sameAs item: ClipItem) {\n        let removed = history.filter { $0.sameContent(as: item) } + pinboards.flatMap(\\.items).filter { $0.sameContent(as: item) }\n        history.removeAll { $0.sameContent(as: item) }\n        for i in pinboards.indices { pinboards[i].items.removeAll { $0.sameContent(as: item) } }\n        for gone in removed { deleteImageFile(gone) }\n        reconcileMultiSelection()\n        if let id = selectedID, !visibleItems.contains(where: { $0.id == id }) { selectFirst() }\n        scheduleSave()\n    }\n\n    /// 보드를 맨 앞 하나(고정)로 합친다. 같은 내용은 하나만 남긴다. 합치기 전 기록 파일을 옆에 한 번 남겨 둔다.\n    func mergePinboards() {\n        guard pinboards.count > 1 else { return }\n        // 백업을 남기지 못하면 합치지 않는다\n        let backup = baseDir.appendingPathComponent("store-before-pinned.json")\n        if !FileManager.default.fileExists(atPath: backup.path) {\n            guard (try? FileManager.default.copyItem(at: storeURL, to: backup)) != nil else { return }\n        }\n        var merged = pinboards[0]\n        for item in pinboards.dropFirst().flatMap(\\.items) where !merged.items.contains(where: { $0.sameContent(as: item) }) {\n            merged.items.append(item)\n        }\n        // 겹쳐 빠진 카드의 그림 파일은 지우지 않는다. 백업으로 되돌리면 다시 쓴다\n        pinboards = [merged]\n        if case .pinboard(let id) = source, id != merged.id { source = .pinboard(merged.id) }\n        saveNow(waiting: true)\n    }\n\n    /// A copy with its own UUID and its own image file, so no two containers'),
    ('            paste: { AppController.shared.pasteItem(item) }))',
     '            paste: { if !CardActions.shared.blocksPaste { AppController.shared.pasteItem(item) } }))'),
    ('        .frame(maxWidth: .infinity, maxHeight: .infinity)\n        .background(Theme.cardBody)\n    }',
     '        .frame(maxWidth: .infinity, maxHeight: .infinity)\n        .background(Theme.cardBody)\n        .overlay(alignment: .bottom) {\n            if hovering {\n                CardActionBar(item: item)\n                    .padding(.bottom, 8)\n                    .transition(.opacity)\n            }\n        }\n    }'),
    ('        Button { AppController.shared.pasteSelection(containing: item, format: .cleanFormatting) } label: {\n            Label("Paste with Clean Formatting", systemImage: "paintbrush")\n        }\n        .disabled(!selection.contains(where: FormatConverter.canConvert))\n\n        Button { AppController.shared.pasteSelection(containing: item, format: .markdown) } label: {\n            Label("Paste as Markdown", systemImage: "number")\n        }\n        .disabled(!selection.contains(where: FormatConverter.canConvert))\n\n        Button { AppController.shared.copySelection(containing: item) } label: {\n            Label(selection.count > 1 ? "Copy \\(selection.count) Clips" : "Copy",\n                  systemImage: "doc.on.doc")\n        }\n\n        Divider()\n\n        Button { AppController.shared.editItem(item) } label: {\n            Label("Edit", systemImage: "pencil")\n        }\n        .disabled(!isEditable)\n\n        if writingToolsAvailable {\n            Button { AppController.shared.editItem(item, launchWritingTools: true) } label: {\n                Label("Writing Tools", systemImage: "pencil.and.scribble")\n            }\n        }\n\n        Button { renameItem() } label: {\n            Label("Rename…", systemImage: "pencil.line")\n        }\n\n        Divider()\n\n        Menu {\n            if store.pinboards.isEmpty {\n                Button("No Pinboards Yet") {}\n                    .disabled(true)\n            } else {\n                ForEach(store.pinboards) { b in\n                    Button { store.saveToPinboard(item, boardID: b.id) } label: {\n                        Label {\n                            Text(b.name)\n                        } icon: {\n                            Image(nsImage: Self.pinboardMenuIcon(color: NSColor(b.color)))\n                                .renderingMode(.original)\n                        }\n                    }\n                }\n            }\n            Divider()\n            Button { pinToNewBoard() } label: {\n                Label("Create Pinboard…", systemImage: "plus")\n            }\n        } label: {\n            Label("Pin", systemImage: "pin")\n        }\n\n        Divider()\n\n        Button { AppController.shared.showPreview(for: item) } label: {\n            Label("Preview", systemImage: "eye")\n        }\n\n        Button { AppController.shared.showSharePicker(for: item) } label: {\n            Label("Share", systemImage: "square.and.arrow.up")\n        }\n',
     '        Button { AppController.shared.copySelection(containing: item) } label: {\n            Label(selection.count > 1 ? "Copy \\(selection.count) Clips" : "Copy",\n                  systemImage: "doc.on.doc")\n        }\n\n        Divider()\n\n        Button { Pinned.toggle(selection) } label: {\n            if selection.allSatisfy(Pinned.contains) {\n                Label("고정 풀기 (⌘P)", systemImage: "pin.slash")\n            } else {\n                Label("고정 (⌘P)", systemImage: "pin")\n            }\n        }\n\n        if item.type == .text || item.type == .richText {\n            Button { AccountActions.save(from: item) } label: {\n                Label("계정으로 저장…", systemImage: "key")\n            }\n        }\n\n        Button { AppController.shared.editItem(item) } label: {\n            Label("Edit", systemImage: "pencil")\n        }\n        .disabled(!isEditable)\n\n        Button { renameItem() } label: {\n            Label("Rename…", systemImage: "pencil.line")\n        }\n\n        Button { AppController.shared.showPreview(for: item) } label: {\n            Label("미리보기 (⌘Y)", systemImage: "eye")\n        }\n'),
    ('\n    private func pinToNewBoard() {\n        if let name = TextPrompt.run(title: String(localized: "Create Pinboard"), message: String(localized: "Name")) {\n            let board = store.addPinboard(name: name)\n            store.saveToPinboard(item, boardID: board.id)\n        }\n    }\n\n    private static func pinboardMenuIcon(color: NSColor) -> NSImage {\n        let size = NSSize(width: 12, height: 12)\n        let image = NSImage(size: size, flipped: false) { rect in\n            color.setFill()\n            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()\n            return true\n        }\n        image.isTemplate = false\n        return image\n    }\n',
     ''),
    # 카드 단추를 누를 때 카드 클릭이 함께 잡혀 여러 장 고른 것이 풀리지 않게 한다 (RunTime/CardActions.swift)
    ('            select: { store.select(item.id) },\n            extendSelection: { store.extendSelection(to: item.id) },\n            toggleSelection: { store.toggleSelection(item.id) },',
     '            select: { CardActions.shared.cardClicked { store.select(item.id) } },\n            extendSelection: { CardActions.shared.cardClicked { store.extendSelection(to: item.id) } },\n            toggleSelection: { CardActions.shared.cardClicked { store.toggleSelection(item.id) } },'),
    # 로그인 정보로 보이는 복사는 기록에 두지 않고 계정으로 옮긴다. 비밀번호를 기록 파일에 평문으로 남기지 않는다 (RunTime/Accounts.swift)
    ('        guard let item = makeItem() else { return }\n        ClipboardStore.shared.addCaptured(item)',
     '        guard let item = makeItem() else { return }\n        if AccountCapture.absorb(item) { return }\n        ClipboardStore.shared.addCaptured(item)'),
    # 앱 진입점은 RunTime이다. 메뉴, 메뉴바 아이콘, 로그인 시 실행, 첫 실행 안내는 RunTime 것을 쓴다
    ("        NSApp.setActivationPolicy(.accessory)\n        installMainMenu()\n\n", ""),
    ("        setMenuBarIconVisible(Settings.shared.showMenuBarIcon)\n\n"
     "        if Settings.shared.launchAtLogin { LaunchAtLogin.set(enabled: true) }\n\n", ""),
    ("""        if !Settings.shared.onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
            }
            Settings.shared.onboarded = true
        }
""", ""),
    ("""        let view = SettingsView()
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = String(localized: "Pesty Settings")
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 520, height: 560))
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
""", "        hideBar()\n        ClipRuntime.openSettings()\n"),
    # 띠의 더 보기 메뉴에서 'Pesty 정보'와 '끄기'는 RunTime 앱 전체를 끄거나 Pesty 이름의 정보 창을 띄운다. 기록 멈추기로 바꾼다
    ("""            Divider()
            Button { AppController.shared.showAbout() } label: {
                Label("About Pesty", systemImage: "info.circle")
            }
            Button { NSApp.terminate(nil) } label: {
                Label("Quit Pesty", systemImage: "power")
            }""",
     """            Divider()
            Button { AppController.shared.togglePestyPause() } label: {
                if AppController.shared.monitor.isPaused {
                    Label("Resume Pesty", systemImage: "play.circle")
                } else {
                    Label("Pause Pesty", systemImage: "pause.circle")
                }
            }"""),
    # 기록은 RunTime 자료 폴더에 둔다. 점검(--clip-check)과 테스트는 이 Mac의 기록을 건드리지 않게 따로 둔 폴더를 쓴다
    ("""    static var localBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pesty", isDirectory: true)
    }""",
     """    static var localBase: URL {
        if let folder = ProcessInfo.processInfo.environment["RUNTIME_CLIP_FOLDER"] { return URL(fileURLWithPath: folder, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunTime/Clipboard", isDirectory: true)
    }"""),
    # 복사할 때마다 기록 전체(웹에서 복사하면 클립마다 HTML 수십 KB)를 다시 쓴다. 500개면 40MB 가까이 되어
    # 메인 스레드가 0.1초씩 멈추고 러너가 끊긴다. 쓰기는 뒤 큐에서 차례로 하고, 앱을 끌 때만 끝날 때까지 기다린다
    ("""    func saveNow() {
        let snap = Snapshot(history: history, pinboards: pinboards)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        ignoreWatchUntil = Date().addingTimeInterval(1.5)
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        NotificationCenter.default.post(name: .pestyStoreDidSave, object: nil)
    }""",
     """    private static let saveQueue = DispatchQueue(label: "RunTime.clip.save", qos: .utility)

    func saveNow(waiting: Bool = false) {
        let snap = Snapshot(history: history, pinboards: pinboards)
        let url = storeURL
        ignoreWatchUntil = Date().addingTimeInterval(1.5)
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            DispatchQueue.main.async { NotificationCenter.default.post(name: .pestyStoreDidSave, object: nil) }
        }
        if waiting { Self.saveQueue.sync {} }
    }"""),
    ("        store.forgetDeletions()\n        store.saveNow()\n",
     "        store.forgetDeletions()\n        store.saveNow(waiting: true)\n"),
    # RunTime은 업무 일지·보고처럼 스스로 복사하는 화면이 많다. 띠가 열려 있을 때만 앞서 쓰던 앱에서 복사한 것으로 본다
    ("        if front == nil || front?.bundleIdentifier == Bundle.main.bundleIdentifier {",
     "        if front == nil || (front?.bundleIdentifier == Bundle.main.bundleIdentifier && NSApp.keyWindow is BarPanel) {"),
    # Pesty는 입력칸이 없는 앱이라 자기를 붙여넣을 곳에서 뺀다. RunTime은 업무 일지처럼 입력칸이 있어,
    # RunTime 창에서 띠를 열었으면 그 창으로 돌아가 붙인다
    ("    var suppressAutoHide = false\n",
     "    var suppressAutoHide = false\n    /// 띠를 열 때 키 창이던 RunTime 창. 붙이거나 닫으면 이 창으로 돌아간다.\n    private weak var returnWindow: NSWindow?\n"),
    ("    func showBar() {\n        let front = NSWorkspace.shared.frontmostApplication\n",
     "    func showBar() {\n        let front = NSWorkspace.shared.frontmostApplication\n"
     "        returnWindow = front.map(isPesty) == true && !(NSApp.keyWindow is BarPanel) ? NSApp.keyWindow : nil\n"),
    # 계정 탭이 붙여 넣을 앱과 그 창 제목을 본다 (RunTime/AccountFill.swift)
    ("    private var pasteTarget: NSRunningApplication? {\n        [lastActiveApp,",
     "    var pasteTarget: NSRunningApplication? {\n        if returnWindow?.isVisible == true { return .current }\n        return [lastActiveApp,"),
    ("    func hideBar() {\n        stopKeyMonitor()\n        barController?.hide()\n    }",
     "    func hideBar() {\n        stopKeyMonitor()\n        barController?.hide()\n"
     "        // 순서는 바꾸지 않고 키만 돌려준다. 바깥 다른 앱을 눌러 닫혔으면 그 앱 위로 올라오지 않는다\n"
     "        if let window = returnWindow, window.isVisible { window.makeKey() }\n    }"),
    # 검색은 초성(ㅋㄹㅂㄷ)으로도 찾는다
    ("return result.filter { $0.searchableText.contains(query) }",
     "return result.filter { ClipSearch.matches($0.searchableText, query: query) }"),
]

if __name__ == "__main__":
    main(sys.argv[1])
    for path, names in sorted(PUBLISHED.items()):
        print(f"{path}: @Published {len(names)}개 ({', '.join(names)})")
    missed = [old for old, _ in PATCHES if old not in APPLIED]
    if missed:
        sys.exit("Pesty 원본이 바뀌어 맞는 자리를 찾지 못한 수정:\n" + "\n---\n".join(missed))
