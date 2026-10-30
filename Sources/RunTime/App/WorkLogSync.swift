import AppKit
import Combine
import Security
import UsageCore
import WorkLogCore

/// 업무 일지 연동 설정. 레드마인 API 키만 키체인에 둔다.
final class WorkLogSettings: ObservableObject {
    static let shared = WorkLogSettings()
    private let defaults = UserDefaults.standard

    /// 회사 GitLab 주소 (glab에 로그인한 곳).
    @Published var gitlabHost: String { didSet { defaults.set(gitlabHost, forKey: "workLog.gitlabHost") } }
    /// `https://`나 경로를 붙여 적어도 glab이 읽는 호스트 이름.
    var gitlabHostName: String { WorkCapture.hostName(gitlabHost) }
    @Published var captureEnabled: Bool { didSet { defaults.set(captureEnabled, forKey: "workLog.capture") } }
    /// 로컬 커밋을 찾을 폴더. 두 단계 아래까지 본다.
    @Published var repoFolder: String { didSet { defaults.set(repoFolder, forKey: "workLog.repoFolder") } }
    @Published var redmineURL: String { didSet { defaults.set(redmineURL, forKey: "workLog.redmineURL") } }
    @Published var reminderEnabled: Bool { didSet { defaults.set(reminderEnabled, forKey: "workLog.reminder") } }
    /// 평일 이 시각(분)에 오늘 기록과 보낼 일감을 알린다. 기본 18:00.
    @Published var reminderMinutes: Int { didSet { defaults.set(reminderMinutes, forKey: "workLog.reminderMinutes") } }
    @Published private(set) var hasRedmineKey: Bool
    @Published private(set) var hasTeamsWebhook: Bool
    @Published private(set) var hasTeamsMeWebhook: Bool
    /// 저장한 주소가 회사 계정 인증을 요구하는지 (서명 없음, 401). 키체인을 읽지 않고 보이려고 따로 둔다.
    @Published private(set) var teamsNeedsAnyone: Set<TeamsTarget>
    /// 채팅 링크(⋯ > 링크 복사). 웹훅이 없거나 막혔을 때 그 채팅을 팀즈 앱에서 열어 붙여 넣는다.
    @Published private(set) var teamsLinks: [TeamsTarget: String]
    /// 채팅을 연 뒤 입력 칸에 붙여 넣기까지 한다 (손쉬운 사용 권한이 있을 때).
    @Published var teamsAutoPaste: Bool { didSet { defaults.set(teamsAutoPaste, forKey: "workLog.teamsAutoPaste") } }
    /// 붙여 넣은 뒤 Enter까지 누른다. 확인 없이 나가므로 기본은 끔.
    @Published var teamsAutoSend: Bool { didSet { defaults.set(teamsAutoSend, forKey: "workLog.teamsAutoSend") } }
    /// 보낸 뒤 쓰던 앱으로 돌아간다 (팀즈를 띄워 둔 채로 두지 않음).
    @Published var teamsReturn: Bool { didSet { defaults.set(teamsReturn, forKey: "workLog.teamsReturn") } }
    /// 보고서 꼴: 상시 → 완료 → 진행 순서, 주간 보고 끝에 차주 계획.
    @Published var doneFirst: Bool { didSet { defaults.set(doneFirst, forKey: "workLog.doneFirst") } }
    @Published var weeklyPlan: Bool { didSet { defaults.set(weeklyPlan, forKey: "workLog.weeklyPlan") } }
    @Published var dailyHeader: Bool { didSet { defaults.set(dailyHeader, forKey: "workLogReportHeader") } }
    /// 보고서를 레드마인 일감 이름으로 쓰고 QA 건은 `QA 수정사항 N건 반영`으로 모은다.
    @Published var reportByIssue: Bool { didSet { defaults.set(reportByIssue, forKey: "workLog.reportByIssue") } }
    /// 같은 메뉴 경로 줄을 경로 한 줄 아래로 묶어 쓴다.
    @Published var reportGrouped: Bool { didSet { defaults.set(reportGrouped, forKey: "workLog.reportGrouped") } }
    /// ⌃⌥L로 어디서든 한 줄 적기.
    @Published var quickAddEnabled: Bool { didSet { defaults.set(quickAddEnabled, forKey: "workLog.quickAdd") } }
    /// 보낼 때 일감 상태·시작일·완료 기한도 일지에 맞춘다. 진행·완료로 쓸 상태는 레드마인마다 달라 고른다.
    @Published var syncIssueFields: Bool { didSet { defaults.set(syncIssueFields, forKey: "workLog.syncIssueFields") } }
    @Published var progressStatusID: Int? { didSet { defaults.set(progressStatusID ?? 0, forKey: "workLog.progressStatus") } }
    @Published var doneStatusID: Int? { didSet { defaults.set(doneStatusID ?? 0, forKey: "workLog.doneStatus") } }
    /// 댓글을 HTML(`<p>`, `<br />`)로 보낸다. 웹 편집기를 쓰는 레드마인은 평문 줄바꿈을 한 줄로 붙인다.
    @Published var redmineHTML: Bool { didSet { defaults.set(redmineHTML, forKey: "workLog.redmineHTML") } }
    /// 일지가 몇 %인지 정하지 않은 진행중일 때 보낼 진척률. nil이면 진척률을 건드리지 않는다.
    @Published var inProgressRatio: Int? { didSet { defaults.set(inProgressRatio ?? -1, forKey: "workLog.inProgressRatio") } }
    /// MR 본문·댓글의 수정 전·후 화면을 레드마인 댓글에 붙인다 (기본 켬).
    @Published var attachScreens: Bool { didSet { defaults.set(attachScreens, forKey: "workLog.attachScreens") } }

    private init() {
        gitlabHost = defaults.string(forKey: "workLog.gitlabHost") ?? Self.detectGitLabHost() ?? ""
        captureEnabled = defaults.object(forKey: "workLog.capture") as? Bool ?? false
        repoFolder = defaults.string(forKey: "workLog.repoFolder") ?? (NSHomeDirectory() + "/GitHub")
        redmineURL = defaults.string(forKey: "workLog.redmineURL") ?? ""
        reminderEnabled = defaults.object(forKey: "workLog.reminder") as? Bool ?? false
        reminderMinutes = defaults.object(forKey: "workLog.reminderMinutes") as? Int ?? 18 * 60
        // 값을 읽지 않고 있는지만 본다 (값을 읽으면 다른 서명의 빌드에서 키체인 창이 뜬다)
        hasRedmineKey = !Self.keychainOff && Keychain.exists(Self.keyAccount)
        hasTeamsWebhook = !Self.keychainOff && Keychain.exists(TeamsTarget.chat.account)
        hasTeamsMeWebhook = !Self.keychainOff && Keychain.exists(TeamsTarget.me.account)
        teamsNeedsAnyone = Set((defaults.stringArray(forKey: "workLog.teamsNeedsAnyone") ?? []).compactMap(TeamsTarget.init(rawValue:)))
        let store = defaults
        teamsLinks = Dictionary(uniqueKeysWithValues: TeamsTarget.allCases.compactMap { target in
            store.string(forKey: "workLog.teamsLink.\(target.rawValue)").map { (target, $0) }
        })
        teamsAutoPaste = defaults.object(forKey: "workLog.teamsAutoPaste") as? Bool ?? true
        teamsAutoSend = defaults.object(forKey: "workLog.teamsAutoSend") as? Bool ?? false
        teamsReturn = defaults.object(forKey: "workLog.teamsReturn") as? Bool ?? true
        teamsHint = defaults.string(forKey: "workLog.teamsHost")
        teamsMeHint = defaults.string(forKey: "workLog.teamsMeHost")
        doneFirst = defaults.object(forKey: "workLog.doneFirst") as? Bool ?? true
        weeklyPlan = defaults.object(forKey: "workLog.weeklyPlan") as? Bool ?? false
        dailyHeader = defaults.object(forKey: "workLogReportHeader") as? Bool ?? false
        reportByIssue = defaults.object(forKey: "workLog.reportByIssue") as? Bool ?? true
        reportGrouped = defaults.object(forKey: "workLog.reportGrouped") as? Bool ?? true
        quickAddEnabled = defaults.object(forKey: "workLog.quickAdd") as? Bool ?? true
        syncIssueFields = defaults.object(forKey: "workLog.syncIssueFields") as? Bool ?? true
        let ratio = defaults.object(forKey: "workLog.inProgressRatio") as? Int ?? -1
        inProgressRatio = (0...100).contains(ratio) ? ratio : nil
        attachScreens = defaults.object(forKey: "workLog.attachScreens") as? Bool ?? true
        redmineHTML = defaults.object(forKey: "workLog.redmineHTML") as? Bool ?? true
        let progress = defaults.integer(forKey: "workLog.progressStatus")
        progressStatusID = progress > 0 ? progress : nil
        let done = defaults.integer(forKey: "workLog.doneStatus")
        doneStatusID = done > 0 ? done : nil
    }

    static let keyAccount = "redmine-api-key"
    static let teamsAccount = TeamsTarget.chat.account

    /// 웹훅 주소는 아는 사람 누구나 그 채팅에 글을 올릴 수 있어 키체인에 둔다.
    func teamsWebhook(_ target: TeamsTarget) -> URL? {
        // 점검용: 다른 서명의 빌드가 키체인을 묻지 않게 환경 변수로 받는다
        if let text = ProcessInfo.processInfo.environment["RUNTIME_TEAMS_WEBHOOK"], TeamsWebhook.isValid(text) { return URL(string: text) }
        guard !Self.keychainOff else { return nil }
        return Keychain.read(target.account).flatMap(URL.init(string:))
    }

    func hasWebhook(_ target: TeamsTarget) -> Bool { target == .me ? hasTeamsMeWebhook : hasTeamsWebhook }
    func teamsHint(_ target: TeamsTarget) -> String? { target == .me ? teamsMeHint : teamsHint }

    /// 열 채팅. 나에게는 넣지 않아도 나와의 채팅이다.
    func teamsLink(_ target: TeamsTarget) -> String? { teamsLinks[target] ?? (target == .me ? TeamsLink.notes : nil) }

