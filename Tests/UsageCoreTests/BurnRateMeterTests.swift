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
