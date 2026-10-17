import Foundation

/// 한도 임박 단계 (§F2 오버라이드: 80% 지침, 95% 경고).
public enum UsageAlertLevel: Int, Comparable, Sendable {
    case normal = 0
    case tired = 1      // 사용률 80% 이상
    case critical = 2   // 사용률 95% 이상

    public static func level(percent: Double) -> UsageAlertLevel {
        if percent >= 95 { return .critical }
        if percent >= 80 { return .tired }
        return .normal
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 80%/95% 알림을 창(세션/주간)별로 각 1회만 발송하도록 추적 (§F4, §7).
/// 창 식별자(windowId)가 바뀌면(리셋) 해당 종류의 기록을 새로 시작한다.
public struct LimitAlertTracker {

    public enum Kind: String, Sendable { case session, weekly }
    public enum Threshold: Int, Sendable { case eighty = 80, ninetyFive = 95 }

    private var sent: [Kind.RawValue: (windowId: String, thresholds: Set<Int>)] = [:]

    public init() {}

    /// 앱을 다시 켜도 같은 창에서 다시 알리지 않게 저장해 두는 값. 종류 → "창ID|80,95".
    public var saved: [String: String] {
        get { sent.mapValues { "\($0.windowId)|\($0.thresholds.sorted().map(String.init).joined(separator: ","))" } }
        set {
            sent = newValue.compactMapValues { value in
                let parts = value.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), Set(parts[1].split(separator: ",").compactMap { Int($0) }))
            }
        }
    }

    /// 창 식별자. resets_at은 조회마다 1초 안쪽으로 흔들려 그대로 쓰면 매 조회가 새 창으로 보이고
    /// 80%/95% 알림이 반복된다. 분 단위로 반올림한다.
    public static func windowId(resetsAt: Date) -> String {
        "\(Int((resetsAt.timeIntervalSince1970 / 60).rounded()))"
    }

    /// 현재 사용률을 보고하고, 새로 발송해야 할 알림 임계값을 반환 (없으면 빈 배열).
    /// 70→96처럼 건너뛰면 95만 발송 (80은 함께 소진 처리해 스팸 방지).
    public mutating func alertsToFire(kind: Kind, percent: Double, windowId: String) -> [Threshold] {
        var record = sent[kind.rawValue] ?? (windowId, [])
        if record.windowId != windowId { record = (windowId, []) }   // 창 리셋 → 기록 초기화

        var fired: [Threshold] = []
        if percent >= 95, !record.thresholds.contains(95) {
            record.thresholds.formUnion([80, 95])
            fired.append(.ninetyFive)
        } else if percent >= 80, !record.thresholds.contains(80) {
            record.thresholds.insert(80)
            fired.append(.eighty)
        }
        sent[kind.rawValue] = record
        return fired
    }
}
