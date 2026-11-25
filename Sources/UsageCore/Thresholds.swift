import Foundation

/// 고양이 상태 (§F2 5단계 상태 머신).
public enum CatState: String, CaseIterable, Sendable {
    case sleeping   // 0 tok/min, 5분 이상 무활동
    case standing   // 일을 멈췄다: Claude 차례가 끝났거나 타자를 멈춤
    case looking    // 멈춘 채 마우스·트랙패드를 쓰는 중: 읽거나 둘러본다
    case waiting    // Claude가 도구 승인을 기다린다
    case walking    // 1 ~ 2,000
    case running    // 2,000 ~ 10,000
    case dashing    // 10,000 ~ 30,000
    case rainbow    // 30,000+

    public var label: String {
        switch self {
        case .sleeping: return "쉬는 중"
        case .standing: return "멈춘 중"
        case .looking:  return "살펴보는 중"
        case .waiting:  return "승인 기다리는 중"
        case .walking:  return "걷는 중"
        case .running:  return "달리는 중"
        case .dashing:  return "질주 중"
        case .rainbow:  return "전력 질주"
        }
    }

    /// 걷거나 달리는 단계인지. 제자리 단계(잠, 멈춤, 살펴보기)는 한도 경고 자세로 바뀐다.
    public var isMoving: Bool {
        switch self {
        case .sleeping, .standing, .looking, .waiting: return false
        case .walking, .running, .dashing, .rainbow: return true
        }
    }
}

public struct Thresholds: Sendable {
    /// tokens/min 경계값. 민감도 조절 시 이 값들에 배율을 곱한다.
    public var walk: Double = 1
    public var run: Double = 2_000
    public var dash: Double = 10_000
    public var rainbow: Double = 30_000

    /// 무활동 → 잠자기 전환 시간 (5분).
    public var sleepAfterIdle: TimeInterval = 5 * 60
    /// 마지막 입력 뒤 이만큼 지나면 멈춘 것으로 본다. 토큰 기록은 차례 끝으로 알아서 쓰지 않는다.
    public var stopAfter: TimeInterval = .infinity

    public init() {}

    /// 민감도 프리셋 (낮음/보통/높음). 높음 = 적은 토큰으로도 빨리 뛴다.
    public static func preset(sensitivity: Sensitivity) -> Thresholds {
        var t = Thresholds()
        let m = sensitivity.multiplier
        t.run *= m
        t.dash *= m
        t.rainbow *= m
        return t
    }

    /// 키 입력 속도(타/분) 경계. Claude가 쉬는 동안 타자 속도로 러너를 움직일 때 쓴다.
    /// 보통 빠르기로 이어 치면 달리고, 2초 넘게 손을 떼면 멈춘다.
    public static func typing(sensitivity: Sensitivity) -> Thresholds {
        var t = Thresholds()
        let m = sensitivity.multiplier
        t.run = 120 * m
        t.dash = 250 * m
        t.rainbow = 400 * m
        t.stopAfter = 2
        return t
    }

    public enum Sensitivity: String, CaseIterable, Sendable {
        case low, normal, high
        public var displayName: String {
            switch self {
            case .low: return "낮음"
            case .normal: return "보통"
            case .high: return "높음"
            }
        }

        var multiplier: Double {
            switch self {
            case .low: return 2.0
            case .normal: return 1.0
            case .high: return 0.5
            }
        }
    }

    /// 움직이는 중일 때의 단계. 속도가 아무리 낮아도 걷는다.
    public func moving(burnRate: Double) -> CatState {
        switch burnRate {
        case ..<run: return .walking
        case ..<dash: return .running
        case ..<rainbow: return .dashing
        default: return .rainbow
        }
    }

    /// 단계를 내릴 때는 그 단계의 아래 경계보다 이만큼 더 느려져야 내린다: 경계의 20%, 최소 25.
    /// 3초 구간에서 키 한 타가 빠지면 타/분이 15~20 흔들리므로, 낮은 경계에서도 그보다 넓게 잡아 경계 근처에서 깜빡이지 않게 한다.
    /// (토큰 속도에서는 EMA라 흔들림이 작아 단계 내림을 조금 늦출 뿐이다)
    static func downshiftMargin(below floor: Double) -> Double { max(floor * 0.2, 25) }

    /// 앞 단계를 이어 가는 움직임 단계. 올라갈 때는 바로 올리고, 내려갈 때만 경계에 여유를 둔다.
    public func moving(burnRate rate: Double, holding previous: CatState?) -> CatState {
        let state = moving(burnRate: rate)
        guard let previous, let floor = lowerBound(of: previous),
              CatState.allCases.firstIndex(of: previous)! > CatState.allCases.firstIndex(of: state)!,
              rate >= floor - Self.downshiftMargin(below: floor)
        else { return state }
        return previous
    }

    /// 움직이는 단계의 아래 경계. 걷기는 더 내려갈 곳이 없고, 멈춘 단계는 이어 갈 것이 없다.
    private func lowerBound(of state: CatState) -> Double? {
        switch state {
        case .running: return run
        case .dashing: return dash
        case .rainbow: return rainbow
        case .sleeping, .standing, .looking, .waiting, .walking: return nil
        }
    }
}
