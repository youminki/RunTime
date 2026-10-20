import AppKit
import SwiftUI
import WorkLogCore

/// 화면 점검: 팝오버·설정·일별·순위표를 실제 데이터로 창에 띄워 PNG로 저장한다.
/// `ImageRenderer`는 Form·Toggle 같은 AppKit 컨트롤을 그리지 못해서 창에 올린 뒤 그 뷰를 찍는다.
@MainActor
enum UIShots {
    private static func workLogPage(_ mode: WorkLogPage.Mode, preview: WorkLogPage.Preview = .report,
                                    search: String = "", newProject: String? = nil) -> WorkLogPage {
        let page = WorkLogPage()
        page.mode = mode
        page.preview = preview
        // 예시 일지의 마지막 기록일을 보인다 (날이 바뀌어도 빈 화면이 찍히지 않게)
        if let last = WorkLogStore.shared.log.days.first { page.day = last }
        page.search = search
        // 줄이 없는 새 프로젝트도 카드와 목록에 보이는지 본다
        if let newProject {
            WorkLogStore.shared.addProject(newProject)
            page.openProjects.insert(newProject)
        }
        return page
    }

    private static func importPage() -> WorkLogPage {
        let page = WorkLogPage()
        page.importText = "1.uxhub\n- QA 수정사항 7건 반영 (완료)\n2. VeloX\n- 데이터 수집 > 파이프라인 생성 API 연동 (100%)"
        return page
    }

    private static func settingsPage(_ section: WorkLogPage.SettingsSection) -> WorkLogPage {
        let page = WorkLogPage()
        page.settingsSection = section
        // 긴 웹훅 주소를 붙여 넣었을 때 창 너비를 넘지 않는지 본다
        if section == .teams { page.teamsDraft = String(repeating: "https://example.environment.api.powerplatform.com/workflows/", count: 3) }
        return page
    }

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
            ("popover-storage", .darkAqua, nil,
             AnyView(PopoverView(engine: engine, settings: engine.settings, startSection: .storage))),
            ("storage", .darkAqua, nil, AnyView(StorageView(settings: engine.settings).padding(14).frame(width: 376).background(Theme.background))),
            ("popover-quests", .darkAqua, nil,
             AnyView(PopoverView(engine: engine, settings: engine.settings, startSection: .quests))),
            ("shop-buddy", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .buddy).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-track", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .track).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-weather", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .weather).padding(14).frame(width: 376).background(Theme.background))),
            ("quests", .darkAqua, nil, AnyView(QuestView().padding(14).frame(width: 376).background(Theme.background))),
            ("shop-ability", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .ability).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-trail", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .trail).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-dust", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .dust).padding(14).frame(width: 376).background(Theme.background))),
            ("shop-crash", .darkAqua, nil, AnyView(GameShopView(settings: engine.settings, tab: .crash).padding(14).frame(width: 376).background(Theme.background))),
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
            ("petdex", .darkAqua, nil, AnyView(PetdexBrowser(settings: engine.settings, close: {}).background(windowBackground))),
            ("leaderboard-light", .aqua, nil, AnyView(LeaderboardView().background(windowBackground))),
            // 업무 일지는 RUNTIME_WORKLOG로 예시 파일을 가리키고 찍는다 (내 일지가 그림에 남지 않게)
            ("worklog-day", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.day)))),
            ("worklog-day-light", .aqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.day)))),
            ("worklog-redmine", .aqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.day, preview: .redmine)))),
            ("worklog-week", .aqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.week)))),
            ("worklog-project", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.project)))),
            ("worklog-month", .aqua, 700, AnyView(WorkLogView(store: .shared, page: workLogPage(.month)))),
            ("worklog-search", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.day, search: "ㄷㅇㅌ")))),
            ("worklog-new-project", .aqua, 700, AnyView(WorkLogView(store: .shared, page: workLogPage(.day, newProject: "회의·보고")))),
            ("worklog-issues", .aqua, 760, AnyView(WorkLogView(store: .shared, page: workLogPage(.issues)))),
            ("worklog-issues-dark", .darkAqua, 760, AnyView(WorkLogView(store: .shared, page: workLogPage(.issues)))),
            ("worklog-quickadd", .aqua, nil, AnyView(QuickAddView(model: QuickAddModel(), store: .shared) {})),
            ("worklog-quickadd-dark", .darkAqua, nil, AnyView(QuickAddView(model: QuickAddModel(), store: .shared) {})),
            ("worklog-editor", .aqua, nil, AnyView(Group {
                if let id = WorkLogStore.shared.log.entries.last(where: { $0.issue != nil })?.id {
                    EntryEditor(store: .shared, page: WorkLogPage(), id: id).background(WL.canvas)
                }
            })),
            ("worklog-editor-unlinked", .darkAqua, nil, AnyView(Group {
                if let id = WorkLogStore.shared.log.entries.last(where: { $0.issue == nil })?.id {
                    EntryEditor(store: .shared, page: WorkLogPage(), id: id).background(WL.canvas)
                }
            })),
            ("worklog-status", .aqua, nil, AnyView(StatusPicker(current: .percent(60)) { _ in }.background(WL.canvas))),
            ("worklog-import", .aqua, nil, AnyView(WorkLogImportSheet(store: .shared, page: importPage()))),
            ("worklog-settings", .aqua, nil, AnyView(WorkLogSettingsView(settings: .shared, sync: .shared, page: WorkLogPage(), store: .shared))),
            ("worklog-settings-dark", .darkAqua, nil, AnyView(WorkLogSettingsView(settings: .shared, sync: .shared, page: WorkLogPage(), store: .shared))),
            ("worklog-settings-redmine", .aqua, nil, AnyView(WorkLogSettingsView(settings: .shared, sync: .shared, page: settingsPage(.redmine), store: .shared))),
            ("worklog-settings-teams", .darkAqua, nil, AnyView(WorkLogSettingsView(settings: .shared, sync: .shared, page: settingsPage(.teams), store: .shared))),
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
