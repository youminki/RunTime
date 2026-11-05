import AppKit
import SwiftUI
import WorkLogCore

/// 앱 안 레드마인. 레드마인 웹과 같은 짜임으로 둔다: 왼쪽 범위(내 일감·프로젝트), 가운데 일감 표(정렬·거르기·트리),
/// 일감을 누르면 큰 창으로 일감 화면(칸·설명·하위·관계·첨부·이력·댓글)을 연다.
/// 칸은 그 자리에서 고치고 바로 보내며, 표와 일감 창이 같은 값을 보아 새로고침이 없다.
struct RedmineView: View {
    @ObservedObject var store: RedmineStore
    @ObservedObject var settings: WorkLogSettings
    let workLogPage: WorkLogPage
    /// 일지에서 보내거나 "오늘 일지에 넣기"를 하면 아래 건수가 바로 바뀌게 지켜본다.
    @ObservedObject var workLog: WorkLogStore = .shared
    var openWorkLogSend: () -> Void = {}
    @StateObject private var state = RedmineViewState()

    /// 오늘 업무 일지에서 아직 보내지 않은 일감 (일지 → 레드마인 보내기로 간다).
    private var pendingFromLog: Int {
        Set(workLog.log.entries(on: WorkDay.today()).filter(\.needsRedmine).compactMap(\.issue)).count
    }

    var body: some View {
        Group {
            if settings.redmineReady {
                HStack(spacing: 0) {
                    sidebar.frame(width: 240)
                    Rectangle().fill(WL.border).frame(width: 1)
                    RedmineIssueTable(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear { store.start() }
                .onChange(of: store.generation) { _ in
                    state.comments = [:]
                    state.files = [:]
                    state.subjectDrafts = [:]
                    state.descriptionDrafts = [:]
                    state.relationTargets = [:]
                    state.journalDrafts = [:]
                    state.privateNotes = []
                    state.preview = nil
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in store.refreshIfStale() }
                // 앞뒤 일감으로 옮길 때 창이 닫혔다 열리지 않게 번호가 아니라 있고 없음으로 띄운다
                .sheet(isPresented: Binding(get: { store.selected != nil }, set: { if !$0 { store.selected = nil } })) {
                    RedmineIssueSheet(store: store, state: state)
                        .frame(minWidth: 820, idealWidth: 940, minHeight: 600, idealHeight: 760)
                }
                .sheet(isPresented: $store.creating) { RedmineNewIssueSheet(store: store) }
            } else {
                notConnected
            }
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .bottom) { RedmineFlash(store: store) }
    }

    private var notConnected: some View {
        VStack(spacing: 10) {
            Image(systemName: "link.badge.plus").font(.system(size: 28)).foregroundStyle(WL.faint)
            Text("레드마인을 연결하면 일감을 앱에서 보고 고칠 수 있습니다").font(WL.body).foregroundStyle(WL.muted)
            Button("레드마인 연결") {
                workLogPage.settingsSection = .redmine
                workLogPage.showsSettings = true
            }
            .buttonStyle(NotionButtonStyle(kind: .primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 왼쪽

    private var sidebar: some View {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group(nil) {
                    item(.mine, icon: "person.crop.circle")
                    item(.authored, icon: "square.and.pencil")
                    if pendingFromLog > 0 {
                        Button(action: openWorkLogSend) {
                            HStack(spacing: 8) {
                                Image(systemName: "paperplane").frame(width: 16).foregroundStyle(WL.waiting)
                                Text("일지에서 보낼 것").lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(pendingFromLog)").font(WL.number).foregroundStyle(WL.waiting)
                            }
                            .sidebarRow(selected: false)
                        }
                        .buttonStyle(.plain)
                        .tip("오늘 업무 일지에 적은 진척률과 댓글을 레드마인에 보냅니다")
                    }
                }
                if !store.projects.isEmpty {
                    group("프로젝트") {
                        ForEach(store.projects) { project in item(.project(project), icon: nil) }
                    }
                }
            }
            .padding(12)
        }
        .background(WL.sidebar)
    }

    private func group<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title { Text(title).font(WL.label).foregroundStyle(WL.quiet).padding(.leading, 8).padding(.bottom, 2) }
            content()
        }
    }

    private func item(_ scope: RedmineStore.Scope, icon: String?) -> some View {
        let on = store.scope == scope
        return Button { store.scope = scope } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).frame(width: 16).foregroundStyle(on ? WL.accent : WL.muted) }
                // 프로젝트 이름은 뒤가 달라 가운데를 줄이면 알아볼 수 없다. 두 줄까지 쓴다
                Text(scope.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if case .project(let project) = scope, let count = store.myOpenCounts[project.id] {
                    Text("\(count)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet)
                        .help("내 열린 일감 \(count)건")
                }
            }
            .sidebarRow(selected: on)
        }
        .buttonStyle(.plain)
        .tip(scope.title)
    }
}

/// 시트에 넘기는 일감 번호 (`sheet(item:)`은 Identifiable을 받는다).

/// 화면 안에서만 쓰는 상태 (이 저장소는 `@State` 대신 ObservableObject를 쓴다).
final class RedmineViewState: ObservableObject {
    /// 일감마다 쓰던 댓글. 하나만 두면 일감을 바꿨을 때 앞 일감에 쓰던 글이 다른 일감에 올라간다.
    @Published var comments: [Int: String] = [:]
    @Published var editingDate: String?
    @Published var pickedDate = Date()
    @Published var history = HistoryTab.all
    @Published var loggingTime = false
    /// 일감마다 고치는 중인 글. 일감을 오가도 다른 일감에 섞이지 않게 번호로 나눈다.
    @Published var subjectDrafts: [Int: String] = [:]
    @Published var descriptionDrafts: [Int: String] = [:]
    @Published var relationType = "relates"
    @Published var relationTargets: [Int: String] = [:]
    @Published var relationOpen: Set<Int> = []
    /// 고치는 중인 댓글 (기록 번호 → 글).
    @Published var journalDrafts: [Int: String] = [:]
    /// 비공개로 쓰는 일감.
    @Published var privateNotes: Set<Int> = []
    /// 크게 보는 그림.
    @Published var preview: Redmine.Attachment?
    /// 일감마다 댓글에 붙일 파일.
    @Published var files: [Int: [URL]] = [:]

    enum HistoryTab: String, CaseIterable { case all = "전체", comments = "댓글", changes = "변경 내역" }
}

private struct RedmineFlash: View {
    @ObservedObject var store: RedmineStore
    /// 일감 창은 아래에 댓글 칸이 있어 위에 띄운다.
    var atTop = false
    var body: some View {
        if let message = store.flash {
            Text(message)
                .font(WL.meta).foregroundStyle(Color.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(atTop ? .top : .bottom, atTop ? 56 : store.checked.isEmpty ? 18 : 70)
                .onTapGesture { store.flash = nil }
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if store.flash == message { store.flash = nil }
                }
        }
    }
}

private extension View {
    func sidebarRow(selected: Bool) -> some View {
        self.font(WL.meta)
            .foregroundStyle(selected ? WL.accent : WL.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? WL.selected : .clear))
            .contentShape(Rectangle())
    }
}

// MARK: - 일감 표

/// 레드마인 일감 목록처럼 칸이 맞춰진 표. 머리를 누르면 정렬하고, 트리 보기면 하위 일감을 들여 쓴다.
/// 창이 좁으면 우선순위·고친 날·트래커 칸부터 숨긴다.
private struct RedmineIssueTable: View {
    @ObservedObject var store: RedmineStore

