import Foundation

/// 메인 스레드가 오래 응답하지 않은 일. 앱이 멈춘 동안 떠 둔 메인 스레드의 호출 순서를 담는다.
/// 멈춘 채 강제로 꺼지면 다음에 켤 때 보내야 해서 저장할 수 있게 둔다.
public struct HangReport: Equatable, Codable {
    /// 저장해 둔 여러 멈춤 가운데 보낸 것만 지우는 열쇠.
    public var id: String
    /// 멈춘 시간(초). 1초마다 묻는 사이에 멈추기 시작하면 1초까지 덜 잴 수 있다. 끝나지 않았으면 호출 순서를 뜬 때까지의 시간이다.
    public var seconds: Double
    /// 메인 스레드가 다시 응답했는지. 아니면 멈춘 채 꺼진 것이다.
    public var ended: Bool
    public var frames: [CrashReport.Frame]
    public var base: Int?
    public var uuid: String
    public var arch: String
    public var app: String
    public var commit: String
    /// `yyyy-MM-dd HH:mm:ss`. 이때까지의 진단 기록을 붙인다.
    public var at: String
    /// 멈춘 순간의 앱·시스템 상태 (`앱 메모리 820MB`, `시스템 메모리 압박: 경고` 등). 호출 순서에 앱 코드가 없을 때
    /// 앱 탓인지 시스템 부하 탓인지 가린다. 옛 버전이 저장해 둔 보고에는 없다.
    public var context: [String]?

    public init(id: String = UUID().uuidString, seconds: Double, ended: Bool, frames: [CrashReport.Frame], base: Int?, uuid: String, arch: String,
                app: String, commit: String, at: String, context: [String]? = nil) {
        self.id = id
        (self.seconds, self.ended, self.frames, self.base, self.uuid, self.arch) = (seconds, ended, frames, base, uuid, arch)
        (self.app, self.commit, self.at, self.context) = (app, commit, at, context)
    }

    /// 메일 제목·묶음 열쇠. 서버가 "앱 멈춤"을 앞에 붙이므로 멈춘 자리만 둔다. 멈춘 시간은 매번 달라서 넣지 않는다.
    public var summary: String {
        CrashReport.place(frames) ?? "메인 스레드가 응답하지 않음"
    }

    public func detail(limit: Int = 2000) -> String {
        let length = String(format: "%.1f초", seconds)
        let head = ["멈춘 시각: \(at)",
                    ended ? "메인 스레드가 \(length) 넘게 응답하지 않다가 돌아옴" : "메인 스레드가 \(length) 넘게 응답하지 않은 채 앱이 꺼짐"]
            + (context ?? [])
        return CrashReport.stack(head: head, title: "멈춘 메인 스레드", frames: frames, base: base, uuid: uuid, arch: arch, limit: limit)
    }

    /// 지켜보는 스레드가 정하는 일. 응답이 `threshold`초 넘게 없으면 한 번만 호출 순서를 뜨고, 응답이 오면 알린다.
    public enum Step: Equatable {
        case wait
        case sample
        case report(seconds: Double)
        case ping
    }

    /// `waited`는 마지막으로 메인 스레드에 물은 뒤 지난 초, `answered`는 그 물음에 답한 데 걸린 초(아직이면 nil).
    /// 시스템이 잠들면 지켜보는 스레드도 멈추고 시계(uptime)도 서서, 잠든 시간은 멈춤으로 세지 않는다.
    public static func step(waited: Double, answered: Double?, sampled: Bool, threshold: Double) -> Step {
        if let answered { return sampled ? .report(seconds: answered) : .ping }
        return waited >= threshold && !sampled ? .sample : .wait
    }
}
