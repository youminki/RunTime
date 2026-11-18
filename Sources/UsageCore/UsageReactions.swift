import Foundation

/// 사용량 흐름에서 러너가 반응할 순간을 고른다. 틱마다 지금 값을 넣으면 반응할 일이 있을 때만 하나를 돌려준다.
/// 같은 반응이 연달아 나오지 않게 쉬는 시간을 두고, 새 세션 알림만 쉬는 시간과 상관없이 낸다.
public struct UsageReactions {
    public enum Reaction: Equatable, Sendable {
        /// 토큰이 갑자기 쏟아졌다 (최근 몇 초 사이 속도가 몇 배로 뛰었다).
        case burst
        /// 몇 분 쉬었다가 다시 쓰기 시작했다.
        case resumed
        /// 세션 사용률이 25·50·75%를 넘었다.
        case sessionMilestone(Int)
        /// 여러 폴더(프로젝트)에서 동시에 쓰고 있다.
        case multitask(Int)
        /// 5시간 세션 창이 새로 시작됐다.
        case newSession
    }

    public struct Input: Sendable {
        public var rate: Double
        public var runThreshold: Double
        public var idleSeconds: TimeInterval
        public var sessionPercent: Double?
        /// 세션 창을 가리키는 값 (초기화 시각 등). 바뀌면 새 세션이다.
        public var sessionWindow: String?
        public var activeProjects: Int
        public var now: Date

        public init(rate: Double, runThreshold: Double, idleSeconds: TimeInterval, sessionPercent: Double?,
                    sessionWindow: String?, activeProjects: Int, now: Date) {
            self.rate = rate
            self.runThreshold = runThreshold
            self.idleSeconds = idleSeconds
            self.sessionPercent = sessionPercent
            self.sessionWindow = sessionWindow
            self.activeProjects = activeProjects
            self.now = now
        }
    }

    /// 반응 사이 쉬는 시간.
    public var cooldown: TimeInterval = 15
    /// 이만큼 쉬었다가 다시 쓰면 "다시 시작".
    public var restGap: TimeInterval = 3 * 60
    /// 동시 작업 알림은 자주 내지 않는다.
    public var multitaskCooldown: TimeInterval = 10 * 60

    private var recentRates: [(at: Date, rate: Double)] = []
    private var lastIdle: TimeInterval?
    private var lastReaction: Date?
    private var lastMultitask: Date?
    private var lastProjects = 0
    private var window: String?
    private var milestone: Int?

    public init() {}

    public mutating func update(_ input: Input) -> Reaction? {
        defer {
            lastIdle = input.idleSeconds
            lastProjects = input.activeProjects
        }
        recentRates.append((input.now, input.rate))
        recentRates.removeAll { input.now.timeIntervalSince($0.at) > 12 }
        // 첫 틱(앱을 켠 직후 지난 기록을 한꺼번에 읽은 때)은 기준만 잡는다
        let first = lastIdle == nil

        // 새 세션: 처음 본 창은 기준으로만 둔다
        if let current = input.sessionWindow {
            let changed = window != nil && window != current
            // 새 세션은 0%부터 다시 센다 (처음 본 창은 지금 단계를 기준으로 둔다)
            if window != current { milestone = changed ? 0 : nil }
            window = current
            if changed { return fire(.newSession, at: input.now, force: true) }
        }
        // 세션 사용률 단계: 처음 본 단계는 기준으로만 둔다
        var crossed: Int?
        if let percent = input.sessionPercent {
            let step = min(Int(percent / 25), 3) * 25
            if let previous = milestone, step > previous, step > 0 { crossed = step } else { milestone = max(milestone ?? step, step) }
        }
        if first { return nil }

        let resting = lastIdle.map { $0 >= restGap } ?? false
        if resting, input.idleSeconds < 30, let reaction = fire(.resumed, at: input.now) { return reaction }

        // 3초 넘게 지난 값 가운데 가장 낮은 속도의 세 배를 넘고, 달리기 기준의 두 배 이상이면 부스트
        let older = recentRates.filter { input.now.timeIntervalSince($0.at) >= 3 }.map(\.rate)
        if let floor = older.min(), input.rate >= input.runThreshold * 2, input.rate >= max(floor, 1) * 3,
           let reaction = fire(.burst, at: input.now) {
            recentRates.removeAll()   // 같은 오름세로 또 내지 않게
            return reaction
        }

        // 쉬는 시간에 막힌 단계는 기준을 올리지 않아 다음 틱에 다시 알린다
        if let crossed, let reaction = fire(.sessionMilestone(crossed), at: input.now) {
            milestone = crossed
            return reaction
        }

        if input.activeProjects >= 2, lastProjects < 2,
           lastMultitask.map({ input.now.timeIntervalSince($0) >= multitaskCooldown }) ?? true,
           let reaction = fire(.multitask(input.activeProjects), at: input.now) {
            lastMultitask = input.now
            return reaction
        }
        return nil
    }

    private mutating func fire(_ reaction: Reaction, at now: Date, force: Bool = false) -> Reaction? {
        if !force, let lastReaction, now.timeIntervalSince(lastReaction) < cooldown { return nil }
        lastReaction = now
        return reaction
    }
}

extension Thresholds {
    /// 같은 단계 안에서의 빠르기 (0.85~1.3). 단계 경계에 가까울수록 다음 단계 쪽으로 빨라져, 단계가 바뀔 때 덜 덜컥인다.
    public func tempo(burnRate rate: Double, state: CatState) -> Double {
        let range: (Double, Double)
        switch state {
        case .sleeping, .standing, .looking, .waiting: return 1
        case .walking: range = (walk, run)
        case .running: range = (run, dash)
        case .dashing: range = (dash, rainbow)
        case .rainbow: range = (rainbow, rainbow * 3)
        }
        let span = max(range.1 - range.0, 1)
        let t = min(max((rate - range.0) / span, 0), 1)
        return 0.85 + 0.45 * t
    }
}