    /// 웹훅으로 앱 밖에서 바로 보낼 수 있는지. 회사 계정 인증 주소면 채팅을 여는 길로 간다.
    func teamsDirect(_ target: TeamsTarget) -> Bool {
        // 점검용 환경 변수 웹훅은 키체인 없이도 바로 보낸다
        if ProcessInfo.processInfo.environment["RUNTIME_TEAMS_WEBHOOK"].map(TeamsWebhook.isValid) == true { return true }
        return hasWebhook(target) && !teamsNeedsAnyone.contains(target)
    }

    /// 실제로 보낼 길이 있는지. 회사 계정 인증으로 막힌 웹훅만 있으면 없는 것으로 본다.
    func hasTeams(_ target: TeamsTarget) -> Bool { teamsLink(target) != nil || teamsDirect(target) }

    /// 보고서를 보낼 곳. 보고 채팅이 없으면 나에게 보낸다.
    var reportTarget: TeamsTarget { hasTeams(.chat) ? .chat : .me }

    /// 설정 화면에 보일 한 줄.
    func teamsSummary(_ target: TeamsTarget) -> String {
        if teamsDirect(target) { return "웹훅 · 앱에서 바로 보냄" }
        guard let link = teamsLink(target) else { return "아직 없음" }
        // 한 번 보낸 채팅은 이름을 기억해 두어 어디로 가는지 보이게 한다
        let name = defaults.string(forKey: "workLog.teamsTitle.\(target.rawValue)").flatMap(TeamsOpener.chatName)
        return "\(name ?? TeamsLink.kind(link)) · " + (TeamsWeb.shared.everReady ? "팀즈 창 없이 보냄" : "팀즈를 열어 붙여 넣음")
    }

    /// 채팅 링크나 웹훅 주소를 알아보고 저장한다. 문제가 있으면 그 이유.
    func setTeams(_ text: String, target: TeamsTarget) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if TeamsLink.isValid(trimmed) {
            // 다른 채팅이면 기억해 둔 채팅 이름도 잊는다
            if teamsLinks[target] != trimmed { defaults.removeObject(forKey: "workLog.teamsTitle.\(target.rawValue)") }
            teamsLinks[target] = trimmed
            defaults.set(trimmed, forKey: "workLog.teamsLink.\(target.rawValue)")
            return nil
        }
        guard TeamsWebhook.isValid(trimmed) else {
            return "팀즈 채팅 링크(⋯ > 링크 복사)나 Workflows 웹훅 주소가 아닙니다."
        }
        return setTeamsWebhook(trimmed, target: target) ? nil : "키체인에 저장하지 못했습니다."
    }

    /// 링크와 웹훅을 모두 지운다. 나에게는 나와의 채팅으로 돌아간다.
    func clearTeams(_ target: TeamsTarget) {
        teamsLinks[target] = nil
        defaults.removeObject(forKey: "workLog.teamsLink.\(target.rawValue)")
        defaults.removeObject(forKey: "workLog.teamsTitle.\(target.rawValue)")
        if hasWebhook(target) { setTeamsWebhook("", target: target) }
    }

    @discardableResult
    func setTeamsWebhook(_ text: String, target: TeamsTarget = .chat) -> Bool {
        guard !Self.keychainOff else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(target.account)
        } else {
            guard TeamsWebhook.isValid(trimmed), Keychain.write(trimmed, account: target.account) else { return false }
        }
        let exists = Keychain.exists(target.account)
        let host = trimmed.isEmpty ? nil : URL(string: trimmed)?.host
        switch target {
        case .chat:
            hasTeamsWebhook = exists
            teamsHint = host
            defaults.set(host, forKey: "workLog.teamsHost")
        case .me:
            hasTeamsMeWebhook = exists
            teamsMeHint = host
            defaults.set(host, forKey: "workLog.teamsMeHost")
        }
        // 워크플로 ID는 비밀이 아니라 기본값에 두고, 새로 복사한 주소가 어느 칸 것인지 맞출 때 쓴다
        defaults.set(trimmed.isEmpty ? nil : TeamsWebhook.workflowID(trimmed), forKey: "workLog.teamsWorkflow.\(target.rawValue)")
        markTeams(target, needsAnyone: !trimmed.isEmpty && TeamsWebhook.needsAnyone(trimmed))
        return true
    }

    func noteSavedTeams(_ text: String, target: TeamsTarget) {
        defaults.set(TeamsWebhook.workflowID(text), forKey: "workLog.teamsWorkflow.\(target.rawValue)")
        markTeams(target, needsAnyone: TeamsWebhook.needsAnyone(text))
    }

    func markTeams(_ target: TeamsTarget, needsAnyone: Bool) {
        if needsAnyone { teamsNeedsAnyone.insert(target) } else { teamsNeedsAnyone.remove(target) }
        defaults.set(teamsNeedsAnyone.map(\.rawValue).sorted(), forKey: "workLog.teamsNeedsAnyone")
    }

    /// 저장해 둔 칸 가운데 이 워크플로를 가리키는 곳 (서명만 바뀐 새 주소를 같은 칸에 다시 넣으려고).
    func teamsTarget(forWorkflow id: String) -> TeamsTarget? {
        TeamsTarget.allCases.first { defaults.string(forKey: "workLog.teamsWorkflow.\($0.rawValue)") == id }
    }

    /// 보낼 때만 키체인에서 읽고, 한 번 읽으면 앱이 켜져 있는 동안 메모리에 둔다.
    var redmineKey: String? {
        // 점검용: 다른 서명의 빌드가 키체인을 묻지 않게 환경 변수로 받는다
        if let key = ProcessInfo.processInfo.environment["RUNTIME_REDMINE_KEY"], !key.isEmpty { return key }
        // 허용 창에서 거부해도 한 번만 묻는다 (보낼 때마다 다시 뜨지 않게). 키를 새로 저장하면 다시 읽는다
        // 키는 저장할 때의 레드마인에만 보낸다. 주소를 다른 곳으로 바꾸면 키를 다시 넣게 한다
        guard keyMatchesHost else { return nil }
        if keyLoaded { return cachedKey }
        guard !Self.keychainOff else { return nil }
        cachedKey = Keychain.read(Self.keyAccount)
        keyLoaded = true
        keyDenied = cachedKey == nil && hasRedmineKey
        return cachedKey
    }

    /// 키체인 허용 창에서 거부해 키를 못 읽었다. ‘연결 확인’을 누르면 다시 묻는다.
    @Published private(set) var keyDenied = false

    func retryKeychain() {
        guard keyDenied else { return }
        keyLoaded = false
        keyDenied = false
    }

    /// 키를 저장한 레드마인 호스트와 지금 주소가 같은지. 예전 판에서 저장한 키는 처음 쓸 때 지금 호스트로 묶는다.
    var keyMatchesHost: Bool {
        guard let host = RedmineAPI.baseURL(effectiveRedmineURL)?.host else { return false }
        if envKey { return true }
        guard let saved = defaults.string(forKey: "workLog.redmineKeyHost") else {
            if hasRedmineKey { defaults.set(host, forKey: "workLog.redmineKeyHost") }
            return true
        }
        return saved == host
    }
    private var cachedKey: String?
    private var keyLoaded = false

    /// 화면 점검(--ui-shots)에서 키체인을 건드리지 않게 한다. 다른 서명의 빌드는 읽을 때마다 허용 창이 뜬다.
    static let keychainOff = ProcessInfo.processInfo.environment["RUNTIME_NO_KEYCHAIN"] != nil

    @discardableResult
    func setRedmineKey(_ key: String) -> Bool {
        guard !Self.keychainOff else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(Self.keyAccount) }
        let saved = trimmed.isEmpty || Keychain.write(trimmed, account: Self.keyAccount)
        cachedKey = saved && !trimmed.isEmpty ? trimmed : nil
        keyLoaded = saved
        keyDenied = false
        defaults.set(saved && !trimmed.isEmpty ? RedmineAPI.baseURL(effectiveRedmineURL)?.host : nil, forKey: "workLog.redmineKeyHost")
        hasRedmineKey = Keychain.exists(Self.keyAccount)
        redmineKeyHint = saved && !trimmed.isEmpty ? "••••" + trimmed.suffix(4) : nil
        return saved
    }

    /// 레드마인 주소를 고쳐 둔다: 앞뒤 빈칸, 끝 `/`를 지우고 주소 꼴이 없으면 https를 붙인다.
    func normalizeRedmineURL() {
        var text = redmineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        if text != redmineURL { redmineURL = text }
    }

    /// 이번에 저장한 키의 끝 네 자리 (`••••abcd`). 키 일부라도 파일에 남기지 않게 메모리에만 둔다.
    @Published private(set) var redmineKeyHint: String?
    /// 웹훅 주소의 호스트만 (서명 값이 든 주소 전체는 키체인에만).
    @Published private(set) var teamsHint: String?
    @Published private(set) var teamsMeHint: String?

    /// 점검용 환경 변수(RUNTIME_REDMINE_URL)가 있으면 그 주소를 쓴다. 설정에는 쓰지 않아 앱 설정이 바뀌지 않는다.
    var effectiveRedmineURL: String { ProcessInfo.processInfo.environment["RUNTIME_REDMINE_URL"] ?? redmineURL }
    private var envKey: Bool { !(ProcessInfo.processInfo.environment["RUNTIME_REDMINE_KEY"] ?? "").isEmpty }

    /// 키가 있는데 쓸 수 없는 까닭 (설정 화면·보내기 실패에 그대로 보인다).
    var redmineKeyProblem: String? {
        guard hasRedmineKey, !envKey else { return nil }
        if !keyMatchesHost { return "레드마인 주소가 키를 저장할 때와 달라 키를 보내지 않았습니다. 이 주소의 API 키를 다시 넣으세요" }
        if keyDenied { return "키체인에서 API 키를 읽지 못했습니다. 설정 > 레드마인에서 ‘연결 확인’을 누르고 ‘항상 허용’을 고르세요" }
        return nil
    }

    var redmineReady: Bool { RedmineAPI.baseURL(effectiveRedmineURL) != nil && (hasRedmineKey || envKey) }

    /// Claude Code의 redmine MCP 설정에서 주소와 키를 옮겨 온다. 키는 그 레드마인에만 보낸다.
    func importFromClaude() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
        guard let data = try? Data(contentsOf: url), let found = RedmineAPI.mcpCredentials(in: data) else { return false }
        redmineURL = found.url
        normalizeRedmineURL()
        return setRedmineKey(found.key)
    }

    /// glab 설정에 있는 gitlab.com 밖의 첫 호스트.
    static func detectGitLabHost() -> String? {
        // 예전 glab은 ~/.config/glab-cli에 둔다
        let paths = [ProcessInfo.processInfo.environment["GLAB_CONFIG_DIR"].map { $0 + "/config.yml" },
                     NSHomeDirectory() + "/Library/Application Support/glab-cli/config.yml",
                     NSHomeDirectory() + "/.config/glab-cli/config.yml"].compactMap { $0 }
        guard let text = paths.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first else { return nil }
        var inHosts = false
        var hostIndent: Int?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("hosts:") { inHosts = true; continue }
            guard inHosts, !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 { break }
            // hosts 바로 아래 첫 들여쓰기 깊이의 줄이 호스트 이름 (glab은 네 칸을 쓴다)
            if hostIndent == nil { hostIndent = indent }
            if indent == hostIndent, line.hasSuffix(":") {
                let host = line.trimmingCharacters(in: .whitespaces).dropLast()
                if host != "gitlab.com" { return String(host) }
            }
        }
        return nil
    }
}

