import AppKit
import Carbon.HIToolbox

/// 계정 창과 계정 넣기를 실제 포인터·키 입력으로 확인한다 (`--clip-live-check`).
/// 포인터가 움직이고 키가 눌리므로 그동안 Mac을 만지지 않아야 한다. 저장소와 비밀번호는 따로 둔 것을 쓰고, 끝나면 클립보드를 되돌린다.
@MainActor
public enum ClipLiveCheck {
    public static func run() -> [ClipCheck.Line] {
        var lines: [ClipCheck.Line] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { lines.append(ClipCheck.Line(ok: ok, name: name, detail: detail)) }

        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) } }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }

        ClipRuntime.secrets = .memory()
        Settings.shared.pasteDirectly = true
        Settings.shared.hideOnClickOutside = false
        ClipRuntime.start()
        let accounts = AccountStore.shared
        for account in accounts.accounts { accounts.delete(account.id) }

        // 보통 앱처럼 편집 메뉴를 둔다. 글자 칸의 ⌘V·⌘A는 이 메뉴의 단축키로 동작한다
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(NSMenuItem())
        main.addItem(editItem)
        NSApp.mainMenu = main

        // 시험용 로그인 창: 아이디·비밀번호 칸에 예전 값이 들어 있다
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "RunTime 로그인 시험"
        window.isReleasedWhenClosed = false
        let user = NSTextField(frame: NSRect(x: 20, y: 90, width: 320, height: 24))
        let pass = NSSecureTextField(frame: NSRect(x: 20, y: 50, width: 320, height: 24))
        user.stringValue = "old-user"
        pass.stringValue = "old-pass"
        window.contentView?.addSubview(user)
        window.contentView?.addSubview(pass)
        user.nextKeyView = pass
        pass.nextKeyView = user
        // 다른 앱 창 뒤에 깔리면 실제 누르기가 그 앱에 간다
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        wait(0.4)
        // 실제로 눌러야 이 앱이 앞으로 온다 (터미널에서 띄운 앱은 스스로 앞으로 나오지 못한다)
        realClick(on: user, in: window)
        wait(0.4)
        check(NSApp.isActive && window.isKeyWindow, "시험 창 앞으로", "앱 활성 \(NSApp.isActive)")

        // 계정 창: 취소, 닫기, 글자 치기, 저장을 실제로 누른다
        AppController.shared.showBar()
        BarMode.shared.select(.accounts)
        wait(0.6)
        for label in ["취소", "닫기"] {
            var result: Account?? = .none
            let panel = AccountEditor.present(draft: Account(title: "", username: ""), password: "", heading: "계정 추가") { result = .some($0) }
            wait(0.6)
            realClick(label, in: panel)
            wait(0.5)
            check(!panel.isVisible && result == .some(nil), "계정 창 \(label) (실제 누르기)", panel.isVisible ? "창이 그대로" : "")
            if panel.isVisible { panel.draft?.onCancel() }
        }
        var created: Account?
        let panel = AccountEditor.present(draft: Account(title: "", username: ""), password: "", heading: "계정 추가") { created = $0 }
        wait(0.6)
        if let draft = panel.draft {
            realClick("이름", in: panel)
            wait(0.3)
            type("abc")
            wait(0.4)
            check(draft.title == "abc", "계정 창 글자 치기", "이름 칸: \(draft.title)")
            draft.title = "시험"
            draft.username = "new-user"
            draft.password = "New!pass99"
            wait(0.3)
            realClick("저장", in: panel)
            wait(0.6)
            check(created != nil && !panel.isVisible, "계정 창 저장 (실제 누르기)", created.map { "\($0.title) 저장" } ?? "저장 안 됨")
            if panel.isVisible { draft.onCancel() }
        }
        guard let account = created ?? accounts.accounts.first else {
            AppController.shared.hideBar()
            window.orderOut(nil)
            return lines
        }

        // 아이디 칸에 커서: 아이디 → Tab → 비밀번호, 예전 값은 지우고 넣는다
        pasteboard.clearContents()
        pasteboard.setString("원래 클립보드", forType: .string)
        AppController.shared.hideBar()
        wait(0.3)
        realClick(on: user, in: window)
        wait(0.3)
        AppController.shared.showBar()
        BarMode.shared.select(.accounts)
        wait(0.6)
        AccountFill.fill(account)
        wait(2.0)
        check(user.stringValue == "new-user" && pass.stringValue == "New!pass99", "아이디·비밀번호 넣기 (있던 글 지움)",
              "아이디 \(user.stringValue), 비밀번호 \(pass.stringValue == "New!pass99" ? "맞음" : "다름(\(pass.stringValue.count)자)")")
        check(pasteboard.string(forType: .string) == "원래 클립보드", "넣은 뒤 클립보드 되돌림", pasteboard.string(forType: .string) ?? "비어 있음")

        // 비밀번호 칸에 커서: 비밀번호만 바꾼다
        user.stringValue = "old-user"
        pass.stringValue = "old-pass"
        AppController.shared.hideBar()
        wait(0.3)
        realClick(on: pass, in: window)
        wait(0.3)
        AppController.shared.showBar()
        BarMode.shared.select(.accounts)
        wait(0.6)
        AccountFill.fill(account)
        wait(2.0)
        check(user.stringValue == "old-user" && pass.stringValue == "New!pass99", "비밀번호 칸이면 비밀번호만",
              "아이디 \(user.stringValue), 비밀번호 \(pass.stringValue == "New!pass99" ? "맞음" : "다름")")

        AppController.shared.hideBar()
        accounts.delete(account.id)
        window.orderOut(nil)
        ClipRuntime.stop()
        return lines
    }

    // MARK: 브라우저

    /// 브라우저 연습 로그인 페이지에 실제로 넣어 본다 (`--clip-browser-check <앱 번들 id> <주소>`).
    /// 페이지는 입력값과 제출 여부를 제목에 적는다 (U=아이디;P=비밀번호;S=제출;E=입력 사건 수). 창은 새로 열고 끝나면 닫는다.
    public static func runBrowser(bundleID: String, url: String) -> [ClipCheck.Line] {
        var lines: [ClipCheck.Line] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { lines.append(ClipCheck.Line(ok: ok, name: name, detail: detail)) }
        let chrome = bundleID != "com.apple.Safari"
        let appName = chrome ? "Google Chrome" : "Safari"
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) } }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }

        ClipRuntime.secrets = .memory()
        Settings.shared.pasteDirectly = true
        Settings.shared.hideOnClickOutside = false
        ClipRuntime.start()
        let accounts = AccountStore.shared
        for account in accounts.accounts { accounts.delete(account.id) }
        guard var account = accounts.save(title: "연습", username: "new-user", password: "New!pass99", site: "127.0.0.1") else { return lines }
        let decoy = accounts.save(title: "다른 곳", username: "decoy", password: "Decoy!pw11", site: "example.com")

        let make = chrome
            ? "tell application \"Google Chrome\"\nset w to make new window\nset URL of active tab of w to \"\(url)\"\nreturn id of w\nend tell"
            : "tell application \"Safari\"\nmake new document with properties {URL:\"\(url)\"}\nreturn id of front window\nend tell"
        guard let windowID = osascript(make)?.trimmingCharacters(in: .whitespacesAndNewlines), !windowID.isEmpty else {
            check(false, "\(appName) 새 창 열기", "AppleScript 실패")
            return lines
        }
        defer { _ = osascript("tell application \"\(appName)\" to close (window id \(windowID))") }
        wait(2.0)

        struct Case { let name: String; let query: String; let field: String; let submit: Bool }
        let cases = [
            Case(name: "아이디 칸에서 넣기", query: "", field: "user", submit: false),
            Case(name: "비밀번호 칸에서 넣기", query: "", field: "pass", submit: false),
            Case(name: "넣고 로그인까지", query: "", field: "user", submit: true),
            Case(name: "붙여넣기 막는 사이트", query: "?block=1", field: "user", submit: false),
            Case(name: "주소창에서는 넣지 않음", query: "", field: "address", submit: false),
        ]
        for item in cases {
            let target = url + item.query
            let navigate = chrome
                ? "tell application \"Google Chrome\" to set URL of active tab of (window id \(windowID)) to \"\(target)\""
                : "tell application \"Safari\" to set URL of current tab of (window id \(windowID)) to \"\(target)\""
            _ = osascript(navigate)
            _ = osascript("tell application \"\(appName)\" to activate")
            wait(1.5)
            account.submit = item.submit
            accounts.update(account, password: nil)
            // 같은 번들의 브라우저가 여럿 떠 있을 수 있다 (자동화용 크롬 등). 연습 페이지 창(제목이 U=로 시작)만 건드린다
            guard let page = practiceWindow(bundleID: bundleID), let fields = webFields(in: page.window) else {
                check(false, "\(appName) · \(item.name)", "입력칸을 찾지 못함 (손쉬운 사용 트리)")
                continue
            }
            guard let spot = item.field == "user" ? fields.user : (item.field == "pass" ? fields.pass : fields.address) else {
                check(false, "\(appName) · \(item.name)", "칸을 찾지 못함")
                continue
            }
            // 새 창이 막 열린 때는 누르기가 앱을 앞으로 올리기 전에 끝날 수 있다. 연습 창의 앱이 앞에 올 때까지 다시 누른다
            for _ in 0..<6 {
                realClick(atCG: spot)
                wait(0.5)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == page.pid { break }
            }
            pasteboard.clearContents()
            pasteboard.setString("원래 클립보드", forType: .string)
            AppController.shared.showBar()
            BarMode.shared.select(.accounts)
            wait(0.8)
            let first = BarMode.shared.visibleAccounts.first
            let matched = BarMode.shared.context?.matches(account) == true && decoy.map { BarMode.shared.context?.matches($0) == false } != false
            AccountFill.fill(account)
            wait(3.0)
            let state = pageState(page.window)
            let restored = pasteboard.string(forType: .string) == "원래 클립보드"
            let addressText = addressValue(page.window) ?? ""
            let warning = AccountFill.lastWarning.map { " · 알림: \($0)" } ?? ""
            let detail = "\(state.map { "아이디 \($0.user), 비밀번호 \($0.pass == "New!pass99" ? "새 값" : $0.pass), 제출 \($0.submitted)" } ?? "페이지 상태를 못 읽음") · 맞는 계정 \(matched && first?.id == account.id) · 클립보드 \(restored ? "되돌림" : "안 되돌림")\(warning)"
            let ok: Bool
            switch item.name {
            case "아이디 칸에서 넣기": ok = state?.user == "new-user" && state?.pass == "New!pass99" && state?.submitted == false
            case "비밀번호 칸에서 넣기": ok = state?.user == "old-user" && state?.pass == "New!pass99"
            case "넣고 로그인까지": ok = state?.user == "new-user" && state?.pass == "New!pass99" && state?.submitted == true
            case "주소창에서는 넣지 않음":
                // 주소창에 아이디가 들어가지 않고, 페이지도 그대로다 (비밀번호는 복사만 해 둔다)
                check(!addressText.contains("new-user") && state?.user == "old-user", "\(appName) · \(item.name)", "주소창: \(addressText.prefix(40))")
                AppController.shared.hideBar()
                wait(0.3)
                continue
            default: ok = state?.user == "new-user" && state?.pass != "New!pass99" && AccountFill.lastWarning == "붙여넣기 막힘"
            }
            check(ok && matched && first?.id == account.id && restored, "\(appName) · \(item.name)", detail)
            AppController.shared.hideBar()
            wait(0.3)
        }
        accounts.delete(account.id)
        if let decoy { accounts.delete(decoy.id) }
        ClipRuntime.stop()
        return lines
    }

    /// 주소창 글자.
    private static func addressValue(_ window: AXUIElement) -> String? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 1500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" { continue }
            if (role as? String) == kAXTextFieldRole {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                return value as? String
            }
            guard depth < 20 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue += list.map { ($0, depth + 1) }
            }
        }
        return nil
    }

    /// 연습 페이지 창. 브라우저 프로세스마다 창 제목을 보고 U=로 시작하는 창을 찾는다.
    private static func practiceWindow(bundleID: String) -> (pid: pid_t, window: AXUIElement)? {
        for _ in 0..<10 {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                var windows: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                      let list = windows as? [AXUIElement] else { continue }
                for window in list {
                    var title: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                    if (title as? String)?.hasPrefix("U=") == true { return (app.processIdentifier, window) }
                }
            }
            wait(0.3)
        }
        return nil
    }

    /// 페이지 제목에서 읽은 입력칸 값.
    private static func pageState(_ window: AXUIElement) -> (user: String, pass: String, submitted: Bool)? {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        guard let text = title as? String,
              let regex = try? NSRegularExpression(pattern: "U=(.*?);P=(.*?);S=(\\d)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let u = Range(match.range(at: 1), in: text), let p = Range(match.range(at: 2), in: text),
              let s = Range(match.range(at: 3), in: text) else { return nil }
        return (String(text[u]), String(text[p]), text[s] == "1")
    }

    /// 웹 페이지의 아이디 칸과 비밀번호 칸 가운데 (화면 위가 0인 좌표).
    private static func webFields(in window: AXUIElement) -> (user: CGPoint, pass: CGPoint, address: CGPoint?)? {
        var user: CGPoint?
        var pass: CGPoint?
        var address: CGPoint?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var inPage = false
        while !queue.isEmpty, visited < 3000, user == nil || pass == nil {
            let (element, depth) = queue.removeFirst()
            visited += 1
            var role: CFTypeRef?
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            // 주소창도 글자 칸이다. 웹 페이지 영역 안의 칸만 본다
            if !inPage, (role as? String) == "AXWebArea" {
                // 여기부터는 페이지 안만 본다
                inPage = true
                queue = []
            }
            if !inPage, address == nil, (role as? String) == kAXTextFieldRole, let center = center(of: element) {
                address = center
            }
            if inPage, (role as? String) == kAXTextFieldRole, let center = center(of: element) {
                if (subrole as? String) == kAXSecureTextFieldSubrole { pass = pass ?? center } else { user = user ?? center }
            }
            guard depth < 25 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue += list.map { ($0, depth + 1) }
            }
        }
        guard let user, let pass else { return nil }
        return (user, pass, address)
    }

    private static func center(of element: AXUIElement) -> CGPoint? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGPoint(x: point.x + extent.width / 2, y: point.y + extent.height / 2)
    }

    private static func osascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    // MARK: 실제 입력

    private static func realClick(on view: NSView, in window: NSWindow) {
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        realClick(at: NSPoint(x: rect.midX, y: rect.midY))
    }

    /// 계정 창의 단추나 칸 가운데를 실제로 누른다.
    private static func realClick(_ label: String, in panel: AccountEditorPanel) {
        guard let host = panel.contentView, let draft = panel.draft else { return }
        guard let frame = draft.buttonFrames[label] else { return }
        let inWindow = NSPoint(x: frame.midX, y: host.bounds.height - frame.midY)
        realClick(at: panel.convertPoint(toScreen: inWindow))
    }

    private static func realClick(at point: NSPoint) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        realClick(atCG: CGPoint(x: point.x, y: height - point.y))
    }

    /// 화면 위가 0인 좌표.
    private static func realClick(atCG location: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        wait(0.08)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
            wait(0.06)
        }
    }

    private static func type(_ text: String) {
        for char in text.utf16 {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                var unit = char
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                event?.post(tap: .cghidEventTap)
                wait(0.03)
            }
        }
    }

    private static func wait(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }
}
