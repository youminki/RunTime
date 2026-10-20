import AppKit
import SwiftUI
import WorkLogCore

/// 업무 일지 연동 설정. 노션 설정 창처럼 왼쪽에서 칸을 고르고, 오른쪽은 "이름·설명 | 조작" 줄로 둔다.
/// 키·주소는 붙여넣기 한 번에 확인하고 저장까지 한다.
struct WorkLogSettingsView: View {
    @ObservedObject var settings: WorkLogSettings
    @ObservedObject var sync: WorkLogSync
    @ObservedObject var page: WorkLogPage
    @ObservedObject var store: WorkLogStore

    var body: some View {
        HStack(spacing: 0) {
            nav
            Rectangle().fill(WL.border).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(page.settingsSection.rawValue).font(WL.title).padding(.bottom, 4)
                        Text(sectionNote).font(.system(size: 12.5)).foregroundStyle(WL.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 18)
                        Rectangle().fill(WL.border).frame(height: 1)
                        switch page.settingsSection {
                        case .gitlab: gitlab
                        case .redmine: redmine
                        case .teams: teams
                        case .recurring: recurring
                        case .shortcuts: shortcuts
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
                }
                Rectangle().fill(WL.border).frame(height: 1)
                HStack {
                    Text("바뀐 값은 바로 저장됩니다").font(.system(size: 12)).foregroundStyle(WL.faint)
                    Spacer()
                    // Return은 칸의 저장에 쓰여 완료에 걸지 않는다
                    Button("완료") { finish() }
                        .buttonStyle(NotionButtonStyle(kind: .primary))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .frame(height: 56)
            }
            .background(WL.canvas)
        }
        .frame(width: 820, height: 580)
        .foregroundStyle(WL.text)
        .onAppear {
            page.keyDraft = ""
            page.teamsDraft = ""
            if settings.redmineReady && settings.logTime { sync.loadActivities() }
        }
    }

    private func finish() {
        // 칸에 써 두고 저장을 누르지 않은 키·주소도 저장한다. 맞지 않으면 닫지 않고 그 칸을 보여 준다
        if !page.keyDraft.isEmpty, let problem = saveKey(page.keyDraft) {
            page.settingsSection = .redmine
            page.flash(problem)
            return
        }
        if !page.teamsDraft.isEmpty, let problem = saveTeams(page.teamsDraft) {
            page.settingsSection = .teams
            page.flash(problem)
            return
        }
        settings.normalizeRedmineURL()
        page.showsSettings = false
        if settings.captureEnabled { sync.capture() }
        if settings.redmineReady { sync.loadMyIssues() }
        GlobalHotKey.shared.setQuickAdd(settings.quickAddEnabled)
    }

    // MARK: 왼쪽

