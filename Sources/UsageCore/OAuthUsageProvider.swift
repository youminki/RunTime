import Foundation
import os.log

/// 주간 사용량의 사용처별 비중 (Claude Code, 채팅 등).
public struct UsageShare: Equatable, Sendable {
    public let name: String
    public let percent: Double

    public init(name: String, percent: Double) {
        self.name = name
        self.percent = percent
    }
}

/// 공식 usage 엔드포인트 응답 (게이지 %의 유일한 소스).
/// 퍼센트는 정수로 온다. resets_at은 조회할 때마다 1초 안쪽으로 흔들린다 (실측 17:09:59.75 → 17:10:00.47).
public struct OfficialUsage: Equatable, Sendable {
    public let sessionPercent: Double?
    public let sessionResetsAt: Date?
    public let weeklyPercent: Double?
    public let weeklyResetsAt: Date?
    public let fetchedAt: Date
    /// 주간 사용처별 비중 (seven_day_breakdown). 로컬 기록은 이 기기의 Claude Code분만 본다.
    public let weeklyBreakdown: [UsageShare]

    public init(sessionPercent: Double?, sessionResetsAt: Date?,
                weeklyPercent: Double?, weeklyResetsAt: Date?, fetchedAt: Date,
                weeklyBreakdown: [UsageShare] = []) {
        self.sessionPercent = sessionPercent
        self.sessionResetsAt = sessionResetsAt
        self.weeklyPercent = weeklyPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.fetchedAt = fetchedAt
        self.weeklyBreakdown = weeklyBreakdown
    }
}

/// 비문서화 OAuth usage 엔드포인트 폴링 (180초 간격 준수).
/// 토큰은 Anthropic 외 어디에도 전송·로깅 금지. 바꿔 쓰는 일은 계정 전환(`ClaudeLogin`)에서만 한다.
/// 실패하면 엔진이 유예 시간 동안 직전 값을 쓰고, 그 뒤로는 게이지를 비운다.
///
/// 키체인 접근 설계 (프롬프트 최소화):
/// 1. 액세스 토큰은 메모리 캐시 — 만료 시에만 자격증명을 다시 읽는다 (매 폴링 금지).
/// 2. `~/.claude/.credentials.json` 파일이 있으면 키체인보다 먼저 사용.
/// 3. 키체인은 Security.framework 직접 호출 대신 `/usr/bin/security` 서브프로세스 —
///    ACL 승인("항상 허용")이 security 바이너리에 걸리므로 앱을 리빌드해도 유지된다.
/// 4. unlock-keychain 자동화·암호 저장류 편법 금지.
public final class OAuthUsageProvider {

    public enum ProviderError: Error, Equatable {
        case tokenNotFound
        case http(Int)
        case badResponse
        /// 리프레시 토큰까지 거절됐다. Claude Code에서 /login을 다시 해야 한다
        case loginRequired
    }

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// User-Agent 필수 — 없으면 공격적 레이트리밋 버킷(429 지속). docs/usage-endpoint.md.
    /// JSONL에서 설치된 Claude Code 버전을 알기 전까지 쓰는 값.
    static let fallbackClientVersion = "2.1.283"

    /// expiresAt이 없을 때의 보수적 토큰 수명 (~60분 만료 가정).
    static let defaultTokenLifetime: TimeInterval = 55 * 60
    /// 만료 이만큼 전부터는 새로 읽는다.
    public static let expiryMargin: TimeInterval = 5 * 60

    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    /// 키체인 프롬프트가 떠 있으면 `security`는 사용자가 답할 때까지 끝나지 않는다.
    /// 그동안 Swift 동시성 스레드를 붙잡지 않도록 자격증명은 이 큐에서만 읽고, 캐시도 이 큐에서만 만진다.
    private let credentialQueue = DispatchQueue(label: "runtime.credentials")
    private var cachedToken: CachedToken?
    /// credentialQueue 전용. 지금 계정 토큰을 새로 받지 못한 때. 실패가 이어질 때 토큰 서버를 두드리지 않게 한다.
    private var liveRefreshFailedAt: Date?
    static let liveRefreshRetryDelay: TimeInterval = 60
    /// credentialQueue 전용. 지금 계정 토큰을 마지막으로 새로 받은 때와 그때 받은 액세스 토큰.
    private var liveRefreshedAt: Date?
    private var liveRefreshedToken: String?
    /// credentialQueue 전용. 토큰 서버가 거절한 리프레시 토큰. 저장소 값이 이대로면 다시 보내지 않는다.
    private var rejectedRefreshToken: String?
    /// 새로 받은 토큰도 401이면 토큰 문제가 아니다. 그동안은 401만으로 리프레시 토큰을 다시 돌리지 않는다.
    static let refreshOn401Cooldown: TimeInterval = 30 * 60

