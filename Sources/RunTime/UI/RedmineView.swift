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
                .sheet(item: Binding(get: { store.selected.map(IssueRef.init) }, set: { store.selected = $0?.id })) { _ in
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
            }
            .sidebarRow(selected: on)
        }
        .buttonStyle(.plain)
        .tip(scope.title)
    }
}

/// 시트에 넘기는 일감 번호 (`sheet(item:)`은 Identifiable을 받는다).
private struct IssueRef: Identifiable { let id: Int }

/// 화면 안에서만 쓰는 상태 (이 저장소는 `@State` 대신 ObservableObject를 쓴다).
final class RedmineViewState: ObservableObject {
    /// 일감마다 쓰던 댓글. 하나만 두면 일감을 바꿨을 때 앞 일감에 쓰던 글이 다른 일감에 올라간다.
    @Published var comments: [Int: String] = [:]
    @Published var editingDate: String?
    @Published var pickedDate = Date()
    @Published var history = HistoryTab.all
    @Published var loggingTime = false

    enum HistoryTab: String, CaseIterable { case all = "전체", comments = "댓글", changes = "변경 내역" }
}

private struct RedmineFlash: View {
    @ObservedObject var store: RedmineStore
    var body: some View {
        if let message = store.flash {
            Text(message)
                .font(WL.meta).foregroundStyle(Color.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.bottom, 18)
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
            header(count: rows.count)
            Rectangle().fill(WL.border).frame(height: 1)
            GeometryReader { geo in
                let columns = Self.columns(for: geo.size.width)
                VStack(spacing: 0) {
                    columnHeader(columns)
                    Rectangle().fill(WL.border).frame(height: 1)
                    if let error = store.error {
                        message(error, icon: "exclamationmark.triangle")
                    } else if rows.isEmpty {
                        if store.loading {
                            VStack { ProgressView() }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            message(emptyText, icon: "tray")
                        }
                    } else {
                        SlimScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(rows) { row in TableRow(row: row, columns: columns, store: store) }
                                if store.total > store.issues.count {
                                    Text("레드마인에는 \(store.total)건이 있고 앞의 \(store.issues.count)건만 보입니다. 거르기를 좁혀 보세요")
                                        .font(WL.caption).foregroundStyle(WL.quiet).padding(14)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if !store.search.isEmpty { return "‘\(store.search)’에 맞는 일감이 없습니다" }
        if store.quick != .all { return "\(store.quick.rawValue) 일감이 없습니다" }
        return "이 범위에 \(store.statusFilter.rawValue)이 없습니다"
    }

    // MARK: 머리

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(store.scope.title).font(WL.title).lineLimit(1)
                Text("\(count)건").font(WL.number).foregroundStyle(WL.quiet)
                if store.loading && !store.issues.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
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
                if case .query = store.scope {
                    Text("질의 조건으로 봅니다").font(WL.caption).foregroundStyle(WL.quiet)
                } else {
                    Picker("", selection: $store.statusFilter) {
                        ForEach(RedmineStore.StatusFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
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
                Spacer(minLength: 8)
                Toggle(isOn: $store.treeMode) { Label("트리", systemImage: "list.bullet.indent") }
                    .toggleStyle(.button)
                    .tip("상위 일감 아래에 하위 일감을 들여 씁니다")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("번호·제목·담당자로 찾기", text: $store.search).textFieldStyle(.plain).font(WL.meta)
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(WL.muted) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 210, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: 칸

    /// 보일 칸과 너비. 제목은 남는 너비를 모두 쓴다.
    static func columns(for width: CGFloat) -> [(RedmineStore.Column, CGFloat?)] {
        // 트래커는 제목 앞 태그로, 높은 우선순위는 제목 뒤 표시로 보여 칸을 따로 두지 않는다 (제목이 넓어야 읽힌다)
        var columns: [(RedmineStore.Column, CGFloat?)] = [(.id, 60), (.status, 72), (.subject, nil), (.assignee, 72), (.ratio, 92), (.due, 84), (.updated, 86)]
        if width < 1100 { columns.removeAll { $0.0 == .updated } }
        if width < 780 { columns.removeAll { $0.0 == .ratio } }
        return columns
    }

    private func columnHeader(_ columns: [(RedmineStore.Column, CGFloat?)]) -> some View {
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
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(WL.sidebar)
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

/// 표 한 줄. 제목 칸은 트리 깊이만큼 들여 쓰고, 짧은 일감 이름이면 업무 일지 장부의 메뉴 경로를 옅게 앞에 붙인다.
private struct TableRow: View {
    let row: Redmine.TreeRow
    let columns: [(RedmineStore.Column, CGFloat?)]
    @ObservedObject var store: RedmineStore
    @StateObject private var hover = HoverFlag()

    var body: some View {
        let issue = row.issue
        Button { store.selected = issue.id } label: {
            HStack(spacing: 10) {
                ForEach(columns, id: \.0) { column, width in
                    cell(column, issue)
                        .frame(width: width, alignment: .leading)
                        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 34)
            .background(store.selected == issue.id ? WL.selected : hover.on ? WL.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(WL.border).frame(height: 0.5) }
        .contextMenu {
            Button("일감 열기") { store.selected = issue.id }
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
            Text(issue.status.name).font(WL.meta).foregroundStyle(WL.muted).lineLimit(1)
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
                subject(issue)
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
            if let due = issue.dueDate { DueText(due: due, finished: issue.doneRatio >= 100) } else {
                Text("—").font(WL.caption).foregroundStyle(WL.faint)
            }
        case .updated:
            Text(issue.updated.map { WorkLogFormat.when($0) } ?? "—").font(WL.caption.monospacedDigit()).foregroundStyle(WL.quiet).lineLimit(1)
        }
    }

    private func subject(_ issue: Redmine.Issue) -> some View {
        let path = WorkLogStore.shared.log.issue(issue.id)?.path ?? []
        let prefix = path.isEmpty ? Text("") : Text(path.joined(separator: " › ") + " › ").foregroundColor(WL.quiet)
        return (prefix + Text(issue.subject).foregroundColor(WL.text))
            .font(WL.body)
            .lineLimit(1)
            // 메뉴 경로가 붙으면 끝의 일감 이름이 남게 앞을 자르고, 제목만이면 뒤를 자른다
            .truncationMode(path.isEmpty ? .tail : .head)
            .help(([path.joined(separator: " › ")].filter { !$0.isEmpty } + [issue.subject]).joined(separator: " › "))
    }
}

private struct TrackerTag: View {
    let name: String
    var body: some View {
        let tint: Color = name == "안정화" ? WL.waiting : name == "결함" ? Palette.red : WL.muted
        Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.12)))
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
        .overlay(alignment: .bottom) { RedmineFlash(store: store) }
    }

    private var topBar: some View {
        let ids = store.rows.map(\.id)
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
                Button { addToLog(issue) } label: { Label("오늘 일지에 넣기", systemImage: "text.badge.plus") }
                    .buttonStyle(TextLinkButtonStyle())
                    .tip("오늘 업무 일지에 이 일감 줄을 넣습니다 (이미 있으면 상태만 맞춥니다)")
                if let base = RedmineAPI.baseURL(WorkLogSettings.shared.effectiveRedmineURL) {
                    Button { NSWorkspace.shared.open(Redmine.webURL(base: base, issue: id)) } label: { Label("웹에서 열기", systemImage: "safari") }
                        .buttonStyle(TextLinkButtonStyle())
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
        SlimScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(issue)
                fields(issue)
                if let description = issue.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    section("설명") { HTMLText(html: description, rendered: HTMLCache.shared.cached(description)) }
                }
                if let children = issue.children, !children.isEmpty { section("하위 일감 \(children.count)") { childList(children, depth: 0) } }
                if let relations = issue.relations, !relations.isEmpty { section("관계 일감 \(relations.count)") { relationList(relations, issue: issue.id) } }
                if let attachments = issue.attachments, !attachments.isEmpty { section("첨부 파일 \(attachments.count)") { attachmentList(attachments) } }
                history(issue)
                composer(issue)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
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
            }
            if let path = WorkLogStore.shared.log.issue(issue.id)?.path, !path.isEmpty {
                Text(path.joined(separator: " › ")).font(WL.meta).foregroundStyle(WL.quiet)
            }
            Text(issue.subject).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text([issue.author.map { "\($0.name)이(가) 등록" }, issue.createdOn.flatMap(Redmine.date).map { WorkLogFormat.when($0) },
                  issue.updated.map { "마지막 수정 " + WorkLogFormat.when($0) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(WL.caption).foregroundStyle(WL.quiet)
        }
    }

    // MARK: 칸 (레드마인 일감 화면처럼 두 줄로)

    private func fields(_ issue: Redmine.Issue) -> some View {
        let busy = store.saving.contains(issue.id)
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
                    Text([issue.estimatedHours.flatMap { $0 > 0 ? "추정 \(hours($0))" : nil },
                          issue.spentHours.flatMap { $0 > 0 ? "소요 \(hours($0))" : nil }].compactMap { $0 }.joined(separator: " · ")
                        .ifEmpty("기록 없음"))
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
            if key == "due", let value, issue.doneRatio < 100, value < today {
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

    private func relationList(_ relations: [Redmine.Relation], issue: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(relations) { relation in
                let (other, label) = relation.describe(from: issue)
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
            }
        }
    }

    private func attachmentList(_ attachments: [Redmine.Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(attachments) { file in
                Button {
                    if let url = file.contentUrl.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme ?? "") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: file.isImage ? "photo" : "doc").foregroundStyle(WL.muted).frame(width: 16)
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
                .tip("브라우저에서 엽니다 (레드마인 로그인이 필요할 수 있습니다)")
            }
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
                        Spacer()
                        Text(verbatim: "#\(number + 1)").font(WL.caption.monospacedDigit()).foregroundStyle(WL.faint)
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
                        HTMLText(html: notes, rendered: HTMLCache.shared.cached(notes))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WL.sidebar))
                            .padding(.leading, 30)
                    }
                }
            }
        }
    }

    // MARK: 댓글

    private func composer(_ issue: Redmine.Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("댓글 쓰기").font(WL.section)
            TextEditor(text: Binding(get: { state.comments[issue.id] ?? "" }, set: { state.comments[issue.id] = $0 }))
                .font(WL.body)
                .frame(minHeight: 100)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            HStack {
                Text("[작업 내용]처럼 대괄호 머리를 쓰면 단락이 나뉩니다").font(WL.caption).foregroundStyle(WL.quiet)
                Spacer()
                Button("댓글 남기기") {
                    let id = issue.id, text = state.comments[issue.id] ?? ""
                    store.update(id, Redmine.Change(notes: text)) { ok in
                        // 보내는 사이 고쳐 쓴 글은 지우지 않는다
                        if ok, state.comments[id] == text { state.comments[id] = nil }
                    }
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled((state.comments[issue.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.saving.contains(issue.id))
                .tip("⌘↩")
            }
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
private struct TimeEntryForm: View {
    @ObservedObject var store: RedmineStore
    let issue: Int
    @StateObject private var draft = TimeDraft()
    @Environment(\.dismiss) private var dismiss

    private var hours: Double? { Double(draft.hours.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 && $0 <= 24 ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("시간 기록").font(WL.heading)
            DatePicker("날짜", selection: $draft.day, displayedComponents: .date)
            HStack {
                Text("시간")
                TextField("1.5", text: $draft.hours).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            Picker("활동", selection: $draft.activityID) {
                Text("기본값").tag(Int?.none)
                ForEach(store.activities) { Text($0.name).tag(Int?.some($0.id)) }
            }
            TextField("설명 (선택)", text: $draft.comment).textFieldStyle(.roundedBorder)
            if let error = draft.error { Text(error).font(WL.caption).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true) }
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
                .disabled(hours == nil || draft.sending)
            }
        }
        .font(WL.meta)
        .padding(14)
        .frame(width: 280)
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
    @Published var hasStart = false
    @Published var start = Date()
    @Published var hasDue = false
    @Published var due = Date()
    @Published var sending = false
    @Published var error: String?
}

/// 새 일감 만들기. 프로젝트 화면에서 열면 그 프로젝트를 고른 채로 연다.
private struct RedmineNewIssueSheet: View {
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
            Form {
                Picker("프로젝트", selection: $draft.projectID) {
                    ForEach(store.projects) { Text($0.name).tag(Int?.some($0.id)) }
                }
                Picker("트래커", selection: $draft.trackerID) {
                    ForEach(trackers) { Text($0.name).tag(Int?.some($0.id)) }
                }
                TextField("제목", text: $draft.subject)
                VStack(alignment: .leading, spacing: 4) {
                    Text("설명")
                    TextEditor(text: $draft.description)
                        .font(WL.body).frame(height: 130).padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
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
                TextField("상위 일감 번호 (선택)", text: $draft.parent)
                Toggle("시작일", isOn: $draft.hasStart)
                if draft.hasStart { DatePicker("", selection: $draft.start, displayedComponents: .date).labelsHidden() }
                Toggle("완료 기한", isOn: $draft.hasDue)
                if draft.hasDue { DatePicker("", selection: $draft.due, displayedComponents: .date).labelsHidden() }
            }
            .formStyle(.grouped)
            .font(WL.meta)
            if let error = draft.error {
                Text(error).font(WL.meta).foregroundStyle(Palette.red).padding(.horizontal, 24).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
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
            if case .project(let project) = store.scope { draft.projectID = project.id } else { draft.projectID = store.projects.first?.id }
            pickTracker()
            if let id = draft.projectID { store.loadPeople(project: id) }
        }
        .onChange(of: draft.projectID) { id in
            pickTracker()
            draft.assigneeID = nil
            if let id { store.loadPeople(project: id) }
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
