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
    }

    @Published var scope: Scope = .important
    @Published var selected: UUID?
    @Published var layer: SpecChange.Layer?
    @Published var search = ""
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
    /// 앱 창에서 숨겨 둔 동안에는 false. 다시 보일 때 오래됐으면 새로 받는다.
    var isActive = true
    /// 화면 점검(`--ui-shots`)에서는 가져오지 않는다.
    var autoStart = true

    static let sidebarWidth: CGFloat = 256
    static let timelineWidth: CGFloat = 344

    /// 상세가 이보다 좁아지면 단추·비교 글이 답답해져서, 창이 좁으면 목록 칸부터 줄인다.
    static let detailMinWidth: CGFloat = 380
    static let sidebarRange: ClosedRange<CGFloat> = 200...380
    static let timelineRange: ClosedRange<CGFloat> = 280...560

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
                    DesignTimeline(sync: sync, page: page, events: events)
                        .frame(width: timeline)
                    ColumnDivider(width: $page.timelineWidth, range: Self.timelineRange, standard: Self.timelineWidth)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .bottom) {
            if let toast = page.toast { Toast(message: toast).padding(.bottom, 18).transition(.opacity) }
        }
        .onAppear { if autoStart && isActive { sync.syncIfStale() } }
        .onChange(of: isActive) { if $0 && autoStart { sync.syncIfStale() } }
    }

    // MARK: 거르기

    private var events: [DesignEvent] {
        let query = page.search.trimmingCharacters(in: .whitespaces).lowercased()
        return sync.history.events.filter { event in
            // 숨긴 프로젝트·메뉴는 어느 보기에서도 빼고, 맨 아래 숨긴 항목에서만 다시 켠다
            if sync.isHidden(event) { return false }
            switch page.scope {
            case .project(let key): if event.fileKey != key { return false }
            case .all: break
            case .important: if !event.isImportant { return false }
            case .working: if event.isImportant { return false }
            case .menu(let key, let path): if event.fileKey != key || event.menuPath != path { return false }
            case .group(let key, let head): if event.fileKey != key || !DesignStatus.covers(head, event.menuPath) { return false }
            }
            if let layer = page.layer, !event.changes.contains(where: { $0.layer == layer && $0.op != .renumbered }) { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([event.screenID, event.title, event.menuPath, event.note ?? ""]
                + event.changes.flatMap { [$0.label, $0.before ?? "", $0.after ?? ""] }).joined(separator: "\n").lowercased()
            return haystack.contains(query)
        }
    }

    // MARK: 상세

    @ViewBuilder private var detail: some View {
        if let id = page.selected, let event = sync.history.events.first(where: { $0.id == id }) {
            DesignEventDetail(event: event, seen: sync.history.isSeen(event), showRenumbered: $page.showRenumbered,
                              compareMode: $page.compareMode,
                              toggleSeen: {
                                  if sync.history.isSeen(event) { sync.markUnseen(event.id) } else { sync.markSeen([event.id]) }
                              },
                              flash: page.flash)
                .id(event.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.squares.leading").font(.system(size: 28, weight: .light)).foregroundStyle(WL.faint)
                Text("변경을 고르면 바뀐 내용이 여기에 나옵니다").font(WL.body).foregroundStyle(WL.muted)
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

    static func build(_ menus: [DesignHistory.Menu]) -> [Node] {
        var roots: [Node] = []
        for menu in menus.sorted(by: { $0.path < $1.path }) {
            insert(menu, menu.path.components(separatedBy: " > ")[...], prefix: "", into: &roots)
        }
        return roots.map(compact)
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
        VStack(alignment: .leading, spacing: 16) {
            searchField
            VStack(spacing: 1) {
                row(key: "important", icon: "checkmark.seal", title: "완료 후 변경", count: sync.unseenCount, badge: true, scope: .important)
                    .tip("완료된 화면에 다시 생긴 변경, 막 완료된 화면, 디자이너가 적은 이력")
                row(key: "working", icon: "pencil.line", title: "작업 중 변경",
                    count: sync.history.events.filter { !$0.isImportant }.count, badge: false, scope: .working)
                    .tip("아직 작업 중인 화면의 변경. 같은 날 바뀐 것은 한 건으로 합칩니다")
                row(key: "all", icon: "tray.full", title: "모든 변경", count: sync.history.events.count, badge: false, scope: .all)
            }
            if !settings.sources.isEmpty && settings.sources.allSatisfy({ $0.alerts.isEmpty }) && !sync.history.files.isEmpty {
                alertHint
            }
            SlimScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    favoritesSection
                    if !files.isEmpty { treeControls }
                    ForEach(files.filter { !(sync.source($0.key)?.isHidden ?? false) }, id: \.key) { file in fileSection(file) }
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

    // MARK: 찾기

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("찾기", text: $page.search)
                .textFieldStyle(.plain)
                .font(WL.meta)
                .focused($searching)
                .onExitCommand { page.search = ""; searching = false }
            if !page.search.isEmpty {
                Button { page.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .tip("찾는 말 지우기 (esc)")
            } else if !searching {
                Text("⌘F").font(WL.caption).foregroundStyle(.tertiary)
            }
        }
        .background {
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        .tip("화면 ID·화면명·명세·문구에서 찾습니다")
    }

    private var alertHint: some View {
        Button { page.openSettings(.alerts) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bell.badge").font(.system(size: 12)).foregroundStyle(WL.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("알림 받을 메뉴를 고르세요").font(.system(size: 12, weight: .semibold))
                    Text("메뉴에 마우스를 올리면 나오는 종을 누르거나, 여기를 눌러 한 번에 고릅니다.")
                        .font(WL.caption).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.selected.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .font(.system(size: 10.5, weight: .medium))
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

    private func fileSection(_ file: (key: String, name: String)) -> some View {
        let nodes = tree(file.key)
        let rows = DesignMenuTree.rows(nodes) { node, depth in folded(node, depth, fileKey: file.key) }
        let collapsed = page.foldedProjects.contains(file.key)
        return VStack(alignment: .leading, spacing: 1) {
            projectHeader(file, nodes: nodes, collapsed: collapsed)
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
                    .font(.system(size: 8, weight: .bold))
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
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip("\(file.name)\n누르면 이 프로젝트의 변경만 봅니다 · 끌어서 순서 바꾸기")
            badge(unseen, fallback: collapsed ? nodes.reduce(0) { $0 + $1.screens } : nil)
        }
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
            .fill(selected ? WL.hover.opacity(1.8) : hover.key == key ? WL.hover : .clear))
        .onHover { hover.update(key, $0) }
        .reorderable(file.key, dragging: $page.draggingProject) { from, to in sync.moveProject(from, to: to) }
        .contextMenu {
            Button("이 프로젝트만 보기") { page.scope = target }
            Button("지금 가져오기") { sync.sync(only: file.key) { count in page.flash(count > 0 ? "변경 \(count)건을 찾았습니다" : "새 변경이 없습니다") } }
            if let url = URL(string: "https://www.figma.com/design/\(file.key)") {
                Button("피그마에서 열기") { NSWorkspace.shared.open(url) }
            }
            Button("알림 받을 메뉴…") { page.openSettings(.alerts) }
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
                page.flash("‘\(name)’를 숨겼습니다. 숨긴 동안은 가져오지 않습니다")
            }
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
            guard sync.source(fileKey)?.hides(path) != true, sync.history.files[fileKey] != nil else { return nil }
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
                Image(systemName: "star.fill").font(.system(size: 9.5)).foregroundStyle(Color.yellow.opacity(0.85)).frame(width: 14)
                Text(path.components(separatedBy: " > ").last ?? path).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if settings.sources.filter({ !$0.isHidden }).count > 1 {
                    Text(project).font(WL.caption).foregroundStyle(WL.projectColor(project)).lineLimit(1)
                }
                Spacer(minLength: 4)
                badge(unseen, fallback: nil)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
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
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
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
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: show) { Image(systemName: "eye") }
                .buttonStyle(GhostIconButtonStyle())
                .tip("다시 보이기")
        }
        .padding(.leading, 26)
        .frame(height: 28)
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
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        .frame(width: 14, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .tip(isFolded ? "펼치기" : "접기")
            } else {
                Color.clear.frame(width: 14, height: 28)
            }
            Button { page.scope = target } label: {
                HStack(spacing: 7) {
                    if screens > 0 { statusDot(state(fileKey, node.path)) } else { Color.clear.frame(width: 6, height: 6) }
                    // 지금 화면이 없는 줄은 이유를 붙인다: 지워진 화면이면 "삭제됨", 페이지 이력만 있으면 "이력"
                    (Text(node.name) + Text(screens == 0 ? "  " + emptyReason(fileKey, node.path) : "").font(WL.caption).foregroundColor(WL.faint))
                        .font(.system(size: 13, weight: selected ? .semibold : parent ? .medium : .regular))
                        .foregroundStyle(screens == 0 ? WL.muted : WL.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 좁은 사이드바에서 잘리는 이름도 전체 경로를 툴팁으로 보인다
            .tip(rowTip(node, screens: screens))
            if screens > 0 { bell(fileKey, node.path, hovered: hover.key == key) }
            badge(node.unseen, fallback: isFolded ? screens : nil)
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 12)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
            .fill(selected ? WL.hover.opacity(1.8) : hover.key == key ? WL.hover : .clear))
        .onHover { hover.update(key, $0) }
        .contextMenu {
            Button(sync.isFavorite(fileKey, node.path) ? "즐겨찾기에서 빼기" : "즐겨찾기에 넣기") { sync.toggleFavorite(fileKey, node.path) }
            if screens > 0 { menuActions(fileKey, node.path) }
            Divider()
            Button("숨기기") {
                sync.setMenuHidden(node.path, hidden: true, in: fileKey)
                page.flash("‘\(node.name)’를 숨겼습니다. 맨 아래 숨긴 항목에서 다시 보입니다")
            }
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
                     scope target: DesignHistoryPage.Scope) -> some View {
        let selected = page.scope == target
        return Button { page.scope = target } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(showsBadge ? WL.accent : .secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if showsBadge { badge(count, fallback: nil) }
                else if count > 0 { Text("\(count)").font(WL.number).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
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
            Text("\(unseen)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                .background(Capsule().fill(WL.accent))
        } else if let fallback, fallback > 0 {
            Text("\(fallback)").font(WL.number).foregroundStyle(.tertiary)
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
                sync.sync { count in page.flash(count > 0 ? "변경 \(count)건을 찾았습니다" : "새 변경이 없습니다") }
            } label: {
                if sync.syncing { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(GhostIconButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(sync.syncing || settings.sources.isEmpty || !settings.hasToken)
            .tip("지금 가져오기 (⌘R)")
        }
    }

    private var problem: String? {
        sync.errors["*"] ?? settings.sources.lazy.compactMap { source in sync.errors[source.fileKey].map { "\(source.name): \($0)" } }.first
    }

    private var schedule: String {
        settings.intervalMinutes == 0 ? "수동" : settings.intervalMinutes < 60 ? "\(settings.intervalMinutes)분마다" : "\(settings.intervalMinutes / 60)시간마다"
    }

    private var status: String {
        if sync.syncing { return sync.progress.isEmpty ? "가져오는 중…" : sync.progress }
        if !settings.hasToken { return "토큰을 넣어야 가져옵니다" }
        if settings.sources.isEmpty { return "지켜볼 화면설계서가 없습니다" }
        return sync.lastRun.map { DesignFormat.stamp($0) + "에 확인" } ?? "아직 확인하지 않았습니다"
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
                step(1, "피그마 토큰 넣기", "피그마 설정 > Security > Personal access tokens에서 file_content:read 범위로 만듭니다.", done: settings.hasToken)
                RowDivider()
                step(2, "화면설계서 주소 붙여넣기", "주소창의 figma.com/design/… 주소를 그대로 넣습니다.", done: !settings.sources.isEmpty)
                RowDivider()
                step(3, "기다리기", "처음 가져온 상태가 기준이 되고, 다음 가져오기부터 바뀐 것을 기록합니다.", done: false)
            }
            .wlSurface()
            Button("피그마 연결하기") { page.openSettings(.figma) }
                .buttonStyle(NotionButtonStyle(kind: .primary))
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: Int, _ title: String, _ detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? WL.done : WL.callout)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
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

private struct DesignTimeline: View {
    @ObservedObject var sync: DesignSync
    @ObservedObject var page: DesignHistoryPage
    let events: [DesignEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(WL.title).lineLimit(1).truncationMode(.middle)
                        .tip(fullTitle)
                    Spacer()
                    Text(summary).font(WL.meta).foregroundStyle(WL.muted)
                }
                chips
            }
            .padding(.horizontal, WL.gutter)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Rectangle().fill(WL.border).frame(height: 1)
            let days = DesignHistory.days(events)
            if days.isEmpty {
                empty
            } else {
                SlimScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.events) { event in
                                    DesignEventRow(event: event, seen: sync.history.isSeen(event), selected: page.selected == event.id,
                                                   project: showsProject ? sync.projectName(event.fileKey) : nil) {
                                        page.selected = event.id
                                        page.showRenumbered = false
                                        sync.markSeen([event.id])
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(DesignFormat.day(day.day)).font(WL.label).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(day.events.count)건").font(WL.label).foregroundStyle(.tertiary)
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

    private var title: String {
        switch page.scope {
        case .all: return "모든 변경"
        case .important: return "완료 후 변경"
        case .working: return "작업 중 변경"
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

    /// 변경 종류로 거르는 칩. 고른 칩을 다시 누르면 모두 보인다.
    private var chips: some View {
        HStack(spacing: 6) {
            chip(nil, "전체")
            // 칩은 좁은 칸에 들어가게 짧게 부르고, 전체 이름은 툴팁에 둔다
            ForEach(DesignHistoryView.layerOrder, id: \.self) { layer in
                chip(layer, ["spec": "명세", "text": "문구"][layer.rawValue] ?? DesignHistoryView.layerName(layer))
                    .tip(DesignHistoryView.layerName(layer) + " 변경만 보기")
            }
        }
    }

    private func chip(_ layer: SpecChange.Layer?, _ title: String) -> some View {
        let on = page.layer == layer
        return Button { page.layer = on ? nil : layer } label: {
            Text(title)
                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? WL.accent : WL.muted)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(on ? WL.selected : Color.clear))
                .overlay(Capsule().strokeBorder(on ? Color.clear : WL.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: sync.history.events.isEmpty ? "clock.arrow.circlepath" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 26, weight: .light)).foregroundStyle(WL.faint)
            Text(sync.history.events.isEmpty ? "아직 기록한 변경이 없습니다" : "이 조건에 맞는 변경이 없습니다")
                .font(WL.body).foregroundStyle(WL.muted)
            Text(sync.history.events.isEmpty
                 ? "처음 가져온 상태가 기준입니다. 다음 가져오기부터 바뀐 것을 남깁니다."
                 : "찾는 말이나 변경 종류를 바꿔 보세요.")
                .font(WL.meta).foregroundStyle(WL.faint).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

private struct DesignEventRow: View {
    let event: DesignEvent
    let seen: Bool
    let selected: Bool
    var project: String?
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
                            .font(.system(size: 13, weight: seen ? .medium : .semibold)).lineLimit(1)
                            .tip(DesignFormat.title(event))
                        Spacer(minLength: 4)
                        Text(DesignFormat.time(event.detectedAt)).font(WL.number).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        if let project {
                            ProjectSwatch(name: project, size: 7)
                            Text(project).font(WL.meta).foregroundStyle(WL.text.opacity(0.75)).lineLimit(1).fixedSize()
                        }
                        Text(DesignFormat.subtitle(event))
                            .font(WL.meta).foregroundStyle(WL.muted).lineLimit(1).truncationMode(.middle)
                            .tip(DesignFormat.subtitle(event))
                    }
                    HStack(spacing: 6) {
                        DesignPhaseBadge(phase: event.phase)
                        Text(event.summary).font(WL.meta).foregroundStyle(WL.muted).lineLimit(1)
                        Spacer(minLength: 0)
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
private struct DesignPhaseBadge: View {
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
        case nil: return nil
        }
    }

    private var tip: String {
        switch phase {
        case .afterDone: return "완료된 시안에 추가 작업이 들어갔습니다"
        case .completed: return "이번 변경으로 완료됐습니다"
        default: return "아직 작업 중인 시안입니다"
        }
    }
}

// MARK: - 상세

private struct DesignEventDetail: View {
    let event: DesignEvent
    let seen: Bool
    @Binding var showRenumbered: Bool
    @Binding var compareMode: Int
    let toggleSeen: () -> Void
    let flash: (String) -> Void
    @ObservedObject private var images = DesignImages.shared

    var body: some View {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actions
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
                comparison
                if event.phase == .completed {
                    callout("checkmark.seal", "이번 변경으로 완료 표시가 붙은 화면입니다.")
                } else if event.phase == .working && event.kind == .changed {
                    callout("pencil.line", "작업 중인 화면입니다. 같은 날 바뀐 것은 이 한 건에 모아 그날 처음 상태와 비교합니다.")
                }
                if event.kind == .removed {
                    callout("trash", "화면설계서에서 이 화면이 없어졌습니다. 다른 화면 ID로 옮겨졌는지 확인하세요.")
                }
                ForEach(DesignHistoryView.layerOrder, id: \.self) { layer in
                    let changes = event.changes.filter { $0.layer == layer && $0.op != .renumbered }
                    if !changes.isEmpty {
                        section(DesignHistoryView.layerName(layer), count: changes.count) {
                            ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                                if index > 0 { RowDivider() }
                                DesignChangeRow(change: change)
                            }
                        }
                    }
                }
                renumbered
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DesignPhaseBadge(phase: event.phase)
                if !event.screenID.isEmpty {
                    Text(event.screenID).font(WL.number).foregroundStyle(WL.muted).textSelection(.enabled)
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
                Button(seen ? "안 본 것으로 표시" : "본 것으로 표시", action: toggleSeen).buttonStyle(TextLinkButtonStyle())
                    .tip(seen ? "목록에 다시 파란 점을 붙여 나중에 볼 것으로 둡니다" : "확인한 것으로 둡니다")
            }
            title
            breadcrumb
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.system(size: 10.5))
                Text(DesignFormat.window(event))
                Text("·")
                ProjectSwatch(name: DesignSync.shared.projectName(event.fileKey), size: 7)
                Text(DesignSync.shared.projectName(event.fileKey)).lineLimit(1).tip(event.fileName)
            }
            .font(WL.meta).foregroundStyle(WL.faint)
        }
    }

    /// 제목을 눌러도 피그마에서 그 프레임이 열린다.
    @ViewBuilder private var title: some View {
        let text = Text(DesignFormat.title(event)).font(WL.pageTitle)
        if let url = DesignFormat.link(event) {
            Button { NSWorkspace.shared.open(url) } label: { text.multilineTextAlignment(.leading) }
                .buttonStyle(.plain)
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
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

    /// 상세가 좁으면(최소 창 크기) 보조 단추는 아이콘만 남겨 줄이 넘치지 않게 한다.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(compact: false)
            actionRow(compact: true)
        }
    }

    private func actionRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let url = DesignFormat.link(event) {
                let title = event.kind == .changelog ? "이력 표 열기" : "피그마에서 열기"
                Button { NSWorkspace.shared.open(url) } label: {
                    HStack(spacing: 7) { FigmaMark(height: 14); Text(title) }
                }
                .buttonStyle(NotionButtonStyle())
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.report, forType: .string)
                flash("변경 요약을 복사했습니다")
            } label: {
                if compact { Image(systemName: "doc.on.doc") } else { Label("요약 복사", systemImage: "doc.on.doc") }
            }
            .buttonStyle(NotionButtonStyle())
            .tip("요약 복사: 레드마인·MR에 붙일 [디자인 변경] 글")
            if event.kind != .changelog && event.kind != .removed {
                Button {
                    flash(DesignSync.shared.addToWorkLog(event) ? "업무 일지 오늘 칸에 넣었습니다" : "업무 일지에 넣지 못했습니다")
                } label: {
                    if compact { Image(systemName: "text.badge.plus") } else { Label("업무 일지에 넣기", systemImage: "text.badge.plus") }
                }
                .buttonStyle(NotionButtonStyle())
                .tip("업무 일지에 넣기: 오늘 칸에 ‘디자인 변경 반영’을 진행중으로")
            }
            Spacer(minLength: 0)
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
    }

    // MARK: 화면 비교

    /// 바뀌기 전·후 버전 그대로 그린 프레임. 볼 때만 받아 이 Mac에 둔다.
    @ViewBuilder private var comparison: some View {
        if event.kind != .changelog, let frame = event.frameID {
            if event.beforeVersion != nil || event.afterVersion != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel("화면 비교")
                        Spacer()
                        Picker("", selection: $compareMode) {
                            Text("나란히").tag(0)
                            Text("이전").tag(1)
                            Text("이후").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 168)
                    }
                    switch compareMode {
                    case 1: shot("이전", version: event.beforeVersion, frame: event.beforeFrameID ?? frame, large: true)
                    case 2: shot("이후", version: event.afterVersion, frame: frame, large: true)
                    default:
                        HStack(alignment: .top, spacing: 10) {
                            shot("이전", version: event.beforeVersion, frame: event.beforeFrameID ?? frame, large: false)
                            shot("이후", version: event.afterVersion, frame: frame, large: false)
                        }
                    }
                }
            } else if event.kind == .changed || event.kind == .replaced {
                Text("화면 비교 이미지는 이 기능이 생긴 뒤 기록한 변경부터 볼 수 있습니다.")
                    .font(WL.caption).foregroundStyle(WL.faint)
            }
        }
    }

    private func shot(_ label: String, version: String?, frame: String, large: Bool) -> some View {
        let state = version.flatMap { images.state(fileKey: event.fileKey, nodeID: frame, version: $0) }
        return VStack(alignment: .leading, spacing: 5) {
            Text(label).font(WL.label).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.callout)
                if version == nil {
                    Text(label == "이전" ? "새로 생긴 화면이라 이전이 없습니다" : "지워진 화면이라 이후가 없습니다")
                        .font(WL.caption).foregroundStyle(WL.faint).multilineTextAlignment(.center).padding(10)
                } else if case .ready(let url) = state, let image = images.image(url) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: WL.inner, style: .continuous))
                        .onTapGesture { NSWorkspace.shared.open(url) }
                        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                        .tip("\(label) 화면 · 누르면 크게 엽니다")
                } else if case .missing(let reason) = state {
                    Text(reason).font(WL.caption).foregroundStyle(WL.waiting).multilineTextAlignment(.center).padding(10)
                } else {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("피그마에서 그리는 중…").font(WL.caption).foregroundStyle(WL.faint)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: large ? 380 : 190)
            .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        }
        .onAppear { if let version { images.load(fileKey: event.fileKey, nodeID: frame, version: version) } }
    }

    /// 지금 이 화면을 완료로 보는지 (사이드바 상태와 같은 규칙).
    private var screenState: ScreenState? {
        guard let frame = event.frameID, let screen = DesignSync.shared.history.files[event.fileKey]?.screens[frame] else { return nil }
        return DesignSync.shared.state(of: screen, in: event.fileKey)
    }

    private func setStatus(_ done: Bool?) {
        DesignSync.shared.setStatus(DesignStatusRules.screenKey(event.screenID), done: done, in: event.fileKey)
        flash(done == nil ? "섹션 표시대로 봅니다" : done! ? "이 화면을 완료로 봅니다. 다음 변경부터 알립니다" : "이 화면을 작업 중으로 봅니다")
    }

    private var renumbered: some View {
        let changes = event.changes.filter { $0.op == .renumbered }
        return Group {
            if !changes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button { showRenumbered.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(showRenumbered ? 90 : 0))
                            Text("번호만 바뀐 명세 \(changes.count)개").font(WL.meta)
                        }
                        .foregroundStyle(WL.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showRenumbered {
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
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(WL.muted)
            Text(text).font(WL.body).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WL.outer, style: .continuous).fill(WL.callout))
    }
}

private struct DesignChangeRow: View {
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
        guard event.kind == .changelog else { return [event.screenID, path(event.menuPath)].filter { !$0.isEmpty }.joined(separator: " · ") }
        let date = event.title.split(separator: " ").first { $0.count == 10 && $0.contains("-") }
        return [event.menuPath, date.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    /// 화면이나 이력 표 프레임으로 바로 가는 주소.
    static func link(_ event: DesignEvent) -> URL? {
        event.frameID.flatMap { FigmaFileURL.link(fileKey: event.fileKey, nodeID: $0) }
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
