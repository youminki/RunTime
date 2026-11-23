import AppKit
import Carbon.HIToolbox

/// 띠가 떠 있는 동안 빠른 붙여넣기(⌘1~9, 서식 없이 ⇧⌘1~9)를 Carbon 단축키로 잡는다.
/// 띠는 활성화하지 않는 창이라 크롬이 앞 앱으로 남으면 ⌘숫자를 크롬 탭 이동이 먼저 가져간다.
/// Carbon 단축키는 앱 메뉴보다 먼저 받으므로, 띠를 닫으면 바로 놓아 평소 ⌘숫자는 앞 앱이 쓴다.
@MainActor
final class QuickPasteKeys {
    static let shared = QuickPasteKeys()

    /// HotKeyCenter(PSTY)와 다른 신호. 자기 것이 아니면 다른 처리기로 넘긴다.
    private static let signature: OSType = 0x50535451
    private static let digitCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                     kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    private var startedAt = Date.distantPast
    /// 띠가 뜬 뒤 지난 시간. 열리는 중에 여는 단축키를 두 번 누른 것을 가려낸다.
    var shownFor: TimeInterval { Date().timeIntervalSince(startedAt) }

    private init() {}

    func start() {
        stop()
        startedAt = Date()
        installHandlerIfNeeded()
        let quick = Settings.shared.quickPasteModifier
        let plain = Settings.shared.plainTextModifier
        register(modifiers: quick, plain: false)
        if plain != quick { register(modifiers: quick | plain, plain: true) }
    }

    func stop() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    /// id: 1~9는 원래 서식, 11~19는 서식 없이.
    private func register(modifiers: Int, plain: Bool) {
        for (index, code) in Self.digitCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1 + (plain ? 10 : 0)))
            if RegisterEventHotKey(UInt32(code), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.signature == 0x50535451 else { return OSStatus(eventNotHandledErr) }
            let id = Int(pressed.id)
            DispatchQueue.main.async { QuickPasteKeys.shared.paste(digit: id % 10, plain: id > 10) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private func paste(digit: Int, plain: Bool) {
        if BarMode.shared.tab == .accounts {
            let accounts = BarMode.shared.visibleAccounts
            if digit >= 1, digit <= accounts.count { AccountFill.fill(accounts[digit - 1], part: plain ? .password : .auto) }
            return
        }
        let items = ClipboardStore.shared.visibleItems
        guard digit >= 1, digit <= items.count else { return }
        AppController.shared.pasteItem(items[digit - 1], format: plain ? .plainText : .original)
    }
}
