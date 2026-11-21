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
    # RunTime은 macOS 13부터 돈다. 이 SF Symbol은 macOS 14부터라 같은 뜻의 오래된 그림으로 바꾼다 (scripts/check-symbols.py)
    ('Label("Writing Tools", systemImage: "pencil.and.scribble")',
     'Label("Writing Tools", systemImage: "pencil.line")'),
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
