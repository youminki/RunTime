import AppKit
import ApplicationServices
import WorkLogCore

/// 팀즈 설정 화면이 열려 있는 동안 클립보드를 보고, 채팅 링크나 웹훅 주소를 복사하면 알맞은 칸에 저장한다.
/// 팀즈에서 ‘링크 복사’, Power Automate에서 ‘URL 복사’만 누르면 연결이 끝나게 하려는 것이다. 다른 글은 읽고 버린다.
final class TeamsLinker: ObservableObject {
    static let shared = TeamsLinker()

    /// 새 워크플로 주소를 넣을 칸. 이미 저장한 워크플로의 새 주소면 그 칸에 넣는다.
    @Published var preferred: TeamsTarget = .me
    @Published private(set) var status: String?
    @Published private(set) var failed = false
    @Published private(set) var watching = false
    /// 손쉬운 사용 권한 (붙여넣기 자동). 시스템 설정에서 켜고 돌아오면 바로 보이게 같이 본다.
    @Published private(set) var accessibility = AXIsProcessTrusted()

    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private var handled: String?
    private let settings = WorkLogSettings.shared

    func start() {
        guard timer == nil else { return }
        // 화면을 열기 전에 복사해 둔 것은 붙여넣기 단추로 넣는다. 예전에 복사한 주소를 다시 넣지 않게.
        changeCount = NSPasteboard.general.changeCount
        // 나에게는 설정 없이 나와의 채팅으로 가니, 새 링크는 대개 보고 채팅 것이다
        preferred = .chat
        handled = nil
        watching = true
        accessibility = AXIsProcessTrusted()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watching = false
    }

    private func poll() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility { accessibility = trusted }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text != handled, TeamsLink.isValid(text) || (TeamsWebhook.isValid(text) && TeamsWebhook.workflowID(text) != nil)
        else { return }
        handled = text
        // 이미 채운 칸을 다른 채팅으로 말없이 바꾸지 않는다 (동료에게 주려고 복사한 링크일 수 있다).
        // 서명만 바뀐 같은 워크플로 주소와 빈 칸만 저절로 넣는다
        let workflowTarget = TeamsWebhook.workflowID(text).flatMap(settings.teamsTarget(forWorkflow:))
        let target = workflowTarget ?? (TeamsLink.conversationID(text) == "48:notes" ? .me : preferred)
        let filled = settings.teamsLinks[target] != nil || settings.hasWebhook(target)
        guard workflowTarget != nil || !filled else {
            show("팀즈 링크를 복사했습니다. \(target.name)을 이 채팅으로 바꾸려면 ‘링크 붙여넣기’를 누르세요.", failed: false)
            return
        }
        link(text, to: target)
    }

    /// 링크나 주소 하나를 칸에 넣는다. 서명 있는 웹훅이면 바로 시험 글을 보낸다.
    @discardableResult
    func link(_ text: String, to chosen: TeamsTarget? = nil) -> String? {
        if TeamsLink.isValid(text) {
            // 나와의 채팅 링크는 어느 칸을 골랐든 나에게로
            let target = chosen ?? (TeamsLink.conversationID(text) == "48:notes" ? .me : preferred)
            if let problem = settings.setTeams(text, target: target) { show(problem, failed: true); return problem }
            show("\(target.name)에 \(TeamsLink.kind(text)) 링크를 넣었습니다. 시험 보내기로 확인하세요.", failed: false)
            return nil
        }
        let target = chosen ?? TeamsWebhook.workflowID(text).flatMap(settings.teamsTarget(forWorkflow:)) ?? preferred
        if let problem = settings.setTeams(text, target: target) {
            show(problem, failed: true)
            return problem
        }
        if TeamsWebhook.needsAnyone(text) {
            show("\(target.name) 웹훅을 저장했지만 회사 계정 인증 주소라 지금은 채팅을 열어 붙여 넣는 길로 보냅니다.", failed: true)
            return nil
        }
        show("\(target.name) 웹훅을 저장했습니다. 시험 글을 보내는 중…", failed: false)
        WorkLogSync.shared.postTeams(Self.testReport, title: Self.testTitle, to: target, fallback: false) { [weak self] message, failed in
            self?.show(failed ? message : "\(target.name) 웹훅 연결 완료. 팀즈에 시험 카드가 왔는지 보세요.", failed: failed)
        }
        return nil
    }

    private func show(_ message: String, failed: Bool) {
        status = message
        self.failed = failed
    }

    static let testReport = "[시험] RunTime 업무 일지\n1. 연결 확인\n- 이 카드가 보이면 팀즈 채팅과 연결됐습니다 (완료)"
    static var testTitle: String { "RunTime 연결 시험 · \(WorkLogFormat.when(Date()))" }
}
