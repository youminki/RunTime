import Foundation
import Combine
import Security
import WorkLogCore

/// 업무 일지 연동 설정. 레드마인 API 키만 키체인에 둔다.
final class WorkLogSettings: ObservableObject {
    static let shared = WorkLogSettings()
    private let defaults = UserDefaults.standard

    /// 회사 GitLab 주소 (glab에 로그인한 곳).
    @Published var gitlabHost: String { didSet { defaults.set(gitlabHost, forKey: "workLog.gitlabHost") } }
    @Published var captureEnabled: Bool { didSet { defaults.set(captureEnabled, forKey: "workLog.capture") } }
    /// 로컬 커밋을 찾을 폴더. 두 단계 아래까지 본다.
    @Published var repoFolder: String { didSet { defaults.set(repoFolder, forKey: "workLog.repoFolder") } }
    @Published var redmineURL: String { didSet { defaults.set(redmineURL, forKey: "workLog.redmineURL") } }
    @Published var reminderEnabled: Bool { didSet { defaults.set(reminderEnabled, forKey: "workLog.reminder") } }
    /// 평일 이 시각(분)에 오늘 기록과 보낼 일감을 알린다. 기본 18:00.
    @Published var reminderMinutes: Int { didSet { defaults.set(reminderMinutes, forKey: "workLog.reminderMinutes") } }
    @Published private(set) var hasRedmineKey: Bool
    @Published private(set) var hasTeamsWebhook: Bool
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

    private init() {
        gitlabHost = defaults.string(forKey: "workLog.gitlabHost") ?? Self.detectGitLabHost() ?? ""
        captureEnabled = defaults.object(forKey: "workLog.capture") as? Bool ?? false
        repoFolder = defaults.string(forKey: "workLog.repoFolder") ?? (NSHomeDirectory() + "/GitHub")
        redmineURL = defaults.string(forKey: "workLog.redmineURL") ?? ""
        reminderEnabled = defaults.object(forKey: "workLog.reminder") as? Bool ?? false
        reminderMinutes = defaults.object(forKey: "workLog.reminderMinutes") as? Int ?? 18 * 60
        // 값을 읽지 않고 있는지만 본다 (값을 읽으면 다른 서명의 빌드에서 키체인 창이 뜬다)
        hasRedmineKey = !Self.keychainOff && Keychain.exists(Self.keyAccount)
        hasTeamsWebhook = !Self.keychainOff && Keychain.exists(Self.teamsAccount)
        teamsHint = defaults.string(forKey: "workLog.teamsHost")
        doneFirst = defaults.object(forKey: "workLog.doneFirst") as? Bool ?? true
        weeklyPlan = defaults.object(forKey: "workLog.weeklyPlan") as? Bool ?? false
        dailyHeader = defaults.object(forKey: "workLogReportHeader") as? Bool ?? false
        reportByIssue = defaults.object(forKey: "workLog.reportByIssue") as? Bool ?? true
        reportGrouped = defaults.object(forKey: "workLog.reportGrouped") as? Bool ?? true
        quickAddEnabled = defaults.object(forKey: "workLog.quickAdd") as? Bool ?? true
        syncIssueFields = defaults.object(forKey: "workLog.syncIssueFields") as? Bool ?? true
        redmineHTML = defaults.object(forKey: "workLog.redmineHTML") as? Bool ?? true
        let progress = defaults.integer(forKey: "workLog.progressStatus")
        progressStatusID = progress > 0 ? progress : nil
        let done = defaults.integer(forKey: "workLog.doneStatus")
        doneStatusID = done > 0 ? done : nil
    }

    private static let keyAccount = "redmine-api-key"
    private static let teamsAccount = "teams-webhook"

    /// 웹훅 주소는 아는 사람 누구나 그 채팅에 글을 올릴 수 있어 키체인에 둔다.
    var teamsWebhook: URL? {
        // 점검용: 다른 서명의 빌드가 키체인을 묻지 않게 환경 변수로 받는다
        if let text = ProcessInfo.processInfo.environment["RUNTIME_TEAMS_WEBHOOK"], TeamsWebhook.isValid(text) { return URL(string: text) }
        guard !Self.keychainOff else { return nil }
        return Keychain.read(Self.teamsAccount).flatMap(URL.init(string:))
    }

