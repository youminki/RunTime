import AppKit
import ApplicationServices
import Carbon.HIToolbox
import LocalAuthentication

/// 계정을 쓰던 앱의 입력칸에 넣는다. 아이디를 붙이고 Tab, 비밀번호를 붙인다.
/// 한 글자씩 치면 한글 입력기가 영문 키를 가로채므로 붙여넣기로 넣고, 넣은 뒤에는 클립보드를 원래대로 돌린다.
/// 넣는 동안 클립보드에는 숨김·임시 표시를 붙여 이 기록과 다른 클립보드 앱이 남기지 않는다.
@MainActor
enum AccountFill {
    enum Part {
        /// 입력칸이 비밀번호 칸이면 비밀번호만, 아니면 아이디 → Tab → 비밀번호.
        case auto
        case username
        case password
    }

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static var generation = 0
    /// 넣는 동안 잠시 비켜 둔 원래 클립보드. 넣기가 겹치면 처음 것을 그대로 둔다.
    private static var pendingRestore: [[NSPasteboard.PasteboardType: Data]]?
    /// 마지막으로 이 기능이 쓴 클립보드. 그 뒤 사람이 새로 복사했으면 되돌리지 않는다.
    private static var lastWritten = -1
    private static var reader: PasteReader?

    static func fill(_ account: Account, part: Part = .auto) {
        AccountLock.unlock(reason: "\(account.title) 계정을 입력합니다") {
            run(account, part: part)
        }
    }

    private static func run(_ account: Account, part: Part) {
        let store = AccountStore.shared
        let needsPassword = part != .username
        let password = needsPassword ? store.password(for: account) : nil
        if needsPassword, password == nil {
            AccountCapture.notify("키체인에서 비밀번호를 읽지 못했습니다", symbol: "exclamationmark.triangle.fill")
            return
        }
        let target = AppController.shared.pasteTarget
        AppController.shared.hideBar()
        store.markUsed(account.id)
        let fallback = part == .username ? account.username : (password ?? "")

        guard Settings.shared.pasteDirectly, AXIsProcessTrusted(), let target, !target.isTerminated else {
            // 바로 넣을 수 없으면 비밀번호(아이디만이면 아이디)를 복사해 두고 ⌘V는 사람이 누른다
            copyInstead(fallback, username: part == .username, reason: nil)
            target?.activate()
            return
        }

        generation += 1
        lastWarning = nil
        let run = generation
        target.activate()
        // 사파리는 앞으로 오기까지 1초 넘게 걸릴 때가 있다. 넉넉히 기다리고, 끝내 못 오면 아무 일 없이 끝내지 않고 알린다
        waitForFrontmost(target, attempts: 70, failed: {
            finish(run)
            AccountCapture.notify("\(target.localizedName ?? "앱")이 앞으로 오지 않아 넣지 못했습니다", symbol: "exclamationmark.triangle.fill")
        }) {
            guard run == generation else { return }
            let field = focusedField(pid: target.processIdentifier)
            // 초점이 입력칸이 아닌 것(메신저 목록, 웹 페이지 본문)이 분명하면 넣지 않고 복사만 한다
            if field == .other || field == .multiline {
                copyInstead(fallback, username: part == .username, reason: "입력칸이 아니라서")
                return
            }
            var steps: [Step]
            switch part {
            case .username:
                steps = [.paste(account.username)]
            case .password:
                steps = [.paste(password ?? "")]
            case .auto:
                if field == .secure || account.username.isEmpty {
                    steps = [.password(password ?? "")]
                } else {
                    steps = [.paste(account.username), .key(kVK_Tab), .password(password ?? "")]
                }
            }
            if account.submit, part != .username { steps.append(.submit) }
            pendingRestore = pendingRestore ?? snapshot()
            perform(steps[...], generation: run, pid: target.processIdentifier, secureConfirmed: field == .secure)
        }
    }

    /// 바로 넣지 못할 때. 비밀번호는 30초 뒤 지운다.
    private static func copyInstead(_ text: String, username: Bool, reason: String?) {
        copy(text, clearAfter: username ? nil : 30)
        let what = username ? "아이디를 복사했습니다" : "비밀번호를 복사했습니다. 30초 뒤 지웁니다"
        AccountCapture.notify(reason.map { "\($0) \(what)" } ?? what, symbol: "doc.on.doc.fill")
    }

    // MARK: 복사

