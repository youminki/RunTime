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

    /// 상태 목록과 신규 상태의 일감을 넣어, 보낼 때 함께 바뀔 상태·날짜 칩이 보이게 한다.
    private static func fieldsPage() -> WorkLogPage {
        let sync = WorkLogSync.shared
        // 회사 레드마인 상태 목록 (순서가 일의 흐름과 다르다)
        sync.statuses = [RedmineAPI.Status(id: 1, name: "할일", isClosed: false), RedmineAPI.Status(id: 2, name: "처리중", isClosed: false),
                         RedmineAPI.Status(id: 8, name: "테스트", isClosed: false), RedmineAPI.Status(id: 5, name: "완료", isClosed: true),
                         RedmineAPI.Status(id: 3, name: "해결", isClosed: false)]
        WorkLogSettings.shared.progressStatusID = 2
        WorkLogSettings.shared.doneStatusID = 5
        let page = workLogPage(.day, preview: .redmine)
        let store = WorkLogStore.shared
        let infos = store.log.entries(on: page.day).compactMap { store.log.issue($0.issue) }.map { info -> IssueInfo in
            var info = info
            info.statusID = 1
            info.status = "할일"
            info.startDate = nil
            info.dueDate = nil
            info.doneRatio = 30
            info.fetchedAt = Date()
            return info
        }
        store.updateIssues(infos, assignedIDs: nil)
        // 첫 일감은 Claude로 이미 올린 것처럼 보이게 한다
        if let first = infos.first {
            sync.postedHints[first.id] = RedmineAPI.Journal(id: 1, notes: "<p>x</p>", createdOn: Date().addingTimeInterval(-7200))
        }
        return page
    }

    /// 보낸 기록: 되돌릴 수 있는 건과 되돌린 건을 하나씩.
    private static func historyPage() -> WorkLogPage {
        let page = workLogPage(.day, preview: .redmine)
        page.redmineHistory = true
        let store = WorkLogStore.shared
        let issues = store.log.entries(on: page.day).compactMap(\.issue)
        if let first = issues.first {
            store.addSent(RedmineSent(issue: first, sentAt: Date().addingTimeInterval(-3600), entryIDs: [], note: "<p>[작업 내용]</p>",
                                      before: .init(doneRatio: 0, statusName: "할일"), after: .init(doneRatio: 100, statusID: 5, statusName: "완료",
                                      startDate: page.day, dueDate: page.day), undoneAt: Date()))
        }
        if let last = issues.last {
            store.addSent(RedmineSent(issue: last, entryIDs: [], note: "<p>[작업 내용]</p>", before: .init(doneRatio: 30, statusName: "처리중"),
                                      after: .init(doneRatio: 100, statusID: 5, statusName: "완료", dueDate: page.day), timeEntryIDs: [1]))
        }
        return page
    }

    /// 프로젝트 하나와 레드마인 프로젝트 하나를 숨긴 화면.
    private static func hiddenPage(_ mode: WorkLogPage.Mode) -> WorkLogPage {
        let page = workLogPage(mode)
        let store = WorkLogStore.shared
        if let name = store.log.allProjects.last { store.setHidden(name, true) }
        if let name = store.log.issues.values.filter(\.assigned).map(\.project).sorted().first { store.setRedmineHidden(name, true) }
        page.showsHidden = mode == .issues
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
            ("worklog-redmine-partial", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: {
                // 일감 하나를 골라 내지 않았을 때 보내기 단추와 카드가 고른 것만 가리키는지 본다
                let page = workLogPage(.day, preview: .redmine)
                if let issue = WorkLogStore.shared.log.entries(on: page.day).compactMap(\.issue).first { page.redmineSkipped = [issue] }
                return page
            }()))),
            ("worklog-redmine-fields", .aqua, 640, AnyView(WorkLogView(store: .shared, page: fieldsPage()))),
            ("worklog-redmine-history", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: historyPage()))),
            ("worklog-field-editor", .aqua, nil, AnyView(Group {
                if let info = WorkLogStore.shared.log.issues.values.filter(\.assigned).sorted(by: { $0.id < $1.id }).first {
                    IssueFieldEditor(current: info, auto: .init(status: RedmineAPI.Status(id: 5, name: "완료", isClosed: true), dueDate: "2026-10-20"),
                                     edit: .constant(.init(startDate: "2026-10-19")), sync: .shared) {
                        Button("레드마인에 저장") {}.buttonStyle(NotionButtonStyle(kind: .primary))
                    }
                    .background(WL.canvas)
                }
            })),
            ("worklog-week", .aqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.week)))),
            ("worklog-project", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.project)))),
            ("worklog-month", .aqua, 700, AnyView(WorkLogView(store: .shared, page: workLogPage(.month)))),
            ("worklog-search", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.day, search: "ㄷㅇㅌ")))),
            ("worklog-new-project", .aqua, 700, AnyView(WorkLogView(store: .shared, page: workLogPage(.day, newProject: "회의·보고")))),
            ("worklog-issues", .aqua, 760, AnyView(WorkLogView(store: .shared, page: workLogPage(.issues)))),
            ("worklog-issues-query", .aqua, 760, AnyView(WorkLogView(store: .shared, page: {
                // 좁은 창에서 일감 찾기 칸의 글이 잘리지 않는지 본다
                let page = workLogPage(.issues)
                page.issueQuery = "목록 화면"
                return page
            }()))),
            ("worklog-issues-dark", .darkAqua, 760, AnyView(WorkLogView(store: .shared, page: workLogPage(.issues)))),
            ("worklog-hidden", .aqua, 760, AnyView(WorkLogView(store: .shared, page: hiddenPage(.issues)))),
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
            // 긴 웹훅 호스트가 저장된 뒤에도 제목·설명이 세로로 서지 않는지 본다
            ("worklog-secret-saved", .darkAqua, nil, AnyView(
                SettingRow("웹훅 주소", "아래 순서로 만든 주소를 복사해 두고 붙여넣기를 누르세요. 주소는 키체인에 둡니다.") {
                    SecretInput(saved: true, hint: "default9cc8af3ec399451c923a3b56304249.a6.environment.api.powerplatform.com",
                                placeholder: "", draft: .constant(""), save: { _ in nil }, clear: {})
                }
                .padding(.horizontal, 32).frame(width: 600).background(WL.canvas))),
            ("worklog-settings-redmine-dark", .darkAqua, nil, AnyView(WorkLogSettingsView(settings: .shared, sync: .shared, page: settingsPage(.redmine), store: .shared))),
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