    @discardableResult
    func setTeamsWebhook(_ text: String) -> Bool {
        guard !Self.keychainOff else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(Self.teamsAccount)
        } else {
            guard TeamsWebhook.isValid(trimmed), Keychain.write(trimmed, account: Self.teamsAccount) else { return false }
        }
        hasTeamsWebhook = Keychain.exists(Self.teamsAccount)
        teamsHint = trimmed.isEmpty ? nil : URL(string: trimmed)?.host
        defaults.set(teamsHint, forKey: "workLog.teamsHost")
        return true
    }

    /// 보낼 때만 키체인에서 읽고, 한 번 읽으면 앱이 켜져 있는 동안 메모리에 둔다.
    var redmineKey: String? {
        // 점검용: 다른 서명의 빌드가 키체인을 묻지 않게 환경 변수로 받는다
        if let key = ProcessInfo.processInfo.environment["RUNTIME_REDMINE_KEY"], !key.isEmpty { return key }
        // 허용 창에서 거부해도 한 번만 묻는다 (보낼 때마다 다시 뜨지 않게). 키를 새로 저장하면 다시 읽는다
        if keyLoaded { return cachedKey }
        guard !Self.keychainOff else { return nil }
        cachedKey = Keychain.read(Self.keyAccount)
        keyLoaded = true
        return cachedKey
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

    /// 점검용 환경 변수(RUNTIME_REDMINE_URL)가 있으면 그 주소를 쓴다. 설정에는 쓰지 않아 앱 설정이 바뀌지 않는다.
    var effectiveRedmineURL: String { ProcessInfo.processInfo.environment["RUNTIME_REDMINE_URL"] ?? redmineURL }
    private var envKey: Bool { !(ProcessInfo.processInfo.environment["RUNTIME_REDMINE_KEY"] ?? "").isEmpty }

    var redmineReady: Bool { RedmineAPI.baseURL(effectiveRedmineURL) != nil && (hasRedmineKey || envKey) }

    /// Claude Code의 redmine MCP 설정에서 주소와 키를 옮겨 온다. 키는 그 레드마인에만 보낸다.
    func importFromClaude() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
        guard let data = try? Data(contentsOf: url), let found = RedmineAPI.mcpCredentials(in: data) else { return false }
        redmineURL = found.url
        return setRedmineKey(found.key)
    }

    /// glab 설정에 있는 gitlab.com 밖의 첫 호스트.
    static func detectGitLabHost() -> String? {
        let path = NSHomeDirectory() + "/Library/Application Support/glab-cli/config.yml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
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

/// 키체인. 앱이 직접 만든 항목이라 고정 서명으로 다시 빌드해도 묻지 않는다.
enum Keychain {
    static let worklogService = "dev.runtime.RunTime.worklog"

    static func read(_ account: String, service: String = worklogService) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 있으면 값만 바꾸고 없을 때만 새로 만든다. 지우고 다시 만들면 만들기가 실패할 때 옛 키까지 잃는다.
    @discardableResult
    static func write(_ value: String, account: String, service: String = worklogService) -> Bool {
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
    static func exists(_ account: String, service: String = worklogService) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String, service: String = worklogService) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// 머지된 MR과 로컬 커밋을 10분마다 가져와 일지에 넣고, 평일 저녁에 보낼 것을 알린다.
final class WorkLogSync: ObservableObject {
    static let shared = WorkLogSync()

    @Published private(set) var capturing = false
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
        timer?.invalidate()
        // 1분마다 깨서 10분이 지났으면 가져오고, 알림 시각이 됐으면 알린다
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        if settings.captureEnabled, Date().timeIntervalSince(lastCapture ?? .distantPast) >= 600 { capture() }
        // 내 일감은 30분마다 새로 받는다
        if settings.redmineReady, Date().timeIntervalSince(issuesLoadedAt ?? .distantPast) >= 1800 { loadMyIssues() }
        remindIfDue()
    }

    // MARK: 가져오기

    func capture(completion: (() -> Void)? = nil) {
        guard !capturing else {
            completion?()
            return
        }
        let host = settings.gitlabHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            captureError = "GitLab 주소를 설정하세요"
            completion?()
            return
        }
        capturing = true
        let folder = settings.repoFolder
        // 지난번 가져온 날의 앞날 0시부터. 처음이거나 일지에 가져온 줄이 없으면 지난 7일.
        let calendar = WorkDay.calendar
        let hasCaptured = store.log.entries.contains { $0.source != nil }
        let last = hasCaptured ? defaults.object(forKey: "workLog.lastCapture") as? Date : nil
        let start = last ?? Date().addingTimeInterval(-6 * 86_400)
        let since = calendar.date(byAdding: .day, value: last == nil ? 0 : -1, to: calendar.startOfDay(for: start)) ?? start
        queue.async { [weak self] in
            var errors: [String] = []
            var mrs: [WorkCapture.MergedMR] = []
            var commits: [WorkCapture.Commit] = []
            do {
                mrs = try Self.fetchMRs(host: host, since: since)
                // MR을 못 받은 채 커밋만 넣으면 이미 머지된 브랜치가 진행중으로 남아, MR을 받을 때만 커밋도 넣는다
                commits = Self.localCommits(folder: folder, host: host, since: since, errors: &errors)
            } catch {
                errors.append("GitLab: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastAdded = self.store.applyCapture(mrs: mrs, commits: commits)
                self.store.applyRecurringToday()
                self.capturing = false
                self.lastCapture = Date()
                self.captureError = errors.first
                if errors.isEmpty { self.defaults.set(Date(), forKey: "workLog.lastCapture") }
                completion?()
            }
        }
    }

    private static func fetchMRs(host: String, since: Date) throws -> [WorkCapture.MergedMR] {
        guard let glab = ["/opt/homebrew/bin/glab", "/usr/local/bin/glab"].first(where: FileManager.default.isExecutableFile)
        else { throw SyncError("glab이 없습니다. brew install glab 뒤 glab auth login") }
        let iso = ISO8601DateFormatter().string(from: since)
        let output = try run(glab, ["api", "--paginate", "--hostname", host,
                                    "merge_requests?scope=created_by_me&state=merged&updated_after=\(iso)&per_page=100"])
        return try WorkCapture.parseMRs(output)
    }

    /// 회사 GitLab 저장소가 아닌 곳은 조용히 건너뛰고, 회사 저장소에서 git이 실패하면 오류로 알린다.
    private static func localCommits(folder: String, host: String, since: Date, errors: inout [String]) -> [WorkCapture.Commit] {
        let iso = ISO8601DateFormatter().string(from: since)
        var commits: [WorkCapture.Commit] = []
        for repo in repositories(in: folder) {
            guard let remote = try? text(run("/usr/bin/git", ["-C", repo, "remote", "get-url", "origin"])),
                  let path = WorkCapture.namespacePath(remote: remote, host: host),
                  let email = try? text(run("/usr/bin/git", ["-C", repo, "config", "user.email"])), !email.isEmpty
            else { continue }
            do {
                let refs = try text(run("/usr/bin/git", ["-C", repo, "for-each-ref", "--format=%(refname)", "refs/remotes"]))
                // main·dev·release에 이미 들어간 커밋은 MR 줄에 있으니, 아직 머지 전인 커밋만 받는다
                // --author는 정규식이라 이메일의 +, . 을 그대로 맞추게 이스케이프한다
                let log = try text(run("/usr/bin/git", ["-C", repo, "log", "--all", "--no-merges",
                                                        "--author=\(NSRegularExpression.escapedPattern(for: email))",
                                                        "--since=\(iso)", "--format=\(WorkCapture.gitLogFormat)", "--not"]
                                       + WorkCapture.sharedBranches(refs.components(separatedBy: "\n"))))
                commits += WorkCapture.parseCommits(log, path: path)
            } catch {
                errors.append("\(URL(fileURLWithPath: repo).lastPathComponent): \(error.localizedDescription)")
            }
        }
        return commits
    }

    /// 폴더 바로 아래와 그 아래의 git 저장소.
    private static func repositories(in folder: String) -> [String] {
        let manager = FileManager.default
        func children(_ path: String) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0 != "node_modules" }
                .map { path + "/" + $0 }
                .filter { var dir: ObjCBool = false; return manager.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue }
        }
        var repos: [String] = []
        for child in children(folder) {
            if manager.fileExists(atPath: child + "/.git") { repos.append(child); continue }
            repos += children(child).filter { manager.fileExists(atPath: $0 + "/.git") }
        }
        return repos
    }

    private static func run(_ tool: String, _ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        // 메뉴바 앱은 셸 PATH를 물려받지 않아 glab이 git을 찾도록 넣어 준다
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["NO_PROMPT"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // 두 파이프를 함께 비워야 한쪽이 가득 차 멈추지 않는다. 망이 끊겨 glab이 멈추면 30초 뒤 끊는다
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()
        if process.terminationReason == .uncaughtSignal {
            throw SyncError("\(URL(fileURLWithPath: tool).lastPathComponent)이 30초 안에 끝나지 않았습니다")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SyncError(message.isEmpty ? "\(URL(fileURLWithPath: tool).lastPathComponent) 실패" : String(message.prefix(160)))
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
        fetchBook(assigned: false, extra: missing)
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

    func loadStatuses() {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else { return }
        URLSession.shared.dataTask(with: RedmineAPI.statusesRequest(base: base, key: key)) { [weak self] data, response, _ in
            guard (try? Self.check(response)) != nil, let list = try? RedmineAPI.parseStatuses(data ?? Data()), !list.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statuses = list
                self.defaults.set(try? JSONEncoder().encode(list), forKey: "workLog.statuses")
                // 고른 상태가 없거나 사라졌으면 이름으로 어림한다
                let guess = WorkReport.defaultStatuses(list)
                if !list.contains(where: { $0.id == self.settings.progressStatusID }) { self.settings.progressStatusID = guess.progress }
                if !list.contains(where: { $0.id == self.settings.doneStatusID }) { self.settings.doneStatusID = guess.done }
            }
        }.resume()
    }

    /// 댓글 수정 API가 되는 레드마인인지. 한 번 404를 받으면 아니라고 적어 둔다.
    var journalAPI: Bool { defaults.object(forKey: "workLog.journalAPI") as? Bool ?? true }

    /// 이 일감을 보낼 때 함께 바꿀 칸: 일지로 정한 상태·날짜 위에 직접 고른 칸을 얹는다.
    func fields(for update: WorkReport.RedmineUpdate, edit: WorkReport.IssueEdit? = nil) -> WorkReport.IssueFields {
        let current = store.log.issue(update.issue)
        let auto = settings.syncIssueFields && !statuses.isEmpty
            ? WorkReport.issueFields(for: update, current: current, statuses: statuses,
                                     progressID: settings.progressStatusID, doneID: settings.doneStatusID)
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
        queue.async { [weak self] in
            for update in todo {
                let response = Self.perform(RedmineAPI.issueWithJournalsRequest(base: base, key: key, issue: update.issue))
                guard response.ok, let data = response.data, let journals = try? RedmineAPI.parseJournals(data) else { continue }
                // Claude는 MR을 올릴 때(머지 전날일 수 있다) 댓글을 다니, 첫날 사흘 전부터 본다
                let since = update.days.first.flatMap(WorkDay.date).map { $0.addingTimeInterval(-3 * 86_400) } ?? .distantPast
                let hit = RedmineComment.alreadyPosted(update.note, journals: journals, since: since)
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

    func postTeams(_ report: String, title: String, done: @escaping (String?) -> Void) {
        guard let url = settings.teamsWebhook else {
            done("팀즈 웹훅 주소를 설정하세요")
            return
        }
        guard !postingTeams, let request = try? TeamsWebhook.request(url: url, report: report, title: title) else {
            done("이미 보내는 중입니다")
            return
        }
        postingTeams = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let message: String? = error?.localizedDescription
                ?? ((try? Self.check(response)) == nil ? TeamsWebhook.failure(status: (response as? HTTPURLResponse)?.statusCode,
                                                                                body: data ?? Data()) : nil)
            DispatchQueue.main.async {
                self?.postingTeams = false
                done(message)
            }
        }.resume()
    }

    /// 일감마다 차례로 지금 값을 다시 읽고 댓글·진척률과 함께 상태·시작일·기한·담당자를 보낸다.
    /// `edits`는 카드에서 직접 고른 칸으로, 일지로 정한 값보다 앞선다.
    func send(_ updates: [WorkReport.RedmineUpdate], edits: [Int: WorkReport.IssueEdit] = [:],
              done: @escaping (_ sent: Int, _ failures: [String]) -> Void) {
        guard !sending else {
            done(0, ["이미 보내는 중입니다"])
            return
        }
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else {
            done(0, ["레드마인 주소(https)와 API 키를 설정하세요"])
            return
        }
        sending = true
        // 설정과 장부는 메인에서 읽어 두고, 보내기는 뒤에서 한 건씩 차례로 한다
        let html = settings.redmineHTML
        let plan = { [settings, statuses] (update: WorkReport.RedmineUpdate, current: IssueInfo?) -> WorkReport.IssueFields in
            let auto = settings.syncIssueFields && !statuses.isEmpty
                ? WorkReport.issueFields(for: update, current: current, statuses: statuses,
                                         progressID: settings.progressStatusID, doneID: settings.doneStatusID)
                : .init()
            return .merged(auto: auto, edit: edits[update.issue], current: current, statuses: statuses)
        }
        let known = Dictionary(uniqueKeysWithValues: updates.compactMap { update in store.log.issue(update.issue).map { (update.issue, $0) } })
        queue.async { [weak self] in
            var sent = 0
            var failures: [String] = []
            for update in updates {
                let result = Self.sendOne(update, base: base, key: key, known: known[update.issue], html: html, plan: plan)
                failures += result.failures
                if result.record != nil { sent += 1 }
                DispatchQueue.main.async { self?.apply(result, update: update) }
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
                } else if fields.isEmpty {
                    problem = "바뀐 칸이 없습니다"
                } else if let request = try? RedmineAPI.revertRequest(base: base, key: key, issue: issue, doneRatio: nil,
                                                                      statusID: fields.status?.id, startDate: fields.startDate,
                                                                      dueDate: fields.dueDate, assigneeID: fields.assignee?.id) {
                    let response = Self.perform(request)
                    if response.ok {
                        record = RedmineSent(issue: issue, entryIDs: [], note: "", before: Self.snapshot(fresh),
                                             after: Self.after(fields, ratio: nil))
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
                    self.store.setIssueState(issue, ratio: nil, fields: Self.fields(record.after, statuses: statuses))
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
    }

    /// 일감 하나: 지금 값을 새로 읽고 → 댓글·진척률·칸. 되돌릴 수 있게 보내기 전 값을 함께 남긴다.
    private static func sendOne(_ update: WorkReport.RedmineUpdate, base: URL, key: String, known: IssueInfo?, html: Bool,
                                plan: (WorkReport.RedmineUpdate, IssueInfo?) -> WorkReport.IssueFields) -> SendResult {
        var result = SendResult()
        guard update.needsNote else { return result }
        // 장부 값은 30분 묵을 수 있어, 바꿀 칸을 정하기 전에 지금 값을 받는다
        let fresh = (try? fetch(RedmineAPI.issueRequest(base: base, key: key, issue: update.issue)))
            .flatMap { try? RedmineAPI.parseIssues($0).first }
        let current = fresh.map { merge(known, $0) } ?? known
        let note = html ? RedmineNote.html(update.note) : update.note
        var extra = fresh == nil ? WorkReport.IssueFields() : plan(update, current)
        if let problem = extra.problem(current: current) {
            result.failures.append("#\(update.issue) \(problem)라 칸은 빼고 보냄")
            extra = .init()
        }
        var response = put(update, note: note, extra: extra, base: base, key: key)
        if response.status == 422 && !extra.isEmpty {
            // 워크플로가 막는 상태 전환이나 구성원이 아닌 담당자면 댓글까지 잃지 않게 칸을 빼고 다시 보낸다
            result.failures.append("#\(update.issue) 상태·날짜·담당자는 레드마인이 받지 않아 댓글과 진척률만 보냄")
            extra = .init()
            response = put(update, note: note, extra: extra, base: base, key: key)
        }
        guard response.ok else {
            result.failures.append("#\(update.issue) " + response.message)
            return result
        }
        let ratio = update.doneRatio == fresh?.doneRatio ? nil : update.doneRatio
        result.record = RedmineSent(issue: update.issue, entryIDs: update.entryIDs, note: note,
                                    before: fresh.map(snapshot) ?? .init(), after: after(extra, ratio: ratio))
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
                            base: URL, key: String) -> (ok: Bool, status: Int?, message: String, data: Data?) {
        guard let request = try? RedmineAPI.updateRequest(base: base, key: key, issue: update.issue, doneRatio: update.doneRatio,
                                                          note: note, fields: extra) else { return (false, nil, "요청을 만들지 못함", nil) }
        return perform(request)
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

    private func apply(_ result: SendResult, update: WorkReport.RedmineUpdate) {
        guard let record = result.record else { return }
        // 보낸 뒤 줄을 고쳐 다시 보낼 목록에 오르면, 방금 올린 댓글과 겹치는지 다시 보게 한다
        checkedNotes[update.issue] = nil
        store.markPosted(update.entryIDs)
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
            if revert.doneRatio != nil || revert.statusID != nil || revert.startDate != nil || revert.dueDate != nil || revert.assigneeID != nil,
               let request = try? RedmineAPI.revertRequest(base: base, key: key, issue: record.issue, doneRatio: revert.doneRatio,
                                                           statusID: revert.statusID, startDate: revert.startDate,
                                                           dueDate: revert.dueDate, assigneeID: revert.assigneeID) {
                let reverted = Self.perform(request)
                if !reverted.ok { problems.append("칸을 되돌리지 못했습니다 (\(reverted.message))") }
            }
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
                            problems.append("댓글을 지우지 못했습니다 (\(cleared.message))")
                            manual = journal.id
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
                self.store.markUndone(record)
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