    var body: some View {
        let rows = store.rows
        VStack(alignment: .leading, spacing: 0) {
            header(count: store.visibleCount)
            Rectangle().fill(WL.border).frame(height: 1)
            GeometryReader { geo in
                let timeline = store.layout == .timeline
                let subjectWidth: CGFloat = geo.size.width < 900 ? 240 : 340
                let columns: [(RedmineStore.Column, CGFloat?)] = timeline ? [(.id, 60), (.subject, subjectWidth)]
                    : Self.columns(for: geo.size.width, shown: store.shownColumns)
                VStack(spacing: 0) {
                    if store.layout == .activity {
                        RedmineActivity(store: store)
                    } else if let error = store.error {
                        columnHeader(columns, timeline: timeline)
                        VStack(spacing: 10) {
                            message(error, icon: "exclamationmark.triangle").frame(height: 110)
                            Button("다시 받기") { store.refresh() }.buttonStyle(NotionButtonStyle())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if rows.isEmpty {
                        columnHeader(columns, timeline: timeline)
                        if store.loading {
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("\(store.scope.title) 불러오는 중").font(WL.meta).foregroundStyle(WL.muted)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 10) {
                                message(emptyText, icon: "tray").frame(height: 90)
                                if store.quick != .all || !store.search.isEmpty || !store.refine.isEmpty {
                                    Button("거르기 지우기") {
                                        store.quick = .all
                                        store.search = ""
                                        store.refine = [:]
                                    }
                                    .buttonStyle(NotionButtonStyle())
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        if store.layout == .board {
                            RedmineBoard(store: store, rows: rows)
                        } else if store.layout == .calendar {
                            RedmineMonth(store: store, rows: rows)
                        } else {
                        SlimScrollView {
                            // 머리를 스크롤 칸 안에 고정해야 스크롤 막대 폭만큼 칸이 어긋나지 않는다
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                Section {
                                    ForEach(store.groups, id: \.title) { group in
                                        if !group.title.isEmpty {
                                            HStack(spacing: 8) {
                                                Text(group.title).font(WL.heading)
                                                Text("\(group.rows.count)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 20).frame(height: 30)
                                            .background(WL.hover)
                                        }
                                        ForEach(group.rows) { row in TableRow(row: row, columns: columns, timeline: timeline, store: store) }
                                    }
                                    if store.total > store.issues.count {
                                        Text("레드마인에는 \(store.total)건이 있고 앞의 \(store.issues.count)건만 보입니다. 거르기를 좁혀 보세요")
                                            .font(WL.caption).foregroundStyle(WL.quiet).padding(14)
                                    }
                                } header: {
                                    columnHeader(columns, timeline: timeline)
                                }
                            }
                        }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { if !store.checked.isEmpty { checkedBar } }
    }

    private var emptyText: String {
        if !store.search.isEmpty { return "‘\(store.search)’에 맞는 일감이 없습니다" }
        if !store.refine.isEmpty { return "거르기 조건에 맞는 일감이 없습니다" }
        if store.quick != .all { return "\(store.quick.rawValue) 일감이 없습니다" }
        if case .query = store.scope { return "이 질의에 맞는 일감이 없습니다" }
        return "이 범위에 \(store.statusFilter.rawValue)이 없습니다"
    }

    // MARK: 머리

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(store.scope.title).font(WL.title).lineLimit(1)
                if !store.loading || count > 0 { Text("\(count)건").font(WL.number).foregroundStyle(WL.quiet) }
                if store.loading && !store.issues.isEmpty { ProgressView().controlSize(.small) }
                if case .project(let project) = store.scope { ReportNameMenu(project: project.name) }
                Spacer()
                searchField
                if !store.queries.isEmpty {
                    Menu {
                        ForEach(store.queries) { query in
                            Button(query.name) { store.scope = .query(query) }
                        }
                    } label: { Label("저장한 질의", systemImage: "line.3.horizontal.decrease.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .tip("레드마인에 저장해 둔 질의로 봅니다")
                }
                Button { store.creating = true } label: { Label("새 일감", systemImage: "plus") }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.projects.isEmpty)
                    .tip("새 일감 만들기 (⌘N)")
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GhostIconButtonStyle())
                    .keyboardShortcut("r", modifiers: .command)
                    .tip("다시 받기 (⌘R)")
            }
            HStack(spacing: 8) {
                if store.layout == .activity {
                    Text(store.activityScope).font(WL.caption).foregroundStyle(WL.quiet)
                } else if case .query = store.scope {
                    Text("질의 조건으로 봅니다").font(WL.caption).foregroundStyle(WL.quiet)
                } else {
                    Picker("", selection: $store.statusFilter) {
                        ForEach(RedmineStore.StatusFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    Rectangle().fill(WL.border).frame(width: 1, height: 16)
                }
                // 칩이 늘어도 머리가 표보다 넓어지지 않게 남는 폭 안에서 옆으로 넘긴다
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RedmineStore.Quick.allCases.filter { $0 != .all }, id: \.self) { quick in
                            let count = store.count(quick)
                            if count > 0 || store.quick == quick {
                                Button { store.quick = store.quick == quick ? .all : quick } label: {
                                    HStack(spacing: 4) {
                                        Text(quick.rawValue)
                                        Text("\(count)").monospacedDigit().opacity(0.7)
                                    }
                                }
                                .buttonStyle(ChipButtonStyle(selected: store.quick == quick))
                                .fixedSize()
                            }
                        }
                    }
                }
                .opacity(store.layout == .activity ? 0 : 1)
                .disabled(store.layout == .activity)
                Spacer(minLength: 8)
                if store.layout == .timeline {
                    legend
                    Button { store.timelineShift -= 4 } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(GhostIconButtonStyle()).tip("이전 4주")
                    Button("오늘") { store.timelineShift = 0 }
                        .buttonStyle(TextLinkButtonStyle()).disabled(store.timelineShift == 0)
                    Button { store.timelineShift += 4 } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(GhostIconButtonStyle()).tip("다음 4주")
                }
                if store.layout != .activity {
                    refineMenu
                    viewMenu
                }
                Picker("", selection: $store.layout) {
                    ForEach(RedmineStore.Layout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                .tip("트리는 상위 아래에 하위를, 일정은 기간을 막대로, 보드는 상태별 칸으로, 달력은 기한 날에, 작업 내역은 사람들의 댓글과 변경을 시간순으로 보입니다")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    /// 칸 값으로 다시 거르기. 조건이 있으면 그 수를 보인다.
    private var refineMenu: some View {
        Menu {
            ForEach(RedmineStore.RefineField.allCases, id: \.self) { field in
                Menu(store.refine[field].map { "\(field.rawValue): \($0)" } ?? field.rawValue) {
                    Button("모두") { store.refine[field] = nil }
                    Divider()
                    ForEach(store.values(of: field), id: \.self) { value in
                        Button(value) { store.refine[field] = value }
                    }
                }
            }
            Divider()
            Button("조건 지우기") { store.refine = [:] }.disabled(store.refine.isEmpty)
        } label: {
            Label(store.refine.isEmpty ? "거르기" : "거르기 \(store.refine.count)", systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .tip("상태·트래커·담당자·우선순위·프로젝트로 거릅니다")
    }

    /// 보일 칸과 묶는 기준.
    private var viewMenu: some View {
        Menu {
            Section("칸") {
                ForEach([RedmineStore.Column.status, .tracker, .priority, .assignee, .ratio, .due, .updated], id: \.self) { column in
                    Toggle(column.rawValue, isOn: Binding(get: { store.shownColumns.contains(column) }, set: { on in
                        if on { store.shownColumns.insert(column) } else { store.shownColumns.remove(column) }
                    }))
                }
            }
            Section("묶기") {
                Picker("묶기", selection: $store.grouping) {
                    ForEach(RedmineStore.Grouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
        } label: { Image(systemName: "slider.horizontal.3") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tip("보일 칸과 묶는 기준")
    }

    /// 고른 일감을 한 번에 고치는 막대.
    private var checkedBar: some View {
        let ids = store.checkedVisible
        let projects = Set(store.issues.filter { ids.contains($0.id) }.map(\.project.id))
        let people = projects.count == 1 ? projects.first.flatMap { store.people[$0] } ?? [] : []
        return HStack(spacing: 10) {
            Text(store.bulkRunning ? "고치는 중…" : "\(ids.count)건 고름").font(WL.meta.weight(.semibold))
            if store.checked.count > ids.count {
                Text("\(store.checked.count - ids.count)건은 가려져 빠짐").font(WL.caption).foregroundStyle(WL.waiting)
            }
            Menu("상태") {
                ForEach(store.statuses) { status in
                    Button(status.name) { confirm("상태를 \(status.name)(으)로 바꿀까요?", Redmine.Change(statusID: status.id)) }
                }
            }
            Menu("진척률") {
                ForEach(Array(stride(from: 0, through: 100, by: 10)), id: \.self) { ratio in
                    Button("\(ratio)%") { confirm("진척률을 \(ratio)%로 바꿀까요?", Redmine.Change(doneRatio: ratio)) }
                }
            }
            Menu("우선순위") {
                ForEach(store.priorities) { priority in
                    Button(priority.name) { confirm("우선순위를 \(priority.name)(으)로 바꿀까요?", Redmine.Change(priorityID: priority.id)) }
                }
            }
            Menu("담당자") {
                if let me = store.me { Button("나에게") { confirm("담당자를 나로 바꿀까요?", Redmine.Change(assignedToID: me.id)) } }
                ForEach(people.filter { $0.id != store.me?.id }) { person in
                    Button(person.name) { confirm("담당자를 \(person.name)(으)로 바꿀까요?", Redmine.Change(assignedToID: person.id)) }
                }
                Divider()
                if projects.count > 1 { Text("프로젝트가 여럿이라 구성원을 고를 수 없습니다") }
                Button("비우기") { confirm("담당자를 비울까요?", Redmine.Change(assignedToID: 0)) }
            }
            Button("풀기") { store.checked = [] }.buttonStyle(TextLinkButtonStyle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(WL.surface))
        .overlay(Capsule().strokeBorder(WL.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(.bottom, 16)
        .disabled(store.bulkRunning)
        .task(id: projects) { if projects.count == 1, let id = projects.first { store.loadPeople(project: id) } }
    }

    /// 동료에게 알림이 가는 일을 여러 건 하니 한 번 묻는다.
    private func confirm(_ what: String, _ change: Redmine.Change) {
        let alert = NSAlert()
        let ids = store.checkedVisible.sorted()
        alert.messageText = "\(ids.count)건의 \(what)"
        alert.informativeText = ids.prefix(12).map { "#\($0)" }.joined(separator: " ") + (ids.count > 12 ? " 외 \(ids.count - 12)건" : "")
        alert.addButton(withTitle: "바꾸기")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn { store.updateChecked(change) }
    }

    /// 일정 막대의 색 뜻.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([("진행", WL.accent), ("기한 지남", Palette.red)], id: \.0) { name, tint in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint).frame(width: 12, height: 6)
                    Text(name).font(WL.caption).foregroundStyle(WL.quiet)
                }
            }
        }
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("찾기 · Enter로 전체 찾기, #번호로 열기", text: $store.search).textFieldStyle(.plain).font(WL.meta)
                .onSubmit { store.submitSearch() }
            if store.searching { ProgressView().controlSize(.mini) }
            if !store.search.isEmpty {
                Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(WL.muted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 250, height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        .popover(isPresented: $store.showsResults, arrowEdge: .bottom) { searchResults }
    }

    /// 모든 프로젝트에서 찾은 일감. 누르면 그 일감을 연다.
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.results.isEmpty ? "찾은 일감이 없습니다"
                    : store.resultsTotal > store.results.count ? "찾은 일감 \(store.resultsTotal)건 중 앞의 \(store.results.count)건" : "찾은 일감 \(store.results.count)건")
                .font(WL.heading).padding(12)
            if !store.results.isEmpty {
                Rectangle().fill(WL.border).frame(height: 1)
                SlimScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.results) { found in
                            Button {
                                store.showsResults = false
                                // 팝오버가 닫힌 뒤에 시트를 띄워야 빠지지 않는다
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.selected = found.id }
                            } label: {
                                Text(found.title).font(WL.meta).lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 460)
    }

    // MARK: 칸

    /// 보일 칸과 너비. 제목은 남는 너비를 모두 쓴다.
    static func columns(for width: CGFloat, shown: Set<RedmineStore.Column>) -> [(RedmineStore.Column, CGFloat?)] {
        // 트래커는 제목 앞 태그로, 높은 우선순위는 제목 뒤 표시로 보여 칸을 따로 두지 않는다 (제목이 넓어야 읽힌다)
        var columns: [(RedmineStore.Column, CGFloat?)] = [(.id, 60), (.status, 72), (.tracker, 64), (.priority, 64), (.subject, nil),
                                                          (.assignee, 72), (.ratio, 92), (.due, 84), (.updated, 86)]
        columns.removeAll { $0.0 != .id && $0.0 != .subject && !shown.contains($0.0) }
        if width < 780 { columns.removeAll { $0.0 == .ratio } }
        return columns
    }

    private func columnHeader(_ columns: [(RedmineStore.Column, CGFloat?)], timeline: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(columns, id: \.0) { column, width in
                Button { store.sort(by: column) } label: {
                    HStack(spacing: 3) {
                        Text(column.rawValue)
                        if store.sort == column {
                            Image(systemName: store.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .font(WL.label)
                    .foregroundStyle(store.sort == column ? WL.text : WL.quiet)
                    .frame(width: width, alignment: .leading)
                    .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if timeline { TimelineWeeks(store: store).frame(maxWidth: .infinity) }
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(WL.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(WL.border).frame(height: 1) }
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(WL.faint)
            Text(text).font(WL.meta).foregroundStyle(WL.muted).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class ActivityFilter: ObservableObject {
    @Published var person: String?
    @Published var commentsOnly = false
}

/// 작업 내역: 프로젝트에서 사람들이 남긴 댓글과 변경을 시간순으로 본다. 웹의 작업 내역 자리.
private struct RedmineActivity: View {
    @ObservedObject var store: RedmineStore
    @StateObject private var filter = ActivityFilter()

    var body: some View {
        let since = Date().addingTimeInterval(-Double(store.activityDays) * 86_400)
        let all = Redmine.activity(store.activityIssues, since: since)
        let items = all.filter { (filter.person == nil || $0.user == filter.person) && (!filter.commentsOnly || $0.notes != nil) }
        let days = Dictionary(grouping: items) { WorkDay.key($0.date) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $store.activityDays) {
                    Text("7일").tag(7)
                    Text("30일").tag(30)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                Menu(filter.person ?? "모든 사람") {
                    Button("모든 사람") { filter.person = nil }
                    Divider()
                    ForEach(Array(Set(all.map(\.user))).sorted(), id: \.self) { name in
                        Button(name) { filter.person = name }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Toggle("댓글만", isOn: $filter.commentsOnly).toggleStyle(.checkbox).font(WL.meta)
                if store.activityLoading { ProgressView().controlSize(.small) }
                Spacer()
                if store.activityTruncated { Text("최근 고친 일감 60건까지 봅니다").font(WL.caption).foregroundStyle(WL.quiet) }
                Text("\(items.count)건").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet)
            }
            .padding(.horizontal, 20).frame(height: 42)
            Rectangle().fill(WL.border).frame(height: 1)
            if items.isEmpty {
                VStack(spacing: 8) {
                    if store.activityLoading { ProgressView() }
                    Text(store.activityLoading ? "이력을 모으는 중" : "이 기간에 작업 내역이 없습니다").font(WL.meta).foregroundStyle(WL.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SlimScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days.keys.sorted(by: >), id: \.self) { day in
                            Text(WorkLogFormat.longDay(day)).font(WL.heading).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
                            ForEach(days[day] ?? []) { item in row(item) }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func row(_ item: Redmine.Activity) -> some View {
        Button { store.selected = item.issue.id } label: {
            HStack(alignment: .top, spacing: 10) {
                Initials(name: item.user)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.user).font(WL.meta.weight(.semibold))
                        Text(item.date.formatted(date: .omitted, time: .shortened)).font(WL.caption).foregroundStyle(WL.quiet)
                        TrackerTag(name: item.issue.tracker.name)
                        Text(verbatim: "#\(item.issue.id)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet)
                        Text(item.issue.subject).font(WL.meta).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.issue.project.name).font(WL.caption).foregroundStyle(WL.quiet).lineLimit(1)
                    }
                    if item.created { Text("새 일감을 만들었습니다").font(WL.meta).foregroundStyle(WL.muted) }
                    ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in
                        Text("• " + Redmine.describe(detail, statuses: store.statuses, trackers: store.trackers, priorities: store.priorities,
                                                      people: store.people[item.issue.project.id] ?? []))
                            .font(WL.caption).foregroundStyle(WL.muted)
                    }
                    if let notes = item.notes {
                        Text(RedmineNote.plain(notes)).font(WL.meta).lineLimit(4).multilineTextAlignment(.leading)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.sidebar))
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 보드: 상태별 칸에 일감 카드를 둔다. 끌어 놓으면 상태가 바뀐다.
private struct RedmineBoard: View {
    @ObservedObject var store: RedmineStore
    let rows: [Redmine.TreeRow]
    @StateObject private var target = HoveredKey()

    var body: some View {
        // 열린 일감만 볼 때도 끌어서 닫을 수 있게 닫힌 상태까지 모두 칸으로 둔다
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(store.statuses) { status in column(status, rows.filter { $0.issue.status.id == status.id }) }
            }
            .padding(16)
        }
    }

    private func column(_ status: Redmine.Status, _ cards: [Redmine.TreeRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusLabel(name: status.name, closed: status.isClosed == true)
                Text("\(cards.count)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet)
            }
            .padding(.horizontal, 4)
            SlimScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { row in card(row.issue) }
                }
            }
        }
        .padding(10)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(target.key == status.name ? WL.selected : WL.sidebar))
        .dropDestination(for: String.self) { items, _ in
            // 다른 앱에서 끌어 온 글자가 일감을 고치지 않게 목록의 일감만 받는다
            guard let id = items.first.flatMap(Int.init), let issue = store.issues.first(where: { $0.id == id }),
                  issue.status.id != status.id else { return false }
            if store.isBlocked(from: issue.status.id, to: status.id) {
                store.flash = "\(issue.status.name)에서 \(status.name)(으)로 옮기는 것은 전에 막혔습니다"
                return false
            }
            store.update(id, Redmine.Change(statusID: status.id))
            return true
        } isTargeted: { target.update(status.name, $0) }
    }

    private func card(_ issue: Redmine.Issue) -> some View {
        // 단추로 감싸면 눌림이 끌기를 가로채 끌어 놓기가 시작되지 않는다
        VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TrackerTag(name: issue.tracker.name)
                    Text(verbatim: "#\(issue.id)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet)
                    Spacer(minLength: 0)
                    if let due = issue.dueDate { DueText(due: due, finished: issue.doneRatio >= 100) }
                }
                Text(issue.subject).font(WL.meta).lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    RatioBar(ratio: issue.doneRatio).frame(width: 60)
                    Spacer(minLength: 0)
                    Text(issue.assignedTo?.name ?? "담당 없음").font(WL.caption).foregroundStyle(WL.quiet).lineLimit(1)
                }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { store.selected = issue.id }
        .draggable(String(issue.id))
        .contextMenu {
            Button("일감 열기") { store.selected = issue.id }
            Menu("상태 바꾸기") {
                ForEach(store.statuses) { status in
                    Button(status.name) { store.update(issue.id, Redmine.Change(statusID: status.id)) }
                        .disabled(status.id == issue.status.id)
                }
            }
        }
    }
}

/// 달력: 기한 날에 일감을 둔다. 기한이 없으면 시작일에 둔다.
private struct RedmineMonth: View {
    @ObservedObject var store: RedmineStore
    let rows: [Redmine.TreeRow]

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }()

    private var month: Date {
        let today = Self.calendar.date(from: Self.calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return Self.calendar.date(byAdding: .month, value: store.monthShift, to: today) ?? today
    }

    /// 달력에 보일 날 (앞뒤 달을 채워 주 단위로).
    private var days: [Date] {
        let lead = (Self.calendar.component(.weekday, from: month) + 5) % 7
        let start = Self.calendar.date(byAdding: .day, value: -lead, to: month) ?? month
        let count = Self.calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let weeks = (lead + count + 6) / 7
        return (0..<(weeks * 7)).compactMap { Self.calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        let byDay = Dictionary(grouping: rows.map(\.issue).filter { ($0.dueDate ?? $0.startDate) != nil }) { $0.dueDate ?? $0.startDate ?? "" }
        let parts = Self.calendar.dateComponents([.year, .month], from: month)
        let undated = rows.filter { ($0.issue.dueDate ?? $0.issue.startDate) == nil }.count
        SlimScrollView {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(String(parts.year ?? 0))년 \(parts.month ?? 0)월").font(WL.section)
                if undated > 0 { Text("날짜 없는 \(undated)건은 달력에 없습니다").font(WL.caption).foregroundStyle(WL.quiet) }
                Spacer()
                Button { store.monthShift -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(GhostIconButtonStyle())
                Button("오늘") { store.monthShift = 0 }.buttonStyle(TextLinkButtonStyle()).disabled(store.monthShift == 0)
                Button { store.monthShift += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(GhostIconButtonStyle())
            }
            .padding(.horizontal, 20).frame(height: 40)
            HStack(spacing: 0) {
                ForEach(["월", "화", "수", "목", "금", "토", "일"], id: \.self) { name in
                    Text(name).font(WL.caption).foregroundStyle(WL.quiet).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 22)
            Rectangle().fill(WL.border).frame(height: 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in cell(day, byDay[WorkDay.key(day)] ?? []) }
            }
        }
        }
    }

    private func verbatim(_ issue: Redmine.Issue) -> String { "#\(issue.id) \(issue.subject)" }

    private func cell(_ day: Date, _ issues: [Redmine.Issue]) -> some View {
        let inMonth = Self.calendar.isDate(day, equalTo: month, toGranularity: .month)
        let today = Self.calendar.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(Self.calendar.component(.day, from: day))")
                .font(WL.caption.monospacedDigit().weight(today ? .bold : .regular))
                .foregroundStyle(today ? Palette.red : inMonth ? WL.muted : WL.faint)
            ForEach(issues.prefix(3)) { issue in
                Button { store.selected = issue.id } label: {
                    Text(issue.subject).font(.system(size: 11.5)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(WL.selected))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("#\(issue.id) \(issue.subject)")
            }
            if issues.count > 3 {
                Menu("+\(issues.count - 3)건") {
                    ForEach(issues.dropFirst(3)) { issue in
                        Button(verbatim(issue)) { store.selected = issue.id }
                    }
                }
                .font(WL.caption).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .overlay(Rectangle().stroke(WL.border, lineWidth: 0.5))
    }
}

/// 일정 보기의 머리: 월요일마다 날짜를 쓰고 오늘 자리를 표시한다.
private struct TimelineWeeks: View {
    @ObservedObject var store: RedmineStore

    var body: some View {
        let from = store.timelineStart, days = RedmineStore.timelineDays
        Canvas { context, size in
            let unit = size.width / CGFloat(days)
            let weeks = Redmine.weeks(from: from, days: days)
            // 좁으면 이름이 겹쳐 격주로만 쓴다
            let step = unit * 7 < 34 ? 2 : 1
            for (index, week) in weeks.enumerated() where index % step == 0 {
                context.draw(Text(week.label).font(WL.label).foregroundColor(WL.quiet),
                             at: CGPoint(x: CGFloat(week.offset) * unit, y: size.height / 2), anchor: .leading)
            }
        }
    }
}

/// 일정 보기의 한 줄: 주 눈금, 오늘 선, 기간 막대. 막대의 진한 부분이 진척률이다.
private struct TimelineLane: View {
    let row: Redmine.TreeRow
    @ObservedObject var store: RedmineStore

    var body: some View {
        let issue = row.issue, from = store.timelineStart, days = RedmineStore.timelineDays
        let today = (Redmine.dayNumber(WorkDay.today()) ?? from) - from
        let closed = store.statuses.first { $0.id == issue.status.id }?.isClosed == true
        let late = !closed && issue.doneRatio < 100 && (Redmine.dayNumber(issue.dueDate) ?? Int.max) < today + from
        let bar = Redmine.bar(start: issue.startDate, due: issue.dueDate, from: from, days: days)
        Canvas { context, size in
            let unit = size.width / CGFloat(days)
            for week in Redmine.weeks(from: from, days: days) {
                let x = CGFloat(week.offset) * unit
                context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(WL.border))
            }
            if let bar {
                let rect = CGRect(x: CGFloat(bar.offset) * unit, y: 11, width: max(CGFloat(bar.length) * unit, 4), height: 12)
                let tint = late ? Palette.red : WL.accent
                context.opacity = row.isContext ? 0.45 : 1
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(tint.opacity(0.25)))
                var done = rect
                done.size.width *= CGFloat(issue.doneRatio) / 100
                context.fill(Path(roundedRect: done, cornerRadius: 3), with: .color(tint))
                context.opacity = 1
            }
            if (0..<days).contains(today) {
                context.fill(Path(CGRect(x: CGFloat(today) * unit, y: 0, width: 1, height: size.height)), with: .color(Palette.red.opacity(0.7)))
            }
        }
        .help(([issue.startDate, issue.dueDate].compactMap { $0 }.joined(separator: " ~ ")) + " · 진척 \(issue.doneRatio)%")
    }
}

/// 표 한 줄. 제목 칸은 트리 깊이만큼 들여 쓰고, 짧은 일감 이름이면 업무 일지 장부의 메뉴 경로를 옅게 앞에 붙인다.
private struct TableRow: View {
    let row: Redmine.TreeRow
    let columns: [(RedmineStore.Column, CGFloat?)]
    let timeline: Bool
    @ObservedObject var store: RedmineStore
    @StateObject private var hover = HoverFlag()

    var body: some View {
        let issue = row.issue
        Button {
            // ⌘클릭이나 이미 고르는 중이면 열지 않고 고른다 (Finder 목록처럼)
            // 끼워 넣은 상위는 남의 일감이라 고르지 않는다
            if !row.isContext, NSEvent.modifierFlags.contains(.command) || !store.checked.isEmpty {
                if store.checked.remove(issue.id) == nil { store.checked.insert(issue.id) }
            } else {
                store.selected = issue.id
            }
        } label: {
            HStack(spacing: 10) {
                ForEach(columns, id: \.0) { column, width in
                    cell(column, issue)
                        .frame(width: width, alignment: .leading)
                        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                }
                if timeline { TimelineLane(row: row, store: store).frame(maxWidth: .infinity) }
            }
            .padding(.horizontal, 20)
            .frame(height: 34)
            .background(store.selected == issue.id || store.checked.contains(issue.id) ? WL.selected : hover.on ? WL.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(WL.border).frame(height: 0.5) }
        .contextMenu {
            Button("일감 열기") { store.selected = issue.id }
            if !row.isContext {
                Button(store.checked.contains(issue.id) ? "고르기 풀기" : "고르기 (⌘클릭)") {
                    if store.checked.remove(issue.id) == nil { store.checked.insert(issue.id) }
                }
            }
            if let base = RedmineAPI.baseURL(WorkLogSettings.shared.effectiveRedmineURL) {
                Button("웹에서 열기") { NSWorkspace.shared.open(Redmine.webURL(base: base, issue: issue.id)) }
            }
            Button("번호 복사 (#\(String(issue.id)))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("#\(issue.id)", forType: .string)
            }
        }
    }

    @ViewBuilder
    private func cell(_ column: RedmineStore.Column, _ issue: Redmine.Issue) -> some View {
        switch column {
        case .id:
            Text(verbatim: "#\(issue.id)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet)
        case .tracker:
            TrackerTag(name: issue.tracker.name)
        case .status:
            StatusLabel(name: issue.status.name, closed: store.statuses.first { $0.id == issue.status.id }?.isClosed == true)
        case .priority:
            Text(issue.priority.name).font(WL.meta)
                .foregroundStyle(issue.priority.id > 2 ? Palette.red : WL.muted).lineLimit(1)
        case .subject:
            HStack(spacing: 4) {
                if row.depth > 0 { Color.clear.frame(width: CGFloat(row.depth) * 16) }
                if store.treeMode {
                    if row.hasChildren {
                        Button {
                            if store.collapsed.contains(issue.id) { store.collapsed.remove(issue.id) } else { store.collapsed.insert(issue.id) }
                        } label: {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(WL.muted)
                                .rotationEffect(.degrees(store.collapsed.contains(issue.id) ? 0 : 90))
                                .frame(width: 14, height: 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 14)
                    }
                }
                TrackerTag(name: issue.tracker.name)
                subject(issue).opacity(row.isContext ? 0.55 : 1)
                if issue.priority.id > 2 {
                    Text(issue.priority.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.red).fixedSize()
                }
            }
        case .assignee:
            Text(issue.assignedTo?.name ?? "—").font(WL.meta).foregroundStyle(issue.assignedTo == nil ? WL.faint : WL.text).lineLimit(1)
        case .ratio:
            HStack(spacing: 6) {
                RatioBar(ratio: issue.doneRatio).frame(width: 46)
                Text("\(issue.doneRatio)%").font(WL.caption.monospacedDigit()).foregroundStyle(WL.muted)
            }
        case .due:
            if let due = issue.dueDate { DueText(due: due, finished: issue.doneRatio >= 100 || store.statuses.first { $0.id == issue.status.id }?.isClosed == true) } else {
                Text("—").font(WL.caption).foregroundStyle(WL.faint)
            }
        case .updated:
            Text(issue.updated.map { WorkLogFormat.when($0) } ?? "—").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet).lineLimit(1)
        }
    }

    private func subject(_ issue: Redmine.Issue) -> some View {
        // 트리에서는 위 줄들이 경로를 보여 주어 되풀이하지 않는다
        let path = store.treeMode ? [] : WorkLogStore.shared.log.issue(issue.id)?.path ?? []
        let prefix = path.isEmpty ? Text("") : Text(path.joined(separator: " › ") + " › ").foregroundColor(WL.quiet)
        return (prefix + Text(issue.subject).foregroundColor(WL.text))
            .font(WL.body)
            .lineLimit(1)
            // 메뉴 경로가 붙으면 끝의 일감 이름이 남게 앞을 자르고, 제목만이면 뒤를 자른다
            .truncationMode(path.isEmpty ? .tail : .head)
            .help(([path.joined(separator: " › ")].filter { !$0.isEmpty } + [issue.subject]).joined(separator: " › "))
    }
}

/// 레드마인 프로젝트를 업무 보고서에서 부를 이름. 긴 공식 이름 대신 `UxHub`처럼 짧게 쓴다.
private struct ReportNameMenu: View {
    let project: String
    @ObservedObject var log: WorkLogStore = .shared

    var body: some View {
        let current = log.log.reportProject(for: IssueInfo(id: 0, subject: "", project: project))
        Menu {
            ForEach(log.log.allProjects.filter { !log.log.hiddenProjects.contains($0) }, id: \.self) { name in
                Button(name) { log.setReportProject(name, for: project) }.disabled(name == current)
            }
            Divider()
            Button("레드마인 이름 그대로") { log.setReportProject("", for: project) }
        } label: { Text("보고서 이름 \(current)").font(WL.caption) }
        .menuStyle(.borderlessButton).fixedSize()
        .tip("일일보고에서 이 프로젝트를 부를 이름입니다. 새 이름은 업무 일지 왼쪽 프로젝트에서 만듭니다")
    }
}

private struct TrackerTag: View {
    let name: String
    var body: some View {
        let tint: Color = {
            switch name {
            case "안정화": return WL.waiting
            case "결함": return Palette.red
            case "구현": return WL.accent
            case "작업": return .teal
            default: return WL.muted
            }
        }()
        Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.12)))
    }
}

/// 상태 글 앞의 색 점. 레드마인이 상태 색을 주지 않아 이름으로 가른다.
private struct StatusLabel: View {
    let name: String
    let closed: Bool

    private var tint: Color {
        if name.contains("반려") || name.contains("거절") { return Palette.red }
        if name.contains("완료") || name.contains("종료") { return WL.done }
        if name.contains("진행") { return WL.accent }
        if name.contains("테스트") || name.contains("리뷰") { return .purple }
        return WL.quiet
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(name).font(WL.meta).foregroundStyle(closed ? WL.quiet : WL.muted).lineLimit(1)
        }
    }
}

private struct RatioBar: View {
    let ratio: Int
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WL.border)
                Capsule().fill(ratio >= 100 ? WL.done : WL.accent).frame(width: geo.size.width * CGFloat(min(100, max(0, ratio))) / 100)
            }
        }
        .frame(height: 5)
    }
}

/// 기한. 지났으면 빨강, 3일 안이면 주황. 끝난 일감은 알릴 것이 없어 옅게.
private struct DueText: View {
    let due: String
    let finished: Bool
    var body: some View {
        let today = WorkDay.today()
        let color: Color = finished ? WL.faint : due < today ? Palette.red : due <= WorkDay.adding(3, to: today) ? WL.waiting : WL.muted
        Text(WorkLogFormat.shortDay(due)).font(WL.caption.monospacedDigit()).foregroundStyle(color).lineLimit(1)
    }
}

// MARK: - 일감 창

/// 레드마인 일감 화면을 큰 창으로. 위에 앞뒤 일감 이동(⌘[ ⌘])과 닫기(esc), 아래로 칸·설명·하위·관계·첨부·이력·댓글.
struct RedmineIssueSheet: View {
    @ObservedObject var store: RedmineStore
    @ObservedObject var state: RedmineViewState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(WL.border).frame(height: 1)
            Group {
                if let id = store.selected {
                    if let issue = store.details[id] {
                        content(issue)
                    } else if let error = store.detailErrors[id] {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(WL.faint)
                            Text(verbatim: "#\(id)을 받지 못했습니다").font(WL.body)
                            Text(error).font(WL.meta).foregroundStyle(WL.muted).multilineTextAlignment(.center)
                            Button("다시 받기") { store.loadDetail(id) }.buttonStyle(NotionButtonStyle())
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack { ProgressView() }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .top) { RedmineFlash(store: store, atTop: true) }
        .sheet(item: $state.preview) { file in
            VStack(spacing: 0) {
                HStack {
                    Text(file.filename).font(WL.heading).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("내려받기") { store.download(file) }.buttonStyle(NotionButtonStyle()).disabled(store.downloading.contains(file.id))
                    Button("닫기") { state.preview = nil }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Rectangle().fill(WL.border).frame(height: 1)
                if let image = store.images[file.id] {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.failedImages.contains(file.id) {
                    VStack(spacing: 10) {
                        Text("그림을 받지 못했습니다").font(WL.meta).foregroundStyle(WL.muted)
                        Button("다시 받기") { store.loadImage(file) }.buttonStyle(NotionButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 760, idealWidth: 1000, minHeight: 520, idealHeight: 720)
            .background(WL.canvas)
            .overlay(alignment: .top) { RedmineFlash(store: store, atTop: true) }
            .onAppear { store.loadImage(file) }
        }
    }

    private var topBar: some View {
        let ids = store.navigableIDs
        let index = store.selected.flatMap { ids.firstIndex(of: $0) }
        return HStack(spacing: 8) {
            Button { store.move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(GhostIconButtonStyle())
                .keyboardShortcut("[", modifiers: .command)
                .disabled(index == nil || index == 0)
                .tip("앞 일감 (⌘[)")
            Button { store.move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(GhostIconButtonStyle())
                .keyboardShortcut("]", modifiers: .command)
                .disabled(index == nil || index == ids.count - 1)
                .tip("다음 일감 (⌘])")
            if let index { Text("\(index + 1) / \(ids.count)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet) }
            Spacer()
            if let id = store.selected, let issue = store.details[id] {
                if store.saving.contains(id) || store.loadingDetail == id { ProgressView().controlSize(.small) }
                // 지켜보는 사람을 볼 권한이 없으면 목록이 없어 지금 상태를 알 수 없다
                if let me = store.me, let watchers = issue.watchers {
                    let watching = watchers.contains { $0.id == me.id }
                    Button { store.setWatching(id, !watching) } label: {
                        Image(systemName: watching ? "star.fill" : "star").foregroundStyle(watching ? WL.waiting : WL.muted)
                    }
                    .buttonStyle(GhostIconButtonStyle())
                    .tip(watching ? "지켜보는 중 · 누르면 그만둡니다" : "지켜보기")
                }
                Button { addToLog(issue) } label: { Label("오늘 일지에 넣기", systemImage: "text.badge.plus") }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .tip("오늘 업무 일지에 이 일감 줄을 넣습니다 (이미 있으면 상태만 맞춥니다)")
                if let base = RedmineAPI.baseURL(WorkLogSettings.shared.effectiveRedmineURL) {
                    Button { NSWorkspace.shared.open(Redmine.webURL(base: base, issue: id)) } label: { Image(systemName: "safari") }
                        .buttonStyle(GhostIconButtonStyle())
                        .tip("웹에서 열기")
                    Menu {
                        Button("일감 복사") { store.copyIssue(issue) }
                        Button("주소 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Redmine.webURL(base: base, issue: id).absoluteString, forType: .string)
                        }
                        Divider()
                        Button("일감 지우기…", role: .destructive) { confirmDelete(issue) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .tip("일감 복사, 주소 복사, 지우기")
                }
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(GhostIconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .tip("닫기 (esc)")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func content(_ issue: Redmine.Issue) -> some View {
        VStack(spacing: 0) {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(issue)
                fields(issue)
                description(issue)
                children(issue)
                relations(issue)
                if let attachments = issue.attachments, !attachments.isEmpty {
                    section("첨부 파일 \(attachments.count)") { attachmentList(attachments, issue: issue.id) }
                }
                if let changesets = issue.changesets, !changesets.isEmpty {
                    section("저장소 변경 \(changesets.count)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(changesets) { change in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(String(change.revision.prefix(8))).font(WL.caption.monospaced()).foregroundStyle(WL.muted)
                                    Text(change.comments ?? "").font(WL.meta).lineLimit(2)
                                    Spacer(minLength: 0)
                                    if let user = change.user { Text(user.name).font(WL.caption).foregroundStyle(WL.quiet) }
                                }
                            }
                        }
                    }
                }
                history(issue)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // 긴 일감도 내리지 않고 바로 쓰게 창 아래에 둔다
        Rectangle().fill(WL.border).frame(height: 1)
        composer(issue)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .id(issue.id)
    }

    private func header(_ issue: Redmine.Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TrackerTag(name: issue.tracker.name)
                Text(verbatim: "#\(issue.id)").font(WL.meta.monospacedDigit()).foregroundStyle(WL.muted)
                Text(issue.project.name).font(WL.meta).foregroundStyle(WL.muted).lineLimit(1)
                if let parent = issue.parent {
                    Button { store.selected = parent.id } label: { Text(verbatim: "상위 #\(parent.id)").font(WL.meta) }
                        .buttonStyle(TextLinkButtonStyle())
                }
                Spacer(minLength: 8)
                if state.subjectDrafts[issue.id] == nil {
                    Button("제목 고치기") { state.subjectDrafts[issue.id] = issue.subject }.buttonStyle(TextLinkButtonStyle())
                }
            }
            if let path = WorkLogStore.shared.log.issue(issue.id)?.path, !path.isEmpty {
                Text(path.joined(separator: " › ")).font(WL.meta).foregroundStyle(WL.quiet)
            }
            if state.subjectDrafts[issue.id] != nil {
                HStack(spacing: 8) {
                    TextField("제목", text: Binding(get: { state.subjectDrafts[issue.id] ?? "" }, set: { state.subjectDrafts[issue.id] = $0 }))
                        .textFieldStyle(.roundedBorder).font(WL.section)
                        .onSubmit { saveSubject(issue) }
                    Button("저장") { saveSubject(issue) }.buttonStyle(NotionButtonStyle(kind: .primary))
                        .disabled(store.isBusy(issue.id))
                    Button("취소") { state.subjectDrafts[issue.id] = nil }.buttonStyle(NotionButtonStyle())
                }
            } else {
                Text(issue.subject).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text([issue.author.map { "\($0.name)이(가) 등록" }, issue.createdOn.flatMap(Redmine.date).map { WorkLogFormat.when($0) },
                  issue.updated.map { "마지막 수정 " + WorkLogFormat.when($0) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(WL.caption).foregroundStyle(WL.quiet)
        }
    }

    private func saveSubject(_ issue: Redmine.Issue) {
        TextInput.afterComposition { commitSubject(issue) }
    }

    private func commitSubject(_ issue: Redmine.Issue) {
        let id = issue.id, text = (state.subjectDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 저장 중 Enter를 또 치면 먼저 바꿔 둔 값과 같아져 초안이 지워진다
        guard !store.isBusy(id) else { return }
        guard !text.isEmpty, text != issue.subject else {
            state.subjectDrafts[id] = nil
            return
        }
        // 실패하면 쓴 글이 남아 있어야 해서 저장이 끝난 뒤에 닫는다
        store.update(id, Redmine.Change(subject: text)) { ok in if ok { state.subjectDrafts[id] = nil } }
    }

    private func saveDescription(_ issue: Redmine.Issue) {
        TextInput.afterComposition { commitDescription(issue) }
    }

    private func commitDescription(_ issue: Redmine.Issue) {
        let id = issue.id, html = issue.description ?? "", editable = RedmineNote.editable(html)
        guard let text = state.descriptionDrafts[id], text != editable ?? html else {
            state.descriptionDrafts[id] = nil
            return
        }
        let change = Redmine.Change(description: text, descriptionRaw: editable == nil || !WorkLogSettings.shared.redmineHTML)
        store.update(id, change) { ok in if ok { state.descriptionDrafts[id] = nil } }
    }

    /// 설명 보기·고치기. 평문으로 고치면 서식을 잃는 설명은 HTML 그대로 고친다.
    @ViewBuilder private func description(_ issue: Redmine.Issue) -> some View {
        let html = issue.description ?? ""
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("설명").font(WL.section)
                Spacer()
                if state.descriptionDrafts[issue.id] == nil {
                    Button("고치기") { state.descriptionDrafts[issue.id] = RedmineNote.editable(html) ?? html }
                    .buttonStyle(TextLinkButtonStyle())
                }
            }
            if state.descriptionDrafts[issue.id] != nil {
                TextEditor(text: Binding(get: { state.descriptionDrafts[issue.id] ?? "" }, set: { state.descriptionDrafts[issue.id] = $0 }))
                    .scrollContentBackground(.hidden)
                    .font(WL.body).frame(minHeight: 160).padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
                HStack {
                    if RedmineNote.editable(html) == nil {
                        Text("목록·표·링크 같은 서식이 있어 HTML 그대로 고칩니다").font(WL.caption).foregroundStyle(WL.waiting)
                    }
                    Spacer()
                    Button("취소") { state.descriptionDrafts[issue.id] = nil }.buttonStyle(NotionButtonStyle())
                    Button("저장") { saveDescription(issue) }
                        .buttonStyle(NotionButtonStyle(kind: .primary))
                        .disabled(store.isBusy(issue.id))
                }
            } else if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("설명이 없습니다").font(WL.meta).foregroundStyle(WL.quiet)
            } else {
                HTMLText(html: html, rendered: HTMLCache.shared.cached(html))
                let inline = Redmine.images(in: html, attachments: issue.attachments ?? [])
                if !inline.isEmpty {
                    FlowLayout(spacing: 8) { ForEach(unique(inline)) { imageTile($0, issue: issue.id, size: 150) } }
                }
            }
        }
    }

    /// 같은 그림을 본문에 두 번 넣어도 한 번만 보인다.
    private func unique(_ files: [Redmine.Attachment]) -> [Redmine.Attachment] {
        var seen = Set<Int>()
        return files.filter { seen.insert($0.id).inserted }
    }

    // MARK: 칸 (레드마인 일감 화면처럼 두 줄로)

    private func fields(_ issue: Redmine.Issue) -> some View {
        let busy = store.isBusy(issue.id)
        return HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 0) {
                fieldRow("상태") {
                    menu(issue.status.name) {
                        ForEach(store.statuses) { status in
                            let blocked = store.isBlocked(from: issue.status.id, to: status.id)
                            Button(status.name + (blocked ? " (전에 막힘)" : "")) { store.update(issue.id, Redmine.Change(statusID: status.id)) }
                                .disabled(status.id == issue.status.id)
                        }
                    }
                }
                fieldRow("우선순위") {
                    menu(issue.priority.name) {
                        ForEach(store.priorities) { priority in
                            Button(priority.name) { store.update(issue.id, Redmine.Change(priorityID: priority.id)) }
                                .disabled(priority.id == issue.priority.id)
                        }
                    }
                }
                fieldRow("담당자") {
                    menu(issue.assignedTo?.name ?? "없음") {
                        Button("나에게") { assignToMe(issue) }.disabled(store.me.map { $0.id == issue.assignedTo?.id } ?? false)
                        Divider()
                        ForEach(store.people[issue.project.id] ?? []) { person in
                            Button(person.name) { store.update(issue.id, Redmine.Change(assignedToID: person.id)) }
                                .disabled(person.id == issue.assignedTo?.id)
                        }
                        Divider()
                        Button("비우기") { store.update(issue.id, Redmine.Change(assignedToID: 0)) }.disabled(issue.assignedTo == nil)
                    }
                }
                fieldRow("트래커") {
                    menu(issue.tracker.name) {
                        ForEach(store.projects.first { $0.id == issue.project.id }?.trackers ?? store.trackers) { tracker in
                            Button(tracker.name) { store.update(issue.id, Redmine.Change(trackerID: tracker.id)) }
                                .disabled(tracker.id == issue.tracker.id)
                        }
                    }
                }
                if let watchers = issue.watchers, !watchers.isEmpty {
                    fieldRow("지켜보는 사람") { Text(watchers.map(\.name).joined(separator: ", ")).font(WL.meta).lineLimit(2) }
                }
            }
            VStack(spacing: 0) {
                fieldRow("시작일") { dateMenu(issue, value: issue.startDate, key: "start") }
                fieldRow("완료 기한") { dateMenu(issue, value: issue.dueDate, key: "due") }
                fieldRow("진척률") {
                    HStack(spacing: 10) {
                        RatioBar(ratio: issue.doneRatio).frame(width: 90)
                        menu("\(issue.doneRatio)%") {
                            ForEach(Array(stride(from: 0, through: 100, by: 10)), id: \.self) { ratio in
                                Button("\(ratio)%") { store.update(issue.id, Redmine.Change(doneRatio: ratio)) }
                                    .disabled(ratio == issue.doneRatio)
                            }
                        }
                    }
                }
                fieldRow("시간") {
                    menu(issue.estimatedHours.flatMap { $0 > 0 ? "추정 \(hours($0))" : nil } ?? "추정 없음") {
                        ForEach([1.0, 2, 4, 8, 16, 24, 40], id: \.self) { value in
                            Button(hours(value)) { store.update(issue.id, Redmine.Change(estimatedHours: value)) }
                                .disabled(issue.estimatedHours == value)
                        }
                        Divider()
                        Button("비우기") { store.update(issue.id, Redmine.Change(estimatedHours: 0)) }.disabled(issue.estimatedHours == nil)
                    }
                    Text(issue.spentHours.flatMap { $0 > 0 ? "소요 \(hours($0))" : nil } ?? "소요 없음")
                        .font(WL.meta).foregroundStyle(WL.muted)
                    Button("시간 기록") { state.loggingTime = true }
                        .buttonStyle(TextLinkButtonStyle())
                        .popover(isPresented: $state.loggingTime) { TimeEntryForm(store: store, issue: issue.id) }
                }
            }
        }
        .disabled(busy)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WL.sidebar))
    }

    private func hours(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))시간" : String(format: "%.1f시간", value)
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(WL.meta).foregroundStyle(WL.muted).frame(width: 78, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(WL.border).frame(height: 0.5) }
    }

    /// 값 자리에 둔 메뉴. 값 글자에 작은 화살표를 붙여 누를 수 있다는 것을 보인다.
    private func menu<Content: View>(_ value: String, @ViewBuilder content: () -> Content) -> some View {
        // 누를 수 있는 칸임을 보이게 값에 바탕을 깐다 (읽기만 하는 값과 가른다)
        Menu { content() } label: { Text(value).font(WL.meta.weight(.medium)) }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
    }

    private func dateMenu(_ issue: Redmine.Issue, value: String?, key: String) -> some View {
        let today = WorkDay.today()
        func set(_ day: String) {
            store.update(issue.id, key == "start" ? Redmine.Change(startDate: day) : Redmine.Change(dueDate: day))
        }
        return HStack(spacing: 6) {
            menu(value.map { WorkLogFormat.shortDay($0) } ?? "없음") {
                Button("오늘 (\(WorkLogFormat.shortDay(today)))") { set(today) }
                Button("내일") { set(WorkDay.adding(1, to: today)) }
                // 주말에 고르면 이번 주 금요일은 이미 지나, 다가오는 금요일만 보인다
                let friday = WorkDay.adding(4, to: WorkDay.week(of: today).lowerBound)
                if friday >= today { Button("이번 주 금요일") { set(friday) } }
                Button("다음 주 금요일") { set(WorkDay.adding(7, to: friday)) }
                Divider()
                Button("날짜 고르기…") {
                    state.pickedDate = value.flatMap(WorkDay.date) ?? Date()
                    state.editingDate = key
                }
                Button("비우기") { set("") }.disabled(value == nil)
            }
            .popover(isPresented: Binding(get: { state.editingDate == key }, set: { if !$0 { state.editingDate = nil } })) {
                VStack(alignment: .trailing, spacing: 8) {
                    DatePicker("", selection: $state.pickedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden()
                    Button("정하기") {
                        set(WorkDay.key(state.pickedDate))
                        state.editingDate = nil
                    }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            if key == "due", let value, issue.doneRatio < 100, value < today, store.statuses.first(where: { $0.id == issue.status.id })?.isClosed != true {
                Text("지남").font(WL.caption).foregroundStyle(Palette.red)
            }
        }
    }

    // MARK: 묶음

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(WL.section)
            content()
        }
    }

    private func childList(_ children: [Redmine.Child], depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            ForEach(children) { child in
                Button { store.selected = child.id } label: {
                    HStack(spacing: 6) {
                        if depth > 0 { Color.clear.frame(width: CGFloat(depth) * 16) }
                        if let tracker = child.tracker { TrackerTag(name: tracker.name) }
                        Text(verbatim: "#\(child.id)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet)
                        Text(child.subject).font(WL.meta).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let grand = child.children, !grand.isEmpty { childList(grand, depth: depth + 1) }
            }
        })
    }

    private func children(_ issue: Redmine.Issue) -> some View {
        let list = issue.children ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(list.isEmpty ? "하위 일감" : "하위 일감 \(list.count)").font(WL.section)
                Button("+ 하위 일감") { store.createChild(of: issue) }.buttonStyle(TextLinkButtonStyle())
            }
            if !list.isEmpty { childList(list, depth: 0) }
        }
    }

    /// 관계 일감. 없는 일감이 많아 더하는 칸은 눌렀을 때만 편다.
    private func relations(_ issue: Redmine.Issue) -> some View {
        let list = issue.relations ?? [], open = state.relationOpen.contains(issue.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(list.isEmpty ? "관계 일감" : "관계 일감 \(list.count)").font(WL.section)
                Button(open ? "접기" : "+ 관계") {
                    if open { state.relationOpen.remove(issue.id) } else { state.relationOpen.insert(issue.id) }
                }
                .buttonStyle(TextLinkButtonStyle())
            }
            if !list.isEmpty || open { relationList(list, issue: issue.id, adding: open) }
        }
    }

    private func relationList(_ relations: [Redmine.Relation], issue: Int, adding: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(relations) { relation in
                let (other, label) = relation.describe(from: issue)
                HStack(spacing: 8) {
                    Button { store.selected = other } label: {
                        HStack(spacing: 8) {
                            Text(label).font(WL.caption).foregroundStyle(WL.muted).frame(width: 48, alignment: .leading)
                            Text(verbatim: "#\(other)").font(WL.meta.monospacedDigit())
                            Spacer(minLength: 0)
                        }
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { store.removeRelation(relation.id, issue: issue) } label: { Image(systemName: "xmark") }
                        .buttonStyle(GhostIconButtonStyle())
                        .disabled(store.removingRelations.contains(relation.id))
                        .tip("관계 지우기")
                }
            }
            if adding { HStack(spacing: 6) {
                Picker("", selection: $state.relationType) {
                    ForEach(Redmine.relationTypes, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().frame(width: 84)
                TextField("일감 번호", text: Binding(get: { state.relationTargets[issue] ?? "" }, set: { state.relationTargets[issue] = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                    .onSubmit { addRelation(issue) }
                Button("관계 추가") { addRelation(issue) }
                    .buttonStyle(TextLinkButtonStyle())
                    .disabled(Redmine.issueNumber(state.relationTargets[issue] ?? "").map { $0 == issue } ?? true)
            }
            .padding(.top, 4) }
        }
    }

    private func addRelation(_ issue: Int) {
        guard let target = Redmine.issueNumber(state.relationTargets[issue] ?? ""), target != issue else { return }
        store.addRelation(issue, to: target, type: state.relationType) { ok in if ok { state.relationTargets[issue] = nil } }
    }

    /// 그림은 작은 그림으로, 나머지는 줄로 보인다. 웹 로그인 없이 앱의 키로 받는다.
    private func attachmentList(_ attachments: [Redmine.Attachment], issue: Int) -> some View {
        let images = attachments.filter(\.isImage), others = attachments.filter { !$0.isImage }
        return VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(images) { file in imageTile(file, issue: issue, size: 150) }
                }
            }
            ForEach(others) { file in
                Button { store.download(file) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc").foregroundStyle(WL.muted).frame(width: 16)
                        Text(file.filename).font(WL.meta).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.filesize), countStyle: .file))
                            .font(WL.caption).foregroundStyle(WL.quiet)
                        Spacer(minLength: 0)
                        if let author = file.author { Text(author.name).font(WL.caption).foregroundStyle(WL.quiet) }
                    }
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { attachmentMenu(file, issue: issue) }
                .tip("내려받기 폴더에 받아 Finder에서 보입니다")
            }
        }
    }

    private func imageTile(_ file: Redmine.Attachment, issue: Int, size: CGFloat) -> some View {
        Button { state.preview = file } label: {
            Group {
                if let image = store.images[file.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(WL.faint)
                }
            }
            .frame(width: size, height: size * 0.7)
            .clipped()
            .background(WL.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onAppear { store.loadImage(file) }
        .contextMenu { attachmentMenu(file, issue: issue) }
        .tip(file.filename)
    }

    @ViewBuilder private func attachmentMenu(_ file: Redmine.Attachment, issue: Int) -> some View {
        Button("내려받기") { store.download(file) }
        Button("지우기…", role: .destructive) {
            let alert = NSAlert()
            alert.messageText = "\(file.filename)을 지울까요?"
            alert.addButton(withTitle: "지우기")
            alert.addButton(withTitle: "취소")
            if alert.runModal() == .alertFirstButtonReturn { store.deleteAttachment(file.id, issue: issue) }
        }
    }

    // MARK: 이력 (레드마인처럼 번호·사람·때, 바뀐 칸, 댓글)

    private func history(_ issue: Redmine.Issue) -> some View {
        let people = store.people[issue.project.id] ?? []
        let all = Array((issue.journals ?? []).enumerated())
        let shown = all.filter { _, journal in
            let notes = !(journal.notes ?? "").isEmpty, changes = !(journal.details ?? []).isEmpty
            switch state.history {
            case .all: return notes || changes
            case .comments: return notes
            case .changes: return changes
            }
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("이력").font(WL.section)
                Spacer()
                Picker("", selection: $state.history) {
                    ForEach(RedmineViewState.HistoryTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if shown.isEmpty {
                Text(state.history == .comments ? "댓글이 없습니다" : "이력이 없습니다").font(WL.meta).foregroundStyle(WL.quiet)
            }
            ForEach(shown, id: \.element.id) { number, journal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Initials(name: journal.user?.name ?? "?")
                        Text(journal.user?.name ?? "알 수 없음").font(WL.meta.weight(.semibold))
                        if let created = journal.created { Text(WorkLogFormat.when(created)).font(WL.caption).foregroundStyle(WL.quiet) }
                        if journal.privateNotes == true {
                            Label("비공개", systemImage: "lock.fill").font(WL.caption).foregroundStyle(WL.waiting)
                        }
                        Spacer()
                        Text(verbatim: "#\(number + 1)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.faint)
                        if !(journal.notes ?? "").isEmpty { journalMenu(journal, issue: issue) }
                    }
                    if state.history != .comments, let details = journal.details, !details.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                                Text("• " + Redmine.describe(detail, statuses: store.statuses, trackers: store.trackers,
                                                              priorities: store.priorities, people: people))
                                    .font(WL.caption).foregroundStyle(WL.muted)
                            }
                        }
                        .padding(.leading, 30)
                    }
                    if state.history != .changes, let notes = journal.notes, !notes.isEmpty {
                        if state.journalDrafts[journal.id] != nil {
                            journalEditor(journal, issue: issue.id, notes: notes).padding(.leading, 30)
                        } else {
                            HTMLText(html: notes, rendered: HTMLCache.shared.cached(notes))
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WL.sidebar))
                                .padding(.leading, 30)
                        }
                    }
                    // 본문이 넣은 그림과 그 기록에서 더한 그림 (본문 글에는 그림 자리만 남는다)
                    let added = unique(Redmine.images(in: journal.notes ?? "", attachments: issue.attachments ?? [])
                                       + (issue.attachments ?? []).filter { journal.attachmentIDs.contains($0.id) && $0.isImage })
                    if !added.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(added) { file in imageTile(file, issue: issue.id, size: 120) }
                        }
                        .padding(.leading, 30)
                    }
                }
            }
        }
    }

    /// 댓글 하나의 일. 레드마인 웹의 인용·고치기·지우기와 같다.
    private func journalMenu(_ journal: Redmine.Journal, issue: Redmine.Issue) -> some View {
        Menu {
            Button("인용") { quote(journal, issue: issue.id) }
            if !store.journalAPI {
                Button("웹에서 고치기") { store.openJournal(journal.id, issue: issue.id) }
            } else if let me = store.me, journal.user?.id == me.id {
                Button("고치기") {
                    if state.history == .changes { state.history = .all }
                    state.journalDrafts[journal.id] = RedmineNote.editable(journal.notes ?? "") ?? journal.notes ?? ""
                }
                Button("지우기…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "이 댓글을 지울까요?"
                    alert.addButton(withTitle: "지우기")
                    alert.addButton(withTitle: "취소")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    store.editJournal(journal.id, issue: issue.id, notes: "") { _ in }
                }
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tip("댓글 인용, 고치기, 지우기")
    }

    private func quote(_ journal: Redmine.Journal, issue: Int) {
        let lines = RedmineNote.plain(journal.notes ?? "").components(separatedBy: .newlines).map { "> " + $0 }
        let text = "\(journal.user?.name ?? "이전 사람")의 덧글:\n" + lines.joined(separator: "\n") + "\n\n"
        state.comments[issue] = (state.comments[issue] ?? "") + text
        // 비공개 댓글을 인용한 글이 공개로 나가지 않게 한다
        if journal.privateNotes == true { state.privateNotes.insert(issue) }
    }

    private func journalEditor(_ journal: Redmine.Journal, issue: Int, notes: String) -> some View {
        let plain = RedmineNote.editable(notes)
        return VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(get: { state.journalDrafts[journal.id] ?? "" }, set: { state.journalDrafts[journal.id] = $0 }))
                .scrollContentBackground(.hidden)
                .font(WL.body).frame(minHeight: 90).padding(6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            HStack {
                if plain == nil { Text("서식이 있어 HTML 그대로 고칩니다").font(WL.caption).foregroundStyle(WL.waiting) }
                Spacer()
                Button("취소") { state.journalDrafts[journal.id] = nil }.buttonStyle(NotionButtonStyle())
                Button("저장") {
                    TextInput.afterComposition {
                        let text = state.journalDrafts[journal.id] ?? ""
                        let html = plain != nil && WorkLogSettings.shared.redmineHTML ? RedmineNote.html(text) : text
                        guard !html.isEmpty else { return }
                        store.editJournal(journal.id, issue: issue, notes: html) { ok in
                            if ok { state.journalDrafts[journal.id] = nil }
                        }
                    }
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                // 비워서 저장하면 확인 없이 지워져, 지우기는 메뉴로만 한다
                .disabled(store.isBusy(issue) || store.editingJournals.contains(journal.id)
                          || (state.journalDrafts[journal.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func confirmDelete(_ issue: Redmine.Issue) {
        let alert = NSAlert()
        alert.messageText = "#\(issue.id)을 지울까요?"
        let spent = (issue.spentHours ?? 0) > 0 ? "기록한 소요 시간도 함께 지워질 수 있습니다. " : ""
        alert.informativeText = spent + "하위 일감과 이력이 함께 지워지고 되돌릴 수 없습니다."
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn { store.deleteIssue(issue.id) }
    }

    // MARK: 댓글

    private func composer(_ issue: Redmine.Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let empty = (state.comments[issue.id] ?? "").isEmpty
            TextEditor(text: Binding(get: { state.comments[issue.id] ?? "" }, set: { state.comments[issue.id] = $0 }))
                .font(WL.body)
                .scrollContentBackground(.hidden)
                .scrollIndicators(empty ? .never : .automatic)
                // 비어 있으면 이력을 가리지 않게 한 줄로 두고, 쓰기 시작하면 넓힌다
                .frame(height: empty ? 24 : 96)
                .overlay(alignment: .topLeading) {
                    if empty {
                        Text("댓글 쓰기").font(WL.body).foregroundStyle(WL.quiet).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            let files = state.files[issue.id] ?? []
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.self) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip").foregroundStyle(WL.muted)
                            Text(file.lastPathComponent).font(WL.meta).lineLimit(1).truncationMode(.middle)
                            Button { state.files[issue.id]?.removeAll { $0 == file } } label: { Image(systemName: "xmark") }
                                .buttonStyle(GhostIconButtonStyle())
                        }
                    }
                }
            }
            HStack {
                Button { pickFiles(issue.id) } label: { Label("파일 첨부", systemImage: "paperclip") }
                    .buttonStyle(TextLinkButtonStyle())
                Toggle("비공개", isOn: Binding(get: { state.privateNotes.contains(issue.id) }, set: { on in
                    if on { state.privateNotes.insert(issue.id) } else { state.privateNotes.remove(issue.id) }
                }))
                .toggleStyle(.checkbox).font(WL.caption)
                .tip("권한이 있는 사람에게만 보이는 댓글")
                Text("[작업 내용]처럼 대괄호 머리를 쓰면 단락이 나뉩니다").font(WL.caption).foregroundStyle(WL.quiet)
                Spacer()
                Button(store.sending.contains(issue.id) ? "보내는 중…" : "댓글 남기기") {
                    // 한글을 조합하는 중에 ⌘↩를 누르면 마지막 글자가 아직 글에 없어 조합을 끝낸 뒤 읽는다
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { editor.unmarkText() }
                    DispatchQueue.main.async {
                        let id = issue.id, text = state.comments[id] ?? "", sending = state.files[id] ?? []
                        store.comment(id, text: text, files: sending, isPrivate: state.privateNotes.contains(id)) { ok in
                            // 보내는 사이 고쳐 쓴 글과 더 붙인 파일은 지우지 않는다
                            guard ok else { return }
                            if state.comments[id] == text { state.comments[id] = nil }
                            state.privateNotes.remove(id)
                            state.files[id]?.removeAll { sending.contains($0) }
                        }
                    }
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(((state.comments[issue.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty)
                          || store.isBusy(issue.id))
                .tip("⌘↩")
            }
        }
    }

    private func pickFiles(_ id: Int) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let chosen = state.files[id] ?? []
            state.files[id] = chosen + panel.urls.filter { !chosen.contains($0) }
        }
    }

    // MARK: 일지·담당자

    /// 업무 일지 장부에 있는 일감이면 그 이름(메뉴 경로)으로, 없으면 제목으로 오늘 줄을 넣는다.
    private func addToLog(_ issue: Redmine.Issue) {
        let log = WorkLogStore.shared
        let info = log.log.issue(issue.id) ?? IssueInfo(
            id: issue.id, subject: issue.subject, project: issue.project.name, tracker: issue.tracker.name,
            status: issue.status.name, doneRatio: issue.doneRatio, dueDate: issue.dueDate, priority: issue.priority.name,
            startDate: issue.startDate, statusID: issue.status.id, projectID: issue.project.id,
            assignee: issue.assignedTo.map { RedmineAPI.Member(id: $0.id, name: $0.name) })
        // 닫힌 상태(완료·종료 등)는 진척률이 0이어도 끝난 일이다
        let closed = store.statuses.first { $0.id == issue.status.id }?.isClosed == true
        let status: WorkStatus = issue.doneRatio >= 100 || closed ? .done : issue.doneRatio > 0 ? .percent(issue.doneRatio) : .inProgress
        if let entry = log.addIssue(info, day: WorkDay.today(), status: status) {
            // 이미 있던 줄이면 돌려받는 값은 고치기 전이라 넣은 상태로 알린다
            var added = entry
            added.status = status
            store.flash = "오늘 일지에 넣었습니다: \(added.project) · \(WorkReport.line(added))"
        }
    }

    private func assignToMe(_ issue: Redmine.Issue) {
        guard let me = store.me else {
            store.flash = "내 계정을 아직 받지 못했습니다. 잠시 뒤 다시 고르세요"
            return
        }
        store.update(issue.id, Redmine.Change(assignedToID: me.id))
    }
}

/// 시간 기록 창의 입력값.
private final class TimeDraft: ObservableObject {
    @Published var day = Date()
    @Published var hours = "1"
    @Published var activityID: Int?
    @Published var comment = ""
    @Published var sending = false
    @Published var error: String?
}

/// 일감에 소요 시간을 남긴다. 시간은 `1.5`처럼 소수로 받는다.
struct TimeEntryForm: View {
    @ObservedObject var store: RedmineStore
    let issue: Int
    @StateObject private var draft = TimeDraft()
    @Environment(\.dismiss) private var dismiss

    private var hours: Double? { Double(draft.hours.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 && $0 <= 24 ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("시간 기록").font(WL.heading)
            DatePicker("날짜", selection: $draft.day, displayedComponents: .date)
            HStack(spacing: 6) {
                Text("시간")
                TextField("1.5", text: $draft.hours).textFieldStyle(.roundedBorder).frame(width: 60)
                ForEach(["0.5", "1", "2", "4"], id: \.self) { value in
                    Button(value) { draft.hours = value }.buttonStyle(ChipButtonStyle(selected: draft.hours == value))
                }
            }
            // 이 레드마인은 기본 활동이 없어 고르지 않으면 받지 않는다
            Picker("활동", selection: $draft.activityID) {
                Text("고르세요").tag(Int?.none)
                ForEach(store.activities) { Text($0.name).tag(Int?.some($0.id)) }
            }
            TextField("메모 (선택)", text: $draft.comment).textFieldStyle(.roundedBorder)
            if let error = draft.error { Text(error).font(WL.caption).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true) }
            Text("권한에 따라 기록한 시간은 지우지 못할 수 있습니다").font(WL.caption).foregroundStyle(WL.quiet)
            HStack {
                Spacer()
                Button("기록") {
                    guard let hours else { return }
                    draft.sending = true
                    draft.error = nil
                    store.logTime(issue, day: WorkDay.key(draft.day), hours: hours, activityID: draft.activityID, comment: draft.comment) { error in
                        draft.sending = false
                        if let error { draft.error = error } else { dismiss() }
                    }
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(hours == nil || draft.activityID == nil || draft.sending)
            }
        }
        .font(WL.meta)
        .padding(14)
        .frame(width: 320)
    }
}

/// 새 일감 창의 입력값.
private final class NewIssueDraft: ObservableObject {
    @Published var projectID: Int?
    @Published var trackerID: Int?
    @Published var subject = ""
    @Published var description = ""
    @Published var priorityID: Int?
    @Published var assigneeID: Int?
    @Published var parent = ""
    /// 취소하면 돌아갈 상위 일감.
    var returnTo: Int?
    /// 복사한 설명이 HTML 그대로라 다시 변환하지 않는다.
    var rawDescription = false
    @Published var hasStart = false
    @Published var start = Date()
    @Published var hasDue = false
    @Published var due = Date()
    @Published var sending = false
    @Published var error: String?
}

/// 새 일감 만들기. 프로젝트 화면에서 열면 그 프로젝트를 고른 채로 연다.
struct RedmineNewIssueSheet: View {
    @ObservedObject var store: RedmineStore
    @StateObject private var draft = NewIssueDraft()
    @Environment(\.dismiss) private var dismiss

    private var project: Redmine.Project? { store.projects.first { $0.id == draft.projectID } }
    private var trackers: [Redmine.Ref] { project?.trackers ?? store.trackers }
    private var parentID: Int? { Int(draft.parent.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) }
    private var parentValid: Bool { draft.parent.trimmingCharacters(in: .whitespaces).isEmpty || parentID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("새 일감").font(WL.title).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)
            VStack(spacing: 6) {
                TextField("제목", text: $draft.subject).textFieldStyle(.plain).font(.system(size: 17, weight: .semibold))
                Rectangle().fill(WL.border).frame(height: 1)
            }
            .padding(.horizontal, 24).padding(.top, 16)
            Form {
                Picker("프로젝트", selection: $draft.projectID) {
                    ForEach(store.projects) { Text($0.name).tag(Int?.some($0.id)) }
                }
                Picker("트래커", selection: $draft.trackerID) {
                    ForEach(trackers) { Text($0.name).tag(Int?.some($0.id)) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("설명")
                    TextEditor(text: $draft.description).font(WL.body).frame(height: 120).padding(4)
                }
                Picker("우선순위", selection: $draft.priorityID) {
                    Text("기본값").tag(Int?.none)
                    ForEach(store.priorities) { Text($0.name).tag(Int?.some($0.id)) }
                }
                Picker("담당자", selection: $draft.assigneeID) {
                    Text("없음").tag(Int?.none)
                    if let me = store.me { Text("나에게 (\(me.name))").tag(Int?.some(me.id)) }
                    ForEach((draft.projectID.flatMap { store.people[$0] } ?? []).filter { $0.id != store.me?.id }) { Text($0.name).tag(Int?.some($0.id)) }
                }
                LabeledContent("상위 일감") {
                    TextField("", text: $draft.parent, prompt: Text("번호 (선택)")).textFieldStyle(.roundedBorder).frame(width: 120)
                }
                dateRow("시작일", on: $draft.hasStart, date: $draft.start)
                dateRow("완료 기한", on: $draft.hasDue, date: $draft.due)
            }
            .formStyle(.grouped)
            .font(WL.meta)
            if let error = draft.error {
                Text(error).font(WL.meta).foregroundStyle(Palette.red).padding(.horizontal, 24).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("제목을 입력하세요").font(WL.caption).foregroundStyle(WL.quiet)
                } else if !parentValid {
                    Text("상위 일감은 번호로 쓰세요").font(WL.caption).foregroundStyle(WL.waiting)
                }
                Spacer()
                Button("취소") {
                    dismiss()
                    // 일감 창에서 하위를 만들러 왔으면 그 창으로 돌아간다
                    if let back = draft.returnTo {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { store.selected = back }
                    }
                }
                .buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
                Button("만들기") { submit() }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!ready || draft.sending)
                    .tip("⌘↩")
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .background(WL.canvas)
        .onAppear {
            if let source = store.creatingFrom {
                store.creatingFrom = nil
                draft.projectID = source.project.id
                draft.subject = source.subject
                // 서식이 있는 설명은 잃지 않게 HTML 그대로 옮긴다
                let html = source.description ?? ""
                draft.description = RedmineNote.editable(html) ?? html
                draft.rawDescription = RedmineNote.editable(html) == nil
                draft.priorityID = source.priority.id
                draft.trackerID = source.tracker.id
                draft.assigneeID = source.assignedTo?.id
                if let start = source.startDate.flatMap(WorkDay.date) { (draft.hasStart, draft.start) = (true, start) }
                if let due = source.dueDate.flatMap(WorkDay.date) { (draft.hasDue, draft.due) = (true, due) }
                draft.returnTo = source.id
            } else if let parent = store.creatingUnder {
                draft.projectID = parent.project.id
                draft.parent = String(parent.id)
                draft.returnTo = parent.id
                store.creatingUnder = nil
            } else if case .project(let project) = store.scope {
                draft.projectID = project.id
            } else {
                draft.projectID = store.projects.first?.id
            }
            pickTracker()
            if let id = draft.projectID { store.loadPeople(project: id) }
        }
        .onChange(of: draft.projectID) { id in
            pickTracker()
            draft.assigneeID = nil
            if let id { store.loadPeople(project: id) }
        }
    }

    private func dateRow(_ title: String, on: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack {
            Text(title)
            Spacer()
            if on.wrappedValue { DatePicker("", selection: date, displayedComponents: .date).labelsHidden() }
            Toggle("", isOn: on).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    private var ready: Bool {
        draft.projectID != nil && draft.trackerID != nil && parentValid
            && !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 프로젝트마다 쓰는 트래커가 달라, 고른 것이 없으면 첫 트래커로 둔다.
    private func pickTracker() {
        if !trackers.contains(where: { $0.id == draft.trackerID }) { draft.trackerID = trackers.first?.id }
    }

    private func submit() {
        guard let projectID = draft.projectID, let trackerID = draft.trackerID else { return }
        var issue = Redmine.NewIssue(projectID: projectID, trackerID: trackerID, subject: draft.subject)
        issue.description = draft.description
        issue.descriptionRaw = draft.rawDescription || !WorkLogSettings.shared.redmineHTML
        issue.priorityID = draft.priorityID
        issue.assignedToID = draft.assigneeID
        issue.parentID = parentID
        if draft.hasStart { issue.startDate = WorkDay.key(draft.start) }
        if draft.hasDue { issue.dueDate = WorkDay.key(draft.due) }
        draft.sending = true
        draft.error = nil
        store.create(issue) { error in
            draft.sending = false
            if let error { draft.error = error } else { store.creating = false }
        }
    }
}

/// 이력의 사람 표시: 이름 첫 글자 동그라미 (사진 대신, 사람마다 같은 색).
private struct Initials: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(WL.projectColor(name)))
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - HTML 글

/// 레드마인이 HTML로 저장한 설명·댓글을 글로 보인다. HTML 해석은 메인 스레드에서 WebKit을 돌려 한 건에 수십 ms가 걸려,
/// 상세를 받을 때 몇 건씩 나눠 미리 해석해 두고(`HTMLCache.warm`), 아직이면 평문으로 먼저 보인다.
/// 링크는 http·https만 연다 (설명에 든 `file://`·앱 주소를 누르는 순간 열지 않게).
private struct HTMLText: View {
    let html: String
    /// 해석해 둔 글. 부모가 넘겨야 해석이 끝났을 때 다시 그려진다 (같은 `html`만 받으면 SwiftUI가 다시 그리지 않는다).
    let rendered: AttributedString?

    var body: some View {
        Text(rendered ?? AttributedString(RedmineNote.plain(html)))
            .font(WL.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
                NSWorkspace.shared.open(url)
                return .handled
            })
    }
}

final class HTMLCache {
    static let shared = HTMLCache()
    /// HTML 전문을 열쇠로 두면 큰 설명이 쌓여 메모리를 먹어, 해시를 열쇠로 둔다.
    private var cache: [Int: AttributedString] = [:]
    private var pending: [String] = []
    private var changed: [() -> Void] = []

    func cached(_ html: String) -> AttributedString? { cache[html.hashValue] }

    /// 아직 해석하지 않은 글을 한 번에 4건씩 메인 스레드에서 해석하고, 끝나면 화면을 다시 그리게 알린다.
    func warm(_ htmls: [String], done: @escaping () -> Void) {
        let fresh = htmls.filter { cache[$0.hashValue] == nil && !pending.contains($0) }
        guard !fresh.isEmpty else { return }
        pending += fresh
        changed.append(done)
        if pending.count == fresh.count { step() }
    }

    private func step() {
        DispatchQueue.main.async { [self] in
            // 넘치면 넣기 전에 비운다 (넣은 뒤 비우면 방금 해석한 글까지 평문으로 돌아간다)
            if cache.count > 600 { cache.removeAll() }
            for html in pending.prefix(4) { cache[html.hashValue] = Self.render(html) }
            pending.removeFirst(min(4, pending.count))
            if pending.isEmpty {
                let callbacks = changed
                changed = []
                callbacks.forEach { $0() }
            } else {
                step()
            }
        }
    }

    static func render(_ html: String) -> AttributedString {
        let safe = RedmineNote.safeHTML(html)
        let parsed: NSMutableAttributedString
        if safe.contains("<") {
            let wrapped = "<meta charset=\"utf-8\"><div style=\"font-family:-apple-system;font-size:13.5px\">\(safe)</div>"
            guard let data = wrapped.data(using: .utf8),
                  let html = try? NSMutableAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil) else {
                return AttributedString(RedmineNote.plain(html))
            }
            parsed = html
        } else {
            // 평문 댓글(옛 Textile)은 줄바꿈을 살려 그대로 보인다
            parsed = NSMutableAttributedString(string: RedmineNote.decodeEntities(safe), attributes: [.font: NSFont.systemFont(ofSize: 13.5)])
        }
        let full = NSRange(location: 0, length: parsed.length)
        parsed.removeAttribute(.foregroundColor, range: full)
        parsed.removeAttribute(.backgroundColor, range: full)
        shortenLinks(parsed)
        // 끝에 붙는 빈 줄을 뗀다
        while parsed.string.hasSuffix("\n") { parsed.deleteCharacters(in: NSRange(location: parsed.length - 1, length: 1)) }
        return (try? AttributedString(parsed, including: \.appKit)) ?? AttributedString(parsed.string)
    }

    /// 글에 그대로 쓴 주소를 누를 수 있게 하고, 긴 주소는 짧은 이름으로 보인다 (`%ED%99…`가 두 줄씩 이어지지 않게).
    private static func shortenLinks(_ text: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let matches = detector.matches(in: text.string, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            text.addAttribute(.link, value: url, range: match.range)
            let label = RedmineNote.linkLabel(url)
            if label != url.absoluteString { text.replaceCharacters(in: match.range, with: label) }
        }
    }
}
