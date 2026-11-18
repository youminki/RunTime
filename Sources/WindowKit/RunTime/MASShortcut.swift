import Cocoa
import Carbon.HIToolbox

// Rectangle이 쓰는 MASShortcut(BSD) 라이브러리의 필요한 부분만 같은 이름으로 다시 만들었다.
// 저장 형식(사전의 keyCode·modifierFlags)과 Carbon 전역 단축키 동작을 맞춰, Rectangle 코드를 고치지 않고 쓴다.

let MASDictionaryTransformerName = "MASDictionaryTransformer"

class MASShortcut: NSObject {
    let keyCode: Int
    let modifierFlags: NSEvent.ModifierFlags

    required init(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection([.control, .option, .shift, .command])
        super.init()
    }

    var carbonKeyCode: UInt32 { UInt32(keyCode) }

    var carbonFlags: UInt32 {
        var carbon = 0
        if modifierFlags.contains(.command) { carbon |= cmdKey }
        if modifierFlags.contains(.option) { carbon |= optionKey }
        if modifierFlags.contains(.control) { carbon |= controlKey }
        if modifierFlags.contains(.shift) { carbon |= shiftKey }
        return UInt32(carbon)
    }

    /// 입력기와 상관없이 자판 자리로 이름을 정한다 (한글 입력 중에도 U가 'ㅕ'로 보이지 않게).
    var keyCodeString: String? { KeyName.name(keyCode) }

    /// 메뉴 항목의 단축키 글자. 화살표 등은 NSMenu가 쓰는 기능키 문자로 준다.
    var keyCodeStringForKeyEquivalent: String? {
        if let special = Self.menuKeys[keyCode] { return String(Character(UnicodeScalar(special)!)) }
        return KeyName.name(keyCode).map { $0.count == 1 ? $0.lowercased() : "" }
    }

    var modifierFlagsString: String {
        var text = ""
        if modifierFlags.contains(.control) { text += "⌃" }
        if modifierFlags.contains(.option) { text += "⌥" }
        if modifierFlags.contains(.shift) { text += "⇧" }
        if modifierFlags.contains(.command) { text += "⌘" }
        return text
    }

    override var description: String { modifierFlagsString + (keyCodeString ?? "") }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MASShortcut else { return false }
        return keyCode == other.keyCode && modifierFlags == other.modifierFlags
    }

    override var hash: Int { keyCode ^ Int(modifierFlags.rawValue) }

    private static let menuKeys: [Int: Int] = [
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
        kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        kVK_ForwardDelete: NSDeleteFunctionKey, kVK_Delete: 0x08, kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Space: 0x20,
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
        kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
        kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
    ]
}

/// 사전 ↔ MASShortcut. MASShortcut 라이브러리와 같은 키를 써서 Rectangle 설정 파일을 그대로 읽는다.
final class MASDictionaryTransformer: ValueTransformer {
    static func register() {
        ValueTransformer.setValueTransformer(MASDictionaryTransformer(),
                                             forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName))
    }

    override class func allowsReverseTransformation() -> Bool { true }
    override class func transformedValueClass() -> AnyClass { MASShortcut.self }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let dict = value as? [String: Any], let keyCode = (dict["keyCode"] as? NSNumber)?.intValue,
              let flags = (dict["modifierFlags"] as? NSNumber)?.uintValue else { return nil }
        return MASShortcut(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: flags))
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let shortcut = value as? MASShortcut else { return nil }
        return ["keyCode": shortcut.keyCode, "modifierFlags": shortcut.modifierFlags.rawValue]
    }
}

/// 설정 키에 저장한 단축키를 Carbon 전역 단축키로 잡는다. 키 값이 바뀌면 다시 잡는다.
final class MASShortcutBinder: NSObject {
    private static let instance = MASShortcutBinder()
    static func shared() -> MASShortcutBinder? { instance }

    var bindingOptions: [NSBindingOption: Any] = [:]
    /// 등록하지 못한 설정 키 (다른 앱이 같은 조합을 먼저 잡음).
    private(set) var failedKeys: Set<String> = []
    var onFailuresChanged: () -> Void = {}

    private struct Binding {
        let action: () -> Void
        var shortcut: MASShortcut?
        var ref: EventHotKeyRef?
        let id: UInt32
    }

    private static let signature = OSType(0x5254_574E)   // 'RTWN'
    private var bindings: [String: Binding] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var defaultsObserver: NSObjectProtocol?
    /// 누르고 있는 동안 되풀이할 설정 키 (크게·작게, 조금씩 옮기기). Carbon 단축키는 저절로 되풀이하지 않는다.
    var repeatingKeys: Set<String> = []
    private var repeatTimer: Timer?

    private override init() {
        super.init()
        MASDictionaryTransformer.register()
    }

    func registerDefaultShortcuts(_ shortcuts: [String: MASShortcut]) {
        let transformer = MASDictionaryTransformer()
        var defaults: [String: Any] = [:]
        for (key, shortcut) in shortcuts {
            if let dict = transformer.reverseTransformedValue(shortcut) { defaults[key] = dict }
        }
        WindowDefaults.store.register(defaults: defaults)
    }

    func bindShortcut(withDefaultsKey key: String, toAction action: @escaping () -> Void) {
        breakBinding(withDefaultsKey: key)
        install()
        var binding = Binding(action: action, shortcut: nil, ref: nil, id: nextID)
        nextID &+= 1
        register(&binding, key: key)
        bindings[key] = binding
        observeDefaults()
    }

