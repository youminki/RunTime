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

        let board = store.addPinboard(name: "점검 보드")
        if let item = store.history.first { store.saveToPinboard(item, boardID: board.id) }
        check(store.pinboards.first { $0.id == board.id }?.items.count == 1, "보드에 담기")
        store.deletePinboard(board.id)

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

    private static func copy(_ write: (NSPasteboard) -> Void) {
        NSPasteboard.general.clearContents()
        write(NSPasteboard.general)
        // 감시는 0.4초마다 changeCount를 본다
        wait(0.9)
    }

    private static func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
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
