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
    /// 레드마인에 보낼 때 작업 시간도 남길지와 그 작업 분류.
    @Published var logTime: Bool { didSet { defaults.set(logTime, forKey: "workLog.logTime") } }
    @Published var activityID: Int? { didSet { defaults.set(activityID ?? 0, forKey: "workLog.activityID") } }
    @Published private(set) var hasTeamsWebhook: Bool
    /// 보고서 꼴: 상시 → 완료 → 진행 순서, 주간 보고 끝에 차주 계획.
    @Published var doneFirst: Bool { didSet { defaults.set(doneFirst, forKey: "workLog.doneFirst") } }
    @Published var weeklyPlan: Bool { didSet { defaults.set(weeklyPlan, forKey: "workLog.weeklyPlan") } }
    @Published var dailyHeader: Bool { didSet { defaults.set(dailyHeader, forKey: "workLogReportHeader") } }
    /// ⌃⌥L로 어디서든 한 줄 적기.
    @Published var quickAddEnabled: Bool { didSet { defaults.set(quickAddEnabled, forKey: "workLog.quickAdd") } }

    private init() {
        gitlabHost = defaults.string(forKey: "workLog.gitlabHost") ?? Self.detectGitLabHost() ?? ""
        captureEnabled = defaults.object(forKey: "workLog.capture") as? Bool ?? false
        repoFolder = defaults.string(forKey: "workLog.repoFolder") ?? (NSHomeDirectory() + "/GitHub")
        redmineURL = defaults.string(forKey: "workLog.redmineURL") ?? ""
        reminderEnabled = defaults.object(forKey: "workLog.reminder") as? Bool ?? false
        reminderMinutes = defaults.object(forKey: "workLog.reminderMinutes") as? Int ?? 18 * 60
        // 값을 읽지 않고 있는지만 본다 (값을 읽으면 다른 서명의 빌드에서 키체인 창이 뜬다)
        hasRedmineKey = !Self.keychainOff && Keychain.exists(Self.keyAccount)
        logTime = defaults.object(forKey: "workLog.logTime") as? Bool ?? false
        let activity = defaults.integer(forKey: "workLog.activityID")
        activityID = activity > 0 ? activity : nil
        hasTeamsWebhook = !Self.keychainOff && Keychain.exists(Self.teamsAccount)
        teamsHint = defaults.string(forKey: "workLog.teamsHost")
        doneFirst = defaults.object(forKey: "workLog.doneFirst") as? Bool ?? true
        weeklyPlan = defaults.object(forKey: "workLog.weeklyPlan") as? Bool ?? false
        dailyHeader = defaults.object(forKey: "workLogReportHeader") as? Bool ?? false
        quickAddEnabled = defaults.object(forKey: "workLog.quickAdd") as? Bool ?? true
    }

    private static let keyAccount = "redmine-api-key"
    private static let teamsAccount = "teams-webhook"

    /// 웹훅 주소는 아는 사람 누구나 채널에 글을 올릴 수 있어 키체인에 둔다.
    var teamsWebhook: URL? {
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

    var redmineReady: Bool { RedmineAPI.baseURL(redmineURL) != nil && hasRedmineKey }

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
    private static let service = "dev.runtime.RunTime.worklog"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 있으면 값만 바꾸고 없을 때만 새로 만든다. 지우고 다시 만들면 만들기가 실패할 때 옛 키까지 잃는다.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
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
    static func exists(_ account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
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
    /// 나에게 배정된 열린 일감. 일감 고르기와 지금 진척률 보기에 쓴다.
    @Published private(set) var myIssues: [RedmineAPI.Issue] = []
    @Published private(set) var issuesError: String?
    /// 보낼 일감의 지금 제목·진척률. 내 열린 일감 목록에 없는 것(남이 맡았거나 닫힌 일감)도 하나씩 받아 둔다.
    @Published private(set) var issueInfo: [Int: RedmineAPI.Issue] = [:]
    private var requestedInfo: Set<Int> = []
    @Published private(set) var sending = false
    @Published private(set) var activities: [RedmineAPI.Activity] = []
    @Published private(set) var postingTeams = false
    /// 그날 폴더별 Claude Code 사용 분. AppDelegate가 사용량 기록에서 이어 준다.
    var minutesByFolder: (String) -> [String: Int] = { _ in [:] }

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

    func loadMyIssues() {
        guard let base = RedmineAPI.baseURL(settings.redmineURL), let key = settings.redmineKey else { return }
        URLSession.shared.dataTask(with: RedmineAPI.myIssuesRequest(base: base, key: key)) { [weak self] data, response, error in
            let result = Result { () -> [RedmineAPI.Issue] in
                if let error { throw error }
                try Self.check(response)
                return try RedmineAPI.parseIssues(data ?? Data())
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let issues):
                    self?.myIssues = issues
                    self?.issuesError = nil
                    for issue in issues { self?.issueInfo[issue.id] = issue }
                case .failure(let error):
                    self?.issuesError = error.localizedDescription
                }
            }
        }.resume()
    }

    func loadActivities() {
        guard let base = RedmineAPI.baseURL(settings.redmineURL), let key = settings.redmineKey else { return }
        URLSession.shared.dataTask(with: RedmineAPI.activitiesRequest(base: base, key: key)) { [weak self] data, response, _ in
            guard (try? Self.check(response)) != nil, let list = try? RedmineAPI.parseActivities(data ?? Data()) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.activities = list
                if self.settings.activityID == nil || !list.contains(where: { $0.id == self.settings.activityID }) {
                    self.settings.activityID = (list.first(where: \.isDefault) ?? list.first)?.id
                }
            }
        }.resume()
    }

    /// 그날 일감별로 아직 남기지 않은 작업 시간 어림값 (Claude Code를 쓴 폴더 기준, 이미 남긴 시간은 뺌).
    func suggestedHours(on day: String, entries: [WorkEntry]) -> [Int: Double] {
        WorkTime.remaining(entries.filter { $0.day == day }, minutesByFolder: minutesByFolder(day))
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
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let message: String? = error?.localizedDescription ?? ((try? Self.check(response)) == nil ? Self.statusText(response) : nil)
            DispatchQueue.main.async {
                self?.postingTeams = false
                done(message)
            }
        }.resume()
    }

    func loadInfo(_ ids: [Int]) {
        guard let base = RedmineAPI.baseURL(settings.redmineURL), let key = settings.redmineKey else { return }
        for id in ids where issueInfo[id] == nil && !requestedInfo.contains(id) {
            requestedInfo.insert(id)
            URLSession.shared.dataTask(with: RedmineAPI.issueRequest(base: base, key: key, issue: id)) { [weak self] data, response, _ in
                guard (try? Self.check(response)) != nil, let issue = (try? RedmineAPI.parseIssues(data ?? Data()))?.first else { return }
                DispatchQueue.main.async { self?.issueInfo[id] = issue }
            }.resume()
        }
    }

    /// 일감마다 차례로: 댓글·진척률을 보내야 하면 먼저 보내고, 그 다음 날짜별 작업 시간을 남긴다. 상태는 바꾸지 않는다.
    /// 댓글이 올라가면 시간이 실패해도 보냄으로 표시하고, 시간은 다음에 시간만 다시 남긴다 (댓글을 또 올리지 않게).
    func send(_ updates: [WorkReport.RedmineUpdate], done: @escaping (_ sent: Int, _ failures: [String]) -> Void) {
        guard !sending else {
            done(0, ["이미 보내는 중입니다"])
            return
        }
        guard let base = RedmineAPI.baseURL(settings.redmineURL), let key = settings.redmineKey else {
            done(0, ["레드마인 주소(https)와 API 키를 설정하세요"])
            return
        }
        sending = true
        var remaining = updates
        var sent = 0
        var failures: [String] = []
        let logTime = settings.logTime
        let activityID = settings.activityID

        func finish() {
            sending = false
            loadMyIssues()
            done(sent, failures)
        }

        func next() {
            guard !remaining.isEmpty else { return finish() }
            let update = remaining.removeFirst()
            let times = logTime ? update.timeEntries : []
            if update.needsNote {
                putNote(update) { ok in
                    guard ok else { return next() }
                    sent += 1
                    logTimes(update, times, then: next)
                }
            } else {
                if !times.isEmpty { sent += 1 }
                logTimes(update, times, then: next)
            }
        }

        func putNote(_ update: WorkReport.RedmineUpdate, then: @escaping (Bool) -> Void) {
            guard let request = try? RedmineAPI.updateRequest(base: base, key: key, issue: update.issue,
                                                              doneRatio: update.doneRatio, note: update.note) else {
                failures.append("#\(update.issue)")
                return then(false)
            }
            URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                let ok = error == nil && (try? Self.check(response)) != nil
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok {
                        self.store.markPosted(update.entryIDs)
                        // 보낸 뒤 진척률을 다시 받아 화면이 새 값을 보이게
                        self.issueInfo[update.issue] = nil
                        self.requestedInfo.remove(update.issue)
                    } else {
                        failures.append("#\(update.issue) " + (error?.localizedDescription ?? Self.statusText(response)))
                    }
                    then(ok)
                }
            }.resume()
        }

        func logTimes(_ update: WorkReport.RedmineUpdate, _ times: [WorkReport.TimeEntry], then: @escaping () -> Void) {
            guard let time = times.first else { return then() }
            guard let request = try? RedmineAPI.timeEntryRequest(base: base, key: key, issue: update.issue, spentOn: time.day,
                                                                 hours: time.hours, activityID: activityID,
                                                                 comments: Self.firstLine(update.note)) else {
                return logTimes(update, Array(times.dropFirst()), then: then)
            }
            URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                let ok = error == nil && (try? Self.check(response)) != nil
                DispatchQueue.main.async {
                    if ok {
                        self?.store.markTimeLogged(time.entryIDs)
                    } else {
                        failures.append("#\(update.issue) \(WorkReport.shortDate(time.day)) 작업 시간 "
                                        + (error?.localizedDescription ?? Self.statusText(response)))
                    }
                    logTimes(update, Array(times.dropFirst()), then: then)
                }
            }.resume()
        }

        next()
    }

    /// 작업 시간 설명: 댓글 [작업 내용]의 첫 항목.
    static func firstLine(_ note: String) -> String {
        let line = note.components(separatedBy: "\n").first { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        return line ?? note.components(separatedBy: "\n").first ?? ""
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