    /// 숨김 표시를 붙여 복사하고, 그대로 남아 있으면 정한 시간 뒤 지운다.
    static func copy(_ text: String, clearAfter seconds: TimeInterval?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setData(Data(), forType: transient)
        let change = pasteboard.changeCount
        AppController.shared.monitor.suppressUntilChangeCount = change
        guard let seconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard NSPasteboard.general.changeCount == change else { return }
            NSPasteboard.general.clearContents()
            AppController.shared.monitor.suppressUntilChangeCount = NSPasteboard.general.changeCount
        }
    }

    /// 앱이 실제로 읽어 갈 때 값을 내준다. 읽었다는 것을 알아야 다음 값으로 바꿔도 앞 칸에 뒤 값이 들어가지 않는다.
    private static func writeLazily(_ text: String, onRead: @escaping @MainActor () -> Void) {
        let pasteboard = NSPasteboard.general
        let provider = PasteReader(text: text, onRead: onRead)
        reader = provider
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: concealed)
        item.setData(Data(), forType: transient)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        lastWritten = pasteboard.changeCount
        AppController.shared.monitor.suppressUntilChangeCount = lastWritten
    }

    // MARK: 순서대로 넣기

    private enum Step {
        case paste(String)
        /// 지금 초점이 비밀번호 칸이 아닌 것이 분명하면 넣지 않는다 (Tab이 OTP·검색 칸으로 갔을 때).
        case password(String)
        case key(Int)
        /// 비밀번호 칸을 확인하고 넣었을 때만 ↩.
        case submit
    }

    private static func perform(_ steps: ArraySlice<Step>, generation run: Int, pid: pid_t, secureConfirmed: Bool) {
        guard run == generation else { return }
        guard let step = steps.first else { finish(run); return }
        let rest = steps.dropFirst()
        func next(after delay: TimeInterval, secure: Bool = secureConfirmed) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                perform(rest, generation: run, pid: pid, secureConfirmed: secure)
            }
        }
        switch step {
        case .paste(let text):
            clearThenPaste(text, field: focusedField(pid: pid), generation: run) { next(after: 0.08) }
        case .password(let text):
            let field = focusedField(pid: pid)
            if field == .text || field == .multiline || field == .other {
                finish(run)
                copyInstead(text, username: false, reason: "비밀번호 칸을 찾지 못해")
                return
            }
            clearThenPaste(text, field: field, generation: run) {
                // 붙여넣기를 막는 사이트는 값이 그대로다. 길이가 다르면 멈추고 알린다 (↩로 틀린 비밀번호를 보내지 않는다)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard run == generation else { return }
                    let length = focusedLength(pid: pid)
                    if field == .secure, let length, length != text.count {
                        finish(run)
                        lastWarning = "붙여넣기 막힘"
                        AccountCapture.notify("이 사이트는 비밀번호 붙여넣기를 막습니다. 비밀번호는 직접 쳐 주세요", symbol: "exclamationmark.triangle.fill")
                        return
                    }
                    next(after: 0, secure: field == .secure)
                }
            }
        case .key(let code):
            press(code, flags: [])
            // 웹 입력칸은 Tab 뒤 다음 칸에 초점이 옮겨 가기까지 잠깐 걸린다
            next(after: 0.2)
        case .submit:
            if secureConfirmed { press(kVK_Return, flags: []) }
            next(after: 0.05)
        }
    }

    /// 칸에 이미 글이 있으면 지우고 붙인다. ⌘A로 칸 안을 모두 고른 뒤 붙이면 고른 글이 바뀐다.
    /// 한 줄 입력칸과 비밀번호 칸에서만 한다. 여러 줄 편집기나 알 수 없는 곳에서 ⌘A를 누르면 문서 전체가 바뀔 수 있다.
    private static func clearThenPaste(_ text: String, field: FieldKind, generation run: Int, then: @escaping @MainActor () -> Void) {
        guard field == .text || field == .secure else {
            paste(text, generation: run, then: then)
            return
        }
        press(kVK_ANSI_A, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard run == generation else { return }
            paste(text, generation: run, then: then)
        }
    }

    /// 붙이고 앱이 읽어 가기를 기다린다. 1.5초 안에 읽지 않으면 멈춘다. 늦게 읽으면 다음 값이 들어갈 수 있다.
    private static func paste(_ text: String, generation run: Int, then: @escaping @MainActor () -> Void) {
        var settled = false
        writeLazily(text) {
            guard !settled, run == generation else { return }
            settled = true
            then()
        }
        press(kVK_ANSI_V, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !settled, run == generation else { return }
            settled = true
            finish(run)
            // 사파리는 붙여넣기를 막는 칸이면 클립보드를 아예 읽지 않는다
            lastWarning = "붙여넣기 막힘"
            AccountCapture.notify("이 칸이 붙여넣기를 받지 않아 멈췄습니다. 직접 쳐 주세요", symbol: "exclamationmark.triangle.fill")
        }
    }

    private static func press(_ code: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func waitForFrontmost(_ app: NSRunningApplication, attempts: Int, failed: @escaping @MainActor () -> Void,
                                         then next: @escaping @MainActor () -> Void) {
        guard attempts > 0, !app.isTerminated else { failed(); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { next() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            waitForFrontmost(app, attempts: attempts - 1, failed: failed, then: next)
        }
    }

    // MARK: 클립보드 되돌리기

    private static func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { data[type] = item.data(forType: type) }
            return data
        }
    }

    /// 끝나거나 멈추면 늘 부른다. 비밀번호를 클립보드에 남기지 않는다.
    private static func finish(_ run: Int) {
        guard run == generation else { return }
        reader = nil
        guard let saved = pendingRestore else { return }
        pendingRestore = nil
        let pasteboard = NSPasteboard.general
        // 그새 사람이 새로 복사했으면 그대로 둔다
        guard lastWritten < 0 || pasteboard.changeCount == lastWritten else { return }
        pasteboard.clearContents()
        // 원래 클립보드가 숨김 표시가 붙은 값(복사해 둔 비밀번호)이면 되살리지 않고 비워 둔다
        let secret = saved.contains { $0.keys.contains(concealed) }
        if !secret {
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        // 되돌린 것은 새로 복사한 것이 아니다
        AppController.shared.monitor.suppressUntilChangeCount = pasteboard.changeCount
    }

    // MARK: 손쉬운 사용으로 본 앞 창

    /// text는 한 줄 입력칸, multiline은 여러 줄 편집기(메모, 노션 본문).
    enum FieldKind { case secure, text, multiline, other, unknown }

    /// 초점이 있는 칸. 크롬·일렉트론 앱은 손쉬운 사용 트리를 켜 달라고 해야 웹 입력칸을 알려 준다.
    static func focusedField(pid: pid_t) -> FieldKind {
        guard AXIsProcessTrusted() else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        // 브라우저 주소창도 글자 칸이다. 주소창에 아이디를 넣으면 검색 제안으로 밖에 나간다. 웹 페이지 안의 칸만 받는다
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        if AccountContext.browsers.contains(bundleID), !insideWebPage(element) { return .other }
        if (subrole as? String) == kAXSecureTextFieldSubrole { return .secure }
        guard let role = role as? String else { return .unknown }
        if role == kAXTextAreaRole { return .multiline }
        let inputs: Set<String> = [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"]
        return inputs.contains(role) ? .text : .other
    }

    private static func insideWebPage(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return false }
            if string(node, kAXRoleAttribute) == "AXWebArea" { return true }
            current = Self.element(node, kAXParentAttribute)
        }
        return false
    }

    /// 초점 칸 글자 수. 비밀번호 칸은 가린 글자(•)로 돌려주어도 길이는 맞다. 읽지 못하면 nil.
    static func focusedLength(pid: pid_t) -> Int? {
        let app = AXUIElementCreateApplication(pid)
        guard let element = element(app, kAXFocusedUIElementAttribute) else { return nil }
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success, let n = count as? Int {
            return n
        }
        return string(element, kAXValueAttribute)?.count
    }

    /// 마지막 넣기에서 생긴 문제. 점검(--clip-browser-check)이 본다.
    static var lastWarning: String?

    /// 띠를 연 곳. 브라우저면 창 제목에 사이트 이름이 들어 있다.
    static func context() -> AccountContext? {
        guard let target = AppController.shared.pasteTarget, target != .current else { return nil }
        var context = AccountContext(bundleID: target.bundleIdentifier, windowTitle: "")
        guard AXIsProcessTrusted() else { return context }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let window = element(app, kAXFocusedWindowAttribute) {
            context.windowTitle = string(window, kAXTitleAttribute) ?? ""
            if AccountContext.browsers.contains(target.bundleIdentifier ?? "") {
                context.pageHost = pageURL(window)?.host.map { $0.lowercased().hasPrefix("www.") ? String($0.dropFirst(4)).lowercased() : $0.lowercased() }
            }
        }
        return context
    }

    /// 창 안 웹 페이지 영역(AXWebArea)의 주소. 초점 칸에서 위로 올라가 보고, 없으면 창 아래로 몇 단 내려가 찾는다.
    static func pageURL(_ window: AXUIElement) -> URL? {
        func url(of element: AXUIElement) -> URL? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success else { return nil }
            return value as? URL
        }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == "AXWebArea", let found = url(of: element) { return found }
            guard depth < 8 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue += list.map { ($0, depth + 1) }
            }
        }
        return nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }
}

/// 설정에서 켜면 계정을 쓰기 전에 Touch ID(또는 Mac 암호)로 확인한다. 한 번 확인하면 5분 동안은 다시 묻지 않는다.
@MainActor
enum AccountLock {
    private static var unlockedUntil = Date.distantPast
    private static let grace: TimeInterval = 300

    static func unlock(reason: String, then run: @escaping @MainActor () -> Void) {
        guard AccountPrefs.requireAuth, Date() > unlockedUntil else { run(); return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { run(); return }
        // 확인 창이 떠 있는 동안 띠가 닫히지 않게 한다
        AppController.shared.suppressAutoHide = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppController.shared.suppressAutoHide = false
                    guard ok else { return }
                    unlockedUntil = Date().addingTimeInterval(grace)
                    run()
                }
            }
        }
    }
}

/// 앱이 붙여넣기로 값을 읽어 갈 때 내주고 알린다.
private final class PasteReader: NSObject, NSPasteboardItemDataProvider {
    let text: String
    let onRead: @MainActor () -> Void

    init(text: String, onRead: @escaping @MainActor () -> Void) {
        self.text = text
        self.onRead = onRead
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        let done = onRead
        DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
    }
}