    private var nav: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("연동 설정").font(.system(size: 12, weight: .medium)).foregroundStyle(WL.muted)
                .padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(WorkLogPage.SettingsSection.allCases, id: \.self) { section in
                Button { page.settingsSection = section } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.icon).font(.system(size: 12)).foregroundStyle(WL.muted).frame(width: 18)
                        Text(section.rawValue).font(.system(size: 13, weight: page.settingsSection == section ? .semibold : .regular))
                        Spacer()
                        Circle().fill(dot(section)).frame(width: 6, height: 6)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 6).fill(page.settingsSection == section ? WL.hover.opacity(1.8) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 24)
        .frame(width: 200)
        .background(WL.sidebar)
    }

    /// 칸마다 켜짐(초록)·문제(주황)·꺼짐(빈) 점.
    private func dot(_ section: WorkLogPage.SettingsSection) -> Color {
        switch section {
        case .gitlab: return sync.captureError != nil ? WL.waiting : settings.captureEnabled ? WL.done : .clear
        case .redmine: return sync.issuesError != nil ? WL.waiting : settings.redmineReady ? WL.done : .clear
        case .teams: return settings.hasTeamsWebhook ? WL.done : .clear
        case .recurring: return store.log.recurring.isEmpty ? .clear : WL.done
        case .shortcuts: return GlobalHotKey.shared.quickClashes || GlobalHotKey.shared.quickFailed ? WL.waiting : .clear
        }
    }

    private var sectionNote: String {
        switch page.settingsSection {
        case .gitlab: return "머지한 내 MR은 머지한 날에 완료로, 아직 main·dev·release에 들어가지 않은 내 커밋은 브랜치마다 진행중으로 들어옵니다. MR 설명이 레드마인 댓글이 됩니다."
        case .redmine: return "앱이 레드마인 API로 진척률과 댓글을 직접 보내 Claude 토큰을 쓰지 않습니다. 보내기는 레드마인 탭에서 눌러야 나가고, 일감 상태는 바꾸지 않습니다."
        case .teams: return "일일·주간·월간 보고를 팀즈 채팅에 카드로 보냅니다. 처음에는 나에게 오는 채팅으로 이어 시험해 보세요. 보내기 전에 한 번 더 묻습니다."
        case .recurring: return "정한 요일이 되면 그날 일지에 저절로 들어갑니다. 그날 지우면 다시 넣지 않습니다."
        case .shortcuts: return "어디서든 한 줄 적기와 퇴근 무렵 알림."
        }
    }

    // MARK: GitLab

    private var gitlab: some View {
        VStack(spacing: 0) {
            SettingRow("자동으로 가져오기", "10분마다, 그리고 업무 일지를 열 때 가져옵니다.") {
                Toggle("", isOn: $settings.captureEnabled).toggleStyle(.switch).labelsHidden()
            }
            SettingRow("GitLab 주소", "glab에 로그인한 회사 GitLab입니다.") {
                HStack(spacing: 6) {
                    TextField("git.example.com", text: $settings.gitlabHost).textFieldStyle(.roundedBorder).frame(width: 190)
                    Button("glab에서 찾기") {
                        if let host = WorkLogSettings.detectGitLabHost() { settings.gitlabHost = host; page.flash("\(host)를 찾았습니다") }
                        else { page.flash("glab 설정에서 회사 GitLab을 찾지 못했습니다") }
                    }
                    .buttonStyle(NotionButtonStyle())
                }
            }
            SettingRow("저장소 폴더", "이 폴더와 그 아래 폴더의 저장소에서 내 커밋을 찾습니다.") {
                HStack(spacing: 6) {
                    TextField("~/GitHub", text: $settings.repoFolder).textFieldStyle(.roundedBorder).frame(width: 190)
                    Button("고르기") { chooseFolder() }.buttonStyle(NotionButtonStyle())
                }
            }
            SettingRow("상태", captureStatus, detailTint: sync.captureError == nil ? nil : WL.waiting) {
                Button(sync.capturing ? "가져오는 중…" : "지금 가져오기") { sync.capture { page.flash("\(sync.lastAdded)줄을 가져왔습니다") } }
                    .buttonStyle(NotionButtonStyle())
                    .disabled(sync.capturing || settings.gitlabHost.isEmpty)
            }
        }
    }

    private var captureStatus: String {
        if let error = sync.captureError { return error }
        guard let last = sync.lastCapture else { return settings.captureEnabled ? "아직 가져오지 않았습니다." : "꺼져 있습니다." }
        return "\(WorkLogFormat.when(last))에 가져왔습니다 · \(sync.lastAdded)줄 넣거나 고침"
    }

    // MARK: 레드마인

    private var redmine: some View {
        VStack(spacing: 0) {
            SettingRow("빠르게 잇기", "Claude Code의 redmine MCP에 넣어 둔 주소와 키를 옮겨 옵니다. 키는 키체인에 두고 그 레드마인에만 보냅니다.") {
                Button("Claude 설정에서 가져오기") {
                    if settings.importFromClaude() {
                        page.flash("redmine MCP의 주소와 키를 가져왔습니다")
                        sync.loadMyIssues()
                    } else {
                        page.flash("redmine MCP 설정을 찾지 못했거나 키체인에 저장하지 못했습니다")
                    }
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
            }
            SettingRow("주소", RedmineAPI.baseURL(settings.redmineURL) == nil && !settings.redmineURL.isEmpty
                       ? "https 주소만 받습니다 (API 키가 평문으로 나가지 않게)." : "예: https://redmine.example.com",
                       detailTint: RedmineAPI.baseURL(settings.redmineURL) == nil && !settings.redmineURL.isEmpty ? WL.waiting : nil) {
                TextField("https://redmine.example.com", text: $settings.redmineURL, onCommit: { settings.normalizeRedmineURL() })
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingRow("API 키", "레드마인 > 내 계정 > API 접근 키. 복사해 두고 붙여넣기를 누르면 바로 저장하고 연결을 확인합니다.") {
                SecretInput(saved: settings.hasRedmineKey, hint: settings.redmineKeyHint ?? "키체인에 저장됨",
                            placeholder: "API 접근 키", draft: $page.keyDraft,
                            save: saveKey, clear: { settings.setRedmineKey(""); page.flash("API 키를 지웠습니다") })
            }
            SettingRow("연결", redmineStatus, detailTint: sync.issuesError == nil ? nil : WL.waiting) {
                Button("연결 확인") { sync.loadMyIssues() }
                    .buttonStyle(NotionButtonStyle())
                    .disabled(!settings.redmineReady)
            }
            SettingRow("작업 시간도 남기기", "보낼 때 레드마인 소요 시간을 날짜별로 함께 남깁니다. 정하지 않은 일감은 그 저장소 폴더에서 Claude Code를 쓴 시간으로 어림하고, 보내기 전에 고칠 수 있습니다.") {
                Toggle("", isOn: $settings.logTime).toggleStyle(.switch).labelsHidden()
                    .onChange(of: settings.logTime) { if $0 { sync.loadActivities() } }
            }
            if settings.logTime {
                SettingRow("작업 분류", "소요 시간에 붙일 분류입니다.") {
                    Picker("", selection: Binding(
                        get: { settings.activityID ?? 0 },
                        set: { settings.activityID = $0 == 0 ? nil : $0 }
                    )) {
                        if sync.activities.isEmpty { Text(settings.redmineReady ? "불러오는 중" : "레드마인을 먼저 이으세요").tag(0) }
                        ForEach(sync.activities) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
        }
    }

    private var redmineStatus: String {
        if let error = sync.issuesError { return error }
        guard settings.redmineReady else { return "아직 잇지 않았습니다." }
        return sync.myIssues.isEmpty ? "이어졌습니다." : "이어졌습니다 · 나에게 배정된 열린 일감 \(sync.myIssues.count)개"
    }

    private func saveKey(_ text: String) -> String? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 20, key.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return "API 키는 영문·숫자로 된 긴 글입니다. 내 계정 > API 접근 키의 ‘보기’를 눌러 복사하세요."
        }
        guard settings.setRedmineKey(key) else { return "키체인에 저장하지 못했습니다." }
        settings.normalizeRedmineURL()
        sync.loadMyIssues()
        page.flash("API 키를 저장했습니다")
        return nil
    }

    // MARK: 팀즈

    private var teams: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow("웹훅 주소", "아래 순서로 만든 주소를 복사해 두고 붙여넣기를 누르세요. 주소는 키체인에 둡니다.") {
                SecretInput(saved: settings.hasTeamsWebhook, hint: settings.teamsHint ?? "키체인에 저장됨", placeholder: "https://…powerplatform.com/…",
                            draft: $page.teamsDraft, save: saveTeams,
                            clear: { settings.setTeamsWebhook(""); page.flash("팀즈 웹훅을 지웠습니다") })
            }
            SettingRow("시험 보내기", teamsTestNote, detailTint: page.teamsTestFailed ? WL.waiting : nil) {
                Button(sync.postingTeams ? "보내는 중…" : "시험 글 보내기") { sendTest() }
                    .buttonStyle(NotionButtonStyle())
                    .disabled(!settings.hasTeamsWebhook || sync.postingTeams)
            }
            Callout {
                VStack(alignment: .leading, spacing: 8) {
                    Text("채팅 웹훅 주소 만들기").font(.system(size: 13, weight: .semibold))
                    // 채팅용 웹훅 템플릿은 워크플로 앱 목록에는 없고, 보낼 채팅의 ⋯ 메뉴에서 열어야 보인다
                    ForEach(Array(["팀즈 채팅 목록에서 보낼 채팅(나와의 채팅은 내 이름 옆 ‘(나)’)에 마우스를 올리고 ⋯를 누릅니다.",
                                   "‘워크플로’를 누르고 ‘웹후크 경고를 채팅으로 보내기’ 템플릿을 고릅니다. 검색은 ‘웹후크’로 합니다.",
                                   "받을 채팅이 그 채팅으로 채워져 있는지 보고 저장합니다.",
                                   "워크플로 앱에서 만든 흐름을 열고 편집 > ‘팀즈 웹후크 요청을 받은 경우’에서 ‘흐름을 트리거할 수 있는 사람’(Who can trigger the flow)을 ‘누구나’(Anyone)로 바꿔 저장합니다. 기본값(회사 사용자만)이면 앱이 보낼 수 없습니다.",
                                   "웹훅 주소를 복사해 위의 붙여넣기를 누르고 ‘시험 글 보내기’로 확인합니다."].enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(WL.muted).monospacedDigit()
                            Text(step).font(.system(size: 12.5)).foregroundStyle(WL.text)
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    private var teamsTestNote: String {
        if let result = page.teamsTestResult { return result }
        return settings.hasTeamsWebhook ? "이어 둔 채팅에 짧은 시험 카드를 보냅니다." : "웹훅 주소를 먼저 넣으세요."
    }

    private func sendTest() {
        sync.postTeams("[시험] RunTime 업무 일지\n1. 연결 확인\n- 이 카드가 보이면 팀즈 채팅과 이어졌습니다 (완료)",
                       title: "RunTime 연결 시험 · \(WorkLogFormat.when(Date()))") { error in
            page.teamsTestFailed = error != nil
            page.teamsTestResult = error.map { "보내지 못했습니다: \($0)" } ?? "보냈습니다. 팀즈 채팅에 카드가 왔는지 보세요."
        }
    }

    private func saveTeams(_ text: String) -> String? {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TeamsWebhook.isValid(url) else { return "Workflows 웹훅 주소(https, logic.azure.com 등)가 아닙니다." }
        guard settings.setTeamsWebhook(url) else { return "키체인에 저장하지 못했습니다." }
        page.flash("팀즈 웹훅을 저장했습니다")
        return nil
    }

    // MARK: 고정 업무

    private var recurring: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.log.recurring) { item in
                HStack(spacing: 10) {
                    ProjectSwatch(name: item.project, size: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 13.5))
                        Text("\(item.project) · \(item.status.label) · " + weekdayText(item.weekdays))
                            .font(.system(size: 12)).foregroundStyle(WL.muted)
                    }
                    Spacer()
                    Button { store.setRecurring(store.log.recurring.filter { $0.id != item.id }) } label: { Image(systemName: "trash") }
                        .buttonStyle(GhostIconButtonStyle())
                        .help("빼기")
                }
                .padding(.vertical, 10)
                Rectangle().fill(WL.border).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("새 고정 업무").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Menu {
                        ForEach(store.log.allProjects, id: \.self) { name in Button(name) { page.recurringProject = name } }
                    } label: {
                        HStack(spacing: 6) {
                            if !page.recurringProject.isEmpty { ProjectSwatch(name: page.recurringProject) }
                            Text(page.recurringProject.isEmpty ? "프로젝트" : page.recurringProject)
                        }
                    }
                    .frame(width: 150)
                    TextField("주간 회의 참석", text: $page.recurringTitle, onCommit: addRecurring).textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 4) {
                    ForEach(WorkLogFormat.weekdays, id: \.number) { day in
                        Button(day.name) {
                            if page.recurringDays.contains(day.number) { page.recurringDays.remove(day.number) }
                            else { page.recurringDays.insert(day.number) }
                        }
                        .buttonStyle(ChipButtonStyle(selected: page.recurringDays.contains(day.number)))
                    }
                    Button("평일") { page.recurringDays = [2, 3, 4, 5, 6] }.buttonStyle(TextLinkButtonStyle(tint: WL.muted))
                        .padding(.leading, 6)
                    Spacer()
                    Button("넣기") { addRecurring() }
                        .buttonStyle(NotionButtonStyle(kind: .primary))
                        .disabled(page.recurringProject.isEmpty || page.recurringTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                  || page.recurringDays.isEmpty)
                }
                Text("상태를 쓰지 않으면 상시로 넣습니다. 끝에 (완료)·(60%)·#일감번호를 붙일 수 있습니다.")
                    .font(.system(size: 12)).foregroundStyle(WL.faint)
            }
            .padding(.top, 18)
        }
    }

    private func addRecurring() {
        let title = page.recurringTitle.trimmingCharacters(in: .whitespaces)
        guard !page.recurringProject.isEmpty, !title.isEmpty, !page.recurringDays.isEmpty else { return }
        let parsed = WorkLogFormat.splitStatus(title)
        let split = WorkReport.splitIssue(parsed.title)
        let status: WorkStatus = title.hasSuffix(")") ? parsed.status : .ongoing
        store.setRecurring(store.log.recurring + [RecurringWork(project: page.recurringProject, title: split.title,
                                                                status: status, issue: split.issue, weekdays: page.recurringDays)])
        page.recurringTitle = ""
        page.flash("고정 업무를 넣었습니다")
    }

    private func weekdayText(_ days: Set<Int>) -> String {
        if days == [2, 3, 4, 5, 6] { return "평일" }
        if days.count == 7 { return "매일" }
        return WorkLogFormat.weekdays.filter { days.contains($0.number) }.map(\.name).joined()
    }

    // MARK: 단축키·알림

    private var shortcuts: some View {
        VStack(spacing: 0) {
            SettingRow("어디서든 한 줄 적기",
                       GlobalHotKey.shared.quickClashes ? "사용량 단축키와 같은 조합이라 쓸 수 없습니다."
                       : GlobalHotKey.shared.quickFailed ? "다른 앱이 이미 쓰는 조합입니다."
                       : "\(GlobalHotKey.quickCombo.label)을 누르면 작은 창이 떠서 오늘 일지에 바로 적습니다.",
                       detailTint: GlobalHotKey.shared.quickClashes || GlobalHotKey.shared.quickFailed ? WL.waiting : nil) {
                Toggle("", isOn: $settings.quickAddEnabled).toggleStyle(.switch).labelsHidden()
                    .onChange(of: settings.quickAddEnabled) { GlobalHotKey.shared.setQuickAdd($0) }
            }
            SettingRow("저녁 알림", "평일 정한 시각에 한 번 더 가져온 뒤 오늘 기록과 보낼 일감을 알립니다.") {
                HStack(spacing: 10) {
                    DatePicker("", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: settings.reminderMinutes / 60,
                                                     minute: settings.reminderMinutes % 60, second: 0, of: Date()) ?? Date() },
                        set: { date in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                            settings.reminderMinutes = (parts.hour ?? 18) * 60 + (parts.minute ?? 0)
                        }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .disabled(!settings.reminderEnabled)
                    Toggle("", isOn: $settings.reminderEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingRow("창 단축키", "⌘[ 이전 · ⌘] 다음 · ⌘T 오늘 · ⌘R 가져오기 · ⇧⌘C 보고서 복사 · ⌘, 설정") { EmptyView() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: (settings.repoFolder as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { settings.repoFolder = url.path }
    }
}

/// 설정 한 줄: 왼쪽에 이름과 설명, 오른쪽에 조작. 줄 사이는 가는 선.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    var detailTint: Color?
    let control: Control

    init(_ title: String, _ detail: String, detailTint: Color? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.detailTint = detailTint
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(WL.text)
                    Text(detail).font(.system(size: 12)).foregroundStyle(detailTint ?? WL.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                // 조작은 줄이지 않고 설명이 남은 너비에서 줄을 바꾼다. 통째로 fixedSize를 걸면
                // 글 칸이 들어 있는 글 길이만큼 늘어나 긴 웹훅 주소가 창 밖으로 나간다
                control.layoutPriority(1)
            }
            .padding(.vertical, 14)
            Rectangle().fill(WL.border).frame(height: 1)
        }
    }
}

/// 키·웹훅 칸. 저장돼 있으면 가린 값과 바꾸기·지우기, 아니면 칸과 "붙여넣기"(복사한 값을 확인하고 바로 저장).
struct SecretInput: View {
    let saved: Bool
    let hint: String?
    let placeholder: String
    @Binding var draft: String
    /// 저장하고 문제가 있으면 그 이유를 돌려준다.
    let save: (String) -> String?
    let clear: () -> Void
    @StateObject private var state = SecretState()

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if saved && !state.editing {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(WL.done).font(.system(size: 12))
                    Text(hint ?? "저장됨").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(WL.muted).lineLimit(1)
                    Button("바꾸기") { state.editing = true; state.problem = nil }.buttonStyle(NotionButtonStyle())
                    Button("지우기") { clear() }.buttonStyle(NotionButtonStyle())
                }
            } else {
                HStack(spacing: 6) {
                    SecureField(placeholder, text: $draft, onCommit: commit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                    Button("붙여넣기") {
                        draft = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if draft.isEmpty { state.problem = "클립보드가 비어 있습니다." } else { commit() }
                    }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .help("복사해 둔 값을 넣고 바로 저장합니다")
                    if saved {
                        Button("취소") { state.editing = false; draft = ""; state.problem = nil }.buttonStyle(NotionButtonStyle())
                    }
                }
            }
            if let problem = state.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(WL.waiting)
                    .frame(maxWidth: 320, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commit() {
        guard !draft.isEmpty else { return }
        if let problem = save(draft) {
            state.problem = problem
        } else {
            state.problem = nil
            state.editing = false
            draft = ""
        }
    }
}

final class SecretState: ObservableObject {
    @Published var editing = false
    @Published var problem: String?
}
