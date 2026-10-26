import AppKit

/// 소스로 설치한 앱의 업데이트. build-app.sh가 Info.plist에 남긴 클론 위치·커밋·저장소로 GitHub의 기본 브랜치와 견주고,
/// 새 커밋이 있으면 알린다. 업데이트는 그 클론에서 `git pull --ff-only && ./install.sh`를 앱과 떨어진 프로세스로 돌린다.
/// install.sh가 앱을 끄고 새 빌드를 띄우므로 업데이트는 앱이 꺼져도 끝까지 간다. 빌드가 실패하면 기존 앱이 그대로 남는다.
/// GitHub에는 공개 저장소의 커밋 비교만 묻고, 사용자 정보는 보내지 않는다. 메인 스레드에서만 쓴다.
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater(build: bundleBuild())

    /// 이 빌드의 출처. `swift run`처럼 install.sh를 거치지 않은 실행에는 없다.
    struct Build {
        let commit: String
        let subject: String
        let sourcePath: String
        /// GitHub 저장소 (owner/repo). GitHub가 아닌 원격에서 클론했으면 없다.
        let repo: String?
        let branch: String
        let dirty: Bool
    }

    enum State: Equatable {
        case unavailable(String)
        case idle
        case checking
        case upToDate
        case available(count: Int, latest: String)
        case updating
        case failed(String)
    }

    private enum Key {
        static let auto = "autoUpdate", lastCheck = "updateLastCheck"
        /// 업데이터가 설치를 시작한 대상 커밋. 다음에 켜졌을 때 "업데이트했어요"를 말할지 정한다.
        static let installing = "updateInstalling"
        /// 자동 업데이트가 실패한 대상 커밋. 같은 커밋으로는 다시 자동 시도하지 않는다.
        static let failedTarget = "updateFailedTarget"
        /// 설치하려고 앱을 끌 때 열려 있던 창. 새 빌드가 켜지면 다시 연다.
        static let reopen = "updateReopenWindows"
        /// 설치를 시작한 시각과 지난 설치에 걸린 시간. 남은 시간을 어림한다.
        static let startedAt = "updateStartedAt", lastDuration = "updateLastDuration"
        /// 자동 업데이트로 설치했는지. 자동 업데이트는 끝나도 말하지 않는다.
        static let silent = "updateSilent"
        /// 설치하는 버전에 든 커밋 제목. 설치를 마치면 패치노트로 옮긴다.
        static let installingNotes = "updateInstallingNotes"
        /// 러너 아래에 띄울 패치노트와 설치한 때. 닫을 때까지 남긴다.
        static let notes = "updatePatchNotes", notesAt = "updatePatchNotesAt"
    }

    private static let checkInterval: TimeInterval = 30 * 60
    /// 30분 확인과 따로 매일 이 시각에 꼭 확인한다. 잠자기로 놓쳤으면 깨어날 때 확인한다.
    private static let dailyHour = 9
    static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/RunTime/update.log")

    let build: Build?
    @Published private(set) var state: State
    @Published var autoUpdate: Bool { didSet { UserDefaults.standard.set(autoUpdate, forKey: Key.auto) } }
    /// 러너가 말풍선으로 알릴 업데이트 소식 (한 번만).
    private var bubble: String?
    private var windowsToReopen: [String] = []
    private var timer: Timer?
    private var dailyTimer: Timer?
    /// 지금 받을 수 있는 커밋. 있으면 러너가 누르면 업데이트하는 말풍선을 띄운다.
    @Published private(set) var target: String?
    /// 설치하는 동안 로그에서 읽은 진행 상황.
    @Published private(set) var progress: Progress?
    private var progressTimer: Timer?
    /// 이번 설치 기록이 로그 파일에서 시작하는 자리.
    private var logOffset: UInt64 = 0
    /// 받을 변경의 제목들 (최근 것부터 5개, "feat: " 같은 머리말은 뺀다).
    @Published private(set) var incoming: [String] = []
    /// 받을 커밋의 첫 줄 전부 (오래된 것부터). 설치할 때 패치노트 재료로 남긴다.
    private var incomingLines: [String] = []
    /// 업데이트 뒤 러너 아래에 띄울 패치노트. 닫으면 nil.
    @Published private(set) var patchNotes: PatchNotes?
    /// 패치노트는 며칠 지나면 새 소식이 아니라 저절로 거둔다.
    private static let notesLifetime: TimeInterval = 3 * 24 * 60 * 60
    /// 새 버전은 있지만 클론 사정(고친 파일, 다른 브랜치)으로 미룬 까닭. 실패가 아니라 다음 확인 때 다시 해 본다.
    @Published private(set) var blocked: String?
    private var blockedAt: Date?
    /// 팝오버나 창을 지금 쓰고 있는지. 자동 업데이트는 설치 중에 앱이 꺼지므로 쓰지 않을 때만 한다 (게임도 팝오버 안에서만 한다).
    var isInUse: () -> Bool = { false }
    /// 지금 열려 있는 창의 이름. 업데이트로 앱이 다시 켜지면 이 창들을 다시 연다.
    var openWindows: () -> [String] = { [] }

    private static func bundleBuild() -> Build? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let commit = info["RunTimeCommitSHA"] as? String, let path = info["RunTimeSourcePath"] as? String
        else { return nil }
        return Build(commit: commit, subject: info["RunTimeCommitSubject"] as? String ?? "", sourcePath: path,
                     repo: info["RunTimeRepo"] as? String, branch: info["RunTimeBranch"] as? String ?? "main",
                     dirty: info["RunTimeDirty"] as? Bool ?? false)
    }

    /// 앱은 `shared`를 쓴다. 다른 빌드 정보로 만드는 것은 점검용이다.
    init(build: Build?) {
        self.build = build
        autoUpdate = UserDefaults.standard.bool(forKey: Key.auto)
        if build == nil {
            state = .unavailable("install.sh로 설치한 앱에서만 업데이트를 확인합니다.")
        } else if build?.repo == nil {
            state = .unavailable("GitHub에서 클론하지 않아 업데이트를 확인할 수 없습니다.")
        } else {
            state = .idle
        }
    }

    var canCheck: Bool {
        if case .unavailable = state { return false }
        return true
    }

    /// 자동으로 받지 못한 새 버전이 있다 (자동 업데이트를 꺼 두었거나, 실패했거나, 클론 사정으로 미뤘다).
    /// 자동 업데이트가 켜져 있고 창을 닫으면 곧 받을 것이면 알리지 않는다.
    var hasPendingUpdate: Bool {
        guard target != nil, canCheck, state != .updating, state != .checking else { return false }
        if installFailed { return true }
        return !autoUpdate || blocked != nil || UserDefaults.standard.string(forKey: Key.failedTarget) == target
    }

    /// 지금 설치가 자동 업데이트인지. 자동 업데이트는 무대에 진행 판을 띄우지 않고 조용히 한다.
    @Published private(set) var isSilent = false
    /// 마지막 실패가 설치 실패인지 (확인 실패는 다음 확인 때 저절로 다시 하므로 알리지 않는다).
    @Published private(set) var installFailed = false

    /// 앱이 켜질 때. 업데이트 뒤 처음 켜진 것이면 알리고, 잠시 뒤부터 30분마다 확인한다.
    func start() {
        guard let build else { return }
        let defaults = UserDefaults.standard
        // 업데이터가 설치한 뒤 처음 켜졌을 때만 (직접 다른 커밋을 설치한 경우는 말하지 않는다)
        if defaults.string(forKey: Key.installing) != nil {
            defaults.removeObject(forKey: Key.installing)
            windowsToReopen = defaults.stringArray(forKey: Key.reopen) ?? []
            defaults.removeObject(forKey: Key.reopen)
            // 자동 업데이트도 무엇이 바뀌었는지는 알린다. 패치노트를 만들 수 없을 때만 한 줄로 말한다
            let lines = defaults.stringArray(forKey: Key.installingNotes) ?? []
            defaults.removeObject(forKey: Key.installingNotes)
            if PatchNotes.make(from: lines) != nil {
                defaults.set(lines, forKey: Key.notes)
                defaults.set(Date().timeIntervalSince1970, forKey: Key.notesAt)
            } else if !defaults.bool(forKey: Key.silent) {
                bubble = build.subject.isEmpty ? "새 버전으로 업데이트했어요" : "업데이트했어요: \(Self.title(of: build.subject))"
            }
            defaults.removeObject(forKey: Key.silent)
            let started = defaults.double(forKey: Key.startedAt)
            // 앱이 꺼져 있던 시간이 섞인 값(10분 넘음)은 어림에 쓰지 않는다
            if started > 0, case let took = Date().timeIntervalSince1970 - started, took > 10, took < 600 {
                defaults.set(took, forKey: Key.lastDuration)
            }
            defaults.removeObject(forKey: Key.startedAt)
            Diagnostics.record("업데이트", "설치 완료: \(build.commit.prefix(7)) \(build.subject)")
        }
        loadPatchNotes()
        guard canCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduleDaily()
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            // 잠든 사이 지난 타이머는 깨어난 뒤 늦게 울리거나 건너뛰어서 다음 9시를 다시 잡는다
            self?.scheduleDaily()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.checkIfStale() }
        }
    }

    private func scheduleDaily() {
        dailyTimer?.invalidate()
        guard let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: Self.dailyHour, minute: 0),
                                                   matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.check()
            self?.scheduleDaily()
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    /// 팝오버를 열 때, 잠자기에서 깨어났을 때. 확인이 30분 넘게 밀렸거나 오늘 9시 확인을 놓쳤으면 다시 본다.
    func checkIfStale() {
        let last = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Key.lastCheck))
        if Date().timeIntervalSince(last) > Self.checkInterval || Self.missedDaily(lastCheck: last) { check() }
    }

    static func missedDaily(lastCheck: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let today = calendar.date(bySettingHour: dailyHour, minute: 0, second: 0, of: now) else { return false }
        return now >= today && lastCheck < today
    }

    /// 업데이트 직전에 열려 있던 창 (한 번만).
    func takeWindowsToReopen() -> [String] {
        defer { windowsToReopen = [] }
        return windowsToReopen
    }

    private func loadPatchNotes() {
        let defaults = UserDefaults.standard
        let at = defaults.double(forKey: Key.notesAt)
        guard at > 0, Date().timeIntervalSince1970 - at < Self.notesLifetime,
              let notes = PatchNotes.make(from: defaults.stringArray(forKey: Key.notes) ?? [])
        else {
            dismissPatchNotes()
            return
        }
        patchNotes = notes
    }

    func dismissPatchNotes() {
        patchNotes = nil
        UserDefaults.standard.removeObject(forKey: Key.notes)
        UserDefaults.standard.removeObject(forKey: Key.notesAt)
    }

    func takeBubble() -> String? {
        defer { bubble = nil }
        return bubble
    }

    // MARK: 확인

    private struct Comparison: Decodable {
        struct Commit: Decodable {
            struct Detail: Decodable { let message: String }
            let sha: String
            let commit: Detail
        }

        let status: String
        let aheadBy: Int
        let commits: [Commit]

        enum CodingKeys: String, CodingKey {
            case status, commits
            case aheadBy = "ahead_by"
        }
    }

    func check() {
        guard let build, let repo = build.repo, canCheck, state != .checking, state != .updating else { return }
        state = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.lastCheck)
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/compare/\(build.commit)...\(build.branch)") else {
            state = .failed("저장소 주소가 올바르지 않습니다.")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RunTime", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let comparison = data.flatMap { try? JSONDecoder().decode(Comparison.self, from: $0) }
            DispatchQueue.main.async { self.finishCheck(comparison, status: status, failed: error != nil) }
        }.resume()
    }

    private func finishCheck(_ comparison: Comparison?, status: Int, failed: Bool) {
        // 확인하는 사이 업데이트를 눌렀으면 설치 상태를 덮지 않는다
        guard state == .checking else { return }
        // 404는 아직 푸시하지 않은 커밋으로 만든 빌드다. GitHub보다 앞서 있으니 받을 것이 없다
        if status == 404 {
            state = .upToDate
            target = nil
            installFailed = false
            return
        }
        guard let comparison, status == 200 else {
            let reason = failed ? "GitHub에 연결하지 못했습니다." : "확인하지 못했습니다 (HTTP \(status))."
            // 30분마다 같은 까닭으로 쌓이지 않게 바뀔 때만 남긴다
            if state != .failed(reason) { Diagnostics.record("업데이트", "확인 실패: \(reason)") }
            state = .failed(reason)
            return
        }
        // ahead: 기본 브랜치가 이 빌드보다 앞섬. diverged·behind는 이 빌드에 기본 브랜치에 없는 커밋이 있는 개발 빌드다
        guard comparison.status == "ahead", comparison.aheadBy > 0 else {
            state = .upToDate
            target = nil
            installFailed = false
            return
        }
        let latest = comparison.commits.last?.commit.message.components(separatedBy: "\n").first ?? ""
        incoming = comparison.commits.suffix(5).reversed().map { Self.title(of: $0.commit.message) }
        incomingLines = comparison.commits.map { $0.commit.message.components(separatedBy: "\n").first ?? "" }
        let newTarget = comparison.commits.last?.sha
        let isNew = newTarget != target
        target = newTarget
        state = .available(count: comparison.aheadBy, latest: latest)
        if isNew {
            blocked = nil
            installFailed = false
        }
        // 자동으로 받지 못한 새 버전은 러너가 누르면 업데이트하는 말풍선으로 알린다 (hasPendingUpdate)
        if autoUpdate, newTarget != UserDefaults.standard.string(forKey: Key.failedTarget) {
            applyAutoUpdateIfIdle()
        }
    }

    /// 러너 말풍선 글. 누르면 `update()`.
    var pendingPrompt: String {
        if installFailed { return "업데이트하지 못했어요 · 눌러서 다시" }
        if blocked != nil { return "새 버전을 기다리는 중 · 눌러서 다시" }
        return "새 버전이 있어요 · 눌러서 업데이트"
    }

    /// 커밋 메시지 첫 줄에서 "feat: ", "fix(ui): " 같은 머리말을 뺀다.
    static func title(of message: String) -> String {
        let line = message.components(separatedBy: "\n").first ?? ""
        guard let range = line.range(of: #"^[a-z]+(\([^)]*\))?!?:\s*"#, options: .regularExpression) else { return line }
        return String(line[range.upperBound...])
    }

    /// 팝오버나 앱 창이 닫히거나 다른 앱으로 넘어갔을 때 미뤄 둔 자동 업데이트를 적용한다.
    /// 팝오버를 닫고 설정·파일 창을 여는 중일 수 있어, 그 창이 뜬 뒤에 다시 본다.
    func appClosedWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.applyAutoUpdateIfIdle() }
    }

    private func applyAutoUpdateIfIdle() {
        guard autoUpdate, case .available = state, !isInUse(),
              target != UserDefaults.standard.string(forKey: Key.failedTarget) else { return }
        // 미룬 업데이트는 창을 닫을 때마다 git을 돌리지 않게 10분에 한 번만 다시 본다
        if let blockedAt, Date().timeIntervalSince(blockedAt) < 10 * 60 { return }
        update(automatic: true)
    }

    // MARK: 업데이트

    /// 클론이 깨끗하고 기본 브랜치에 있을 때만 받는다. 직접 고친 파일이 있으면 덮어쓰지 않고 멈춘다.
    func update(automatic: Bool = false) {
        // 확인 중에 받으면 그 응답이 버려져, 미룰 때 .checking으로 돌아가 다시는 확인하지 못한다
        guard let build, canCheck, state != .updating, state != .checking else { return }
        // .updating으로 바꾸기 전에 잡아 둬야 미룰 때 원래 상태로 돌아간다 (안 그러면 설치 중에 멈춰 확인도 다시 못 한다)
        let previous = state
        isSilent = automatic
        installFailed = false
        state = .updating
        progress = Progress(fraction: 0.02, step: "준비하는 중", remaining: nil)
        let target = target
        DispatchQueue.global(qos: .utility).async {
            let problem = Self.checkClone(build)
            DispatchQueue.main.async {
                switch problem {
                case .none:
                    self.blocked = nil
                    self.blockedAt = nil
                    self.launchInstall(build, target: target, automatic: automatic)
                case .busy(let reason)?:
                    // 개발 중인 클론은 그대로 두고, 같은 저장소의 업데이트 전용 worktree에서 GitHub 최신을 빌드한다
                    Diagnostics.record("업데이트", "\(reason) 업데이트 전용 폴더에서 설치")
                    self.blocked = nil
                    self.blockedAt = nil
                    self.launchInstall(build, target: target, automatic: automatic, inWorktree: true)
                case .wait(let reason)?:
                    // 개발 중인 클론은 실패로 남기지 않는다. 커밋하거나 브랜치를 돌려 놓으면 다음 확인 때 받는다
                    Diagnostics.record("업데이트", "미룸: \(reason)")
                    self.blocked = reason
                    self.blockedAt = Date()
                    self.progress = nil
                    self.state = previous
                case .broken(let reason)?:
                    self.fail(reason, target: target, automatic: automatic)
                }
            }
        }
    }

    private func fail(_ reason: String, target: String?, automatic: Bool) {
        Diagnostics.record("업데이트", (automatic ? "자동 " : "") + "실패: \(reason)")
        state = .failed(reason)
        installFailed = true
        stopProgress()
        UserDefaults.standard.removeObject(forKey: Key.installing)
        UserDefaults.standard.removeObject(forKey: Key.reopen)
        UserDefaults.standard.removeObject(forKey: Key.startedAt)
        UserDefaults.standard.removeObject(forKey: Key.silent)
        UserDefaults.standard.removeObject(forKey: Key.installingNotes)
        // 눌러서 받다 실패한 버전도 자동으로 다시 빌드하지 않는다. 말풍선을 눌러 다시 할 수 있다
        if let target { UserDefaults.standard.set(target, forKey: Key.failedTarget) }
    }

    private enum CloneProblem {
        /// 사용자가 클론에서 일하는 중이다 (다른 브랜치, 커밋하지 않은 변경, 푸시하지 않은 커밋). 전용 폴더에서 설치한다.
        case busy(String)
        /// 잠시 미룬다.
        case wait(String)
        /// 손대지 않으면 계속 안 되는 문제.
        case broken(String)
    }

    private static func checkClone(_ build: Build) -> CloneProblem? {
        let path = build.sourcePath
        guard FileManager.default.fileExists(atPath: path + "/install.sh") else {
            return .broken("설치할 때 쓴 폴더(\(path))가 없습니다. 다시 클론해서 ./install.sh를 실행하세요.")
        }
        guard let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: path) else {
            return .broken("git을 실행하지 못했습니다.")
        }
        guard !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Caches/RunTime/install.lock") else {
            return .wait("다른 설치가 진행 중이라 끝난 뒤 받습니다.")
        }
        // 업데이트 전용 폴더에서 설치한 빌드는 늘 그 폴더에서 다시 받는다 (브랜치 없이 커밋을 꺼내 두므로)
        if path == worktreePath { return .busy("업데이트 전용 폴더에서 설치한 빌드라") }
        guard branch == build.branch else { return .busy("클론이 \(branch) 브랜치에 있어") }
        guard git(["status", "--porcelain", "--untracked-files=no"], in: path)?.isEmpty == true else {
            return .busy("클론에 커밋하지 않은 변경이 있어")
        }
        // pull --ff-only가 로그에만 남기고 실패하지 않게, 갈라진 클론은 먼저 가린다
        guard git(["fetch", "--quiet", "origin", build.branch], in: path) != nil else {
            return .wait("GitHub에서 받아 오지 못했습니다. 연결되면 다시 해 봅니다.")
        }
        guard git(["merge-base", "--is-ancestor", "HEAD", "FETCH_HEAD"], in: path) != nil
                || git(["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"], in: path) != nil else {
            return .busy("클론에 GitHub에 없는 커밋이 있어")
        }
        return nil
    }

    /// 마지막 업데이트 기록에서 까닭이 적힌 줄 (`✗ …`, `error: …`, `fatal: …`).
    static func failureReason(inLog text: String) -> String? {
        let attempt = text.components(separatedBy: "\n== ").last ?? text
        return attempt.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { line in ["✗", "error:", "fatal:"].contains { line.contains($0) } }
            .map { String($0.prefix(140)) }
    }

    private static func git(_ arguments: [String], in path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 앱과 떨어진 셸로 받고 빌드한다. 출력은 로그 파일로 보내 앱이 꺼져도 끊기지 않게 한다.
    /// 개발 클론이 작업 중일 때 빌드하는 곳. 개발 클론과 같은 저장소를 쓰는 worktree다.
    static let worktreePath = NSHomeDirectory() + "/Library/Application Support/RunTime/update-source"

    private func launchInstall(_ build: Build, target: String?, automatic: Bool, inWorktree: Bool = false) {
        try? FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let branch = quote(build.branch)
        let install: String
        if inWorktree {
            // 원격 브랜치만 새로 받아 전용 폴더에 꺼낸다. 개발 클론의 작업 파일·브랜치는 건드리지 않는다
            let worktree = quote(Self.worktreePath)
            install = """
            cd \(quote(build.sourcePath)) && git fetch origin "+refs/heads/"\(branch)":refs/remotes/origin/"\(branch) \\
              && { [ -e \(worktree)/.git ] || { git worktree prune && git worktree add --detach \(worktree) origin/\(branch); }; } \\
              && cd \(worktree) && git checkout --detach --force origin/\(branch) && ./install.sh
            """
        } else {
            install = "cd \(quote(build.sourcePath)) && git pull --ff-only origin \(branch) && ./install.sh"
        }
        let script = """
        exec >> \(quote(Self.logURL.path)) 2>&1
        echo "== $(date) 업데이트 시작\(inWorktree ? " (업데이트 전용 폴더)" : "")"
        \(install)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 사용자 셸 설정(~/.zshenv)이 섞이지 않게 -f, 자격 증명을 묻느라 멈추지 않게 GIT_TERMINAL_PROMPT=0
        process.arguments = ["-f", "-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        UserDefaults.standard.set(target ?? build.commit, forKey: Key.installing)
        UserDefaults.standard.set(automatic, forKey: Key.silent)
        UserDefaults.standard.set(Array(incomingLines.suffix(30)), forKey: Key.installingNotes)
        UserDefaults.standard.set(openWindows(), forKey: Key.reopen)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.startedAt)
        logOffset = ((try? FileManager.default.attributesOfItem(atPath: Self.logURL.path))?[.size] as? UInt64) ?? 0
        startProgress()
        Diagnostics.record("업데이트", (automatic ? "자동 " : "") + "설치 시작: \(build.commit.prefix(7)) → \((target ?? "").prefix(7))")
        // install.sh가 성공하면 이 앱은 꺼지고 새 빌드가 뜬다. 여기로 돌아왔다면 실패한 것이다
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                if finished.terminationStatus == 0 {
                    // install.sh가 이 앱을 끄지 못했다. 설치 중에 멈춰 있지 않게 돌려 두고 다시 확인한다
                    guard self.state == .updating else { return }
                    Diagnostics.record("업데이트", "설치는 끝났지만 앱이 꺼지지 않았습니다")
                    self.stopProgress()
                    self.state = .idle
                    UserDefaults.standard.removeObject(forKey: Key.startedAt)
                    self.check()
                } else {
                    let log = (try? String(contentsOf: Self.logURL, encoding: .utf8)) ?? ""
                    let reason = Self.failureReason(inLog: log).map { "업데이트에 실패했습니다: \($0)" }
                        ?? "업데이트에 실패했습니다. 로그: \(Self.logURL.path)"
                    self.fail(reason, target: target, automatic: automatic)
                }
            }
        }
        do {
            try process.run()
        } catch {
            fail("업데이트를 시작하지 못했습니다.", target: target, automatic: automatic)
        }
    }

    // MARK: 진행 상황

    struct Progress: Equatable {
        /// 0~1. 뒤로 가지 않는다.
        var fraction: Double
        var step: String
        /// 남은 시간 어림 (초).
        var remaining: TimeInterval?
    }

    /// install.sh·build-app.sh가 남기는 줄로 단계를 나눈다. swift build의 `[12 / 56]`은 빌드 안의 진행이다.
    /// 분모가 빌드 계획이 늘며 커지므로 값이 잠깐 줄 수 있어, 쓰는 쪽에서 큰 값만 받는다.
    static func progress(inLog text: String) -> (fraction: Double, step: String) {
        var result = (fraction: 0.02, step: "준비하는 중")
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("== ") {
                result = (0.04, "새 코드 받는 중")
            } else if line.hasPrefix("RunTime 설치를 시작합니다") {
                result = (0.08, "빌드 준비 중")
            } else if line.hasPrefix("▸ release 빌드") {
                result = (0.1, "빌드하는 중")
            } else if line.hasPrefix("Build complete") {
                result = (0.86, "앱으로 묶는 중")
            } else if line.hasPrefix("▸ 서명") {
                result = (0.88, "서명하는 중")
            } else if line.hasPrefix("▸ dmg") {
                result = (0.92, "마무리하는 중")
            } else if line.hasPrefix("✓ 완료: dist/") {  // setup-signing.sh도 "✓ 완료:"를 찍는다
                result = (0.97, "새 버전으로 다시 켜는 중")
            } else if let match = line.firstMatch(of: #/^\[(\d+) / (\d+)\]/#),
                      let done = Double(match.1), let total = Double(match.2), total > 0 {
                result = (0.1 + 0.75 * min(done / total, 1), "빌드하는 중")
            }
        }
        return result
    }

    /// 남은 시간. 지난 설치 시간과 지금 속도로 잰 값을 섞는다. 처음엔 진행률이 거칠어 지난 시간을 더 믿는다.
    static func remaining(fraction: Double, elapsed: TimeInterval, typical: TimeInterval) -> TimeInterval {
        let byHistory = typical - elapsed
        guard fraction >= 0.2 else { return max(byHistory, 5) }
        let bySpeed = elapsed / fraction * (1 - fraction)
        return max((byHistory + bySpeed) / 2, 3)
    }

    /// 화면 점검(--ui-shots)용. 받지 않고 말풍선이나 진행 판이 뜬 상태로만 둔다.
    func rehearsePatchNotes() {
        patchNotes = PatchNotes.make(from: [
            "feat: 피그마 연동으로 알림 기능 및 diff 비교 기능 추가 ( 피그마 화면설계서에서 바뀐 화면 보기)",
            "fix: 레드마인 일감을 다시 읽지 못할 때 보낸 것으로 잘못 남기는 문제",
            "refactor: 레드마인 반영 기능 고도화",
            "feat: 자동업데이트 게이지 추가, 실패시 말풍선 기능 추가",
            "docs: README 그림 바꾸기",
        ])
    }

    func rehearse(progress: Progress?) {
        target = "rehearsal"
        incoming = ["업데이트 진행 막대", "매일 9시 업데이트 확인"]
        state = progress == nil ? .available(count: 2, latest: "feat: 업데이트 진행 막대") : .updating
        self.progress = progress
    }

    private func startProgress() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.readProgress() }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        progress = nil
    }

    private func readProgress() {
        guard state == .updating, let handle = try? FileHandle(forReadingFrom: Self.logURL) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: logOffset)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let (fraction, step) = Self.progress(inLog: text)
        let defaults = UserDefaults.standard
        let elapsed = Date().timeIntervalSince1970 - defaults.double(forKey: Key.startedAt)
        let typical = defaults.double(forKey: Key.lastDuration)
        let best = max(fraction, progress?.fraction ?? 0)
        progress = Progress(fraction: best, step: step,
                            remaining: Self.remaining(fraction: best, elapsed: elapsed, typical: typical > 0 ? typical : 100))
    }
}
