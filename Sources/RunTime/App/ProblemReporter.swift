import Foundation

/// 업데이트가 실패하거나 멈추면 만든 사람에게 알린다. 순위 서버의 `/v1/reports`로 보내고, 서버가 메일로 넘긴다.
/// 무작위 설치 ID, 앱 버전, macOS 버전, 까닭, 사용자 폴더·이름을 가린 기록 끝부분만 보낸다. 설정 > 일반 > 문제 기록에서 끈다.
/// 같은 까닭은 서버가 하루 한 번만 메일로 보낸다. 메인 스레드에서만 쓴다.
enum ProblemReporter {
    enum Kind: String {
        case failed = "update-failed"
        case timeout = "update-timeout"
        case unknown = "update-unknown"
    }

    static let key = "reportProblems", installKey = "reportInstallID"

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
    static func payload(_ kind: Kind, _ message: String) -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "install": installID,
            "kind": kind.rawValue,
            "message": redact(message),
            "app": info["CFBundleShortVersionString"] as? String ?? "",
            "commit": info["RunTimeCommit"] as? String ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "log": redact(recentLog()),
        ]
    }

    static func send(_ kind: Kind, _ message: String) {
        // swift run처럼 install.sh를 거치지 않은 실행과 화면 점검은 보내지 않는다
        guard isOn, Bundle.main.infoDictionary?["RunTimeCommitSHA"] != nil, !CommandLine.arguments.contains("--ui-shots"),
              let base = Leaderboard.shared.baseURL, let url = URL(string: "v1/reports", relativeTo: base) else { return }
        let body = payload(kind, message)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                Diagnostics.record("문제 보고", status == 200 ? "만든 사람에게 보냄: \(kind.rawValue)" : "보내지 못함 (\(error.map { _ in "연결 실패" } ?? "HTTP \(status)"))")
            }
        }.resume()
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
