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
        /// 제목·일감 묶음 머리·그림 바로 위 줄에 적힌 일감 번호. 이 화면이 어느 일감 것인지 가장 확실한 단서다.
        public var issues: [Int]
        /// 검증에서 `판단 어려움`이 나온 항목. 받아는 두되 사용자가 고를 때만 붙인다.
        public var unsure: Bool

        public init(title: String?, before: String?, after: String?, issues: [Int] = [], unsure: Bool = false) {
            self.title = title
            self.before = before
            self.after = after
            self.issues = issues
            self.unsure = unsure
        }

        /// 화면을 가리키는 키. 업로드 경로는 MR마다 달라 고른 것·옮긴 것을 기억하는 데 쓴다.
        public var key: String { before ?? after ?? "" }

        public var images: [(kind: Kind, path: String)] {
            [(Kind.before, before), (.after, after)].compactMap { kind, path in path.map { (kind, $0) } }
        }
    }

    public enum Kind: String, Codable {
        case before, after
        public var label: String { self == .before ? "수정 전" : "수정 후" }
    }

    /// 레드마인 댓글 하나에 붙일 그림 수 한도. 넘치면 앞 항목부터 쓴다.
    public static let maxImages = 8

    /// 본문의 화면과 댓글의 화면. 처음부터 다시 검증한 댓글은 앞 댓글 화면을 갈아 치우고,
    /// 지난 검증 뒤 커밋만 본 댓글(`… 이후 추가된 커밋의 변경만 리뷰했습니다`)은 앞 화면에 더한다 (같은 제목이면 새 것으로).
    /// 한도는 일감마다 나눈 뒤에 `limited`로 건다 (MR 전체에 걸면 뒤 일감 몫이 잘린다).
    public static func screens(description: String, notes: [String]) -> [Screen] {
        var fromNotes: [Screen] = []
        for note in notes {
            let found = parse(note)
            guard !found.isEmpty else { continue }
            guard note.contains("이후 추가된 커밋") else { fromNotes = found; continue }
            // 같은 제목 아래 화면이 여럿일 수 있어 제목마다 통째로 바꾼다 (첫 자리에 새 묶음)
            var order: [String?] = []
            for screen in fromNotes + found where !order.contains(screen.title) { order.append(screen.title) }
            let replaced = Set(found.compactMap(\.title))
            var groups: [String?: [Screen]] = [:]
            for screen in fromNotes where screen.title.map(replaced.contains) != true { groups[screen.title, default: []].append(screen) }
            for screen in found { groups[screen.title, default: []].append(screen) }
            fromNotes = order.flatMap { groups[$0] ?? [] }
        }
        var result = parse(description) + fromNotes
        // 같은 그림이 본문과 댓글에 함께 있으면 한 번만
        var seen = Set<String>()
        return result.compactMap { screen in
            var copy = screen
            if let before = copy.before, !seen.insert(before).inserted { copy.before = nil }
            if let after = copy.after, !seen.insert(after).inserted { copy.after = nil }
            return copy.before == nil && copy.after == nil ? nil : copy
        }
    }

    public static func limited(_ screens: [Screen]) -> [Screen] {
        var budget = maxImages
        return screens.compactMap { screen in
            guard budget > 0 else { return nil }
            var copy = screen
            if copy.before != nil { if budget > 0 { budget -= 1 } else { copy.before = nil } }
            if copy.after != nil { if budget > 0 { budget -= 1 } else { copy.after = nil } }
            return copy.before == nil && copy.after == nil ? nil : copy
        }
    }

    // MARK: - 일감마다 나누기

    /// MR 하나를 나눠 받는 일감들. 일지에 그 MR 줄이 있는 일감만 받는다.
    public struct Split: Equatable, Sendable {
        /// 어느 일감 것인지 모르는 화면을 받는 일감 (MR 대표 줄의 일감). 한 화면을 두 번 올리지 않게 한 곳에만 둔다.
        public var primary: Int?
        public var issues: [Int]
        /// 일감 이름의 낱말 (레드마인 제목, `[일감]`에 적은 이름, 일감별 묶음 머리).
        public var names: [Int: Set<String>]
        /// MR 설명에서 그 일감 몫인 줄의 낱말 (번호가 붙은 줄, 일감별 묶음 본문).
        public var words: [Int: Set<String>]

        public init(primary: Int?, issues: [Int], names: [Int: Set<String>] = [:], words: [Int: Set<String>] = [:]) {
            self.primary = primary
            self.issues = issues
            self.names = names
            self.words = words
        }

        /// MR 줄이 하나뿐인 일감 (머지 전 브랜치 줄 등).
        public static func single(_ issue: Int) -> Split { Split(primary: issue, issues: [issue]) }
    }

    /// 일지의 MR 줄(`mr:경로!번호`, 다른 일감 몫 `…#일감`)을 MR마다 모은다. 키는 `경로!번호`.
    public static func splits(_ log: WorkLog) -> [String: Split] {
        var groups: [String: [WorkEntry]] = [:]
        for entry in log.entries {
            guard let source = entry.source, source.hasPrefix("mr:"), entry.issue != nil else { continue }
            let base = String(source.split(separator: "#").first ?? Substring(source))
            groups[String(base.dropFirst(3)), default: []].append(entry)
        }
        return groups.mapValues { entries in
            var issues: [Int] = []
            for issue in entries.compactMap(\.issue) where !issues.contains(issue) { issues.append(issue) }
            let primary = entries.first { !($0.source ?? "").contains("#") }?.issue ?? issues.first
            let body = entries.lazy.compactMap(\.mrBody).first { !$0.isEmpty } ?? ""
            var names: [Int: Set<String>] = [:], words: [Int: Set<String>] = [:]
            for issue in issues {
                if let info = log.issue(issue) { names[issue, default: []].formUnion(IssueMatch.tokens(info.reportTitle)) }
            }
            for (id, title) in RedmineComment.listedIssues(body) where issues.contains(id) {
                names[id, default: []].formUnion(IssueMatch.tokens(title))
            }
            for (id, _, text) in RedmineComment.issueBlocks(body).blocks where issues.contains(id) {
                words[id, default: []].formUnion(IssueMatch.tokens(text))
            }
            for line in body.components(separatedBy: .newlines) where RedmineComment.blockHeader(line.trimmingCharacters(in: .whitespaces)) == nil {
                let refs = RedmineComment.issueRefs(line).filter(issues.contains)
                let tokens = IssueMatch.tokens(RedmineComment.stripRefs(line))
                for id in refs { words[id, default: []].formUnion(tokens) }
            }
            return Split(primary: primary, issues: issues, names: names, words: words)
        }
    }

    /// 미리보기에서 사용자가 고친 것. 화면 키(`Screen.key`)로 기억한다.
    public struct Picks: Equatable, Sendable {
        /// 붙일지 직접 고른 화면. 없으면 판단 어려움이 아닌 화면만 붙인다.
        public var chosen: [String: Bool]
        /// 다른 일감으로 옮긴 화면 → 받을 일감.
        public var moves: [String: Int]

        public init(chosen: [String: Bool] = [:], moves: [String: Int] = [:]) {
            self.chosen = chosen
            self.moves = moves
        }

        public func includes(_ screen: Screen) -> Bool { chosen[screen.key] ?? !screen.unsure }
    }

    /// 화면 주인을 무엇으로 정했는지. 미리보기에서 왜 이 일감에 붙는지 보인다.
    public enum Match: Equatable, Sendable {
        /// 사용자가 이 일감으로 옮겼다.
        case moved
        /// 제목·묶음 머리·바로 위 줄에 일감 번호가 적혀 있다.
        case number
        /// 제목 낱말이 이 일감 이름·작업 줄과 더 겹친다.
        case title
        /// 단서가 없어 MR 대표 일감이 받는다.
        case primary
    }

    /// 화면을 받을 일감. 적힌 번호가 먼저고, 없으면 제목 낱말이 한 일감에만 더 겹칠 때 그 일감, 그래도 모르면 대표 일감.
    /// 일지에 줄이 없는 다른 일감 번호가 적힌 화면은 어디에도 붙이지 않는다 (엉뚱한 일감에 올리지 않게).
    public static func owners(_ screen: Screen, split: Split, picks: Picks = Picks()) -> (issues: [Int], match: Match) {
        if let moved = picks.moves[screen.key], split.issues.contains(moved) { return ([moved], .moved) }
        if !screen.issues.isEmpty { return (screen.issues.filter(split.issues.contains), .number) }
        if split.issues.count > 1, let title = screen.title, let best = closest(title, split: split) { return ([best], .title) }
        return ([split.primary ?? split.issues.first].compactMap { $0 }, .primary)
    }

    /// 한 MR의 화면 가운데 `issue` 일감 몫. 순서는 MR에 적힌 대로다. 붙이지 않기로 한 화면은 뺀다.
    public static func share(_ screens: [Screen], issue: Int, split: Split, picks: Picks = Picks()) -> [Screen] {
        owned(screens, issue: issue, split: split, picks: picks).filter(picks.includes)
    }

    /// 붙일지와 상관없이 `issue` 일감이 받는 화면 (미리보기에서 고르게 다 보인다).
    public static func owned(_ screens: [Screen], issue: Int, split: Split, picks: Picks = Picks()) -> [Screen] {
        screens.filter { owners($0, split: split, picks: picks).issues.contains(issue) }
    }

    /// 모든 일감에 다 있는 낱말(`화면`, `마크업` 등)은 가르는 데 쓸모가 없어 빼고 센다.
    /// 일감 이름과 겹친 낱말은 두 배로 친다 (본문 줄에는 다른 일감 이야기도 섞인다).
    /// 낱말 한두 개만 우연히 겹치면(`생성`, `선택`) 엉뚱한 일감에 붙기 쉬워, 이름 낱말이 둘 이상 겹치거나
    /// 본문 낱말이 둘 이상이면서 제목 낱말의 40% 넘게 겹쳐야 한다.
    static func closest(_ title: String, split: Split) -> Int? {
        let words = stems(IssueMatch.tokens(title))
        func distinct(_ table: [Int: Set<String>]) -> [Set<String>] {
            let sets = split.issues.map { stems(table[$0] ?? []) }
            let common = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
            return sets.map { $0.subtracting(common).intersection(words) }
        }
        let names = distinct(split.names), bodies = distinct(split.words)
        let total = Double(words.count)
        let scores = split.issues.indices.map { index -> (id: Int, score: Int, sure: Bool) in
            let name = names[index].count, body = bodies[index].count
            return (split.issues[index], name * 2 + body, name >= 2 || (body >= 2 && Double(body) >= total * 0.4))
        }
        guard let best = scores.max(by: { $0.score < $1.score }), best.sure,
              scores.filter({ $0.score == best.score }).count == 1 else { return nil }
        return best.id
    }

    private static let particles = ["에서", "으로", "까지", "부터", "와", "과", "의", "에", "를", "을", "은", "는", "이", "가", "로", "도"]

    /// 끝 조사를 뗀 낱말 (`대화상자와` → `대화상자`). 남는 말이 한 글자면 그대로 둔다 (`추가`, `결과`).
    static func stems(_ words: Set<String>) -> Set<String> {
        Set(words.map { word in
            guard let particle = particles.first(where: { word.hasSuffix($0) }), word.count - particle.count >= 2 else { return word }
            return String(word.dropLast(particle.count))
        })
    }

    // MARK: - 글 하나 읽기

    static func parse(_ text: String) -> [Screen] {
        var screens: [Screen] = []
        var title: String?
        var skipping = false
        var unsure = false
        var columns: [Kind?] = []
        var lastLine = ""
        // 일감 단서: 일감별 묶음 머리(`#37742 …`), 항목 제목의 번호. 그림 줄·바로 위 줄의 번호가 더 앞선다
        var blockIssues: [Int] = []
        var headingIssues: [Int] = []
        var lineIssues: [Int] = []
        func context(_ near: String) -> [Int] {
            let refs = RedmineComment.issueRefs(near)
            return [refs, lineIssues, headingIssues, blockIssues].first { !$0.isEmpty } ?? []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let block = RedmineComment.blockHeader(line) {
                blockIssues = [block.id]
                headingIssues = []
                title = block.title.isEmpty ? nil : block.title
                skipping = false
                unsure = false
                columns = []
                lineIssues = []
                continue
            }
            if let heading = heading(line) {
                let refs = RedmineComment.issueRefs(line)
                headingIssues = refs
                title = refs.isEmpty ? heading : RedmineComment.stripRefs(heading)
                // 검증에서 문제가 나온 항목의 화면은 완료 댓글에 붙이지 않는다. 판단하지 못한 항목은 골라야 붙는다
                skipping = line.contains("문제 있음")
                unsure = line.contains("판단 어려움")
                columns = []
                lineIssues = []
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
                var screen = Screen(title: title, before: nil, after: nil, issues: context(line), unsure: unsure)
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
                if !line.isEmpty {
                    lastLine = line
                    // 이름표처럼 짧은 줄의 번호만 단서로 본다. 검증 글의 문장(`… 중단 태그(#38059)는 확인되지 않았습니다`)은 다른 일감을 말하기도 한다
                    lineIssues = RedmineComment.stripRefs(line).count <= 40 ? RedmineComment.issueRefs(line) : []
                }
                continue
            }
            guard !skipping else { continue }
            for image in found {
                // 그림 이름이 없으면 바로 위 줄(`수정 전(-30 입력)` 등)에서 찾는다
                guard let label = kind(of: image.alt) ?? kind(of: lastLine) else { continue }
                let issues = context(image.alt)
                if label == .after, var last = screens.last, last.after == nil, last.before != nil, last.title == title,
                   issues.isEmpty || last.issues.isEmpty || issues == last.issues {
                    last.after = image.path
                    if last.issues.isEmpty { last.issues = issues }
                    screens[screens.count - 1] = last
                } else {
                    var screen = Screen(title: title, before: nil, after: nil, issues: issues, unsure: unsure)
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
