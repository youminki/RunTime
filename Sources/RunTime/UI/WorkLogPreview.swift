import AppKit
import SwiftUI
import WorkLogCore

/// 오른쪽 칸: 지금 보는 범위의 보고서(복사·팀즈)와 레드마인에 보낼 진척률·댓글·작업 시간.
struct WorkLogPreview: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var sync: WorkLogSync
    @ObservedObject var settings: WorkLogSettings

    var body: some View {
        let updates = WorkReport.redmineUpdates(pendingEntries)
        VStack(alignment: .leading, spacing: 14) {
            PageTabs(items: [(WorkLogPage.Preview.report, reportTitle),
                             (WorkLogPage.Preview.redmine, updates.isEmpty ? "레드마인" : "레드마인 \(updates.count)")],
                     selection: $page.preview)
            switch page.preview {
            case .report: report
            case .redmine: redmine(updates)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WL.sidebar)
        .alert("팀즈 채팅에 보낼까요?", isPresented: $page.confirmingTeams) {
            Button("보내기") { postTeams() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(reportTitle)를 이어 둔 팀즈 채팅에 보냅니다. 보낸 글은 팀즈에서 지워야 합니다.")
        }
    }

    // MARK: 범위

    private var selectedProject: String? {
        if let project = page.project, store.log.allProjects.contains(project) { return project }
        return store.log.allProjects.first
    }

    private var scopeEntries: [WorkEntry] {
        switch page.mode {
        case .day, .issues: return store.log.entries(on: page.day)
        case .week: return store.log.entries(in: WorkDay.week(of: page.day))
        case .month: return store.log.entries(in: WorkDay.month(of: page.day))
        case .project: return selectedProject.map { name in store.log.entries.filter { $0.project == name } } ?? []
        }
    }

    /// 레드마인에 보낼 줄: 댓글을 보내야 하거나, 시간 남기기가 켜져 있고 시간만 남은 줄.
    private var pendingEntries: [WorkEntry] {
        scopeEntries.filter { $0.needsRedmine || (settings.logTime && $0.needsTime) }
    }

    private var reportTitle: String {
        switch page.mode {
        case .day, .issues: return "일일보고"
        case .week: return "주간 보고"
        case .month: return "월간 보고"
        case .project: return "프로젝트 요약"
        }
    }

    private var rangeText: String {
        switch page.mode {
        case .day, .issues: return WorkLogFormat.dayTitle(page.day)
        case .week: return WorkLogFormat.weekTitle(page.day)
        case .month: return WorkLogFormat.monthTitle(page.day)
        case .project: return selectedProject ?? ""
        }
    }

    private var reportText: String {
        switch page.mode {
        case .day, .issues:
            let body = WorkReport.daily(scopeEntries, in: store.log, doneFirst: settings.doneFirst, byIssue: settings.reportByIssue)
            return body.isEmpty || !settings.dailyHeader ? body : "[금일 진행 사항]\n" + body
        case .week:
            return WorkReport.weekly(scopeEntries, in: store.log, week: WorkDay.week(of: page.day),
                                     doneFirst: settings.doneFirst, nextWeekPlan: settings.weeklyPlan, byIssue: settings.reportByIssue)
        case .month:
            return WorkReport.monthly(scopeEntries, in: store.log, month: WorkDay.month(of: page.day), byIssue: settings.reportByIssue)
        case .project:
            return WorkReport.daily(WorkReport.merged(scopeEntries), in: store.log, doneFirst: settings.doneFirst,
                                    byIssue: settings.reportByIssue)
        }
    }

    // MARK: 보고서

    private var report: some View {
        let text = reportText
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(reportTitle).font(WL.heading)
                Spacer()
                Text(rangeText).font(WL.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollView {
                Text(text.isEmpty ? "적은 일이 여기 보고서 꼴로 만들어집니다." : text)
                    .font(.system(size: 13))
                    .foregroundStyle(text.isEmpty ? WL.muted : WL.text)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("레드마인 일감 이름으로, QA는 건수로 모아 쓰기", isOn: $settings.reportByIssue)
                    .help("일감 줄은 `데이터 수집 > 공유 파일 관리 API 연동 (100%)`처럼, QA 건은 `QA 수정사항 N건 반영`으로 적습니다")
                if page.mode == .day || page.mode == .issues {
                    Toggle("맨 위에 [금일 진행 사항] 붙이기", isOn: $settings.dailyHeader)
                }
                if page.mode != .month {
                    Toggle("상시 → 완료 → 진행 순서로", isOn: $settings.doneFirst)
                }
                if page.mode == .week {
                    Toggle("끝나지 않은 일을 [차주 계획]으로", isOn: $settings.weeklyPlan)
                }
            }
            .toggleStyle(.checkbox)
            .font(WL.meta)
            VStack(spacing: 8) {
                Button {
                    copy(text, message: "\(reportTitle)를 복사했습니다")
                } label: {
                    Label("\(reportTitle) 복사", systemImage: "doc.on.doc")
                }
                .buttonStyle(NotionButtonStyle(kind: .primary, fill: true))
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(text.isEmpty)
                .help("⇧⌘C")
                if settings.hasTeamsWebhook {
                    Button { page.confirmingTeams = true } label: {
                        HStack {
                            if sync.postingTeams { ProgressView().controlSize(.small) }
                            Label("팀즈 채팅에 보내기", systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                    .buttonStyle(NotionButtonStyle(fill: true))
                    .disabled(text.isEmpty || sync.postingTeams)
                } else {
                    Button("팀즈 채팅 잇기") { page.settingsSection = .teams; page.showsSettings = true }
                        .buttonStyle(TextLinkButtonStyle())
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func postTeams() {
        sync.postTeams(reportText, title: "\(reportTitle) · \(rangeText)") { error in
            page.flash(error.map { "팀즈에 보내지 못했습니다: \($0)" } ?? "팀즈 채팅에 보냈습니다")
        }
    }

    // MARK: 레드마인

    private func redmine(_ updates: [WorkReport.RedmineUpdate]) -> some View {
        let missing = scopeEntries.filter { $0.issue == nil && $0.status != .ongoing }.count
        let hours = updates.compactMap { hoursValue($0) }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("레드마인").font(WL.heading)
                Spacer()
                Text(rangeText).font(WL.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if updates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("보낼 일감이 없습니다").font(WL.heading)
                    Text("줄에 일감 번호가 있고 아직 보내지 않았거나 보낸 뒤 고친 것이 여기 모입니다.")
                        .font(WL.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wlSurface()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(updates, id: \.issue) { update in card(update) }
                    }
                }
                .onAppear { sync.loadInfo(updates.map(\.issue)) }
                .onChange(of: updates.map(\.issue)) { sync.loadInfo($0) }
            }
            if missing > 0 {
                Text("일감 번호가 없는 \(missing)줄은 빠졌습니다. 줄의 말풍선에서 번호를 넣으세요.")
                    .font(WL.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !updates.isEmpty {
                VStack(spacing: 8) {
                    if settings.redmineReady {
                        Text(sendSummary(updates.count, hours: hours))
                            .font(WL.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { send(updates) } label: {
                            HStack {
                                if sync.sending { ProgressView().controlSize(.small) }
                                Label("레드마인에 보내기", systemImage: "paperplane")
                            }
                        }
                        .buttonStyle(NotionButtonStyle(kind: .primary, fill: true))
                        .disabled(sync.sending)
                    } else {
                        Button { page.settingsSection = .redmine; page.showsSettings = true } label: {
                            Label("레드마인 잇고 바로 보내기", systemImage: "link")
                        }
                        .buttonStyle(NotionButtonStyle(kind: .primary, fill: true))
                    }
                    HStack {
                        Button("Claude용 복사") {
                            copy(WorkReport.redmineRequest(updates), message: "Claude에 붙여 넣을 글을 복사했습니다")
                        }
                        .help("Claude Code에 붙여 넣으면 git을 다시 훑지 않고 이 내용만 MCP로 올립니다")
                        Spacer()
                        Button("보낸 것으로 표시") {
                            store.markPosted(updates.flatMap(\.entryIDs))
                            page.flash("\(updates.count)개 일감을 보낸 것으로 표시했습니다")
                        }
                        .help("다른 곳에서 이미 올렸을 때")
                    }
                    .buttonStyle(TextLinkButtonStyle(tint: .secondary))
                }
            }
        }
    }

    private func sendSummary(_ count: Int, hours: Double) -> String {
        var parts = ["\(count)건", "진척률과 댓글"]
        if settings.logTime && hours > 0 { parts.append("작업 시간 \(WorkTime.label(hours))") }
        return parts.joined(separator: " · ") + " · 일감 상태는 바꾸지 않습니다"
    }

    private func info(_ issue: Int) -> IssueInfo? {
        sync.info(issue)
    }

    /// 이 일감에서 작업 시간을 아직 남기지 않은 날들.
    private func pendingDays(_ update: WorkReport.RedmineUpdate) -> [String] {
        let ids = Set(update.entryIDs)
        return Array(Set(store.log.entries.filter { ids.contains($0.id) && !$0.timeLogged }.map(\.day))).sorted()
    }

    /// 그날 보낼 시간: 정한 값, 없으면 어림값(이미 남긴 시간은 뺀 값).
    private func dayHours(_ update: WorkReport.RedmineUpdate, _ day: String) -> (hours: Double?, guessed: Bool) {
        let ids = Set(update.entryIDs)
        let set = store.log.entries.filter { ids.contains($0.id) && $0.day == day && !$0.timeLogged }.compactMap(\.hours).reduce(0, +)
        if set > 0 { return (set, false) }
        if let guess = sync.suggestedHours(on: day, entries: store.log.entries)[update.issue] { return (guess, true) }
        return (nil, false)
    }

    /// 보낼 작업 시간 합. 시간 남기기를 껐으면 nil.
    private func hoursValue(_ update: WorkReport.RedmineUpdate) -> Double? {
        guard settings.logTime else { return nil }
        let total = pendingDays(update).compactMap { dayHours(update, $0).hours }.reduce(0, +)
        return total > 0 ? total : nil
    }

    private func card(_ update: WorkReport.RedmineUpdate) -> some View {
        let current = info(update.issue)
        let lowering = update.doneRatio.map { ratio in (current?.doneRatio ?? 0) > ratio } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IssueLabel(issue: update.issue)
                Spacer()
                Text(ratioText(update, current: current?.doneRatio))
                    .font(WL.number)
                    .foregroundStyle(lowering ? WL.waiting : .primary)
                    .help(lowering ? "레드마인의 지금 진척률보다 낮습니다" : "")
            }
            if let current {
                // 대괄호 머리와 기능 번호를 뗀 보고서 이름으로 보인다. QA 건은 QA로 묶일 것을 알린다
                Text(current.isQA ? IssueInfo.cleanSubject(current.subject) : current.reportTitle).font(WL.meta).lineLimit(2)
                Text((current.isQA ? "QA 수정사항 · " : "") + current.project).font(WL.caption).foregroundStyle(WL.muted).lineLimit(1)
            }
            if !update.needsNote {
                Text("댓글은 보냈습니다. 작업 시간만 남깁니다.").font(WL.caption).foregroundStyle(.secondary)
            } else if let ratio = update.doneRatio {
                RatioBar(current: current?.doneRatio, next: ratio)
            }
            if settings.logTime { hoursControl(update) }
            Text(update.note)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.callout))
            HStack(spacing: 2) {
                Spacer()
                Button { copy(update.note, message: "#\(update.issue) 댓글을 복사했습니다") } label: { Image(systemName: "doc.on.doc") }
                    .help("댓글 복사")
                Button { copy(String(update.issue), message: "#\(update.issue)를 복사했습니다") } label: { Image(systemName: "number") }
                    .help("일감 번호 복사")
                if settings.redmineReady {
                    Button { send([update]) } label: { Image(systemName: "paperplane") }
                        .help("이 일감만 보내기")
                        .disabled(sync.sending)
                }
            }
            .buttonStyle(GhostIconButtonStyle())
        }
        .padding(12)
        .wlSurface()
    }

    private func ratioText(_ update: WorkReport.RedmineUpdate, current: Int?) -> String {
        guard let ratio = update.doneRatio else { return "진척률 그대로" }
        if let current, current != ratio { return "\(current)% → \(ratio)%" }
        return "\(ratio)%"
    }

    /// 하루치면 −/+로 고치고, 여러 날이면 날짜별 값을 보여 준다 (레드마인 소요 시간은 날마다 한 건).
    @ViewBuilder
    private func hoursControl(_ update: WorkReport.RedmineUpdate) -> some View {
        let days = pendingDays(update)
        if days.count == 1, let day = days.first {
            let (value, guessed) = dayHours(update, day)
            HStack(spacing: 6) {
                Text("작업 시간").font(WL.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.setHours(max(0, (value ?? 0) - 0.25), issue: update.issue, day: day) } label: { Image(systemName: "minus") }
                    .buttonStyle(GhostIconButtonStyle())
                    .disabled((value ?? 0) <= 0)
                Text(value.map(WorkTime.label) ?? "없음")
                    .font(WL.number)
                    .foregroundStyle(guessed ? Color.secondary : .primary)
                    .frame(minWidth: 40)
                    .help(guessed ? "이 저장소 폴더에서 Claude Code를 쓴 시간으로 어림한 값 (이미 남긴 시간은 뺌)" : "")
                Button { store.setHours((value ?? 0) + 0.25, issue: update.issue, day: day) } label: { Image(systemName: "plus") }
                    .buttonStyle(GhostIconButtonStyle())
                if guessed { Text("추정").font(WL.caption).foregroundStyle(.tertiary) }
            }
        } else if days.count > 1 {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("작업 시간").font(WL.caption).foregroundStyle(.secondary)
                Spacer()
                Text(days.compactMap { day in dayHours(update, day).hours.map { "\(WorkReport.shortDate(day)) \(WorkTime.label($0))" } }
                        .joined(separator: " · "))
                    .font(WL.caption).foregroundStyle(.secondary).monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            .help("날짜마다 따로 남깁니다. 하루 보기에서 고칠 수 있습니다")
        }
    }

    // MARK: 보내기

    /// 어림값만 있는 일감은 그 값을 먼저 정해 두고 보낸다 (보낸 시간이 화면에 보이던 값과 같게).
    private func send(_ updates: [WorkReport.RedmineUpdate]) {
        let issues = Set(updates.map(\.issue))
        if settings.logTime {
            for update in updates {
                for day in pendingDays(update) {
                    let (value, guessed) = dayHours(update, day)
                    if guessed, let value { store.setHours(value, issue: update.issue, day: day) }
                }
            }
        }
        let fresh = WorkReport.redmineUpdates(pendingEntries).filter { issues.contains($0.issue) }
        sync.send(fresh) { sent, failures in
            page.flash(failures.isEmpty ? "레드마인에 \(sent)건 보냈습니다" : "\(sent)건 보냄 · " + failures.joined(separator: ", "))
        }
    }

    private func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        page.flash(message)
    }
}

/// 지금 진척률(회색)과 보낼 진척률(파랑·초록)을 한 막대에.
private struct RatioBar: View {
    let current: Int?
    let next: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(next >= 100 ? WL.done : WL.accent).frame(width: geo.size.width * CGFloat(next) / 100)
                if let current, current > 0 {
                    Rectangle().fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * CGFloat(min(current, 100)) / 100 - 0.75)
                }
            }
        }
        .frame(height: 4)
    }
}
