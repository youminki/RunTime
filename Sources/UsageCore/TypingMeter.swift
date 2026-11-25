import Foundation

/// 키 누름 횟수로 타자 빠르기(타/분)를 잰다. 최근 `window`초를 평균하되, 쉬다가 다시 치면 쉰 구간을 빼고
/// 치기 직전부터 잰다. 쉰 시간까지 나누면 치기 시작한 뒤 몇 초 동안 실제보다 느리게 나온다.
public struct TypingMeter: Sendable {
    public let window: TimeInterval
    private var samples: [(at: Date, count: UInt32)] = []

    public init(window: TimeInterval = 3) {
        self.window = window
    }

    public mutating func reset() {
        samples = []
    }

    /// 지금까지 누른 키 수(시스템 누적값)를 넣고 타/분을 받는다.
    public mutating func rate(count: UInt32, now: Date) -> Double {
        // 누적값이 줄었으면 다시 센 것이다 (재시동 등)
        if let last = samples.last, count < last.count { samples = [] }
        samples.append((now, count))
        if let cut = samples.lastIndex(where: { now.timeIntervalSince($0.at) >= window }) {
            samples.removeFirst(cut)
        }
        // 앞쪽의 쉰 구간을 덜어 내고, 치기 직전 표본 하나를 기준으로 남긴다
        while samples.count > 2, samples[0].count == samples[1].count {
            samples.removeFirst()
        }
        guard let first = samples.first, samples.count > 1 else { return 0 }
        return Double(count - first.count) / max(now.timeIntervalSince(first.at), 1) * 60
    }
}
