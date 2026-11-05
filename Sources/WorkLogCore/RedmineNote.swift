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

    /// `&quot;` 같은 HTML 기호를 글자로. `&amp;`는 맨 뒤에 풀어 `&amp;lt;`가 `<`가 되지 않게 한다.
    public static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, letter) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                 ("&middot;", "·"), ("&nbsp;", " "), ("&hellip;", "…"), ("&rarr;", "→")] {
            result = result.replacingOccurrences(of: entity, with: letter)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 화면에 보일 링크 글. 길면 호스트와 경로 앞부분만 남기고, 피그마는 이름으로 쓴다.
    public static func linkLabel(_ url: URL) -> String {
        let text = url.absoluteString
        guard text.count > 48, let host = url.host else { return text }
        if host.hasSuffix("figma.com") { return "Figma 열기" }
        return host + String(url.path.prefix(24)) + "…"
    }

    /// 화면에 그리기 전에 외부 자원을 그 자리에서 받는 꼴을 지운다. HTML 해석기는 그림을 메인 스레드에서 내려받아
    /// 화면이 멈추고 추적 그림이 새어 나갈 수 있다. 그림은 `[이미지]` 자리만 남기고, 원본은 첨부에서 연다.
    public static func safeHTML(_ html: String) -> String {
        let attr = #"(?:[^>"']|"[^"]*"|'[^']*')*"#
        let steps: [(String, String)] = [
            // 짝이 있는 요소는 내용째 지운다
            (#"<(script|style|iframe|object|video|audio|svg|noscript|template)\b"# + attr + #">[\s\S]*?</\1\s*>"#, ""),
            (#"<(img|image)\b"# + attr + ">", "[이미지]"),
            (#"<(script|style|iframe|object|embed|video|audio|svg|link|source|input|meta|base)\b"# + attr + ">", ""),
            (#"\s(background|srcset|poster)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, ""),
            (#"(url|image-set)\s*\([^)]*\)"#, ""),
        ]
        var result = html
        for (pattern, replacement) in steps {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    /// 본문의 `<img>`가 가리키는 주소나 파일 이름.
    public static func imageSources(_ html: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) else { return [] }
        return pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    /// 평문으로 고쳐도 잃는 것이 없는 HTML의 평문. 문단·줄바꿈 말고 다른 서식(목록·표·링크·그림)이 있거나
    /// `html`로 되돌렸을 때 보이는 글이 달라지면 nil이다. 그때는 HTML 그대로 고쳐야 내용이 상하지 않는다.
    public static func editable(_ html: String) -> String? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmed
        for (pattern, replacement) in [(#"</p>\s*<p>"#, "\n\n"), (#"<br\s*/?>\s*"#, "\n"), (#"</?p>"#, "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        guard !text.contains("<") else { return nil }
        text = decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
        func visible(_ source: String) -> String {
            source.replacingOccurrences(of: #"</?p>|<br\s*/?>|\s"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return visible(Self.html(text)) == visible(trimmed) ? text : nil
    }

    /// 레드마인에 남은 HTML 댓글을 평문으로 (보낸 댓글을 다시 찾을 때 비교용).
    public static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "</p>", with: "\n")
        while let open = text.range(of: "<"), let close = text.range(of: ">", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = decodeEntities(text)
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
