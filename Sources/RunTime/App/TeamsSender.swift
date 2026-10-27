import AppKit
import ApplicationServices
import WorkLogCore

/// 팀즈로 보낼 곳. 나에게는 설정 없이 나와의 채팅으로, 보고 채팅은 링크나 웹훅을 넣은 곳으로.
enum TeamsTarget: String, CaseIterable {
    case me, chat

    var account: String { self == .me ? "teams-webhook-me" : "teams-webhook" }
    var name: String { self == .me ? "나에게" : "보고 채팅" }
}

/// 웹훅 없이 보내는 길: 보고서를 서식 있는 글로 복사하고, 그 채팅을 팀즈 앱에서 연 뒤 (허용했으면) 붙여 넣고 보낸다.
/// 팀즈가 PWA(크롬·엣지 앱)면 그 창에서, 데스크톱 앱이면 msteams:로, 둘 다 없으면 브라우저로 연다.
/// 붙여 넣기와 보내기는 PWA에서만 한다. 손쉬운 사용 API로 입력 칸을 찾아 초점을 주고, 들어갔는지·비었는지를 읽어 확인한다.
enum TeamsOpener {
    enum Result {
        /// 복사하고 열기만 했다. 사람이 ⌘V, Enter. 이유가 있으면 함께.
        case copied(String?)
        /// 입력 칸에 넣었지만 보내지 않았다.
        case pasted(String?)
        case sent
        case failed(String)
    }

    /// `key`는 보낼 곳 이름. 그 채팅의 창 제목을 기억해 두고 다음에 맞는 채팅인지 볼 때 쓴다.
    /// `returnBack`이면 다 보낸 뒤 보내기 전에 쓰던 앱으로 돌아간다. 팀즈는 1초 남짓 앞에 나왔다 들어간다.
    static func deliver(_ report: String, title: String, link: String, key: String, autoPaste: Bool, autoSend: Bool,
                        returnBack: Bool = false, done: @escaping (Result) -> Void) {
        copy(report, title: title)
        let previous = NSWorkspace.shared.frontmostApplication
        let pwa = teamsPWA()
        let automate = autoPaste && pwa != nil && AXIsProcessTrusted()
        let firstLine = TeamsLink.plain(report, title: title).components(separatedBy: "\n").first ?? title
        DispatchQueue.global(qos: .userInitiated).async {
            // 꺼져 있는 PWA에 링크를 주면 크롬이 링크 대신 첫 화면이나 일반 창을 연다.
            // 먼저 앱을 띄워 팀즈가 다 뜨기를 기다린 뒤 링크로 채팅을 바꾼다
            if let pwa, !isRunning(pwa.bundle) { launch(pwa, readable: automate) }
            // 열기 전 화면(창 제목)을 적어 두어, 링크의 채팅으로 바뀌었는지 알아본다.
            // 크롬은 손쉬운 사용을 처음 켠 직후 웹 트리를 늦게 내놓아 몇 번 다시 읽는다
            var before: Snapshot?
            if automate, let pwa {
                for _ in 0..<10 where before == nil {
                    before = snapshot(bundle: pwa.bundle)
                    if before == nil { Thread.sleep(forTimeInterval: 0.1) }
                }
            }
            let opened = DispatchQueue.main.sync { open(link) != nil }
            let result: Result
            if !opened { result = .failed("팀즈를 열지 못했습니다. 보고서는 복사해 두었습니다") }
            else if !autoPaste { result = .copied(nil) }
            else if pwa == nil { result = .copied("팀즈 앱(PWA)이 아니라 붙여 넣기는 직접 하세요") }
            else if !automate { result = .copied("손쉬운 사용 권한이 없어 붙여 넣기는 직접 하세요") }
            else if before == nil { result = .copied("팀즈 화면을 읽지 못해 붙여 넣지 않았습니다") }
            else { result = paste(into: pwa!.bundle, before: before, key: key, link: link, check: firstLine, autoSend: autoSend) }
            DispatchQueue.main.async {
                // 보내기까지 끝났을 때만 돌아간다. 붙여 넣기만 했으면 Enter를 누르게 팀즈를 앞에 둔다
                if returnBack, case .sent = result, let pwa { goBack(to: previous, from: pwa.bundle) }
                done(result)
            }
        }
    }

