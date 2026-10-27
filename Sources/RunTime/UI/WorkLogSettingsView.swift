import AppKit
import SwiftUI
import WorkLogCore

/// 업무 일지 연동 설정. 앱 창 설정 화면의 "업무 일지" 묶음에서 고른 칸을 "이름·설명 | 조작" 줄로 둔다.
/// 키·주소는 붙여넣기 한 번에 확인하고 저장까지 한다. 바뀐 값은 바로 저장되고, 떠날 때 연동을 다시 받는다.
struct WorkLogSettingsView: View {
    @ObservedObject var settings: WorkLogSettings
    @ObservedObject var sync: WorkLogSync
    @ObservedObject var page: WorkLogPage
    @ObservedObject var store: WorkLogStore
    @ObservedObject private var linker = TeamsLinker.shared
    @ObservedObject private var web = TeamsWeb.shared

    var body: some View {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(WL.text)
        // 저장·가져오기 결과 알림. 업무 일지 화면 밖이라 여기에도 띄운다
        .overlay(alignment: .bottom) {
            if let message = page.toast {
                Toast(message: message).padding(.bottom, 18).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear {
            // 화면을 열자마자 첫 글 칸(GitLab 주소)이 글자를 통째로 고른 채 잡히지 않게 초점을 푼다
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            page.keyDraft = ""
            if settings.redmineReady { sync.loadStatuses() }
        }
        .onDisappear { finish() }
    }

    /// 설정을 떠날 때. 칸에 써 두고 저장을 누르지 않은 키·주소도 맞으면 저장하고, 바뀐 연동으로 다시 받는다.
    private func finish() {
        // 맞지 않는 값은 저장하지 않고 알린다 (예전 완료 단추처럼 그 칸으로 돌려보낼 수 없어 알림만)
        if !page.keyDraft.isEmpty {
            if let problem = saveKey(page.keyDraft) { page.flash("레드마인 API 키를 저장하지 못했습니다: \(problem)") }
            else { page.keyDraft = "" }
        }
        settings.normalizeRedmineURL()
        if settings.captureEnabled { sync.capture() }
        if settings.redmineReady { sync.loadMyIssues() }
        GlobalHotKey.shared.setQuickAdd(settings.quickAddEnabled)
    }

    /// 칸마다 켜짐(초록)·문제(주황)·꺼짐(빈) 점. 설정 화면 왼쪽 목록에 붙는다.
    static func dot(_ section: WorkLogPage.SettingsSection, settings: WorkLogSettings, sync: WorkLogSync,
                    store: WorkLogStore) -> Color {
        switch section {
        case .gitlab: return sync.captureError != nil ? WL.waiting : settings.captureEnabled ? WL.done : .clear
        case .redmine: return sync.issuesError != nil ? WL.waiting : settings.redmineReady ? WL.done : .clear
        case .teams: return settings.hasTeams(.chat) ? WL.done : .clear
        case .recurring: return store.log.recurring.isEmpty ? .clear : WL.done
        case .shortcuts: return GlobalHotKey.shared.quickClashes || GlobalHotKey.shared.quickFailed ? WL.waiting : .clear
        }
    }

    private var sectionNote: String {
        switch page.settingsSection {
        case .gitlab: return "머지한 MR은 머지한 날 완료로, main·dev·release에 들어가지 않은 커밋은 브랜치마다 진행중으로 들어옵니다. MR 설명은 일감별 레드마인 댓글로 나눠 씁니다."
        case .redmine: return "진척률과 댓글을 레드마인 API로 직접 보내 Claude 토큰을 쓰지 않습니다. 레드마인 탭에서 보내기를 눌러야 나갑니다."
        case .teams: return "보고서를 팀즈 채팅에 올립니다. 나에게는 설정 없이 나와의 채팅으로 가고, 보고 채팅은 채팅 링크 하나만 넣으면 됩니다."
        case .recurring: return "정한 요일이 되면 그날 일지에 자동으로 들어갑니다. 그날 지우면 다시 넣지 않습니다."
        case .shortcuts: return "어디서든 한 줄 적기와 퇴근 무렵 알림."
        }
    }

    // MARK: GitLab

    private var gitlab: some View {
        VStack(spacing: 0) {
            SettingRow("자동으로 가져오기", "10분마다, 그리고 업무 일지를 열 때 가져옵니다.") {
                Toggle("", isOn: $settings.captureEnabled).toggleStyle(.switch).labelsHidden()
            }
            SettingRow("GitLab 주소", WorkLogSync.glabInstalled ? "glab에 로그인한 회사 GitLab입니다." : "glab이 없습니다. 터미널에서 brew install glab 뒤 glab auth login",
                       detailTint: WorkLogSync.glabInstalled ? nil : WL.waiting) {
                HStack(spacing: 6) {
                    TextField("git.example.com", text: $settings.gitlabHost).textFieldStyle(.roundedBorder).frame(width: 240)
                    Button("glab에서 찾기") {
                        if let host = WorkLogSettings.detectGitLabHost() { settings.gitlabHost = host; page.flash("\(host)를 찾았습니다") }
                        else { page.flash("glab 설정에서 회사 GitLab을 찾지 못했습니다") }
                    }
                    .buttonStyle(NotionButtonStyle())
                }
            }
            SettingRow("저장소 폴더", repoFolderDetail, detailTint: repoFolderExists && repoCount > 0 ? nil : WL.waiting) {
                HStack(spacing: 6) {
                    TextField("~/GitHub", text: $settings.repoFolder).textFieldStyle(.roundedBorder).frame(width: 240)
                        .help(settings.repoFolder)
                    Button("고르기") { chooseFolder() }.buttonStyle(NotionButtonStyle())
                }
            }
            SettingRow("상태", captureStatus, detailTint: sync.captureError == nil ? nil : WL.waiting) {
                HStack(spacing: 6) {
                    if sync.captureError?.contains("user.email") == true {
                        Button("회사 이메일로 채우기") { sync.fillMissingEmails { page.flash($0) } }
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                            .tip("GitLab 계정의 커밋 이메일을 user.email이 없는 저장소에 넣고 다시 가져옵니다")
                    }
                    if let command = fixCommand {
                        Button("명령 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            page.flash("터미널에 붙여 넣어 실행하세요")
                        }
                        .buttonStyle(NotionButtonStyle())
                        .help(command)
                    }
                    Button(sync.capturing ? "가져오는 중…" : "지금 가져오기") {
                        sync.capture {
                            if sync.captureError != nil { page.flash("가져오지 못했습니다. 상태를 확인하세요") }
                            else { page.flash(sync.lastAdded == 0 ? "새로 들어온 줄이 없습니다" : "\(sync.lastAdded)줄을 가져왔습니다") }
                        }
                    }
                    .buttonStyle(NotionButtonStyle())
                    .disabled(sync.capturing || settings.gitlabHostName.isEmpty)
                }
            }
        }
    }

    /// 폴더 바로 아래와 그 아래의 git 저장소 수. 폴더 목록만 읽어 빠르다.
    private var repoCount: Int { WorkLogSync.repositories(in: (settings.repoFolder as NSString).expandingTildeInPath).count }

    private var repoFolderDetail: String {
        guard repoFolderExists else { return "폴더가 없습니다. 고르기로 저장소를 둔 폴더를 고르세요." }
        let count = repoCount
        return count == 0 ? "이 폴더와 그 아래에 git 저장소가 없습니다. 저장소를 둔 폴더를 고르세요."
                          : "git 저장소 \(count)개에서 내 커밋을 찾습니다 (폴더 바로 아래와 그 아래까지)."
    }

    private var repoFolderExists: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: (settings.repoFolder as NSString).expandingTildeInPath, isDirectory: &directory)
            && directory.boolValue
    }

