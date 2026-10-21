import AppKit
import SwiftUI
import WorkLogCore

/// 오른쪽 칸: 지금 보는 범위의 보고서(복사·팀즈)와 레드마인에 보낼 진척률·댓글·상태·날짜·담당자.
struct WorkLogPreview: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var sync: WorkLogSync
    @ObservedObject var settings: WorkLogSettings

    var body: some View {
        let updates = WorkReport.redmineUpdates(pendingEntries, log: store.log)
        VStack(alignment: .leading, spacing: 14) {
            PageTabs(items: [(WorkLogPage.Preview.report, reportTitle),
                             (WorkLogPage.Preview.redmine, updates.isEmpty ? "레드마인" : "레드마인 \(updates.count)")],
                     selection: $page.preview, fill: true)
            switch page.preview {
            case .report: report
            case .redmine: redmine(updates)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WL.sidebar)
        .sheet(isPresented: Binding(
            get: { page.confirmingSend != nil },
            set: { if !$0 { page.confirmingSend = nil } }
        )) {
            sendConfirm(Set(page.confirmingSend ?? []))
        }
        .alert("보낸 것을 되돌릴까요?", isPresented: Binding(
            get: { page.confirmingUndo != nil },
            set: { if !$0 { page.confirmingUndo = nil } }
        )) {
            Button("되돌리기", role: .destructive) {
                if let record = page.confirmingUndo { undo(record) }
                page.confirmingUndo = nil
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("#\(page.confirmingUndo?.issue ?? 0)에서 앱이 바꾼 진척률·상태·날짜·담당자를 보내기 전 값으로 돌리고, 보낸 댓글을 지웁니다. 보낸 뒤 다른 사람이 바꾼 칸은 그대로 둡니다. 그 줄들은 다시 보낼 목록으로 돌아옵니다."
                 + (sync.journalAPI ? "" : "\n\n이 레드마인은 API로 댓글을 지우게 두지 않아, 댓글 자리를 브라우저로 열어 드립니다. 연필 > 지우기로 지우세요."))
        }
        .alert("팀즈 채팅에 보낼까요?", isPresented: $page.confirmingTeams) {
            Button("보내기") { postTeams() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(reportTitle)를 연결한 팀즈 채팅에 보냅니다. 보낸 글은 팀즈에서 지워야 합니다.")
        }
    }

    // MARK: 범위

    private var selectedProject: String? {
        page.selectedProject(in: store.log)
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
        scopeEntries.filter(\.needsRedmine)
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
            ReportText(text: text.isEmpty ? "적은 일이 여기 보고서 꼴로 만들어집니다." : text, placeholder: text.isEmpty)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("레드마인 일감 이름으로, QA는 건수로 모아 쓰기", isOn: $settings.reportByIssue)
                    .tip("일감 줄은 `데이터 수집 > 공유 파일 관리 API 연동 (100%)`처럼, QA 건은 `QA 수정사항 N건 반영`으로 적습니다")
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
                .tip("⇧⌘C")
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
                    Button("팀즈 채팅 연결") { page.settingsSection = .teams; page.showsSettings = true }
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
        let chosen = updates.filter { !page.redmineSkipped.contains($0.issue) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.redmineHistory ? "보낸 기록" : "레드마인").font(WL.heading)
                Spacer()
                if !page.redmineHistory {
                    Text(rangeText).font(WL.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button(page.redmineHistory ? "보낼 것" : "보낸 기록") { page.redmineHistory.toggle() }
                    .buttonStyle(TextLinkButtonStyle())
                    .tip("앱으로 보낸 건을 보고, 잘못 보냈으면 되돌립니다")
            }
            if page.redmineHistory {
                history
            } else if updates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("보낼 일감이 없습니다").font(WL.heading)
                    Text("줄에 일감 번호가 있고 아직 보내지 않았거나 보낸 뒤 고친 것이 여기 모입니다.")
                        .font(WL.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wlSurface()
            } else {
                selectionBar(updates, chosen: chosen.count)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(updates, id: \.issue) { update in card(update) }
                    }
                }
                .onAppear {
                    sync.loadInfo(updates.map(\.issue))
                    if settings.redmineReady { sync.checkPosted(updates) }
                }
                .onChange(of: updates.map(\.issue)) { _ in
                    sync.loadInfo(updates.map(\.issue))
                    if settings.redmineReady { sync.checkPosted(updates) }
                }
                .onReceive(sync.$postedHints) { hints in
                    // 이미 올라간 것 같은 일감은 처음 한 번 체크를 풀어 둔다 (다시 고르면 그대로 보낸다)
                    for issue in hints.keys where !page.hintApplied.contains(issue) {
                        page.hintApplied.insert(issue)
                        page.redmineSkipped.insert(issue)
                    }
                }
            }
            if missing > 0 && !page.redmineHistory {
                Text("일감 번호가 없는 \(missing)줄은 빠졌습니다. 줄의 말풍선에서 번호를 넣으세요.")
                    .font(WL.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !updates.isEmpty && !page.redmineHistory {
                VStack(spacing: 8) {
                    if settings.redmineReady {
                        Text(sendSummary(chosen))
                            .font(WL.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { send(chosen) } label: {
                            HStack {
                                if sync.sending { ProgressView().controlSize(.small) }
                                Label(chosen.count == updates.count ? "레드마인에 보내기" : "고른 \(chosen.count)건 보내기",
                                      systemImage: "paperplane")
                            }
                        }
                        .buttonStyle(NotionButtonStyle(kind: .primary, fill: true))
                        .disabled(sync.sending || chosen.isEmpty)
                    } else {
                        Button { page.settingsSection = .redmine; page.showsSettings = true } label: {
                            Label("레드마인 연결하고 보내기", systemImage: "link")
                        }
                        .buttonStyle(NotionButtonStyle(kind: .primary, fill: true))
                    }
                    HStack {
                        Button("Claude용 복사") {
                            copy(WorkReport.redmineRequest(chosen, fields: fieldsByIssue(chosen), html: settings.redmineHTML), message: "고른 \(chosen.count)건을 Claude에 붙여 넣을 글로 복사했습니다")
                        }
                        .tip("Claude Code에 붙여 넣으면 git을 다시 훑지 않고 고른 일감만 MCP로 올립니다")
                        Spacer()
                        Button("보낸 것으로 표시") {
                            store.markPosted(chosen.flatMap(\.entryIDs))
                            page.flash("\(chosen.count)개 일감을 보낸 것으로 표시했습니다")
                        }
                        .tip("고른 일감을 다른 곳에서 이미 올렸을 때")
                    }
                    .buttonStyle(TextLinkButtonStyle(tint: .secondary))
                    .disabled(chosen.isEmpty)
                }
            }
        }
    }

    /// 몇 건을 골랐는지와 모두 고르기·풀기.
    private func selectionBar(_ updates: [WorkReport.RedmineUpdate], chosen: Int) -> some View {
        let all = chosen == updates.count
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { all },
                set: { on in
                    let issues = updates.map(\.issue)
                    if on { page.redmineSkipped.subtract(issues) } else { page.redmineSkipped.formUnion(issues) }
                }
            )) {
                Text(all ? "모두 고름" : "\(updates.count)건 가운데 \(chosen)건 고름")
                    .font(WL.meta).monospacedDigit()
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.leading, 12)
    }

    private func sendSummary(_ updates: [WorkReport.RedmineUpdate]) -> String {
        var parts = ["\(updates.count)건", "진척률과 댓글"]
        let changing = updates.filter { !fields($0).isEmpty }.count
        if changing > 0 { parts.append("상태·날짜·담당자 \(changing)건") }
        return parts.joined(separator: " · ")
    }

    private func fieldsByIssue(_ updates: [WorkReport.RedmineUpdate]) -> [Int: WorkReport.IssueFields] {
        Dictionary(uniqueKeysWithValues: updates.map { ($0.issue, fields($0)) })
    }

    /// 보낼 때 함께 바꿀 칸: 일지로 정한 값 위에 카드에서 직접 고른 값.
    private func fields(_ update: WorkReport.RedmineUpdate) -> WorkReport.IssueFields {
        sync.fields(for: update, edit: page.issueEdits[update.issue])
    }

    /// 진척률을 실제로 보내는 일감만 따진다 (시간만 남기는 일감은 진척률을 보내지 않는다).
    private func isLowering(_ update: WorkReport.RedmineUpdate) -> Bool {
        guard update.needsNote, let ratio = update.doneRatio, let current = info(update.issue)?.doneRatio else { return false }
        return current > ratio
    }

    /// 보내기 전 확인 창: 일감마다 진척률, 함께 바뀔 칸, 댓글, 작업 시간을 한눈에 보이고 확인해야 보낸다.
    func sendConfirm(_ issues: Set<Int>) -> some View {
        let updates = WorkReport.redmineUpdates(pendingEntries, log: store.log).filter { issues.contains($0.issue) }
        let lowering = updates.filter(isLowering)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("레드마인에 \(updates.count)건을 보낼까요?").font(WL.title)
                Text("보내면 레드마인에 바로 반영됩니다. 잘못 보냈으면 레드마인 탭 > 보낸 기록에서 되돌릴 수 있습니다.")
                    .font(.system(size: 12.5)).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !lowering.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("진척률이 레드마인에 적힌 값보다 낮아지는 일감이 있습니다: "
                         + lowering.map { "#\($0.issue)" }.joined(separator: ", "))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WL.waiting)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.waiting.opacity(0.1)))
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(updates.enumerated()), id: \.element.issue) { index, update in
                        if index > 0 { Rectangle().fill(WL.border.opacity(0.7)).frame(height: 0.5) }
                        confirmRow(update, lowering: isLowering(update))
                    }
                }
            }
            // 시트는 내용 높이로 열려 스크롤 칸이 0으로 접히므로, 일감 수만큼(한 줄 약 52) 높이를 잡아 둔다
            .frame(minHeight: min(CGFloat(updates.count) * 52, 320), maxHeight: 340)
            .wlSurface()
            HStack(spacing: 8) {
                Spacer()
                Button("취소") { page.confirmingSend = nil }
                    .buttonStyle(NotionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                let confirm = Button(lowering.isEmpty ? "\(updates.count)건 보내기" : "낮은 진척률도 그대로 보내기") {
                    page.confirmingSend = nil
                    send(updates, confirmed: true)
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .disabled(updates.isEmpty || sync.sending)
                // 진척률이 낮아지는 일감이 있으면 Return 한 번에 보내지 않게 기본 단추로 두지 않는다
                if lowering.isEmpty { confirm.keyboardShortcut(.defaultAction) } else { confirm }
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(WL.canvas)
    }

    private func confirmRow(_ update: WorkReport.RedmineUpdate, lowering: Bool) -> some View {
        let current = info(update.issue)
        var parts = WorkLogFormat.fieldChanges(fields(update), current: current)
        if update.needsNote { parts.append("댓글 \(update.note.components(separatedBy: "\n").filter { !$0.isEmpty }.count)줄") }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                IssueLabel(issue: update.issue)
                Text(current?.reportTitle ?? "").font(WL.meta).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ratioText(update, current: current?.doneRatio))
                    .font(WL.number)
                    .foregroundStyle(lowering ? WL.waiting : WL.text)
                    .fixedSize()
            }
            FlowLayout(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Text(index < parts.count - 1 ? part + " · " : part)
                }
            }
            .font(WL.caption).foregroundStyle(WL.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func info(_ issue: Int) -> IssueInfo? {
        sync.info(issue)
    }

    private func card(_ update: WorkReport.RedmineUpdate) -> some View {
        let current = info(update.issue)
        let lowering = update.doneRatio.map { ratio in (current?.doneRatio ?? 0) > ratio } ?? false
        let chosen = !page.redmineSkipped.contains(update.issue)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { chosen },
                    set: { on in
                        if on { page.redmineSkipped.remove(update.issue) } else { page.redmineSkipped.insert(update.issue) }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tip(chosen ? "이번에 보내지 않기" : "이번에 보내기")
                IssueLabel(issue: update.issue)
                // 진척률은 번호 옆에 두고 단추는 카드 오른쪽 끝에 모은다 (단추 사이에 숫자가 끼지 않게)
                Text(ratioText(update, current: current?.doneRatio))
                    .font(WL.number)
                    .foregroundStyle(lowering ? WL.waiting : .primary)
                    .tip(lowering ? "레드마인의 지금 진척률보다 낮습니다" : "레드마인 진척률 지금 → 보낼 값")
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    if settings.redmineReady {
                        Button { send([update]) } label: { Image(systemName: "paperplane") }
                            .tip("이 일감만 보내기 (보내기 전에 확인)")
                            .disabled(sync.sending)
                    }
                    cardMenu(update)
                }
                .buttonStyle(GhostIconButtonStyle())
            }
            if let hint = sync.postedHints[update.issue] { postedBanner(update, hint: hint) }
            if let current {
                // 대괄호 머리와 기능 번호를 뗀 보고서 이름으로 보인다. QA 건은 QA로 묶일 것을 알린다
                Text(current.isQA ? IssueInfo.cleanSubject(current.subject) : current.reportTitle).font(WL.meta).lineLimit(2)
                Text((current.isQA ? "QA 수정사항 · " : "") + current.project).font(WL.caption).foregroundStyle(WL.muted).lineLimit(1)
            }
            if let ratio = update.doneRatio {
                RatioBar(current: current?.doneRatio, next: ratio)
            }
            fieldChanges(update, current: current)
            note(update)
        }
        .padding(12)
        .wlSurface()
        // 고르지 않은 일감은 옅게 두어 보낼 것만 눈에 들어오게 한다
        .opacity(chosen ? 1 : 0.5)
    }

    /// 비슷한 댓글이 이미 있을 때: 보낸 것으로 표시하거나 그 댓글을 열어 본다.
    private func postedBanner(_ update: WorkReport.RedmineUpdate, hint: RedmineAPI.Journal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.bubble").font(.system(size: 11, weight: .semibold))
                // 시각은 오른쪽 끝에 따로 두어 좁은 칸에서 시각만 다음 줄로 떨어지지 않게 한다
                Text("비슷한 댓글이 이미 있습니다").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(WorkLogFormat.when(hint.createdOn)).font(WL.caption).monospacedDigit().fixedSize()
            }
            .foregroundStyle(WL.waiting)
            HStack(spacing: 12) {
                Button("보낸 것으로 표시") {
                    store.markPosted(update.entryIDs)
                    page.redmineSkipped.remove(update.issue)
                    page.flash("#\(update.issue)를 보낸 것으로 표시했습니다")
                }
                Button("댓글 보기") { open(update.issue, journal: hint.id) }
            }
            .buttonStyle(TextLinkButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.waiting.opacity(0.1)))
        .tip("Claude나 손으로 이미 올린 것 같아 체크를 풀어 두었습니다. 다시 고르면 그대로 보냅니다")
    }

    /// 잘못 고른 일감을 빼는 방법들. 연결 끊기는 줄을 지우지 않고 일감 번호만 떼어 낸다.
    private func cardMenu(_ update: WorkReport.RedmineUpdate) -> some View {
        Menu {
            Button("일감 번호 바꾸기…") { page.noteEditing = update.issue }
            Button("일감 연결 끊기") {
                for id in update.entryIDs { store.update(id) { $0.issue = nil } }
                page.redmineSkipped.remove(update.issue)
                page.flash("#\(update.issue) 연결을 끊었습니다. 줄은 일지에 그대로 있습니다")
            }
            Button("보낸 것으로 표시") {
                store.markPosted(update.entryIDs)
                page.flash("#\(update.issue)를 보낸 것으로 표시했습니다")
            }
            Divider()
            Button("댓글 복사") { copy(update.note, message: "#\(update.issue) 댓글을 복사했습니다") }
            Button("일감 번호 복사") { copy(String(update.issue), message: "#\(update.issue)를 복사했습니다") }
            Button("레드마인에서 열기") { open(update.issue) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 24)
        .tip("일감 번호 바꾸기·연결 끊기·복사·열기")
    }

    private func open(_ issue: Int, journal: Int? = nil) {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL),
              let url = URL(string: base.appendingPathComponent("issues/\(issue)").absoluteString + (journal.map { "#change-\($0)" } ?? ""))
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 보낸 기록

    private var history: some View {
        let records = Array(store.log.sent.prefix(40))
        return Group {
            if records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("앱으로 보낸 기록이 없습니다").font(WL.heading)
                    Text("레드마인에 보내면 여기 남고, 잘못 보낸 건은 되돌릴 수 있습니다.")
                        .font(WL.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wlSurface()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(records) { record in sentRow(record) }
                    }
                }
            }
        }
    }

    private func sentRow(_ record: RedmineSent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IssueLabel(issue: record.issue)
                Text(WorkLogFormat.when(record.sentAt)).font(WL.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if record.undoneAt != nil {
                    Text("되돌림").font(WL.caption).foregroundStyle(WL.waiting)
                } else {
                    Button("되돌리기") { page.confirmingUndo = record }
                        .buttonStyle(TextLinkButtonStyle(tint: Palette.red))
                        .disabled(sync.sending || !settings.redmineReady)
                }
                Button { open(record.issue) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(GhostIconButtonStyle())
                    .tip("레드마인에서 열기")
            }
            if let title = info(record.issue)?.reportTitle {
                Text(title).font(WL.meta).lineLimit(1)
            }
            // 바뀐 칸마다 통째로 꺾어 `1건`처럼 끝 글자만 다음 줄로 떨어지지 않게 한다
            FlowLayout(spacing: 0) {
                let parts = changeParts(record)
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Text(index < parts.count - 1 ? part + " · " : part)
                }
            }
            .font(WL.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .wlSurface()
        .opacity(record.undoneAt == nil ? 1 : 0.55)
    }

    /// `30% → 100% · 할일 → 완료 · 시작 10.20 · 댓글 · 작업 시간 1건`
    private func changeParts(_ record: RedmineSent) -> [String] {
        var parts: [String] = []
        if let ratio = record.after.doneRatio { parts.append("\(record.before.doneRatio ?? 0)% → \(ratio)%") }
        if let status = record.after.statusName { parts.append("\(record.before.statusName ?? "") → \(status)") }
        if let start = record.after.startDate { parts.append("시작 \(WorkReport.shortDate(start))") }
        if let start = record.after.startDate, start.isEmpty { parts.removeAll { $0.hasPrefix("시작") }; parts.append("시작일 비움") }
        if let due = record.after.dueDate { parts.append(due.isEmpty ? "기한 비움" : "기한 \(WorkReport.shortDate(due))") }
        if let assignee = record.after.assignee { parts.append("담당 \(record.before.assignee?.name ?? "") → \(assignee.name)") }
        if !record.note.isEmpty { parts.append("댓글") }
        if !record.timeEntryIDs.isEmpty { parts.append("작업 시간 \(record.timeEntryIDs.count)건") }
        return parts
    }

    private func undo(_ record: RedmineSent) {
        sync.undo(record) { problems, manual in
            if let manual, let base = RedmineAPI.baseURL(settings.effectiveRedmineURL) {
                // 이 레드마인은 API로 댓글을 지우게 두지 않아, 그 댓글 자리를 열어 연필 > 지우기로 지우게 한다
                NSWorkspace.shared.open(URL(string: base.appendingPathComponent("issues/\(record.issue)").absoluteString + "#change-\(manual)")!)
            }
            var parts = problems
            if manual != nil { parts.insert("댓글은 연 화면에서 연필 > 지우기로 지우세요", at: 0) }
            page.flash(parts.isEmpty ? "#\(record.issue) 보낸 것을 되돌렸습니다. 다시 보낼 목록에 돌아왔습니다"
                       : "#\(record.issue) 되돌림 · " + parts.joined(separator: ", "))
        }
    }

    /// 함께 바꿀 상태·날짜·담당자를 작은 칩으로, 끝에 고치기 단추. 직접 고른 칸은 진하게.
    private func fieldChanges(_ update: WorkReport.RedmineUpdate, current: IssueInfo?) -> some View {
        let fields = fields(update)
        let edit = page.issueEdits[update.issue]
        return FlowLayout(spacing: 4) {
            if let status = fields.status {
                FieldChip(icon: "flag", text: "\(current?.status ?? "") → \(status.name)", picked: edit?.statusID != nil)
            }
            if let start = fields.startDate {
                FieldChip(icon: "play", text: start.isEmpty ? "시작일 비움" : "시작 \(WorkReport.shortDate(start))", picked: edit?.startDate != nil)
            }
            if let due = fields.dueDate {
                FieldChip(icon: "flag.checkered", text: due.isEmpty ? "기한 비움" : "기한 \(WorkReport.shortDate(due))", picked: edit?.dueDate != nil)
            }
            if let assignee = fields.assignee {
                FieldChip(icon: "person", text: "담당 \(assignee.name)", picked: true)
            }
            Button { page.fieldEditing = update.issue } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 9.5, weight: .semibold))
                    Text(fields.isEmpty ? "상태·날짜·담당자" : "고치기").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(WL.muted)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().strokeBorder(WL.border, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .tip("보낼 때 함께 바꿀 상태·시작일·완료 기한·담당자 고르기")
            .popover(isPresented: Binding(
                get: { page.fieldEditing == update.issue },
                set: { if !$0 { page.fieldEditing = nil } }
            ), arrowEdge: .leading) {
                IssueFieldEditor(current: current, auto: settings.syncIssueFields ? sync.fields(for: update) : .init(),
                                 edit: Binding(get: { page.issueEdits[update.issue] ?? .init() },
                                               set: { page.issueEdits[update.issue] = $0.isEmpty ? nil : $0 }),
                                 sync: sync) {
                    Button("닫기") { page.fieldEditing = nil }.buttonStyle(NotionButtonStyle(kind: .primary))
                }
            }
        }
    }

    /// 댓글 미리보기. 길면 펼쳐 보고, 고치기를 누르면 그 줄의 댓글 칸이 뜬다.
    private func note(_ update: WorkReport.RedmineUpdate) -> some View {
        let expanded = page.expandedNotes.contains(update.issue)
        let long = update.note.components(separatedBy: "\n").count > 6 || update.note.count > 240
        let target = store.log.entries.filter { update.entryIDs.contains($0.id) }.sorted { $0.day < $1.day }
            .last(where: \.needsRedmine)?.id ?? update.entryIDs.last
        return VStack(alignment: .leading, spacing: 6) {
            Text(update.note)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 6)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if long {
                    Button(expanded ? "접기" : "펼치기") {
                        if expanded { page.expandedNotes.remove(update.issue) } else { page.expandedNotes.insert(update.issue) }
                    }
                }
                Spacer()
                if let target, update.needsNote {
                    Button("댓글 고치기") { page.noteEditing = update.issue }
                        .popover(isPresented: Binding(
                            get: { page.noteEditing == update.issue },
                            set: { if !$0 { page.noteEditing = nil } }
                        ), arrowEdge: .leading) {
                            EntryEditor(store: store, page: page, id: target)
                        }
                }
            }
            .buttonStyle(TextLinkButtonStyle(tint: WL.muted))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.callout))
    }

    private func ratioText(_ update: WorkReport.RedmineUpdate, current: Int?) -> String {
        guard let ratio = update.doneRatio else { return "진척률 그대로" }
        if let current, current != ratio { return "\(current)% → \(ratio)%" }
        return "\(ratio)%"
    }

    // MARK: 보내기

    private func send(_ updates: [WorkReport.RedmineUpdate], confirmed: Bool = false) {
        if !confirmed {
            page.confirmingSend = updates.map(\.issue)
            return
        }
        let issues = Set(updates.map(\.issue))
        let fresh = WorkReport.redmineUpdates(pendingEntries, log: store.log).filter { issues.contains($0.issue) }
        sync.send(fresh, edits: page.issueEdits) { sent, failures in
            // 보낸 일감은 직접 고른 칸을 비운다 (다음에 또 보낼 때 묵은 값이 나가지 않게)
            let left = Set(pendingEntries.compactMap(\.issue))
            for issue in issues where !left.contains(issue) { page.issueEdits[issue] = nil }
            page.flash(failures.isEmpty ? "레드마인에 \(sent)건 보냈습니다" : "\(sent)건 보냄 · " + failures.joined(separator: ", "))
        }
    }

    private func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        page.flash(message)
    }
}

