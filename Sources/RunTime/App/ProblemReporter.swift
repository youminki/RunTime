import DesignSyncCore
import Foundation

/// 업데이트가 실패하거나 멈추거나 화면에서 일이 실패하거나 앱이 죽거나 멈추면 만든 사람에게 알린다. 보고 서버의 `/v1/reports`로 보내고, 서버가 메일로 넘긴다.
/// 무작위 설치 ID, 앱 버전, macOS 버전, 까닭, 사용자 폴더·이름을 가린 기록 끝부분만 보낸다. 설정 > 일반 > 문제 기록에서 끈다.
/// 같은 까닭은 서버가 하루 한 번만 메일로 보낸다. 메인 스레드에서만 쓴다.
enum ProblemReporter {
    enum Kind: String {
        case failed = "update-failed"
        case timeout = "update-timeout"
        case unknown = "update-unknown"
        case screen = "screen-error"
        case crash = "app-crash"
        case hang = "app-hang"
    }

    static let key = "reportProblems", installKey = "reportInstallID"

    /// 보고를 받는 서버. 끝에 /가 있어야 상대 경로가 붙는다. 직접 띄운 서버로 바꾸려면
    /// `defaults write dev.runtime.RunTime leaderboardURL <주소>`.
    private static var serverURL: URL? {
        let custom = UserDefaults.standard.string(forKey: "leaderboardURL").flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 }
        guard let url = custom ?? URL(string: "https://tokencat-leaderboard.youminki.workers.dev") else { return nil }
        return url.absoluteString.hasSuffix("/") ? url : URL(string: url.absoluteString + "/")
    }

    /// 기본은 켜 둔다. 다른 사람 Mac에서 생긴 문제는 그 사람이 알려 주기 전에는 알 수 없어서다.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 이 Mac의 무작위 ID. 같은 Mac의 보고를 묶을 때만 쓴다.
    private static var installID: String {
        if let saved = UserDefaults.standard.string(forKey: installKey), UUID(uuidString: saved) != nil { return saved }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: installKey)
        return made
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// 서버로 보내는 본문 그대로. `--report-preview`가 찍어 무엇이 나가는지 보게 한다.
    /// 커밋은 40자 해시로 보내 메일에서 그 빌드의 소스 줄로 바로 간다.
    /// 충돌은 죽은 빌드가 지금 빌드와 다를 수 있어 `app`·`commit`·`log`를 따로 받는다.
    static func payload(_ kind: Kind, _ message: String, screen: String = "", source: String = "", detail: String = "",
                        app: String? = nil, commit: String? = nil, log: String? = nil) -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "install": installID,
            "kind": kind.rawValue,
            "message": redact(message),
            "app": app ?? info["CFBundleShortVersionString"] as? String ?? "",
            "commit": commit ?? info["RunTimeCommitSHA"] as? String ?? info["RunTimeCommit"] as? String ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "log": newest(redact(log ?? (kind == .screen ? recentEvents() : recentLog())), limit: 3900),
            "screen": screen,
            "source": source,
            "detail": redact(detail),
        ]
    }

    /// 앱을 켠 동안 이미 보낸 화면·까닭. 다시 받는 화면은 같은 실패를 몇 분마다 낸다.
    private static var sentScreens: Set<String> = []

    /// 화면에서 일이 실패했을 때 부른다. 설정이 빠진 것처럼 사용자가 고칠 일은 부르지 않는다.
    /// 부른 파일·줄을 함께 보내 메일에서 고칠 자리를 바로 찾게 한다. `detail`에는 요청·상태처럼 다시 만들 때 필요한 것을 적는다.
    static func screen(_ screen: String, _ message: String, detail: String = "",
                       file: String = #filePath, line: Int = #line, function: String = #function) {
        let fire = {
            Diagnostics.record(screen, "실패: \(message)")
            guard sentScreens.insert("\(screen)|\(message)").inserted else { return }
            send(.screen, message, screen: screen, source: source(file, line, function), detail: detail)
        }
        if Thread.isMainThread { fire() } else { DispatchQueue.main.async(execute: fire) }
    }

    /// 만든 사람이 고칠 실패인지. 망 끊김·느림과 피그마 토큰·권한·한도·없는 파일은 사용자 쪽 일이라 화면에만 보인다.
    static func shouldReport(_ error: Error) -> Bool {
        if let failure = error as? FigmaAPI.Failure {
            switch failure {
            case .server, .malformed: return true
            default: return false
            }
        }
        guard let error = error as? URLError else { return true }
        return ![.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed, .cancelled, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed].contains(error.code)
    }

    /// `/Users/이름/.../Sources/RunTime/App/A.swift`에서 저장소 안 경로만 남긴다.
    static func source(_ file: String, _ line: Int, _ function: String) -> String {
        let path = file.range(of: "Sources/").map { String(file[$0.lowerBound...]) } ?? URL(fileURLWithPath: file).lastPathComponent
        let name = function.filter { $0.isLetter || $0.isNumber || "()_:".contains($0) }
        return "\(path):\(line)" + (name.isEmpty ? "" : " \(name)")
    }

    /// `done`은 메인 스레드에서 HTTP 상태(연결 실패면 0)로 부른다. 보내지 않기로 했으면 부르지 않는다.
    static func send(_ kind: Kind, _ message: String, screen: String = "", source: String = "", detail: String = "",
                     app: String? = nil, commit: String? = nil, log: String? = nil, done: ((Int) -> Void)? = nil) {
        // swift run처럼 install.sh를 거치지 않은 실행과 화면 점검은 보내지 않는다
        guard isOn, Bundle.main.infoDictionary?["RunTimeCommitSHA"] != nil, !CommandLine.arguments.contains("--ui-shots"),
              let url = URL(string: "v1/reports", relativeTo: serverURL) else { return }
        let body = payload(kind, message, screen: screen, source: source, detail: detail, app: app, commit: commit, log: log)
        post(body, to: url) { status in
            // 충돌·멈춤 보고는 스스로 저장해 두고 다시 보내서, 나머지만 남겨 둔다
            if kind != .crash, kind != .hang, retryable(status) { keep(body) }
            if status == 200 { schedulePending() }
            done?(status)
        }
    }

    /// 사용자가 직접 보낸 문제. 오류 없이 틀리게 도는 것은 앱이 알 수 없어서 사람이 알려 준다.
    /// 서버를 바꾸지 않고 받게 화면 오류 종류로 보낸다. 쓴 글은 첫 줄을 제목으로, 전부를 `detail`에 넣는다
    /// (`message`는 메일 제목이라 짧게 잘린다). 진단 내용 전부를 기록으로 붙이고, `shots`(JPEG)는 메일 첨부로만 간다.
    /// 사용자가 누른 것이라 '만든 사람에게 알리기'를 꺼 두었어도 보낸다. `swift run`처럼 설치하지 않은 실행이면 -1.
    static func userReport(_ text: String, usage: String, shots: [Data] = [], done: @escaping (Int) -> Void) {
        guard Bundle.main.infoDictionary?["RunTimeCommitSHA"] != nil, let url = URL(string: "v1/reports", relativeTo: serverURL)
        else { return done(-1) }
        let title = text.split(separator: "\n").first.map { String($0.prefix(60)) } ?? text
        var body = payload(.screen, title, screen: userScreen, log: Diagnostics.report(usage: usage))
        body["detail"] = String(redact(text, lineLimit: nil).prefix(userTextLimit))
        post(body, extra: shots.isEmpty ? [:] : ["shots": shots.map { $0.base64EncodedString() }], to: url) { status in
            if retryable(status) {
                // 그림은 커서 다시 보낼 줄에 넣지 않는다. 빠졌다는 것만 적어 둔다
                var kept = body
                if !shots.isEmpty { kept["detail"] = (kept["detail"] ?? "") + "\n(그림 \(shots.count)장은 다시 보낼 때 뺐습니다)" }
                keep(kept)
            }
            if status == 200 { schedulePending() }
            done(status)
        }
    }

    /// 서버의 detail 한도(2000자)보다 조금 적게. 쓰는 칸에 남은 글자 수로 보인다.
    static let userTextLimit = 1900
    static let userScreen = "직접 보냄"

    /// `done`은 메인 스레드에서 부른다.
    private static func post(_ body: [String: String], extra: [String: Any] = [:], to url: URL, done: @escaping (Int) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: (body as [String: Any]).merging(extra) { $1 })
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                Diagnostics.record("문제 보고", status == 200 ? "만든 사람에게 보냄: \(body["kind"] ?? "")" : "보내지 못함 (\(error.map { _ in "연결 실패" } ?? "HTTP \(status)"))")
                done(status)
            }
        }.resume()
    }

    // MARK: 못 보낸 보고

    /// 망이 끊겼거나(0) 서버가 1분 한도로 막았거나(429) 넘어졌을 때(5xx). 400은 서버가 받지 않는 꼴이라 다시 보내도 같다.
    static func retryable(_ status: Int) -> Bool { status == 0 || status == 429 || status >= 500 }

    private static let pendingKey = "reportPending"
    /// 오래된 보고는 그 빌드가 이미 바뀌었을 수 있어 버린다. 쌓여도 몇 건이면 충분하다.
    private static let pendingLifetime: TimeInterval = 3 * 24 * 60 * 60, pendingLimit = 20
    /// 서버가 1분에 두 건까지 받아서 한 건씩 띄워 보낸다.
    private static let pendingGap: TimeInterval = 35
    private static var pendingScheduled = false

    /// 망이 붙어 있는데도 이만큼 거절되면 그 보고만의 문제라 버린다. 뒤의 보고가 막히지 않게 한다.
    private static let pendingTries = 5

    private struct Pending {
        let at: TimeInterval
        var tries: Int
        let body: [String: String]
    }

    private static func keep(_ body: [String: String]) {
        save(pending() + [Pending(at: Date().timeIntervalSince1970, tries: 0, body: body)])
    }

    private static func pending() -> [Pending] {
        (UserDefaults.standard.array(forKey: pendingKey) as? [[String: Any]] ?? []).compactMap { item in
            guard let at = item["at"] as? Double, let body = item["body"] as? [String: String] else { return nil }
            return Pending(at: at, tries: item["tries"] as? Int ?? 0, body: body)
        }
    }

    /// 오래됐거나 너무 많이 거절된 것은 버리고 최근 것만 둔다.
    private static func save(_ list: [Pending]) {
        let now = Date().timeIntervalSince1970
        let kept = list.filter { now - $0.at < pendingLifetime && $0.tries < pendingTries }.suffix(pendingLimit)
        if kept.isEmpty { UserDefaults.standard.removeObject(forKey: pendingKey); return }
        UserDefaults.standard.set(kept.map { ["at": $0.at, "tries": $0.tries, "body": $0.body] as [String: Any] }, forKey: pendingKey)
    }

    /// 앱을 켰을 때, 잠자기에서 깨어났을 때, 보고가 하나 닿았을 때. 남은 보고를 한 건씩 다시 보낸다.
    static func schedulePending(after delay: TimeInterval = pendingGap) {
        guard !pendingScheduled, !pending().isEmpty else { return }
        pendingScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            pendingScheduled = false
            // 알리기를 끄면 앱이 모은 보고는 버리고 사용자가 직접 보낸 것만 남긴다
            var list = pending().filter { isOn || $0.body["screen"] == userScreen }
            save(list)
            guard !list.isEmpty, let url = URL(string: "v1/reports", relativeTo: serverURL) else { return }
            var first = list.removeFirst()
            save(list)
            post(first.body, to: url) { status in
                if retryable(status) {
                    // 망이 끊겼거나 1분 한도(429, 한 사무실이 IP를 나눠 쓰면 잦다)면 다음 기회를 기다린다.
                    // 서버가 넘어진 것이면 횟수를 세어 이 보고 하나가 줄을 막지 않게 한다
                    if status >= 500 { first.tries += 1 }
                    save([first] + pending())
                } else {
                    schedulePending()
                }
            }
        }
    }

    /// 화면 오류에 붙이는 최근 기록. 실패 바로 앞의 요청·응답 줄이 까닭을 보여 준다.
    static func recentEvents() -> String {
        let events = ((try? String(contentsOf: Diagnostics.logURL, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").filter { !$0.isEmpty && !$0.contains("[문제 보고]") }.suffix(25)
        return (["[최근 기록]"] + events).joined(separator: "\n")
    }

    /// 업데이트 관련 최근 기록과 마지막 업데이트 로그 끝부분.
    static func recentLog() -> String {
        let events = ((try? String(contentsOf: Diagnostics.logURL, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").filter { $0.contains("[업데이트]") }.suffix(15)
        // 컴파일러 경고·소스 인용 줄은 빼고 단계·오류·완료 줄만 둔다 (까닭이 보이는 줄)
        let last = ((try? String(contentsOf: AppUpdater.logURL, encoding: .utf8)) ?? "").components(separatedBy: "\n== ").last ?? ""
        return (["[최근 기록]"] + events + ["", "[업데이트 로그 끝]"] + updateLines(last)).joined(separator: "\n")
    }

    /// 업데이트 한 번의 로그에서 까닭이 보이는 줄. 단계·오류 줄에 더해 마지막 몇 줄은 늘 둔다.
    /// codesign처럼 "경로: 까닭" 꼴로만 실패를 알리는 명령은 어떤 낱말로도 걸러지지 않아서다.
    static func updateLines(_ attempt: String) -> [String] {
        let lines = attempt.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.contains("warning:") && !trimmed.hasPrefix("[#")
            }
        let tail = lines.count - 6
        return lines.enumerated()
            .filter { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if index >= tail { return true }
                guard !line.hasPrefix(" ") else { return false }
                return ["✗", "error", "fatal", "▸", "✓", "✅", "Build complete", "업데이트 시작", "Already", "Updating", "Fast-forward"].contains { trimmed.contains($0) }
                    || trimmed.first.map { !$0.isASCII } == true
            }
            .map(\.element)
            .suffix(40)
    }

    /// 서버는 기록을 앞에서부터 4000자로 자른다. 까닭은 끝 쪽에 있어, 첫 줄(머리)을 두고 그 뒤 오래된 줄부터 덜어 맞춘다.
    static func newest(_ text: String, limit: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        // 진단 내용은 머리(빌드·업데이트·화면)가 기록보다 쓸모 있어 "최근 기록" 줄 뒤부터 덜어 낸다
        let first = (lines.firstIndex { $0.hasPrefix("최근 기록") } ?? 0) + 1
        var length = lines.reduce(lines.count - 1) { $0 + $1.count }
        while length > limit, lines.count > first + 1 { length -= lines.remove(at: first).count + 1 }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    /// 주소에 박힌 계정·토큰과 흔한 토큰 꼴. git 오류 줄에 `https://이름:토큰@github.com/...`이 그대로 찍힌다.
    private static let secrets: [(String, String)] = [
        ("([A-Za-z][A-Za-z0-9+.-]*://)[^/\\s@]+@", "$1***@"),
        ("\\b(gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|glpat-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]+)", "***"),
        ("(?i)\\b(bearer|token|password|passwd|secret|api[_-]?key)([\\s:=]+)\\S+", "$1$2***"),
        // 계정 전환 오류 문구에 이메일이 들어간다
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "(이메일)"),
    ]

    /// 사용자 폴더 경로·계정 이름·토큰을 가리고, 긴 줄은 자른다. 클론 위치(`/Users/이름/...`)가 로그 곳곳에 찍힌다.
    /// `lineLimit`이 nil이면 줄을 자르지 않는다 (사용자가 쓴 글).
    static func redact(_ text: String, lineLimit: Int? = 200) -> String {
        let user = NSUserName()
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if user.count >= 3 { result = result.replacingOccurrences(of: user, with: "(사용자)") }
        for (pattern, template) in secrets {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        guard let lineLimit else { return result }
        return result.components(separatedBy: "\n").map { $0.count > lineLimit ? String($0.prefix(lineLimit)) + "…" : $0 }.joined(separator: "\n")
    }
}
