import Foundation

/// 게이지 값이 어디서 왔는지.
public enum GaugeSource: Equatable, Sendable {
    /// 공식 조회값 그대로.
    case official
    /// 조회 뒤 창이 초기화됐다. 새 공식 값을 받기 전까지 0%로 둔다.
    case rolledOver
}

/// 게이지 하나(세션 또는 주간)의 표시값.
public struct GaugeReading: Equatable, Sendable {
    public let percent: Double
    public let source: GaugeSource

    public init(percent: Double, source: GaugeSource) {
        self.percent = percent
        self.source = source
    }

    /// 화면 표시용 정수 %. 공식 값이 정수로 온다.
    public var displayPercent: Int { Int(min(max(percent, 0), 100).rounded(.down)) }
}

/// 공식 응답의 창 하나 (세션 5시간 또는 주간 7일).
public struct OfficialWindow: Equatable, Sendable {
    public let percent: Double
    public let resetsAt: Date?
    public let fetchedAt: Date

    public init(percent: Double, resetsAt: Date?, fetchedAt: Date) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
    }

    /// 조회할 때 아직 오지 않은 리셋 시각. 이미 지난 시각이 왔으면 활성 창이 없는 것이라 nil.
    public var upcomingReset: Date? { resetsAt.flatMap { $0 > fetchedAt ? $0 : nil } }
}

/// 게이지 계산 (§F3).
///
/// 게이지 %는 공식 조회값만 쓴다. 로컬 기록은 이 기기의 Claude Code만 보고 한도 환산 비율도 창마다 달라
/// (실측 세션 1.3배, 주간 4.4배 차이) 조회 사이를 보간하거나 로컬 토큰으로 추정하면 `/usage`와 어긋난다.
/// 공식값만 쓰면 조회 사이 최대 3분 늦을 뿐 값은 늘 일치하고, 공식 값이 없으면 게이지를 비워 둔다.
public enum GaugeMath {
    /// 메뉴바에 쓰는 초기화까지 남은 시간 `2:18`. 모르거나 지났으면 `--:--`. 분은 버림이라 0:00은 1분 안쪽이다.
    public static func countdown(until end: Date?, now: Date) -> String {
        guard let end, end > now else { return "--:--" }
        let minutes = Int(end.timeIntervalSince(now) / 60)
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// 공식 창 하나의 표시값. 조회 뒤 리셋 시각이 지났으면 창이 초기화된 것이라 0%로 둔다.
    /// 조회할 때 이미 지난 리셋 시각이 왔으면 활성 창이 없는 것이라 0%로 두되 다시 조회하지 않는다
    /// (서버가 끝난 창의 시각을 계속 주면 30초마다 재조회가 반복된다).
    public static func reading(official: OfficialWindow, now: Date) -> GaugeReading {
        if let reset = official.resetsAt, reset <= official.fetchedAt {
            return GaugeReading(percent: 0, source: .official)
        }
        if let reset = official.resetsAt, reset <= now {
            return GaugeReading(percent: 0, source: .rolledOver)
        }
        return GaugeReading(percent: min(max(official.percent, 0), 100), source: .official)
    }

    /// 지금 오름세(분당 %p)로 남은 %를 다 쓰는 데 걸리는 분. 오름세가 없거나 이미 꽉 찼으면 nil.
    public static func minutesUntilFull(percent: Double, ratePerMinute: Double?) -> Int? {
        guard let ratePerMinute, ratePerMinute > 0, percent < 100 else { return nil }
        return Int(((100 - percent) / ratePerMinute).rounded())
    }

    /// 창이 지난 비율(0~1). 게이지에 경과 시간 표시선을 그려 사용량이 시간보다 앞서는지 보이게 한다.
    public static func elapsedFraction(resetsAt: Date, duration: TimeInterval, now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(1 - resetsAt.timeIntervalSince(now) / duration, 0), 1)
    }

