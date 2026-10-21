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
    }

    private static let checkInterval: TimeInterval = 30 * 60
    static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/RunTime/update.log")

    let build: Build?
    @Published private(set) var state: State
    @Published var autoUpdate: Bool { didSet { UserDefaults.standard.set(autoUpdate, forKey: Key.auto) } }
    /// 러너가 말풍선으로 알릴 업데이트 소식 (한 번만).
    private var bubble: String?
    private var timer: Timer?
    /// 지금 받을 수 있는 커밋.
    private var target: String?
    /// 받을 변경의 제목들 (최근 것부터 5개, "feat: " 같은 머리말은 뺀다).
    @Published private(set) var incoming: [String] = []
    /// 새 버전은 있지만 클론 사정(고친 파일, 다른 브랜치)으로 미룬 까닭. 실패가 아니라 다음 확인 때 다시 해 본다.
    @Published private(set) var blocked: String?
    private var blockedAt: Date?
    /// 팝오버가 열려 있는지. 자동 업데이트는 설치 중에 앱이 꺼지므로 닫혀 있을 때만 한다 (게임도 팝오버 안에서만 한다).
    var isInUse: () -> Bool = { false }

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

    /// 앱이 켜질 때. 업데이트 뒤 처음 켜진 것이면 알리고, 잠시 뒤부터 30분마다 확인한다.
    func start() {
        guard let build else { return }
        let defaults = UserDefaults.standard
        // 업데이터가 설치한 뒤 처음 켜졌을 때만 (직접 다른 커밋을 설치한 경우는 말하지 않는다)
        if defaults.string(forKey: Key.installing) != nil {
            defaults.removeObject(forKey: Key.installing)
            bubble = build.subject.isEmpty ? "새 버전으로 업데이트했어요" : "업데이트했어요: \(Self.title(of: build.subject))"
            Diagnostics.record("업데이트", "설치 완료: \(build.commit.prefix(7)) \(build.subject)")
        }
        guard canCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 팝오버를 열 때. 잠자기에서 깨어나 확인이 밀렸으면 다시 본다.
    func checkIfStale() {
        let last = UserDefaults.standard.double(forKey: Key.lastCheck)
        if Date().timeIntervalSince1970 - last > Self.checkInterval { check() }
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
        // 404는 아직 푸시하지 않은 커밋으로 만든 빌드다. GitHub보다 앞서 있으니 받을 것이 없다
        if status == 404 {
            state = .upToDate
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
            return
        }
        let latest = comparison.commits.last?.commit.message.components(separatedBy: "\n").first ?? ""
        incoming = comparison.commits.suffix(5).reversed().map { Self.title(of: $0.commit.message) }
        let newTarget = comparison.commits.last?.sha
        let isNew = newTarget != target
        target = newTarget
        state = .available(count: comparison.aheadBy, latest: latest)
        if isNew { blocked = nil }
        if autoUpdate, newTarget != UserDefaults.standard.string(forKey: Key.failedTarget) {
            applyAutoUpdateIfIdle()
        } else if isNew {
            bubble = "새 버전이 있어요: \(Self.title(of: latest))"
        }
    }

    /// 커밋 메시지 첫 줄에서 "feat: ", "fix(ui): " 같은 머리말을 뺀다.
    static func title(of message: String) -> String {
        let line = message.components(separatedBy: "\n").first ?? ""
        guard let range = line.range(of: #"^[a-z]+(\([^)]*\))?!?:\s*"#, options: .regularExpression) else { return line }
        return String(line[range.upperBound...])
    }

    /// 팝오버나 앱 창이 닫혔을 때 미뤄 둔 자동 업데이트를 적용한다.
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
        guard let build, canCheck, state != .updating else { return }
        state = .updating
        let target = target
        let previous = state
        DispatchQueue.global(qos: .utility).async {
            let problem = Self.checkClone(build)
            DispatchQueue.main.async {
                switch problem {
                case .none:
                    self.blocked = nil
                    self.blockedAt = nil
                    self.launchInstall(build, target: target, automatic: automatic)
                case .wait(let reason)?:
                    // 개발 중인 클론은 실패로 남기지 않는다. 커밋하거나 브랜치를 돌려 놓으면 다음 확인 때 받는다
                    Diagnostics.record("업데이트", "미룸: \(reason)")
                    self.blocked = reason
                    self.blockedAt = Date()
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
        UserDefaults.standard.removeObject(forKey: Key.installing)
        if automatic, let target { UserDefaults.standard.set(target, forKey: Key.failedTarget) }
    }

    private enum CloneProblem {
        /// 사용자가 클론에서 일하는 중이라 잠시 미룬다.
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
        guard branch == build.branch else { return .wait("클론이 \(branch) 브랜치에 있어 \(build.branch)로 돌아오면 받습니다.") }
        guard git(["status", "--porcelain", "--untracked-files=no"], in: path)?.isEmpty == true else {
            return .wait("클론에 커밋하지 않은 변경이 있어 커밋한 뒤 받습니다.")
        }
        // pull --ff-only가 로그에만 남기고 실패하지 않게, 갈라진 클론은 먼저 가린다
        guard git(["fetch", "--quiet", "origin", build.branch], in: path) != nil else {
            return .wait("GitHub에서 받아 오지 못했습니다. 연결되면 다시 해 봅니다.")
        }
        guard git(["merge-base", "--is-ancestor", "HEAD", "FETCH_HEAD"], in: path) != nil
                || git(["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"], in: path) != nil else {
            return .wait("클론에 GitHub에 없는 커밋이 있어 푸시하거나 맞춘 뒤 받습니다.")
        }
        guard !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Caches/RunTime/install.lock") else {
            return .wait("다른 설치가 진행 중이라 끝난 뒤 받습니다.")
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
    private func launchInstall(_ build: Build, target: String?, automatic: Bool) {
        try? FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        exec >> \(quote(Self.logURL.path)) 2>&1
        echo "== $(date) 업데이트 시작"
        cd \(quote(build.sourcePath)) && git pull --ff-only origin \(quote(build.branch)) && ./install.sh
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
        Diagnostics.record("업데이트", (automatic ? "자동 " : "") + "설치 시작: \(build.commit.prefix(7)) → \((target ?? "").prefix(7))")
        // install.sh가 성공하면 이 앱은 꺼지고 새 빌드가 뜬다. 여기로 돌아왔다면 실패한 것이다
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                if finished.terminationStatus != 0 {
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
}
