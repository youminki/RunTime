import AppKit
import DesignSyncCore
import SwiftUI
import WorkLogCore

/// 화면 점검: 팝오버·설정·일별·순위표를 실제 데이터로 창에 띄워 PNG로 저장한다.
/// `ImageRenderer`는 Form·Toggle 같은 AppKit 컨트롤을 그리지 못해서 창에 올린 뒤 그 뷰를 찍는다.
/// 화면 점검 창. 화면 밖에 두어도 키 창이 되면 사용자가 다른 앱에서 치는 글자를 가져가서, 키 창이 되지 않게 한다.
final class ShotWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
enum UIShots {
    private static func workLogPage(_ mode: WorkLogPage.Mode, preview: WorkLogPage.Preview = .report,
                                    search: String = "", newProject: String? = nil) -> WorkLogPage {
        let page = WorkLogPage()
        page.mode = mode
        page.preview = preview
        // 예시 일지의 마지막 기록일을 보인다 (날이 바뀌어도 빈 화면이 찍히지 않게)
        if let last = WorkLogStore.shared.log.days.first { page.day = last }
        // 점검할 날을 고를 때 (예: 보낼 MR 줄이 있는 날의 화면 첨부 미리보기). 화면은 앱처럼 카드 목록이 불러온다
        if let day = ProcessInfo.processInfo.environment["RUNTIME_SHOT_DAY"], !day.isEmpty { page.day = day }
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

    /// 앱 창을 기본 크기로, 고른 화면을 띄운 채 찍는다 (사용량에서 들어온 것처럼 뒤로 단추가 켜진다).
    private static func mainPage(_ page: MainPage, engine: UsageEngine, workLog: WorkLogPage.Mode = .day) -> AnyView {
        let navigator = MainNavigator()
        navigator.start(at: page)
        return AnyView(MainWindowView(engine: engine, settings: engine.settings, navigator: navigator,
                                      workLogPage: workLogPage(workLog), settingsTab: SettingsTabState(.general))
            .frame(width: mainSize.width, height: mainSize.height))
    }

    /// 앱 창 화면을 찍을 크기. RUNTIME_SHOT_MIN=1이면 최소 크기로 찍어 잘리는 곳을 본다.
    private static var mainSize: CGSize {
        ProcessInfo.processInfo.environment["RUNTIME_SHOT_MIN"] == "1" ? AppWindow.minSize : AppWindow.size
    }

    /// 앱 창 설정 화면에서 업무 일지 연동 칸을 고른 채 찍는다.
    private static func mainSettings(_ section: WorkLogPage.SettingsSection, engine: UsageEngine) -> AnyView {
        let navigator = MainNavigator()
        navigator.start(at: .settings)
        return AnyView(MainWindowView(engine: engine, settings: engine.settings, navigator: navigator,
                                      workLogPage: settingsPage(section), settingsTab: SettingsTabState(.workLog))
            .frame(width: mainSize.width, height: mainSize.height))
    }

    /// 디자인 화면은 RUNTIME_DESIGN_HISTORY로 예시 기록을 가리킬 때만 찍는다. 내 기록에는 회사 화면설계서가 들어 있다.
    /// 없는 파일을 가리키면 처음 화면(피그마 연결 안내)을 찍는다.
    private static func designScreens(engine: UsageEngine) -> [(name: String, appearance: NSAppearance.Name, height: CGFloat?, view: AnyView)] {
        guard ProcessInfo.processInfo.environment["RUNTIME_DESIGN_HISTORY"]?.isEmpty == false else { return [] }
        // 예시 파일을 지켜보는 것으로 두고 한 묶음에 알림을 켜, 종과 상태 점이 어떻게 보이는지 찍는다 (개발용 설정에만 남는다)
        // 프로젝트가 여럿일 때: 첫 파일 한 묶음에 알림, 메뉴 둘을 즐겨찾기, 둘째 파일 메뉴 하나를 숨긴다
        if ProcessInfo.processInfo.environment["RUNTIME_SHOT_DESIGN_ALERTS"] == "1" {
            let files = DesignSync.shared.history.files.sorted { $0.value.name < $1.value.name }
            DesignSyncSettings.shared.sources = files.enumerated().map { index, file in
                let paths = Set(file.value.screens.values.map(\.menuPath)).sorted()
                return DesignSource(fileKey: file.key, name: file.value.name,
                                    alerts: index == 0 ? [paths.first.map(DesignMenuTree.head) ?? ""] : [],
                                    hiddenMenus: index == 1 ? Array(paths.suffix(1)) : [])
            }
            DesignSyncSettings.shared.favorites = files.prefix(2).compactMap { file in
                Set(file.value.screens.values.map(\.menuPath)).sorted().dropFirst().first.map { DesignSync.favoriteKey(file.key, $0) }
            }
        }
        return [
            ("main-design", .aqua, nil, mainDesign(engine: engine)),
            ("main-design-dark", .darkAqua, nil, mainDesign(engine: engine)),
            ("main-design-working", .aqua, nil, mainDesign(engine: engine, scope: .working, select: false)),
            ("main-design-menu", .aqua, nil, mainDesign(engine: engine, scope: firstGroup.map { .group(fileKey: $0.0, head: $0.1) } ?? .all)),
            ("main-settings-design-alerts", .aqua, nil, {
                let navigator = MainNavigator()
                navigator.start(at: .settings)
                return AnyView(MainWindowView(engine: engine, settings: engine.settings, navigator: navigator,
                                              workLogPage: WorkLogPage(), settingsTab: SettingsTabState(.designAlerts))
                    .frame(width: mainSize.width, height: mainSize.height))
            }()),
            ("design-alert-picker", .aqua, nil, AnyView(DesignAlertPicker(sync: .shared,
                                                                          fileKey: DesignSync.shared.history.files.keys.first ?? ""))),
            ("main-settings-design", .aqua, nil, {
                let navigator = MainNavigator()
                navigator.start(at: .settings)
                return AnyView(MainWindowView(engine: engine, settings: engine.settings, navigator: navigator,
                                              workLogPage: WorkLogPage(), settingsTab: SettingsTabState(.design))
                    .frame(width: mainSize.width, height: mainSize.height))
            }()),
        ]
    }

    private static var firstGroup: (String, String)? {
        DesignSync.shared.history.menus().first.map { ($0.fileKey, DesignMenuTree.head($0.path)) }
    }

    /// 앱 창의 디자인 화면. 화면마다 새 상태로 찍고, 가장 최근 변경을 골라 둔다.
    private static func mainDesign(engine: UsageEngine, scope: DesignHistoryPage.Scope = .all, select: Bool = true) -> AnyView {
        let page = DesignHistoryPage()
        page.scope = scope
        if select { page.selected = DesignSync.shared.history.events.last(where: { $0.kind == .changed })?.id }
        let navigator = MainNavigator()
        navigator.start(at: .design)
        return AnyView(MainWindowView(engine: engine, settings: engine.settings, navigator: navigator,
                                      workLogPage: WorkLogPage(), settingsTab: SettingsTabState(.general), designPage: page)
            .frame(width: mainSize.width, height: mainSize.height))
    }

    static func run(to directory: URL, engine: UsageEngine) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
        // RUNTIME_UPDATE_SHOT=pending이면 업데이트 말풍선, progress면 설치 진행 판이 뜬 무대를 찍는다
        switch ProcessInfo.processInfo.environment["RUNTIME_UPDATE_SHOT"] {
        case "pending": AppUpdater.shared.rehearse(progress: nil)
        case "progress": AppUpdater.shared.rehearse(progress: .init(fraction: 0.62, step: "빌드하는 중", remaining: 41))
        default: break
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
            ("main-usage", .darkAqua, nil, mainPage(.usage, engine: engine)),
            ("main-game", .darkAqua, nil, mainPage(.game, engine: engine)),
            ("main-runners", .darkAqua, nil, mainPage(.runners, engine: engine)),
            ("main-worklog", .aqua, nil, mainPage(.workLog, engine: engine)),
            ("main-worklog-dark", .darkAqua, nil, mainPage(.workLog, engine: engine)),
            ("main-worklog-issues", .aqua, nil, mainPage(.workLog, engine: engine, workLog: .issues)),
            ("main-calendar", .aqua, nil, mainPage(.calendar, engine: engine)),
            ("main-calendar-dark", .darkAqua, nil, mainPage(.calendar, engine: engine)),
            ("main-worklog-week", .aqua, nil, mainPage(.workLog, engine: engine, workLog: .week)),
            ("main-settings", .aqua, nil, mainPage(.settings, engine: engine)),
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
            ("petdex", .darkAqua, nil, AnyView(PetdexBrowser(settings: engine.settings, close: {}).background(windowBackground))),
            // 업무 일지는 RUNTIME_WORKLOG로 예시 파일을 가리키고 찍는다 (내 일지가 그림에 남지 않게)
            ("worklog-day", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.day)))),
            ("worklog-day-light", .aqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.day)))),
            ("worklog-redmine", .aqua, 640, AnyView(WorkLogView(store: .shared, page: workLogPage(.day, preview: .redmine)))),
            // 카드 아래 MR 화면 첨부 미리보기까지 보이게 길게 찍는다
            ("worklog-redmine-tall", .darkAqua, 1400, AnyView(WorkLogView(store: .shared, page: workLogPage(.day, preview: .redmine)))),
            ("worklog-redmine-partial", .darkAqua, 640, AnyView(WorkLogView(store: .shared, page: {
                // 일감 하나를 골라 내지 않았을 때 보내기 단추와 카드가 고른 것만 가리키는지 본다
                let page = workLogPage(.day, preview: .redmine)
                if let issue = WorkLogStore.shared.log.entries(on: page.day).compactMap(\.issue).first { page.redmineSkipped = [issue] }
                return page
            }()))),
            ("worklog-redmine-fields", .aqua, 640, AnyView(WorkLogView(store: .shared, page: fieldsPage()))),
            ("worklog-send-confirm", .aqua, nil, AnyView({
                // 보내기 전 확인 창: 일감마다 진척률·함께 바뀔 칸·댓글이 보이는지 본다
                let page = fieldsPage()
                let issues = Set(WorkLogStore.shared.log.entries(on: page.day).compactMap(\.issue))
                return WorkLogPreview(store: .shared, page: page, sync: .shared, settings: .shared).sendConfirm(issues)
            }())),
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
            ("main-settings-worklog", .aqua, nil, mainSettings(.gitlab, engine: engine)),
            ("main-settings-worklog-dark", .darkAqua, nil, mainSettings(.gitlab, engine: engine)),
            ("main-settings-redmine", .aqua, nil, mainSettings(.redmine, engine: engine)),
            // 긴 웹훅 호스트가 저장된 뒤에도 제목·설명이 세로로 서지 않는지 본다
            ("worklog-secret-saved", .darkAqua, nil, AnyView(
                SettingRow("웹훅 주소", "아래 순서로 만든 주소를 복사해 두고 붙여넣기를 누르세요. 주소는 키체인에 둡니다.") {
                    SecretInput(saved: true, hint: "default9cc8af3ec399451c923a3b56304249.a6.environment.api.powerplatform.com",
                                placeholder: "", draft: .constant(""), save: { _ in nil }, clear: {})
                }
                .padding(.horizontal, 32).frame(width: 600).background(WL.canvas))),
            ("main-settings-redmine-dark", .darkAqua, nil, mainSettings(.redmine, engine: engine)),
            ("main-settings-teams", .darkAqua, nil, mainSettings(.teams, engine: engine)),
        ] + designScreens(engine: engine)
        // RUNTIME_SHOTS=main-,worklog-day처럼 이름 앞부분을 주면 그 화면만 찍는다
        let only = ProcessInfo.processInfo.environment["RUNTIME_SHOTS"].flatMap { $0.isEmpty ? nil : $0.split(separator: ",").map(String.init) }
        let picked = only.map { prefixes in screens.filter { screen in prefixes.contains { screen.name.hasPrefix($0) } } } ?? screens
        let windows = picked.map { screen -> NSWindow in
            let window = ShotWindow(contentViewController: NSHostingController(rootView: screen.view))
            window.styleMask = [.titled]
            window.appearance = NSAppearance(named: screen.appearance)
            // 설정처럼 스크롤되는 창은 최대 높이로 펼쳐 한 장에 담는다
            // 업무 일지는 창 너비를 따라 칸을 나누므로 앱 창 안에서의 너비(아이콘 막대를 뺀 값)로 찍는다
            let width = screen.name.hasPrefix("worklog-") && screen.height != nil
                ? AppWindow.size.width - MainWindowView.railWidth - 1 : window.frame.width
            if let height = screen.height { window.setContentSize(NSSize(width: width, height: height)) }
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
            for (screen, window) in zip(picked, windows) { shot(screen.name, window) }
            // 무대 하늘은 시각마다 달라 글자·러너 대비를 시간대별로 본다 (아침·낮·노을)
            var hours = picked.first?.name == "popover" ? [7, 12, 18] : []
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
