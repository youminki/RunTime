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
        let all = sync.myIssues
        let shown = filtered(all)
        VStack(alignment: .leading, spacing: 0) {
            header(all)
            if !settings.redmineReady && all.isEmpty {
                Callout {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("레드마인을 이으면 나에게 배정된 일감이 여기 모입니다").font(.system(size: 13, weight: .semibold))
                        Button("레드마인 잇기") { page.settingsSection = .redmine; page.showsSettings = true }
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                    }
                }
            } else if all.isEmpty {
                Callout {
                    Text(sync.loadingIssues ? "일감을 받는 중입니다…" : "열린 일감이 없습니다.")
                        .font(.system(size: 12.5)).foregroundStyle(WL.muted)
                }
            } else {
                if !settings.redmineReady {
                    Text("레드마인이 이어지지 않아 마지막으로 받은 목록을 보입니다.")
                        .font(.system(size: 12)).foregroundStyle(WL.waiting).padding(.bottom, 10)
                }
                filterBar
                if shown.isEmpty {
                    Text("맞는 일감이 없습니다.").font(.system(size: 12.5)).foregroundStyle(WL.muted).padding(.vertical, 12)
                }
                ForEach(projects(of: shown), id: \.self) { project in
                    projectSection(project, issues: shown.filter { $0.project == project })
                }
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
        return VStack(alignment: .leading, spacing: 14) {
            Text("내 일감").font(WL.pageTitle)
            VStack(alignment: .leading, spacing: 0) {
                PropertyRow("열린 일감", icon: "tray") {
                    HStack(spacing: 14) {
                        Text("\(all.count)개").monospacedDigit()
                        ForEach(statuses.prefix(4), id: \.0) { name, count in Tally(title: name, value: count) }
                    }
                }
                PropertyRow("기한", icon: "calendar.badge.exclamationmark") {
                    HStack(spacing: 14) {
                        Tally(title: "지남", value: overdue, tint: overdue > 0 ? Palette.red : nil)
                        Tally(title: "3일 안", value: dueSoon, tint: dueSoon > 0 ? WL.waiting : nil)
                    }
                }
                PropertyRow("적을 날", icon: "square.and.pencil") {
                    HStack(spacing: 8) {
                        Text(page.day == today ? "오늘" : WorkLogFormat.dayTitle(page.day))
                        Text("왼쪽 달력에서 바꿉니다").foregroundStyle(WL.faint)
                    }
                }
                PropertyRow("받은 때", icon: "arrow.down.circle") {
                    HStack(spacing: 8) {
                        if sync.loadingIssues {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("받는 중").foregroundStyle(WL.muted)
                        } else {
                            Text(sync.issuesError ?? sync.issuesLoadedAt.map { "\(WorkLogFormat.when($0)) · 30분마다" } ?? "아직")
                                .foregroundStyle(sync.issuesError == nil ? WL.muted : WL.waiting)
                        }
                        Button("새로 받기") { sync.loadMyIssues() }
                            .buttonStyle(TextLinkButtonStyle())
                            .disabled(sync.loadingIssues || !settings.redmineReady)
                    }
                }
            }
            Rectangle().fill(WL.border).frame(height: 1).padding(.top, 6)
        }
        .padding(.bottom, 16)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(WL.faint)
                TextField("일감 찾기 (제목·화면·#번호)", text: $page.issueQuery).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 120, maxWidth: 260)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(WL.callout))
            Spacer(minLength: 8)
            PageTabs(items: WorkLogPage.IssueFilter.allCases.map { ($0, $0.rawValue) }, selection: $page.issueFilter)
                .layoutPriority(1)
        }
        .padding(.bottom, 14)
    }

    private func filtered(_ all: [IssueInfo]) -> [IssueInfo] {
        let today = WorkDay.today()
        let logged = Set(store.log.entries(on: page.day).compactMap(\.issue))
        let query = page.issueQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { info in
            switch page.issueFilter {
            case .all: break
            case .working: if info.doneRatio == 0 && !logged.contains(info.id) { return false }
            case .due: if (info.dueDate ?? "9999") > WorkDay.adding(3, to: today) { return false }
            case .logged: if !logged.contains(info.id) { return false }
            }
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
        let collapsed = page.collapsed.contains(key)
        let groups = Dictionary(grouping: issues, by: \.group)
        let order = issues.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let reportName = issues.first.map { store.log.reportProject(for: $0) } ?? project
        return VStack(alignment: .leading, spacing: 0) {
            ToggleHeading(collapsed: collapsed, toggle: { page.toggle(key) }) {
                HStack(spacing: 8) {
                    Text(project).font(WL.section)
                    Text("\(issues.count)").font(.system(size: 13)).foregroundStyle(WL.faint).monospacedDigit()
                }
            } trailing: { EmptyView() }
            reportNameRow(project, current: reportName)
            if !collapsed {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(order, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group).font(.system(size: 12, weight: .medium)).foregroundStyle(WL.muted)
                                .padding(.horizontal, 6).padding(.bottom, 2)
                            ForEach(groups[group] ?? []) { info in
                                IssueRow(store: store, page: page, settings: settings, info: info)
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

    /// 보고서에 쓸 프로젝트 이름 (예: 경북대학교 빅데이터플랫폼 구축 → VeloX).
    private func reportNameRow(_ project: String, current: String) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 16, height: 1)
            Text("보고서 이름").font(.system(size: 12)).foregroundStyle(WL.faint)
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
                    ForEach(store.log.allProjects, id: \.self) { name in
                        Button(name) { store.setReportProject(name, for: project) }
                    }
                    Divider()
                    Button("새 이름…") { page.redmineRenameText = current; page.renamingRedmine = project }
                } label: {
                    HStack(spacing: 5) {
                        ProjectSwatch(name: current, size: 8)
                        Text(current).font(.system(size: 12.5, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("이 레드마인 프로젝트의 일감을 보고서에서 이 이름 아래에 적습니다")
            }
        }
        .frame(height: 24)
    }
}

/// 내 일감 한 줄. 이미 그날 적었으면 적은 상태를, 아니면 레드마인 진척률을 보인다.
private struct IssueRow: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var settings: WorkLogSettings
    let info: IssueInfo
    @StateObject private var hover = HoverFlag()

    var body: some View {
        let entry = store.log.entries(on: page.day).first { $0.issue == info.id }
        let status = entry?.status ?? redmineStatus
        HStack(spacing: 10) {
            StatusGlyph(status: status)
                .opacity(entry == nil ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(IssueInfo.isWorkName(leaf) ? info.reportTitle.components(separatedBy: " > ").last ?? leaf : leaf)
                    .font(.system(size: 14))
                    .foregroundStyle(WL.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("#" + String(info.id)).monospacedDigit()
                    Text(info.status)
                    if info.doneRatio > 0 { Text("레드마인 \(info.doneRatio)%").monospacedDigit() }
                    if let due = info.dueDate { dueLabel(due) }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(WL.faint)
            }
            Spacer(minLength: 8)
            if let entry {
                Text(dayLabel + " 적음 · " + entry.status.label).font(.system(size: 12)).foregroundStyle(WL.done)
            }
            HStack(spacing: 2) {
                Button { add(entry?.status ?? defaultStatus) } label: { Image(systemName: entry == nil ? "plus" : "checkmark") }
                    .buttonStyle(GhostIconButtonStyle())
                    .help(entry == nil ? "\(dayLabel) 일지에 넣기" : "\(dayLabel) 일지에 있음")
                    .disabled(entry != nil)
                Menu {
                    Button("완료") { add(.done) }
                    ForEach(Array(stride(from: 100, through: 10, by: -10)), id: \.self) { value in
                        Button("\(value)%") { add(.percent(value)) }
                    }
                    Button("진행중") { add(.inProgress) }
                } label: {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("진척률을 정해 \(dayLabel) 일지에 넣기")
                Button { open() } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(GhostIconButtonStyle())
                    .help("레드마인에서 열기")
            }
            // 노션처럼 줄에 올렸을 때만 단추를 보인다
            .opacity(hover.on ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hover.on ? WL.hover : .clear))
        .onHover { hover.on = $0 }
        .contextMenu {
            Button("\(dayLabel) 일지에 넣기") { add(defaultStatus) }
            Button("보고서 이름 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.reportTitle, forType: .string)
                page.flash("보고서 이름을 복사했습니다")
            }
            Button("레드마인에서 열기") { open() }
        }
    }

    private var leaf: String { IssueInfo.cleanSubject(info.subject) }

    private var dayLabel: String { page.day == WorkDay.today() ? "오늘" : WorkLogFormat.shortDay(page.day) }

    private var redmineStatus: WorkStatus {
        info.doneRatio >= 100 ? .done : info.doneRatio > 0 ? .percent(info.doneRatio) : .inProgress
    }

    /// 넣을 때 기본 상태: 레드마인 진척률이 있으면 그 값, 없으면 진행중.
    private var defaultStatus: WorkStatus { info.doneRatio > 0 ? .percent(min(info.doneRatio, 100)) : .inProgress }

    private func add(_ status: WorkStatus) {
        if let entry = store.addIssue(info, day: page.day, status: status) {
            page.flash("\(entry.project) · \(WorkReport.line(entry))")
        }
    }

    private func dueLabel(_ due: String) -> some View {
        let today = WorkDay.today()
        let color: Color = due < today ? Palette.red : due <= WorkDay.adding(3, to: today) ? WL.waiting : WL.faint
        return Text("기한 \(WorkLogFormat.shortDay(due))").foregroundStyle(color).monospacedDigit()
    }

    private func open() {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL) else { return }
        NSWorkspace.shared.open(base.appendingPathComponent("issues/\(info.id)"))
    }
}
