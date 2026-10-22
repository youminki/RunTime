import Foundation

/// MR 본문·댓글에 올린 수정 전·후 화면. 레드마인 댓글에 붙여 올린다.
/// AI 검증 댓글은 항목마다 `**1. 제목** (...): 확인됨` 다음에 `| 수정 전 | 수정 후 |` 표로 그림을 둔다.
/// 손으로 쓴 MR은 `![수정 전](/uploads/...)`처럼 그림 이름이나 바로 위 줄에 수정 전·후를 적는다.
public enum MRScreens {

    public struct Screen: Equatable, Codable {
        public var title: String?
        /// GitLab 업로드 경로 (`/uploads/<해시>/<파일>`). 없으면 그쪽 캡처가 없다.
        public var before: String?
        public var after: String?

        public init(title: String?, before: String?, after: String?) {
            self.title = title
            self.before = before
            self.after = after
        }

        public var images: [(kind: Kind, path: String)] {
            [(Kind.before, before), (.after, after)].compactMap { kind, path in path.map { (kind, $0) } }
        }
    }

    public enum Kind: String, Codable {
        case before, after
        public var label: String { self == .before ? "수정 전" : "수정 후" }
    }

    /// 레드마인 댓글에 붙일 그림 수 한도. 넘치면 앞 항목부터 쓴다.
    public static let maxImages = 8

    /// 본문의 화면과, 화면이 있는 마지막 댓글의 화면. AI 검증은 커밋마다 다시 달려서 마지막 것이 지금 모습이다.
    public static func screens(description: String, notes: [String]) -> [Screen] {
        var result = parse(description)
        if let latest = notes.reversed().lazy.map(parse).first(where: { !$0.isEmpty }) { result += latest }
        // 같은 그림이 본문과 댓글에 함께 있으면 한 번만
        var seen = Set<String>()
        result = result.compactMap { screen in
            var copy = screen
            if let before = copy.before, !seen.insert(before).inserted { copy.before = nil }
            if let after = copy.after, !seen.insert(after).inserted { copy.after = nil }
            return copy.before == nil && copy.after == nil ? nil : copy
        }
        var budget = maxImages
        return result.compactMap { screen in
            guard budget > 0 else { return nil }
            var copy = screen
            if copy.before != nil { if budget > 0 { budget -= 1 } else { copy.before = nil } }
            if copy.after != nil { if budget > 0 { budget -= 1 } else { copy.after = nil } }
            return copy.before == nil && copy.after == nil ? nil : copy
        }
    }

    // MARK: - 글 하나 읽기

