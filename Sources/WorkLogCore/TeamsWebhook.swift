import Foundation

/// 팀즈 Workflows 웹훅("웹후크 요청을 받으면 채널에 게시")에 보낼 적응형 카드.
/// 옛 Office 365 커넥터 웹훅은 꺼져서 Workflows 꼴(attachments 안의 적응형 카드)로 보낸다.
public enum TeamsWebhook {
    public static func payload(_ report: String, title: String) throws -> Data {
        var body: [[String: Any]] = [[
            "type": "TextBlock", "text": title, "weight": "Bolder", "size": "Medium", "wrap": true,
        ]]
        for raw in report.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                // [주간 진행 사항], [차주 계획] 같은 머리
                body.append(["type": "TextBlock", "text": line, "weight": "Bolder", "spacing": "Medium", "wrap": true])
            } else if line.first?.isNumber == true {
                body.append(["type": "TextBlock", "text": line, "weight": "Bolder", "spacing": "Small", "wrap": true])
            } else {
                body.append(["type": "TextBlock", "text": line, "spacing": "None", "wrap": true])
            }
        }
        let card: [String: Any] = [
            "type": "AdaptiveCard",
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "version": "1.4",
            "body": body,
        ]
        let message: [String: Any] = [
            "type": "message",
            "attachments": [["contentType": "application/vnd.microsoft.card.adaptive", "content": card]],
        ]
        return try JSONSerialization.data(withJSONObject: message)
    }

    /// Workflows 웹훅 주소만 받는다 (https, logic.azure.com·powerplatform 등). 다른 주소에 보고서를 보내지 않게.
    public static func isValid(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        // 점 경계로 맞춘다 (evil-office.com이 office.com으로 통과하지 않게)
        return ["logic.azure.com", "powerplatform.com", "powerautomate.com", "office.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    public static func request(url: URL, report: String, title: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try payload(report, title: title)
        return request
    }
}