    /// 시간 대비 사용 속도. 게이지 눈금을 읽지 않아도 한눈에 보이게 한 단어로 줄인다.
    public enum Pace: Equatable, Sendable {
        case relaxed, steady, fast, critical
    }

    /// 지난 시간 비율보다 사용률이 `margin`%p 넘게 앞서면 빠름, 뒤처지면 여유. 95% 이상은 시간과 상관없이 한도 임박.
    /// 창이 막 시작했을 때(5% 미만)는 몇 번만 써도 빠름이 되어 판단하지 않는다.
    public static func pace(percent: Double, elapsed: Double, margin: Double = 10) -> Pace {
        if percent >= 95 { return .critical }
        if elapsed < 0.05 { return .steady }
        let lead = percent - elapsed * 100
        if lead > margin { return .fast }
        if lead < -margin { return .relaxed }
        return .steady
    }

    public enum LimitOutlook: Equatable, Sendable {
        /// 리셋 전에 한도에 닿는다. 남은 분.
        case reachesLimit(minutes: Int)
        /// 지금 속도로도 리셋이 먼저 온다.
        case clearUntilReset
    }

    /// 한도에 닿는 시점과 리셋 시점 비교. 리셋이 먼저면 "N분 뒤 한도"는 의미가 없다. 속도가 없으면 nil.
    /// 리셋 시각이 이미 지났으면(새 공식 값을 받기 전) 모르는 것으로 본다.
    public static func limitOutlook(minutesLeft: Int?, resetsAt: Date?, now: Date) -> LimitOutlook? {
        guard let minutesLeft else { return nil }
        if let resetsAt, resetsAt > now, now.addingTimeInterval(Double(minutesLeft) * 60) >= resetsAt {
            return .clearUntilReset
        }
        return .reachesLimit(minutes: minutesLeft)
    }
}

/// 최근 공식 값의 오름세 (분당 %p). "약 N분 뒤 한도"를 공식 값만으로 계산한다.
public struct OfficialTrend: Equatable, Sendable {

    /// 오름세를 볼 기간.
    public static let span: TimeInterval = 30 * 60
    /// 마지막으로 오른 뒤 이만큼 지나면 쉬는 것으로 보고 오름세를 쓰지 않는다.
    public static let idleAfter: TimeInterval = 10 * 60
    /// 공식 %는 정수라 짧은 구간·작은 변화는 오차가 크다. 이 이상 지나고 올라야 쓴다.
    public static let minimumElapsed: TimeInterval = 5 * 60
    public static let minimumRise: Double = 2

    private struct Sample: Equatable, Sendable {
        let at: Date
        let percent: Double
    }

    private var windowId: String?
    private var samples: [Sample] = []
    private var lastRise: Date?

    public init() {}

    /// 공식 값 하나를 기록한다 (조회 1건당 한 번). 창이 바뀌거나 %가 내려가면 새로 센다.
    public mutating func record(_ official: OfficialWindow) {
        let id = official.resetsAt.map(LimitAlertTracker.windowId(resetsAt:)) ?? "unknown"
        if id != windowId || (samples.last.map { official.percent < $0.percent } ?? false) {
            windowId = id
            samples = []
            lastRise = nil
        }
        if let previous = samples.last, official.percent > previous.percent { lastRise = official.fetchedAt }
        samples.append(Sample(at: official.fetchedAt, percent: official.percent))
        samples.removeAll { official.fetchedAt.timeIntervalSince($0.at) > Self.span }
    }

    /// 분당 %p. 기록이 부족하거나 한동안 오르지 않았으면(쉬는 중) nil.
    public func ratePerMinute(now: Date) -> Double? {
        guard let first = samples.first, let last = samples.last,
              let lastRise, now.timeIntervalSince(lastRise) <= Self.idleAfter else { return nil }
        let elapsed = last.at.timeIntervalSince(first.at)
        let rise = last.percent - first.percent
        guard elapsed >= Self.minimumElapsed, rise >= Self.minimumRise else { return nil }
        return rise / (elapsed / 60)
    }
}
