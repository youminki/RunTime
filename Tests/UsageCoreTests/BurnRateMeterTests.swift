import Foundation
import Testing
@testable import UsageCore

struct BurnRateMeterTests {

    @Test func eMASmoothing() {
        let meter = BurnRateMeter(alpha: 0.3)
        #expect(abs((meter.update(tokensInLastMinute: 1000)) - (300)) <= 0.001)
        #expect(abs((meter.update(tokensInLastMinute: 1000)) - (510)) <= 0.001)
        #expect(abs((meter.update(tokensInLastMinute: 0)) - (357)) <= 0.001)
    }

    @Test func movingStages() {
        let t = Thresholds()
        #expect(t.moving(burnRate: 0) == .walking)
        #expect(t.moving(burnRate: 500) == .walking)
        #expect(t.moving(burnRate: 5_000) == .running)
        #expect(t.moving(burnRate: 15_000) == .dashing)
        #expect(t.moving(burnRate: 50_000) == .rainbow)
    }

    @Test func sensitivityPresets() {
        let high = Thresholds.preset(sensitivity: .high)
        #expect(high.moving(burnRate: 1_500) == .running) // run 경계 1000으로 하향
        let low = Thresholds.preset(sensitivity: .low)
        #expect(low.moving(burnRate: 3_000) == .walking) // run 경계 4000으로 상향
    }

    @Test func typingStages() {
        let t = Thresholds.typing(sensitivity: .normal)
        #expect(t.moving(burnRate: 80) == .walking)
        #expect(t.moving(burnRate: 200) == .running)
        #expect(t.moving(burnRate: 300) == .dashing)
        #expect(t.moving(burnRate: 500) == .rainbow)
    }
}

struct PaceTests {
    private let claude = Thresholds()
    private let keys = Thresholds.typing(sensitivity: .normal)

    private func decide(rate: Double = 0, working: Bool = false, typing: Double? = nil, keyIdle: TimeInterval = .infinity,
                        away: TimeInterval = 0) -> CatState {
        Pace.decide(.init(claudeRate: rate, claudeWorking: working, typingRate: typing, keyIdle: keyIdle, away: away),
                    claude: claude, keys: keys).state
    }

    @Test func claudeMovesOnlyWhileTurnIsOpen() {
        #expect(decide(rate: 5_000, working: true) == .running)
        // 도구를 돌리느라 기록이 끊겨도 차례가 열려 있으면 걷는다
        #expect(decide(rate: 0, working: true, away: 90) == .walking)
        // 차례가 끝나면 남은 속도와 상관없이 바로 선다
        #expect(decide(rate: 5_000, working: false, away: 1) == .standing)
        #expect(decide(working: false, away: 301) == .sleeping)
    }

    @Test func typingStopsRightAfterHandsLeave() {
        #expect(decide(typing: 200, keyIdle: 0.5) == .running)
        #expect(decide(typing: 200, keyIdle: 2.5, away: 2.5) == .standing)
        // 타자 반응을 끄면 키를 쳐도 움직이지 않는다
        #expect(decide(typing: nil, keyIdle: 0.5) == .standing)
    }

    @Test func fasterSourceWins() {
        #expect(decide(rate: 500, working: true, typing: 300, keyIdle: 0.5) == .dashing)
        #expect(decide(rate: 50_000, working: true, typing: 80, keyIdle: 0.5) == .rainbow)
    }

