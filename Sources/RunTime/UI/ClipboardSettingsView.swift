import AppKit
import Carbon.HIToolbox
import ClipKit
import SwiftUI
import UniformTypeIdentifiers

/// 설정 > 클립보드. 켜기, 단축키, 붙여넣기, 보관, 기록하지 않을 앱을 한 화면에 둔다.
struct ClipboardSettingsView: View {
    @ObservedObject var clipboard: Clipboard
    @ObservedObject private var prefs = ClipPreferences.shared
    @ObservedObject private var layout = WindowLayout.shared
    @StateObject private var recorder = ClipKeyRecorder()
    /// 화면 찍기(--ui-shots)에서 켜지 않고도 모든 묶음을 보인다.
    var showsAll = false

    var body: some View {
        GroupedList {
            header
            if clipboard.enabled || showsAll {
                pasting
                retention
                ignored
                history
            }
        }
        .onAppear { if clipboard.enabled || showsAll { prefs.refreshDataSize() } }
        .onDisappear { recorder.stop() }
    }

    // MARK: 켜기

    @ViewBuilder private var header: some View {
        GroupedSection(footer: "복사한 텍스트·이미지·파일·색을 이 Mac에 쌓아 두고, 단축키로 화면 아래에 띄워 골라 붙입니다. 기록은 어디로도 보내지 않습니다.") {
            ToggleRow(title: "클립보드 기록 켜기", icon: "doc.on.clipboard", isOn: $clipboard.enabled)
            if clipboard.enabled || showsAll {
                GroupedRow("열기 단축키", icon: "keyboard") {
                    HStack(spacing: 6) {
                        if !isDefaultKey && !recorder.recording {
                            Button("기본으로") { recorder.reset(clipboard) }
                        }
                        Button(recorder.recording ? "새 조합을 누르세요 (esc 취소)" : clipboard.hotKeyLabel) {
                            recorder.toggle(clipboard)
                        }
                        .tip("누른 뒤 원하는 조합을 누르면 바뀝니다")
                    }
                    .controlSize(.small)
                }
                if let hint = recorder.hint {
                    GroupedRow(hint, icon: "exclamationmark.circle").foregroundStyle(Palette.orange)
                } else if clipboard.enabled && !ClipRuntime.hotKeyRegistered {
                    GroupedRow("다른 앱이 이 단축키를 쓰고 있어 등록하지 못했습니다.", icon: "exclamationmark.circle")
                        .foregroundStyle(Palette.orange)
                }
            }
        }
    }

    private var isDefaultKey: Bool {
        prefs.hotKeyCode == ClipPreferences.defaultHotKeyCode && prefs.hotKeyModifiers == ClipPreferences.defaultHotKeyModifiers
    }

    // MARK: 붙여넣기

    @ViewBuilder private var pasting: some View {
        GroupedSection("붙여넣기", footer: "띠에서 ⌘1~9로 앞의 아홉 개를 바로 붙이고, ⇧을 함께 누르면 서식 없이 붙입니다. 바로 붙여넣기는 창 배치와 같은 손쉬운 사용 권한을 씁니다.") {
            ToggleRow(title: "쓰던 앱에 바로 붙여넣기", icon: "arrow.down.doc", isOn: $prefs.pasteDirectly)
            if prefs.pasteDirectly && !layout.trusted {
                GroupedRow("권한이 없어 복사만 합니다. ⌘V는 직접 누르세요", icon: "lock") {
                    Button("권한 허용") { layout.requestAccess() }.controlSize(.small)
                }
                .foregroundStyle(Palette.orange)
            }
            ToggleRow(title: "붙여넣은 클립을 맨 앞으로", icon: "arrow.left.to.line", isOn: $prefs.promoteOnPaste)
            ToggleRow(title: "고른 클립을 오른쪽 끝에 두기", icon: "rectangle.righthalf.inset.filled", isOn: $prefs.selectedAtRightEdge)
            ToggleRow(title: "띠 바깥을 누르면 닫기", icon: "xmark.rectangle", isOn: $prefs.hideOnClickOutside)
            ToggleRow(title: "띠에 크기 손잡이 보이기", icon: "arrow.up.and.down", isOn: $prefs.showResizeHandle)
            ToggleRow(title: "붙여넣을 때 소리 내기", icon: "speaker.wave.2", isOn: $prefs.playSound)
        }
    }

    // MARK: 보관

