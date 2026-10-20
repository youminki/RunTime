import Foundation

/// 중복 제거된 이벤트를 모아 세션/오늘/주간/burn rate 집계를 제공. 스레드 안전.
public final class UsageStore {

    /// 스파크라인 창: 최근 30분, 1분 버킷 (§F3).
    public static let sparklineMinutes = 30
    /// 일별 합계에 넣는 날 수 (오늘 포함). 보관 기간(8×24시간)으로는 8일 전 날이 중간부터만 남아 그날은 뺀다.
    public static let dailyDays = 8

    public struct Snapshot: Sendable {
        public let todayTokens: Int
        public let todayCostUSD: Double
        public let currentBlock: SessionBlock?
        public let tokensLast60s: Int
        public let lastEventDate: Date?
        public let totalEventCount: Int
        /// 주간 창(호출측이 시작 시각 지정: 공식 주간 창 또는 롤링 7일) 토큰 합계.
        public let weeklyTokens: Int
        /// 주간 창 모델별 토큰 (모델 비중 표시용).
        public let weeklyModelTokens: [String: Int]
        /// 최근 30분 1분 버킷 토큰 (오래된 것부터, 30개).
        public let sparkline: [Int]
        /// 오늘 프로그래매틱(SDK) 사용분 — 별도 크레딧 풀이라 분리 표시 (v1.1).
        public let todayProgrammaticTokens: Int
        /// 일별 합계 (최신 날짜부터). 일별 상세 시트용.
        public let dailyTotals: [DailyTotal]
        /// 가장 최근 기록의 Claude Code 버전.
        public let latestClientVersion: String?
    }

    public struct DailyTotal: Equatable, Sendable {
        public let dayStart: Date
        public let tokens: Int
        public let costUSD: Double
        /// 모델별 토큰 (일별 상세의 모델 구성 막대용).
        public let modelTokens: [String: Int]
        /// 폴더(프로젝트)별 토큰과 비용. 폴더를 남기지 않은 옛 기록은 빈 이름("")으로 모은다.
        public var projectTokens: [String: Int] = [:]
        public var projectCostUSD: [String: Double] = [:]
        /// 폴더별로 Claude Code를 쓴 시간(분). 기록이 있는 5분 칸을 센다. 업무 일지의 작업 시간 추정에 쓴다.
        public var projectActiveMinutes: [String: Int] = [:]
    }

    /// 활동 시간을 셀 때 한 칸의 길이(분).
    public static let activitySlotMinutes = 5

    private let queue = DispatchQueue(label: "runtime.usagestore")
    private var events: [UsageEvent] = []
    private var seenKeys: Set<String> = []
    private var sorted = true
    /// 이보다 오래된 이벤트는 스냅샷 때 버린다. 장기 실행 시 메모리·틱 비용이 계속 늘지 않게.
    private let retention: TimeInterval

    public init(retention: TimeInterval = 8 * 24 * 60 * 60) {
        self.retention = retention
    }

    /// 이벤트 추가. dedupKey 기준 최초 1회만 반영. 추가된 건수 반환.
    @discardableResult
    public func add(_ newEvents: [UsageEvent]) -> Int {
        queue.sync {
            var added = 0
            for event in newEvents where seenKeys.insert(event.dedupKey).inserted {
                if let last = events.last, event.timestamp < last.timestamp { sorted = false }
                events.append(event)
                added += 1
            }
            return added
        }
    }

