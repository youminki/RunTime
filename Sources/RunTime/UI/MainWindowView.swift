import SwiftUI

/// 한 창 안에서 오가는 화면. 메뉴바·팝오버·알림의 단추도 새 창을 띄우지 않고 이 창의 화면을 바꾼다.
enum MainPage: String, CaseIterable {
    case usage, game, runners, workLog, calendar, design, hosts, settings

    /// 예전 버전이 따로 띄우던 창 이름. 지금은 합친 화면으로 연다 (일별 사용량은 사용량, 순위는 게임).
    init?(windowName: String) {
        let legacy: [String: MainPage] = ["daily": .usage, "dailyDetail": .usage, "leaderboard": .game]
        guard let page = MainPage(rawValue: windowName) ?? legacy[windowName] else { return nil }
        self = page
    }

    var title: String {
        switch self {
        case .usage: return "사용량"
        case .game: return "게임"
        case .runners: return "러너"
        case .workLog: return "업무 일지"
        case .calendar: return "캘린더"
        case .design: return "디자인"
        case .hosts: return "호스트"
        case .settings: return "설정"
        }
    }

    var icon: String {
        switch self {
        case .usage: return "gauge.medium"
        case .game: return "gamecontroller"
        case .runners: return "hare"
        case .workLog: return "checklist"
        case .calendar: return "calendar"
        case .design: return "paintpalette"
        case .hosts: return "network"
        case .settings: return "gearshape"
        }
    }

    var detail: String {
        switch self {
        case .usage: return "세션·주간 사용률, 최근 30분, 날짜별 토큰과 비용"
        case .game: return "장애물 피하기 게임과 순위"
        case .runners: return "러너 고르기, 상점, 창고, 퀘스트"
        case .workLog: return "업무 일지와 일일·주간 보고, 레드마인 보내기"
        case .calendar: return "업무 일지를 한 달 달력으로 크게, 공휴일과 함께"
        case .design: return "피그마 화면설계서의 메뉴·화면별 변경 기록"
        case .hosts: return "/etc/hosts 묶음별 켜기·끄기, 정리, 백업"
        case .settings: return "일반, 러너, 사용량 설정"
        }
    }

    /// 들른 뒤로 숨겨 두고 다시 쓰는 화면 (MainWindowView.content 참고).
    static let kept: [MainPage] = [.workLog, .calendar, .design]

    /// 팝오버와 같은 어두운 색 규칙으로 그리는 화면. 이 화면에서는 창 전체를 어둡게 한다.
    var isDark: Bool { self == .usage || self == .game || self == .runners }
    /// 러너 무대가 있는 화면 (게임·러너). 팝오버 무대와 동시에 띄우지 않는다.
    var hasStage: Bool { self == .game || self == .runners }
}

/// 창 안의 이동 기록. Finder·시스템 설정처럼 뒤로·앞으로를 쓴다.
final class MainNavigator: ObservableObject {
    @Published private(set) var page: MainPage = .usage
    @Published private(set) var back: [MainPage] = []
    @Published private(set) var forward: [MainPage] = []
    /// 창을 연 뒤 한 번이라도 들른 화면. 업무 일지는 들른 뒤로 떠나도 버리지 않고 숨겨 두어 다시 올 때 바로 보인다.
    @Published private(set) var visited: Set<MainPage> = [.usage]

    func go(_ next: MainPage) {
        guard next != page else { return }
        back.append(page)
        forward.removeAll()
        page = next
        visited.insert(next)
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(page)
        page = previous
        visited.insert(previous)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(page)
        page = next
        visited.insert(next)
    }

    /// 닫혀 있던 창을 열 때. 사용량을 처음 화면으로 깔아 두어 뒤로 가면 사용량이 나온다.
    func start(at first: MainPage) {
        back = first == .usage ? [] : [.usage]
        forward = []
        page = first
        visited = [first]
    }
}

/// 앱 창: 왼쪽 아이콘 막대와 고른 화면. 뒤로·앞으로와 화면 이름은 창 도구 막대(MainToolbar)에 있다.
struct MainWindowView: View {
    // 사용량은 몇 초마다 바뀌어, 창 전체가 아니라 그것을 보이는 화면만 다시 그리게 지켜보지 않고 넘기기만 한다
    let engine: UsageEngine
    let settings: AppSettings
    @ObservedObject var navigator: MainNavigator
    let workLogPage: WorkLogPage
    let settingsTab: SettingsTabState
    /// 디자인 화면 상태. 앱은 하나를 계속 쓰고, 화면 점검은 화면마다 따로 넘긴다.
    var designPage: DesignHistoryPage = .shared
    var importRunner: () -> Void = {}
    var performTrick: (Trick) -> Void = { _ in }

