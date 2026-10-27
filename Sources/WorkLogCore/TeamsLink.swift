import Foundation

/// 팀즈 채팅 링크(채팅 ⋯ > 링크 복사). 웹훅 없이 그 채팅을 팀즈 앱에서 열어 보고서를 붙여 넣는 데 쓴다.
public enum TeamsLink {
    /// 나와의 채팅. 대화 ID `48:notes`는 누구에게나 같아 설정 없이 쓴다.
    public static let notes = "https://teams.cloud.microsoft/l/chat/48:notes/conversations"

    private static let hosts = ["teams.cloud.microsoft", "teams.microsoft.com", "teams.live.com"]

    public static func isValid(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              let host = url.host?.lowercased(), hosts.contains(host) else { return false }
        return ["/l/chat/", "/l/channel/", "/l/message/"].contains { url.path.hasPrefix($0) }
    }

    /// 링크가 가리키는 대화 ID (`48:notes`, `19:…@thread.v2`).
    public static func conversationID(_ text: String) -> String? {
        guard let path = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.path else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "l" else { return nil }
        return String(parts[2]).removingPercentEncoding
    }

    /// 사람이 알아볼 이름. 링크에는 채팅 이름이 없어 종류만 쓴다.
    public static func kind(_ text: String) -> String {
        guard let id = conversationID(text) else { return "팀즈 채팅" }
        if id == "48:notes" { return "나와의 채팅" }
        if text.contains("/l/channel/") { return "채널" }
        if id.hasSuffix("@unq.gbl.spaces") { return "1:1 채팅" }
        return "그룹 채팅"
    }

    /// 데스크톱 팀즈가 받는 꼴 (`msteams:/l/chat/…`).
    public static func appURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return URL(string: "msteams:" + parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? ""))
    }

    /// 팀즈 입력 칸에 붙여 넣을 서식 글. 제목과 머리(`[주간 진행 사항]`, `1. 프로젝트`)를 굵게 쓴다.
    public static func html(_ report: String, title: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var lines = ["<b>\(escape(title))</b>"]
        for raw in report.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let bold = line.hasPrefix("[") || line.first?.isNumber == true
            // 묶어 쓴 하위 줄은 붙여 넣으면 앞 빈칸이 사라져 넓은 빈칸으로 들여 쓴다
            let indent = raw.first?.isWhitespace == true ? "\u{2003}" : ""
            lines.append(indent + (bold ? "<b>\(escape(line))</b>" : escape(line)))
        }
        return lines.joined(separator: "<br>")
    }

    /// 서식을 받지 않는 곳에 붙일 평문.
    public static func plain(_ report: String, title: String) -> String {
        title + "\n" + report.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }
}
