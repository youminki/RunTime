import AppKit
import Carbon.HIToolbox

/// 어느 앱을 쓰고 있든 단축키(기본 ⌃⌥U)로 사용량 창을 연다. Carbon 단축키는 손쉬운 사용 권한 없이 동작한다.
/// 기본은 다른 앱 단축키와 겹치지 않도록 잘 쓰지 않는 control+option 조합이고, 설정에서 바꿀 수 있다.
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static var displayName: String { shared.combo.label }

    /// 키 하나와 보조키 조합. modifiers는 Carbon 값(cmdKey 등)이다.
    struct Combo: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String

        static let standard = Combo(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥U")
    }

    var action: () -> Void = {}
    /// 업무 일지 한 줄 적기 (⌃⌥L). 사용량 단축키와 같은 처리기에서 번호로 가른다.
    var quickAction: () -> Void = {}
    static let quickCombo = Combo(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥L")
    private var quickHotKey: EventHotKeyRef?
    private(set) var quickFailed = false
    /// 사용량 단축키와 같은 조합이라 등록하지 않았다.
    private(set) var quickClashes = false
    private var quickEnabled = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var isRegistered: Bool { hotKey != nil }
    /// 등록을 시도했다가 실패했는지 (다른 앱이 같은 조합을 먼저 잡음). 등록 전에는 false.
    private(set) var failed = false
    private var enabled = false
    private(set) var combo: Combo

    private enum Key {
        static let code = "hotKeyCode", modifiers = "hotKeyModifiers", label = "hotKeyLabel"
    }

    private init() {
        let defaults = UserDefaults.standard
        if let label = defaults.string(forKey: Key.label), defaults.object(forKey: Key.code) != nil {
            combo = Combo(keyCode: UInt32(defaults.integer(forKey: Key.code)),
                          modifiers: UInt32(defaults.integer(forKey: Key.modifiers)), label: label)
        } else {
            combo = .standard
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        enabled ? register() : unregister()
    }

    /// 새 조합을 저장하고, 켜져 있으면 바로 다시 등록한다.
    func setCombo(_ combo: Combo) {
        self.combo = combo
        defer { setQuickAdd(quickEnabled) }   // 사용량 단축키를 ⌃⌥L로 바꾸면 한 줄 적기를 비킨다
        let defaults = UserDefaults.standard
        defaults.set(Int(combo.keyCode), forKey: Key.code)
        defaults.set(Int(combo.modifiers), forKey: Key.modifiers)
        defaults.set(combo.label, forKey: Key.label)
        unregister()
        if enabled { register() }
    }

    /// 새 조합을 기록하는 동안 잠깐 끈다. 켜 두면 같은 조합을 눌렀을 때 Carbon이 먼저 가져가 기록되지 않는다.
    func suspend() {
        unregister()
        // 새 조합을 기록하는 동안 ⌃⌥L도 비켜 둔다
        if let quickHotKey { UnregisterEventHotKey(quickHotKey) }
        quickHotKey = nil
    }

    func resume() {
        if enabled { register() }
        setQuickAdd(quickEnabled)
    }

    func setQuickAdd(_ enabled: Bool) {
        quickEnabled = enabled
        if let quickHotKey { UnregisterEventHotKey(quickHotKey) }
        quickHotKey = nil
        quickFailed = false
        quickClashes = enabled && combo.keyCode == Self.quickCombo.keyCode && combo.modifiers == Self.quickCombo.modifiers
        guard enabled, !quickClashes else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5254_494D), id: 2)
        let combo = Self.quickCombo
        quickFailed = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &quickHotKey) != noErr
        if quickFailed { quickHotKey = nil }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let quick = pressed.id == 2
            DispatchQueue.main.async { quick ? GlobalHotKey.shared.quickAction() : GlobalHotKey.shared.action() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func register() {
        guard hotKey == nil else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5254_494D), id: 1)   // 'RTIM'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        failed = status != noErr
        if failed {
            hotKey = nil   // 다른 앱이 같은 조합을 먼저 잡은 경우 (eventHotKeyExistsErr)
            NSLog("[RunTime] 단축키 등록 실패: %d", status)
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        failed = false
    }
}

extension GlobalHotKey.Combo {
    /// 누른 키로 조합을 만든다. ⌘·⌥·⌃ 가운데 하나는 있어야 한다 (글자만 누르면 글을 쓸 때마다 열린다).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty,
              let name = Self.keyName(event.keyCode) else { return nil }
        var carbon = 0
        var label = ""
        if flags.contains(.control) { carbon |= controlKey; label += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; label += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; label += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; label += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(carbon), label: label + name)
    }

    /// 키 이름은 입력기와 상관없이 자판 자리로 정한다 (한글 입력 중에도 U가 'ㅕ'로 보이지 않게).
    static func keyName(_ code: UInt16) -> String? {
        if let name = names[Int(code)] { return name }
        return nil
    }

    private static let names: [Int: String] = {
        var map: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        let ansi: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","),
            (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Grave, "`"),
        ]
        for (code, name) in ansi { map[code] = name }
        return map
    }()
}

/// 설정 화면에서 새 단축키를 기록한다. `@State`를 못 써서(HoverFlag 참고) 관찰 객체로 둔다.
final class HotKeyRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published var hint: String?
    private var monitor: Any?
    private var observers: [Any] = []

    func toggle() { recording ? stop() : start() }

    func start() {
        guard !recording else { return }
        recording = true
        hint = nil
        GlobalHotKey.shared.suspend()
        // 키를 받을 창이 바뀌거나 앱이 뒤로 가거나 창이 닫히면 멈춘다. 그대로 두면 앱의 모든 키를 삼키고
        // 단축키도 꺼진 채 남는다. 기록을 누른 순간 키 창이 없을 수도 있어 키는 그때그때의 키 창에서 받는다.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window != nil, event.window === NSApp.keyWindow else { return event }
            self?.handle(event)
            return nil
        }
        // 기록을 누른 창을 알면 그 창만 본다 (툴팁 같은 다른 창이 닫힐 때 멈추지 않게)
        let window = NSApp.keyWindow
        let center = NotificationCenter.default
        observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.stop() }
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.stop() })
    }

    func stop() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        monitor = nil
        observers = []
        recording = false
        GlobalHotKey.shared.resume()
    }

    func reset() {
        GlobalHotKey.shared.setCombo(.standard)
        objectWillChange.send()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        guard let combo = GlobalHotKey.Combo(event: event) else {
            hint = "⌘·⌥·⌃ 가운데 하나와 함께 눌러 주세요."
            return
        }
        stop()
        GlobalHotKey.shared.setCombo(combo)
        hint = GlobalHotKey.shared.failed ? "다른 앱이 이 조합을 쓰고 있어 등록하지 못했습니다." : nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        if recording { GlobalHotKey.shared.resume() }
    }
}
