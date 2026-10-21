import Foundation

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

    public enum ProviderError: Error {
        case tokenNotFound
        case http(Int)
        case badResponse
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

    public init() {}

    /// - clientVersion: JSONL에 기록된 Claude Code 버전. User-Agent에 넣는다.
    public func fetch(clientVersion: String? = nil) async throws -> OfficialUsage {
        let userAgent = Self.userAgent(clientVersion: clientVersion)
        do {
            return try await fetchOnce(userAgent: userAgent)
        } catch ProviderError.http(401) {
            // 토큰 만료/회전 — 캐시 무효화 후 새로 읽어 1회 재시도
            invalidateCachedToken()
            return try await fetchOnce(userAgent: userAgent)
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

    private func fetchOnce(userAgent: String) async throws -> OfficialUsage {
        guard let token = await accessToken() else { throw ProviderError.tokenNotFound }
        return try await Self.fetch(token: token, userAgent: userAgent)
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

    private func accessToken() async -> String? {
        await withCheckedContinuation { continuation in
            credentialQueue.async {
                continuation.resume(returning: self.loadAccessToken(now: Date()))
            }
        }
    }

    /// credentialQueue 전용.
    private func loadAccessToken(now: Date) -> String? {
        if let cached = cachedToken, now < cached.expiresAt.addingTimeInterval(-Self.expiryMargin) {
            return cached.token
        }
        guard let data = Self.fileCredentials() ?? Self.keychainCredentials(),
              let parsed = Self.parseCredentials(data, now: now)
        else { return nil }
        cachedToken = CachedToken(token: parsed.token, expiresAt: parsed.expiresAt)
        return parsed.token
    }

    /// 직렬 큐라 뒤이어 들어오는 accessToken()보다 먼저 처리된다. 계정을 바꾼 뒤에도 부른다.
    public func invalidateCachedToken() {
        credentialQueue.async { self.cachedToken = nil }
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
