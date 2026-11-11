import Foundation

/// 공식 조회가 실패한 뒤 언제 다시 받을지. 엔진의 큐·타이머와 떼어 단위 시험한다.
public enum OfficialRetry {
    /// 토큰 문제로 막힌 동안 Claude Code 기록이 생겼을 때 다시 읽는 최소 간격.
    /// 거절된 토큰이면 이 조회도 요청이라 요청 제한을 앞당기지 않게 1분에 한 번까지만 한다.
    public static let activityRefetchInterval: TimeInterval = 60

    /// 토큰 문제(만료·거절·갱신 제한·토큰 없음·로그인 풀림)인지. 이때는 Claude Code가 새로 받거나
    /// /login을 다시 하면 저장소 토큰이 바뀌어 다음 조회에서 풀린다.
    public static func isTokenProblem(_ error: Error) -> Bool {
        switch error as? OAuthUsageProvider.ProviderError {
        case .http(401)?, .http(403)?, .refreshLimited?, .tokenNotFound?, .loginRequired?: return true
        default: return false
        }
    }

    /// 토큰 문제로 막힌 동안 새 Claude Code 기록이 생겼으면 정기 조회(3분)를 기다리지 않고 다시 읽을지.
    public static func shouldRefetchOnActivity(tokenStalled: Bool, newEvents: Int, lastAttempt: Date?, now: Date) -> Bool {
        tokenStalled && newEvents > 0 && now.timeIntervalSince(lastAttempt ?? .distantPast) >= activityRefetchInterval
    }

    /// 실패 뒤 정기 조회를 기다리지 않고 다시 받을 때. 요청 제한이나 토큰 갱신 제한이면 풀리는 때,
    /// 그 밖에는 nil이라 정기 조회가 받는다. 사용량 관문이 그새 풀렸으면 nil.
    public static func retryAt(after error: Error, usageGate: RateLimitGate = .usage, now: Date = Date()) -> Date? {
        switch error as? OAuthUsageProvider.ProviderError {
        case .http(429)?: return usageGate.blockedUntil(now: now)
        case .refreshLimited(let until)?: return until > now ? until : nil
        default: return nil
        }
    }
}