    static func parse(_ text: String) -> [Screen] {
        var screens: [Screen] = []
        var title: String?
        var skipping = false
        var columns: [Kind?] = []
        var lastLine = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let heading = heading(line) {
                title = heading
                // 검증에서 문제가 나온 항목의 화면은 완료 댓글에 붙이지 않는다
                skipping = line.contains("문제 있음")
                columns = []
                continue
            }
            if line.hasPrefix("|") {
                let cells = tableCells(line)
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                let images = cells.map(images(in:))
                if images.allSatisfy(\.isEmpty) {
                    let kinds = cells.map(kind(of:))
                    if kinds.contains(where: { $0 != nil }) { columns = kinds }
                    continue
                }
                guard !skipping else { continue }
                var screen = Screen(title: title, before: nil, after: nil)
                for (index, found) in images.enumerated() {
                    for image in found {
                        let label = (index < columns.count ? columns[index] : nil) ?? kind(of: image.alt)
                        assign(image.path, kind: label, to: &screen)
                    }
                }
                if screen.before != nil || screen.after != nil { screens.append(screen) }
                continue
            }
            columns = []
            let found = images(in: line)
            if found.isEmpty {
                if !line.isEmpty { lastLine = line }
                continue
            }
            guard !skipping else { continue }
            for image in found {
                // 그림 이름이 없으면 바로 위 줄(`수정 전(-30 입력)` 등)에서 찾는다
                guard let label = kind(of: image.alt) ?? kind(of: lastLine) else { continue }
                if label == .after, var last = screens.last, last.after == nil, last.before != nil, last.title == title {
                    last.after = image.path
                    screens[screens.count - 1] = last
                } else {
                    var screen = Screen(title: title, before: nil, after: nil)
                    assign(image.path, kind: label, to: &screen)
                    screens.append(screen)
                }
            }
        }
        return screens
    }

    private static func assign(_ path: String, kind: Kind?, to screen: inout Screen) {
        switch kind {
        case .before?: if screen.before == nil { screen.before = path }
        case .after?: if screen.after == nil { screen.after = path }
        case nil: break
        }
    }

    /// `**1. 폴더 이동 후 …** (…): 확인됨`, `### 제목` → 제목.
    static func heading(_ line: String) -> String? {
        if line.hasPrefix("#") {
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : String(title)
        }
        guard line.hasPrefix("**"), let close = line.range(of: "**", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex)
        else { return nil }
        let inner = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        // 번호가 붙은 항목만 화면 제목으로 본다 (`**[빌드/테스트]**` 같은 섹션 머리는 아니다)
        guard let first = inner.first, first.isNumber else { return nil }
        let title = inner.drop { $0.isNumber || $0 == "." || $0 == " " }
        return title.isEmpty ? nil : String(title)
    }

    static func kind(of text: String) -> Kind? {
        let compact = text.lowercased().replacingOccurrences(of: " ", with: "")
        if compact.contains("수정전") || compact.contains("before") || compact.contains("변경전") { return .before }
        if compact.contains("수정후") || compact.contains("after") || compact.contains("변경후") { return .after }
        return nil
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static let markdownImage = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\((/uploads/[^)\s]+)\)"#)
    private static let htmlImage = try! NSRegularExpression(pattern: #"<img[^>]*src="(/uploads/[^"]+)"[^>]*>"#, options: [.caseInsensitive])
    private static let altAttribute = try! NSRegularExpression(pattern: #"alt="([^"]*)""#, options: [.caseInsensitive])

    /// GitLab에 올린 그림만 (`/uploads/…`). 바깥 주소 그림은 받지 않는다.
    static func images(in text: String) -> [(alt: String, path: String)] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [(Int, String, String)] = []
        for match in markdownImage.matches(in: text, range: range) {
            guard let alt = Range(match.range(at: 1), in: text), let path = Range(match.range(at: 2), in: text) else { continue }
            found.append((match.range.location, String(text[alt]), String(text[path])))
        }
        for match in htmlImage.matches(in: text, range: range) {
            guard let tag = Range(match.range, in: text), let path = Range(match.range(at: 1), in: text) else { continue }
            let tagText = String(text[tag])
            let alt = altAttribute.firstMatch(in: tagText, range: NSRange(tagText.startIndex..., in: tagText))
                .flatMap { Range($0.range(at: 1), in: tagText) }.map { String(tagText[$0]) } ?? ""
            found.append((match.range.location, alt, String(text[path])))
        }
        return found.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    // MARK: - 레드마인 댓글

    /// 레드마인에 올릴 첨부 이름. 같은 일감에 여러 번 올려도 겹치지 않게 MR 번호와 순서를 넣는다.
    public static func filename(mr: Int, index: Int, kind: Kind, path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return "mr\(mr)-\(index + 1)-\(kind.rawValue).\(ext.isEmpty ? "png" : ext)"
    }

    /// 댓글 끝에 붙일 화면 부분. `files`는 (항목 순서, 종류) → 올린 첨부 이름.
    /// 화면이 넓어도 레드마인이 본문 폭에 맞춰 줄이므로 위아래로 쌓는다 (표로 나란히 두면 가로로 넘친다).
    public static func noteSection(_ screens: [Screen], files: [String: String], html: Bool) -> String {
        var blocks: [String] = []
        for (index, screen) in screens.enumerated() {
            let shots = screen.images.compactMap { kind, _ in files["\(index):\(kind.rawValue)"].map { (kind, $0) } }
            guard !shots.isEmpty else { continue }
            let title = "\(index + 1). " + (screen.title.map(clean) ?? "화면")
            if html {
                var parts = ["<p><strong>\(RedmineNote.escape(title))</strong></p>"]
                for (kind, file) in shots {
                    parts.append("<p>\(kind.label)<br />\n<img src=\"\(RedmineNote.escape(file))\" alt=\"\(kind.label)\" /></p>")
                }
                blocks.append(parts.joined(separator: "\n"))
            } else {
                blocks.append(([title] + shots.map { "\($0.0.label)\n!\($0.1)!" }).joined(separator: "\n"))
            }
        }
        guard !blocks.isEmpty else { return "" }
        let head = html ? "<p>[수정 전·후 화면]</p>" : "[수정 전·후 화면]"
        return ([head] + blocks).joined(separator: html ? "\n" : "\n\n")
    }

    /// 제목의 마크다운 꾸밈과 끝 괄호(경로) 떼기.
    static func clean(_ title: String) -> String {
        title.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
