import SwiftUI

/// 한 창 안에서 오가는 화면. 메뉴바·팝오버·알림의 단추도 새 창을 띄우지 않고 이 창의 화면을 바꾼다.
enum MainPage: String, CaseIterable {
    case usage, game, runners, workLog, settings

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
        case .settings: return "설정"
        }
    }

    var icon: String {
        switch self {
        case .usage: return "gauge.with.dots.needle.33percent"
        case .game: return "gamecontroller"
        case .runners: return "hare"
        case .workLog: return "checklist"
        case .settings: return "gearshape"
        }
    }

    var detail: String {
        switch self {
        case .usage: return "세션·주간 사용률, 최근 30분, 날짜별 토큰과 비용"
        case .game: return "장애물 피하기 게임과 순위"
        case .runners: return "러너 고르기, 상점, 창고, 퀘스트"
        case .workLog: return "업무 일지와 일일·주간 보고, 레드마인 보내기"
        case .settings: return "일반, 러너, 사용량 설정"
        }
    }

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

    func go(_ next: MainPage) {
        guard next != page else { return }
        back.append(page)
        forward.removeAll()
        page = next
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(page)
        page = previous
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(page)
        page = next
    }

    /// 닫혀 있던 창을 열 때. 사용량을 처음 화면으로 깔아 두어 뒤로 가면 사용량이 나온다.
    func start(at first: MainPage) {
        back = first == .usage ? [] : [.usage]
        forward = []
        page = first
    }
}

/// 앱 창: 왼쪽 아이콘 막대와 고른 화면. 뒤로·앞으로와 화면 이름은 창 도구 막대(MainToolbar)에 있다.
struct MainWindowView: View {
    @ObservedObject var engine: UsageEngine
    @ObservedObject var settings: AppSettings
    @ObservedObject var navigator: MainNavigator
    let workLogPage: WorkLogPage
    let settingsTab: SettingsTabState
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

    @ViewBuilder
    private var content: some View {
        switch navigator.page {
        case .usage, .game, .runners:
            PopoverView(engine: engine, settings: settings,
                        openSettings: { [navigator] in navigator.go(.settings) },
                        importRunner: importRunner,
                        openDailyDetail: { [navigator] in navigator.go(.usage) },
                        openWorkLog: { [navigator] in navigator.go(.workLog) },
                        openLeaderboard: { [navigator] in navigator.go(.game) },
                        performTrick: performTrick,
                        layout: navigator.page == .usage ? .usagePage : navigator.page == .game ? .gamePage : .runnersPage)
                .id(navigator.page)
                .environment(\.colorScheme, .dark)
        case .workLog:
            WorkLogView(store: .shared, page: workLogPage)
        case .settings:
            SettingsView(settings: settings, engine: engine, tab: settingsTab, workLog: workLogPage)
        }
    }
}