/// 업무 일지 키체인 (레드마인 API 키, 팀즈 웹훅). Claude Code 로그인 항목처럼 `/usr/bin/security`로 만든다.
/// 앱이 직접 만든 항목은 자체 서명 앱의 코드 해시에 묶여, "항상 허용"을 눌러도 다시 빌드할 때마다 또 묻는다.
/// 예전 항목은 처음 읽을 때 한 번 옮기고 지운다 (그때 한 번 더 물을 수 있다).
enum Keychain {
    static let service = "RunTime worklog"

    static func read(_ account: String) -> String? {
        if let data = ClaudeLogin.readKeychain(service: service, account: account) {
            return String(data: data, encoding: .utf8)
        }
        guard AppKeychain.exists(account, service: AppKeychain.worklogService),
              let legacy = AppKeychain.read(account, service: AppKeychain.worklogService) else { return nil }
        if ClaudeLogin.writeKeychain(Data(legacy.utf8), service: service, account: account) {
            AppKeychain.delete(account, service: AppKeychain.worklogService)
        }
        return legacy
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard ClaudeLogin.writeKeychain(Data(value.utf8), service: service, account: account) else { return false }
        AppKeychain.delete(account, service: AppKeychain.worklogService)
        return true
    }

    /// 값을 읽지 않고 항목이 있는지만 본다. 허용 창이 뜨지 않는다.
    static func exists(_ account: String) -> Bool {
        ClaudeLogin.keychainItemExists(service: service, account: account)
            || AppKeychain.exists(account, service: AppKeychain.worklogService)
    }

    static func delete(_ account: String) {
        ClaudeLogin.deleteKeychain(service: service, account: account)
        AppKeychain.delete(account, service: AppKeychain.worklogService)
    }
}

/// 앱이 Security.framework로 직접 만든 키체인 항목. 예전 저장소를 옮길 때만 쓴다.
enum AppKeychain {
    static let worklogService = "dev.runtime.RunTime.worklog"

    static func read(_ account: String, service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 있으면 값만 바꾸고 없을 때만 새로 만든다. 지우고 다시 만들면 만들기가 실패할 때 옛 키까지 잃는다.
    @discardableResult
    static func write(_ value: String, account: String, service: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// 값을 읽지 않고 항목이 있는지만 본다. 값을 읽을 때와 달리 키체인 허용 창이 뜨지 않는다.
    static func exists(_ account: String, service: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String, service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// 머지된 MR과 로컬 커밋을 10분마다 가져와 일지에 넣고, 평일 저녁에 보낼 것을 알린다.
final class WorkLogSync: ObservableObject {
    static let shared = WorkLogSync()

    @Published private(set) var capturing = false
    private var wakeObserver: NSObjectProtocol?
    /// 가져오는 중에 들어온 completion. 끝난 뒤 함께 불러 알림이 가져오기 전 줄 수로 나가지 않게 한다.
    private var captureWaiters: [() -> Void] = []
    @Published private(set) var lastCapture: Date?
    @Published private(set) var captureError: String?
    @Published private(set) var lastAdded = 0
    @Published private(set) var issuesError: String?
    @Published private(set) var loadingIssues = false
    @Published private(set) var issuesLoadedAt: Date?
    private var requestedInfo: Set<Int> = []
    @Published private(set) var sending = false
    /// 일감 상태 목록. 레드마인이 닿지 않을 때도 보낼 내용을 미리 보이게 마지막으로 받은 목록을 둔다.
    @Published var statuses: [RedmineAPI.Status] = {
        guard let data = UserDefaults.standard.data(forKey: "workLog.statuses") else { return [] }
        return (try? JSONDecoder().decode([RedmineAPI.Status].self, from: data)) ?? []
    }()
    @Published private(set) var postingTeams = false

    private let settings = WorkLogSettings.shared
    private let store = WorkLogStore.shared
    private let queue = DispatchQueue(label: "dev.runtime.worklog.sync", qos: .utility)
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    func start() {
        // 예전 항목이 남아 있으면 켤 때 한꺼번에 옮긴다. 보낼 때 따로따로 다시 묻지 않게
        if !WorkLogSettings.keychainOff {
            DispatchQueue.global(qos: .utility).async {
                for account in [WorkLogSettings.keyAccount] + TeamsTarget.allCases.map(\.account)
                where AppKeychain.exists(account, service: AppKeychain.worklogService) {
                    _ = Keychain.read(account)
                }
                // 예전에 저장한 웹훅도 회사 계정 인증 주소인지 보고 워크플로를 기억해, 설정 화면이 고치는 길과 자동 연결 칸을 맞춘다
                // 워크플로를 이미 기억한 칸은 다시 읽지 않는다 (값을 읽으면 다른 서명의 빌드에서 키체인 창이 뜬다)
                for target in TeamsTarget.allCases where Keychain.exists(target.account)
                    && UserDefaults.standard.string(forKey: "workLog.teamsWorkflow.\(target.rawValue)") == nil {
                    guard let text = Keychain.read(target.account) else { continue }
                    DispatchQueue.main.async { WorkLogSettings.shared.noteSavedTeams(text, target: target) }
                }
            }
        }
        timer?.invalidate()
        // 1분마다 깨서 10분이 지났으면 가져오고, 알림 시각이 됐으면 알린다
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        // 잠에서 깨면 망이 붙을 틈을 30초 주고 바로 가져온다 (깨자마자 받다 실패한 오류가 남지 않게)
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                             queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    guard let self, self.settings.captureEnabled else { return }
                    self.capture()
                }
            }
        }
        tick()
    }

    private func tick() {
        if settings.captureEnabled, Date().timeIntervalSince(lastCapture ?? .distantPast) >= 600 { capture() }
        // 내 일감은 30분마다 새로 받는다
        if settings.redmineReady, Date().timeIntervalSince(issuesLoadedAt ?? .distantPast) >= 1800 { loadMyIssues() }
        // 자정을 넘기면 그날 고정 업무를 넣는다 (가져오기를 꺼 두었거나 창을 켜 둔 채여도). 이미 있으면 아무것도 하지 않는다
        store.applyRecurringToday()
        remindIfDue()
        TeamsWeb.shared.refreshIfDue()
    }

    // MARK: 가져오기

    func capture(completion: (() -> Void)? = nil) {
        guard !capturing else {
            if let completion { captureWaiters.append(completion) }
            return
        }
        let host = settings.gitlabHostName
        guard !host.isEmpty else {
            captureError = "GitLab 주소를 설정하세요"
            lastAdded = 0
            completion?()
            return
        }
        capturing = true
        let folder = (settings.repoFolder as NSString).expandingTildeInPath
        // 지난번 가져온 날의 앞날 0시부터. 처음이거나 일지에 가져온 줄이 없으면 지난 7일.
        let calendar = WorkDay.calendar
        let hasCaptured = store.log.entries.contains { $0.source != nil }
        let last = hasCaptured ? defaults.object(forKey: "workLog.lastCapture") as? Date : nil
        // 오래 꺼 두었거나 실패가 이어져도 14일보다 앞은 받지 않는다 (쪽이 늘어 시간 초과로 다시 실패하지 않게)
        let start = max(last ?? Date().addingTimeInterval(-6 * 86_400), Date().addingTimeInterval(-14 * 86_400))
        let since = calendar.date(byAdding: .day, value: last == nil ? 0 : -1, to: calendar.startOfDay(for: start)) ?? start
        queue.async { [weak self] in
            var errors: [String] = []
            var mrs: [WorkCapture.MergedMR] = []
            var commits: [WorkCapture.Commit] = []
            var gotMRs = false
            do {
                mrs = try Self.fetchMRs(host: host, since: since)
                gotMRs = true
                // MR을 못 받은 채 커밋만 넣으면 이미 머지된 브랜치가 진행중으로 남아, MR을 받을 때만 커밋도 넣는다
                commits = Self.localCommits(folder: folder, host: host, since: since, mrs: mrs, errors: &errors)
            } catch {
                errors.append("GitLab: \(Self.gitLabHint(error.localizedDescription, host: host))")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastAdded = self.store.applyCapture(mrs: mrs, commits: commits)
                self.store.applyRecurringToday()
                self.capturing = false
                // MR을 못 받았으면(잠에서 막 깨 VPN이 붙기 전 등) 10분을 다 기다리지 않고 2분 뒤 다시 해 본다
                self.lastCapture = gotMRs ? Date() : Date().addingTimeInterval(-480)
                self.captureError = errors.first
                // 저장소 하나의 git 오류로 기간이 멈추지 않게, MR을 받았으면 다음엔 그 뒤부터 받는다
                if gotMRs { self.defaults.set(Date(), forKey: "workLog.lastCapture") }
                completion?()
                let waiters = self.captureWaiters
                self.captureWaiters = []
                waiters.forEach { $0() }
            }
        }
    }

    private static func fetchMRs(host: String, since: Date) throws -> [WorkCapture.MergedMR] {
        let iso = ISO8601DateFormatter().string(from: since)
        let output = try glab(host: host, "merge_requests?scope=created_by_me&state=merged&updated_after=\(iso)&per_page=100",
                              paginate: true)
        return try WorkCapture.parseMRs(output)
    }

    /// 다른 Mac에서 흔한 실패는 할 일을 함께 알린다.
    static func gitLabHint(_ message: String, host: String) -> String {
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("invalid_token")
            || lower.contains("no token") || lower.contains("not authenticated") || lower.contains("authentication") {
            return "로그인이 필요합니다. 터미널에서 glab auth login --hostname \(host)"
        }
        if lower.contains("timeout") || lower.contains("no such host") || lower.contains("connection refused")
            || lower.contains("network is unreachable") {
            return "\(host)에 닿지 않습니다. VPN이나 회사망 연결을 확인하세요"
        }
        if lower.contains("403") || lower.contains("forbidden") || lower.contains("insufficient_scope") {
            return "토큰 권한이 모자랍니다. api 권한으로 glab auth login --hostname \(host)"
        }
        return message
    }

    static var glabInstalled: Bool { (try? glabPath()) != nil }

    private static func glabPath() throws -> String {
        let candidates = ["/opt/homebrew/bin/glab", "/usr/local/bin/glab", "/opt/local/bin/glab",
                          NSHomeDirectory() + "/.local/bin/glab", NSHomeDirectory() + "/bin/glab"]
        guard let glab = candidates.first(where: FileManager.default.isExecutableFile)
        else { throw SyncError("glab이 없습니다. 터미널에서 brew install glab 뒤 glab auth login") }
        return glab
    }

    /// GitLab API 한 번 (`glab api`).
    /// 여러 쪽을 받을 때는 쪽마다 1~2초씩 걸려 시간을 넉넉히 준다.
    static func glab(host: String, _ endpoint: String, paginate: Bool = false) throws -> Data {
        try run(glabPath(), ["api"] + (paginate ? ["--paginate"] : []) + ["--hostname", host, endpoint],
                timeout: paginate ? 120 : 30)
    }

    static func glabText(_ args: [String]) throws -> String {
        text(try run(glabPath(), args))
    }

    /// 회사 GitLab 저장소가 아닌 곳은 조용히 건너뛰고, 회사 저장소에서 git이 실패하면 오류로 알린다.
    private static func localCommits(folder: String, host: String, since: Date, mrs: [WorkCapture.MergedMR],
                                     errors: inout [String]) -> [WorkCapture.Commit] {
        let mrPaths = Set(mrs.map(\.path))
        let iso = ISO8601DateFormatter().string(from: since)
        // 저장소마다 git을 띄우기 전에 .git/config를 파일로 읽어 회사 GitLab 원격이 없는 저장소는 바로 거른다
        // (저장소가 수십 개면 git 호출만 수백 번이라 가져오기가 느려진다)
        let candidates = repositories(in: folder).filter { repo in
            gitConfig(repo).range(of: host, options: .caseInsensitive) != nil
        }
        var commits: [WorkCapture.Commit] = []
        var noEmail: [String] = []
        var problems: [String] = []
        let lock = NSLock()
        // 회사 저장소만 네 개씩 함께 읽는다
        let lanes = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            lanes.wait()
            defer { lanes.signal() }
            let repo = candidates[index]
            let name = URL(fileURLWithPath: repo).lastPathComponent
            // origin이 GitHub이고 upstream이 회사 GitLab이거나, 포크에서 일하는 저장소도 잡게 원격을 모두 본다
            guard let remotes = try? text(run("/usr/bin/git", ["-C", repo, "config", "--get-regexp", "^remote\\..*\\.url$"], timeout: 15)),
                  let path = WorkCapture.projectPath(remotes: remotes, host: host, mrPaths: mrPaths)
            else { return }
            guard let email = try? text(run("/usr/bin/git", ["-C", repo, "config", "user.email"], timeout: 15)), !email.isEmpty else {
                lock.lock(); noEmail.append(name); lock.unlock()
                return
            }
            do {
                let refs = try text(run("/usr/bin/git", ["-C", repo, "for-each-ref", "--format=%(refname)", "refs/remotes", "refs/heads"],
                                        timeout: 15))
                    .components(separatedBy: "\n")
                // main·dev·release와 이미 머지된 MR의 대상·원본 브랜치에 들어간 커밋은 MR 줄에 있으니, 아직 머지 전인 커밋만 받는다.
                // --all은 stash·태그까지 읽어 브랜치와 원격만 본다. --branches/--remotes는 %S를 짧은 이름(origin/x)으로 내
                // 지난 줄과 브랜치가 어긋나므로 --glob으로 전체 ref 이름을 받는다. 이메일은 글자 그대로(--fixed-strings) <…>까지 맞춘다
                let excluded = WorkCapture.sharedBranches(refs) + WorkCapture.mergedRefs(mrs, path: path, refs: refs)
                let log = try text(run("/usr/bin/git", ["-C", repo, "log", "--glob=refs/heads/*", "--glob=refs/remotes/*", "--no-merges",
                                                        "--fixed-strings", "--author=<\(email)>",
                                                        "--since=\(iso)", "--format=\(WorkCapture.gitLogFormat)", "--not"]
                                       + Array(Set(excluded))))
                let found = WorkCapture.parseCommits(log, path: path)
                lock.lock(); commits += found; lock.unlock()
            } catch {
                lock.lock(); problems.append("\(name): \(error.localizedDescription)"); lock.unlock()
            }
        }
        errors += problems.sorted()
        // 회사 저장소인데 작성자를 몰라 건너뛰면 진행중 줄이 조용히 비므로 알린다
        if !noEmail.isEmpty {
            let names = noEmail.sorted()
            errors.append("git user.email이 없어 건너뛴 저장소: \(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? " 외 \(names.count - 3)개" : "")")
        }
        // 함께 읽어 순서가 섞이니 날짜순으로 둔다 (같은 날 줄 순서가 가져올 때마다 바뀌지 않게)
        return commits.sorted { $0.date < $1.date }
    }

