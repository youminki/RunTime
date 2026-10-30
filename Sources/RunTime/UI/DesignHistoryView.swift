import AppKit
import DesignSyncCore
import SwiftUI

/// 디자인 화면의 상태. 이 툴체인은 SwiftUI 매크로(@State)를 못 써서 다른 화면처럼 모델에 둔다.
/// 앱 창에서 숨겼다 다시 보여도 고른 메뉴와 변경이 남게 하나만 쓴다.
@MainActor
final class DesignHistoryPage: ObservableObject {
    static let shared = DesignHistoryPage()

    enum Scope: Hashable {
        /// 완료 후 변경·막 완료됨·이력 (처음 화면)
        case important
        /// 작업 중인 화면의 변경
        case working
        case all
        case menu(fileKey: String, path: String)
        /// 화면 경로의 앞부분 (예: `상품 관리` 또는 `상품 관리 > 상품 목록`) 아래 전부
        case group(fileKey: String, head: String)
        /// 한 프로젝트(화면설계서)의 변경 전부
        case project(fileKey: String)
        /// 마크업에 반영을 마친 변경. 다른 보기에서는 빠진다
        case applied
        /// 두 날짜의 피그마 버전과 그 사이 기록을 견준다
        case compare

        /// 한 프로젝트 안의 보기면 그 프로젝트.
        var fileKey: String? {
            switch self {
            case .menu(let key, _), .group(let key, _), .project(let key): return key
            default: return nil
            }
        }
    }

    /// 지금 보는 프로젝트. nil이면 모든 프로젝트. 프로젝트가 여럿이면 하나씩 보는 것이 기본이다.
    @Published var project: String? = DesignHistoryPage.storedProject() {
        didSet {
            UserDefaults.standard.set(project ?? "*", forKey: "design.project")
            guard project != oldValue, !followingScope else { return }
            // 다른 프로젝트의 메뉴·화면을 고른 채 남지 않게 변경 목록으로 돌아간다
            if scope != .compare && scope != .applied { scope = .important }
            selected = nil
            screen = nil
        }
    }

    private static func storedProject() -> String? {
        let keys = DesignSyncSettings.shared.sources.filter { !$0.isHidden }.map(\.fileKey)
        switch UserDefaults.standard.string(forKey: "design.project") {
        case "*": return nil
        case let key? where keys.contains(key): return key
        default: return keys.first
        }
    }

    /// 다른 프로젝트의 메뉴·화면을 고르면 프로젝트도 따라 바꾼다. 그때는 고른 것을 풀지 않는다.
    private var followingScope = false

    /// 알림 받을 메뉴를 고르는 창을 띄울 프로젝트.
    @Published var alertPicker: String?

    @Published var scope: Scope = .important {
        didSet {
            // 날짜 비교 결과는 기록에 없어서, 다른 보기로 가면 고른 것을 풀어 상세에 남지 않게 한다
            if oldValue == .compare && scope != .compare { selected = nil }
            // 다른 메뉴로 옮기면 그 메뉴 밖의 변경·화면이 상세에 남지 않게 한다
            if scope != oldValue, scope.fileKey != nil { dropSelection(outside: scope) }
            if let key = scope.fileKey, project != nil, project != key {
                followingScope = true
                project = key
                followingScope = false
            }
        }
    }
    @Published var selected: UUID? {
        didSet {
            if selected != oldValue { selectedChange = nil; foldedChangeGroups = [] }
            if selected != nil { screen = nil }
        }
    }
    /// 메뉴·묶음·프로젝트를 볼 때 화면 목록과 변경 목록 가운데 무엇을 보는지. 마크업할 때는 화면이 먼저다.
    enum MenuTab: Hashable { case screens, changes }
    @Published var menuTab: MenuTab = .screens
    /// 기능 명세를 다 구현했고 반영할 변경도 없는 화면을 화면 목록에서 뺀다.
    @Published var hidesBuiltScreens = false
    /// 늘리면 상세를 목록의 다음 항목으로 넘긴다. 화면 상세에서 모두 반영한 뒤 다음 화면으로 갈 때 쓴다.
    @Published var stepRequest = 0

    private func dropSelection(outside scope: Scope) {
        let history = DesignSync.shared.history
        func inside(_ fileKey: String, _ path: String, menus: [String] = []) -> Bool {
            switch scope {
            case .menu(let key, let menu): return key == fileKey && (path == menu || menus.contains(menu))
            case .group(let key, let head): return key == fileKey && ([path] + menus).contains { DesignStatus.covers(head, $0) }
            case .project(let key): return key == fileKey
            default: return true
            }
        }
        if let id = selected, let event = history.events.first(where: { $0.id == id }),
           !inside(event.fileKey, event.menuPath, menus: event.menus ?? []) { selected = nil }
        if let frame = screen, let key = scope.fileKey, !(history.files[key]?.screens[frame].map { inside(key, $0.menuPath) } ?? false) {
            screen = nil
        }
    }

    /// 변경 대신 고른 지금 시안 화면 (프레임 ID). 바뀐 적 없는 화면도 상세에서 명세·이미지를 본다.
    @Published var screen: String? {
        didSet { if screen != nil { selected = nil } }
    }
    /// 화면 상세에서 목업 문구·컴포넌트 목록을 펼쳤는지
    @Published var showsScreenTexts = true
    @Published var showsScreenComponents = false
    /// 상세에서 고른 목업 변경 번호. 화면 비교 이미지에서 그 자리를 강조한다.
    @Published var selectedChange: Int?
    @Published var hoveredChange: Int?
    /// 변경 트리에서 접은 묶음
    @Published var foldedChangeGroups: Set<String> = []
    /// 화면 비교 이미지 위에 바뀐 자리를 그린다
    @Published var showsMarks = true
    @Published var layer: SpecChange.Layer?
    @Published var search = ""
    /// 찾기 칸에 입력 중. 그동안 ⌥↑·⌥↓는 글자 칸이 쓰게 상세 넘기기 단축키를 뺀다.
    @Published var searchFocused = false
    @Published var toast: String?
    @Published var showRenumbered = false
    /// 기본 접힘에서 손으로 바꾼 마디 (`파일키|경로`). 기본은 셋째 단계부터 접는다.
    @Published var toggled: Set<String> = []
    /// "모두 펼치기"(false)·"모두 접기"(true)를 누른 뒤의 기준. nil이면 셋째 단계부터 자동으로 접는다.
    @Published var foldAll: Bool?

    func setAllFolded(_ folded: Bool) {
        foldAll = folded
        toggled = []
        if !folded { foldedProjects = [] }
    }
    /// 접어 둔 프로젝트
    @Published var foldedProjects: Set<String> = []
    @Published var showsHidden = false
    /// 사이드바에서 끌고 있는 프로젝트·즐겨찾기
    @Published var draggingProject: String?
    @Published var draggingFavorite: String?
    /// 화면 비교: 0 나란히, 1 이전만 크게, 2 이후만 크게
    @Published var compareMode = 0
    /// 끌어서 바꾼 칸 너비. 다음에 열 때도 그대로 둔다.
    @Published var sidebarWidth: CGFloat = DesignHistoryPage.stored("design.sidebarWidth", DesignHistoryView.sidebarWidth) {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "design.sidebarWidth") }
    }
    @Published var timelineWidth: CGFloat = DesignHistoryPage.stored("design.timelineWidth", DesignHistoryView.timelineWidth) {
        didSet { UserDefaults.standard.set(Double(timelineWidth), forKey: "design.timelineWidth") }
    }

    private static func stored(_ key: String, _ fallback: CGFloat) -> CGFloat {
        (UserDefaults.standard.object(forKey: key) as? Double).map { CGFloat($0) } ?? fallback
    }
    /// 설정의 디자인 칸으로 가 달라는 신호. 앱 창이 받아 설정 화면을 연다.
    @Published var showsSettings = false
    /// 그때 열 칸 (연결 또는 알림).
    var settingsSection: DesignSettingsView.Section = .figma

    func openSettings(_ section: DesignSettingsView.Section) {
        settingsSection = section
        showsSettings = true
    }

    /// 링크를 더하고 받는 중. 사이드바 링크 단추가 돈다.
    @Published var addingLink = false

    /// 피그마에서 복사한 링크를 더하고, 받은 뒤 그 화면을 연다. 이미 받은 화면이면 바로 연다.
    func addLink(_ text: String, sync: DesignSync) {
        guard text.contains("figma.com/") else {
            flash(text.isEmpty ? "클립보드가 비어 있습니다. 피그마에서 ‘링크 복사’를 해 오세요" : "클립보드에 피그마 링크가 없습니다")
            return
        }
        guard !addingLink else { return }
        addingLink = true
        Task {
            let result = await sync.addLink(text)
            switch result {
            case .failure(let problem):
                addingLink = false
                flash(problem.message)
            case .success(let link):
                flash(link.needsFetch ? link.message + " · 가져오는 중…" : link.message)
                guard link.needsFetch else {
                    addingLink = false
                    open(link, sync: sync)
                    return
                }
                sync.sync(only: link.fileKey) { [weak self] _ in
                    guard let self else { return }
                    self.addingLink = false
                    if let error = sync.errors[link.fileKey] { self.flash(error) }
                    self.open(link, sync: sync)
                }
            }
        }
    }

    /// 링크한 화면을 상세로 연다. 화면을 못 찾았으면 그 프로젝트만 보인다.
    private func open(_ link: DesignSync.AddedLink, sync: DesignSync) {
        if project != nil { project = link.fileKey }
        scope = .project(fileKey: link.fileKey)
        foldedProjects.remove(link.fileKey)
        if let node = link.nodeID, let screen = sync.screen(for: node, in: link.fileKey) { self.screen = screen.frameID }
    }

    /// 변경 보기(완료 후·작업 중·전체)인지. 사이드바에서는 한 줄로, 목록 머리에서 셋으로 나눠 고른다.
    var showsChanges: Bool { [.important, .working, .all].contains(scope) }

    func flash(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            withAnimation { if self?.toast == message { self?.toast = nil } }
        }
    }
}

/// 디자인 화면: 왼쪽 메뉴 트리, 가운데 날짜별 변경, 오른쪽 상세. 업무 일지와 같은 종이·회색 규칙으로 그린다.
struct DesignHistoryView: View {
    @ObservedObject var sync: DesignSync
    @ObservedObject var settings: DesignSyncSettings
    @ObservedObject var page: DesignHistoryPage
    @ObservedObject var compare = DesignCompareModel.shared
    /// 앱 창에서 숨겨 둔 동안에는 false. 다시 보일 때 오래됐으면 새로 받는다.
    var isActive = true
    /// 화면 점검(`--ui-shots`)에서는 가져오지 않는다.
    var autoStart = true

    static let sidebarWidth: CGFloat = 256
    static let timelineWidth: CGFloat = 344

    /// 상세가 이보다 좁아지면 단추·비교 글이 답답해져서, 창이 좁으면 목록 칸부터 줄인다.
    static let detailMinWidth: CGFloat = 360
    /// 상세 글은 이보다 넓어지지 않는다. 더 넓으면 줄이 길어 읽기 어렵다.
    static let detailMaxWidth: CGFloat = 1100
    static let sidebarRange: ClosedRange<CGFloat> = 190...480
    static let timelineRange: ClosedRange<CGFloat> = 260...800

