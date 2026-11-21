import AppKit

/// 띠 화면 찍기 (`--clip-shots <폴더>`). 여러 종류의 클립을 넣고 기본·검색·거르기·보드·빈 결과 상태를 찍는다.
/// 부르는 쪽이 RUNTIME_CLIP_DEFAULTS·RUNTIME_CLIP_FOLDER로 따로 둔 저장소를 정한다.
@MainActor
public enum ClipShots {
    public static func run(to folder: URL) {
        let store = ClipboardStore.shared
        store.clearHistory()
        Settings.shared.hideOnClickOutside = false
        seed(store)
        ClipRuntime.start()

        shoot("clip-1-default", folder)
        store.moveSelection(by: 3)
        shoot("clip-2-selected-4th", folder)
        AppController.shared.hideBar()
        wait(0.4)

        store.searchText = "ㅇㅁ ㅇㅈ"
        shoot("clip-3-choseong-search", folder, reset: false)
        store.searchText = "없는 검색어"
        shoot("clip-4-no-match", folder, reset: false)
        store.searchText = ""
        store.typeFilter = .link
        shoot("clip-5-filter-link", folder, reset: false)
        store.typeFilter = nil

        let board = store.addPinboard(name: "자주 쓰는 것")
        for item in store.history.prefix(3) { store.saveToPinboard(item, boardID: board.id) }
        store.source = .pinboard(board.id)
        shoot("clip-6-pinboard", folder, reset: false)
        store.source = .history

        store.clearHistory()
        shoot("clip-7-empty", folder)
        ClipRuntime.stop()
    }

    private static func seed(_ store: ClipboardStore) {
        let now = Date()
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        var items: [ClipItem] = [
            ClipItem(type: .text, text: "오늘 회의는 3시로 옮겼습니다. 안건은 배포 일정과 QA 범위입니다.",
                     sourceBundleID: "com.tinyspeck.slackmacgap", sourceAppName: "Slack", createdAt: at(15)),
            ClipItem(type: .link, text: "https://github.com/youminki/RunTime/pull/42",
                     sourceBundleID: "com.google.Chrome", sourceAppName: "Chrome", createdAt: at(80)),
            ClipItem(type: .text, text: "func paste(_ item: ClipItem) {\n    pasteboard.clearContents()\n    pasteboard.setString(item.text, forType: .string)\n}",
                     sourceBundleID: "com.microsoft.VSCode", sourceAppName: "Code", createdAt: at(300)),
            ClipItem(type: .color, colorHex: "#5B8DEF",
                     sourceBundleID: "com.figma.Desktop", sourceAppName: "Figma", createdAt: at(900)),
            ClipItem(type: .file, text: "화면설계서_v3.pdf", fileURLs: ["file:///Users/me/Documents/%ED%99%94%EB%A9%B4%EC%84%A4%EA%B3%84%EC%84%9C_v3.pdf"],
                     sourceBundleID: "com.apple.finder", sourceAppName: "Finder", createdAt: at(3600)),
            ClipItem(type: .text, text: "업무 일지: 클립보드 기록 띠 점검, 초성 검색 확인",
                     sourceBundleID: "com.apple.Notes", sourceAppName: "메모", createdAt: at(7200)),
            ClipItem(type: .link, text: "https://pasteapp.io",
                     sourceBundleID: "com.apple.Safari", sourceAppName: "Safari", createdAt: at(86_400)),
        ]
        if let png = sampleImage(), let name = store.storeImageData(png) {
            items.insert(ClipItem(type: .image, imageFileName: name, sourceBundleID: "com.apple.Preview",
                                  sourceAppName: "미리보기", createdAt: at(1800)), at: 4)
        }
        for item in items.reversed() { store.addCaptured(item) }
        store.selectFirst()
    }

    private static func sampleImage() -> Data? {
        let size = NSSize(width: 640, height: 400)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 30)
            ("RunTime" as NSString).draw(at: NSPoint(x: 40, y: 170), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.white])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func shoot(_ name: String, _ folder: URL, reset: Bool = true) {
        if reset || !(NSApp.windows.contains { $0 is BarPanel && $0.isVisible }) {
            if reset { AppController.shared.showBar() } else { showKeepingState() }
        }
        wait(1.0)
        guard let panel = NSApp.windows.first(where: { $0 is BarPanel && $0.isVisible }),
              let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
    }

    /// showBar는 검색어·거르기·보드를 비운다. 그 상태를 찍을 때는 띠만 다시 올린다.
    private static func showKeepingState() {
        let store = ClipboardStore.shared
        let (search, filter, source) = (store.searchText, store.typeFilter, store.source)
        AppController.shared.showBar()
        store.source = source
        store.typeFilter = filter
        store.searchText = search
    }

    private static func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
