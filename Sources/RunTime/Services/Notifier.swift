import Foundation
import UserNotifications

/// macOS 알림 (§F4). UNUserNotificationCenter는 번들 앱에서만 동작 —
/// `swift run` 개발 실행(번들 ID 없음)에서는 조용히 비활성화된다.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Notifier()

    /// 알림을 눌렀을 때 열 화면.
    enum Destination: String {
        case usage, daily, workLog, design, hosts
        /// Claude Code가 일하던 앱. `context`에 작업 폴더 이름을 싣는다.
        case claude
    }

    /// 번들 앱(.app)으로 실행 중일 때만 사용 가능.
    let available = Bundle.main.bundleIdentifier != nil
    /// 알림을 누르면 부른다. 메인 스레드에서 부른다.
    var onOpen: (Destination, _ context: String?) -> Void = { _, _ in }
    /// 시스템 알림 대신 말풍선으로 보일 수 있으면 보이고 true를 돌려준다 (화면에 펫을 꺼내 두었을 때). 메인 스레드에서 부른다.
    /// `destination`이 nil이면 열어 볼 곳이 없는 알림이라 단추 없이 띄운다.
    /// `closesAfter`가 있으면 그만큼 지나 저절로 닫힌다.
    var bubble: (_ title: String, _ body: String, _ destination: Destination?, _ context: String?, _ actionTitle: String?,
                 _ closesAfter: TimeInterval?) -> Bool
        = { _, _, _, _, _, _ in false }
    /// 열어 볼 곳이 없는 안내는 읽을 만큼 두고 저절로 닫는다.
    static let infoLifetime: TimeInterval = 10
    private static let destinationKey = "open"
    private static let contextKey = "context"

    private override init() {}

    /// 시스템 설정에서 고른 알림 스타일. 사용자만 바꿀 수 있다.
    enum Style { case alert, banner, off }

    /// 지금 알림 스타일을 메인 스레드로 돌려준다.
    func style(_ done: @escaping (Style) -> Void) {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let style: Style = switch settings.alertStyle {
            case .alert: .alert
            case .banner: .banner
            default: .off
            }
            DispatchQueue.main.async { done(style) }
        }
    }

    func requestAuthorization() {
        guard available else { return }
        // 앱이 앞에 있을 때(설정 창·사용량 창이 열려 있을 때)도 배너를 띄우려면 위임이 있어야 한다
        UNUserNotificationCenter.current().delegate = self
        // 거부돼도 send는 그대로 둔다. 시스템이 표시하지 않을 뿐이다.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `bubbles`가 false면 펫을 꺼내 두어도 시스템 알림으로 보낸다 (말풍선을 따로 띄우는 곳).
    /// `destination`은 눌렀을 때 열 곳. 한도·초기화처럼 열어 볼 게 없는 알림은 비워 두면 단추도 없다.
    /// `context`는 열 곳에 넘길 값 (Claude 작업 끝 알림의 작업 폴더 이름), `actionTitle`은 말풍선 단추 이름.
    func send(title: String, body: String, opens destination: Destination? = nil, context: String? = nil,
              actionTitle: String? = nil, bubbles: Bool = true, stays: Bool = false, closesAfter: TimeInterval? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.send(title: title, body: body, opens: destination, context: context, actionTitle: actionTitle, bubbles: bubbles,
                          stays: stays, closesAfter: closesAfter)
            }
            return
        }
        // 할 일이 남은 알림(한도, 실패)은 사람이 닫을 때까지 둔다
        let lifetime = stays ? nil : closesAfter ?? (destination == nil ? Self.infoLifetime : nil)
        if bubbles, bubble(title, body, destination, context, actionTitle, lifetime) { return }
        guard available else {
            NSLog("[RunTime] (알림 비활성 — 번들 앱 아님) %@ %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let destination { content.userInfo = [Self.destinationKey: destination.rawValue, Self.contextKey: context ?? ""] }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let raw = response.notification.request.content.userInfo[Self.destinationKey] as? String
            let context = (response.notification.request.content.userInfo[Self.contextKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // 열 곳이 없는 알림은 누르면 닫히기만 한다
            if let destination = raw.flatMap(Destination.init(rawValue:)) {
                DispatchQueue.main.async { self.onOpen(destination, context) }
            }
        }
        completionHandler()
    }
}