    var body: some View {
        GeometryReader { geo in
            let sidebar = min(page.sidebarWidth, max(Self.sidebarRange.lowerBound, geo.size.width - Self.timelineRange.lowerBound - Self.detailMinWidth - 2))
            let timeline = min(page.timelineWidth, max(Self.timelineRange.lowerBound, geo.size.width - sidebar - Self.detailMinWidth - 2))
            HStack(spacing: 0) {
                DesignSidebar(sync: sync, settings: settings, page: page)
                    .frame(width: sidebar)
                ColumnDivider(width: $page.sidebarWidth, range: Self.sidebarRange, standard: Self.sidebarWidth)
                if settings.sources.isEmpty && sync.history.files.isEmpty {
                    DesignOnboarding(settings: settings, page: page)
                } else {
                    Group {
                        if page.scope == .compare {
                            DesignCompareView(sync: sync, page: page, model: compare)
                        } else {
                            let scoped = screenScope
                            DesignTimeline(sync: sync, page: page, events: events, screenFile: scoped?.fileKey, screens: scoped?.screens ?? [],
                                           allScreens: scoped?.all ?? [])
                        }
                    }
                    .frame(width: timeline)
                    ColumnDivider(width: $page.timelineWidth, range: Self.timelineRange, standard: Self.timelineWidth)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .bottomTrailing) { stepper.padding(16) }
                }
            }
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .bottom) {
            if let toast = page.toast { Toast(message: toast).padding(.bottom, 18).transition(.opacity) }
        }
        .sheet(item: Binding(get: { page.alertPicker.map(AlertPickerTarget.init) }, set: { page.alertPicker = $0?.id })) { target in
            DesignAlertPicker(sync: sync, fileKey: target.id)
        }
        .onAppear { if autoStart && isActive { sync.syncIfStale() } }
        .onChange(of: settings.sources) { sources in
            // 지우거나 숨긴 프로젝트를 고른 채 빈 화면이 남지 않게 한다
            let visible = sources.filter { !$0.isHidden }.map(\.fileKey)
            if let project = page.project, !visible.contains(project) { page.project = visible.first }
        }
        .onChange(of: isActive) { if $0 && autoStart { sync.syncIfStale() } }
        .onChange(of: page.stepRequest) { _ in step(1) }
    }

    private struct AlertPickerTarget: Identifiable { let id: String }

    // MARK: 거르기

    private var events: [DesignEvent] {
        let query = page.search.trimmingCharacters(in: .whitespaces).lowercased()
        return sync.history.events.filter { event in
            // 숨긴 프로젝트·메뉴는 어느 보기에서도 빼고, 맨 아래 숨긴 항목에서만 다시 켠다
            if sync.isHidden(event) { return false }
            if let project = page.project, event.fileKey != project { return false }
            // 반영을 마친 변경은 "반영 완료" 보기에만 남긴다
            if sync.history.isApplied(event) != (page.scope == .applied) { return false }
            switch page.scope {
            case .project(let key): if event.fileKey != key { return false }
            case .all, .applied: break
            case .compare: return false
            // 알림 받을 메뉴를 고른 프로젝트는 그 메뉴의 변경만 본다. 다른 메뉴는 "전체"에서 본다
            case .important: if !event.isImportant || !sync.follows(event) { return false }
            case .working: if event.isImportant || !sync.follows(event) { return false }
            case .menu(let key, let path): if event.fileKey != key || (event.menuPath != path && !(event.menus ?? []).contains(path)) { return false }
            case .group(let key, let head): if event.fileKey != key || !event.concerns(head) { return false }
            }
            if let layer = page.layer, !event.changes.contains(where: { $0.layer == layer && $0.op != .renumbered }) { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([event.screenID, event.title, event.menuPath, event.note ?? ""]
                + event.changes.flatMap { [$0.label, $0.before ?? "", $0.after ?? ""] }).joined(separator: "\n").lowercased()
            return haystack.contains(query)
        }
    }

    /// 메뉴·묶음·프로젝트를 고르면 바뀐 적 없는 화면도 목록에 보인다. 숨긴 메뉴는 빼고 찾는 말로 거른다.
    private var screenScope: (fileKey: String, screens: [ScreenSnapshot], all: [ScreenSnapshot])? {
        let found: (String, [ScreenSnapshot])
        switch page.scope {
        case .menu(let key, let path): found = (key, sync.screens(key, under: path, exact: true))
        case .group(let key, let head): found = (key, sync.screens(key, under: head))
        case .project(let key): found = (key, sync.screens(key))
        default: return nil
        }
        let source = sync.source(found.0)
        let query = page.search.trimmingCharacters(in: .whitespaces).lowercased()
        let screens = found.1.filter { screen in
            guard source?.hides(screen.menuPath) != true else { return false }
            if page.hidesBuiltScreens, !screen.items.isEmpty,
               sync.history.built(screen, in: found.0).count == screen.items.count,
               sync.pendingEvents(for: screen, in: found.0).isEmpty { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([screen.screenID, screen.title, screen.menuPath, screen.requirementID]
                + screen.items.map(\.text) + Array(screen.texts.values)).joined(separator: "\n").lowercased()
            return haystack.contains(query)
        }
        return (found.0, screens, found.1.filter { source?.hides($0.menuPath) != true })
    }

    // MARK: 넘기기

    /// 가운데에 보이는 것이 화면 목록인지. 화면을 고르고 있거나 메뉴 보기의 화면 탭이면 화면을 넘긴다.
    private var steppingScreens: Bool {
        page.screen != nil || (page.selected == nil && page.scope.fileKey != nil && page.menuTab == .screens && !(screenScope?.screens.isEmpty ?? true))
    }

    private var stepOrder: [String] {
        steppingScreens ? DesignTimeline.grouped(screenScope?.screens ?? []).flatMap { $0.screens.map(\.frameID) }
            : DesignHistory.days(events).flatMap(\.events).map(\.id.uuidString)
    }

    private var stepIndex: Int? {
        let current = steppingScreens ? page.screen : page.selected?.uuidString
        return current.flatMap { stepOrder.firstIndex(of: $0) }
    }

    /// 목록 순서대로 앞뒤 화면이나 변경으로 넘긴다. 아무것도 고르지 않았으면 처음 것을 연다.
    private func step(_ delta: Int) {
        let order = stepOrder
        guard !order.isEmpty else { return }
        // 고른 것이 목록에 없으면(찾기로 빠짐) 아래로만 첫 항목을 연다
        guard let next = stepIndex.map({ $0 + delta }) ?? (delta > 0 ? 0 : nil) else { return }
        guard order.indices.contains(next) else { return }
        if steppingScreens {
            page.screen = order[next]
        } else if let id = UUID(uuidString: order[next]) {
            page.selected = id
            page.showRenumbered = false
            sync.markSeen([id])
        }
    }

    /// 상세 오른쪽 아래의 앞뒤 단추. ⌥↑·⌥↓로도 넘긴다.
    @ViewBuilder private var stepper: some View {
        let order = stepOrder
        if order.count > 1 && page.scope != .compare {
            let index = stepIndex
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "chevron.up").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .keyboardShortcut(page.searchFocused ? nil : KeyboardShortcut(.upArrow, modifiers: .option))
                    .disabled((index ?? 0) <= 0)
                    .tip(steppingScreens ? "이전 화면 (⌥↑)" : "이전 변경 (⌥↑)")
                Text(index.map { "\($0 + 1) / \(order.count)" } ?? "– / \(order.count)")
                    .font(WL.number).foregroundStyle(WL.muted).frame(minWidth: 52)
                Button { step(1) } label: { Image(systemName: "chevron.down").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .keyboardShortcut(page.searchFocused ? nil : KeyboardShortcut(.downArrow, modifiers: .option))
                    .disabled((index ?? -1) >= order.count - 1)
                    .tip(steppingScreens ? "다음 화면 (⌥↓)" : "다음 변경 (⌥↓)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(WL.text)
            .padding(.horizontal, 6)
            .background(Capsule().fill(WL.surface).shadow(color: .black.opacity(0.12), radius: 6, y: 2))
            .overlay(Capsule().strokeBorder(WL.border, lineWidth: 1))
        }
    }

    // MARK: 상세

    @ViewBuilder private var detail: some View {
        if let frame = page.screen, let key = screenScope?.fileKey, let screen = sync.history.files[key]?.screens[frame] {
            DesignScreenDetail(fileKey: key, screen: screen, sync: sync, page: page)
                .id(key + frame)
        } else if let id = page.selected,
                  let event = sync.history.events.first(where: { $0.id == id }) ?? compare.currentResult?.events.first(where: { $0.id == id }),
                  // 다른 프로젝트를 보는 동안, 날짜 비교에서는 지금 결과 밖의 변경이 상세에 남지 않게 한다
                  page.scope == .compare ? compare.shownEvents.contains { $0.id == id } : (page.project == nil || event.fileKey == page.project) {
            DesignEventDetail(event: event, seen: sync.history.isSeen(event), sync: sync, page: page,
                              toggleSeen: {
                                  if sync.history.isSeen(event) { sync.markUnseen(event.id) } else { sync.markSeen([event.id]) }
                              },
                              toggleApplied: { toggleApplied(event) })
                .id(event.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.squares.leading").font(.system(size: 28, weight: .light)).foregroundStyle(WL.muted)
                Text(screenScope == nil ? "변경을 고르면 바뀐 내용이 여기에 나옵니다" : "변경이나 화면을 고르면 여기에 나옵니다").font(WL.body).foregroundStyle(WL.muted)
                Text("⌥↓ 를 누르면 목록의 첫 항목부터 차례로 엽니다").font(WL.meta).foregroundStyle(WL.muted)
                let unseen = events.filter { $0.isImportant && !sync.history.isSeen($0) }
                if !unseen.isEmpty {
                    Button("보이는 변경 \(unseen.count)건 모두 본 것으로 표시") { sync.markSeen(unseen.map(\.id)) }
                        .buttonStyle(NotionButtonStyle())
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 반영 완료로 넘기면 목록에서 바로 아래 변경을 골라 이어서 고치게 한다.
    private func toggleApplied(_ event: DesignEvent) {
        if sync.history.isApplied(event) {
            sync.setApplied(event.id, false)
            page.flash("반영 완료를 풀었습니다. 다시 목록에 나옵니다")
            return
        }
        let order = DesignHistory.days(events).flatMap(\.events)
        let index = order.firstIndex { $0.id == event.id }
        sync.setApplied(event.id, true)
        if page.scope != .applied, let index {
            let next = order.indices.contains(index + 1) ? order[index + 1] : index > 0 ? order[index - 1] : nil
            page.selected = next?.id
            if let next { sync.markSeen([next.id]) }
        }
        page.flash("반영 완료로 넘겼습니다. 사이드바 ‘반영 완료’에서 다시 볼 수 있습니다")
    }

    /// 자주 보는 것부터. 헤더 표의 화면명·경로·작성자는 개발 용어 대신 "화면 정보"라 부른다.
    static let layerOrder: [SpecChange.Layer] = [.spec, .text, .header, .component]

    static func layerName(_ layer: SpecChange.Layer) -> String {
        switch layer {
        case .spec: return "기능 명세"
        case .text: return "목업 문구"
        case .header: return "화면 정보"
        case .component: return "컴포넌트"
        }
    }
}

// MARK: - 메뉴 트리

/// 화면 경로(`데이터셋 > 목록 > 상세`)를 마디마다 나눈 트리. 하위가 하나뿐인 마디는 `워크플로우 › DAG`처럼 한 줄로 합쳐
/// 좁은 사이드바에서 들여쓰기가 너무 깊어지지 않게 한다.
enum DesignMenuTree {
    struct Node: Identifiable {
        var name: String
        /// 이 마디까지의 화면 경로. 아래 화면을 거를 때 앞부분으로 쓴다.
        var path: String
        /// 이 경로에 바로 걸린 메뉴 (화면이나 이력)
        var own: DesignHistory.Menu?
        var children: [Node]

        var id: String { path }
        var unseen: Int { (own?.unseen ?? 0) + children.reduce(0) { $0 + $1.unseen } }
        var screens: Int { (own?.screenCount ?? 0) + children.reduce(0) { $0 + $1.screens } }
        var lastChange: Date? { ([own?.lastChange] + children.map(\.lastChange)).compactMap { $0 }.max() }
    }

    /// 트리를 위에서부터 펼친 한 줄.
    struct Row: Identifiable {
        enum Kind { case node, own }
        let node: Node
        let depth: Int
        /// `.own`은 하위가 있는 마디에 바로 걸린 기록(이력·공통 화면)을 따로 보이는 줄이다
        let kind: Kind
        var id: String { node.path + (kind == .own ? "#own" : "") }
    }

    static func head(_ path: String) -> String {
        path.components(separatedBy: " > ").first?.trimmingCharacters(in: .whitespaces) ?? path
    }

    /// `compact`가 false면 하위가 하나뿐인 마디도 합치지 않는다 (알림 고르기처럼 마디마다 따로 켜고 끌 때).
    static func build(_ menus: [DesignHistory.Menu], compact merges: Bool = true) -> [Node] {
        var roots: [Node] = []
        for menu in menus.sorted(by: { $0.path < $1.path }) {
            insert(menu, menu.path.components(separatedBy: " > ")[...], prefix: "", into: &roots)
        }
        return merges ? roots.map(compact) : roots
    }

    private static func insert(_ menu: DesignHistory.Menu, _ parts: ArraySlice<String>, prefix: String, into nodes: inout [Node]) {
        guard let first = parts.first else { return }
        let path = prefix.isEmpty ? first : prefix + " > " + first
        let index: Int
        if let found = nodes.firstIndex(where: { $0.name == first }) {
            index = found
        } else {
            nodes.append(Node(name: first, path: path, own: nil, children: []))
            index = nodes.count - 1
        }
        if parts.count == 1 { nodes[index].own = menu } else { insert(menu, parts.dropFirst(), prefix: path, into: &nodes[index].children) }
    }

    private static func compact(_ node: Node) -> Node {
        var node = node
        while node.own == nil, node.children.count == 1 {
            let child = node.children[0]
            node = Node(name: node.name + " › " + child.name, path: child.path, own: child.own, children: child.children)
        }
        node.children = node.children.map(compact)
        return node
    }

    /// 접힌 마디 아래는 건너뛰고 펼친다.
    static func rows(_ nodes: [Node], depth: Int = 0, folded: (Node, Int) -> Bool) -> [Row] {
        nodes.flatMap { node -> [Row] in
            // 자기 화면과 하위 화면이 함께 있는 메뉴는 그 줄 하나가 둘 다를 모은다 (따로 "이 화면" 줄을 두지 않는다)
            var rows = [Row(node: node, depth: depth, kind: .node)]
            if !node.children.isEmpty, !folded(node, depth) {
                rows += self.rows(node.children, depth: depth + 1, folded: folded)
            }
            return rows
        }
    }
}

// MARK: - 사이드바

private struct DesignSidebar: View {
    @ObservedObject var sync: DesignSync
    @ObservedObject var settings: DesignSyncSettings
    @ObservedObject var page: DesignHistoryPage
    @StateObject private var hover = HoveredKey()
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if visibleFiles.count > 1 || page.project != nil { projectSwitcher }
            HStack(spacing: 6) {
                searchField
                linkButton
            }
            VStack(spacing: 1) {
                // 알림 메뉴·작업 중·전체는 목록 머리에서 고른다. 여기서는 확인 안 한 건수만 보인다
                row(key: "changes", icon: "tray.full", title: "변경", count: sync.unseenCount(in: page.project), badge: true,
                    scope: page.showsChanges ? page.scope : .important, selected: page.showsChanges)
                    .tip("화면설계서에 생긴 변경. 파란 숫자는 알림 받는 메뉴(고르지 않았으면 전체)에서 확인하지 않은 변경입니다")
                row(key: "applied", icon: "checkmark.circle", title: "반영 완료", count: appliedCount, badge: false, scope: .applied)
                    .tip("마크업에 반영을 마친 변경. 상세에서 반영 완료를 풀면 다시 목록에 나옵니다")
                row(key: "compare", icon: "calendar.badge.clock", title: "날짜 비교", count: 0, badge: false, scope: .compare)
                    .tip("두 날짜 사이에 바뀐 디자인을 피그마 버전 기록으로 견줍니다")
            }
            SlimScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    alertsSection
                    favoritesSection
                    if !shownFiles.isEmpty { treeControls }
                    if let project = page.project, let file = shownFiles.first(where: { $0.key == project }) {
                        // 한 프로젝트만 보면 프로젝트 머리줄 없이 메뉴만 둔다. 프로젝트 동작은 위 전환 메뉴에 있다
                        fileSection(file, header: false)
                    } else {
                        ForEach(shownFiles, id: \.key) { file in fileSection(file, header: true) }
                    }
                    hiddenSection
                }
                .padding(.bottom, 8)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WL.sidebar)
    }

    private var appliedCount: Int {
        guard let project = page.project else { return sync.history.applied.count }
        return sync.history.events.filter { $0.fileKey == project && sync.history.isApplied($0) }.count
    }

    /// 숨기지 않은 프로젝트.
    private var visibleFiles: [(key: String, name: String)] { files.filter { !(sync.source($0.key)?.isHidden ?? false) } }

    /// 사이드바에 그릴 프로젝트. 한 프로젝트를 고르면 그것만.
    private var shownFiles: [(key: String, name: String)] {
        guard let project = page.project else { return visibleFiles }
        return visibleFiles.filter { $0.key == project }
    }

    // MARK: 프로젝트 전환

    /// 프로젝트를 하나씩 본다. 셋을 한꺼번에 펼치면 메뉴가 섞여 찾기 어렵다. 고른 프로젝트의 동작(가져오기 주기 등)도 여기 있다.
    private var projectSwitcher: some View {
        HStack(spacing: 4) {
            Menu {
                Button((page.project == nil ? "✓ " : "") + "모든 프로젝트") { page.project = nil }
                Divider()
                ForEach(visibleFiles, id: \.key) { file in
                    let unseen = sync.unseenCount(in: file.key)
                    Button((page.project == file.key ? "✓ " : "") + sync.projectName(file.key) + (unseen > 0 ? "  · 확인할 변경 \(unseen)" : "")) {
                        page.project = file.key
                    }
                }
                if let key = page.project, let file = visibleFiles.first(where: { $0.key == key }) {
                    Divider()
                    projectActions(file)
                }
            } label: {
                HStack(spacing: 8) {
                    if let key = page.project {
                        ProjectSwatch(name: sync.projectName(key))
                    } else {
                        Image(systemName: "square.stack").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(page.project.map(sync.projectName) ?? "모든 프로젝트").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let key = page.project, sync.source(key)?.scope.isEmpty == false {
                        Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(WL.muted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            .tip(page.project.map { "\(sync.source($0)?.name ?? sync.projectName($0))\n다른 프로젝트로 바꾸거나 이 프로젝트의 가져오기 주기·상태 판단을 정합니다" }
                 ?? "프로젝트를 하나 고르면 그 프로젝트의 메뉴와 변경만 봅니다")
            if let key = page.project, sync.source(key) != nil { fetchButton(key, name: sync.projectName(key)) }
        }
    }

    // MARK: 알림 받는 메뉴

    /// 🔔를 켠 메뉴를 한곳에 모은다. 무엇을 알림 받는지 바로 보이고, 눌러서 그 메뉴로 간다.
    @ViewBuilder private var alertsSection: some View {
        let keys = shownFiles.map(\.key).filter { sync.source($0) != nil }
        let items = keys.flatMap { key in (sync.source(key)?.alerts ?? []).filter { !$0.isEmpty }.map { (fileKey: key, path: $0) } }
        if !keys.isEmpty && keys.contains(where: { sync.history.files[$0] != nil }) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    SectionLabel("알림 받는 메뉴")
                    Spacer(minLength: 4)
                    alertPickButton(keys)
                }
                .padding(.leading, 6).padding(.bottom, 3)
                if items.isEmpty {
                    // 고르지 않아도 모든 변경을 보므로 자리를 적게 차지하는 한 줄로 둔다
                    Button { pickAlerts(keys) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 14)
                            Text("맡은 메뉴 고르기").font(.system(size: 13.5))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(WL.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(hover.key == "alerts-pick" ? WL.hover : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hover.update("alerts-pick", $0) }
                    .tip(keys.count == 1 ? "고른 메뉴가 없어 이 프로젝트의 모든 변경을 봅니다.\n맡은 메뉴를 고르면 그 메뉴의 변경만 모아 보고 알림도 그것만 옵니다."
                                         : "맡은 메뉴를 고르면 그 메뉴의 변경만 모아 보고 알림도 그것만 옵니다.")
                }
                ForEach(items, id: \.path) { item in alertRow(fileKey: item.fileKey, path: item.path) }
            }
        }
    }

    private func pickAlerts(_ keys: [String]) {
        guard let key = keys.first(where: { sync.history.files[$0] != nil }) else { return }
        page.alertPicker = key
    }

    @ViewBuilder private func alertPickButton(_ keys: [String]) -> some View {
        if keys.count == 1 {
            Button { pickAlerts(keys) } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(GhostIconButtonStyle())
                .disabled(sync.history.files[keys[0]] == nil)
                .tip("알림 받을 메뉴 고르기")
        } else {
            Menu {
                ForEach(keys, id: \.self) { key in
                    Button(sync.projectName(key)) { page.alertPicker = key }.disabled(sync.history.files[key] == nil)
                }
            } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 24, height: 24)
                .tip("알림 받을 메뉴 고르기")
        }
    }

    private func alertRow(fileKey: String, path: String) -> some View {
        let hasChildren = sync.history.files[fileKey]?.screens.values.contains { $0.menuPath.hasPrefix(path + " > ") } == true
        let target: DesignHistoryPage.Scope = hasChildren ? .group(fileKey: fileKey, head: path) : .menu(fileKey: fileKey, path: path)
        let selected = page.scope == target
        let key = "a:" + fileKey + path
        let project = sync.projectName(fileKey)
        let unseen = sync.history.events.filter { $0.fileKey == fileKey && $0.concerns(path) && $0.isImportant
            && !sync.history.isSeen($0) && !sync.isHidden($0) }.count
        return Button { page.scope = target } label: {
            HStack(spacing: 7) {
                Image(systemName: "bell.fill").font(.system(size: 11)).foregroundStyle(WL.accent).frame(width: 14)
                Text(path.components(separatedBy: " > ").last ?? path).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if page.project == nil && visibleFiles.count > 1 {
                    Text(project).font(WL.caption).foregroundStyle(WL.projectColor(project)).lineLimit(1)
                }
                Spacer(minLength: 4)
                badge(unseen, fallback: nil)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(selected ? WL.hover.opacity(1.8) : hover.key == key ? WL.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update(key, $0) }
        .tip("\(project) · \(DesignFormat.path(path))" + (hasChildren ? "\n아래 메뉴 모두, 앞으로 생길 화면까지 알림" : ""))
        .contextMenu {
            Button("알림 끄기") { sync.setAlert(path, on: false, in: fileKey) }
            Button("알림 받을 메뉴 고르기…") { page.alertPicker = fileKey }
        }
    }

    // MARK: 찾기

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            TextField("찾기", text: $page.search)
                .textFieldStyle(.plain)
                .font(WL.meta)
                .focused($searching)
                .onChange(of: searching) { page.searchFocused = $0 }
                .onExitCommand { page.search = ""; searching = false }
            if !page.search.isEmpty {
                Button { page.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(WL.muted) }
                    .buttonStyle(.plain)
                    .tip("찾는 말 지우기 (esc)")
            } else if !searching {
                Text("⌘F").font(WL.caption).foregroundStyle(WL.muted)
            }
        }
        .background {
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        .tip("화면 ID·화면명·명세·문구에서 찾습니다")
    }

    /// 피그마에서 ‘링크 복사’한 화면을 붙여 넣으면 그 화면만 가져와 바로 연다.
    private var linkButton: some View {
        Button { page.addLink(NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", sync: sync) } label: {
            Group {
                if page.addingLink { ProgressView().controlSize(.small) } else { Image(systemName: "link").font(.system(size: 13, weight: .semibold)).foregroundStyle(WL.accent) }
            }
            .frame(width: 28, height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(page.addingLink || !settings.hasToken)
        .tip(settings.hasToken ? "피그마 링크 붙여넣기 (⇧⌘V)\n피그마에서 화면을 오른쪽 클릭 > ‘링크 복사’한 주소를 넣으면 그 화면만 가져와 바로 엽니다"
                               : "피그마 토큰을 넣은 뒤에 쓸 수 있습니다")
    }

    /// 경로(묶음이면 그 아래 전부) 화면들의 상태. 모두 완료면 초록, 작업 중이 있으면 주황.
    private func state(_ fileKey: String, _ path: String) -> ScreenState? {
        let screens = sync.history.files[fileKey]?.screens.values.filter { DesignStatus.covers(path, $0.menuPath) } ?? []
        guard !screens.isEmpty else { return nil }
        let states = screens.map { sync.state(of: $0, in: fileKey) }
        if states.allSatisfy({ $0 == .done }) { return .done }
        return states.contains(.working) ? .working : .unknown
    }

    private func alerting(_ fileKey: String, _ path: String) -> Bool {
        settings.sources.first { $0.fileKey == fileKey }?.alerts(path) == true
    }

    private func statusDot(_ state: ScreenState?) -> some View {
        Circle()
            .fill(state == .done ? WL.done : state == .working ? WL.waiting : Color.secondary.opacity(0.35))
            .frame(width: 6, height: 6)
            .tip(state == .done ? "완료" : state == .working ? "작업 중이 있음" : "상태 표시 없음")
    }

    /// 이 줄에 직접 켰거나 마우스를 올렸을 때만 보이는 종. 묶음에 켠 알림은 묶음 줄에만 보여 이름 자리를 아낀다.
    @ViewBuilder private func bell(_ fileKey: String, _ path: String, hovered: Bool) -> some View {
        let on = alerting(fileKey, path)
        let own = sync.source(fileKey)?.alerts.contains(path) == true
        if own || hovered {
            Button { sync.setAlert(path, on: !on, in: fileKey) } label: {
                Image(systemName: on ? "bell.fill" : "bell")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(on ? WL.accent : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(on ? "알림 끄기" : "완료된 화면이 바뀌면 알림 받기")
        }
    }

    @ViewBuilder private func menuActions(_ fileKey: String, _ path: String) -> some View {
        let on = alerting(fileKey, path)
        Button(on ? "알림 끄기" : "알림 받기") { sync.setAlert(path, on: !on, in: fileKey) }
        Divider()
        let manual = settings.sources.first { $0.fileKey == fileKey }?.statusOverrides[path]
        Button(manual == true ? "✓ 완료로 보기" : "완료로 보기") { sync.setStatus(path, done: true, in: fileKey) }
        Button(manual == false ? "✓ 작업 중으로 보기" : "작업 중으로 보기") { sync.setStatus(path, done: false, in: fileKey) }
        if manual != nil { Button("섹션 표시대로 보기") { sync.setStatus(path, done: nil, in: fileKey) } }
    }

    // MARK: 파일과 메뉴

    /// 설정에 있는 파일과, 기록만 남아 있는 파일.
    private var files: [(key: String, name: String)] {
        let listed = settings.sources.map { (key: $0.fileKey, name: $0.name.isEmpty ? $0.fileKey : $0.name) }
        let recorded = sync.history.files.filter { key, _ in !settings.sources.contains { $0.fileKey == key } }
            .map { (key: $0.key, name: $0.value.name) }.sorted { $0.name < $1.name }
        return listed + recorded
    }

    /// 숨긴 메뉴를 뺀 그 프로젝트의 트리.
    private func tree(_ fileKey: String) -> [DesignMenuTree.Node] {
        let source = sync.source(fileKey)
        let menus = sync.history.menus().filter { $0.fileKey == fileKey && !$0.path.isEmpty && source?.hides($0.path) != true }
        return DesignMenuTree.build(menus)
    }

    private func fileSection(_ file: (key: String, name: String), header: Bool) -> some View {
        let nodes = tree(file.key)
        let rows = DesignMenuTree.rows(nodes) { node, depth in folded(node, depth, fileKey: file.key) }
        let collapsed = header && page.foldedProjects.contains(file.key)
        return VStack(alignment: .leading, spacing: 1) {
            if header { projectHeader(file, nodes: nodes, collapsed: collapsed) }
            if !collapsed {
                if rows.isEmpty {
                    Text(sync.history.files[file.key] == nil ? (sync.syncing ? "처음 가져오는 중…" : "아직 가져오지 않았습니다") : "보이는 메뉴가 없습니다")
                        .font(WL.caption).foregroundStyle(.secondary).padding(.leading, 28).padding(.vertical, 4)
                }
                ForEach(rows) { row in treeRow(row, fileKey: file.key) }
            }
        }
        .opacity(page.draggingProject == file.key ? 0.4 : 1)
    }

    /// 프로젝트 머리줄: 업무 일지와 같은 색 네모와 짧은 이름. 끌어서 프로젝트 순서를 바꾼다.
    private func projectHeader(_ file: (key: String, name: String), nodes: [DesignMenuTree.Node], collapsed: Bool) -> some View {
        let name = sync.projectName(file.key)
        let target = DesignHistoryPage.Scope.project(fileKey: file.key)
        let selected = page.scope == target
        let key = "p:" + file.key
        let unseen = sync.history.events.filter { $0.fileKey == file.key && $0.isImportant && !sync.history.isSeen($0) && !sync.isHidden($0) }.count
        return HStack(spacing: 4) {
            Button {
                if collapsed { page.foldedProjects.remove(file.key) } else { page.foldedProjects.insert(file.key) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 14, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .tip(collapsed ? "펼치기" : "접기")
            Button { page.scope = target } label: {
                HStack(spacing: 7) {
                    ProjectSwatch(name: name)
                    Text(name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if sync.source(file.key)?.scope.isEmpty == false {
                        // 링크한 화면만 지켜보는 프로젝트
                        Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(WL.muted)
                    }
                    Spacer(minLength: 4)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip("\(file.name)" + (sync.source(file.key).map { $0.scope.isEmpty ? "" : "\n링크한 화면 \($0.scope.count)개만 지켜봅니다 · 오른쪽 클릭으로 전체 지켜보기" } ?? "")
                 + "\n누르면 이 프로젝트의 변경만 봅니다 · 끌어서 순서 바꾸기")
            // 가져오기 단추는 올려 두거나 받는 동안만 보여 목록을 어지럽히지 않는다
            if sync.source(file.key) != nil && (hover.key == key || sync.isBusy(file.key)) {
                fetchButton(file.key, name: name)
            }
            badge(unseen, fallback: collapsed ? nodes.reduce(0) { $0 + $1.screens } : nil)
        }
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
            .fill(selected ? WL.hover.opacity(1.8) : hover.key == key ? WL.hover : .clear))
        .onHover { hover.update(key, $0) }
        .reorderable(file.key, dragging: $page.draggingProject) { from, to in sync.moveProject(from, to: to) }
        .contextMenu { projectActions(file) }
    }

    /// 프로젝트 머리줄 오른쪽 클릭과 프로젝트 전환 메뉴에 같이 쓰는 동작.
    @ViewBuilder private func projectActions(_ file: (key: String, name: String)) -> some View {
        let name = sync.projectName(file.key)
        if page.project != file.key {
            Button("이 프로젝트만 보기") { page.project = file.key }
        }
        Button("날짜별로 비교…") { DesignCompareModel.shared.open(fileKey: file.key, path: nil); page.scope = .compare }
        Button("지금 가져오기") { fetch(file.key, name: name) }
            .disabled(sync.isBusy(file.key) || !settings.hasToken)
        if let url = URL(string: "https://www.figma.com/design/\(file.key)") {
            Button("피그마에서 열기") { NSWorkspace.shared.open(url) }
        }
        if let source = sync.source(file.key), !source.scope.isEmpty {
            Button("프로젝트 전체 지켜보기") {
                sync.widen(file.key)
                fetch(file.key, name: name)
            }
            .disabled(sync.isBusy(file.key) || !settings.hasToken)
        }
        Button("알림 받을 메뉴 고르기…") { page.alertPicker = file.key }
            .disabled(sync.history.files[file.key] == nil)
        Menu("상태 표시가 없는 화면") {
            let current = sync.source(file.key)?.untaggedIsDone
            let global = settings.untaggedIsDone.map { $0 ? "완료로 봄" : "작업 중으로 봄" } ?? "판단하지 않음"
            Button((current == nil ? "✓ " : "") + "전체 설정대로 (\(global))") { sync.setUntaggedIsDone(nil, for: file.key) }
            Button((current == true ? "✓ " : "") + "완료로 보기") { sync.setUntaggedIsDone(true, for: file.key) }
            Button((current == false ? "✓ " : "") + "작업 중으로 보기") { sync.setUntaggedIsDone(false, for: file.key) }
        }
        Menu("가져오기 주기") {
            ForEach(DesignSync.projectIntervals.indices, id: \.self) { index in
                let minutes = DesignSync.projectIntervals[index]
                let current = sync.source(file.key)?.intervalMinutes
                Button((current == minutes ? "✓ " : "") + sync.intervalLabel(minutes)) { sync.setInterval(minutes, for: file.key) }
            }
        }
        Divider()
        Button("프로젝트 숨기기") {
            sync.setProjectHidden(file.key, hidden: true)
            if page.project == file.key { page.project = visibleFiles.first { $0.key != file.key }?.key }
            page.flash("‘\(name)’를 숨겼습니다. 숨긴 동안은 가져오지 않습니다")
        }
    }

    private func fetchButton(_ fileKey: String, name: String) -> some View {
        Button { fetch(fileKey, name: name) } label: {
            if sync.fetching == fileKey {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: sync.isBusy(fileKey) ? "clock" : "arrow.down.circle")
            }
        }
        .buttonStyle(GhostIconButtonStyle())
        .disabled(sync.isBusy(fileKey) || !settings.hasToken)
        .tip(fetchTip(fileKey, name: name))
    }

    private func fetchTip(_ fileKey: String, name: String) -> String {
        if sync.fetching == fileKey { return "‘\(name)’ 가져오는 중" }
        if sync.isBusy(fileKey) { return "앞 프로젝트를 받은 뒤 가져옵니다" }
        let checked = sync.lastChecked(fileKey)
        let last = checked == .distantPast ? "아직 가져오지 않음" : DesignFormat.stamp(checked) + " 확인"
        let minutes = sync.source(fileKey).map(sync.interval(for:)) ?? 0
        let schedule = minutes == 0 ? "누를 때만 가져옴" : sync.intervalLabel(minutes) + " 자동"
        return "‘\(name)’ 지금 가져오기\n\(last) · \(schedule)"
    }

    private func fetch(_ fileKey: String, name: String) {
        sync.sync(only: fileKey) { count in
            page.flash(count > 0 ? "‘\(name)’ 변경 \(count)건을 찾았습니다" : "‘\(name)’ 새 변경이 없습니다")
        }
    }

    /// 지금 보는 범위가 한 프로젝트 안이면 그 프로젝트.
    private var scopedFileKey: String? {
        switch page.scope {
        case .project(let key), .menu(let key, _), .group(let key, _): return sync.source(key) == nil ? nil : key
        default: return page.project.flatMap { sync.source($0) == nil ? nil : $0 }
        }
    }

    /// 메뉴나 묶음을 보고 있고 그 메뉴만 받을 수 있으면 그 메뉴. ⌘R이 그 메뉴만 받는다.
    private var scopedMenu: (fileKey: String, path: String)? {
        switch page.scope {
        case .menu(let key, let path), .group(let key, let path): return sync.canFetchMenu(key, path) ? (key, path) : nil
        default: return nil
        }
    }

    /// 메뉴 트리를 한 번에 펼치거나 접는다.
    private var treeControls: some View {
        HStack(spacing: 2) {
            SectionLabel("메뉴")
            Button { withAnimation(.easeOut(duration: 0.15)) { page.setAllFolded(false) } } label: {
                Image(systemName: "arrow.up.and.line.horizontal.and.arrow.down")
            }
            .buttonStyle(GhostIconButtonStyle())
            .tip("모든 메뉴 펼치기")
            Button { withAnimation(.easeOut(duration: 0.15)) { page.setAllFolded(true) } } label: {
                Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
            }
            .buttonStyle(GhostIconButtonStyle())
            .tip("모든 메뉴 접기 (첫 단계만 남김)")
        }
        .padding(.leading, 6)
        .padding(.bottom, -8)
    }

    // MARK: 즐겨찾기

    /// 프로젝트가 달라도 자주 보는 메뉴를 한곳에 모은다. 끌어서 순서를 바꾼다.
    @ViewBuilder private var favoritesSection: some View {
        let items = settings.favorites.compactMap { key -> (key: String, fileKey: String, path: String)? in
            guard let bar = key.firstIndex(of: "|") else { return nil }
            let fileKey = String(key[..<bar]), path = String(key[key.index(after: bar)...])
            guard sync.source(fileKey)?.hides(path) != true, sync.history.files[fileKey] != nil,
                  page.project == nil || page.project == fileKey else { return nil }
            return (key, fileKey, path)
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                SectionLabel("즐겨찾기").padding(.leading, 6).padding(.bottom, 3)
                ForEach(items, id: \.key) { item in favoriteRow(item.key, fileKey: item.fileKey, path: item.path) }
            }
        }
    }

    private func favoriteRow(_ id: String, fileKey: String, path: String) -> some View {
        let hasChildren = sync.history.files[fileKey]?.screens.values.contains { $0.menuPath.hasPrefix(path + " > ") } == true
        let target: DesignHistoryPage.Scope = hasChildren ? .group(fileKey: fileKey, head: path) : .menu(fileKey: fileKey, path: path)
        let selected = page.scope == target
        let key = "f:" + id
        let project = sync.projectName(fileKey)
        let unseen = sync.history.events.filter { $0.fileKey == fileKey && DesignStatus.covers(path, $0.menuPath)
            && $0.isImportant && !sync.history.isSeen($0) }.count
        return Button { page.scope = target } label: {
            HStack(spacing: 7) {
                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color.yellow.opacity(0.85)).frame(width: 14)
                Text(path.components(separatedBy: " > ").last ?? path).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if page.project == nil && settings.sources.filter({ !$0.isHidden }).count > 1 {
                    Text(project).font(WL.caption).foregroundStyle(WL.projectColor(project)).lineLimit(1)
                }
                Spacer(minLength: 4)
                badge(unseen, fallback: nil)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(selected ? WL.hover.opacity(1.8) : hover.key == key ? WL.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update(key, $0) }
        .tip("\(project) · \(DesignFormat.path(path))\n끌어서 순서 바꾸기")
        .reorderable(id, dragging: $page.draggingFavorite) { from, to in sync.moveFavorite(from, to: to) }
        .opacity(page.draggingFavorite == id ? 0.4 : 1)
        .contextMenu {
            Button("즐겨찾기에서 빼기") { sync.toggleFavorite(fileKey, path) }
        }
    }

    // MARK: 숨긴 항목

    /// 숨긴 프로젝트와 메뉴는 접힌 묶음 하나로 모은다. 눈 단추로 다시 보인다.
    @ViewBuilder private var hiddenSection: some View {
        let projects = settings.sources.filter(\.isHidden)
        let menus = settings.sources.filter { !$0.isHidden }.flatMap { source in source.hiddenMenus.map { (source.fileKey, $0) } }
        let count = projects.count + menus.count
        if count > 0 {
            VStack(alignment: .leading, spacing: 1) {
                Button { page.showsHidden.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(page.showsHidden ? 90 : 0)).frame(width: 14)
                        Text("숨긴 항목 \(count)").font(WL.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if page.showsHidden {
                    ForEach(projects) { source in
                        hiddenRow(sync.projectName(source.fileKey), detail: "프로젝트 · 가져오지 않음") {
                            sync.setProjectHidden(source.fileKey, hidden: false)
                        }
                    }
                    ForEach(menus, id: \.1) { fileKey, path in
                        hiddenRow(path.components(separatedBy: " > ").last ?? path, detail: sync.projectName(fileKey) + " · " + DesignFormat.path(path)) {
                            sync.setMenuHidden(path, hidden: false, in: fileKey)
                        }
                    }
                }
            }
        }
    }

    private func hiddenRow(_ title: String, detail: String, show: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: show) { Image(systemName: "eye") }
                .buttonStyle(GhostIconButtonStyle())
                .tip("다시 보이기")
        }
        .padding(.leading, 26)
        .frame(height: 30)
        .tip(detail)
    }

    /// 둘째 단계까지 펼치고 그 아래는 접는다. 확인 안 한 변경이 있거나 고른 메뉴가 안에 있으면 펼친다.
    private func folded(_ node: DesignMenuTree.Node, _ depth: Int, fileKey: String) -> Bool {
        let auto = depth >= 1 && node.unseen == 0 && !holdsSelection(node, fileKey: fileKey)
        return (page.foldAll ?? auto) != page.toggled.contains(fileKey + "|" + node.path)
    }

    private func holdsSelection(_ node: DesignMenuTree.Node, fileKey: String) -> Bool {
        switch page.scope {
        case .menu(let key, let path), .group(let key, let path):
            return key == fileKey && path != node.path && DesignStatus.covers(node.path, path)
        default:
            return false
        }
    }

    private func treeRow(_ row: DesignMenuTree.Row, fileKey: String) -> some View {
        let node = row.node
        let parent = !node.children.isEmpty
        let key = "t:" + fileKey + "|" + row.id
        let target: DesignHistoryPage.Scope = parent
            ? .group(fileKey: fileKey, head: node.path)
            : .menu(fileKey: fileKey, path: node.own?.path ?? node.path)
        let selected = page.scope == target
        let isFolded = parent && folded(node, row.depth, fileKey: fileKey)
        let screens = node.screens
        return HStack(spacing: 4) {
            if parent {
                Button {
                    let toggle = fileKey + "|" + node.path
                    if page.toggled.contains(toggle) { page.toggled.remove(toggle) } else { page.toggled.insert(toggle) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        .frame(width: 14, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .tip(isFolded ? "펼치기" : "접기")
            } else {
                Color.clear.frame(width: 14, height: 30)
            }
            Button { page.scope = target } label: {
                HStack(spacing: 7) {
                    if screens > 0 { statusDot(state(fileKey, node.path)) } else { Color.clear.frame(width: 6, height: 6) }
                    // 지금 화면이 없는 줄은 이유를 붙인다: 지워진 화면이면 "삭제됨", 페이지 이력만 있으면 "이력"
                    (Text(node.name) + Text(screens == 0 ? "  " + emptyReason(fileKey, node.path) : "").font(WL.caption).foregroundColor(WL.faint))
                        .font(.system(size: 13.5, weight: selected ? .semibold : parent ? .medium : .regular))
                        .foregroundStyle(screens == 0 ? WL.muted : WL.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 좁은 사이드바에서 잘리는 이름도 전체 경로를 툴팁으로 보인다
            .tip(rowTip(node, screens: screens))
            if screens > 0 { menuFetchButton(fileKey, node.path, name: node.name, hovered: hover.key == key) }
            if screens > 0 { bell(fileKey, node.path, hovered: hover.key == key) }
            badge(node.unseen, fallback: isFolded ? screens : nil)
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 12)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
            .fill(selected ? WL.hover.opacity(1.8) : hover.key == key ? WL.hover : .clear))
        .onHover { hover.update(key, $0) }
        .contextMenu {
            if sync.canFetchMenu(fileKey, node.path) {
                Button("이 메뉴만 가져오기") { fetchMenu(fileKey, node.path, name: node.name) }
                    .disabled(sync.isBusy(fileKey, menu: node.path) || !settings.hasToken)
                Divider()
            }
            Button(sync.isFavorite(fileKey, node.path) ? "즐겨찾기에서 빼기" : "즐겨찾기에 넣기") { sync.toggleFavorite(fileKey, node.path) }
            Button("날짜별로 비교…") { DesignCompareModel.shared.open(fileKey: fileKey, path: node.path); page.scope = .compare }
            if screens > 0 { menuActions(fileKey, node.path) }
            Divider()
            Button("숨기기") {
                sync.setMenuHidden(node.path, hidden: true, in: fileKey)
                page.flash("‘\(node.name)’를 숨겼습니다. 맨 아래 숨긴 항목에서 다시 보입니다")
            }
        }
    }

    /// 올려 두거나 받는 동안만 보이는 ↓. 그 메뉴 화면이 있는 페이지만 받는다.
    @ViewBuilder private func menuFetchButton(_ fileKey: String, _ path: String, name: String, hovered: Bool) -> some View {
        let busy = sync.isBusy(fileKey, menu: path)
        if sync.canFetchMenu(fileKey, path) && (hovered || busy) {
            Button { fetchMenu(fileKey, path, name: name) } label: {
                if busy && sync.fetchingMenu?.fileKey == fileKey { ProgressView().controlSize(.mini) }
                else { Image(systemName: busy ? "clock" : "arrow.down.circle") }
            }
            .buttonStyle(GhostIconButtonStyle())
            .disabled(busy || !settings.hasToken)
            .tip(busy ? "가져오는 중이거나 차례를 기다립니다" : "‘\(name)’만 가져오기\n이 메뉴 화면이 있는 페이지만 봐서 프로젝트 전체보다 빠르고 피그마 요청이 적습니다")
        }
    }

    private func fetchMenu(_ fileKey: String, _ path: String, name: String) {
        sync.syncMenu(path, in: fileKey) { count in
            page.flash(count > 0 ? "‘\(name)’ 변경 \(count)건을 찾았습니다" : "‘\(name)’ 새 변경이 없습니다")
        }
    }

    /// 화면이 없는 경로에 남은 변경이 지운 화면인지, 페이지 이력인지.
    private func emptyReason(_ fileKey: String, _ path: String) -> String {
        let kinds = Set(sync.history.events.filter { $0.fileKey == fileKey && $0.menuPath == path }.map(\.kind))
        return kinds.contains(.removed) ? "삭제됨" : "이력"
    }

    private func rowTip(_ node: DesignMenuTree.Node, screens: Int) -> String {
        let detail = [screens > 0 ? "화면 \(screens)개" : node.own.map { emptyReason($0.fileKey, $0.path) == "삭제됨" ? "지워진 화면" : "페이지 제·개정 이력" },
                      node.lastChange.map { "마지막 변경 " + DesignFormat.stamp($0) }].compactMap { $0 }.joined(separator: " · ")
        return DesignFormat.path(node.own?.path ?? node.path) + "\n" + detail
    }

    private func row(key: String, icon: String, title: String, count: Int, badge showsBadge: Bool,
                     scope target: DesignHistoryPage.Scope, selected: Bool? = nil) -> some View {
        let selected = selected ?? (page.scope == target)
        return Button { page.scope = target } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .medium)).foregroundStyle(showsBadge ? WL.accent : .secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if showsBadge { badge(count, fallback: nil) }
                else if count > 0 { Text("\(count)").font(WL.number).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(selected ? WL.hover.opacity(1.8) : hover.key == key ? WL.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update(key, $0) }
    }

    /// 확인 안 한 변경은 파란 알약, 없으면 옅은 숫자(접은 묶음의 화면 수).
    @ViewBuilder private func badge(_ unseen: Int, fallback: Int?) -> some View {
        if unseen > 0 {
            Text("\(unseen)").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                .background(Capsule().fill(WL.accent))
        } else if let fallback, fallback > 0 {
            Text("\(fallback)").font(WL.number).foregroundStyle(WL.muted)
        }
    }

    // MARK: 연동 상태

    private var footer: some View {
        HStack(spacing: 4) {
            Button { page.openSettings(.figma) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(problem != nil ? WL.waiting : settings.hasToken && !settings.sources.isEmpty ? WL.done : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text("피그마").font(WL.caption)
                        Spacer(minLength: 4)
                        Text(problem != nil ? "확인 필요" : schedule).font(WL.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(status).font(WL.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                    .fill(hover.key == "footer" ? WL.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover.update("footer", $0) }
            .tip(problem ?? "피그마 연동 설정")
            Button {
                if let (key, path) = scopedMenu {
                    fetchMenu(key, path, name: path.components(separatedBy: " > ").last ?? path)
                } else if let key = scopedFileKey {
                    fetch(key, name: sync.projectName(key))
                } else {
                    sync.sync { count in page.flash(count > 0 ? "변경 \(count)건을 찾았습니다" : "새 변경이 없습니다") }
                }
            } label: {
                if sync.syncing { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(GhostIconButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(sync.syncing || settings.sources.isEmpty || !settings.hasToken)
            .tip(scopedMenu.map { "‘\($0.path.components(separatedBy: " > ").last ?? $0.path)’ 메뉴만 가져오기 (⌘R)" }
                 ?? scopedFileKey.map { "‘\(sync.projectName($0))’ 가져오기 (⌘R)" } ?? "숨기지 않은 프로젝트 모두 가져오기 (⌘R)\n하나만 받으려면 프로젝트에 올려 ↓를 누르세요")
        }
    }

    private var problem: String? {
        sync.errors["*"] ?? settings.sources.lazy.compactMap { source in sync.errors[source.fileKey].map { "\(source.name): \($0)" } }.first
    }

    private var schedule: String {
        let automatic = sync.automaticCount
        return automatic == 0 ? "누를 때만" : "자동 \(automatic)개"
    }

    private var status: String {
        if sync.syncing {
            let waiting = sync.queued.isEmpty ? "" : " · 대기 \(sync.queued.count)개"
            return (sync.progress.isEmpty ? "가져오는 중…" : sync.progress) + waiting
        }
        if !settings.hasToken { return "토큰을 넣어야 가져옵니다" }
        if settings.sources.isEmpty { return "지켜볼 화면설계서가 없습니다" }
        // 손으로 받는 프로젝트는 언제 받았는지가 중요해, 보는 프로젝트(없으면 가장 최근) 기준으로 적는다
        if let key = scopedFileKey {
            let checked = sync.lastChecked(key)
            return sync.projectName(key) + " · " + (checked == .distantPast ? "아직 가져오지 않았습니다" : DesignFormat.stamp(checked) + "에 확인")
        }
        return sync.history.files.values.map(\.syncedAt).max().map { DesignFormat.stamp($0) + "에 확인" } ?? "아직 확인하지 않았습니다"
    }
}

// MARK: - 처음 화면

private struct DesignOnboarding: View {
    @ObservedObject var settings: DesignSyncSettings
    @ObservedObject var page: DesignHistoryPage

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "paintpalette").font(.system(size: 30, weight: .light)).foregroundStyle(WL.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("화면설계서의 변경을 메뉴별로 모읍니다").font(WL.title)
                Text("피그마 화면설계서를 연결하면 어느 메뉴의 어느 화면이 언제 바뀌었는지 날짜별로 남깁니다. 기능 명세, 목업 문구, 컴포넌트, 디자이너가 적은 제·개정 이력까지 봅니다.")
                    .font(WL.body).foregroundStyle(WL.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                step(1, "피그마 토큰 넣기", "피그마 설정 > Security > Personal access tokens에서 file_content:read 범위로 만듭니다. 날짜 비교까지 쓰려면 file_versions:read도 더합니다.", done: settings.hasToken)
                RowDivider()
                step(2, "링크 붙여넣기", "작업할 화면을 피그마에서 오른쪽 클릭 > ‘링크 복사’해 넣으면 그 화면만, 파일 주소를 넣으면 프로젝트 전체를 가져옵니다.", done: !settings.sources.isEmpty)
                RowDivider()
                step(3, "필요할 때 가져오기", "처음 가져온 상태가 기준이 되고, 프로젝트의 ↓를 누를 때마다 바뀐 것을 기록합니다. 주기를 정하면 저절로 받습니다.", done: false)
            }
            .wlSurface()
            HStack(spacing: 8) {
                if settings.hasToken {
                    Button(page.addingLink ? "가져오는 중…" : "복사한 링크 붙여넣기") {
                        page.addLink(NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", sync: .shared)
                    }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .disabled(page.addingLink)
                    Button("설정 열기") { page.openSettings(.figma) }.buttonStyle(NotionButtonStyle())
                } else {
                    Button("피그마 연결하기") { page.openSettings(.figma) }
                        .buttonStyle(NotionButtonStyle(kind: .primary))
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: Int, _ title: String, _ detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? WL.done : WL.callout)
                if done { Image(systemName: "checkmark").font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(WL.number).foregroundStyle(WL.muted) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(WL.heading)
                Text(detail).font(WL.meta).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// MARK: - 타임라인

struct DesignTimeline: View {
    @ObservedObject var sync: DesignSync
    @ObservedObject var page: DesignHistoryPage
    let events: [DesignEvent]
    /// 고른 메뉴의 지금 시안 화면과 그 프로젝트.
    var screenFile: String?
    var screens: [ScreenSnapshot] = []
    /// 찾기·끝난 화면 숨기기로 거르기 전의 화면. 작업대 요약은 메뉴 전체로 세고, 찾는 말에 맞는 화면이 없어도 화면 탭은 남긴다.
    var allScreens: [ScreenSnapshot] = []
    private var hasScreens: Bool { !allScreens.isEmpty }

    /// 메뉴·묶음·프로젝트를 고른 보기. 마크업할 곳이라 가져오기·진행·Claude 문구를 위에 두고 화면과 변경을 탭으로 나눈다.
    private var workspace: Bool { screenFile != nil }

    /// 화면이 없는 경로(지운 화면·이력만 남은 줄)는 변경만 있다.
    private var tab: DesignHistoryPage.MenuTab { hasScreens ? page.menuTab : .changes }

    /// 메뉴·묶음이면 그 경로. 프로젝트면 nil.
    private var menuPath: String? {
        switch page.scope {
        case .menu(_, let path), .group(_, let path): return path
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(WL.title).lineLimit(1).truncationMode(.middle)
                        .tip(fullTitle)
                    Spacer()
                    if !workspace { Text(summary).font(WL.meta).foregroundStyle(WL.muted) }
                }
                if let screenFile { workbench(screenFile) }
                HStack(spacing: 8) {
                    if page.showsChanges { phasePicker }
                    if workspace && hasScreens { tabPicker }
                    if workspace && hasScreens && tab == .screens {
                        Toggle("끝난 화면 숨기기", isOn: $page.hidesBuiltScreens)
                            .toggleStyle(.checkbox).font(WL.meta).foregroundStyle(WL.muted).lineLimit(1).fixedSize()
                            .tip("기능 명세를 모두 구현 체크했고 반영할 변경도 없는 화면을 목록에서 뺍니다")
                    }
                    Spacer(minLength: 0)
                    if tab == .changes { layerMenu }
                }
            }
            .padding(.horizontal, WL.gutter)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Rectangle().fill(WL.border).frame(height: 1)
            let days = DesignHistory.days(events)
            if workspace && tab == .screens {
                SlimScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if screens.isEmpty {
                            Text("찾는 말에 맞는 화면이 없습니다").font(WL.meta).foregroundStyle(WL.muted)
                                .padding(.horizontal, WL.gutter).padding(.top, 12)
                        }
                        screenList
                    }
                    .padding(.top, 8).padding(.bottom, 16)
                }
            } else if days.isEmpty {
                empty
            } else {
                SlimScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.events) { event in
                                    DesignEventRow(event: event, seen: sync.history.isSeen(event), selected: page.selected == event.id,
                                                   project: showsProject ? sync.projectName(event.fileKey) : nil,
                                                   progress: sync.history.progress(event)) {
                                        page.selected = event.id
                                        page.showRenumbered = false
                                        sync.markSeen([event.id])
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(DesignFormat.day(day.day)).font(WL.label).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(day.events.count)건").font(WL.label).foregroundStyle(WL.muted)
                                }
                                .padding(.horizontal, WL.gutter)
                                .padding(.top, 12).padding(.bottom, 6)
                                .background(WL.canvas)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: 메뉴 작업대

    /// 화면 수·구현 진행·반영할 변경·확인 시각과, 이 메뉴만 가져오기·메뉴 Claude 문구 단추.
    private func workbench(_ fileKey: String) -> some View {
        let items = allScreens.reduce(into: (built: 0, total: 0)) { sum, screen in
            sum.built += sync.history.built(screen, in: fileKey).count
            sum.total += screen.items.count
        }
        let pending = allScreens.reduce(0) { $0 + sync.pendingEvents(for: $1, in: fileKey).count }
        let checked: Date? = menuPath.map { sync.menuChecked(fileKey, $0) } ?? {
            let last = sync.lastChecked(fileKey)
            return last == .distantPast ? nil : last
        }()
        let stats = [allScreens.isEmpty ? nil : "화면 \(allScreens.count)",
                     items.total > 0 ? "구현 \(items.built)/\(items.total)" : nil,
                     pending > 0 ? "반영할 변경 \(pending)" : nil,
                     checked.map { DesignFormat.stamp($0) + " 확인" } ?? "아직 가져오지 않음"].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 8) {
            if let path = menuPath, path.contains(" > ") {
                Text(DesignFormat.path(path)).font(WL.meta).foregroundStyle(WL.muted).lineLimit(1).truncationMode(.head)
            }
            Text(stats.joined(separator: " · ")).font(WL.meta).foregroundStyle(WL.muted).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // 칸이 좁으면 짧은 이름으로 바꿔 단추가 칸 밖으로 밀리지 않게 한다
            ViewThatFits(in: .horizontal) {
                actionButtons(fileKey, pending: pending, unbuilt: items.built < items.total, compact: false)
                actionButtons(fileKey, pending: pending, unbuilt: items.built < items.total, compact: true)
            }
        }
    }

    private func actionButtons(_ fileKey: String, pending: Int, unbuilt: Bool, compact: Bool) -> some View {
        HStack(spacing: 6) {
            if sync.source(fileKey) != nil { fetchButton(fileKey, compact: compact) }
            Button {
                DesignCompareModel.shared.open(fileKey: fileKey, path: menuPath)
                page.scope = .compare
            } label: { Image(systemName: "calendar.badge.clock").frame(width: 14) }
            .buttonStyle(NotionButtonStyle())
            .tip("기간 비교: 이 " + (menuPath == nil ? "프로젝트" : "메뉴") + "에서 며칠 동안 바뀐 화면을 모아 보고 Claude 문구로 넘깁니다")
            if pending > 0, let path = menuPath {
                Button {
                    NSPasteboard.general.clearContents()
                    let prompt = sync.claudePrompt(menu: path, in: fileKey)
                    NSPasteboard.general.setString(prompt, forType: .string)
                    page.flash(DesignFormat.copied(prompt))
                } label: { Label(compact ? "변경 \(pending)건 문구" : "변경 \(pending)건 Claude 문구", systemImage: "sparkles") }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .tip("이 메뉴 화면들의 반영하지 않은 변경을 화면별로 묶어 복사합니다. 반영 체크한 항목은 빼고, 전체 명세 대신 화면마다 피그마 링크를 넣어 짧게 만듭니다")
            } else if unbuilt, let path = menuPath {
                Button {
                    NSPasteboard.general.clearContents()
                    let prompt = sync.claudeBuildPrompt(menu: path, in: fileKey)
                    NSPasteboard.general.setString(prompt, forType: .string)
                    page.flash(DesignFormat.copied(prompt))
                } label: { Label(compact ? "마크업 문구" : "메뉴 마크업 Claude 문구", systemImage: "sparkles") }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .tip("이 메뉴 화면마다 피그마 링크·참고·남은 기능 명세를 묶어 복사합니다. 목업 문구와 배치는 Claude가 피그마 MCP로 읽게 해 글을 줄이고, 구현을 마친 화면은 뺍니다")
            }
            Spacer(minLength: 0)
        }
    }

    /// 메뉴를 고르면 그 메뉴 화면이 있는 페이지만, 프로젝트면 프로젝트 전체를 받는다.
    private func fetchButton(_ fileKey: String, compact: Bool = false) -> some View {
        let menu = menuPath.flatMap { sync.canFetchMenu(fileKey, $0) ? $0 : nil }
        let busy = menu.map { sync.isBusy(fileKey, menu: $0) } ?? sync.isBusy(fileKey)
        return Button {
            let name = menu.map { $0.components(separatedBy: " > ").last ?? $0 } ?? sync.projectName(fileKey)
            let done: (Int) -> Void = { count in page.flash(count > 0 ? "‘\(name)’ 변경 \(count)건을 찾았습니다" : "‘\(name)’ 새 변경이 없습니다") }
            if let menu { sync.syncMenu(menu, in: fileKey, completion: done) } else { sync.sync(only: fileKey, completion: done) }
        } label: {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.down.circle") }
                Text(busy ? (sync.syncing && (sync.fetchingMenu != nil || sync.fetching == fileKey) ? "가져오는 중…" : "차례 기다리는 중")
                     : menu == nil || compact ? "가져오기" : "이 메뉴 가져오기")
            }
        }
        .buttonStyle(NotionButtonStyle())
        .disabled(busy || !DesignSyncSettings.shared.hasToken)
        .tip(menu == nil ? "‘\(sync.projectName(fileKey))’ 프로젝트를 가져옵니다 (⌘R)"
             : "이 메뉴 화면이 있는 페이지만 살펴보고 이 메뉴 화면만 받습니다 (⌘R). 프로젝트 전체보다 피그마 요청이 훨씬 적습니다.\n다른 페이지에 새로 생긴 화면은 프로젝트를 가져와야 보입니다")
    }

    private var tabPicker: some View {
        Picker("", selection: $page.menuTab) {
            Text(screens.count == allScreens.count ? "화면 \(screens.count)" : "화면 \(screens.count)/\(allScreens.count)")
                .tag(DesignHistoryPage.MenuTab.screens)
            Text(events.isEmpty ? "변경" : "변경 \(events.count)").tag(DesignHistoryPage.MenuTab.changes)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .tip("화면: 지금 시안의 화면과 구현 진행\n변경: 이 메뉴에 기록한 변경")
    }

    /// 지금 시안 화면. 묶음이나 프로젝트처럼 메뉴가 여럿이면 메뉴마다 작은 머리를 단다.
    @ViewBuilder private var screenList: some View {
        if let screenFile {
            let notes = Self.duplicateNotes(screens)
            let groups = Self.grouped(screens)
            ForEach(groups, id: \.path) { group in
                if groups.count > 1 {
                    Text(DesignFormat.path(relative(group.path)))
                        .font(WL.label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .padding(.horizontal, WL.gutter).padding(.top, 12).padding(.bottom, 4)
                        .tip(DesignFormat.path(group.path))
                }
                ForEach(group.screens, id: \.frameID) { screen in
                    DesignScreenRow(screen: screen, state: sync.state(of: screen, in: screenFile), note: notes[screen.frameID],
                                    changes: sync.pendingEvents(for: screen, in: screenFile).count,
                                    built: sync.history.built(screen, in: screenFile).count,
                                    selected: page.screen == screen.frameID) {
                        page.screen = screen.frameID
                    }
                    .contextMenu {
                        Button("날짜별로 비교…") { DesignScreenDetail.compareDates(fileKey: screenFile, screen: screen, page: page) }
                        if let url = FigmaFileURL.link(fileKey: screenFile, nodeID: screen.frameID) {
                            Button("피그마에서 열기") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
        }
    }

    /// 경로 순으로 정렬된 화면을 경로마다 묶는다.
    static func grouped(_ screens: [ScreenSnapshot]) -> [(path: String, screens: [ScreenSnapshot])] {
        var groups: [(path: String, screens: [ScreenSnapshot])] = []
        for screen in screens {
            if groups.last?.path == screen.menuPath { groups[groups.count - 1].screens.append(screen) } else { groups.append((screen.menuPath, [screen])) }
        }
        return groups
    }

    /// 묶음 안에서는 묶음 이름을 뺀 나머지 경로만 보인다.
    private func relative(_ path: String) -> String {
        guard let head = menuPath, path.hasPrefix(head + " > ") else { return path }
        return String(path.dropFirst(head.count + 3))
    }

    /// 같은 화면 ID를 쓰는 프레임(상태별 화면 등)을 가를 이름. 프레임 이름이 다르면 그것을, 같으면 순번을 붙인다.
    static func duplicateNotes(_ screens: [ScreenSnapshot]) -> [String: String] {
        var notes: [String: String] = [:]
        for group in Dictionary(grouping: screens, by: \.screenID).values where group.count > 1 {
            let names = Set(group.map(\.frameName))
            for (index, screen) in group.enumerated() {
                let name = SpecExtractor.stripStatus(screen.frameName)
                notes[screen.frameID] = names.count == group.count && name != screen.screenID ? name : "같은 ID \(index + 1)/\(group.count)"
            }
        }
        return notes
    }

    private var title: String {
        switch page.scope {
        case .all, .important, .working: return "변경"
        case .applied: return "반영 완료"
        case .compare: return "날짜 비교"
        case .menu(_, let path): return path.components(separatedBy: " > ").last ?? path
        case .group(_, let head): return head.components(separatedBy: " > ").last ?? head
        case .project(let key): return sync.projectName(key)
        }
    }

    /// 프로젝트가 둘 이상 보일 때만 줄마다 어느 프로젝트인지 붙인다.
    private var showsProject: Bool {
        if case .project = page.scope { return false }
        if case .menu = page.scope { return false }
        if case .group = page.scope { return false }
        return Set(events.map(\.fileKey)).count > 1
    }

    /// 제목은 마지막 마디만 보여서, 툴팁에는 전체 경로를 둔다.
    private var fullTitle: String {
        switch page.scope {
        case .menu(_, let path), .group(_, let path): return DesignFormat.path(path)
        default: return title
        }
    }

    private var summary: String {
        let today = events.filter { Calendar.current.isDateInToday($0.detectedAt) }.count
        return [events.isEmpty ? nil : "\(events.count)건", today > 0 ? "오늘 \(today)" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// 완료 후 변경이 처음 보이는 목록이고, 작업 중 변경과 전체는 여기서 고른다.
    private var phasePicker: some View {
        let open = sync.history.events.filter { event in
            !sync.history.isApplied(event) && (page.project == nil || event.fileKey == page.project) && sync.follows(event)
        }
        let working = open.filter { !$0.isImportant }.count
        return Picker("", selection: $page.scope) {
            Text(hasAlerts ? "알림 메뉴" : "확인할 변경").tag(DesignHistoryPage.Scope.important)
            Text(working > 0 ? "작업 중 \(working)" : "작업 중").tag(DesignHistoryPage.Scope.working)
            Text("전체").tag(DesignHistoryPage.Scope.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .tip((hasAlerts ? "알림 메뉴: 알림 받는 메뉴의" : "확인할 변경:") + " 완료 후 변경·막 완료된 화면·상태 모르는 화면의 변경·디자이너가 적은 이력\n작업 중: 작업 중 표시가 붙은 화면의 변경 (같은 날 것은 한 건으로)\n전체: 메뉴와 상태를 가리지 않은 변경 전부")
    }

    /// 보이는 프로젝트에 알림 받는 메뉴가 하나라도 있는지.
    private var hasAlerts: Bool {
        DesignSyncSettings.shared.sources.contains { !$0.isHidden && !$0.alerts.isEmpty && (page.project == nil || $0.fileKey == page.project) }
    }

    /// 변경 종류로 거른다. 칩 다섯 개 대신 메뉴 하나로 두고, 고르면 이름이 강조색으로 바뀐다.
    private var layerMenu: some View {
        Menu {
            Button((page.layer == nil ? "✓ " : "") + "모든 종류") { page.layer = nil }
            Divider()
            ForEach(DesignHistoryView.layerOrder, id: \.self) { layer in
                Button((page.layer == layer ? "✓ " : "") + DesignHistoryView.layerName(layer) + " 변경만") { page.layer = layer }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11.5, weight: .semibold))
                Text(page.layer.map(DesignHistoryView.layerName) ?? "모든 종류").font(.system(size: 13, weight: page.layer == nil ? .regular : .semibold))
            }
            .foregroundStyle(page.layer == nil ? WL.muted : WL.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("기능 명세·목업 문구·화면 정보·컴포넌트 가운데 하나만 봅니다")
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: sync.history.events.isEmpty ? "clock.arrow.circlepath" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 26, weight: .light)).foregroundStyle(WL.muted)
            Text(sync.history.events.isEmpty ? "아직 기록한 변경이 없습니다"
                 : page.project.map { key in !sync.history.events.contains { $0.fileKey == key } } == true ? "이 프로젝트에는 아직 기록한 변경이 없습니다"
                 : "이 조건에 맞는 변경이 없습니다")
                .font(WL.body).foregroundStyle(WL.muted)
            Text(sync.history.events.isEmpty || page.project.map { key in !sync.history.events.contains { $0.fileKey == key } } == true
                 ? "처음 가져온 상태가 기준입니다. 가져오기(↓)를 누를 때마다 그때부터 바뀐 것을 남깁니다. 메뉴를 고르면 지금 시안 화면을 봅니다."
                 : page.scope == .important ? (hasAlerts ? "알림 받는 메뉴에 새 변경이 없습니다. 다른 메뉴는 위 ‘전체’에서 봅니다." : "확인할 변경이 없습니다. 위에서 ‘작업 중’이나 ‘전체’를 골라 보세요.") : "찾는 말이나 변경 종류를 바꿔 보세요.")
                .font(WL.meta).foregroundStyle(WL.muted).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct DesignEventRow: View {
    let event: DesignEvent
    let seen: Bool
    let selected: Bool
    var project: String?
    /// 반영한 항목 수. 손대기 시작한 변경만 줄에 보인다.
    var progress: (done: Int, total: Int) = (0, 0)
    let select: () -> Void
    @StateObject private var hover = HoveredKey()

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                // 미확인 점은 세는 변경(완료 후 변경 등)만 파랗고, 작업 중 변경은 옅게 둔다
                Circle().fill(seen ? Color.clear : event.isImportant ? WL.accent : WL.faint.opacity(0.6))
                    .frame(width: 7, height: 7).padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(DesignFormat.title(event))
                            .font(.system(size: 13.5, weight: seen ? .medium : .semibold)).lineLimit(1)
                            .tip(DesignFormat.title(event))
                        Spacer(minLength: 4)
                        Text(DesignFormat.time(event.detectedAt)).font(WL.number).foregroundStyle(WL.muted)
                    }
                    HStack(spacing: 5) {
                        if let project {
                            ProjectSwatch(name: project, size: 7)
                            Text(project).font(WL.meta).foregroundStyle(WL.text.opacity(0.75)).lineLimit(1).fixedSize()
                        }
                        Text(DesignFormat.subtitle(event))
                            .font(WL.meta).foregroundStyle(WL.muted).lineLimit(1).truncationMode(.tail)
                            .tip([event.screenID, DesignFormat.path(event.menuPath)].filter { !$0.isEmpty }.joined(separator: "\n"))
                    }
                    HStack(spacing: 6) {
                        DesignPhaseBadge(phase: event.phase)
                        Text(event.summary).font(WL.meta).foregroundStyle(WL.muted).lineLimit(1)
                        Spacer(minLength: 0)
                        if progress.done > 0 {
                            Text("반영 \(progress.done)/\(progress.total)").font(WL.label).monospacedDigit()
                                .foregroundStyle(progress.done == progress.total ? WL.done : WL.muted)
                                .fixedSize()
                        }
                        if hover.key == "row", let url = DesignFormat.link(event) {
                            Button { NSWorkspace.shared.open(url) } label: { FigmaMark(height: 12).frame(width: 18, height: 18) }
                                .buttonStyle(.plain)
                                .tip("피그마에서 열기")
                        }
                    }
                }
            }
            // 작업 중 변경은 계속 바뀌는 시안이라 흐리게 두어 완료 후 변경이 먼저 눈에 들어오게 한다
            .opacity(event.isImportant || selected ? 1 : 0.72)
            .padding(.horizontal, WL.gutter - 8)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(selected ? WL.selected : hover.key == "row" ? WL.hover : .clear))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update("row", $0) }
    }
}

/// 바뀔 때의 단계. 완료 후 변경은 파랑, 막 완료됨은 초록, 작업 중은 회색.
struct DesignPhaseBadge: View {
    let phase: DesignEvent.Phase?

    var body: some View {
        if let (text, color) = style {
            Text(text).font(WL.label)
                .foregroundStyle(color)
                .padding(.horizontal, 6).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.12)))
                .tip(tip)
        }
    }

    private var style: (String, Color)? {
        switch phase {
        case .afterDone: return ("완료 후 변경", WL.accent)
        case .completed: return ("완료됨", WL.done)
        case .working: return ("작업 중", WL.quiet)
        case .unmarked: return ("상태 모름", WL.waiting)
        case nil: return nil
        }
    }

    private var tip: String {
        switch phase {
        case .afterDone: return "완료된 시안에 추가 작업이 들어갔습니다"
        case .completed: return "이번 변경으로 완료됐습니다"
        case .unmarked: return "섹션에 완료·작업 중 표시가 없어 상태를 모르는 화면입니다. 알림 받는 메뉴면 알립니다"
        default: return "아직 작업 중인 시안입니다"
        }
    }
}

// MARK: - 상세

private struct DesignEventDetail: View {
    let event: DesignEvent
    let seen: Bool
    @ObservedObject var sync: DesignSync
    @ObservedObject var page: DesignHistoryPage
    let toggleSeen: () -> Void
    let toggleApplied: () -> Void
    @ObservedObject private var images = DesignImages.shared

    var body: some View {
        // 칸을 둘로 나누지 않고 한 칸으로 쌓는다. 너비는 칸 경계를 끌어 정한다
        GeometryReader { geo in
            let width = min(geo.size.width - 64, DesignHistoryView.detailMaxWidth)
            SlimScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    overview(wide: width >= 760, width: width)
                    changeList
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .frame(maxWidth: DesignHistoryView.detailMaxWidth + 64, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var applied: Bool { sync.history.isApplied(event) }
    /// 날짜 비교 결과처럼 기록에 없는 변경은 본 것·반영 표시를 두지 않는다.
    private var stored: Bool { sync.history.events.contains { $0.id == event.id } }
    private var progress: (done: Int, total: Int) { sync.history.progress(event) }
    private var checked: Set<String> { sync.history.checkedKeys(event) }
    private var tree: DesignChangeTree.Node? { DesignChangeTree.mockupChanges(event).map(DesignChangeTree.build) }

    /// 머리, 단추, 안내, 화면 비교.
    /// `width`는 이 칸의 글 너비. 단추 줄이 들어가지 않으면 보조 단추를 아이콘만 남긴다.
    private func overview(wide: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            actions(compact: width < 720)
            if applied {
                callout("checkmark.circle", "마크업에 반영을 마친 변경입니다. 목록과 알림에서 뺐습니다.")
            }
            if event.kind == .changelog, let note = event.note {
                section("디자이너가 적은 이력", count: nil) {
                    Text(note).font(WL.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if event.kind == .replaced, let old = event.note {
                callout("square.on.square", "옛 프레임 ‘\(old)’를 지우고 새 프레임으로 바꿨습니다. 아래는 옛 프레임과 비교한 차이입니다.")
            }
            if DesignSync.shared.isHidden(event) {
                callout("eye.slash", "숨긴 프로젝트나 메뉴의 변경입니다. 목록과 알림에는 나오지 않습니다.")
            }
            if event.kind == .added {
                callout("plus.square.dashed", "처음 보는 화면입니다. 피그마에서 열어 전체를 확인하세요.")
            }
            comparison(wide: wide)
            if event.phase == .completed {
                callout("checkmark.seal", "이번 변경으로 완료 표시가 붙은 화면입니다.")
            } else if event.phase == .unmarked && stored {
                callout("questionmark.circle", "섹션에 완료·작업 중 표시가 없어 상태를 모르는 화면입니다. 같은 날 바뀐 것은 한 건에 모으고, 알림 받는 메뉴면 알립니다. 상태를 알면 오른쪽 ‘상태’에서 정하세요.")
            } else if event.phase == .working && event.kind == .changed && stored {
                callout("pencil.line", "작업 중인 화면입니다. 같은 날 바뀐 것은 이 한 건에 모아 그날 처음 상태와 비교합니다.")
            }
            if event.kind == .removed {
                callout("trash", "화면설계서에서 이 화면이 없어졌습니다. 다른 화면 ID로 옮겨졌는지 확인하세요.")
            }
        }
    }

    /// 바뀐 내용. 목업 문구·컴포넌트는 자리를 알면 레이어 트리로 묶어 명세와 화면 정보 사이에 둔다.
    private var changeList: some View {
        let tree = tree
        return VStack(alignment: .leading, spacing: 22) {
            layerSection(.spec)
            if let tree {
                DesignChangeTreeView(root: tree, fileKey: event.fileKey, page: page, checked: checked,
                                     toggle: { sync.toggleChecked($0, in: event.id) }, checkable: stored)
            } else {
                layerSection(.text)
            }
            layerSection(.header)
            if tree == nil { layerSection(.component) }
            renumbered
        }
    }

    @ViewBuilder private func layerSection(_ layer: SpecChange.Layer) -> some View {
        let changes = event.changes.filter { $0.layer == layer && $0.op != .renumbered }
        if !changes.isEmpty {
            section(DesignHistoryView.layerName(layer), count: changes.count) {
                ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                    if index > 0 { RowDivider(inset: 26) }
                    HStack(alignment: .top, spacing: 8) {
                        if stored {
                            AppliedCheck(on: checked.contains(change.key)) { sync.toggleChecked(change, in: event.id) }
                                .padding(.top, 12)
                        }
                        DesignChangeRow(change: change).opacity(checked.contains(change.key) ? 0.45 : 1)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DesignPhaseBadge(phase: event.phase)
                if !event.screenID.isEmpty {
                    CopyableID(text: event.screenID) { page.flash("‘\($0)’를 복사했습니다") }
                }
                if let url = DesignFormat.link(event) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        FigmaMark(height: 13).padding(4)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(WL.callout))
                    }
                    .buttonStyle(.plain)
                    .tip("피그마에서 이 프레임 열기")
                }
                Spacer(minLength: 8)
                // 좁은 창에서도 단추 줄 끝으로 밀려 사라지지 않게 맨 위에 둔다
                if !applied && stored {
                    Button(seen ? "안 본 것으로 표시" : "본 것으로 표시", action: toggleSeen).buttonStyle(TextLinkButtonStyle())
                        .tip(seen ? "목록에 다시 파란 점을 붙여 나중에 볼 것으로 둡니다" : "확인한 것으로 둡니다")
                }
            }
            title
            breadcrumb
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.system(size: 11.5))
                Text(DesignFormat.window(event))
                Text("·")
                ProjectSwatch(name: DesignSync.shared.projectName(event.fileKey), size: 7)
                Text(DesignSync.shared.projectName(event.fileKey)).lineLimit(1).tip(event.fileName)
            }
            .font(WL.meta).foregroundStyle(WL.muted)
        }
    }

    /// 제목을 눌러도 피그마에서 그 프레임이 열린다.
    @ViewBuilder private var title: some View {
        let text = Text(DesignFormat.title(event)).font(WL.pageTitle)
        if let url = DesignFormat.link(event) {
            Button { NSWorkspace.shared.open(url) } label: { text.multilineTextAlignment(.leading) }
                .buttonStyle(.plain)
                // push·pop은 올린 채 상세가 바뀌면 짝이 어긋나 손가락 모양이 남아서 set으로 바꾼다
                .onHover { inside in (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
                .tip("피그마에서 열기")
        } else {
            text.textSelection(.enabled)
        }
    }

    /// `상품 관리 › 상품 목록`. 경로가 길면 잘리지 않고 다음 줄로 넘어간다.
    private var breadcrumb: some View {
        let parts = event.menuPath.components(separatedBy: " > ")
        return parts.enumerated().reduce(Text("")) { text, item in
            let piece = Text(item.element).foregroundColor(item.offset == parts.count - 1 ? WL.text : WL.muted)
            return item.offset == 0 ? piece : text + Text("  ›  ").foregroundColor(WL.faint) + piece
        }
        .font(WL.body)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func actions(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 칸이 좁으면 단추 이름을 줄이고, 그래도 넘치면 상태 메뉴를 다음 줄로 내린다 (칸 밖으로 밀려 잘리지 않게)
            ViewThatFits(in: .horizontal) {
                actionRow(compact: compact, status: true)
                actionRow(compact: true, status: true)
                VStack(alignment: .leading, spacing: 8) {
                    actionRow(compact: true, status: false)
                    statusMenu
                }
            }
            if progress.total > 0 && !applied && stored { progressBar }
        }
    }

    /// 항목을 체크한 만큼 채운다. 다 채우면 반영 완료로 넘기라고 알린다.
    private var progressBar: some View {
        let ratio = CGFloat(progress.done) / CGFloat(max(progress.total, 1))
        let full = progress.done == progress.total
        return HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(full ? WL.done : WL.accent).frame(width: geo.size.width * ratio)
                }
            }
            .frame(height: 4)
            Text(full ? "모두 반영함 · 반영 완료로 넘기세요" : "반영 \(progress.done)/\(progress.total)")
                .font(WL.label).monospacedDigit()
                .foregroundStyle(full ? WL.done : WL.muted)
                .fixedSize()
        }
    }

    private func actionRow(compact: Bool, status: Bool) -> some View {
        HStack(spacing: 8) {
            if stored {
                Button(action: toggleApplied) {
                    Label(applied ? "반영 완료 풀기" : "반영 완료", systemImage: applied ? "arrow.uturn.backward" : "checkmark.circle")
                }
                .buttonStyle(NotionButtonStyle(kind: applied ? .secondary : .primary))
                .tip(applied ? "다시 목록에 나오게 합니다" : "마크업에 반영했으면 목록에서 빼고 다음 변경으로 넘어갑니다")
            }
            if event.kind != .changelog && event.kind != .removed {
                Button {
                    NSPasteboard.general.clearContents()
                    let prompt = sync.claudePrompt(for: event)
                    NSPasteboard.general.setString(prompt, forType: .string)
                    page.flash(DesignFormat.copied(prompt))
                } label: { Label(compact ? "Claude 문구" : "Claude 문구 복사", systemImage: "sparkles") }
                .buttonStyle(NotionButtonStyle())
                .tip("이 변경을 마크업에 반영해 달라는 글을 복사합니다. 명세는 전·후 원문, 목업 문구는 화면 위치까지 넣고 체크한 항목은 뺍니다. Claude Code에 그대로 붙여 넣으세요")
            }
            if let url = DesignFormat.link(event) {
                let title = event.kind == .changelog ? "이력 표 열기" : "피그마에서 열기"
                Button { NSWorkspace.shared.open(url) } label: {
                    if compact || event.kind != .changelog { FigmaMark(height: 14) } else { HStack(spacing: 7) { FigmaMark(height: 14); Text(title) } }
                }
                .buttonStyle(NotionButtonStyle())
                .tip(title)
            }
            let screen = event.frameID.flatMap { sync.history.files[event.fileKey]?.screens[$0] }
            MoreMenu(tip: "요약 복사·업무 일지에 넣기·날짜별 비교") {
                Button("요약 복사 (레드마인·MR에 붙일 글)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(event.report, forType: .string)
                    page.flash("변경 요약을 복사했습니다")
                }
                if event.kind != .changelog && event.kind != .removed {
                    Button("업무 일지 오늘 칸에 넣기") {
                        page.flash(DesignSync.shared.addToWorkLog(event) ? "업무 일지 오늘 칸에 넣었습니다" : "업무 일지에 넣지 못했습니다")
                    }
                }
                if let screen, event.kind != .changelog {
                    Divider()
                    Button("지금 시안 보기") { page.scope = .menu(fileKey: event.fileKey, path: screen.menuPath); page.screen = screen.frameID }
                    Button("이 화면 날짜별 비교…") { DesignScreenDetail.compareDates(fileKey: event.fileKey, screen: screen, page: page) }
                }
            }
            Spacer(minLength: 0)
            if status { statusMenu }
        }
    }

    /// 이 화면을 완료로 볼지 정하는 메뉴.
    @ViewBuilder private var statusMenu: some View {
        if event.kind != .changelog, let state = screenState {
            Menu {
                Button(state == .done ? "✓ 완료" : "완료") { setStatus(true) }
                Button(state == .working ? "✓ 작업 중" : "작업 중") { setStatus(false) }
                Divider()
                Button("자동 (섹션 표시대로)") { setStatus(nil) }
            } label: {
                Text("상태: " + (state == .done ? "완료" : state == .working ? "작업 중" : "모름")).font(WL.meta)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tip("이 화면의 변경을 알릴지 정하는 상태. 섹션 표시가 틀렸으면 직접 정합니다")
        }
    }

    // MARK: 화면 비교

    /// 바뀌기 전·후 버전 그대로 그린 프레임. 볼 때만 받아 이 Mac에 둔다.
    @ViewBuilder private func comparison(wide: Bool) -> some View {
        if event.kind != .changelog, let frame = event.frameID {
            if event.beforeVersion != nil || event.afterVersion != nil {
                let marks = tree.map(DesignChangeTree.items)?.filter { $0.change.place?.hasBox == true } ?? []
                VStack(alignment: .leading, spacing: 8) {
                    // 좁으면 제목 아래로 조절 단추를 내린다
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { SectionLabel("화면 비교"); comparisonControls(marks: marks) }
                        VStack(alignment: .leading, spacing: 6) { SectionLabel("화면 비교"); HStack(spacing: 10) { comparisonControls(marks: marks) } }
                    }
                    let shown = page.showsMarks ? marks : []
                    switch page.compareMode {
                    case 1: shot("이전", version: event.beforeVersion, frame: event.beforeFrameID ?? frame, marks: shown, maxHeight: wide ? 1400 : 640)
                    case 2: shot("이후", version: event.afterVersion, frame: frame, marks: shown, maxHeight: wide ? 1400 : 640)
                    default:
                        // 넓으면 나란히 두어 한눈에 견주고, 좁으면 위아래로 쌓아 한 장씩 크게 본다
                        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                        layout {
                            shot("이전", version: event.beforeVersion, frame: event.beforeFrameID ?? frame, marks: shown, maxHeight: wide ? 760 : 520)
                            shot("이후", version: event.afterVersion, frame: frame, marks: shown, maxHeight: wide ? 760 : 520)
                        }
                    }
                }
            } else if event.kind == .changed || event.kind == .replaced {
                Text("화면 비교 이미지는 이 기능이 생긴 뒤 기록한 변경부터 볼 수 있습니다.")
                    .font(WL.caption).foregroundStyle(WL.muted)
            }
        }
    }

    /// 바뀐 자리 표시와 둘 다·이전·이후.
    @ViewBuilder private func comparisonControls(marks: [DesignChangeTree.Item]) -> some View {
        Spacer(minLength: 0)
        if !marks.isEmpty {
            Toggle("바뀐 자리 표시", isOn: $page.showsMarks)
                .toggleStyle(.checkbox).font(WL.meta).foregroundStyle(WL.muted)
                .lineLimit(1).fixedSize()
                .tip("목업 변경의 자리와 번호를 이미지 위에 그립니다. 번호는 변경 목록과 같습니다")
        }
        Picker("", selection: $page.compareMode) {
            Text("둘 다").tag(0)
            Text("이전").tag(1)
            Text("이후").tag(2)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 168)
    }

    /// 이미지는 제 비율대로 칸 너비에 맞춘다. 받기 전·실패는 고정 높이 자리로 둔다.
    private func shot(_ label: String, version: String?, frame: String, marks: [DesignChangeTree.Item], maxHeight: CGFloat) -> some View {
        let state = version.flatMap { images.state(fileKey: event.fileKey, nodeID: frame, version: $0) }
        return VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.label).foregroundStyle(.secondary)
            Group {
                if version != nil, case .ready(let url) = state, let image = images.image(url) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .overlay(ChangeMarks(items: marks, before: label == "이전", selected: $page.selectedChange))
                        .clipShape(RoundedRectangle(cornerRadius: WL.inner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .top)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .tip("\(label) 화면 · 두 번 누르면 크게 엽니다")
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.callout)
                        if version == nil {
                            Text(label == "이전" ? "새로 생긴 화면이라 이전이 없습니다" : "지워진 화면이라 이후가 없습니다")
                                .font(WL.caption).foregroundStyle(WL.muted).multilineTextAlignment(.center).padding(10)
                        } else if case .missing(let reason) = state {
                            Text(reason).font(WL.caption).foregroundStyle(WL.waiting).multilineTextAlignment(.center).padding(10)
                        } else {
                            VStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("피그마에서 그리는 중…").font(WL.caption).foregroundStyle(WL.muted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: min(maxHeight, 220))
                    .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
                }
            }
        }
        .onAppear {
            if let version { images.load(fileKey: event.fileKey, nodeIDs: neighbours(frame, version: version, before: label == "이전"), version: version) }
        }
    }

    /// 지금 프레임과, 같은 버전으로 그릴 가까운 변경의 프레임. 한 요청으로 받아 다음 변경은 기다리지 않고 열린다.
    private func neighbours(_ frame: String, version: String, before: Bool) -> [String] {
        let all = stored ? sync.history.events : (DesignCompareModel.shared.currentResult?.events ?? [])
        guard let index = all.firstIndex(where: { $0.id == event.id }) else { return [frame] }
        var ids = [frame]
        for i in all.indices.sorted(by: { abs($0 - index) < abs($1 - index) }) where ids.count < DesignImages.batchSize {
            let other = all[i]
            guard other.fileKey == event.fileKey, other.kind != .changelog else { continue }
            let id = before ? (other.kind == .added ? nil : other.beforeFrameID ?? other.frameID) : (other.kind == .removed ? nil : other.frameID)
            if let id, (before ? other.beforeVersion : other.afterVersion) == version, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// 지금 이 화면을 완료로 보는지 (사이드바 상태와 같은 규칙).
    private var screenState: ScreenState? {
        guard let frame = event.frameID, let screen = DesignSync.shared.history.files[event.fileKey]?.screens[frame] else { return nil }
        return DesignSync.shared.state(of: screen, in: event.fileKey)
    }

    private func setStatus(_ done: Bool?) {
        DesignSync.shared.setStatus(DesignStatusRules.screenKey(event.screenID), done: done, in: event.fileKey)
        page.flash(done == nil ? "섹션 표시대로 봅니다" : done! ? "이 화면을 완료로 봅니다. 다음 변경부터 알립니다" : "이 화면을 작업 중으로 봅니다")
    }

    private var renumbered: some View {
        let changes = event.changes.filter { $0.op == .renumbered }
        return Group {
            if !changes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button { page.showRenumbered.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(page.showRenumbered ? 90 : 0))
                            Text("번호만 바뀐 명세 \(changes.count)개").font(WL.meta)
                        }
                        .foregroundStyle(WL.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if page.showRenumbered {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                                HStack(spacing: 6) {
                                    Text("\(change.before ?? "") → \(change.after ?? "")").font(WL.number).foregroundStyle(WL.muted)
                                    Text(DesignText.headline(change.label, limit: 60)).font(WL.meta).foregroundStyle(WL.muted)
                                }
                            }
                        }
                        .padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, count: Int?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title, trailing: count.map { "\($0)" })
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wlSurface()
        }
    }

    private func callout(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13.5)).foregroundStyle(WL.muted)
            Text(text).font(WL.body).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WL.outer, style: .continuous).fill(WL.callout))
    }
}

/// 반영 체크. 누르면 그 항목을 마크업에 반영한 것으로 둔다.
struct AppliedCheck: View {
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(on ? WL.done : WL.quiet)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(on ? "반영 안 함으로 되돌리기" : "마크업에 반영함")
    }
}

struct DesignChangeRow: View {
    let change: SpecChange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(op).font(WL.label).foregroundStyle(color)
                    .padding(.horizontal, 5).frame(height: 17)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.12)))
                Text(title).font(WL.heading).lineLimit(2).textSelection(.enabled)
            }
            switch change.op {
            case .modified:
                DesignFormat.diff(before: body(change.before, whenSameTitleAs: change.after), after: body(change.after, whenSameTitleAs: change.before))
                    .font(WL.body).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            case .added:
                if change.layer == .spec || change.layer == .component {
                    Text(body(change.after)).font(WL.body).foregroundStyle(WL.done).lineSpacing(3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .removed:
                if change.layer == .spec || change.layer == .component {
                    Text(body(change.before)).font(WL.body).strikethrough().foregroundStyle(WL.muted).lineSpacing(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            case .renumbered:
                EmptyView()
            }
        }
        .padding(.vertical, 12)
    }

    /// 제목 줄이 그대로면 위에 이미 보이니 본문만 비교한다.
    private func body(_ text: String?, whenSameTitleAs other: String?) -> String {
        let text = text ?? ""
        guard change.layer == .spec else { return text }
        let mine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let theirs = (other ?? "").split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard mine.count == 2, theirs.count == 2, mine[0] == theirs[0] else { return text }
        return String(mine[1])
    }

    /// 명세는 첫 줄이 제목이라 제목 줄 아래 본문만 보인다.
    private func body(_ text: String?) -> String {
        let text = text ?? ""
        guard change.layer == .spec else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : text
    }

    private var title: String {
        switch change.layer {
        case .spec, .header, .component: return change.label
        case .text: return change.op == .removed ? change.before ?? change.label : change.after ?? change.label
        }
    }

    private var op: String {
        switch change.op {
        case .added: return "추가"
        case .removed: return "삭제"
        case .modified: return "수정"
        case .renumbered: return "번호"
        }
    }

    private var color: Color {
        switch change.op {
        case .added: return WL.done
        case .removed: return WL.waiting
        case .modified, .renumbered: return WL.accent
        }
    }
}

// MARK: - 형식

enum DesignFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = format
        return formatter
    }

    private static let dayFormatter = formatter("M월 d일 EEEE")
    private static let timeFormatter = formatter("HH:mm")
    private static let stampFormatter = formatter("M/d HH:mm")

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "오늘 · " + dayFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "어제 · " + dayFormatter.string(from: date) }
        return dayFormatter.string(from: date)
    }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// `상품 관리 > 상품 목록` → `상품 관리 › 상품 목록`
    static func path(_ path: String) -> String { path.replacingOccurrences(of: " > ", with: " › ") }

    /// 이력은 `v0.2 2026-10-22`만으론 무엇인지 몰라 `제·개정 이력 v0.2`로 부른다.
    static func title(_ event: DesignEvent) -> String {
        guard event.kind == .changelog else { return event.title.isEmpty ? event.screenID : event.title }
        let version = event.title.split(separator: " ").first { $0.hasPrefix("v") }
        return "제·개정 이력" + (version.map { " " + $0 } ?? "")
    }

    /// 둘째 줄: 화면 ID와 경로, 이력은 페이지와 적은 날.
    static func subtitle(_ event: DesignEvent) -> String {
        // 경로 가운데가 잘리면 읽기 어려워 마지막 두 마디만 둔다 (전체 경로는 툴팁과 상세에 있다)
        guard event.kind == .changelog else {
            let tail = event.menuPath.components(separatedBy: " > ").suffix(2).joined(separator: " › ")
            return [event.screenID, tail].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let date = event.title.split(separator: " ").first { $0.count == 10 && $0.contains("-") }
        return [event.menuPath, date.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    /// 화면이나 이력 표 프레임으로 바로 가는 주소.
    static func link(_ event: DesignEvent) -> URL? {
        event.frameID.flatMap { FigmaFileURL.link(fileKey: event.fileKey, nodeID: $0) }
    }

    /// Claude 문구를 복사한 뒤 알림. 화면 수와 글자 수를 보여 문구가 길면 범위를 좁힐지 정하게 한다.
    static func copied(_ prompt: String) -> String {
        let screens = prompt.components(separatedBy: "[화면] ").count - 1
        return "Claude 문구를 복사했습니다 · " + (screens > 1 ? "화면 \(screens)개 · " : "") + "\(prompt.count.formatted())자"
    }

    static func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "오늘 " + timeFormatter.string(from: date) : stampFormatter.string(from: date)
    }

    /// `10/22 13:00 ~ 14:32 사이 변경`
    static func window(_ event: DesignEvent) -> String {
        guard let start = event.windowStart else { return "\(stamp(event.detectedAt)) 확인" }
        let end = event.windowEnd
        let range = Calendar.current.isDate(start, inSameDayAs: end)
            ? "\(stampFormatter.string(from: start)) ~ \(timeFormatter.string(from: end))"
            : "\(stampFormatter.string(from: start)) ~ \(stampFormatter.string(from: end))"
        return "\(range) 사이 변경"
    }

    /// 빠진 말은 줄을 긋고, 들어온 말은 초록으로.
    static func diff(before: String, after: String) -> Text {
        InlineDiff.segments(before: before, after: after).reduce(Text("")) { text, segment in
            switch segment.kind {
            case .same: return text + Text(segment.text)
            case .removed: return text + Text(segment.text).strikethrough().foregroundColor(WL.waiting)
            case .added: return text + Text(segment.text).foregroundColor(WL.done).bold()
            }
        }
    }
}