/// 보낼 때 함께 바꿀 칸 하나 (상태, 시작일, 기한).
/// 보고서 미리보기. `- ` 줄이 꺾이면 이어지는 줄을 `- ` 다음 글자에 맞춰, `(100%)`만 맨 앞으로 떨어져 보이지 않게 한다.
/// SwiftUI Text는 내어쓰기를 못 해서 읽기 전용 NSTextView로 그린다.
private struct ReportText: NSViewRepresentable {
    let text: String
    let placeholder: Bool
    // 화면 모드를 바꾸면 다시 그리게 읽어 둔다
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 11, height: 14)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let rendered = attributed()
        guard view.attributedString() != rendered else { return }
        // 자동 수집으로 글이 바뀌어도 복사하려고 끌어 둔 선택과 읽던 자리가 풀리지 않게 되돌린다
        let selection = view.selectedRanges
        let visible = scroll.contentView.bounds.origin
        view.textStorage?.setAttributedString(rendered)
        let length = rendered.length
        view.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= length }.nilIfEmpty ?? [NSValue(range: NSRange(location: 0, length: 0))]
        scroll.contentView.scroll(to: visible)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func attributed() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13)
        let color = NSColor(placeholder ? WL.muted : WL.text)
        let lines = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            // AppKit은 한글을 글자 사이에서도 꺾어 `연동`이 `연/동`으로 갈린다
            style.lineBreakStrategy = .hangulWordPriority
            let indent = line.prefix { $0 == " " }
            if line.dropFirst(indent.count).hasPrefix("- ") {
                style.headIndent = (String(indent) + "- " as NSString).size(withAttributes: [.font: font]).width
            }
            result.append(NSAttributedString(string: line + (index < lines.count - 1 ? "\n" : ""),
                                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        return result
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

private struct FieldChip: View {
    let icon: String
    let text: String
    var picked = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(picked ? Color.white : WL.accent)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(picked ? WL.accent : WL.selected))
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
