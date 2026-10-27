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
            } else if raw.first?.isWhitespace == true {
                // 묶어 쓴 하위 줄은 카드가 앞 빈칸을 지우므로 넓은 빈칸으로 들여 쓴다
                body.append(["type": "TextBlock", "text": "\u{2003}" + line, "spacing": "None", "wrap": true])
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

    /// 실패 응답을 고칠 수 있는 말로. 템플릿 기본값(회사 사용자만 실행)이면 OAuth를 요구해 401이 온다.
    public static func failure(status: Int?, body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        if text.contains("DirectApiAuthorizationRequired") || status == 401 {
            return "워크플로가 회사 계정 인증을 요구합니다. ‘흐름을 트리거할 수 있는 사람’을 ‘누구나’로 바꿔야 합니다."
        }
        if status == 404 { return "워크플로를 찾지 못했습니다. 지웠거나 꺼져 있는지 보세요. (404)" }
        if status == 400 { return "워크플로가 카드 꼴을 받지 않았습니다. ‘웹후크 경고를 채팅으로 보내기’ 템플릿인지 보세요. (400)" }
        return "팀즈가 받지 않았습니다 (HTTP \(status ?? 0))"
    }

    /// 트리거를 ‘누구나’로 두면 주소에 서명(`sig`)이 붙는다. 없으면 회사 계정 토큰을 요구해 앱이 보낼 수 없다.
    public static func needsAnyone(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.path.contains("/workflows/") else { return false }
        return !(parts.queryItems ?? []).contains { $0.name == "sig" && !($0.value ?? "").isEmpty }
    }

    /// 주소가 가리키는 워크플로 (`/workflows/<id>/`). 서명만 바뀐 새 주소가 같은 흐름인지 볼 때 쓴다.
    public static func workflowID(_ text: String) -> String? {
        guard let path = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.path,
              let range = path.range(of: "/workflows/") else { return nil }
        let id = path[range.upperBound...].prefix { $0 != "/" }
        return id.isEmpty ? nil : id.lowercased()
    }

    /// 웹훅 주소가 속한 환경의 Power Automate ‘내 흐름’ 화면.
    /// 호스트 `default9cc8…4249.a6.environment.api.powerplatform.com`은 환경 ID(`Default-9cc8…-…49a6`)를 점 하나 넣어 쓴 것이다.
    /// 주소의 워크플로 ID는 흐름 ID와 달라 흐름 화면으로 바로 가지 못한다.
    public static func flowsURL(_ text: String) -> URL? {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
              host.hasSuffix(".environment.api.powerplatform.com") else { return URL(string: "https://make.powerautomate.com/") }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return nil }
        var environment = String(labels[0] + labels[1])
        let isDefault = environment.hasPrefix("default")
        if isDefault { environment.removeFirst("default".count) }
        guard let environmentGUID = guid(environment) else { return URL(string: "https://make.powerautomate.com/") }
        return URL(string: "https://make.powerautomate.com/environments/\(isDefault ? "Default-" : "")\(environmentGUID)/flows")
    }

    /// 32자리 16진수 → 8-4-4-4-12. 이미 줄표가 있으면 그대로.
    static func guid(_ text: String) -> String? {
        let hex = text.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        var parts: [Substring] = []
        var rest = Substring(hex)
        for length in [8, 4, 4, 4, 12] {
            parts.append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return parts.joined(separator: "-")
    }

    public static func request(url: URL, report: String, title: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try payload(report, title: title)
        return request
    }
}