    // 바깥과 닿는 일. 시험에서 바꿔 끼운다.
    var refreshLive: (_ credentials: Data, _ clientVersion: String?) async -> ClaudeLogin.RefreshResult = { part, version in
        await ClaudeLogin.refresh(part, clientVersion: version)
    }
    var readCredentials: () -> Data? = { OAuthUsageProvider.fileCredentials() ?? OAuthUsageProvider.keychainCredentials() }
    var writeCredentials: (Data) -> Bool = { ClaudeLogin.setLiveCredentials($0) }
    var currentAccountID: () -> String? = { ClaudeLogin.currentAccount()?.uuid }
    var lockPaths: () -> [URL] = { ClaudeRefreshLock.defaultPaths() }
    var clock: () -> Date = { Date() }
    var send: (_ token: String, _ userAgent: String) async throws -> OfficialUsage = { token, userAgent in
        try await OAuthUsageProvider.fetch(token: token, userAgent: userAgent)
    }

    public init() {}

    /// - clientVersion: JSONL에 기록된 Claude Code 버전. User-Agent에 넣는다.
    public func fetch(clientVersion: String? = nil) async throws -> OfficialUsage {
        let usage = try await fetchRetrying(clientVersion: clientVersion)
        credentialQueue.async { self.loginRequired = false }
        return usage
    }

    private func fetchRetrying(clientVersion: String?) async throws -> OfficialUsage {
        let userAgent = Self.userAgent(clientVersion: clientVersion)
        do {
            return try await fetchOnce(userAgent: userAgent, clientVersion: clientVersion)
        } catch ProviderError.http(401) {
            // 토큰 만료/회전. 다른 곳(Claude Code, /login)이 새로 받았을 수 있어 캐시를 버리고 다시 읽는다
            invalidateCachedToken()
            do {
                return try await fetchOnce(userAgent: userAgent, clientVersion: clientVersion)
            } catch ProviderError.http(401) {
                // 다시 읽어도 막히면 아무도 새로 받지 않은 것이다. Claude Code를 쓰지 않는 동안에도 바로 보이게 직접 받는다
                guard let token = await refreshLiveToken(rejectedToken: nil, clientVersion: clientVersion) else {
                    throw await onCredentialQueue { self.loginRequired } ? ProviderError.loginRequired : ProviderError.http(401)
                }
                return try await send(token, userAgent)
            }
        }
    }

    /// 버전 문자열은 로그 파일에서 온 값이라 숫자와 점으로만 된 경우에만 헤더에 넣는다.
    public static func userAgent(clientVersion: String?) -> String {
        let valid = clientVersion.flatMap { version -> String? in
            guard !version.isEmpty, version.count <= 20,
                  version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") })
            else { return nil }
            return version
        }
        return "claude-code/\(valid ?? fallbackClientVersion)"
    }

    private func fetchOnce(userAgent: String, clientVersion: String?) async throws -> OfficialUsage {
        guard let loaded = await accessToken() else { throw ProviderError.tokenNotFound }
        var token = loaded.token
        // 이미 만료된 토큰이면 보내 봐야 401이다. Claude Code를 한동안 안 쓰면 이렇게 된다
        if loaded.expiresAt <= Date(),
           let fresh = await refreshLiveToken(rejectedToken: loaded.token, clientVersion: clientVersion) {
            token = fresh
        }
        return try await send(token, userAgent)
    }

    /// 주어진 액세스 토큰으로 한 번 조회한다. 계정 점검에서 저장해 둔 다른 계정 토큰으로도 쓴다.
    public static func fetch(token: String, userAgent: String) async throws -> OfficialUsage {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard http.statusCode == 200 else { throw ProviderError.http(http.statusCode) }
        guard let usage = parse(data: data, fetchedAt: Date()) else { throw ProviderError.badResponse }
        return usage
    }

    // MARK: - 토큰 캐시

    private func accessToken() async -> CachedToken? {
        await onCredentialQueue { self.loadAccessToken(now: Date()) }
    }

