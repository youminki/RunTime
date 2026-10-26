import Foundation

/// Claude Code에 로그인한 계정 (`~/.claude.json`의 oauthAccount).
public struct ClaudeAccountInfo: Equatable, Sendable {
    public let uuid: String
    public let email: String
    public let displayName: String?
    public let organizationName: String?
    public let organizationType: String?
    /// oauthAccount 원본 JSON. 계정을 바꿀 때 `~/.claude.json`에 그대로 되돌려 넣는다.
    public let raw: Data

    public init?(raw: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let uuid = object["accountUuid"] as? String, !uuid.isEmpty,
              let email = object["emailAddress"] as? String
        else { return nil }
        self.uuid = uuid
        self.email = email
        displayName = object["displayName"] as? String
        organizationName = object["organizationName"] as? String
        organizationType = object["organizationType"] as? String
        self.raw = raw
    }
}

/// Claude Code 로그인 정보 읽기·바꾸기. 계정 전환에 쓴다.
/// 토큰은 키체인과 이 Mac 안에서만 옮기고 어디로도 보내지 않는다.
public enum ClaudeLogin {

    /// Claude Code 전역 설정 파일. `CLAUDE_CONFIG_DIR`이 있으면 그 안의 `.claude.json`.
    public static var globalConfigFile: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    // MARK: - 설정 파일의 oauthAccount

