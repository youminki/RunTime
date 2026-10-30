import AppKit
import SwiftUI
import WorkLogCore

/// 내 일감: 레드마인에서 나에게 배정된 열린 일감을 프로젝트 → 메뉴·화면 순으로 묶어 보인다.
/// 줄에서 바로 고른 날 일지에 넣거나 진척률을 정하면, 보고서와 레드마인 보내기에 그대로 이어진다.
struct IssueBoard: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var sync: WorkLogSync
    @ObservedObject var settings: WorkLogSettings

    var body: some View {
        // 숨긴 레드마인 프로젝트는 머리 숫자와 거르기에서도 뺀다
        let hiddenNames = store.log.hiddenRedmineProjects
        let all = sync.myIssues.filter { !hiddenNames.contains($0.project) }
        let hidden = sync.myIssues.filter { hiddenNames.contains($0.project) }
        let shown = filtered(all)
        VStack(alignment: .leading, spacing: 0) {
            header(all)
            if !settings.redmineReady && all.isEmpty {
                Callout {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("레드마인을 연결하면 나에게 배정된 일감이 여기 모입니다").font(.system(size: 13.5, weight: .semibold))
                        Button("레드마인 연결") { page.settingsSection = .redmine; page.showsSettings = true }
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                    }
                }
            } else if sync.myIssues.isEmpty {
                Callout {
                    Text(sync.loadingIssues ? "일감을 받는 중입니다…" : "열린 일감이 없습니다.")
                        .font(.system(size: 13)).foregroundStyle(WL.muted)
                }
            } else {
                if !settings.redmineReady {
                    Text("레드마인이 이어지지 않아 마지막으로 받은 목록을 보입니다.")
                        .font(.system(size: 13)).foregroundStyle(WL.waiting).padding(.bottom, 10)
                }
                filterBar(all)
                if shown.isEmpty {
                    Text("맞는 일감이 없습니다.").font(.system(size: 13)).foregroundStyle(WL.muted).padding(.vertical, 12)
                }
                ForEach(projects(of: shown), id: \.self) { project in
                    projectSection(project, issues: shown.filter { $0.project == project })
                }
                if !hidden.isEmpty { hiddenFooter(hidden) }
            }
        }
        .onAppear { if settings.redmineReady && sync.issuesLoadedAt == nil { sync.loadMyIssues() } }
    }

    // MARK: 머리

    private func header(_ all: [IssueInfo]) -> some View {
        let today = WorkDay.today()
        let soon = WorkDay.adding(3, to: today)
        let overdue = all.filter { ($0.dueDate ?? "9999") < today }.count
        let dueSoon = all.filter { ($0.dueDate ?? "9999") >= today && ($0.dueDate ?? "9999") <= soon }.count
        let statuses = Dictionary(grouping: all, by: \.status).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        return PageHeading("내 일감") {
            Tally(title: "열린 일감", value: all.count)
            // 상태가 하나뿐이면 열린 일감 수와 같은 말이라 나누어 보이지 않는다
            if statuses.count > 1 { ForEach(statuses.prefix(3), id: \.0) { name, count in Tally(title: name, value: count) } }
            if overdue > 0 { Tally(title: "기한 지남", value: overdue, tint: Palette.red) }
            if dueSoon > 0 { Tally(title: "3일 안", value: dueSoon, tint: WL.waiting) }
            // 다른 날을 골랐을 때만 적을 날을 알린다 (오늘이면 따로 말하지 않는다)
            if page.day != today { DayBadge(text: WorkReport.shortDate(page.day) + "에 적기", tint: WL.muted) }
        } accessory: {
            HStack(spacing: 8) {
                if !settings.redmineReady {
                    Text("레드마인 꺼짐").font(.system(size: 13)).foregroundStyle(WL.quiet)
                } else if sync.loadingIssues {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else if let error = sync.issuesError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(WL.waiting).tip(error)
                } else if let loaded = sync.issuesLoadedAt {
                    Text(WorkLogFormat.when(loaded) + " 받음").font(.system(size: 13)).foregroundStyle(WL.quiet).monospacedDigit()
                }
                Button { sync.loadMyIssues() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GhostIconButtonStyle())
                    .disabled(sync.loadingIssues || !settings.redmineReady)
                    .tip("레드마인에서 새로 받기 (30분마다 저절로 받음)")
            }
        }
    }

    /// 찾기 칸은 한 줄을 다 쓰고, 거르기는 그 아래 칩으로 둔다 (좁은 창에서 찾는 말이 잘리지 않게).
    private func filterBar(_ all: [IssueInfo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(WL.quiet)
                TextField("제목·화면·#번호로 일감 찾기", text: $page.issueQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                if !page.issueQuery.isEmpty {
                    Button { page.issueQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(WL.quiet) }
                        .buttonStyle(.plain)
                        .tip("찾는 말 지우기")
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.callout))
            .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.border, lineWidth: 0.5))
            HStack(spacing: 6) {
                ForEach(WorkLogPage.IssueFilter.allCases, id: \.self) { filter in
                    let on = page.issueFilter == filter
                    Button { page.issueFilter = filter } label: {
                        HStack(spacing: 5) {
                            Text(label(filter))
                            Text("\(count(all, filter))").monospacedDigit().opacity(on ? 0.85 : 0.55)
                        }
                    }
                    .buttonStyle(ChipButtonStyle(selected: on))
                }
            }
        }
        .padding(.bottom, 14)
    }

    /// `오늘 적은`은 고른 날에 맞춰 `10.20 적은`처럼 바꿔 부른다.
    private func label(_ filter: WorkLogPage.IssueFilter) -> String {
        guard filter == .logged, page.day != WorkDay.today() else { return filter.rawValue }
        return WorkReport.shortDate(page.day) + " 적은"
    }

    private func count(_ all: [IssueInfo], _ filter: WorkLogPage.IssueFilter) -> Int {
        let logged = Set(store.log.entries(on: page.day).compactMap(\.issue))
        return all.filter { matches($0, filter, logged: logged) }.count
    }

    private func matches(_ info: IssueInfo, _ filter: WorkLogPage.IssueFilter, logged: Set<Int>) -> Bool {
        switch filter {
        case .all: return true
        case .working: return info.doneRatio > 0 || logged.contains(info.id)
        case .due: return (info.dueDate ?? "9999") <= WorkDay.adding(3, to: WorkDay.today())
        case .logged: return logged.contains(info.id)
        }
    }

    private func filtered(_ all: [IssueInfo]) -> [IssueInfo] {
        let logged = Set(store.log.entries(on: page.day).compactMap(\.issue))
        let query = page.issueQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { info in
            guard matches(info, page.issueFilter, logged: logged) else { return false }
            guard !query.isEmpty else { return true }
            let text = ([info.subject, info.reportTitle, "#\(info.id)"] + info.path).joined(separator: " ").lowercased()
            return query.split(separator: " ").allSatisfy { text.contains($0) }
        }
    }

    private func projects(of issues: [IssueInfo]) -> [String] {
        var order: [String] = []
        for info in issues where !order.contains(info.project) { order.append(info.project) }
        return order
    }

    // MARK: 묶음

    private func projectSection(_ project: String, issues: [IssueInfo]) -> some View {
        let key = "issues:" + project
        let collapsed = page.isCollapsed(key)
        let groups = Dictionary(grouping: issues, by: \.group)
        let order = issues.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let reportName = issues.first.map { store.log.reportProject(for: $0) } ?? project
        return VStack(alignment: .leading, spacing: 0) {
            ToggleHeading(collapsed: collapsed, toggle: { page.toggle(key) }) {
                HStack(spacing: 8) {
                    Text(project).font(WL.section)
                    Text("\(issues.count)").font(.system(size: 13.5)).foregroundStyle(WL.quiet).monospacedDigit()
                }
            } trailing: {
                Button {
                    store.setRedmineHidden(project, true)
                    page.flash("‘\(project)’ 일감을 숨겼습니다. 맨 아래에서 다시 보입니다")
                } label: { Image(systemName: "eye.slash") }
                .buttonStyle(GhostIconButtonStyle())
                .tip("이 프로젝트 일감 숨기기")
            }
            reportNameRow(project, current: reportName)
            if !collapsed {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(order, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group).font(.system(size: 13, weight: .medium)).foregroundStyle(WL.muted)
                                .padding(.horizontal, 6).padding(.bottom, 2)
                            ForEach(groups[group] ?? []) { info in
                                IssueRow(store: store, page: page, settings: settings, sync: sync, info: info)
                            }
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 6)
            }
        }
        .padding(.bottom, 22)
    }

    /// 숨긴 레드마인 프로젝트를 이름 칩으로 모아 두고, 누르면 다시 보인다.
    private func hiddenFooter(_ hidden: [IssueInfo]) -> some View {
        let names = projects(of: hidden)
        return VStack(alignment: .leading, spacing: 6) {
            Text("숨긴 프로젝트 \(names.count)개 · 일감 \(hidden.count)개").font(.system(size: 13)).foregroundStyle(WL.quiet)
            FlowLayout(spacing: 4) {
                ForEach(names, id: \.self) { name in
                    Button { store.setRedmineHidden(name, false) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "eye").font(.system(size: 11.5))
                            Text(name)
                        }
                        .foregroundStyle(WL.muted)
                    }
                    .buttonStyle(GhostTextButtonStyle())
                    .tip("다시 보이기")
                }
            }
        }
        .padding(.top, 8)
    }

    /// 보고서에 쓸 프로젝트 이름 (예: 경북대학교 빅데이터플랫폼 구축 → VeloX).
    private func reportNameRow(_ project: String, current: String) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 16, height: 1)
            Text("보고서 이름").font(.system(size: 13)).foregroundStyle(WL.quiet)
            if page.renamingRedmine == project {
                TextField("VeloX", text: $page.redmineRenameText, onCommit: {
                    store.setReportProject(page.redmineRenameText, for: project)
                    page.renamingRedmine = nil
                })
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onExitCommand { page.renamingRedmine = nil }
            } else {
                Menu {
                    ForEach(store.log.visibleProjects, id: \.self) { name in
                        Button(name) { store.setReportProject(name, for: project) }
                    }
                    Divider()
                    Button("새 이름…") { page.redmineRenameText = current; page.renamingRedmine = project }
                } label: {
                    HStack(spacing: 5) {
                        ProjectSwatch(name: current, size: 8)
                        Text(current).font(.system(size: 13, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tip("이 레드마인 프로젝트의 일감을 보고서에서 이 이름 아래에 적습니다")
            }
        }
        .frame(height: 24)
    }
}

/// 가운데 칸이 좁은지. 좁으면 일감 줄에서 진척률을 빼고 기간을 마감일만 보여 제목 자리를 남긴다.
private struct NarrowRowsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var narrowRows: Bool {
        get { self[NarrowRowsKey.self] }
        set { self[NarrowRowsKey.self] = newValue }
    }
}

