import Foundation

/// 새로 읽은 기록에서 Claude가 방금 대화 차례를 마친 때와, 그 차례에 얼마나 일했는지를 찾는다.
/// 한 응답이 여러 줄로 기록돼 같은 메시지가 여러 번 나오고, 앱을 켤 때는 지난 기록을 한꺼번에 읽으므로 둘 다 거른다.
public struct TurnEndDetector {
    public struct FinishedTurn: Equatable {
        public let project: String?
        public let endedAt: Date
        /// 차례가 끝나기 전 첫 응답부터 끝날 때까지. 사람이 보낸 글은 기록에 시각만 있고 토큰이 없어 응답부터 센다.
        public let duration: TimeInterval

        /// 축하할 만큼 오래 걸린 작업.
        public static let longDuration: TimeInterval = 10 * 60
        public var isLong: Bool { duration >= Self.longDuration }
    }

    /// 이보다 오래된 기록은 지금 끝난 것이 아니다.
    public var maxAge: TimeInterval = 60
    /// 이만큼 쉬었다가 온 응답은 새 차례의 시작으로 본다 (끝 표시가 빠진 차례가 다음 차례에 붙지 않게).
    public var idleGap: TimeInterval = 10 * 60
    private var announced: Set<String> = []
    /// 폴더별 이번 차례의 첫 응답과 마지막 응답 시각.
    private var started: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]

    public init() {}

    /// 아직 끝나지 않은 차례가 있는지. 도구를 오래 돌려 기록이 잠시 끊겨도 일하는 중으로 본다.
    /// 끝 표시 없이 멈춘 차례(중단 등)는 `within`이 지나면 끝난 것으로 본다.
    public func isWorking(now: Date, within: TimeInterval) -> Bool {
        started.keys.contains { lastSeen[$0].map { now.timeIntervalSince($0) < within } ?? false }
    }

    /// 방금 끝난 차례들. 같은 메시지는 한 번만.
    public mutating func finishedTurns(in events: [UsageEvent], now: Date) -> [FinishedTurn] {
        if announced.count > 1000 { announced.removeAll() }
        var finished: [FinishedTurn] = []
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            let project = event.project ?? ""
            if let last = lastSeen[project], event.timestamp.timeIntervalSince(last) > idleGap { started[project] = nil }
            lastSeen[project] = max(event.timestamp, lastSeen[project] ?? .distantPast)
            if started[project] == nil { started[project] = event.timestamp }
            guard event.endsTurn else { continue }
            let start = started.removeValue(forKey: project) ?? event.timestamp
            guard now.timeIntervalSince(event.timestamp) <= maxAge, announced.insert(event.messageId).inserted else { continue }
            finished.append(FinishedTurn(project: event.project, endedAt: event.timestamp,
                                         duration: max(0, event.timestamp.timeIntervalSince(start))))
        }
        return finished
    }
}