    /// 오류 문구가 알려 준 터미널 명령 (`glab auth login --hostname …`, `brew install glab`).
    private var fixCommand: String? {
        guard let error = sync.captureError else { return nil }
        if let range = error.range(of: "glab auth login") { return String(error[range.lowerBound...]) }
        if error.contains("brew install glab") { return "brew install glab && glab auth login --hostname \(settings.gitlabHostName)" }
        return nil
    }

    private var captureStatus: String {
        if let error = sync.captureError { return error }
        guard let last = sync.lastCapture else { return settings.captureEnabled ? "아직 가져오지 않았습니다." : "꺼져 있습니다." }
        return "\(WorkLogFormat.when(last))에 가져왔습니다 · \(sync.lastAdded)줄 넣거나 고침"
    }

    // MARK: 레드마인

    private var redmine: some View {
        VStack(spacing: 0) {
            SettingRow("Claude 설정 가져오기", "Claude Code의 redmine MCP에 넣어 둔 주소와 키를 옮겨 옵니다. 키는 키체인에 두고 그 레드마인에만 보냅니다.") {
                Button("Claude 설정에서 가져오기") {
                    if settings.importFromClaude() {
                        page.flash("redmine MCP의 주소와 키를 가져왔습니다")
                        sync.loadMyIssues()
                        sync.loadStatuses()
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
                HStack(alignment: .top, spacing: 6) {
                    // 키가 있는 내 계정 화면으로 바로 보낸다
                    if !settings.hasRedmineKey, let base = RedmineAPI.baseURL(settings.redmineURL) {
                        Button("키 페이지 열기") { NSWorkspace.shared.open(base.appendingPathComponent("my/account")) }
                            .buttonStyle(NotionButtonStyle())
                            .tip("레드마인 내 계정을 엽니다. 오른쪽 API 접근 키 > 보기에서 복사해 오세요")
                    }

                    SecretInput(saved: settings.hasRedmineKey, hint: settings.redmineKeyHint ?? "키체인에 저장됨",
                                placeholder: "API 접근 키", draft: $page.keyDraft,
                                save: saveKey, clear: { settings.setRedmineKey(""); page.flash("API 키를 지웠습니다") })
                }
            }
            SettingRow("연결", redmineStatus, detailTint: sync.issuesError == nil ? nil : WL.waiting) {
                Button("연결 확인") { settings.retryKeychain(); sync.loadMyIssues(); sync.loadStatuses() }
                    .buttonStyle(NotionButtonStyle())
                    .disabled(!settings.redmineReady)
            }
            // 연결하기 전에는 고를 것이 없어 숨긴다 (처음 화면은 주소·키·연결만)
            if settings.redmineReady {
                SettingRow("댓글을 HTML로 보내기", UserDefaults.standard.bool(forKey: "workLog.redmineHTMLAuto")
                           ? "이 레드마인의 기존 댓글을 보고 자동으로 정했습니다. 직접 바꾸면 그대로 둡니다."
                           : "웹 편집기를 쓰는 레드마인은 HTML로 보내야 줄바꿈이 살아납니다.") {
                    // 직접 바꾸면 자동 판별이 다시 덮지 않게 한다
                    Toggle("", isOn: Binding(get: { settings.redmineHTML }, set: {
                        UserDefaults.standard.set(false, forKey: "workLog.redmineHTMLAuto")
                        settings.redmineHTML = $0
                    })).toggleStyle(.switch).labelsHidden()
                }
                SettingRow("상태·날짜도 맞추기", "할일 일감은 일지 상태에 맞춰 진행·완료로 옮기고, 비어 있는 시작일·완료 기한은 일지 날짜로 채웁니다. 테스트·반려 같은 다른 상태는 그대로 둡니다.") {
                    Toggle("", isOn: $settings.syncIssueFields).toggleStyle(.switch).labelsHidden()
                        .onChange(of: settings.syncIssueFields) { if $0 { sync.loadStatuses() } }
                }
                if settings.syncIssueFields {
                    SettingRow("진행 · 완료 상태", sync.statuses.isEmpty ? "레드마인을 연결하면 상태 목록을 받습니다." : "일지가 진행·완료일 때 옮길 상태입니다.") {
                        HStack(spacing: 6) {
                            statusPicker($settings.progressStatusID)
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(WL.faint)
                            statusPicker($settings.doneStatusID)
                        }
                    }
                    if !sync.blockedTransitions.isEmpty {
                        SettingRow("막힌 상태 전환", blockedText + " · 레드마인 워크플로가 막아 자동으로 보내지 않습니다. 워크플로를 고쳤으면 지우세요.",
                                   detailTint: WL.waiting) {
                            Button("기억 지우기") { sync.clearBlockedTransitions(); page.flash("막힌 상태 전환 기억을 지웠습니다") }
                                .buttonStyle(NotionButtonStyle())
                        }
                    }
                SettingRow("진행중 진척률", "일지 줄이 몇 %인지 정하지 않은 진행중일 때 보낼 진척률입니다. 그대로 두면 진척률은 건드리지 않고 댓글만 보냅니다. 카드마다 진척률 > 고치기로 따로 고를 수 있습니다.") {
                    Picker("", selection: Binding(get: { settings.inProgressRatio ?? -1 },
                                                  set: { settings.inProgressRatio = $0 < 0 ? nil : $0 })) {
                        Text("그대로").tag(-1)
                        ForEach(Array(stride(from: 10, through: 90, by: 10)), id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                SettingRow("MR 화면 붙이기", "MR 본문이나 AI 검증 댓글에 수정 전·후 그림이 있으면 레드마인에 첨부하고 댓글 끝에 붙입니다. 카드마다 끌 수도 있습니다.") {
                    Toggle("", isOn: $settings.attachScreens).toggleStyle(.switch).labelsHidden()
                }
            }
            }
        }
    }

    /// `할일 → 해결` 꼴.
    private var blockedText: String {
        sync.blockedTransitions.sorted().compactMap { key -> String? in
            let ids = key.split(separator: ">").compactMap { Int($0) }
            guard ids.count == 2 else { return nil }
            let name = { (id: Int) in sync.statuses.first { $0.id == id }?.name ?? "#\(id)" }
            return "\(name(ids[0])) → \(name(ids[1]))"
        }.joined(separator: ", ")
    }

    private func statusPicker(_ selection: Binding<Int?>) -> some View {
        Picker("", selection: Binding(get: { selection.wrappedValue ?? 0 }, set: { selection.wrappedValue = $0 == 0 ? nil : $0 })) {
            Text("바꾸지 않음").tag(0)
            ForEach(sync.statuses) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .frame(width: 110)
        .disabled(sync.statuses.isEmpty)
    }

    private var redmineStatus: String {
        if let error = sync.issuesError { return error }
        guard settings.redmineReady else { return "연결하지 않았습니다." }
        return sync.myIssues.isEmpty ? "연결됐습니다." : "연결됐습니다 · 나에게 배정된 열린 일감 \(sync.myIssues.count)개"
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
            SettingRow("팀즈 웹 연결", webDetail, detailTint: webFailed ? WL.waiting : nil) {
                HStack(spacing: 6) {
                    if web.everReady || web.lostLogin {
                        Button("로그아웃") { web.signOut(); page.flash("팀즈 웹에서 로그아웃했습니다") }
                            .buttonStyle(NotionButtonStyle())
                    }
                    if !web.everReady {
                        Button(web.loggingIn ? "로그인 창 보기" : web.lostLogin ? "다시 로그인" : "로그인") { web.showLogin() }
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                            .tip("회사 계정으로 한 번 로그인해 두면 팀즈 창을 띄우지 않고 보냅니다")
                    }
                }
            }
            ForEach(TeamsTarget.allCases, id: \.self) { target in
                SettingRow(target.name, teamsDetail(target),
                           detailTint: settings.teamsNeedsAnyone.contains(target) ? WL.waiting : nil) {
                    HStack(spacing: 6) {
                        Button("링크 붙여넣기") { pasteTeams(target) }
                            .buttonStyle(NotionButtonStyle(kind: settings.hasTeams(target) ? .secondary : .primary))
                            .tip("팀즈 채팅 ⋯ > ‘링크 복사’ 한 것을 넣습니다. 웹훅 주소도 됩니다")
                        if settings.teamsLinks[target] != nil || settings.hasWebhook(target) {
                            Button("지우기") { settings.clearTeams(target); page.flash("\(target.name) 설정을 지웠습니다") }
                                .buttonStyle(NotionButtonStyle())
                        }
                        Button("시험") { sendTest(target) }
                            .buttonStyle(NotionButtonStyle())
                            .disabled(!settings.hasTeams(target) || sync.postingTeams)
                            .tip("\(target.name) 짧은 시험 글을 보냅니다")
                    }
                }
            }
            // 팀즈 웹에 로그인해 두면 쓰지 않는 길이라, 그때만 보인다
            if !web.everReady {
                SettingRow("입력 칸에 붙여 넣기", linker.accessibility
                           ? "채팅을 연 뒤 보고서를 입력 칸에 붙여 넣습니다. 끄면 복사만 하고 ⌘V는 직접 누릅니다."
                           : "손쉬운 사용 권한을 주면 채팅을 연 뒤 붙여 넣기까지 합니다. 지금은 복사하고 채팅만 엽니다.",
                           detailTint: settings.teamsAutoPaste && !linker.accessibility ? WL.waiting : nil) {
                    HStack(spacing: 8) {
                        if settings.teamsAutoPaste && !linker.accessibility {
                            Button("권한 주기") { TeamsOpener.requestPermission() }.buttonStyle(NotionButtonStyle(kind: .primary))
                        }
                        Toggle("", isOn: $settings.teamsAutoPaste).toggleStyle(.switch).labelsHidden()
                    }
                }
                SettingRow("붙여 넣고 바로 보내기", "Enter까지 누르고 입력 칸이 비었는지로 나갔는지 확인합니다. 끄면 붙여 넣은 글을 보고 직접 보냅니다.") {
                    Toggle("", isOn: $settings.teamsAutoSend).toggleStyle(.switch).labelsHidden()
                        .disabled(!settings.teamsAutoPaste || !linker.accessibility)
                }
                SettingRow("보낸 뒤 쓰던 앱으로 돌아가기", "팀즈가 1초쯤 앞에 나왔다가 보내고 나면 원래 창으로 돌아갑니다. 붙여 넣기만 했을 때는 팀즈에 남습니다.") {
                    Toggle("", isOn: $settings.teamsReturn).toggleStyle(.switch).labelsHidden()
                        .disabled(!settings.teamsAutoSend || !settings.teamsAutoPaste || !linker.accessibility)
                }
            }
            if let status = page.teamsTestResult ?? linker.status {
                Text(status).font(.system(size: 12)).foregroundStyle(page.teamsTestFailed || linker.failed ? WL.waiting : WL.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            Callout {
                VStack(alignment: .leading, spacing: 8) {
                    Text("처음 한 번").font(.system(size: 13, weight: .semibold))
                    steps(["‘로그인’을 눌러 뜬 창에서 회사 계정으로 팀즈에 로그인합니다. 다 뜨면 창은 저절로 닫힙니다.",
                           "보고를 올릴 채팅에 마우스를 올리고 ⋯ > ‘링크 복사’를 누릅니다. 이 화면이 열려 있으면 복사만으로 보고 채팅에 들어갑니다.",
                           "‘시험’으로 확인합니다. 그다음부터는 보고서 화면의 단추 하나로 팀즈 창 없이 올라갑니다."])
                }
            }
            .padding(.top, 16)
        }
        .onAppear { linker.start() }
        .onDisappear { linker.stop() }
    }

    private var webFailed: Bool {
        if case .failed = web.state { return true }
        return web.lostLogin
    }

    private var webDetail: String {
        if web.loggingIn { return "뜬 창에서 회사 계정으로 로그인하세요. 팀즈가 다 뜨면 창이 저절로 닫힙니다." }
        if case .failed(let message) = web.state { return message }
        if web.lostLogin { return "로그인이 풀렸습니다. 다시 로그인하세요. 그동안은 팀즈 앱을 열어 붙여 넣습니다." }
        return web.everReady ? "연결됨 · 팀즈 창을 띄우지 않고 앱 안에서 바로 보냅니다."
                             : "한 번 로그인해 두면 팀즈 창을 띄우지 않고 보냅니다. 로그인 정보는 이 Mac에만 남습니다."
    }

    private func teamsDetail(_ target: TeamsTarget) -> String {
        guard settings.hasTeams(target) else { return "팀즈 채팅 ⋯ > ‘링크 복사’ 한 뒤 붙여 넣으세요. 비워 두면 보고서는 나에게 갑니다." }
        var text = settings.teamsSummary(target)

        return text
    }

    private func steps(_ items: [String]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(WL.muted).monospacedDigit()
                Text(step).font(.system(size: 12.5)).foregroundStyle(WL.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pasteTeams(_ target: TeamsTarget) {
        page.teamsTestResult = nil
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return page.flash("클립보드가 비어 있습니다. 팀즈 채팅 ⋯ > ‘링크 복사’를 먼저 누르세요") }
        linker.preferred = target
        if let problem = linker.link(text, to: target) { page.flash(problem) } else { page.flash("\(target.name) 설정을 넣었습니다") }
    }

    private func sendTest(_ target: TeamsTarget) {
        sync.postTeams(TeamsLinker.testReport, title: TeamsLinker.testTitle, to: target) { message, failed in
            page.teamsTestFailed = failed
            page.teamsTestResult = message
        }
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
                        .tip("이 고정 업무 빼기")
                }
                .padding(.vertical, 10)
                Rectangle().fill(WL.border).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("새 고정 업무").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Menu {
                        ForEach(store.log.visibleProjects, id: \.self) { name in Button(name) { page.recurringProject = name } }
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
        if panel.runModal() == .OK, let url = panel.url { settings.repoFolder = (url.path as NSString).abbreviatingWithTildeInPath }
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
                // 조작이 넓어도 제목·설명이 한 글자 너비로 눌려 세로로 서지 않게 최소 너비를 둔다
                .frame(minWidth: 180, alignment: .leading)
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
                    // 체크와 글을 한 묶음으로 오른쪽에 붙여, 글이 짧을 때 체크만 왼쪽에 떨어져 있지 않게 한다
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(WL.done).font(.system(size: 12))
                        // 웹훅 호스트처럼 긴 값은 가운데를 줄여 설명 칸을 밀어내지 않게 한다
                        Text(hint ?? "저장됨").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(WL.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: 196, alignment: .trailing)
                    .tip(hint ?? "")
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
                    .tip("복사해 둔 값을 넣고 바로 저장합니다")
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
