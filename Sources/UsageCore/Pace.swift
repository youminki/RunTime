import Foundation

/// 러너의 지금 단계. Claude가 일하는 동안이나 타자를 치는 동안만 움직이고, 멈추면 바로 서고, 자리를 비우면 잔다.
/// 멈춘 채 마우스를 쓰고 있으면 둘러보고, 늦은 밤에는 걸음이 느려진다. Claude가 승인을 기다리면 무엇보다 먼저 알린다.
public enum Pace {
    public struct Input: Sendable {
        /// Claude 토큰 속도 (토큰/분).
        public var claudeRate: Double
        /// 끝나지 않은 Claude 차례가 있다.
        public var claudeWorking: Bool
        /// 타자 속도 (타/분). nil이면 타자에 반응하지 않는다.
        public var typingRate: Double?
        /// 마지막 키 누름 뒤 지난 시간.
        public var keyIdle: TimeInterval
        /// 마지막 Claude 기록이나 입력 뒤 지난 시간. 이만큼 자리를 비우면 잔다.
        public var away: TimeInterval
        /// 마지막 마우스·트랙패드 입력 뒤 지난 시간.
        public var pointerIdle: TimeInterval
        public var night: Bool
        /// Claude가 도구 승인을 기다린다.
        public var waiting: Bool

        public init(claudeRate: Double, claudeWorking: Bool, typingRate: Double?, keyIdle: TimeInterval, away: TimeInterval,
                    pointerIdle: TimeInterval = .infinity, night: Bool = false, waiting: Bool = false) {
            self.claudeRate = claudeRate
            self.claudeWorking = claudeWorking
            self.typingRate = typingRate
            self.keyIdle = keyIdle
            self.away = away
            self.pointerIdle = pointerIdle
            self.night = night
            self.waiting = waiting
        }
    }

    /// 단계와 그 단계 안의 빠르기. Claude와 타자가 함께 움직이면 빠른 쪽을 따른다.
    public static func decide(_ input: Input, claude: Thresholds, keys: Thresholds) -> (state: CatState, tempo: Double) {
        if input.waiting { return (.waiting, 1) }
        var moves: [(CatState, Double)] = []
        if input.claudeWorking {
            let state = claude.moving(burnRate: input.claudeRate)
            moves.append((state, claude.tempo(burnRate: input.claudeRate, state: state)))
        }
        if let rate = input.typingRate, input.keyIdle < keys.stopAfter {
            let state = keys.moving(burnRate: rate)
            moves.append((state, keys.tempo(burnRate: rate, state: state)))
        }
        if let fastest = moves.max(by: { rank($0.0) < rank($1.0) }) {
            return (fastest.0, input.night ? fastest.1 * nightTempo : fastest.1)
        }
        if input.away >= claude.sleepAfterIdle { return (.sleeping, 1) }
        return (input.pointerIdle < lookAfter ? .looking : .standing, 1)
    }

    /// 마우스를 이만큼 쉬면 둘러보기를 멈추고 선다. 스크롤하며 읽는 사이 잠깐씩 멈추는 동안은 이어 둘러본다.
    public static let lookAfter: TimeInterval = 8
    /// 늦은 밤의 걸음 빠르기 배율.
    public static let nightTempo = 0.8

    /// 자정부터 새벽 5시까지.
    public static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: date) < 5
    }

    private static func rank(_ state: CatState) -> Int { CatState.allCases.firstIndex(of: state) ?? 0 }
}