    public func snapshot(now: Date = Date(), calendar: Calendar = .current,
                         weeklySince: Date? = nil) -> Snapshot {
        queue.sync {
            if !sorted {
                events.sort { $0.timestamp < $1.timestamp }
                sorted = true
            }
            pruneEvents(before: now.addingTimeInterval(-retention))
            let dayStart = calendar.startOfDay(for: now)
            let weekStart = weeklySince ?? WeeklyWindow.rollingStart(now: now)
            let sparkStart = now.addingTimeInterval(-Double(Self.sparklineMinutes) * 60)
            let firstDay = calendar.date(byAdding: .day, value: -(Self.dailyDays - 1), to: dayStart) ?? dayStart

            var todayTokens = 0
            var todayCost = 0.0
            var todayProgrammatic = 0
            var last60s = 0
            var weeklyTokens = 0
            var weeklyModelTokens: [String: Int] = [:]
            var sparkline = [Int](repeating: 0, count: Self.sparklineMinutes)
            var daily: [Date: (tokens: Int, cost: Double, models: [String: Int], projects: [String: Int],
                               projectCost: [String: Double])] = [:]
            var slots: [Date: [String: Set<Int>]] = [:]

            for event in events where event.timestamp <= now {
                let tokens = event.totalTokens
                let cost = PricingTable.cost(of: event)
                if event.timestamp >= dayStart {
                    todayTokens += tokens
                    todayCost += cost
                    if event.isProgrammatic { todayProgrammatic += tokens }
                }
                let eventDay = calendar.startOfDay(for: event.timestamp)
                if eventDay >= firstDay {
                    daily[eventDay, default: (0, 0, [:], [:], [:])].tokens += tokens
                    daily[eventDay]!.cost += cost
                    daily[eventDay]!.models[event.model, default: 0] += tokens
                    daily[eventDay]!.projects[event.project ?? "", default: 0] += tokens
                    daily[eventDay]!.projectCost[event.project ?? "", default: 0] += cost
                    if let project = event.project, !project.isEmpty {
                        let slot = Int(event.timestamp.timeIntervalSince(eventDay)) / (Self.activitySlotMinutes * 60)
                        slots[eventDay, default: [:]][project, default: []].insert(slot)
                    }
                }
                if event.timestamp > now.addingTimeInterval(-60) {
                    last60s += tokens
                }
                if event.timestamp >= weekStart {
                    weeklyTokens += tokens
                    weeklyModelTokens[event.model, default: 0] += tokens
                }
                if event.timestamp > sparkStart {
                    let age = now.timeIntervalSince(event.timestamp)
                    let bucket = Self.sparklineMinutes - 1 - Int(age / 60)
                    if (0..<Self.sparklineMinutes).contains(bucket) {
                        sparkline[bucket] += tokens
                    }
                }
            }
            return Snapshot(
                todayTokens: todayTokens,
                todayCostUSD: todayCost,
                currentBlock: BlockCalculator.currentBlock(from: events, now: now),
                tokensLast60s: last60s,
                lastEventDate: events.last?.timestamp,
                totalEventCount: events.count,
                weeklyTokens: weeklyTokens,
                weeklyModelTokens: weeklyModelTokens,
                sparkline: sparkline,
                todayProgrammaticTokens: todayProgrammatic,
                dailyTotals: daily
                    .map { DailyTotal(dayStart: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost,
                                      modelTokens: $0.value.models, projectTokens: $0.value.projects,
                                      projectCostUSD: $0.value.projectCost,
                                      projectActiveMinutes: (slots[$0.key] ?? [:]).mapValues { $0.count * Self.activitySlotMinutes }) }
                    .sorted { $0.dayStart > $1.dayStart },
                latestClientVersion: events.last { $0.clientVersion != nil }?.clientVersion
            )
        }
    }

    /// 정렬된 상태에서 호출. queue 안에서만 사용.
    /// 한 주(또는 아무 기간)를 묶은 요약. 주간 초기화 때 지난주를 알린다.
    public struct PeriodSummary: Equatable, Sendable {
        public let tokens: Int
        public let costUSD: Double
        /// 가장 많이 쓴 날의 시작과 그날 토큰.
        public let busiestDay: Date?
        public let busiestDayTokens: Int
        /// 가장 많이 쓴 폴더와 그 비율 (0~1). 폴더를 남기지 않은 기록뿐이면 nil.
        public let topProject: String?
        public let topProjectShare: Double
    }

    /// [from, to) 기간 요약. 보관 기간(retention)보다 오래된 기록은 이미 버려져 셈에 들지 않는다.
    public func summary(from: Date, to: Date, calendar: Calendar = .current) -> PeriodSummary {
        queue.sync {
            var tokens = 0, cost = 0.0
            var days: [Date: Int] = [:], projects: [String: Int] = [:]
            for event in events where event.timestamp >= from && event.timestamp < to {
                let t = event.totalTokens
                tokens += t
                cost += PricingTable.cost(of: event)
                days[calendar.startOfDay(for: event.timestamp), default: 0] += t
                if let project = event.project, !project.isEmpty { projects[project, default: 0] += t }
            }
            let busiest = days.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
            let top = projects.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
            return PeriodSummary(tokens: tokens, costUSD: cost, busiestDay: busiest?.key, busiestDayTokens: busiest?.value ?? 0,
                                 topProject: top?.key, topProjectShare: tokens > 0 ? Double(top?.value ?? 0) / Double(tokens) : 0)
        }
    }

    private func pruneEvents(before cutoff: Date) {
        guard let keep = events.firstIndex(where: { $0.timestamp >= cutoff }) else {
            events.removeAll()
            seenKeys.removeAll()
            return
        }
        guard keep > 0 else { return }
        for event in events[..<keep] { seenKeys.remove(event.dedupKey) }
        events.removeFirst(keep)
    }
}
