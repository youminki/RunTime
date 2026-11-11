import Foundation

/// Anthropic이 이 기기의 요청을 막은 동안 같은 곳에 다시 보내지 않게 한다.
/// 요청 제한은 토큰이 아니라 요청한 곳에 걸린다. 가짜 리프레시 토큰에도 429가 오고(2026-11-11 실측),
/// 계정을 바꾼 직후 첫 조회도 429였다. 그래서 계정마다가 아니라 앱 전체가 한 관문을 함께 쓴다.
/// 막힌 동안 또 보내면 제한이 풀리지 않아, 거듭 막히면 쉬는 시간을 늘린다.
public final class RateLimitGate: @unchecked Sendable {
    /// 사용량 조회 (`/api/oauth/usage`). 지금 계정과 쓰지 않는 계정 조회가 함께 쓴다.
    public static let usage = RateLimitGate(first: 10 * 60, maximum: 30 * 60)
    /// 토큰 새로 받기 (`/v1/oauth/token`). Claude Code도 같은 곳에 받으러 가니 짧게 시작한다.
    /// 이 곳은 `Retry-After`를 주지 않고, 우리가 쉬는 동안에도 Claude Code는 몇 분 만에 받아 간다(2026-11-11 실측). 그래서 짧게 끊는다.
    public static let token = RateLimitGate(first: 2 * 60, maximum: 10 * 60)

    private let lock = NSLock()
    private var until: Date?
    private var streak = 0
    let first: TimeInterval
    let maximum: TimeInterval
    /// `Retry-After`가 터무니없이 길 때만 자른다.
    static let serverMaximum: TimeInterval = 6 * 3600

    public init(first: TimeInterval, maximum: TimeInterval) {
        (self.first, self.maximum) = (first, maximum)
    }

    /// 막혀 있으면 풀리는 때.
    public func blockedUntil(now: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let until, until > now else { return nil }
        return until
    }

    /// 429를 받았다. 서버가 기다릴 시간을 알려 주면 그대로, 아니면 처음 쉬는 시간에서 거듭할 때마다 두 배로 쉰다.
    @discardableResult
    public func hit(retryAfter: TimeInterval? = nil, now: Date = Date()) -> Date {
        lock.lock()
        defer { lock.unlock() }
        // 막힌 동안 함께 나갔던 요청들이 잇달아 429를 받아도 한 번 막힌 것으로 센다
        if let until, until > now {
            if let retryAfter { self.until = max(until, now.addingTimeInterval(min(max(retryAfter, 30), Self.serverMaximum))) }
            return self.until ?? until
        }
        // 풀린 뒤 한참 막히지 않았으면 지난 일이다. 몇 시간 전 429까지 세면 한 번 막혀도 최대로 쉰다
        if let until, now.timeIntervalSince(until) > maximum { streak = 0 }
        streak += 1
        let doubled = first * pow(2, Double(min(streak - 1, 8)))
        // 서버가 알려 준 시간은 우리 한도보다 길어도 따른다. 그 전에 보내면 제한이 풀리지 않는다
        let wait = retryAfter.map { min(max($0, 30), Self.serverMaximum) } ?? min(doubled, maximum)
        let next = now.addingTimeInterval(wait)
        until = max(until ?? next, next)
        return until ?? next
    }

    /// 요청이 통했다.
    public func cleared() {
        lock.lock()
        defer { lock.unlock() }
        streak = 0
        until = nil
    }

    /// `Retry-After` 헤더 (초 또는 HTTP 날짜).
    public static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { $0.timeIntervalSince(now) }
    }
}