    @ViewBuilder private var retention: some View {
        GroupedSection("보관", footer: "기준을 넘은 기록은 저절로 지웁니다. 보드에 담은 클립은 지우지 않습니다.") {
            GroupedRow("정리 기준", icon: "line.3.horizontal.decrease") {
                Picker("정리 기준", selection: Binding(
                    get: { prefs.keepByAge },
                    set: { apply(byAge: $0, limit: prefs.historyLimit, days: prefs.historyDays == 0 && $0 ? 30 : prefs.historyDays) })) {
                    Text("개수").tag(false)
                    Text("기간").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if prefs.keepByAge {
                GroupedRow("이보다 오래된 것 지우기", icon: "calendar") {
                    Picker("기간", selection: Binding(
                        get: { nearestDays(prefs.historyDays) },
                        set: { apply(byAge: true, limit: prefs.historyLimit, days: $0) })) {
                        ForEach(ClipPreferences.retentionDays, id: \.self) { Text(ClipPreferences.dayLabel($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            } else {
                GroupedRow("최대 보관", icon: "number") {
                    Picker("개수", selection: Binding(
                        get: { nearestLimit(prefs.historyLimit) },
                        set: { apply(byAge: false, limit: $0, days: prefs.historyDays) })) {
                        ForEach(ClipPreferences.historyLimits, id: \.self) { Text("\($0)개").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            ToggleRow(title: "지운 클립 되살리지 않기 (⌘Z 없이 바로 삭제)", icon: "trash", isOn: $prefs.deletePermanently)
        }
    }

    private func nearestDays(_ days: Int) -> Int {
        ClipPreferences.retentionDays.min { abs($0 - days) < abs($1 - days) } ?? 30
    }

    private func nearestLimit(_ limit: Int) -> Int {
        ClipPreferences.historyLimits.min { abs($0 - limit) < abs($1 - limit) } ?? 500
    }

    /// 기준을 바꿔 지금 지워지는 기록이 있으면 먼저 묻는다. 되돌릴 수 없다.
    private func apply(byAge: Bool, limit: Int, days: Int) {
        let removed = prefs.removalCount(byAge: byAge, limit: limit, days: days)
        if removed > 0 {
            let alert = NSAlert()
            alert.messageText = "클립 \(removed)개를 지울까요?"
            alert.informativeText = "바꾼 기준을 넘는 기록을 지금 지우고, 앞으로도 저절로 정리합니다. 보드는 그대로이고 되돌릴 수 없습니다."
            alert.addButton(withTitle: "지우기").hasDestructiveAction = true
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        prefs.setRetention(byAge: byAge, limit: limit, days: days)
    }

    // MARK: 기록하지 않을 것

    @ViewBuilder private var ignored: some View {
        GroupedSection("기록하지 않을 것", footer: "이 앱들이 앞에 있을 때 복사한 것은 남기지 않습니다. 암호 관리자가 숨김 표시를 붙인 암호는 이 설정과 관계없이 늘 남기지 않습니다.") {
            ToggleRow(title: "자동으로 만든 항목(생성한 암호 등)도 기록하지 않기", icon: "key", isOn: $prefs.ignoreConcealed)
            ForEach(prefs.ignoredApps, id: \.self) { bundleID in
                GroupedRow(Self.appName(bundleID), icon: "app") {
                    Button("빼기") { prefs.allowApp(bundleID) }.controlSize(.small)
                }
            }
            GroupedRow("앱 추가", icon: "plus") {
                Button("고르기…") { chooseApps() }.controlSize(.small)
            }
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "추가"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { prefs.ignoreApp(id) }
        }
    }

    // MARK: 기록

    @ViewBuilder private var history: some View {
        GroupedSection("기록", footer: "기록은 \((prefs.dataFolder.path as NSString).abbreviatingWithTildeInPath)에 있습니다. 멈추면 그동안 복사한 것은 남기지 않습니다.") {
            GroupedRow("클립 \(prefs.historyCount)개, 보드 \(prefs.pinboardCount)개 · \(ByteCountFormatter.string(fromByteCount: prefs.dataBytes, countStyle: .file))", icon: "tray.full") {
                Button("폴더 열기") { NSWorkspace.shared.open(prefs.dataFolder) }.controlSize(.small)
            }
            GroupedRow(prefs.paused ? "기록을 멈췄습니다" : "복사할 때마다 기록합니다", icon: prefs.paused ? "pause.circle" : "record.circle") {
                Button(prefs.paused ? "다시 기록" : "멈추기") { prefs.togglePause() }.controlSize(.small)
                    .disabled(!clipboard.enabled)
            }
            GroupedRow("기록 지우기", icon: "trash") {
                Button("모두 지우기…") { confirmClear() }.controlSize(.small)
                    .disabled(prefs.historyCount == 0)
            }
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "클립 \(prefs.historyCount)개를 모두 지울까요?"
        alert.informativeText = "보드에 담은 클립은 남습니다. 되돌릴 수 없습니다."
        alert.addButton(withTitle: "지우기").hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn { prefs.clearHistory() }
    }
}

/// 클립보드 기록 단축키를 새로 기록한다. 창 배치 단축키 기록기와 같은 방식이다.
@MainActor
final class ClipKeyRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published var hint: String?
    private var monitor: Any?
    private var observers: [Any] = []

    func toggle(_ clipboard: Clipboard) { recording ? stop() : start(clipboard) }

    func start(_ clipboard: Clipboard) {
        guard !recording else { return }
        recording = true
        hint = nil
        ClipRuntime.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window != nil, event.window === NSApp.keyWindow else { return event }
            self?.handle(event, clipboard)
            return nil
        }
        // 키 창이 바뀌거나 앱이 뒤로 가면 멈춘다. 그대로 두면 앱의 모든 키를 삼킨다
        let window = NSApp.keyWindow
        let center = NotificationCenter.default
        observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    func stop() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        monitor = nil
        observers = []
        recording = false
        ClipRuntime.resumeHotKey()
    }

    func reset(_ clipboard: Clipboard) {
        let combo = KeyCombo(keyCode: UInt32(ClipPreferences.defaultHotKeyCode),
                                       modifiers: UInt32(ClipPreferences.defaultHotKeyModifiers), label: "⇧⌘V")
        hint = clipboard.setHotKey(combo)
    }

    private func handle(_ event: NSEvent, _ clipboard: Clipboard) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        guard let combo = KeyCombo(event: event) else {
            hint = "⌘·⌥·⌃ 가운데 하나와 함께 눌러 주세요."
            return
        }
        stop()
        hint = clipboard.setHotKey(combo)
    }
}