    static let railWidth: CGFloat = 68

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(WL.border).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 업무 일지의 "연동 설정"·"레드마인 연결" 단추는 이 창의 설정 화면 업무 일지 칸으로 간다
        .onReceive(workLogPage.$showsSettings.filter { $0 }) { _ in
            workLogPage.showsSettings = false
            settingsTab.selection = .workLog
            navigator.go(.settings)
        }
        // 디자인 화면의 연동 상태·"피그마 연결하기"는 설정 화면의 디자인 칸으로 간다
        .onReceive(designPage.$showsSettings.filter { $0 }) { _ in
            designPage.showsSettings = false
            settingsTab.selection = designPage.settingsSection == .alerts ? .designAlerts : .design
            navigator.go(.settings)
        }
        .frame(minWidth: AppWindow.minSize.width, idealWidth: AppWindow.size.width,
               minHeight: AppWindow.minSize.height, idealHeight: AppWindow.size.height)
    }

    // MARK: 아이콘 막대

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(MainPage.allCases.filter { $0 != .settings }, id: \.self) { page in railItem(page) }
            Spacer()
            railItem(.settings)
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
    }

    private func railItem(_ page: MainPage) -> some View {
        let on = navigator.page == page
        // 설정은 macOS 관례대로 ⌘,로, 나머지는 위에서부터 ⌘1, ⌘2…
        let number = MainPage.allCases.firstIndex(of: page).map { $0 + 1 } ?? 0
        let key: KeyEquivalent = page == .settings ? "," : KeyEquivalent(Character(String(number)))
        return Button { navigator.go(page) } label: {
            VStack(spacing: 3) {
                Image(systemName: page.icon)
                    .font(.system(size: 16, weight: on ? .semibold : .regular))
                    .frame(width: 40, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.18) : .clear))
                Text(page.title)
                    .font(.system(size: 10, weight: on ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(width: Self.railWidth - 8, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .tip("\(page.title) (⌘\(page == .settings ? "," : String(number))) · \(page.detail)")
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: 화면

    /// 업무 일지와 캘린더는 만드는 데 오래 걸려(달력·보고서·레드마인 목록) 한 번 들른 뒤로는 숨겨 두고 다시 쓴다.
    /// 숨긴 동안은 단축키와 클릭을 받지 않게 끈다. 무대가 있는 화면은 숨겨도 애니메이션이 돌고,
    /// 설정은 떠날 때 연동을 다시 받아야 해서 매번 새로 만든다.
    private var content: some View {
        let page = navigator.page
        return ZStack {
            ForEach(MainPage.kept.filter { navigator.visited.contains($0) }, id: \.self) { kept in
                let shown = page == kept
                Group {
                    if kept == .workLog {
                        WorkLogView(store: .shared, page: workLogPage, isActive: shown)
                    } else if kept == .design {
                        DesignHistoryView(sync: .shared, settings: .shared, page: designPage, isActive: shown)
                    } else {
                        screen(kept)
                    }
                }
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .disabled(!shown)
                .accessibilityHidden(!shown)
            }
            if !MainPage.kept.contains(page) { screen(page) }
        }
        // 화면을 떠나며 숨긴 화면의 글 칸에 초점이 남으면 치는 글이 보이지 않는 곳으로 간다
        .onChange(of: page) { _ in NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    @ViewBuilder
    private func screen(_ page: MainPage) -> some View {
        switch page {
        case .usage, .game, .runners:
            PopoverView(engine: engine, settings: settings,
                        openSettings: { [navigator] in navigator.go(.settings) },
                        importRunner: importRunner,
                        openDailyDetail: { [navigator] in navigator.go(.usage) },
                        openWorkLog: { [navigator] in navigator.go(.workLog) },
                        openDesign: { [navigator] in navigator.go(.design) },
                        openLeaderboard: { [navigator] in navigator.go(.game) },
                        performTrick: performTrick,
                        layout: page == .usage ? .usagePage : page == .game ? .gamePage : .runnersPage)
                .id(page)
                .environment(\.colorScheme, .dark)
        case .workLog:
            WorkLogView(store: .shared, page: workLogPage)
        case .calendar:
            CalendarPageView(store: .shared, page: workLogPage) { [navigator, workLogPage] day in
                workLogPage.search = ""
                workLogPage.day = day
                workLogPage.mode = .day
                navigator.go(.workLog)
            }
        case .design:
            DesignHistoryView(sync: .shared, settings: .shared, page: designPage)
        case .hosts:
            HostsView(store: .shared, page: .shared)
        case .settings:
            SettingsView(settings: settings, engine: engine, tab: settingsTab, workLog: workLogPage)
        }
    }
}