    private static func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// PWA를 켜고 팀즈 화면(채팅 이름이 든 창 제목)이 뜰 때까지 기다린다. 읽을 수 없으면 넉넉히 기다린다.
    private static func launch(_ pwa: PWA, readable: Bool) {
        DispatchQueue.main.sync {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: pwa.url, configuration: configuration)
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 25 {
            Thread.sleep(forTimeInterval: 0.3)
            guard isRunning(pwa.bundle) else { continue }
            if !readable {
                if Date().timeIntervalSince(start) > 6 { return }
                continue
            }
            if let title = snapshot(bundle: pwa.bundle)?.title, chatName(normalized(title)) != nil { return }
        }
    }

    /// 보내기 전에 쓰던 앱으로 돌아간다. 다른 앱이 앞에 있을 때 `activate()`는 macOS가 무시해서
    /// LaunchServices로 다시 열고(독을 누른 것과 같다), RunTime이었으면 스스로 앞에 나온다.
    /// 그래도 팀즈가 앞에 남아 있으면 팀즈를 숨겨 뒤의 앱이 앞에 오게 한다.
    private static func goBack(to previous: NSRunningApplication?, from teams: String) {
        if let previous, !previous.isTerminated, previous.bundleIdentifier != teams {
            if previous.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                NSApp.activate(ignoringOtherApps: true)
            } else if let url = previous.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == teams else { return }
            NSRunningApplication.runningApplications(withBundleIdentifier: teams).first?.hide()
        }
    }

    /// 백그라운드에서 돈다. 손쉬운 사용 호출이 수백 ms씩 걸릴 수 있어서.
    private static func paste(into bundle: String, before: Snapshot?, key: String, link: String, check: String,
                              autoSend: Bool) -> Result {
        // 1. 팀즈 창이 앞에 나오고 링크의 채팅이 그려질 때까지 (최대 12초).
        // 입력 칸은 채팅을 바꿔도 같은 요소라 창 제목(`채팅 | 유민기 사원(나) | Microsoft Teams`)으로 어느 채팅인지 본다.
        // 나와의 채팅은 이름 뒤 (나)로, 그 밖의 채팅은 지난번 보낸 창 제목으로 알아본다 (= 확인된 채팅).
        // 알아볼 수 있는 채팅이면 그 제목이 뜰 때까지만 기다리고, 다른 채팅이 떠 있으면 손대지 않는다.
        // 처음 보내는 채팅은 제목이 바뀌어 0.36초 동안 그대로면 붙여 넣되, 맞는지 사람이 보게 보내지는 않는다
        let saved = UserDefaults.standard.string(forKey: "workLog.teamsTitle.\(key)")
        let isNotes = TeamsLink.conversationID(link) == "48:notes"
        func confirmed(_ title: String) -> Bool {
            (isNotes && (title.contains("(나)") || title.contains("(You)"))) || (saved != nil && saved == title)
        }
        let beforeTitle = before.map { normalized($0.title) }
        let identifiable = isNotes || saved != nil
        var now: Snapshot?
        var title = ""
        var lastTitle = ""
        var steady = 0
        var sure = false
        let start = Date()
        while Date().timeIntervalSince(start) < 12 {
            Thread.sleep(forTimeInterval: 0.12)
            guard frontmost() == bundle, let current = snapshot(bundle: bundle), current.composer != nil else { continue }
            now = current
            title = normalized(current.title)
            steady = title == lastTitle ? steady + 1 : 1
            lastTitle = title
            // 채팅 이름이 든 제목만 본다 (넘어가는 동안 `채팅 | Microsoft Teams` 같은 중간 제목이 잠깐 뜬다)
            guard chatName(title) != nil else { continue }
            if identifiable {
                if confirmed(title), steady >= 2 { sure = true; break }
                continue
            }
            if title != beforeTitle, steady >= 3 { sure = true; break }
            // 바뀌지 않으면 3초까지는 바뀌기를 기다린다
            if Date().timeIntervalSince(start) > 3, title == beforeTitle { break }
        }
        guard let now, let composer = now.composer else { return .copied("팀즈 입력 칸을 찾지 못했습니다") }
        // 다른 채팅에 붙여 넣지 않게, 맞는 채팅인지 모르겠으면 아예 손대지 않는다
        guard sure else {
            return .copied(identifiable ? "‘\(chatName(title) ?? title)’ 채팅이 떠 있어 붙여 넣지 않았습니다"
                                        : "링크의 채팅으로 바뀌었는지 알 수 없어 붙여 넣지 않았습니다")
        }
        let known = confirmed(title)

        // 2. 입력 칸에 초점을 주고 붙여 넣는다. 쓰다 만 글이 있으면 그 뒤에 붙여 보내지 않는다
        let draft = !isEmpty(composer)
        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.08)
        guard frontmost() == bundle else { return .copied("팀즈가 뒤로 가서 붙여 넣지 않았습니다") }
        press(9, flags: .maskCommand) // V
        var pasted = false
        for _ in 0..<25 where !pasted {
            Thread.sleep(forTimeInterval: 0.08)
            pasted = value(composer).contains(check)
        }
        guard pasted else { return .copied("입력 칸에 붙지 않았습니다") }

        // 3. 보내고, 입력 칸이 비었는지로 나갔는지 본다
        guard autoSend else { return .pasted(nil) }
        guard !draft else { return .pasted("쓰다 만 글이 있어 보내지 않았습니다") }
        guard known else {
            // 이 채팅을 기억해 두고 다음부터 바로 보낸다. 잘못 고른 채팅이면 설정에서 지우면 잊는다
            UserDefaults.standard.set(title, forKey: "workLog.teamsTitle.\(key)")
            return .pasted("처음 보내는 채팅이라 붙여만 넣었습니다. ‘\(chatName(title) ?? title)’이 맞으면 Enter를 누르세요. 다음부터는 바로 보냅니다")
        }
        // 그 사이 팀즈 안 다른 곳을 눌렀으면 Enter가 엉뚱한 데 가지 않게 멈춘다
        guard frontmost() == bundle, attribute(composer, kAXFocusedAttribute) as? Bool == true
        else { return .pasted("입력 칸에서 초점이 옮겨져 보내지 않았습니다") }
        press(36, flags: []) // Return
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.08)
            if isEmpty(composer) { return .sent }
        }
        return .pasted("Enter를 눌렀지만 입력 칸이 비지 않았습니다. 팀즈에서 확인하세요")
    }

    // MARK: 손쉬운 사용

    struct Snapshot {
        /// 웹 문서 제목 (`채팅 | 유민기 사원(나) | Microsoft Teams`)
        let title: String
        let composer: AXUIElement?
    }

    private static func snapshot(bundle: String) -> Snapshot? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // 크롬은 화면 읽기 프로그램이 없으면 웹 내용을 손쉬운 사용 트리에 내놓지 않는다
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let window = (attribute(element, kAXFocusedWindowAttribute) as! AXUIElement?)
            ?? (attribute(element, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window, let web = find(in: window, depth: 14, where: { role($0) == "AXWebArea" }) else { return nil }
        let composer = search(web) ?? find(in: web, depth: 60) { element in
            guard role(element) == "AXTextArea" else { return false }
            let id = attribute(element, "AXDOMIdentifier") as? String ?? ""
            return id.hasPrefix("new-message") || (attribute(element, kAXDescriptionAttribute) as? String ?? "").contains("메시지")
                || (attribute(element, kAXDescriptionAttribute) as? String ?? "").localizedCaseInsensitiveContains("message")
        }
        return Snapshot(title: attribute(web, kAXTitleAttribute) as? String ?? "", composer: composer)
    }

    /// 안 읽은 수(`(3) 채팅 | …`)를 뗀 창 제목.
    static func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { text.removeSubrange(range) }
        return text
    }

    /// `채팅 | UX Lab-Work Report | Microsoft Teams` → `UX Lab-Work Report`. 채팅 이름이 없는 제목이면 nil.
    static func chatName(_ title: String) -> String? {
        let parts = title.components(separatedBy: " | ")
        return parts.count >= 3 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
    }

    /// 크롬이 내놓는 검색 API로 입력 칸을 찾는다. 대화가 길어도 트리를 훑지 않아 1ms 안쪽이다.
    private static func search(_ web: AXUIElement) -> AXUIElement? {
        let predicate: [String: Any] = ["AXSearchKey": "AXTextFieldSearchKey", "AXResultsLimit": 10,
                                        "AXDirection": "AXDirectionNext", "AXImmediateDescendantsOnly": false, "AXVisibleOnly": false]
        var result: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString,
                                                         predicate as CFDictionary, &result) == .success else { return nil }
        return (result as? [AXUIElement])?.first { (attribute($0, "AXDOMIdentifier") as? String ?? "").hasPrefix("new-message") }
    }

    /// 비어 있으면 자리 표시 글(`메시지를 입력하세요.`)이 값으로 읽힌다.
    private static func isEmpty(_ composer: AXUIElement) -> Bool {
        let text = value(composer).trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = (attribute(composer, kAXDescriptionAttribute) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == placeholder
    }

    private static func value(_ element: AXUIElement) -> String { attribute(element, kAXValueAttribute) as? String ?? "" }
    private static func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "" }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func find(in element: AXUIElement, depth: Int, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) { return element }
        guard depth > 0 else { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = find(in: child, depth: depth - 1, where: match) { return found }
        }
        return nil
    }

    private static func frontmost() -> String? {
        if Thread.isMainThread { return NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        return DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    static func copy(_ report: String, title: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(TeamsLink.html(report, title: title), forType: .html)
        pasteboard.setString(TeamsLink.plain(report, title: title), forType: .string)
    }

    /// 연 앱의 번들 ID (앞으로 나왔는지 볼 때 쓴다).
    @discardableResult
    static func open(_ link: String) -> String? {
        guard let url = URL(string: link) else { return nil }
        if let pwa = teamsPWA(), let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pwa.browser) {
            let process = Process()
            process.executableURL = browser.appendingPathComponent("Contents/MacOS")
                .appendingPathComponent((Bundle(url: browser)?.executableURL?.lastPathComponent) ?? "Google Chrome")
            // 앱 창(PWA)을 그 링크로 연다. 이미 떠 있으면 그 창에서 채팅만 바뀐다
            process.arguments = ["--app-id=\(pwa.id)", "--app-launch-url-for-shortcuts-menu-item=\(link)"]
            if (try? process.run()) != nil { return pwa.bundle }
        }
        if let app = TeamsLink.appURL(link), let handler = NSWorkspace.shared.urlForApplication(toOpen: app) {
            NSWorkspace.shared.open(app)
            return Bundle(url: handler)?.bundleIdentifier
        }
        return NSWorkspace.shared.open(url) ? NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier } : nil
    }

    /// 크롬·엣지로 설치한 팀즈 앱. Info.plist에 앱 ID와 그 앱을 띄우는 브라우저가 적혀 있다.
    typealias PWA = (id: String, browser: String, bundle: String, url: URL)

    static func teamsPWA() -> PWA? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ["Applications/Chrome Apps.localized", "Applications/Edge Apps.localized", "Applications/Chromium Apps.localized"]
        for folder in folders {
            let dir = home.appendingPathComponent(folder)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".app") {
                guard let info = NSDictionary(contentsOf: dir.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")),
                      let start = info["CrAppModeShortcutURL"] as? String, let host = URL(string: start)?.host?.lowercased(),
                      host.hasPrefix("teams."), let id = info["CrAppModeShortcutID"] as? String,
                      let browser = info["CrBundleIdentifier"] as? String, let bundle = info["CFBundleIdentifier"] as? String
                else { continue }
                return (id, browser, bundle, dir.appendingPathComponent(name))
            }
        }
        return nil
    }

    /// 손쉬운 사용 권한을 묻는다 (시스템 설정 창이 뜬다).
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func press(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