    private func onCredentialQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            credentialQueue.async { continuation.resume(returning: work()) }
        }
    }

    /// credentialQueue 전용.
    private func loadAccessToken(now: Date) -> CachedToken? {
        if let cached = cachedToken, now < cached.expiresAt.addingTimeInterval(-Self.expiryMargin) {
            return cached
        }
        guard let data = readCredentials(), let parsed = Self.parseCredentials(data, now: now) else { return nil }
        let token = CachedToken(token: parsed.token, expiresAt: parsed.expiresAt)
        cachedToken = token
        return token
    }

    /// 지금 Claude Code 계정의 토큰을 새로 받아 Claude Code 저장소에 써 넣고 새 액세스 토큰을 돌려준다.
    /// Claude Code와 같은 잠금을 잡고, 잡은 뒤 저장소를 다시 읽어 그새 다른 쪽이 받아 두었으면 그 토큰을 쓴다.
    /// 열려 있는 Claude Code 세션은 갱신 전에 저장소를 다시 읽어 바뀐 토큰을 이어 쓴다 (claude-code 2.1.318 확인).
    /// - rejectedToken: 만료돼 쓸 수 없던 토큰. nil이면 서버가 401로 거절한 지금 토큰.
    private func refreshLiveToken(rejectedToken: String?, clientVersion: String?) async -> String? {
        // credentialQueue에서 잠금을 잡고 저장소를 읽는다. 네트워크는 큐 밖에서 기다린다
        enum Plan { case use(String), refresh(Data, ClaudeRefreshLock), skip }
        let plan: Plan = await onCredentialQueue {
            let now = self.clock()
            if let failed = self.liveRefreshFailedAt, now.timeIntervalSince(failed) < Self.liveRefreshRetryDelay { return .skip }
            guard let lock = ClaudeRefreshLock.acquire(paths: self.lockPaths(), now: now) else {
                Self.log.info("지금 계정 토큰 새로 받기 건너뜀: 다른 곳이 받는 중")
                return .skip
            }
            guard let live = self.readCredentials(),
                  let parsed = Self.parseCredentials(live, now: now)
            else { lock.release(); return .skip }
            // 죽은 리프레시 토큰을 폴링마다 다시 보내지 않는다. /login으로 바뀌면 다시 해 본다
            if let dead = self.rejectedRefreshToken, ClaudeLogin.refreshToken(in: live) == dead {
                self.loginRequired = true
                lock.release()
                return .skip
            }
            // 방금 받은 토큰도 401이면 토큰 문제가 아니라 리프레시 토큰을 또 돌리지 않는다
            if rejectedToken == nil, parsed.token == self.liveRefreshedToken, let last = self.liveRefreshedAt,
               now.timeIntervalSince(last) < Self.refreshOn401Cooldown {
                lock.release()
                return .skip
            }
            let stillRejected = rejectedToken.map { $0 == parsed.token } ?? (self.cachedToken?.token == parsed.token)
            if !stillRejected, parsed.expiresAt > now.addingTimeInterval(60) {
                self.cachedToken = CachedToken(token: parsed.token, expiresAt: parsed.expiresAt)
                lock.release()
                return .use(parsed.token)
            }
            return .refresh(live, lock)
        }
        switch plan {
        case .skip: return nil
        case .use(let token): return token
        case .refresh(let live, let lock):
            guard let part = ClaudeLogin.oauthPart(of: live) else {
                lock.release()
                return nil
            }
            let result = await refreshLive(part, clientVersion)
            Self.log.info("지금 계정 토큰 새로 받기: \(Self.describe(result), privacy: .public)")
            return await onCredentialQueue {
                defer { lock.release() }
                switch result {
                case .refreshed(let updated, let owner):
                    // 서버는 이미 리프레시 토큰을 돌렸다. 써 넣지 못하면 Claude Code도 로그인이 풀리니 한 번 더 써 본다
                    guard let merged = ClaudeLogin.merging(oauthPart: updated, into: live),
                          self.writeCredentials(merged) || self.writeCredentials(merged),
                          let parsed = Self.parseCredentials(merged)
                    else {
                        self.liveRefreshFailedAt = self.clock()
                        return nil
                    }
                    self.liveRefreshFailedAt = nil
                    self.liveRefreshedAt = self.clock()
                    self.liveRefreshedToken = parsed.token
                    self.loginRequired = false
                    self.cachedToken = CachedToken(token: parsed.token, expiresAt: parsed.expiresAt)
                    // 키체인 토큰이 `~/.claude.json`과 다른 계정 것이면 그 값을 이 계정 사용률로 보이지 않는다
                    if let owner, let current = self.currentAccountID(), owner != current { return nil }
                    return parsed.token
                case .rejected:
                    self.rejectedRefreshToken = ClaudeLogin.refreshToken(in: part)
                    self.loginRequired = true
                    return nil
                case .unknown:
                    self.liveRefreshFailedAt = self.clock()
                    return nil
                }
            }
        }
    }

    private static let log = Logger(subsystem: "dev.runtime.RunTime", category: "token")

    private static func describe(_ result: ClaudeLogin.RefreshResult) -> String {
        switch result {
        case .refreshed: return "받음"
        case .rejected: return "거절됨(다시 로그인 필요)"
        case .unknown: return "못 받음(네트워크·요청 제한)"
        }
    }

    /// credentialQueue 전용. 리프레시 토큰이 거절됐다. 저장소의 토큰이 바뀌면(/login) 지운다.
    private var loginRequired = false

    /// 직렬 큐라 뒤이어 들어오는 accessToken()보다 먼저 처리된다.
    public func invalidateCachedToken() {
        credentialQueue.async { self.cachedToken = nil }
    }

    /// 계정이 바뀔 때 부른다. 앞 계정의 토큰 캐시와 갱신 실패·쿨다운이 새 계정 토큰을 막지 않게 비운다.
    public func resetForAccountChange() {
        credentialQueue.async {
            self.cachedToken = nil
            self.liveRefreshFailedAt = nil
            self.liveRefreshedAt = nil
            self.liveRefreshedToken = nil
            self.loginRequired = false
        }
    }

    // MARK: - 응답 파싱 (스키마-관용적: 필드 누락 시 nil, 둘 다 없으면 실패)

    private static func date(_ any: Any?) -> Date? {
        (any as? String).flatMap(ISODate.parse)
    }

    private static func percent(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }

    public static func parse(data: Data, fetchedAt: Date) -> OfficialUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        var sessionPct = percent((root["five_hour"] as? [String: Any])?["utilization"])
        var sessionReset = date((root["five_hour"] as? [String: Any])?["resets_at"])
        var weeklyPct = percent((root["seven_day"] as? [String: Any])?["utilization"])
        var weeklyReset = date((root["seven_day"] as? [String: Any])?["resets_at"])

        // 폴백: five_hour/seven_day가 없으면 limits[] 배열에서 추출
        if sessionPct == nil || weeklyPct == nil, let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                switch limit["kind"] as? String {
                case "session" where sessionPct == nil:
                    sessionPct = percent(limit["percent"])
                    sessionReset = sessionReset ?? date(limit["resets_at"])
                case "weekly_all" where weeklyPct == nil:
                    weeklyPct = percent(limit["percent"])
                    weeklyReset = weeklyReset ?? date(limit["resets_at"])
                default: break
                }
            }
        }

        guard sessionPct != nil || weeklyPct != nil else { return nil }
        let rows = ((root["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]]) ?? []
        let breakdown = rows.compactMap { row -> UsageShare? in
            guard let name = (row["display_name"] as? String) ?? (row["key"] as? String),
                  let pct = percent(row["percent"]) else { return nil }
            return UsageShare(name: name, percent: pct)
        }
        return OfficialUsage(sessionPercent: sessionPct, sessionResetsAt: sessionReset,
                             weeklyPercent: weeklyPct, weeklyResetsAt: weeklyReset,
                             fetchedAt: fetchedAt, weeklyBreakdown: breakdown)
    }

    // MARK: - 자격증명 로드 (파일 우선 → 키체인 서브프로세스, docs/usage-endpoint.md)

    /// credentials JSON → (액세스 토큰, 만료 시각). expiresAt(epoch ms)이 없으면 ~60분 가정.
    public static func parseCredentials(_ data: Data, now: Date = Date()) -> (token: String, expiresAt: Date)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            ?? now.addingTimeInterval(defaultTokenLifetime)
        return (token, expiresAt)
    }

    static func fileCredentials() -> Data? {
        try? Data(contentsOf: ClaudePaths.configDirectory.appendingPathComponent(".credentials.json"))
    }

    /// `/usr/bin/security find-generic-password -s "Claude Code-credentials" -a $USER -w`
    /// Security.framework 직접 호출 금지 — ACL이 앱 서명이 아닌 security 바이너리에 걸려
    /// 리빌드해도 "항상 허용" 승인이 유지된다.
    static func keychainCredentials(service: String = "Claude Code-credentials") -> Data? {
        let base = ["find-generic-password", "-s", service]
        // 계정 지정 조회 → 실패 시 계정 생략 폴백 (관용)
        return runSecurity(base + ["-a", NSUserName(), "-w"])
            ?? runSecurity(base + ["-w"])
    }

    static func runSecurity(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()   // 에러 출력 무시 (토큰 관련 정보 로깅 금지)
        do {
            try process.run()
        } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()   // 첫 접근 시 키체인 프롬프트가 뜨면 사용자 응답까지 대기
        guard process.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return Data(text.utf8)
    }
}

/// 가변 상태(cachedToken)는 credentialQueue에서만 만진다.
extension OAuthUsageProvider: @unchecked Sendable {}
