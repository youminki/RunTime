import Foundation

/// 레드마인 댓글 꼴. 이 레드마인은 댓글을 HTML로 저장해서 평문 줄바꿈을 보내면 한 줄로 붙는다.
/// 손으로 쓴 댓글과 같은 꼴로 바꾼다: 섹션(`[작업 내용]` 등)마다 `<p>`, 섹션 안의 줄은 `<br />` 뒤 줄바꿈.
public enum RedmineNote {
    public static func html(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 이미 HTML로 쓴 댓글은 그대로 둔다
        if trimmed.hasPrefix("<p") || trimmed.hasPrefix("<div") { return trimmed }
        var sections: [[String]] = []
        var current: [String] = []
        for raw in trimmed.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isHeading(line), !current.isEmpty {
                sections.append(current)
                current = []
            }
            if !line.isEmpty { current.append(escape(line)) }
        }
        if !current.isEmpty { sections.append(current) }
        return sections.map { "<p>" + $0.joined(separator: "<br />\n") + "</p>" }.joined(separator: "\n")
    }

    /// `[작업 내용]`, `[비고]` 같은 섹션 머리.
    static func isHeading(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("]") && line.count <= 20
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 레드마인에 남은 HTML 댓글을 평문으로 (보낸 댓글을 다시 찾을 때 비교용).
    public static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "</p>", with: "\n")
        while let open = text.range(of: "<"), let close = text.range(of: ">", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