    public static func account(inConfig data: Data) -> ClaudeAccountInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: oauth)
        else { return nil }
        return ClaudeAccountInfo(raw: raw)
    }

    /// oauthAccount만 바꾸고 나머지 키는 그대로 둔 설정 파일 내용.
    public static func replacingAccount(inConfig data: Data, with raw: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }
        root["oauthAccount"] = oauth
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    public static func currentAccount() -> ClaudeAccountInfo? {
        (try? Data(contentsOf: globalConfigFile)).flatMap(account(inConfig:))
    }

    /// Claude Code가 이 파일을 자주 다시 쓰므로 읽은 직후 바꿔 원자적으로 쓰고, 다시 읽어 바뀌었는지 본다.
    /// dotfiles로 관리하는 심볼릭 링크는 가리키는 파일에 쓰고, 권한은 원래대로 둔다.
    @discardableResult
    public static func setCurrentAccount(_ raw: Data) -> Bool {
        let url = globalConfigFile.resolvingSymlinksInPath()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        guard let data = try? Data(contentsOf: url),
              let updated = replacingAccount(inConfig: data, with: raw),
              (try? updated.write(to: url, options: .atomic)) != nil
        else { return false }
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        let wanted = ClaudeAccountInfo(raw: raw)?.uuid
        return (try? Data(contentsOf: url)).flatMap(account(inConfig:))?.uuid == wanted
    }

    // MARK: - 자격증명 (키체인 "Claude Code-credentials" 또는 .credentials.json)

    /// 지금 Claude Code가 쓰는 자격증명 JSON. 첫 접근이면 키체인 허용 창이 뜰 수 있어 메인 스레드에서 부르지 않는다.
    public static func liveCredentials() -> Data? {
        OAuthUsageProvider.fileCredentials() ?? OAuthUsageProvider.keychainCredentials()
    }

    /// 자격증명을 바꿔 넣고 다시 읽어 같은지 확인한다.
    /// 키체인은 Claude Code처럼 `security`로 쓰되, 토큰이 프로세스 인자로 드러나지 않게 표준 입력으로 넘긴다.
    public static func setLiveCredentials(_ data: Data) -> Bool {
        let file = ClaudePaths.configDirectory.appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard (try? data.write(to: file, options: .atomic)) != nil else { return false }
            return OAuthUsageProvider.fileCredentials() == data
        }
        return writeKeychain(data, service: "Claude Code-credentials")
    }

    /// `security -i`는 4096자를 넘는 줄을 실패로 끝내지 않고 깨진 값으로 저장한다 (실측: 데이터 2000바이트까지 정상).
    static let interactiveLineLimit = 4000

    /// `security`로 일반 암호 항목을 쓰고 다시 읽어 같은지 본다. 앱이 아닌 `security`가 만든 항목이라
    /// 앱을 다시 빌드해도 키체인이 다시 묻지 않는다. 토큰이 프로세스 인자로 드러나지 않게 표준 입력으로 넘기되,
    /// 한 줄에 담기지 않는 큰 값(MCP 토큰이 함께 든 자격증명 등)은 Claude Code처럼 인자로 넘긴다.
    @discardableResult
    public static func writeKeychain(_ data: Data, service: String, account: String = NSUserName()) -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -X \(hex)\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        let input = Pipe()
        if command.utf8.count <= interactiveLineLimit {
            process.arguments = ["-i"]
            process.standardInput = input
        } else {
            process.arguments = ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        if process.arguments == ["-i"] {
            input.fileHandleForWriting.write(Data(command.utf8))
            try? input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        return readKeychain(service: service, account: account) == data
    }

    public static func readKeychain(service: String, account: String) -> Data? {
        OAuthUsageProvider.runSecurity(["find-generic-password", "-s", service, "-a", account, "-w"])
    }

    /// 값을 읽지 않고 항목이 있는지만 본다 (`-w` 없이는 허용 창이 뜨지 않는다).
    public static func keychainItemExists(service: String, account: String) -> Bool {
        OAuthUsageProvider.runSecurity(["find-generic-password", "-s", service, "-a", account]) != nil
    }

    public static func deleteKeychain(service: String, account: String) {
        _ = OAuthUsageProvider.runSecurity(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 자격증명 JSON에서 Claude 로그인(claudeAiOauth)만 뗀 JSON. 같은 항목에 든 MCP 서버 토큰은 계정과 상관없다.
    public static func oauthPart(of credentials: Data) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any],
              let oauth = root["claudeAiOauth"]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    }

    /// 지금 자격증명의 claudeAiOauth만 바꿔 넣는다. MCP 토큰 등 나머지는 지금 값을 그대로 둔다.
    public static func merging(oauthPart part: Data, into live: Data?) -> Data? {
        guard let partRoot = (try? JSONSerialization.jsonObject(with: part)) as? [String: Any],
              let oauth = partRoot["claudeAiOauth"]
        else { return nil }
        var root = live.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    /// 자격증명 JSON의 리프레시 토큰. 같은 계정의 토큰이 새로 바뀌었는지 볼 때 쓴다.
    public static func refreshToken(in credentials: Data) -> String? {
        let root = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any]
        return (root?["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String
    }

    // MARK: - 쓰지 않는 계정의 토큰 갱신

    /// Claude Code가 토큰을 새로 받는 곳과 그 클라이언트 ID (claude-code 2.1.304에서 확인).
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    public enum RefreshResult: Equatable {
        /// 새 claudeAiOauth 저장본과, 응답이 알려 준 토큰 주인
        case refreshed(Data, owner: String?)
        /// 리프레시 토큰이 더는 통하지 않는다. 그 계정으로 /login을 다시 해야 한다
        case rejected
        case unknown
    }

    /// 저장본의 액세스 토큰이 곧 만료되는지. 만료 시각이 없으면 새로 받을 때가 된 것으로 본다.
    public static func needsRefresh(_ part: Data, now: Date = Date(), margin: TimeInterval) -> Bool {
        let root = (try? JSONSerialization.jsonObject(with: part)) as? [String: Any]
        guard let ms = ((root?["claudeAiOauth"] as? [String: Any])?["expiresAt"] as? NSNumber)?.doubleValue else { return true }
        return Date(timeIntervalSince1970: ms / 1000) <= now.addingTimeInterval(margin)
    }

    /// 쓰지 않는 계정의 리프레시 토큰으로 새 토큰을 받는다. 리프레시 토큰도 바뀌므로 받은 값은 꼭 저장해야 한다.
    /// 지금 Claude Code가 쓰는 계정에는 부르지 않는다 (Claude Code가 가진 리프레시 토큰이 무효가 된다).
    public static func refresh(_ part: Data, clientVersion: String? = nil, now: Date = Date()) async -> RefreshResult {
        guard let oauth = ((try? JSONSerialization.jsonObject(with: part)) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty
        else { return .rejected }
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": oauthClientID]
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(OAuthUsageProvider.userAgent(clientVersion: clientVersion), forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unknown }
        guard http.statusCode == 200 else { return refreshRejected(status: http.statusCode, body: data) ? .rejected : .unknown }
        return applying(tokenResponse: data, to: part, now: now).map { .refreshed($0.part, owner: $0.owner) } ?? .unknown
    }

    /// 토큰이 죽었다는 답인지. 서버가 바쁘거나 막힌 답(429, 5xx)은 다음에 다시 해 본다.
    static func refreshRejected(status: Int, body: Data) -> Bool {
        guard status == 400 || status == 401 else { return false }
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
        return error == nil || error == "invalid_grant"
    }

    /// 토큰 응답을 저장본에 덮어 쓴다. 요금제 등 다른 칸은 그대로 둔다.
    static func applying(tokenResponse data: Data, to part: Data, now: Date) -> (part: Data, owner: String?)? {
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = response["access_token"] as? String, !access.isEmpty,
              let expiresIn = (response["expires_in"] as? NSNumber)?.doubleValue,
              var oauth = ((try? JSONSerialization.jsonObject(with: part)) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
        else { return nil }
        oauth["accessToken"] = access
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty { oauth["refreshToken"] = refresh }
        oauth["expiresAt"] = Int64((now.timeIntervalSince1970 + expiresIn) * 1000)
        if let refreshIn = (response["refresh_token_expires_in"] as? NSNumber)?.doubleValue {
            oauth["refreshTokenExpiresAt"] = Int64((now.timeIntervalSince1970 + refreshIn) * 1000)
        }
        if let scope = response["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        guard let updated = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys]) else { return nil }
        let owner = (response["account"] as? [String: Any])?["uuid"] as? String
        return (updated, owner)
    }

    public enum Owner: Equatable {
        case account(String)
        /// 액세스 토큰이 만료돼 물어볼 수 없다
        case expired
        case unknown
    }

    /// 자격증명이 어느 계정 것인지 Anthropic에 묻는다. 키체인과 `~/.claude.json`이 서로 다른 계정을 가리키는
    /// 순간(다른 세션이 옛 계정 토큰을 갱신해 쓴 경우 등)에 남의 토큰을 저장하지 않으려고 쓴다.
    public static func owner(of credentials: Data, clientVersion: String? = nil) async -> Owner {
        guard let token = OAuthUsageProvider.parseCredentials(credentials)?.token else { return .unknown }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(OAuthUsageProvider.userAgent(clientVersion: clientVersion), forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unknown }
        if http.statusCode == 401 { return .expired }
        guard http.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let uuid = (root["account"] as? [String: Any])?["uuid"] as? String
        else { return .unknown }
        return .account(uuid)
    }

    // MARK: - 자동 전환 후보

    /// 계정의 마지막 사용률. 리셋 시각이 지났으면 0으로 본다.
    public struct LastUsage: Codable, Equatable, Sendable {
        public var sessionPercent: Double?
        public var sessionResetsAt: Date?
        public var weeklyPercent: Double?
        public var weeklyResetsAt: Date?

        public init(sessionPercent: Double?, sessionResetsAt: Date?, weeklyPercent: Double?, weeklyResetsAt: Date?) {
            self.sessionPercent = sessionPercent
            self.sessionResetsAt = sessionResetsAt
            self.weeklyPercent = weeklyPercent
            self.weeklyResetsAt = weeklyResetsAt
        }

        /// 지금 기준 세션·주간 중 높은 쪽. 모르면 0.
        public func effectivePercent(now: Date) -> Double {
            func value(_ pct: Double?, _ reset: Date?) -> Double {
                if let reset, reset <= now { return 0 }
                return pct ?? 0
            }
            return max(value(sessionPercent, sessionResetsAt), value(weeklyPercent, weeklyResetsAt))
        }
    }

    /// 지금 계정이 한도(`limit`) 이상이면 여유(`limit` 미만)가 가장 많은 다른 계정. 없으면 nil.
    public static func autoSwitchTarget(current: String, usage: [String: LastUsage], candidates: [String],
                                        limit: Double, now: Date) -> String? {
        guard let mine = usage[current], mine.effectivePercent(now: now) >= limit else { return nil }
        // Xcode 16의 컴파일러는 이어 쓴 클로저 체인의 타입 추론이 느려 반복문으로 쓴다
        var best: (id: String, percent: Double)?
        for id in candidates where id != current {
            let percent: Double = usage[id]?.effectivePercent(now: now) ?? 0
            if percent < limit, best.map({ percent < $0.percent }) ?? true { best = (id, percent) }
        }
        return best?.id
    }
}