    @Test func looksAroundWhilePointerMoves() {
        func state(pointer: TimeInterval, away: TimeInterval = 1) -> CatState {
            Pace.decide(.init(claudeRate: 0, claudeWorking: false, typingRate: 0, keyIdle: 30, away: away,
                              pointerIdle: pointer), claude: claude, keys: keys).state
        }
        #expect(state(pointer: 1) == .looking)
        #expect(state(pointer: 9) == .standing)
        #expect(state(pointer: 400, away: 400) == .sleeping)
        // 타자를 치면 둘러보기보다 움직이기가 먼저다
        #expect(Pace.decide(.init(claudeRate: 0, claudeWorking: false, typingRate: 200, keyIdle: 0.5, away: 0, pointerIdle: 1),
                            claude: claude, keys: keys).state == .running)
    }

    @Test func typingRateCatchesUpRightAfterAPause() {
        var meter = TypingMeter()
        let start = Date()
        // 3초 넘게 쉬다가 1초에 4타씩(240타/분) 치기 시작한다
        for second in 0...4 { _ = meter.rate(count: 100, now: start.addingTimeInterval(Double(second))) }
        let first = meter.rate(count: 104, now: start.addingTimeInterval(5))
        let second = meter.rate(count: 108, now: start.addingTimeInterval(6))
        // 쉰 시간까지 나누면 첫 초에 80타/분으로 나온다
        #expect(first == 240)
        #expect(second == 240)
    }

    @Test func typingRateFollowsTheWindowWhileTyping() {
        var meter = TypingMeter(window: 3)
        let start = Date()
        var count: UInt32 = 0
        for second in 0...5 {
            count += 2   // 120타/분
            _ = meter.rate(count: count, now: start.addingTimeInterval(Double(second)))
        }
        // 빨라지면 3초 안에 새 빠르기가 된다
        var rate = 0.0
        for second in 6...9 {
            count += 5   // 300타/분
            rate = meter.rate(count: count, now: start.addingTimeInterval(Double(second)))
        }
        #expect(rate == 300)
        #expect(meter.rate(count: 3, now: start.addingTimeInterval(10)) == 0)   // 누적값이 줄면 다시 센다
    }

    @Test func downshiftWaitsForAClearDropButUpshiftIsImmediate() {
        let keys = Thresholds.typing(sensitivity: .normal)   // 달리기 120, 질주 250
        // 경계 바로 아래로 흔들려도 달리기를 이어 간다
        #expect(keys.moving(burnRate: 115, holding: .running) == .running)
        #expect(keys.moving(burnRate: 96, holding: .running) == .running)
        // 경계보다 20% 넘게 느려지면 걷는다
        #expect(keys.moving(burnRate: 94, holding: .running) == .walking)
        // 낮은 경계에서도 최소 25는 여유를 둔다 (높음 민감도 달리기 경계 60)
        let high = Thresholds.typing(sensitivity: .high)
        #expect(high.moving(burnRate: 36, holding: .running) == .running)
        #expect(high.moving(burnRate: 34, holding: .running) == .walking)
        // 올라갈 때는 바로 올린다
        #expect(keys.moving(burnRate: 121, holding: .walking) == .running)
        #expect(keys.moving(burnRate: 260, holding: .walking) == .dashing)
        // 멈췄다 다시 움직이면 이어 갈 단계가 없다
        #expect(keys.moving(burnRate: 115, holding: .standing) == .walking)
        #expect(keys.moving(burnRate: 115, holding: nil) == .walking)
        // 질주에서 크게 느려지면 걷기까지 내려간다
        #expect(keys.moving(burnRate: 90, holding: .dashing) == .walking)
        #expect(keys.moving(burnRate: 205, holding: .dashing) == .dashing)
        #expect(keys.moving(burnRate: 195, holding: .dashing) == .running)
    }

    @Test func paceKeepsTheStageNearABoundary() {
        func state(_ rate: Double, after previous: CatState?) -> CatState {
            Pace.decide(.init(claudeRate: 0, claudeWorking: false, typingRate: rate, keyIdle: 0.3, away: 0,
                              previous: .init(typing: previous)), claude: claude, keys: keys).state
        }
        #expect(state(115, after: .running) == .running)
        #expect(state(115, after: nil) == .walking)
    }

    @Test func holdingOneSourcesStageDoesNotHoldTheOther() {
        // Claude가 질주를 이끌다 끝났다. 타자 205타/분은 달리기여야 한다 (질주 경계 250의 여유 안이라도)
        let afterClaude = Pace.Input.Sources(claude: .dashing, typing: .running)
        let typingOnly = Pace.decide(.init(claudeRate: 0, claudeWorking: false, typingRate: 205, keyIdle: 0.3, away: 0,
                                           previous: afterClaude), claude: claude, keys: keys)
        #expect(typingOnly.state == .running)
        // 타자가 질주를 이끌다 멈췄다. Claude 8,500 tok/min은 달리기여야 한다
        let afterTyping = Pace.Input.Sources(claude: .running, typing: .dashing)
        let claudeOnly = Pace.decide(.init(claudeRate: 8_500, claudeWorking: true, typingRate: nil, keyIdle: 30, away: 0,
                                           previous: afterTyping), claude: claude, keys: keys)
        #expect(claudeOnly.state == .running)
        // 자기 출처가 질주였으면 경계 근처에서 이어 간다
        let own = Pace.decide(.init(claudeRate: 0, claudeWorking: false, typingRate: 205, keyIdle: 0.3, away: 0,
                                    previous: .init(typing: .dashing)), claude: claude, keys: keys)
        #expect(own.state == .dashing)
        #expect(own.sources == .init(typing: .dashing))
    }

    @Test func speedScalesOnlyMovingStates() {
        for state in [CatState.walking, .running, .dashing, .rainbow] {
            #expect(Pace.scaledTempo(1.2, state: state, speed: 0.5) == 0.6)
        }
        for state in [CatState.sleeping, .standing, .looking, .waiting] {
            #expect(Pace.scaledTempo(1, state: state, speed: 2) == 1)
        }
        #expect(Pace.scaledTempo(1.1, state: .running, speed: 1) == 1.1)
    }

    @Test func slowerAtNight() {
        let day = Pace.decide(.init(claudeRate: 5_000, claudeWorking: true, typingRate: nil, keyIdle: 9, away: 0),
                              claude: claude, keys: keys)
        let night = Pace.decide(.init(claudeRate: 5_000, claudeWorking: true, typingRate: nil, keyIdle: 9, away: 0, night: true),
                                claude: claude, keys: keys)
        #expect(night.state == day.state)
        #expect(abs(night.tempo - day.tempo * Pace.nightTempo) < 0.0001)
        // 서 있을 때는 빠르기가 없다
        #expect(Pace.decide(.init(claudeRate: 0, claudeWorking: false, typingRate: nil, keyIdle: 9, away: 0, night: true),
                            claude: claude, keys: keys).tempo == 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func at(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: hour, minute: 30))! }
        #expect(Pace.isNight(at(0), calendar: calendar))
        #expect(Pace.isNight(at(4), calendar: calendar))
        #expect(!Pace.isNight(at(5), calendar: calendar))
        #expect(!Pace.isNight(at(23), calendar: calendar))
    }

    @Test func onlyMovingStagesKeepRunningUnderLimit() {
        #expect(!CatState.sleeping.isMoving && !CatState.standing.isMoving && !CatState.looking.isMoving)
        #expect(CatState.walking.isMoving && CatState.rainbow.isMoving)
    }
}