    /// user.email이 없는 회사 저장소에 GitLab 계정의 커밋 이메일을 채우고 다시 가져온다 (그 저장소 설정에만 쓴다).
    func fillMissingEmails(done: @escaping (String) -> Void) {
        let host = settings.gitlabHostName
        let folder = (settings.repoFolder as NSString).expandingTildeInPath
        queue.async { [weak self] in
            let repos = Self.repositories(in: folder).filter { repo in
                Self.gitConfig(repo).range(of: host, options: .caseInsensitive) != nil
                    && ((try? Self.text(Self.run("/usr/bin/git", ["-C", repo, "config", "user.email"], timeout: 15))) ?? "").isEmpty
            }
            struct User: Decodable { let commit_email: String?; let email: String? }
            let user = (try? Self.glab(host: host, "user")).flatMap { try? JSONDecoder().decode(User.self, from: $0) }
            guard let email = [user?.commit_email, user?.email].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
                return DispatchQueue.main.async { done("GitLab 계정 이메일을 받지 못했습니다. glab 로그인을 확인하세요") }
            }
            var filled = 0
            for repo in repos where (try? Self.run("/usr/bin/git", ["-C", repo, "config", "user.email", email], timeout: 15)) != nil {
                filled += 1
            }
            DispatchQueue.main.async {
                done("저장소 \(filled)곳에 \(email)을 넣었습니다")
                self?.capture()
            }
        }
    }

    /// 저장소의 git 설정 글. 서브모듈은 `.git`이 `gitdir: …` 한 줄짜리 파일이라 그 자리의 설정을 읽는다.
    private static func gitConfig(_ repo: String) -> String {
        let dotGit = repo + "/.git"
        if let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            let dir = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let path = dir.hasPrefix("/") ? dir : repo + "/" + dir
            return (try? String(contentsOfFile: path + "/config", encoding: .utf8)) ?? ""
        }
        return (try? String(contentsOfFile: dotGit + "/config", encoding: .utf8)) ?? ""
    }

    /// 폴더 아래 네 단계까지의 git 저장소. 저장소를 찾으면 그 안으로는 내려가지 않고,
    /// 빌드·의존성 폴더와 연결된 워크트리(같은 저장소를 두 번 읽게 됨)는 건너뛴다.
    static func repositories(in folder: String) -> [String] {
        let manager = FileManager.default
        let skipped: Set<String> = ["node_modules", ".build", "build", "Pods", "DerivedData", "vendor", "dist", "Library"]
        func children(_ path: String) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: path)) ?? [])
                .filter { !$0.hasPrefix(".") && !skipped.contains($0) }
                .map { path + "/" + $0 }
                .filter { var dir: ObjCBool = false; return manager.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue }
        }
        var repos: [String] = []
        func walk(_ path: String, depth: Int) {
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: path + "/.git", isDirectory: &isDirectory) {
                // `.git`이 파일이면 워크트리다. 본 저장소에서 이미 모든 브랜치를 읽는다
                let worktree = !isDirectory.boolValue
                    && ((try? String(contentsOfFile: path + "/.git", encoding: .utf8)) ?? "").contains("/worktrees/")
                if !worktree { repos.append(path) }
                return
            }
            guard depth < 4 else { return }
            for child in children(path) { walk(child, depth: depth + 1) }
        }
        for child in children(folder) { walk(child, depth: 1) }
        return repos
    }

    private static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        // 메뉴바 앱은 셸 PATH를 물려받지 않아 glab이 git을 찾도록 넣어 준다
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GLAB_NO_PROMPT"] = "1"
        environment["NO_PROMPT"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // 두 파이프를 함께 비워야 한쪽이 가득 차 멈추지 않는다. 망이 끊겨 glab이 멈추면 timeout 뒤 끊는다
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()
        if process.terminationReason == .uncaughtSignal {
            throw SyncError("응답이 느려 \(Int(timeout))초 뒤 멈췄습니다. 잠시 뒤 다시 가져오세요")
        }
        guard process.terminationStatus == 0 else {
            // glab은 오류를 색과 빈 줄로 꾸민 ERROR 상자에 담아 낸다
            let message = String(decoding: errorData, as: UTF8.self)
                .replacingOccurrences(of: #"\u{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "ERROR" && !$0.hasPrefix("DEPRECATION WARNING") }
                .joined(separator: " ")
            throw SyncError(message.isEmpty ? "\(URL(fileURLWithPath: tool).lastPathComponent) 실패" : String(message.prefix(200)))
        }
        return data
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 레드마인

    /// 나에게 배정된 열린 일감 전부와, 일지가 가리키는 일감, 그 조상 일감을 받아 장부에 넣는다.
    /// 조상 이름으로 보고서 이름(`데이터 수집 > 공유 파일 관리 API 연동`)을 만들고 QA 건을 가린다.
    func loadMyIssues(completion: (() -> Void)? = nil) {
        let referenced = store.log.entries.filter { $0.day >= WorkDay.adding(-40, to: WorkDay.today()) }.compactMap(\.issue)
        fetchBook(assigned: true, extra: referenced, completion: completion)
    }

    /// 장부에 없는 일감만 받아 넣는다 (일감 번호를 새로 적었을 때).
    func loadInfo(_ ids: [Int]) {
        let missing = ids.filter { store.log.issue($0) == nil && !requestedInfo.contains($0) }
        guard !missing.isEmpty else { return }
        requestedInfo.formUnion(missing)
        // 망 오류로 못 받았으면 다음에 다시 묻는다 (남겨 두면 그 카드가 앱을 다시 켤 때까지 "받는 중"에 멈춘다)
        fetchBook(assigned: false, extra: missing) { [weak self] in
            if self?.issuesError != nil { self?.requestedInfo.subtract(missing) }
        }
    }

    private func fetchBook(assigned: Bool, extra: [Int], completion: (() -> Void)? = nil) {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else {
            issuesError = "레드마인 주소(https)와 API 키를 설정하세요"
            completion?()
            return
        }
        if assigned {
            guard !loadingIssues else { completion?(); return }
            loadingIssues = true
        }
        queue.async { [weak self] in
            // 받기를 시작한 때를 장부에 적어, 그 뒤에 앱에서 보낸 진척률을 덮지 않게 한다
            let startedAt = Date()
            let result = Result { () -> (infos: [IssueInfo], assignedIDs: Set<Int>?) in
                var lookup: [Int: RedmineAPI.Issue] = [:]
                var assignedIDs: Set<Int>?
                if assigned {
                    // 100개씩 끝까지 (열린 일감이 100개를 넘는다)
                    var offset = 0
                    var ids = Set<Int>()
                    while offset < 1000 {
                        let data = try Self.fetch(RedmineAPI.myIssuesRequest(base: base, key: key, offset: offset))
                        let page = try RedmineAPI.parseIssues(data)
                        for issue in page { lookup[issue.id] = issue; ids.insert(issue.id) }
                        offset += 100
                        if page.isEmpty || offset >= (RedmineAPI.totalCount(data) ?? 0) { break }
                    }
                    assignedIDs = ids
                }
                // 조상과 따로 부른 일감을 100개씩 묶어 받는다. 사슬이 깊어도 여섯 번이면 맨 위에 닿는다
                var wanted = Set(extra).subtracting(lookup.keys)
                var asked = Set<Int>()
                for _ in 0..<6 {
                    wanted.formUnion(lookup.values.compactMap(\.parentID))
                    // 받아지지 않는(권한 없는·지운) 번호는 다시 묻지 않는다
                    wanted.subtract(lookup.keys)
                    wanted.subtract(asked)
                    guard !wanted.isEmpty else { break }
                    asked.formUnion(wanted)
                    let list = Array(wanted)
                    for start in stride(from: 0, to: list.count, by: 100) {
                        let data = try Self.fetch(RedmineAPI.issuesRequest(base: base, key: key,
                                                                            ids: Array(list[start..<min(start + 100, list.count)])))
                        for issue in try RedmineAPI.parseIssues(data) { lookup[issue.id] = issue }
                    }
                    wanted = []
                }
                let targets = (assignedIDs ?? []).union(extra).filter { lookup[$0] != nil }
                let infos = targets.compactMap { id in
                    lookup[id].map { IssueInfo.build($0, lookup: lookup, assigned: assignedIDs?.contains(id) ?? false, now: startedAt) }
                }
                return (infos, assignedIDs)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if assigned { self.loadingIssues = false }
                switch result {
                case .success(let book):
                    self.store.updateIssues(book.infos, assignedIDs: book.assignedIDs)
                    if assigned { self.issuesLoadedAt = Date() }
                    self.issuesError = nil
                    self.detectNoteFormat()
                case .failure(let error):
                    self.issuesError = error.localizedDescription
                }
                completion?()
            }
        }
    }

    /// 백그라운드 큐에서 응답을 기다린다.
    private static func fetch(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<Data, Error> = .failure(SyncError("응답 없음"))
        var timed = request
        timed.timeoutInterval = 30
        URLSession.shared.dataTask(with: timed) { data, response, error in
            if let error {
                output = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                output = .failure(SyncError(statusText(response)))
            } else {
                output = .success(data ?? Data())
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try output.get()
    }

    /// 나에게 배정된 열린 일감 (장부에서). 기한 가까운 것 먼저, 같으면 최근 번호 먼저.
    var myIssues: [IssueInfo] {
        store.log.issues.values.filter(\.assigned).sorted {
            let a = $0.dueDate ?? "9999", b = $1.dueDate ?? "9999"
            return a != b ? a < b : $0.id > $1.id
        }
    }

    func info(_ id: Int) -> IssueInfo? { store.log.issue(id) }

    /// 댓글을 HTML로 보낼지 평문으로 보낼지 이 레드마인의 기존 댓글을 보고 정한다. 웹 편집기(CKEditor 등)를 쓰는 곳은
    /// 댓글에 `<p>`·`<br`가 있고, Textile·Markdown 레드마인은 없다. 사용자가 스위치를 직접 바꿨으면 그대로 둔다.
    private func detectNoteFormat() {
        guard defaults.object(forKey: "workLog.redmineHTML") == nil || defaults.bool(forKey: "workLog.redmineHTMLAuto"),
              !defaults.bool(forKey: "workLog.redmineHTMLChecked"),
              let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else { return }
        let ids = Array(store.log.issues.values.filter(\.assigned).map(\.id).sorted(by: >).prefix(6))
        guard !ids.isEmpty else { return }
        defaults.set(true, forKey: "workLog.redmineHTMLChecked")
        queue.async { [weak self] in
            var html = 0, plain = 0
            for id in ids where html + plain < 8 {
                let response = Self.perform(RedmineAPI.issueWithJournalsRequest(base: base, key: key, issue: id))
                guard response.ok, let data = response.data, let journals = try? RedmineAPI.parseJournals(data) else { continue }
                for note in journals.map(\.notes) where note.count > 10 {
                    if note.contains("<p>") || note.contains("<br") { html += 1 } else { plain += 1 }
                }
            }
            guard html + plain > 0 else {
                DispatchQueue.main.async { self?.defaults.set(false, forKey: "workLog.redmineHTMLChecked") }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.settings.redmineHTML = html >= plain
                self.defaults.set(true, forKey: "workLog.redmineHTMLAuto")
            }
        }
    }

    func loadStatuses() {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else { return }
        URLSession.shared.dataTask(with: RedmineAPI.statusesRequest(base: base, key: key)) { [weak self] data, response, _ in
            guard (try? Self.check(response)) != nil, let list = try? RedmineAPI.parseStatuses(data ?? Data()), !list.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statuses = list
                self.defaults.set(try? JSONEncoder().encode(list), forKey: "workLog.statuses")
                // 고른 적이 없거나 고른 상태가 사라졌을 때만 이름으로 어림한다.
                // ‘바꾸지 않음’(nil, 0으로 저장)을 고른 것은 그대로 둔다 (어림하면 완료로 바뀌어 일감이 닫힌다)
                let guess = WorkReport.defaultStatuses(list)
                func lost(_ id: Int?, _ key: String) -> Bool {
                    self.defaults.object(forKey: key) == nil || (id != nil && !list.contains { $0.id == id })
                }
                if lost(self.settings.progressStatusID, "workLog.progressStatus") { self.settings.progressStatusID = guess.progress }
                if lost(self.settings.doneStatusID, "workLog.doneStatus") { self.settings.doneStatusID = guess.done }
            }
        }.resume()
    }

    /// 댓글 수정 API가 되는 레드마인인지. 한 번 404를 받으면 아니라고 적어 둔다.
    var journalAPI: Bool { defaults.object(forKey: "workLog.journalAPI") as? Bool ?? true }

    /// 이 일감을 보낼 때 함께 바꿀 칸: 일지로 정한 상태·날짜 위에 직접 고른 칸을 얹는다.
    func fields(for update: WorkReport.RedmineUpdate, edit: WorkReport.IssueEdit? = nil) -> WorkReport.IssueFields {
        let update = prepared(update, edit: edit)
        let current = store.log.issue(update.issue)
        let auto = settings.syncIssueFields && !statuses.isEmpty
            ? Self.droppingBlocked(WorkReport.issueFields(for: update, current: current, statuses: statuses,
                                                          progressID: settings.progressStatusID, doneID: settings.doneStatusID),
                                   current: current, blocked: blockedTransitions)
            : .init()
        return .merged(auto: auto, edit: edit, current: current, statuses: statuses)
    }

    /// Claude 등으로 이미 올린 것 같은 댓글 (일감 번호 → 그 댓글). 같은 글을 두 번 올리지 않게 카드에 알린다.
    @Published var postedHints: [Int: RedmineAPI.Journal] = [:]
    private var checkedNotes: [Int: String] = [:]

    /// 보낼 일감마다 레드마인 댓글을 읽어 비슷한 댓글이 이미 있는지 본다. 같은 글은 한 번만 본다.
    func checkPosted(_ updates: [WorkReport.RedmineUpdate]) {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else { return }
        let todo = updates.filter { $0.needsNote && checkedNotes[$0.issue] != $0.note }
        guard !todo.isEmpty else { return }
        for update in todo { checkedNotes[update.issue] = update.note }
        // 앱이 전에 올린 자기 댓글은 ‘이미 올린 댓글’로 보지 않는다 (이어 쓰는 오늘 댓글이 빠지지 않게)
        let mine = Dictionary(grouping: store.log.sent.filter { $0.undoneAt == nil }, by: \.issue)
        queue.async { [weak self] in
            for update in todo {
                let response = Self.perform(RedmineAPI.issueWithJournalsRequest(base: base, key: key, issue: update.issue))
                guard response.ok, let data = response.data, let journals = try? RedmineAPI.parseJournals(data) else {
                    // 못 읽었으면 확인한 것으로 남기지 않는다. 다음에 목록을 열 때 다시 본다
                    DispatchQueue.main.async { self?.checkedNotes[update.issue] = nil }
                    continue
                }
                // Claude는 MR을 올릴 때(머지 전날일 수 있다) 댓글을 다니, 첫날 사흘 전부터 본다
                let since = update.days.first.flatMap(WorkDay.date).map { $0.addingTimeInterval(-3 * 86_400) } ?? .distantPast
                let own = Set((mine[update.issue] ?? []).compactMap { $0.matchJournal(journals)?.id })
                let hit = RedmineComment.alreadyPosted(update.note, journals: journals.filter { !own.contains($0.id) }, since: since)
                DispatchQueue.main.async { self?.postedHints[update.issue] = hit }
            }
        }
    }

    /// 프로젝트 구성원 (담당자 고르기). 프로젝트마다 한 번 받아 둔다.
    @Published private(set) var members: [Int: [RedmineAPI.Member]] = [:]
    private var requestedMembers: Set<Int> = []

    func loadMembers(project: Int?) {
        guard let project, !requestedMembers.contains(project),
              let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else { return }
        requestedMembers.insert(project)
        URLSession.shared.dataTask(with: RedmineAPI.membersRequest(base: base, key: key, project: project)) { [weak self] data, response, _ in
            let list = (try? Self.check(response)) != nil ? (try? RedmineAPI.parseMembers(data ?? Data())) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let list { self.members[project] = list } else { self.requestedMembers.remove(project) }
            }
        }.resume()
    }

    // MARK: 팀즈

    /// 웹훅이 있으면 앱에서 바로 보내고, 없거나 회사 계정 인증으로 막히면 그 채팅을 팀즈에서 열어 붙여 넣는다.
    /// `done`에는 알릴 말과 실패 여부가 온다.
    /// `fallback`이 false면 웹훅으로만 보낸다 (웹훅 시험이 채팅 열기로 넘어가 성공처럼 보이지 않게).
    func postTeams(_ report: String, title: String, to target: TeamsTarget? = nil, fallback: Bool = true,
                   done: @escaping (_ message: String, _ failed: Bool) -> Void) {
        let target = target ?? settings.reportTarget
        guard !postingTeams else { return done("이미 보내는 중입니다", true) }
        guard settings.teamsDirect(target), let url = settings.teamsWebhook(target),
              let request = try? TeamsWebhook.request(url: url, report: report, title: title) else {
            guard fallback else { return done("\(target.name) 웹훅으로 보낼 수 없습니다", true) }
            return openTeams(report, title: title, target: target, done: done)
        }
        postingTeams = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let message: String? = error?.localizedDescription
                ?? ((try? Self.check(response)) == nil ? TeamsWebhook.failure(status: (response as? HTTPURLResponse)?.statusCode,
                                                                                body: data ?? Data()) : nil)
            let status = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async {
                guard let self else { return }
                self.postingTeams = false
                guard let message else {
                    self.settings.markTeams(target, needsAnyone: false)
                    return done("\(target.name) 보냈습니다", false)
                }
                // 회사 계정 인증으로 막히면 표시해 두고, 채팅 링크가 있으면 그 길로 이어서 보낸다
                if status == 401 || status == 403 {
                    self.settings.markTeams(target, needsAnyone: true)
                    if fallback, self.settings.teamsLink(target) != nil {
                        return self.openTeams(report, title: title, target: target, done: done)
                    }
                }
                done("\(target.name) 보내지 못했습니다: \(message)", true)
            }
        }.resume()
    }

    private func openTeams(_ report: String, title: String, target: TeamsTarget,
                           done: @escaping (_ message: String, _ failed: Bool) -> Void) {
        guard let link = settings.teamsLink(target) else {
            return done("\(target.name) 채팅 링크를 넣으세요 (팀즈 채팅 ⋯ > 링크 복사)", true)
        }
        // 팀즈 웹에 로그인해 두었으면 창을 띄우지 않고 보낸다. 로그인이 풀렸으면 팀즈 앱을 여는 길로 넘어간다
        let web = TeamsWeb.shared
        if web.everReady, TeamsWeb.canSend(link) {
            postingTeams = true
            web.send(report, title: title, link: link, key: target.rawValue) { [weak self] outcome in
                guard let self else { return }
                self.postingTeams = false
                switch outcome {
                case .sent:
                    done("\(target.name) 보냈습니다", false)
                case .unsure(let message):
                    // 늦게 나갔을 수 있어 다시 보내지 않게 실패로 보이지 않는다
                    Diagnostics.record("팀즈", "\(target.name) 웹: \(message)")
                    done("\(target.name): \(message)", false)
                case .failed(let message):
                    Diagnostics.record("팀즈", "\(target.name) 웹: \(message)")
                    guard web.state == .needsLogin else { return done("\(target.name) 보내지 못했습니다: \(message)", true) }
                    self.openWithApp(report, title: title, target: target, link: link) { text, failed in
                        done("팀즈 웹 로그인이 풀려 팀즈 앱으로 엽니다. " + text, failed)
                    }
                }
            }
            return
        }
        openWithApp(report, title: title, target: target, link: link, done: done)
    }

    private func openWithApp(_ report: String, title: String, target: TeamsTarget, link: String,
                             done: @escaping (_ message: String, _ failed: Bool) -> Void) {
        postingTeams = true
        TeamsOpener.deliver(report, title: title, link: link, key: target.rawValue, autoPaste: settings.teamsAutoPaste,
                            autoSend: settings.teamsAutoSend, returnBack: settings.teamsReturn) { [weak self] result in
            self?.postingTeams = false
            // 보고서 내용은 남기지 않고 어디서 멈췄는지만 (다른 Mac에서 안 될 때 원인을 보려고)
            switch result {
            case .copied(let reason?), .pasted(let reason?): Diagnostics.record("팀즈", "\(target.name): \(reason)")
            case .failed(let message): Diagnostics.record("팀즈", "\(target.name): \(message)")
            default: break
            }
            switch result {
            case .copied(let reason):
                done((reason.map { $0 + ". " } ?? "") + "팀즈에서 \(target.name) 채팅을 열었습니다. ⌘V로 붙여 넣고 Enter를 누르세요", reason != nil)
            case .pasted(let reason):
                done("\(target.name) 채팅에 붙여 넣었습니다. " + (reason ?? "확인하고 Enter를 누르세요"), false)
            case .sent: done("\(target.name) 보냈습니다", false)
            case .failed(let message): done(message, true)
            }
        }
    }

    /// 일감마다 차례로 지금 값을 다시 읽고 댓글·진척률과 함께 상태·시작일·기한·담당자를 보낸다.
    /// `edits`는 카드에서 직접 고른 칸으로, 일지로 정한 값보다 앞선다.
    func send(_ updates: [WorkReport.RedmineUpdate], edits: [Int: WorkReport.IssueEdit] = [:],
              withoutScreens: Set<Int> = [], withoutNotes: Set<Int> = [], screenPicks: MRScreens.Picks = MRScreens.Picks(),
              done: @escaping (_ sent: Int, _ failures: [String]) -> Void) {
        guard !sending else {
            done(0, ["이미 보내는 중입니다"])
            return
        }
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else {
            done(0, [settings.redmineKeyProblem ?? "레드마인 주소(https)와 API 키를 설정하세요"])
            return
        }
        sending = true
        // 보내는 동안 고친 줄은 보낸 것으로 찍지 않게 시작 시각을 잡아 둔다
        let startedAt = Date()
        // 진행중 기본 진척률과 카드에서 직접 고른 진척률을 먼저 얹는다 (100%로 고르면 완료 상태도 따라온다)
        let updates = updates.map { prepared($0, edit: edits[$0.issue]) }
        // 설정과 장부는 메인에서 읽어 두고, 보내기는 뒤에서 한 건씩 차례로 한다
        let html = settings.redmineHTML
        // 보내는 동안 설정을 바꿔도 값이 갈리지 않게 메인에서 읽어 둔다
        let syncFields = settings.syncIssueFields, progressID = settings.progressStatusID, doneID = settings.doneStatusID
        let plan = { [statuses, blockedTransitions] (update: WorkReport.RedmineUpdate, current: IssueInfo?) -> WorkReport.IssueFields in
            let auto = syncFields && !statuses.isEmpty
                ? Self.droppingBlocked(WorkReport.issueFields(for: update, current: current, statuses: statuses,
                                                              progressID: progressID, doneID: doneID),
                                       current: current, blocked: blockedTransitions)
                : .init()
            return .merged(auto: auto, edit: edits[update.issue], current: current, statuses: statuses)
        }
        let known = Dictionary(uniqueKeysWithValues: updates.compactMap { update in store.log.issue(update.issue).map { (update.issue, $0) } })
        // 줄이 MR에서 왔으면 그 MR의 수정 전·후 화면을 함께 붙인다. 이미 붙여 보낸 MR은 다시 붙이지 않는다
        let host = settings.gitlabHostName
        // 한 MR이 여러 일감에 걸치면 화면을 일감마다 나눠 붙인다. 장부는 메인에서 읽어 둔다
        let splits = store.screenSplits
        var attach: [Int: (origins: [MRScreenStore.Origin], previous: String)] = [:]
        // 화면은 댓글에 붙으므로 댓글을 빼고 보내는 일감에는 붙이지 않는다
        for update in updates where settings.attachScreens && !withoutScreens.contains(update.issue)
            && !withoutNotes.contains(update.issue) && !host.isEmpty {
            let sources = store.log.entries.filter { update.entryIDs.contains($0.id) }.map(\.source)
            let previous = store.log.sent.filter { $0.issue == update.issue && $0.undoneAt == nil }.map(\.note).joined()
            let origins = MRScreenStore.origins(sources)
            if !origins.isEmpty { attach[update.issue] = (origins, previous) }
        }
        queue.async { [weak self] in
            var sent = 0
            var failures: [String] = []
            for update in updates {
                let screens = attach[update.issue].flatMap { plan -> ScreenAttachment? in
                    let refs = MRScreenStore.shared.refsForSending(plan.origins, host: host)
                        .filter { !plan.previous.contains("mr\($0.iid)-") }
                    return refs.isEmpty ? nil : Self.attachScreens(refs, issue: update.issue, splits: splits, picks: screenPicks,
                                                                   base: base, key: key, host: host, html: html)
                }
                let result = Self.sendOne(update, base: base, key: key, known: known[update.issue], html: html,
                                          screens: screens, noteless: withoutNotes.contains(update.issue), plan: plan)
                failures += result.failures
                if result.record != nil || result.markOnly { sent += 1 }
                DispatchQueue.main.async { self?.apply(result, update: update, startedAt: startedAt) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sending = false
                self.loadMyIssues()
                done(sent, failures)
            }
        }
    }

    /// 내 일감에서 칸만 고친다 (댓글 없이). 보낸 기록에 남아 되돌릴 수 있다.
    func saveFields(issue: Int, edit: WorkReport.IssueEdit, done: @escaping (_ problem: String?) -> Void) {
        guard !sending else { return done("보내는 중입니다") }
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else {
            return done("레드마인 주소(https)와 API 키를 설정하세요")
        }
        sending = true
        let statuses = statuses
        let known = store.log.issue(issue)
        queue.async { [weak self] in
            var problem: String?
            var record: RedmineSent?
            let fresh = (try? Self.fetch(RedmineAPI.issueRequest(base: base, key: key, issue: issue))).flatMap { try? RedmineAPI.parseIssues($0).first }
            if let fresh {
                let current = Self.merge(known, fresh)
                let fields = WorkReport.IssueFields.merged(auto: .init(), edit: edit, current: current, statuses: statuses)
                if let message = fields.problem(current: current) {
                    problem = message
                } else if fields.isEmpty && (edit.doneRatio == nil || edit.doneRatio == fresh.doneRatio) {
                    problem = "바뀐 칸이 없습니다"
                } else if let request = try? RedmineAPI.revertRequest(base: base, key: key, issue: issue,
                                                                      doneRatio: edit.doneRatio == fresh.doneRatio ? nil : edit.doneRatio,
                                                                      statusID: fields.status?.id, startDate: fields.startDate,
                                                                      dueDate: fields.dueDate, assigneeID: fields.assignee?.id) {
                    let response = Self.perform(request)
                    if response.ok {
                        record = RedmineSent(issue: issue, entryIDs: [], note: "", before: Self.snapshot(fresh),
                                             after: Self.after(fields, ratio: edit.doneRatio == fresh.doneRatio ? nil : edit.doneRatio))
                    } else {
                        problem = response.message
                    }
                }
            } else {
                problem = "#\(issue)를 읽지 못했습니다"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let record {
                    self.store.addSent(record)
                    self.store.setIssueState(issue, ratio: record.after.doneRatio, fields: Self.fields(record.after, statuses: statuses))
                }
                self.sending = false
                self.loadMyIssues()
                done(problem)
            }
        }
    }

    private struct SendResult {
        var record: RedmineSent?
        var failures: [String] = []
        /// 레드마인 워크플로가 막은 상태 전환 (지금 상태 → 보내려던 상태).
        var blocked: (from: Int, to: Int)?
        /// 보낼 것이 없어 보낸 것으로만 표시한다.
        var markOnly = false
    }

    /// 보낼 진척률: 일지 값 → 진행중 기본값 → 직접 고른 값 순으로 얹는다.
    func prepared(_ update: WorkReport.RedmineUpdate, edit: WorkReport.IssueEdit?) -> WorkReport.RedmineUpdate {
        let base = update.withInProgressRatio(settings.inProgressRatio)
        return edit?.applied(to: base) ?? base
    }

    /// 설정에서 막힌 전환 기억을 지운다 (레드마인 워크플로를 고친 뒤).
    func clearBlockedTransitions() {
        blockedTransitions = []
        defaults.removeObject(forKey: "workLog.blockedTransitions")
    }

    /// 레드마인이 막은 상태 전환 (`"1>3"`). 다음부터는 일지로 정한 상태에서 빼고 보낸다.
    @Published private(set) var blockedTransitions: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "workLog.blockedTransitions") ?? [])

    static func transitionKey(_ from: Int, _ to: Int) -> String { "\(from)>\(to)" }

    /// 일지로 정한 상태가 이미 막힌 전환이면 뺀다. 직접 고른 상태는 그대로 보내 다시 확인하게 둔다.
    static func droppingBlocked(_ auto: WorkReport.IssueFields, current: IssueInfo?, blocked: Set<String>) -> WorkReport.IssueFields {
        guard let status = auto.status, let from = current?.statusID, blocked.contains(transitionKey(from, status.id)) else { return auto }
        var copy = auto
        copy.status = nil
        return copy
    }

    /// 일감 하나: 지금 값을 새로 읽고 → 댓글·진척률·칸. 되돌릴 수 있게 보내기 전 값을 함께 남긴다.
    private static func sendOne(_ update: WorkReport.RedmineUpdate, base: URL, key: String, known: IssueInfo?, html: Bool,
                                screens: ScreenAttachment? = nil, noteless: Bool = false,
                                plan: (WorkReport.RedmineUpdate, IssueInfo?) -> WorkReport.IssueFields) -> SendResult {
        var result = SendResult()
        guard update.needsNote else { return result }
        // 장부 값은 30분 묵을 수 있어, 바꿀 칸을 정하기 전에 지금 값을 받는다
        let fresh = (try? fetch(RedmineAPI.issueRequest(base: base, key: key, issue: update.issue)))
            .flatMap { try? RedmineAPI.parseIssues($0).first }
        let current = fresh.map { merge(known, $0) } ?? known
        // 같은 댓글이 이미 있으면 댓글은 빼고 진척률·칸만 보낸다
        var note = noteless ? "" : html ? RedmineNote.html(update.note) : update.note
        let uploads = noteless ? [] : screens?.uploads ?? []
        if let screens {
            result.failures += screens.failures.map { "#\(update.issue) \($0)" }
            if !screens.section.isEmpty { note += (html ? "\n" : "\n\n") + screens.section }
        }
        var extra = fresh == nil ? WorkReport.IssueFields() : plan(update, current)
        if let problem = extra.problem(current: current) {
            result.failures.append("#\(update.issue) \(problem)라 칸은 빼고 보냄")
            extra = .init()
        }
        if noteless, fresh == nil {
            // 지금 값을 모르면 바뀐 것이 있는지 알 수 없다. 묵은 장부로 보내거나 보낸 것으로 표시하지 않는다
            result.failures.append("#\(update.issue)를 읽지 못해 보내지 않음")
            return result
        }
        if noteless, extra.isEmpty, update.doneRatio == nil || update.doneRatio == fresh?.doneRatio {
            // 바꿀 것이 없다. 레드마인에 빈 기록을 남기지 않고 보낸 것으로만 표시한다
            result.markOnly = true
            result.failures.append("#\(update.issue) 바뀐 것이 없어 보낸 것으로만 표시")
            return result
        }
        var response = put(update, note: note, extra: extra, uploads: uploads, base: base, key: key)
        if response.status == 422 && !extra.isEmpty {
            // 워크플로가 막는 상태 전환이나 구성원이 아닌 담당자면 댓글까지 잃지 않게 칸을 빼고 다시 보낸다
            result.failures.append("#\(update.issue) 상태·날짜·담당자는 레드마인이 받지 않아 댓글과 진척률만 보냄")
            extra = .init()
            response = put(update, note: note, extra: extra, uploads: uploads, base: base, key: key)
        }
        guard response.ok else {
            result.failures.append("#\(update.issue) " + response.message)
            return result
        }
        // 레드마인은 워크플로가 막는 상태 전환을 오류 없이 빼고 저장한다 (예: 할일 → 해결). 다시 읽어 바뀌었는지 본다
        if let wanted = extra.status {
            let after = (try? fetch(RedmineAPI.issueRequest(base: base, key: key, issue: update.issue)))
                .flatMap { try? RedmineAPI.parseIssues($0).first }
            if after == nil {
                // 다시 읽지 못하면 바뀌었는지 모르니 보낸 기록에 상태를 남기지 않는다 (되돌리기가 엉뚱한 값을 되돌리지 않게)
                result.failures.append("#\(update.issue) 상태가 바뀌었는지 확인하지 못함")
                extra.status = nil
            } else if let after, after.statusID != wanted.id {
                result.failures.append("#\(update.issue) 상태는 레드마인 워크플로가 막아 '\(after.status)'에 그대로 둠 ('\(wanted.name)'(으)로 못 바꿈)")
                if let from = current?.statusID, from == after.statusID { result.blocked = (from, wanted.id) }
                extra.status = nil
            }
        }
        let ratio = update.doneRatio == fresh?.doneRatio ? nil : update.doneRatio
        // 보내기 전 값을 못 읽었으면 장부 값을 앞값으로 둔다. 그것도 없으면 되돌릴 때 진척률을 손대지 못한다
        let before = fresh.map(snapshot) ?? known.map {
            RedmineSent.Snapshot(doneRatio: $0.doneRatio, statusID: $0.statusID, statusName: $0.status,
                                 startDate: $0.startDate, dueDate: $0.dueDate, assignee: $0.assignee)
        } ?? .init()
        if fresh == nil, ratio != nil, known == nil {
            result.failures.append("#\(update.issue) 지금 값을 읽지 못해 되돌리기로 진척률을 돌릴 수 없음")
        }
        result.record = RedmineSent(issue: update.issue, entryIDs: update.entryIDs, note: note,
                                    before: before, after: after(extra, ratio: ratio))
        return result
    }

    private static func merge(_ known: IssueInfo?, _ fresh: RedmineAPI.Issue) -> IssueInfo {
        var current = known ?? IssueInfo(id: fresh.id, subject: fresh.subject, project: fresh.project)
        current.status = fresh.status
        current.statusID = fresh.statusID
        current.doneRatio = fresh.doneRatio
        current.startDate = fresh.startDate
        current.dueDate = fresh.dueDate
        current.assignee = fresh.assignee
        current.projectID = fresh.projectID ?? current.projectID
        return current
    }

    private static func snapshot(_ issue: RedmineAPI.Issue) -> RedmineSent.Snapshot {
        .init(doneRatio: issue.doneRatio, statusID: issue.statusID, statusName: issue.status,
              startDate: issue.startDate, dueDate: issue.dueDate, assignee: issue.assignee)
    }

    private static func after(_ fields: WorkReport.IssueFields, ratio: Int?) -> RedmineSent.Snapshot {
        .init(doneRatio: ratio, statusID: fields.status?.id, statusName: fields.status?.name,
              startDate: fields.startDate, dueDate: fields.dueDate, assignee: fields.assignee)
    }

    private static func fields(_ after: RedmineSent.Snapshot, statuses: [RedmineAPI.Status]) -> WorkReport.IssueFields {
        .init(status: after.statusID.flatMap { id in statuses.first { $0.id == id } }, startDate: after.startDate,
              dueDate: after.dueDate, assignee: after.assignee)
    }

    private static func put(_ update: WorkReport.RedmineUpdate, note: String, extra: WorkReport.IssueFields,
                            uploads: [RedmineAPI.Upload] = [],
                            base: URL, key: String) -> (ok: Bool, status: Int?, message: String, data: Data?) {
        guard let request = try? RedmineAPI.updateRequest(base: base, key: key, issue: update.issue, doneRatio: update.doneRatio,
                                                          note: note, fields: extra, uploads: uploads)
        else { return (false, nil, "요청을 만들지 못함", nil) }
        return perform(request)
    }

    struct ScreenAttachment {
        var section = ""
        var uploads: [RedmineAPI.Upload] = []
        var failures: [String] = []
    }

    /// MR 화면 가운데 `issue` 몫을 받아 레드마인에 먼저 올리고, 댓글에 붙일 부분과 첨부 토큰을 돌려준다.
    /// 그림을 못 받거나 못 올려도 댓글은 보낸다 (못 붙인 까닭만 알린다).
    static func attachScreens(_ refs: [MRScreenStore.Ref], issue: Int, splits: [String: MRScreens.Split],
                              picks: MRScreens.Picks = MRScreens.Picks(), base: URL, key: String, host: String, html: Bool) -> ScreenAttachment {
        var result = ScreenAttachment()
        var sections: [String] = []
        for ref in refs {
            guard let all = MRScreenStore.shared.screensForSending(ref, host: host) else {
                result.failures.append("MR !\(ref.iid) 화면을 GitLab에서 읽지 못해 그림 없이 보냄")
                continue
            }
            let screens = MRScreenStore.share(all, ref: ref, issue: issue, splits: splits, picks: picks)
            var files: [String: String] = [:]
            var missing = 0
            for (index, screen) in screens.enumerated() {
                for (kind, path) in screen.images {
                    let name = MRScreens.filename(mr: ref.iid, index: index, kind: kind, path: path)
                    guard let bytes = MRScreenStore.shared.image(path, ref: ref, host: host) else { missing += 1; continue }
                    let response = perform(RedmineAPI.uploadRequest(base: base, key: key, filename: name, data: bytes))
                    guard response.ok, let token = response.data.flatMap(RedmineAPI.parseUploadToken) else {
                        missing += 1
                        continue
                    }
                    files["\(index):\(kind.rawValue)"] = name
                    result.uploads.append(.init(token: token, filename: name, contentType: RedmineAPI.contentType(forFilename: name)))
                }
            }
            if missing > 0 { result.failures.append("MR !\(ref.iid) 화면 \(missing)장을 붙이지 못함") }
            let section = MRScreens.noteSection(screens, files: files, html: html)
            if !section.isEmpty { sections.append(section) }
        }
        // MR이 여럿이면 머리는 한 번만 둔다
        let head = html ? "<p>[수정 전·후 화면]</p>" : "[수정 전·후 화면]"
        result.section = sections.enumerated().map { index, section in
            index == 0 ? section : section.replacingOccurrences(of: head + (html ? "\n" : "\n\n"), with: "")
        }.joined(separator: html ? "\n" : "\n\n")
        return result
    }

    /// 뒤 큐에서 한 요청을 끝까지 기다린다. 422처럼 상태 번호로 갈라야 해서 fetch와 따로 둔다.
    private static func perform(_ request: URLRequest) -> (ok: Bool, status: Int?, message: String, data: Data?) {
        let semaphore = DispatchSemaphore(value: 0)
        var output: (ok: Bool, status: Int?, message: String, data: Data?) = (false, nil, "응답 없음", nil)
        var timed = request
        timed.timeoutInterval = 30
        URLSession.shared.dataTask(with: timed) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let ok = error == nil && status.map { (200..<300).contains($0) } == true
            output = (ok, status, error?.localizedDescription ?? statusText(response), data)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return output
    }

    private func apply(_ result: SendResult, update: WorkReport.RedmineUpdate, startedAt: Date) {
        if let blocked = result.blocked {
            blockedTransitions.insert(Self.transitionKey(blocked.from, blocked.to))
            defaults.set(Array(blockedTransitions).sorted(), forKey: "workLog.blockedTransitions")
        }
        if result.markOnly { store.markPosted(update.entryIDs, unchangedSince: startedAt) }
        // 실패해도 시간 초과처럼 서버에는 올라갔을 수 있다. 다시 보내기 전에 레드마인 댓글을 다시 읽어 겹침을 알리게 한다
        checkedNotes[update.issue] = nil
        guard let record = result.record else { return }
        store.markPosted(update.entryIDs, unchangedSince: startedAt)
        // 보낸 값을 장부에도 적어 다시 받기 전에도 화면이 새 값을 보이게
        store.setIssueState(update.issue, ratio: update.doneRatio, fields: Self.fields(record.after, statuses: statuses))
        store.addSent(record)
    }

    // MARK: 되돌리기

    /// 잘못 보낸 건을 되돌린다: 앱이 바꾼 그대로인 칸을 옛 값으로, 보낸 댓글을 지우고, 그 줄들을 다시 보낼 목록으로 돌린다.
    /// 댓글 수정 API가 없는 레드마인(5.0 아래)이면 지울 댓글 번호를 돌려줘 화면이 그 댓글을 브라우저로 연다.
    func undo(_ record: RedmineSent, done: @escaping (_ problems: [String], _ manualJournal: Int?) -> Void) {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else {
            done(["레드마인 주소(https)와 API 키를 설정하세요"], nil)
            return
        }
        guard !sending else { done(["보내는 중에는 되돌릴 수 없습니다"], nil); return }
        sending = true
        queue.async { [weak self] in
            var problems: [String] = []
            var manual: Int?
            let response = Self.perform(RedmineAPI.issueWithJournalsRequest(base: base, key: key, issue: record.issue))
            guard response.ok, let data = response.data, let issue = try? RedmineAPI.parseIssues(data).first else {
                DispatchQueue.main.async {
                    self?.sending = false
                    done(["#\(record.issue)를 읽지 못했습니다: " + response.message], nil)
                }
                return
            }
            let revert = record.revert(current: Self.snapshot(issue))
            var fieldsKept = false
            if revert.doneRatio != nil || revert.statusID != nil || revert.startDate != nil || revert.dueDate != nil || revert.assigneeID != nil,
               let request = try? RedmineAPI.revertRequest(base: base, key: key, issue: record.issue, doneRatio: revert.doneRatio,
                                                           statusID: revert.statusID, startDate: revert.startDate,
                                                           dueDate: revert.dueDate, assigneeID: revert.assigneeID) {
                let reverted = Self.perform(request)
                if !reverted.ok {
                    problems.append("칸을 되돌리지 못했습니다 (\(reverted.message)). 보낸 기록에서 다시 되돌릴 수 있습니다")
                    fieldsKept = true
                }
            }
            // 댓글을 지우지 못했으면 줄을 다시 보낼 목록에 돌리지 않는다 (그대로 다시 보내면 댓글이 둘이 된다)
            var keepPosted = false
            var commentCleared = false
            if !record.note.isEmpty {
                let journals = (try? RedmineAPI.parseJournals(data)) ?? []
                if let journal = record.matchJournal(journals) {
                    if let request = try? RedmineAPI.clearJournalRequest(base: base, key: key, journal: journal.id) {
                        let cleared = Self.perform(request)
                        if cleared.status == 404 || cleared.status == 403 || cleared.status == 405 {
                            // 레드마인 5.0 아래는 댓글 수정 API가 없다. 그 댓글을 열어 직접 지우게 한다
                            manual = journal.id
                            DispatchQueue.main.async { self?.defaults.set(false, forKey: "workLog.journalAPI") }
                        } else if !cleared.ok {
                            problems.append("댓글을 지우지 못했습니다 (\(cleared.message)). 지운 뒤 줄을 고치면 다시 보낼 목록에 오릅니다")
                            manual = journal.id
                            keepPosted = true
                        } else {
                            commentCleared = true
                        }
                    }
                } else {
                    problems.append("보낸 댓글을 찾지 못했습니다. 이미 지웠거나 고친 것 같습니다")
                }
            }
            // 예전 판이 남긴 작업 시간
            for id in record.timeEntryIDs {
                let deleted = Self.perform(RedmineAPI.deleteTimeEntryRequest(base: base, key: key, id: id))
                if !deleted.ok && deleted.status != 404 { problems.append("작업 시간 \(id)를 지우지 못했습니다 (\(deleted.message))") }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // 칸을 못 되돌렸으면 기록을 남겨 다시 되돌릴 수 있게 한다 (다시 하면 지운 댓글은 건너뛴다)
                if !fieldsKept {
                    self.store.markUndone(record, reopenNote: !keepPosted)
                } else if commentCleared {
                    // 댓글은 지웠으니 줄은 다시 보낼 목록에 돌린다 (남기면 작업 댓글이 조용히 사라진다)
                    self.store.markCommentCleared(record)
                }
                self.sending = false
                self.loadMyIssues()
                done(problems, manual)
            }
        }
    }

    private static func check(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError(statusText(response))
        }
    }

    private static func statusText(_ response: URLResponse?) -> String {
        guard let http = response as? HTTPURLResponse else { return "응답 없음" }
        switch http.statusCode {
        case 401: return "API 키가 맞지 않습니다 (401)"
        case 403: return "권한이 없습니다 (403)"
        case 404: return "일감을 찾지 못했습니다 (404)"
        case 422: return "레드마인이 값을 받지 않았습니다 (422)"
        default: return "HTTP \(http.statusCode)"
        }
    }

    // MARK: 알림

    private func remindIfDue() {
        guard settings.reminderEnabled else { return }
        let calendar = WorkDay.calendar
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let today = WorkDay.today()
        guard (2...6).contains(weekday), minutes >= settings.reminderMinutes,
              defaults.string(forKey: "workLog.lastReminder") != today else { return }
        defaults.set(today, forKey: "workLog.lastReminder")
        // 알리기 전에 마지막으로 한 번 더 가져와 퇴근 직전 머지도 넣는다
        let notify = { [weak self] in
            guard let self else { return }
            let entries = self.store.log.entries(on: today)
            guard !entries.isEmpty else { return }
            let waiting = Set(entries.filter(\.needsRedmine).compactMap(\.issue)).count
            Notifier.shared.send(title: "오늘 업무 일지 \(entries.count)줄",
                                 body: waiting > 0 ? "레드마인에 보낼 일감 \(waiting)개. 눌러서 확인하고 보내세요."
                                                   : "눌러서 일일보고를 복사하세요.",
                                 opens: .workLog)
        }
        if settings.captureEnabled { capture(completion: notify) } else { notify() }
    }
}

struct SyncError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