    func breakBinding(withDefaultsKey key: String) {
        guard let binding = bindings.removeValue(forKey: key) else { return }
        if let ref = binding.ref { UnregisterEventHotKey(ref) }
        if failedKeys.remove(key) != nil { onFailuresChanged() }
    }

    static func storedShortcut(forKey key: String) -> MASShortcut? {
        MASDictionaryTransformer().transformedValue(WindowDefaults.store.dictionary(forKey: key)) as? MASShortcut
    }

    private func register(_ binding: inout Binding, key: String) {
        if let ref = binding.ref { UnregisterEventHotKey(ref) }
        binding.ref = nil
        binding.shortcut = Self.storedShortcut(forKey: key)
        var failed = false
        guard !WindowRuntime.paused, !WindowRuntime.recording else {
            if failedKeys.remove(key) != nil { onFailuresChanged() }
            return
        }
        // 마우스 버튼 단축키는 MouseButtonShortcutMonitor가 따로 잡는다
        if let shortcut = binding.shortcut, MouseButtonShortcut.buttonNumber(forKeyCode: shortcut.keyCode) == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: binding.id)
            if RegisterEventHotKey(shortcut.carbonKeyCode, shortcut.carbonFlags, id, GetApplicationEventTarget(), 0, &ref) == noErr {
                binding.ref = ref
            } else {
                failed = true
            }
        }
        let changed = failed ? failedKeys.insert(key).inserted : failedKeys.remove(key) != nil
        if changed { onFailuresChanged() }
    }

    /// 설정 화면이나 가져오기로 단축키 값이 바뀌면 그 키만 다시 잡는다.
    private func observeDefaults() {
        guard defaultsObserver == nil else { return }
        // RunTime의 다른 설정(사용량, 업무 일지…)이 바뀔 때는 볼 필요가 없다
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: WindowDefaults.store,
                                                                  queue: .main) { [weak self] _ in
            guard let self else { return }
            for (key, binding) in self.bindings where Self.storedShortcut(forKey: key) != binding.shortcut {
                var updated = binding
                self.register(&updated, key: key)
                self.bindings[key] = updated
            }
        }
    }

    private func install() {
        guard handler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.signature == MASShortcutBinder.signature else { return OSStatus(eventNotHandledErr) }
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = pressed.id
            DispatchQueue.main.async { MASShortcutBinder.instance.hotKey(id: id, down: down) }
            return noErr
        }, specs.count, &specs, nil, &handler)
    }

    /// 누르면 한 번 하고, 되풀이하는 키면 0.35초 뒤부터 놓을 때까지 0.06초마다 한다.
    private func hotKey(id: UInt32, down: Bool) {
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard down, let (key, binding) = bindings.first(where: { $0.value.id == id }) else { return }
        binding.action()
        guard repeatingKeys.contains(key) else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] timer in
                // 보조키를 먼저 떼면 놓음 이벤트가 오지 않는다. 키와 보조키가 실제로 눌려 있을 때만 되풀이한다
                guard let self, !WindowRuntime.paused, let binding = self.bindings[key], binding.ref != nil,
                      let shortcut = binding.shortcut, Self.isHeld(shortcut) else { return timer.invalidate() }
                binding.action()
            }
        }
    }

    /// 그 단축키의 키와 보조키가 지금 모두 눌려 있는지. 수를 세거나 내용을 읽지 않아 권한이 필요 없다.
    /// 점검 도구는 키를 실제로 누르지 않아 눌린 것으로 친다.
    static var assumesHeld = false

    static func isHeld(_ shortcut: MASShortcut) -> Bool {
        if assumesHeld { return true }
        guard CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.keyCode)) else { return false }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let needed: [(NSEvent.ModifierFlags, CGEventFlags)] = [(.control, .maskControl), (.option, .maskAlternate),
                                                                (.shift, .maskShift), (.command, .maskCommand)]
        return needed.allSatisfy { !shortcut.modifierFlags.contains($0.0) || flags.contains($0.1) }
    }

    /// 창 배치를 껐다 켤 때 모든 단축키를 놓거나 다시 잡는다.
    func refreshAll() {
        for (key, binding) in bindings {
            var updated = binding
            register(&updated, key: key)
            bindings[key] = updated
        }
    }

    /// 지금 잡힌 단축키의 설정 키.
    var boundKeys: [String] { bindings.compactMap { $0.value.ref == nil ? nil : $0.key } }

    /// 점검 도구용: 그 설정 키의 단축키를 누른 것처럼 처리기를 부른다.
    func simulatePress(defaultsKey key: String, down: Bool = true) -> Bool {
        guard let binding = bindings[key] else { return false }
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(down ? kEventHotKeyPressed : kEventHotKeyReleased), 0, 0, &event)
        guard let event else { return false }
        var id = EventHotKeyID(signature: Self.signature, id: binding.id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &id)
        SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
        return true
    }
}

/// 단축키가 쓸 만한지 판단한다. RunTime의 기록기는 직접 걸러 내므로 기본은 모두 받는다.
class MASShortcutValidator: NSObject {
    var allowAnyShortcutWithOptionModifier = false

    func isShortcutValid(_ shortcut: MASShortcut!) -> Bool {
        guard let shortcut else { return false }
        return !shortcut.modifierFlags.intersection([.control, .option, .command]).isEmpty
    }

    func isShortcutAlreadyTaken(bySystem shortcut: MASShortcut!, explanation: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Bool {
        false
    }

    func isShortcut(_ shortcut: MASShortcut!, alreadyTakenIn menu: NSMenu!, explanation: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Bool {
        false
    }
}
