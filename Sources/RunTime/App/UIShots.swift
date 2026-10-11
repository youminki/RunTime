import AppKit
import SwiftUI

/// 화면 점검: 팝오버·설정·일별·순위표를 실제 데이터로 창에 띄워 PNG로 저장한다.
/// `ImageRenderer`는 Form·Toggle 같은 AppKit 컨트롤을 그리지 못해서 창에 올린 뒤 그 뷰를 찍는다.
@MainActor
enum UIShots {
    static func run(to directory: URL, engine: UsageEngine) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
        // 찍힌 그림에는 창 배경이 빠지므로 뷰 뒤에 배경을 직접 깐다. 팝오버는 PopoverView가 바탕을 칠한다.
        let windowBackground = Color(nsColor: .windowBackgroundColor)
        let screens: [(name: String, appearance: NSAppearance.Name, height: CGFloat?, view: AnyView)] = [
            ("popover", .darkAqua, nil, AnyView(PopoverView(engine: engine, settings: engine.settings))),
            ("popover-runners", .darkAqua, nil,
             AnyView(PopoverView(engine: engine, settings: engine.settings, startSection: .runners))),
            ("popover-shop", .darkAqua, nil,
             AnyView(PopoverView(engine: engine, settings: engine.settings, startSection: .shop))),
            ("popover-quests", .darkAqua, nil,
             AnyView(PopoverView(engine: engine, settings: engine.settings, startSection: .quests))),
            ("shop-buddy", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .buddy).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-head", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .head).padding(14).frame(width: 376).background(Theme.background))),
            ("quests", .darkAqua, nil, AnyView(QuestView().padding(14).frame(width: 376).background(Theme.background))),
            ("shop-ability", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .ability).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-trail", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .trail).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-dust", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .dust).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-crash", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .crash).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-back", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .back).padding(14).frame(width: 376).background(Theme.background))),
            ("welcome", .darkAqua, nil, AnyView(WelcomeView(settings: engine.settings))),
            ("welcome-light", .aqua, nil, AnyView(WelcomeView(settings: engine.settings))),
            ("settings-general", .darkAqua, 720, AnyView(SettingsView(settings: engine.settings, engine: engine, tab: SettingsTabState(.general)).background(windowBackground))),
            ("settings-general-light", .aqua, 720, AnyView(SettingsView(settings: engine.settings, engine: engine, tab: SettingsTabState(.general)).background(windowBackground))),
            ("settings-runner", .darkAqua, 720,
             AnyView(SettingsView(settings: engine.settings, engine: engine, tab: SettingsTabState(.runner)).background(windowBackground))),
            ("settings-usage", .darkAqua, 720,
             AnyView(SettingsView(settings: engine.settings, engine: engine, tab: SettingsTabState(.usage)).background(windowBackground))),
            ("settings-runner-light", .aqua, 720,
             AnyView(SettingsView(settings: engine.settings, engine: engine, tab: SettingsTabState(.runner)).background(windowBackground))),
            ("daily", .darkAqua, nil, AnyView(DailyDetailView(engine: engine).background(windowBackground))),
            ("daily-light", .aqua, nil, AnyView(DailyDetailView(engine: engine).background(windowBackground))),
            ("leaderboard", .darkAqua, nil, AnyView(LeaderboardView().background(windowBackground))),
            ("leaderboard-light", .aqua, nil, AnyView(LeaderboardView().background(windowBackground))),
        ]
        let windows = screens.map { screen -> NSWindow in
            let window = NSWindow(contentViewController: NSHostingController(rootView: screen.view))
            window.styleMask = [.titled]
            window.appearance = NSAppearance(named: screen.appearance)
            // 설정처럼 스크롤되는 창은 최대 높이로 펼쳐 한 장에 담는다
            if let height = screen.height { window.setContentSize(NSSize(width: window.frame.width, height: height)) }
            // 화면 밖에 두어 사용자 작업을 가리지 않는다
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            return window
        }
        // 무대 애니메이션과 비동기로 오는 순위·사용량이 자리 잡을 때까지 기다린다
        func shot(_ name: String, _ window: NSWindow) {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = directory.appendingPathComponent("\(name).png")
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                print("saved: \(url.path) \(Int(view.bounds.width))×\(Int(view.bounds.height))")
            } catch {
                print("failed: \(url.path) \(error)")
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            for (screen, window) in zip(screens, windows) { shot(screen.name, window) }
            // 무대 하늘은 시각마다 달라 글자·러너 대비를 시간대별로 본다 (아침·낮·노을)
            var hours = [7, 12, 18]
            func next() {
                guard let hour = hours.first else { exit(0) }
                hours.removeFirst()
                Sky.hourOverride = hour
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    shot("popover-\(hour)h", windows[0])
                    next()
                }
            }
            next()
        }
    }
}