/// 내 일감 한 줄. 이미 그날 적었으면 적은 상태를, 아니면 레드마인 진척률을 보인다.
private struct IssueRow: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var settings: WorkLogSettings
    @ObservedObject var sync: WorkLogSync
    let info: IssueInfo
    @StateObject private var hover = HoverFlag()
    @Environment(\.narrowRows) private var narrow

    var body: some View {
        let written = store.log.entries(on: page.day).filter { $0.issue == info.id }
        let entry = written.first
        let status = entry?.status ?? redmineStatus
        // 제목·적음·상태·진척률·기간·번호를 한 줄에 두고, 칸 너비를 고정해 줄마다 같은 자리에서 읽히게 한다
        HStack(spacing: 10) {
            StatusGlyph(status: status)
                .opacity(entry == nil ? 0.55 : 1)
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(WL.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .tip(fullTitle)
            Spacer(minLength: 8)
            if let entry {
                // 상태는 왼쪽 표시로 보여, 완료가 아닐 때만 진척률을 덧붙인다
                Text(dayLabel + (written.count > 1 ? " \(written.count)줄" : "") + " 적음"
                     + (entry.status == .done ? "" : " · " + entry.status.label))
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(WL.done).monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            ZStack(alignment: .trailing) {
                columns
                actions
                    .padding(.leading, 18)
                    // 단추가 칸 글자 위에 겹쳐 보이지 않게 줄 배경색으로 왼쪽을 흐려 덮는다
                    .background(ZStack { WL.canvas; WL.hover }
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading,
                                             endPoint: UnitPoint(x: 0.3, y: 0.5))))
                    // 노션처럼 줄에 올렸을 때만 단추를 보인다 (고치는 창이 열려 있으면 그대로 둔다)
                    .opacity(hover.on || page.boardEditing == info.id ? 1 : 0)
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hover.on ? WL.hover : .clear))
        .onHover { hover.on = $0 }
        .contextMenu {
            Button("\(dayLabel) 일지에 넣기") { add(defaultStatus) }
            if let entry { Button("\(dayLabel) 일지에 한 줄 더 넣기") { add(entry.status, again: true) } }
            Button("보고서 이름 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.reportTitle, forType: .string)
                page.flash("보고서 이름을 복사했습니다")
            }
            Button("상태·날짜·담당자 고치기…") { startEditing() }.disabled(!settings.redmineReady)
            Button("레드마인에서 열기") { open() }
        }
    }

    /// 줄에 보이는 이름. 메뉴·화면 경로는 묶음 제목에 있어 끝 이름만 쓴다.
    private var title: String {
        IssueInfo.isWorkName(leaf) ? info.reportTitle.components(separatedBy: " > ").last ?? leaf : leaf
    }

    /// 제목에 마우스를 올리면 보이는 전체 이름과 날짜.
    private var fullTitle: String {
        var lines = [info.reportTitle, "#\(info.id) · \(info.status)" + (info.doneRatio > 0 ? " · 레드마인 \(info.doneRatio)%" : "")]
        let dates = [info.startDate.map { "시작 " + WorkLogFormat.shortDay($0) }, info.dueDate.map { "기한 " + WorkLogFormat.shortDay($0) }]
            .compactMap { $0 }
        if !dates.isEmpty { lines.append(dates.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }

    /// 상태, 레드마인 진척률, 기간, 번호. 비어도 자리를 지켜 아래위 줄과 칸이 맞는다.
    private var columns: some View {
        HStack(spacing: 10) {
            Text(info.status)
                .lineLimit(1)
                .frame(width: 54, alignment: .leading)
            // 글자를 키운 뒤에도 `100%`, `10.21 ~ 10.21`, `#38063`이 잘리지 않는 너비
            if !narrow {
                Text(info.doneRatio > 0 ? "\(info.doneRatio)%" : "")
                    .frame(width: 42, alignment: .trailing)
            }
            period
                .frame(width: narrow ? 86 : 122, alignment: .trailing)
            Text("#" + String(info.id))
                .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 12.5).monospacedDigit())
        .foregroundStyle(WL.muted)
        .lineLimit(1)
    }

    /// 시작~기한. 기한이 지났거나 3일 안이면 색으로 알린다.
    @ViewBuilder
    private var period: some View {
        let today = WorkDay.today()
        if let due = info.dueDate {
            let color: Color = due < today ? Palette.red : due <= WorkDay.adding(3, to: today) ? WL.waiting : WL.faint
            HStack(spacing: 0) {
                if let start = info.startDate, !narrow { Text(WorkReport.shortDate(start) + " ~ ") }
                Text(WorkLogFormat.shortDay(due)).foregroundStyle(color)
            }
        } else if let start = info.startDate {
            Text(WorkReport.shortDate(start) + " ~")
        } else {
            Text("")
        }
    }

    private var actions: some View {
        let entry = store.log.entries(on: page.day).first { $0.issue == info.id }
        return HStack(spacing: 2) {
            // 이미 적은 일감도 한 줄 더 넣을 수 있다 (같은 일감에 따로 적을 일이 여럿인 날)
            Button { add(entry?.status ?? defaultStatus, again: entry != nil) } label: {
                Image(systemName: entry == nil ? "plus" : "plus.square.on.square")
            }
                .buttonStyle(GhostIconButtonStyle())
                .tip(entry == nil ? "\(dayLabel) 일지에 넣기" : "\(dayLabel) 일지에 한 줄 더 넣기")
            Menu {
                Button("완료") { add(.done) }
                ForEach(Array(stride(from: 100, through: 10, by: -10)), id: \.self) { value in
                    Button("\(value)%") { add(.percent(value)) }
                }
                Button("진행중") { add(.inProgress) }
            } label: {
                Image(systemName: "gauge.medium")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip("진척률을 정해 \(dayLabel) 일지에 넣기")
            Button { startEditing() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(GhostIconButtonStyle())
                .tip("상태·시작일·완료 기한·담당자 고치기")
                .disabled(!settings.redmineReady)
                .popover(isPresented: Binding(
                    get: { page.boardEditing == info.id },
                    set: { if !$0 { page.boardEditing = nil } }
                ), arrowEdge: .trailing) {
                    IssueFieldEditor(current: info, edit: $page.boardDraft, sync: sync, locked: page.boardConfirming) {
                        let fields = WorkReport.IssueFields.merged(auto: .init(), edit: page.boardDraft, current: info,
                                                                   statuses: sync.statuses)
                        // 진척률은 IssueFields에 없어 따로 본다. 진척률만 바꿔도 저장할 수 있어야 한다
                        let ratio = page.boardDraft.doneRatio.flatMap { $0 == info.doneRatio ? nil : $0 }
                        let changes = (ratio.map { ["진척률 \(info.doneRatio)% → \($0)%"] } ?? [])
                            + WorkLogFormat.fieldChanges(fields, current: info)
                        let unchanged = fields.isEmpty && ratio == nil
                        if page.boardConfirming {
                            // 레드마인에 바로 반영되므로 바뀔 칸을 한 번 더 보이고 저장한다
                            VStack(alignment: .trailing, spacing: 8) {
                                Text("#\(String(info.id))에 " + changes.joined(separator: " · ")
                                     + "을(를) 저장할까요?")
                                    .font(.system(size: 13)).foregroundStyle(WL.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button("돌아가기") { page.boardConfirming = false }.buttonStyle(NotionButtonStyle())
                                        .keyboardShortcut(.cancelAction)
                                    // Return 두 번으로 바로 저장되지 않게 확인 단추는 눌러야만 저장한다
                                    Button(sync.sending ? "저장 중…" : "저장") { save() }
                                        .buttonStyle(NotionButtonStyle(kind: .primary))
                                        .disabled(sync.sending || unchanged || fields.problem(current: info) != nil)
                                }
                            }
                        } else {
                            Button("취소") { page.boardEditing = nil }.buttonStyle(NotionButtonStyle())
                            Button("레드마인에 저장…") { page.boardConfirming = true }
                                .buttonStyle(NotionButtonStyle(kind: .primary))
                                .disabled(sync.sending || unchanged || fields.problem(current: info) != nil)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            Button { open() } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(GhostIconButtonStyle())
                .tip("레드마인에서 열기")
        }
    }

    private func startEditing() {
        page.boardDraft = .init()
        page.boardConfirming = false
        page.boardEditing = info.id
    }

    /// 댓글 없이 칸만 바로 저장한다. 보낸 기록에 남아 되돌릴 수 있다.
    private func save() {
        let edit = page.boardDraft
        sync.saveFields(issue: info.id, edit: edit) { problem in
            if let problem {
                page.flash("#\(info.id) 저장하지 못했습니다: \(problem)")
            } else {
                page.boardEditing = nil
                page.boardConfirming = false
                page.flash("#\(info.id)에 저장했습니다. 레드마인 탭 > 보낸 기록에서 되돌릴 수 있습니다")
            }
        }
    }

    private var leaf: String { IssueInfo.cleanSubject(info.subject) }

    private var dayLabel: String { page.day == WorkDay.today() ? "오늘" : WorkLogFormat.shortDay(page.day) }

    private var redmineStatus: WorkStatus {
        info.doneRatio >= 100 ? .done : info.doneRatio > 0 ? .percent(info.doneRatio) : .inProgress
    }

    /// 넣을 때 기본 상태: 레드마인 진척률이 있으면 그 값, 없으면 진행중.
    private var defaultStatus: WorkStatus { info.doneRatio > 0 ? .percent(min(info.doneRatio, 100)) : .inProgress }

    private func add(_ status: WorkStatus, again: Bool = false) {
        if let entry = store.addIssue(info, day: page.day, status: status, again: again) {
            page.flash("\(entry.project) · \(WorkReport.line(entry))")
        }
    }

    private func open() {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL) else { return }
        NSWorkspace.shared.open(base.appendingPathComponent("issues/\(info.id)"))
    }
}
