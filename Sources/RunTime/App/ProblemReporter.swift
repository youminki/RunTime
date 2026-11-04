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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                Diagnostics.record("문제 보고", status == 200 ? "만든 사람에게 보냄: \(kind.rawValue)" : "보내지 못함 (\(error.map { _ in "연결 실패" } ?? "HTTP \(status)"))")
                done?(status)
            }
        }.resume()
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
        let update = last.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !line.hasPrefix(" "), !trimmed.contains("warning:"), !trimmed.hasPrefix("[#") else { return false }
                return ["✗", "error", "fatal", "▸", "✓", "✅", "Build complete", "업데이트 시작", "Already", "Updating", "Fast-forward"].contains { trimmed.contains($0) }
                    || trimmed.first.map { !$0.isASCII } == true
            }
            .suffix(40)
        return (["[최근 기록]"] + events + ["", "[업데이트 로그 끝]"] + update).joined(separator: "\n")
    }

    /// 서버는 기록을 앞에서부터 4000자로 자른다. 까닭은 끝 쪽에 있어, 첫 줄(머리)을 두고 그 뒤 오래된 줄부터 덜어 맞춘다.
    static func newest(_ text: String, limit: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.joined(separator: "\n").count > limit, lines.count > 2 { lines.remove(at: 1) }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    /// 주소에 박힌 계정·토큰과 흔한 토큰 꼴. git 오류 줄에 `https://이름:토큰@github.com/...`이 그대로 찍힌다.
    private static let secrets: [(String, String)] = [
        ("([A-Za-z][A-Za-z0-9+.-]*://)[^/\\s@]+@", "$1***@"),
        ("\\b(gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|glpat-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]+)", "***"),
        ("(?i)\\b(bearer|token|password|passwd|secret|api[_-]?key)([\\s:=]+)\\S+", "$1$2***"),
    ]

    /// 사용자 폴더 경로·계정 이름·토큰을 가리고, 긴 줄은 자른다. 클론 위치(`/Users/이름/...`)가 로그 곳곳에 찍힌다.
    static func redact(_ text: String) -> String {
        let user = NSUserName()
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if user.count >= 3 { result = result.replacingOccurrences(of: user, with: "(사용자)") }
        for (pattern, template) in secrets {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.components(separatedBy: "\n").map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }.joined(separator: "\n")
    }
}
