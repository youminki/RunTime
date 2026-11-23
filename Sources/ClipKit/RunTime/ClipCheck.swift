import AppKit

/// 클립보드 기록 점검 (`--clip-check`). 실제 시스템 클립보드에 복사해 기록에 잡히는지, 띠가 뜨는지 본다.
/// 부르는 쪽이 RUNTIME_CLIP_DEFAULTS·RUNTIME_CLIP_FOLDER로 따로 둔 저장소를 정한다. 끝나면 클립보드를 되돌린다.
@MainActor
public enum ClipCheck {
    public struct Line {
        public let ok: Bool
        public let name: String
        public let detail: String
    }

    public static func run(shots: URL?) -> [Line] {
        var lines: [Line] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { lines.append(Line(ok: ok, name: name, detail: detail)) }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        defer { restore(saved, to: pasteboard) }

        let store = ClipboardStore.shared
        store.clearHistory()
        ClipRuntime.start()
        check(ClipRuntime.running && HotKeyCenter.shared.isRegistered, "켜기", "단축키 \(Settings.shared.hotkeyDisplay) 등록")

        copy { $0.setString("RunTime 클립 점검 hello", forType: .string) }
        let first = store.history.first
        check(first?.plainText == "RunTime 클립 점검 hello", "텍스트 기록", first?.plainText ?? "기록 없음")
        check(first?.type == .text, "종류", first.map { "\($0.type)" } ?? "")
        // 기록 파일은 뒤 큐에서 쓴다. 0.4초 모았다가 쓰므로 조금 기다린다
        wait(0.6)
        let file = (try? String(contentsOf: store.dataDirectory.appendingPathComponent("store.json"), encoding: .utf8)) ?? ""
        check(file.contains("RunTime 클립 점검 hello"), "기록 파일 저장", "\(file.utf8.count)바이트")

        copy {
            let rich = NSAttributedString(string: "굵은 글씨", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            $0.setData(try? rich.data(from: NSRange(location: 0, length: rich.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
            $0.setString(rich.string, forType: .string)
        }
        check(store.history.first?.type == .richText, "서식 있는 텍스트", store.history.first.map { "\($0.type)" } ?? "")

        let before = store.history.count
        copy {
            $0.setString("secret-password", forType: .string)
            $0.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        check(store.history.count == before, "숨김 항목 건너뜀", "기록 \(before) → \(store.history.count)")

        store.searchText = "ㅋㄹ ㅈㄱ"
        check(store.visibleItems.first?.plainText == "RunTime 클립 점검 hello", "초성 검색", "\(store.visibleItems.count)개")
        store.searchText = ""

        if let item = store.history.first {
            Pinned.toggle([item])
            check(Pinned.contains(item), "고정")
            Pinned.toggle([item])
            check(!Pinned.contains(item) && store.history.contains { $0.id == item.id }, "고정 풀기", "기록은 그대로")
        }

        // 로그인 정보를 복사하면 기록에 남지 않고 계정으로 옮겨 간다 (비밀번호는 메모리에만)
        ClipRuntime.secrets = .memory()
        let accounts = AccountStore.shared
        let countBefore = store.history.count
        copy { $0.setString("사이트: check.example.com\n아이디: runtime-check\n비밀번호: Chk!2345abc", forType: .string) }
        let captured = accounts.accounts.first { $0.username == "runtime-check" }
        check(captured != nil && store.history.count == countBefore, "로그인 정보 자동 저장", captured.map { "\($0.title) · 기록 \(countBefore) → \(store.history.count)" } ?? "계정 없음")
        check(captured.flatMap(accounts.password(for:)) == "Chk!2345abc", "비밀번호는 기록 밖에", "")
        if let captured { accounts.delete(captured.id) }

        // 자동 저장 알림의 "기록으로 되돌리기": 계정을 빼고 클립을 기록에 되살린다
        copy { $0.setString("아이디: undo-check\n비밀번호: Und0!check1", forType: .string) }
        wait(0.4)
        let toast = CaptureUndoToast.shared
        let undone = accounts.accounts.first { $0.username == "undo-check" }
        if toast.isShown, let panel = toast.window, let host = panel.contentView, let frame = toast.undoFrame {
            let point = NSPoint(x: frame.midX, y: host.bounds.height - frame.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            wait(0.4)
        }
        let restored = store.history.first?.plainText?.contains("undo-check") == true
        check(undone != nil && !accounts.accounts.contains { $0.username == "undo-check" } && restored && !toast.isShown,
              "자동 저장 되돌리기", restored ? "기록에 되살림" : "되살리지 못함")
        store.removeFromHistory { $0.plainText?.contains("undo-check") == true }
        for line in editorChecks() { check(line.ok, line.name, line.detail) }

        // 터미널에서 띄운 점검은 앞으로 나오지 못해 띠가 키 창이 되지 않는다. 바깥 누르면 닫기가 바로 닫지 않게 끈다
        Settings.shared.hideOnClickOutside = false
        AppController.shared.showBar()
        wait(0.8)
        let panel = NSApp.windows.first { $0 is BarPanel && $0.isVisible }
        let screen = panel?.screen?.visibleFrame ?? .zero
        check(panel != nil, "띠 열기", panel.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) y=\(Int($0.frame.minY))" } ?? "창 없음")
        if let panel {
            check(abs(panel.frame.minY - screen.minY) < 2, "띠가 화면 아래에 붙음", "화면 아래 \(Int(screen.minY))")
            if let shots { save(panel, to: shots.appendingPathComponent("clip-bar.png")) }
        }
        AppController.shared.hideBar()
        wait(0.4)
        check(!(panel?.isVisible ?? false), "띠 닫기")

        ClipRuntime.stop()
        check(!HotKeyCenter.shared.isRegistered, "끄면 단축키를 놓음")
        copy { $0.setString("꺼진 뒤 복사", forType: .string) }
        check(store.history.first?.plainText != "꺼진 뒤 복사", "끄면 기록하지 않음")
        store.clearHistory()
        store.saveNow()
        return lines
    }

    /// 계정 추가·수정 창. 안내·오류 줄이 생겨도 창 크기가 그대로인지, 단추를 보이는 자리에서 눌렀을 때 듣는지 본다.
    /// 누르기는 이 창에만 보내는 마우스 사건이라 실제 포인터는 움직이지 않는다.
    private static func editorChecks() -> [Line] {
        var lines: [Line] = []
        for existing in [false, true] {
            let name = existing ? "계정 수정 창" : "계정 추가 창"
            let account = Account(title: existing ? "GitHub" : "", username: existing ? "kim" : "", site: existing ? "github.com" : "")
            let draft = AccountDraft(account: account, password: existing ? "Gh!secret99" : "", heading: name, existing: existing)
            var calls: [String] = []
            draft.onSave = { calls.append("저장") }
            draft.onCancel = { calls.append("취소") }
            if existing { draft.onDelete = { calls.append("삭제") } }
            let panel = AccountEditorPanel.make(draft)
            panel.center()
            panel.orderFrontRegardless()
            panel.makeKey()
            wait(0.5)
            let size = panel.frame.size
            var sizes: [CGSize] = []
            for change in [{ draft.password = "" }, { draft.password = "abc" }, { draft.error = "키체인에 저장하지 못했습니다. 키체인이 잠겨 있는지 확인해 주세요" },
                           { draft.error = nil }, { draft.reveal.toggle() }, { draft.reveal.toggle() }] {
                change()
                wait(0.15)
                sizes.append(panel.frame.size)
                if let host = panel.contentView { sizes.append(host.frame.size) }
            }
            let stable = sizes.allSatisfy { $0 == size }
            lines.append(Line(ok: stable, name: "\(name) 크기 고정", detail: "\(Int(size.width))×\(Int(size.height))"))

            draft.password = "abc"
            wait(0.15)
            var labels = ["새로 만들기", "비밀번호 보기", "취소", "저장", "닫기"]
            if existing { labels.insert("계정 삭제", at: 0) }
            var missed: [String] = []
            for label in labels {
                let before = (calls.count, draft.password, draft.reveal)
                guard click(label, in: panel, draft: draft) else { missed.append("\(label)(못 찾음)"); continue }
                wait(0.2)
                let heard: Bool
                switch label {
                case "새로 만들기": heard = draft.password != before.1 && draft.password.count == 16
                case "비밀번호 보기": heard = draft.reveal != before.2
                default: heard = calls.count == before.0 + 1
                }
                if !heard { missed.append(label) }
            }
            lines.append(Line(ok: missed.isEmpty, name: "\(name) 단추 누르기", detail: missed.isEmpty ? labels.joined(separator: ", ") : "안 들음: \(missed.joined(separator: ", "))"))
            // ↩ 저장, esc 취소
            var keyMissed: [String] = []
            for (key, code, expect) in [("↩", UInt16(36), "저장"), ("esc", UInt16(53), "취소")] {
                let count = calls.count
                let chars = code == 36 ? "\r" : "\u{1b}"
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: panel.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                        panel.sendEvent(event)
                    }
                }
                wait(0.2)
                if calls.count != count + 1 || calls.last != expect { keyMissed.append(key) }
            }
            lines.append(Line(ok: keyMissed.isEmpty, name: "\(name) ↩ 저장 · esc 취소", detail: keyMissed.isEmpty ? "" : "안 들음: \(keyMissed.joined(separator: ", "))"))
            let afterClicks = panel.frame.size == size
            lines.append(Line(ok: afterClicks, name: "\(name) 누른 뒤에도 크기 그대로", detail: ""))
            panel.orderOut(nil)
        }
        lines += presentedEditorChecks()
        return lines
    }

    /// 앱이 실제로 여는 길(AccountEditor.present)로 열어 취소·닫기·esc·저장·↩를 눌러 본다. 닫히는지, 저장되는지까지 본다.
    private static func presentedEditorChecks() -> [Line] {
        var lines: [Line] = []
        let accounts = AccountStore.shared
        let blank = Account(title: "", username: "")
        for (label, key) in [("취소", nil), ("닫기", nil), ("esc", UInt16(53))] as [(String, UInt16?)] {
            var result: Account?? = .none
            let panel = AccountEditor.present(draft: blank, password: "", heading: "계정 추가") { result = .some($0) }
            wait(0.5)
            if let key { press(key, in: panel) } else if let draft = panel.draft { _ = click(label, in: panel, draft: draft) }
            wait(0.4)
            let closed = !panel.isVisible && AccountEditor.openPanel == nil
            lines.append(Line(ok: closed && result == .some(nil), name: "계정 추가 창 \(label)로 닫기", detail: closed ? "" : "창이 그대로"))
            if !closed { panel.orderOut(nil) }
        }
        for (label, key) in [("저장", nil), ("↩", UInt16(36))] as [(String, UInt16?)] {
            var saved: Account?
            let panel = AccountEditor.present(draft: blank, password: "", heading: "계정 추가") { saved = $0 }
            wait(0.5)
            guard let draft = panel.draft else { continue }
            draft.title = "점검 \(label)"
            draft.username = "check-\(label)"
            let tint = draft.tint
            draft.password = "Chk!pw1234"
            wait(0.3)
            if let key { press(key, in: panel) } else { _ = click("저장", in: panel, draft: draft) }
            wait(0.5)
            let stored = saved.flatMap(accounts.password(for:)) == "Chk!pw1234"
            lines.append(Line(ok: stored && !panel.isVisible && draft.tint == tint, name: "계정 추가 창 \(label)로 저장",
                              detail: saved.map { "\($0.title) · 창 닫힘 \(!panel.isVisible)" } ?? "저장 안 됨"))
            if let saved { accounts.delete(saved.id) }
            if panel.isVisible { draft.onCancel() }
        }
        return lines
    }

    private static func press(_ code: UInt16, in panel: NSPanel) {
        let chars = code == 36 ? "\r" : "\u{1b}"
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// 단추가 그려진 자리 가운데를 누른다.
    private static func click(_ label: String, in panel: NSPanel, draft: AccountDraft) -> Bool {
        guard let host = panel.contentView, let frame = draft.buttonFrames[label], frame.width > 0 else { return false }
        // SwiftUI는 위가 0, 창은 아래가 0
        let point = NSPoint(x: frame.midX, y: host.bounds.height - frame.midY)
        // 창에 바로 넘기지 않고 앱 사건 줄에 넣는다. 그래야 창 끌기처럼 AppKit이 누르기를 먼저 가로채는 경우도 실제처럼 겪는다
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }

    private static func copy(_ write: (NSPasteboard) -> Void) {
        NSPasteboard.general.clearContents()
        write(NSPasteboard.general)
        // 감시는 0.4초마다 changeCount를 본다
        wait(0.9)
    }

    /// 앱 본 루프처럼 사건 줄을 비우며 기다린다. RunLoop만 돌리면 줄에 넣은 마우스·키 사건이 창에 가지 않는다.
    private static func wait(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
