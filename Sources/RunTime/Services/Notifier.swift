import Foundation
import UserNotifications

/// macOS 알림 (§F4). UNUserNotificationCenter는 번들 앱에서만 동작 —
/// `swift run` 개발 실행(번들 ID 없음)에서는 조용히 비활성화된다.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Notifier()

    /// 알림을 눌렀을 때 열 화면.
    enum Destination: String {
        case usage, daily, workLog
    }

    /// 번들 앱(.app)으로 실행 중일 때만 사용 가능.
    let available = Bundle.main.bundleIdentifier != nil
    /// 알림을 누르면 부른다. 메인 스레드에서 부른다.
    var onOpen: (Destination) -> Void = { _ in }
    private static let destinationKey = "open"

    private override init() {}

    func requestAuthorization() {
        guard available else { return }
        // 앱이 앞에 있을 때(설정 창·사용량 창이 열려 있을 때)도 배너를 띄우려면 위임이 있어야 한다
        UNUserNotificationCenter.current().delegate = self
        // 거부돼도 send는 그대로 둔다. 시스템이 표시하지 않을 뿐이다.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String, opens destination: Destination = .usage) {
        guard available else {
            NSLog("[RunTime] (알림 비활성 — 번들 앱 아님) %@ %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.destinationKey: destination.rawValue]
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
            let destination = raw.flatMap(Destination.init(rawValue:)) ?? .usage
            DispatchQueue.main.async { self.onOpen(destination) }
        }
        completionHandler()
    }
}
