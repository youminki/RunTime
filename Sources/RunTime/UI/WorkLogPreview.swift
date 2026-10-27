import AppKit
import SwiftUI
import WorkLogCore

/// 오른쪽 칸: 지금 보는 범위의 보고서(복사·팀즈)와 레드마인에 보낼 진척률·댓글·상태·날짜·담당자.
struct WorkLogPreview: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var sync: WorkLogSync
    @ObservedObject var settings: WorkLogSettings
    @ObservedObject private var shots = MRScreenStore.shared

    var body: some View {
        let updates = WorkReport.redmineUpdates(pendingEntries, log: store.log)
        VStack(alignment: .leading, spacing: 14) {
            PageTabs(items: [(WorkLogPage.Preview.report, reportTitle),
                             (WorkLogPage.Preview.redmine, updates.isEmpty ? "레드마인" : "레드마인 \(updates.count)")],
                     selection: $page.preview, fill: true)
            switch page.preview {
            case .report: report
            case .redmine: redmine(edited(updates))
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
        .alert("보고 채팅에 올릴까요?", isPresented: $page.confirmingTeams) {
            Button("올리기") { postTeams(to: .chat) }
            Button("취소", role: .cancel) {}
        } message: {
            Text(settings.teamsDirect(.chat)
                 || (settings.teamsAutoSend && settings.teamsAutoPaste && AXIsProcessTrusted() && TeamsOpener.teamsPWA() != nil)
                 ? "\(postTitle)을 팀 채팅에 바로 올립니다. 올린 글은 팀즈에서 지워야 합니다."
                 : "팀즈에서 보고 채팅을 열고 \(postTitle)을 붙여 넣습니다. 확인하고 Enter를 누르면 올라갑니다.")
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

    private var copyName: String { isPlan ? "진행 예정" : page.mode == .day || page.mode == .issues ? "진행 사항" : reportTitle }

    private var isPlan: Bool { (page.mode == .day || page.mode == .issues) && page.dayReport == .plan }

    /// 일지에서 만든 진행 예정 사항 (고쳐 쓰기 전).
    private var generatedPlan: String {
        WorkReport.plan(day: page.day, in: store.log)
    }

    /// 하루 보고서 머리줄 `[10/27 진행 사항]`. 팀즈에는 늘 이 줄을 제목으로 올린다.
    private var dayHeader: String { WorkReport.dayHeader(page.day, plan: isPlan) }

    /// 머리줄을 뺀 보고서 몸통.
    private var reportBody: String {
        let grouped = settings.reportGrouped
        switch page.mode {
        case .day, .issues:
            if isPlan { return page.planEdits[page.day]?.text ?? generatedPlan }
            return WorkReport.daily(scopeEntries, in: store.log, doneFirst: settings.doneFirst, byIssue: settings.reportByIssue,
                                    grouped: grouped)
        default:
            // 주간·월간은 첫 줄이 머리줄이다
            let lines = reportText.components(separatedBy: "\n")
            return lines.first?.hasPrefix("[") == true ? lines.dropFirst().joined(separator: "\n") : reportText
        }
    }

    /// 팀즈에 올릴 제목 (굵게 첫 줄로 간다).
    private var postTitle: String {
        switch page.mode {
        case .day, .issues: return dayHeader
        case .project: return "\(selectedProject ?? "프로젝트") 요약"
        default: return reportText.components(separatedBy: "\n").first ?? reportTitle
        }
    }

    private var reportText: String {
        let grouped = settings.reportGrouped
        switch page.mode {
        case .day, .issues:
            let body = reportBody
            return body.isEmpty || !settings.dailyHeader ? body : dayHeader + "\n" + body
        case .week:
            return WorkReport.weekly(scopeEntries, in: store.log, week: WorkDay.week(of: page.day),
                                     doneFirst: settings.doneFirst, nextWeekPlan: settings.weeklyPlan, byIssue: settings.reportByIssue,
                                     grouped: grouped)
        case .month:
            return WorkReport.monthly(scopeEntries, in: store.log, month: WorkDay.month(of: page.day), byIssue: settings.reportByIssue,
                                      grouped: grouped)
        case .project:
            return WorkReport.daily(WorkReport.merged(scopeEntries), in: store.log, doneFirst: settings.doneFirst,
                                    byIssue: settings.reportByIssue, grouped: grouped)
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
            if page.mode == .day || page.mode == .issues {
                // 출근 때는 진행 예정, 퇴근 때는 진행 사항을 올린다
                HStack(spacing: 8) {
                    Picker("", selection: $page.dayReport) {
                        ForEach(WorkLogPage.DayReport.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text(dayHeader).font(WL.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                }
            }
            if isPlan {
                planEditor
            } else {
                ReportText(text: text.isEmpty ? "적은 일이 여기 보고서 꼴로 만들어집니다." : text, placeholder: text.isEmpty)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.canvas))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("레드마인 일감 이름으로, QA는 건수로 모아 쓰기", isOn: $settings.reportByIssue)
                    .tip("일감 줄은 `데이터 수집 > 공유 파일 관리 API 연동 (100%)`처럼, QA 건은 `QA 수정사항 N건 반영`으로 적습니다")
                Toggle("같은 메뉴는 묶어 쓰기", isOn: $settings.reportGrouped)
                    .tip("`데이터 수집 > 수집 관리`처럼 앞 경로가 같은 줄이 둘 이상이면 경로를 한 번만 적고 그 아래 `· 끝 이름 (상태)`로 늘어놓습니다")
                if page.mode == .day || page.mode == .issues {
                    Toggle("맨 위에 \(dayHeader) 붙이기", isOn: $settings.dailyHeader)
                        .tip("복사할 때 맨 위에 붙입니다. 팀즈에는 켜고 끄는 것과 상관없이 늘 이 줄을 제목으로 올립니다")
                }
                // 진행 예정에는 상태가 없어 순서도 쓰지 않는다
                if page.mode != .month && !isPlan {
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
                    copy(text, message: "\(copyName)를 복사했습니다")
                } label: {
                    Label("\(copyName) 복사", systemImage: "doc.on.doc")
                }
                .buttonStyle(NotionButtonStyle(kind: .primary, fill: true))
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(text.isEmpty)
                .tip("⇧⌘C")
                // 나에게는 설정 없이 늘 보낼 수 있고, 보고 채팅은 링크나 웹훅을 넣었을 때만 보인다
                HStack(spacing: 6) {
                    if settings.hasTeams(.chat) {
                        Button { page.confirmingTeams = true } label: {
                            HStack {
                                if sync.postingTeams { ProgressView().controlSize(.small) }
                                Label("팀즈 채팅에 올리기", systemImage: "bubble.left.and.bubble.right")
                            }
                        }
                        .buttonStyle(NotionButtonStyle(fill: true))
                    }
                    Button { postTeams(to: .me) } label: {
                        Label("나에게 보내기", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(NotionButtonStyle(fill: true))
                    .tip("나와의 채팅으로 먼저 보내 봅니다")
                }
                .disabled(text.isEmpty || sync.postingTeams)
                if !settings.hasTeams(.chat) {
                    Button("보고 채팅 연결") { page.settingsSection = .teams; page.showsSettings = true }
                        .buttonStyle(TextLinkButtonStyle())
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 진행 예정 사항은 일지에서 만든 뒤 그대로 고쳐 쓸 수 있다 (`마크업 및 api 연동`처럼 뭉뚱그려 쓰는 관례).
    private var planEditor: some View {
        let generated = generatedPlan
        let edit = page.planEdits[page.day]
        // 고친 뒤 일지에 프로젝트가 더해지거나 빠졌으면 알린다
        let stale = edit.map { $0.base != generated } ?? false
        return VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                // 머리줄은 진행 사항 보고서처럼 글 맨 위에 보이되, 날짜에서 만들므로 고쳐 쓰지는 않는다
                if settings.dailyHeader {
                    Text(dayHeader).font(.system(size: 13)).foregroundStyle(WL.text)
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, -9)
                        .textSelection(.enabled)
                }
                ReportText(text: page.planEdits[page.day]?.text ?? generated, placeholder: false) { text in
                    let base = page.planEdits[page.day]?.base ?? generated
                    page.planEdits[page.day] = text == generated ? nil : (text, base)
                }
                .frame(minHeight: 140)
            }
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if reportBody.isEmpty {
                    Text("어제 끝내지 못한 일과 오늘 적은 일로 만들어집니다. 여기에 바로 써도 됩니다.")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 16).padding(.top, settings.dailyHeader ? 32 : 14).allowsHitTesting(false)
                }
            }
            HStack(spacing: 10) {
                Text(stale ? "고친 뒤 일지가 바뀌었습니다" : edit != nil ? "고쳐 쓴 계획" : "일지에서 만든 계획 · 바로 고쳐 쓸 수 있습니다")
                    .font(WL.caption).foregroundStyle(stale ? WL.waiting : .secondary)
                Spacer()
                if edit != nil {
                    Button("일지로 다시 만들기") { page.planEdits[page.day] = nil }.buttonStyle(TextLinkButtonStyle())
                }
            }
        }
    }

    private func postTeams(to target: TeamsTarget) {
        sync.postTeams(reportBody, title: postTitle, to: target) { message, _ in
            page.flash(message)
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
                SlimScrollView {
                    VStack(spacing: 14) {
                        ForEach(updates, id: \.issue) { update in card(update) }
                    }
                }
                .onAppear {
                    sync.loadInfo(updates.map(\.issue))
                    if settings.redmineReady { sync.checkPosted(updates) }
                    loadScreens(updates)
                }
                .onChange(of: updates.map(\.issue)) { _ in
                    sync.loadInfo(updates.map(\.issue))
                    if settings.redmineReady { sync.checkPosted(updates) }
                    loadScreens(updates)
                }
                .onReceive(sync.$postedHints) { hints in
                    // 같은 댓글이 이미 있는 일감은 처음 한 번 댓글만 뺀다. 진척률·칸은 그대로 보낸다 (댓글 스위치로 되돌린다)
                    for issue in hints.keys where !page.hintApplied.contains(issue) {
                        page.hintApplied.insert(issue)
                        page.redmineNoNote.insert(issue)
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
        let noted = updates.filter { $0.needsNote && !page.redmineNoNote.contains($0.issue) }.count
        var parts = ["\(updates.count)건", noted == updates.count ? "진척률과 댓글" : "댓글 \(noted)건"]
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
    /// 카드에서 직접 고른 진척률을 얹는다. 보낼 때(`sync.send`)도 같은 값을 얹는다.
    private func edited(_ updates: [WorkReport.RedmineUpdate]) -> [WorkReport.RedmineUpdate] {
        updates.map { sync.prepared($0, edit: page.issueEdits[$0.issue]) }
    }

    /// 일지 줄의 상태로 정한 진척률 (직접 고르기 전 값).
    private func journalRatio(_ issue: Int) -> Int? {
        WorkReport.redmineUpdates(pendingEntries, log: store.log).first { $0.issue == issue }
            .flatMap { sync.prepared($0, edit: nil).doneRatio }
    }

    private func isLowering(_ update: WorkReport.RedmineUpdate) -> Bool {
        guard update.needsNote, let ratio = update.doneRatio, let current = info(update.issue)?.doneRatio else { return false }
        return current > ratio
    }

    /// 보내기 전 확인 창: 일감마다 진척률, 함께 바뀔 칸, 댓글, 작업 시간을 한눈에 보이고 확인해야 보낸다.
    func sendConfirm(_ issues: Set<Int>) -> some View {
        let updates = edited(WorkReport.redmineUpdates(pendingEntries, log: store.log).filter { issues.contains($0.issue) })
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
            SlimScrollView {
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
        if page.redmineNoNote.contains(update.issue) {
            parts.append("댓글 빼고 보냄")
        } else if update.needsNote {
            parts.append("댓글 \(update.note.components(separatedBy: "\n").filter { !$0.isEmpty }.count)줄")
        }
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

    /// 보낼 일감 카드. 머리(번호·제목) 아래로 진척률 · 함께 바꿀 칸 · 댓글 · 화면 영역을 선으로 나누고,
    /// 영역마다 고치는 단추를 제목줄 오른쪽 같은 자리에 둔다.
    private func card(_ update: WorkReport.RedmineUpdate) -> some View {
        let current = info(update.issue)
        let chosen = !page.redmineSkipped.contains(update.issue)
        let shape = RoundedRectangle(cornerRadius: WL.outer, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            // 머리에 옅은 띠를 깔아 카드가 어디서 시작하는지 보이게 한다 (카드가 길어도 다음 카드와 섞이지 않게)
            cardHeader(update, current: current, chosen: chosen)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(chosen ? WL.accent.opacity(0.07) : Color.primary.opacity(0.035))
            Rectangle().fill(WL.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                if let hint = sync.postedHints[update.issue] {
                    postedBanner(update, hint: hint).padding(.top, 12).padding(.bottom, 2)
                }
                cardSection(first: true) { progress(update, current: current) }
                cardSection { fieldChanges(update, current: current) }
                cardSection { note(update) }
                screens(update)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .background(shape.fill(WL.surface))
        .clipShape(shape)
        .overlay(shape.strokeBorder(chosen ? WL.border.opacity(1) : WL.border.opacity(0.5), lineWidth: 1))
        .shadow(color: Color.black.opacity(chosen ? 0.08 : 0), radius: 3, y: 1)
        // 고르지 않은 일감은 옅게 두어 보낼 것만 눈에 들어오게 한다
        .opacity(chosen ? 1 : 0.55)
    }

    /// 영역 하나: 위에 가는 선, 위아래 여백.
    private func cardSection<Content: View>(first: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Rectangle().fill(WL.border.opacity(0.6)).frame(height: 1) }
            content().padding(.vertical, 11)
        }
    }

    private func cardHeader(_ update: WorkReport.RedmineUpdate, current: IssueInfo?, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
                if current?.isQA == true {
                    Text("QA").font(.system(size: 9.5, weight: .bold)).foregroundStyle(WL.waiting)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Capsule().fill(WL.waiting.opacity(0.14)))
                        .tip("QA 수정사항으로 묶여 보고됩니다")
                }
                Spacer(minLength: 4)
                if settings.redmineReady {
                    Button { send([update]) } label: { Label("보내기", systemImage: "paperplane") }
                        .buttonStyle(PillButtonStyle(tint: WL.accent))
                        .tip("이 일감만 보내기 (보내기 전에 확인)")
                        .disabled(sync.sending)
                }
                cardMenu(update)
                    .buttonStyle(GhostIconButtonStyle())
            }
            if let current {
                // 대괄호 머리와 기능 번호를 뗀 보고서 이름으로 보인다
                Text(current.isQA ? IssueInfo.cleanSubject(current.subject) : current.reportTitle)
                    .font(WL.heading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(current.project).font(WL.caption).foregroundStyle(WL.muted).lineLimit(1)
            } else {
                Text("일감 정보를 받는 중…").font(WL.caption).foregroundStyle(WL.faint)
            }
        }
    }

    /// 진척률: 지금 → 보낼 값과 막대. 고치기로 0~100%를 바로 고르고, 직접 고른 값은 파란 점으로 알린다.
    /// 100%를 고르면 함께 바꿀 칸의 상태도 완료로 따라온다.
    private func progress(_ update: WorkReport.RedmineUpdate, current: IssueInfo?) -> some View {
        let lowering = update.doneRatio.map { ratio in (current?.doneRatio ?? 0) > ratio } ?? false
        let picked = page.issueEdits[update.issue]?.doneRatio != nil
        return VStack(alignment: .leading, spacing: 8) {
            CardSectionHeader(icon: "chart.bar.fill", title: "진척률") {
                HStack(spacing: 6) {
                    if picked { Circle().fill(WL.accent).frame(width: 5, height: 5).tip("직접 고른 진척률") }
                    Text(ratioText(update, current: current?.doneRatio))
                        .font(WL.number)
                        .foregroundStyle(lowering ? WL.waiting : update.doneRatio == nil ? WL.muted : .primary)
                        .tip(lowering ? "레드마인의 지금 진척률보다 낮습니다" : "레드마인 진척률 지금 → 보낼 값")
                    ratioMenu(update, current: current)
                }
            }
            if let ratio = update.doneRatio {
                RatioBar(current: current?.doneRatio, next: ratio)
            }
        }
    }

    /// 진척률 고르기. 다른 고치기와 같은 단추에서 작은 창을 열어 일지대로 두거나 10% 단위로 고른다.
    private func ratioMenu(_ update: WorkReport.RedmineUpdate, current: IssueInfo?) -> some View {
        Button { page.ratioEditing = update.issue } label: { Label("고치기", systemImage: "pencil") }
            .buttonStyle(PillButtonStyle())
            .tip("보낼 진척률 고르기")
            .popover(isPresented: Binding(
                get: { page.ratioEditing == update.issue },
                set: { if !$0 { page.ratioEditing = nil } }
            ), arrowEdge: .leading) {
                ratioPicker(update, current: current)
            }
    }

    private func ratioPicker(_ update: WorkReport.RedmineUpdate, current: IssueInfo?) -> some View {
        let picked = page.issueEdits[update.issue]?.doneRatio
        let auto = journalRatio(update.issue)
        func set(_ ratio: Int?) {
            var edit = page.issueEdits[update.issue] ?? .init()
            edit.doneRatio = ratio
            page.issueEdits[update.issue] = edit.isEmpty ? nil : edit
            page.ratioEditing = nil
        }
        func cell(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium)).monospacedDigit()
                    .foregroundStyle(selected ? Color.white : WL.text)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? WL.accent : Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("보낼 진척률").font(WL.heading)
                Text("레드마인 지금 \(current.map { "\($0.doneRatio)%" } ?? "모름") · 100%를 고르면 상태도 완료로 바뀝니다")
                    .font(WL.caption).foregroundStyle(WL.muted)
            }
            cell("일지대로 · " + (auto.map { "\($0)%" } ?? "그대로 둠"), selected: picked == nil) { set(nil) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(stride(from: 0, through: 100, by: 10)), id: \.self) { value in
                    cell(value == 100 ? "완료" : "\(value)%", selected: picked == value) { set(value) }
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    /// 비슷한 댓글이 이미 있을 때: 댓글은 저절로 빼고 진척률·칸만 보낸다. 댓글도 보내거나, 보낸 것으로 표시하거나, 그 댓글을 연다.
    private func postedBanner(_ update: WorkReport.RedmineUpdate, hint: RedmineAPI.Journal) -> some View {
        let noNote = page.redmineNoNote.contains(update.issue)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.bubble").font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("같은 댓글이 이미 있습니다").font(.system(size: 11.5, weight: .semibold))
                    Text(!noNote ? "댓글도 다시 보냅니다"
                         : nothingElse(update) ? "진척률·칸도 이미 같아, 보내면 보낸 것으로만 표시합니다"
                         : "이번에는 댓글을 빼고 진척률·칸만 보냅니다")
                        .font(WL.caption).foregroundStyle(WL.text.opacity(0.75))
                }
                Spacer(minLength: 4)
                // 시각은 오른쪽 끝에 따로 두어 좁은 칸에서 시각만 다음 줄로 떨어지지 않게 한다
                Text(WorkLogFormat.when(hint.createdOn)).font(WL.caption).monospacedDigit().fixedSize()
            }
            .foregroundStyle(WL.waiting)
            FlowLayout(spacing: 6) {
                Button { open(update.issue, journal: hint.id) } label: { Label("댓글 보기", systemImage: "arrow.up.right") }
                Button {
                    if noNote { page.redmineNoNote.remove(update.issue) } else { page.redmineNoNote.insert(update.issue) }
                } label: { Label(noNote ? "댓글도 보내기" : "댓글 빼기", systemImage: noNote ? "plus.bubble" : "minus.circle") }
                Button {
                    store.markPosted(update.entryIDs)
                    page.redmineSkipped.remove(update.issue)
                    page.flash("#\(update.issue)를 보낸 것으로 표시했습니다")
                } label: { Label("보낸 것으로 표시", systemImage: "checkmark") }
                    .tip("진척률·칸도 보내지 않고 목록에서 뺍니다")
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.waiting.opacity(0.1)))
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
                SlimScrollView {
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

    /// 함께 바꿀 상태·날짜·담당자. 직접 고른 칸은 진하게, 고치기는 제목줄 오른쪽에.
    private func fieldChanges(_ update: WorkReport.RedmineUpdate, current: IssueInfo?) -> some View {
        let fields = fields(update)
        let edit = page.issueEdits[update.issue]
        return VStack(alignment: .leading, spacing: 8) {
            CardSectionHeader(icon: "slider.horizontal.3", title: "함께 바꿀 칸") {
                Button { page.fieldEditing = update.issue } label: { Label("고치기", systemImage: "pencil") }
                    .buttonStyle(PillButtonStyle())
                    .tip("보낼 때 함께 바꿀 상태·시작일·완료 기한·담당자 고르기")
                    .popover(isPresented: Binding(
                        get: { page.fieldEditing == update.issue },
                        set: { if !$0 { page.fieldEditing = nil } }
                    ), arrowEdge: .leading) {
                        IssueFieldEditor(current: current, auto: settings.syncIssueFields ? sync.fields(for: update) : .init(),
                                         autoRatio: journalRatio(update.issue),
                                         edit: Binding(get: { page.issueEdits[update.issue] ?? .init() },
                                                       set: { page.issueEdits[update.issue] = $0.isEmpty ? nil : $0 }),
                                         sync: sync) {
                            Button("닫기") { page.fieldEditing = nil }.buttonStyle(NotionButtonStyle(kind: .primary))
                        }
                    }
            }
            if fields.isEmpty {
                Text("바꿀 칸 없음 · 상태\(current?.status.isEmpty == false ? "(\(current!.status))" : "")는 그대로 둡니다")
                    .font(WL.caption).foregroundStyle(WL.muted)
            } else {
                FlowLayout(spacing: 4) {
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
                }
            }
        }
    }

    /// 댓글 미리보기. 고치기는 제목줄 오른쪽, 길면 아래에서 펼친다.
    private func note(_ update: WorkReport.RedmineUpdate) -> some View {
        let expanded = page.expandedNotes.contains(update.issue)
        let long = update.note.components(separatedBy: "\n").count > 6 || update.note.count > 240
        let target = store.log.entries.filter { update.entryIDs.contains($0.id) }.sorted { $0.day < $1.day }
            .last(where: \.needsRedmine)?.id ?? update.entryIDs.last
        let noNote = page.redmineNoNote.contains(update.issue)
        return VStack(alignment: .leading, spacing: 8) {
            CardSectionHeader(icon: "text.bubble", title: "댓글", detail: noNote ? "빼고 보냄" : nil) {
                if update.needsNote {
                    Toggle("", isOn: Binding(
                        get: { !noNote },
                        set: { on in
                            if on { page.redmineNoNote.remove(update.issue) } else { page.redmineNoNote.insert(update.issue) }
                        }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .tip(noNote ? "댓글도 함께 보내기" : "댓글은 빼고 진척률·상태·날짜만 보내기")
                }
                if let target, update.needsNote, !noNote {
                    Button { page.noteEditing = update.issue } label: { Label("고치기", systemImage: "pencil") }
                        .buttonStyle(PillButtonStyle())
                        .tip("이 일감 줄의 댓글 고치기")
                        .popover(isPresented: Binding(
                            get: { page.noteEditing == update.issue },
                            set: { if !$0 { page.noteEditing = nil } }
                        ), arrowEdge: .leading) {
                            EntryEditor(store: store, page: page, id: target)
                        }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(update.note)
                    .font(.system(size: 12))
                    .foregroundStyle(WL.text)
                    .lineLimit(expanded ? nil : noNote ? 2 : 6)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if long {
                    Button {
                        if expanded { page.expandedNotes.remove(update.issue) } else { page.expandedNotes.insert(update.issue) }
                    } label: {
                        Label(expanded ? "접기" : "모두 보기", systemImage: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(TextLinkButtonStyle(tint: WL.accent))
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11.5, weight: .medium))
                }
            }
            .padding(10)
            .opacity(noNote ? 0.4 : 1)
            // 어두운 화면에서는 callout과 카드 바탕이 같은 색이라 옅은 덧칠과 테두리로 상자를 보인다
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.border.opacity(0.6), lineWidth: 1))
        }
    }

    /// 이 일감 줄이 온 MR의 수정 전·후 화면. 보낼 때 레드마인에 첨부하고 댓글 끝에 붙는다.
    /// 레드마인 댓글과 같은 순서로, 항목 제목 아래 수정 전·후를 나란히 보인다.
    @ViewBuilder
    private func screens(_ update: WorkReport.RedmineUpdate) -> some View {
        let origins = settings.attachScreens && !page.redmineNoNote.contains(update.issue)
            ? MRScreenStore.origins(store.log.entries.filter { update.entryIDs.contains($0.id) }.map(\.source)) : []
        let refs = shots.refs(origins)
        if !origins.isEmpty {
            let groups = refs.flatMap { ref in
                (shots.screens[ref] ?? []).enumerated().map { index, screen in
                    ScreenGroup(id: "\(ref.key)#\(index)", mr: refs.count > 1 && index == 0 ? ref.iid : nil, number: index + 1,
                                title: screen.title, before: screen.before, after: screen.after)
                }
            }
            let count = groups.reduce(0) { $0 + ($1.before == nil ? 0 : 1) + ($1.after == nil ? 0 : 1) }
            let loading = origins.contains { shots.loading.contains($0) }
            let off = page.redmineNoScreens.contains(update.issue)
            if loading || !groups.isEmpty {
                cardSection {
                    VStack(alignment: .leading, spacing: 10) {
                        CardSectionHeader(icon: "photo.on.rectangle.angled", title: "수정 전·후 화면",
                                          detail: loading ? nil : off ? "붙이지 않음" : "\(count)장 첨부") {
                            if loading {
                                ProgressView().controlSize(.mini)
                            } else if !groups.isEmpty {
                                Toggle("", isOn: Binding(
                                    get: { !off },
                                    set: { on in
                                        if on { page.redmineNoScreens.remove(update.issue) } else { page.redmineNoScreens.insert(update.issue) }
                                    }
                                ))
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .tip(off ? "화면을 함께 올리기" : "이번에는 화면 없이 댓글만 보내기")
                            }
                        }
                        if loading {
                            Text("MR에서 수정 전·후 화면을 찾는 중…").font(WL.caption).foregroundStyle(WL.muted)
                        } else if !off {
                            ForEach(groups) { group in
                                // MR이 여럿이면 어느 MR 화면인지 머리를 단다 (번호는 MR마다 1부터)
                                if let mr = group.mr {
                                    Text("MR !\(mr)").font(WL.label).foregroundStyle(WL.muted).padding(.top, 2)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(group.number). \(group.title.map(MRScreenTitle.short) ?? "화면")")
                                        .font(WL.caption).foregroundStyle(.secondary).lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 6) {
                                        thumb(group.before, kind: .before)
                                        thumb(group.after, kind: .after)
                                    }
                                }
                            }
                            Text("댓글 끝 [수정 전·후 화면]에 이 순서로 붙습니다. 누르면 크게 봅니다.")
                                .font(WL.caption).foregroundStyle(WL.faint)
                        }
                    }
                }
            }
        }
    }

    /// 보낼 일감들의 MR 화면을 받는다. 카드 안의 빈 칸에 달면 처음에 보이는 것이 없어 불리지 않으므로 목록에서 부른다.
    private func loadScreens(_ updates: [WorkReport.RedmineUpdate]) {
        guard settings.attachScreens else { return }
        let ids = Set(updates.flatMap(\.entryIDs))
        let origins = MRScreenStore.origins(store.log.entries.filter { ids.contains($0.id) }.map(\.source))
        shots.load(origins, host: settings.gitlabHostName)
    }

    /// 썸네일 하나. 캡처가 없으면 빈 칸으로 두어 어느 쪽이 빠졌는지 보인다. 누르면 원본을 연다.
    private func thumb(_ path: String?, kind: MRScreens.Kind) -> some View {
        let image = path.flatMap { shots.thumbnails[$0] }
        return Button {
            if let path { shots.open(path) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(WL.callout)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(path == nil ? "캡처 없음" : "불러오는 중").font(WL.caption).foregroundStyle(WL.faint)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(WL.border, style: StrokeStyle(lineWidth: 1, dash: path == nil ? [3, 3] : [])))
            .overlay(alignment: .topLeading) {
                Text(kind.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule().fill(path == nil ? WL.faint : kind == .before ? WL.quiet : WL.done))
                    .padding(4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .tip(image == nil ? kind.label : "\(kind.label) 크게 보기")
    }

    private func ratioText(_ update: WorkReport.RedmineUpdate, current: Int?) -> String {
        guard let ratio = update.doneRatio else { return "진척률 그대로" }
        guard let current else { return "\(ratio)%" }
        return current == ratio ? "\(ratio)% · 같음" : "\(current)% → \(ratio)%"
    }

    /// 댓글을 빼면 레드마인에서 바뀌는 것이 없는지 (진척률이 같고 함께 바꿀 칸도 없다).
    private func nothingElse(_ update: WorkReport.RedmineUpdate) -> Bool {
        let ratioSame = update.doneRatio == nil || update.doneRatio == info(update.issue)?.doneRatio
        return ratioSame && fields(update).isEmpty
    }

    // MARK: 보내기

    private func send(_ updates: [WorkReport.RedmineUpdate], confirmed: Bool = false) {
        if !confirmed {
            page.confirmingSend = updates.map(\.issue)
            return
        }
        let issues = Set(updates.map(\.issue))
        let fresh = WorkReport.redmineUpdates(pendingEntries, log: store.log).filter { issues.contains($0.issue) }
        sync.send(fresh, edits: page.issueEdits, withoutScreens: page.redmineNoScreens, withoutNotes: page.redmineNoNote) { sent, failures in
            // 보낸 일감은 직접 고른 칸을 비운다 (다음에 또 보낼 때 묵은 값이 나가지 않게)
            let left = Set(pendingEntries.compactMap(\.issue))
            for issue in issues where !left.contains(issue) {
                page.issueEdits[issue] = nil
                page.redmineNoNote.remove(issue)
            }
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
    /// 있으면 고쳐 쓸 수 있다 (진행 예정). 진행 사항과 같은 글꼴·줄 간격으로 보이게 같은 칸을 쓴다.
    var onEdit: ((String) -> Void)?
    // 화면 모드를 바꾸면 다시 그리게 읽어 둔다
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: ((String) -> Void)?
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onEdit?(view.string)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        // 다른 칸과 같은 얇은 막대 (글을 덮지 않게 제 자리를 갖는다)
        SlimScroller.install(on: scroll)
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = onEdit != nil
            view.isSelectable = true
            view.isRichText = false
            view.allowsUndo = true
            view.delegate = context.coordinator
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 11, height: 14)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.onEdit = onEdit
        view.isEditable = onEdit != nil
        // 고쳐 쓰는 칸에서 새로 친 글도 같은 글꼴·줄 간격으로
        view.typingAttributes = Self.base(NSColor(WL.text))
        // 글자를 치는 중에는 다시 그리지 않는다 (한글 조합이 끊기고 커서가 튄다)
        if onEdit != nil, view.string == text || view.hasMarkedText() { return }
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

    static func base(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.lineBreakStrategy = .hangulWordPriority
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: style]
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
            // `- `와 묶음 하위 줄의 `· `는 꺾인 줄이 글머리 뒤에서 시작하게 한다
            if let bullet = ["- ", "· "].first(where: { line.dropFirst(indent.count).hasPrefix($0) }) {
                style.headIndent = (String(indent) + bullet as NSString).size(withAttributes: [.font: font]).width
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

/// 카드에 보일 화면 항목 하나 (제목과 수정 전·후).
private struct ScreenGroup: Identifiable {
    let id: String
    /// MR이 여럿일 때 그 MR의 첫 항목에만 번호를 둔다.
    let mr: Int?
    let number: Int
    let title: String?
    let before: String?
    let after: String?
}

private enum MRScreenTitle {
    /// `제목 (\`/경로\`): 확인됨` → `제목`.
    static func short(_ title: String) -> String {
        var text = title
        if let open = text.range(of: " (") { text = String(text[..<open.lowerBound]) }
        return text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }
}
