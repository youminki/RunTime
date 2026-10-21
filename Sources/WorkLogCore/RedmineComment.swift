import Foundation

/// MR 설명을 레드마인 댓글 꼴로 다듬는다.
///
/// MR 설명은 리뷰어에게 쓰는 글이라 레드마인에 손으로 올리던 댓글과 다르다 (2026-10-20 #37828·#37856 대조).
/// - `[확인 방법]`은 리뷰어용이라 뺀다. 댓글에는 `[작업 내용]`·`[연동 API]`·`[마크업 작업]`·`[비고]`만 남는다.
/// - 줄 안의 `(#37828)`, `레드마인 #37856, #37857` 같은 일감 번호는 레드마인에서는 군더더기라 뗀다.
/// - MR 하나가 일감 여럿을 다루면 일감마다 따로 올렸다. 다른 일감 줄은 그 일감 댓글로 보낸다.
/// - `[비고]` 맨 앞에 `- MR !110`을 둔다.
/// - `[일감]`은 이 MR이 다룬 일감 목록(`- #37742 상품 신청 내역 > API 연동`)이라 댓글에 올리지 않는다.
/// - 일감별 묶음(`#37742 …` 줄 아래 [작업 내용]·[연동 API]·[비고])으로 쓴 MR은 그 묶음을 그 일감 댓글로 그대로 쓴다.
public enum RedmineComment {
    /// 리뷰어에게만 쓸모 있는 섹션.
    static let reviewerSections = ["확인 방법", "확인방법", "테스트", "검증", "리뷰", "스크린샷", "변경 파일"]

    /// MR이 다룬 일감을 적는 섹션 (2026-10-21부터 MR 맨 위에 둔다).
    static let issueSections = ["일감", "레드마인", "관련 일감"]

    /// - Parameters:
    ///   - mr: MR 번호 (`!110`). `[비고]`에 남긴다.
    ///   - issue: 이 댓글을 올릴 일감.
    ///   - subjects: 같은 MR이 다룬 일감들의 제목 (일감 번호 → 제목). 번호 없는 줄을 어느 일감 것인지 가르는 데 쓴다.
    ///   - siblings: 같은 MR에서 따로 댓글을 받는 다른 일감. 이 일감들의 줄만 뺀다 (따로 받지 않는 일감 줄은 남겨 잃지 않게).
    public static func fromMR(_ text: String, mr: Int?, issue: Int?, subjects: [Int: String] = [:], siblings: Set<Int> = []) -> String {
        // 일감별 묶음으로 쓴 MR은 짐작하지 않고 적힌 대로 나눈다: 묶음 앞 칸(모든 일감) + 이 일감 묶음
        let split = issueBlocks(text)
        var text = text
        var siblings = siblings
        if !split.blocks.isEmpty {
            text = ([split.shared] + split.blocks.filter { $0.id == issue }.map(\.body)).joined(separator: "\n")
            siblings = []
        }
        var sections: [(name: String, lines: [String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if RedmineNote.isHeading(line) {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                // 묶음 앞 칸과 일감 묶음에 같은 머리가 있으면 한 칸으로 모은다 (뒤로 옮겨 이어 쓴다)
                if let index = sections.firstIndex(where: { $0.name == name }) {
                    sections.append(sections.remove(at: index))
                } else {
                    sections.append((name, []))
                }
                continue
            }
            // 머리 없이 쓴 설명(커밋 목록, 문장)은 [작업 내용] 항목으로 본다
            if sections.isEmpty { sections.append(("작업 내용", [])) }
            sections[sections.count - 1].lines.append(line)
        }
        let others = siblings.subtracting(issue.map { [$0] } ?? [])
        var result: [(name: String, lines: [String])] = []
        for section in sections where !reviewerSections.contains(where: section.name.contains)
            && !issueSections.contains(section.name) {
            var lines: [String] = []
            // 어느 일감 줄인지 모르는 줄은 바로 위 줄의 일감을 잇는다 (`… 제거(#37828)` 아래 이어지는 설명)
            var carried: [Int] = []
            for line in section.lines {
                let refs = issueRefs(line)
                let bare = stripRefs(line)
                // `레드마인 #37856, #37857`처럼 번호만 늘어놓은 줄
                if !refs.isEmpty && isRefList(bare) { continue }
                // [비고]의 코드 이름(AppForm, useQuery, *.vue)이 든 줄은 개발자에게 쓴 메모라 레드마인에 올리지 않았다
                if section.name == "비고" && mentionsCode(bare) { continue }
                let owners = refs.isEmpty ? (owner(bare, candidates: [issue].compactMap { $0 } + others, subjects: subjects).map { [$0] } ?? carried) : refs
                carried = owners
                if let issue, !owners.isEmpty, !owners.contains(issue), !others.isDisjoint(with: owners) { continue }
                lines.append(bullet(bare))
            }
            if !lines.isEmpty || section.name == "비고" { result.append((section.name, lines)) }
        }
        if let mr {
            let tag = "- MR !\(mr)"
            if let index = result.firstIndex(where: { $0.name == "비고" }) {
                if !result[index].lines.contains(where: { $0.contains("MR !") }) { result[index].lines.insert(tag, at: 0) }
            } else {
                result.append(("비고", [tag]))
            }
        }
        return result.filter { !$0.lines.isEmpty }
            .map { (["[\($0.name)]"] + $0.lines).joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    /// `[일감]` 섹션의 일감과 그 이름. `- #37742 상품 신청 내역 > API 연동` → `[37742: "상품 신청 내역 > API 연동"]`.
    /// 이름을 비워 적은 줄은 번호만 남는다 (빈 이름은 넣지 않는다).
    public static func listedIssues(_ text: String) -> [(id: Int, title: String)] {
        var inSection = false
        var result: [(id: Int, title: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if RedmineNote.isHeading(line) {
                inSection = issueSections.contains(String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let header = blockHeader(line) {
                inSection = false
                if !result.contains(where: { $0.id == header.id }) { result.append((header.id, header.title)) }
                continue
            }
            guard inSection else { continue }
            for id in issueRefs(line) where !result.contains(where: { $0.id == id }) {
                let title = stripRefs(line.hasPrefix("-") ? String(line.dropFirst()) : line)
                result.append((id, title))
            }
        }
        return result
    }

    /// 일감별 묶음. `#37742 상품 신청 내역 > API 연동`처럼 번호로 시작하는 줄(목록 기호 없이)이 묶음 머리다.
    /// 첫 묶음 앞의 글은 모든 일감에 함께 들어간다.
    public static func issueBlocks(_ text: String) -> (shared: String, blocks: [(id: Int, title: String, body: String)]) {
        var shared: [String] = []
        var blocks: [(id: Int, title: String, body: [String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let header = blockHeader(line) {
                blocks.append((header.id, header.title, []))
            } else if blocks.isEmpty {
                shared.append(raw)
            } else {
                blocks[blocks.count - 1].body.append(raw)
            }
        }
        return (shared.joined(separator: "\n"), blocks.map { ($0.id, $0.title, $0.body.joined(separator: "\n")) })
    }

    static func blockHeader(_ line: String) -> (id: Int, title: String)? {
        guard let range = line.range(of: #"^#\d{4,7}\b"#, options: .regularExpression),
              let id = Int(line[range].dropFirst()) else { return nil }
        return (id, String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// 줄에 적힌 일감 번호들.
    public static func issueRefs(_ text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"#(\d{4,7})\b"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    /// MR 글 전체에 나온 일감 번호 (나온 순서, 겹침 없이).
    public static func allIssueRefs(_ texts: [String]) -> [Int] {
        var seen = Set<Int>()
        return texts.flatMap(issueRefs).filter { seen.insert($0).inserted }
    }

    /// 제목 낱말이 가장 많이 겹치는 일감. 겹치는 게 없거나 비기면 nil.
    /// 제목을 모르는 일감이 하나라도 있으면 가르지 않는다 (모르는 일감 줄을 엉뚱한 일감에 붙이지 않게).
    static func owner(_ line: String, candidates: [Int], subjects: [Int: String]) -> Int? {
        guard candidates.count > 1, candidates.allSatisfy({ subjects[$0] != nil }) else { return nil }
        let words = IssueMatch.tokens(line)
        let scores = candidates.map { id in (id, subjects[id].map { IssueMatch.tokens($0).intersection(words).count } ?? 0) }
        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0, scores.filter({ $0.1 == best.1 }).count == 1 else { return nil }
        return best.0
    }

    /// `AppForm`, `useQuery`, `widget_count`, `src/a.vue`, `` `x` `` 같은 코드 이름.
    static func mentionsCode(_ line: String) -> Bool {
        let patterns = [#"\b[A-Z][a-z]+[A-Z][a-z]+"#, #"\b[a-z]+[A-Z][A-Za-z]*\b"#, #"\b[a-z]+_[a-z_]+\b"#,
                        #"\.(ts|tsx|js|vue|swift|json|css|scss)\b"#, "`"]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    static func stripRefs(_ line: String) -> String {
        var text = line
        let patterns = [#"\s*\(\s*#\d{4,7}(\s*,\s*#\d{4,7})*\s*\)"#,   // (#37828), (#1, #2)
                        #"\s*,\s*#\d{4,7}\b"#,                            // (18.9, #37828) → (18.9)
                        #"#\d{4,7}\b\s*,?\s*"#]                           // 남은 #37828
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "()", with: "")
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
    }

    /// 번호를 떼고 나면 `레드마인`, `일감` 같은 말만 남는 줄.
    static func isRefList(_ bare: String) -> Bool {
        var rest = bare.hasPrefix("-") ? String(bare.dropFirst()) : bare
        for word in ["레드마인", "일감", "이슈", "관련", "redmine", "Redmine", ":", ","] {
            rest = rest.replacingOccurrences(of: word, with: "")
        }
        return rest.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `fix: 포트 중복…` 같은 커밋 줄도 `- 포트 중복…` 항목으로.
    static func bullet(_ line: String) -> String {
        if line.hasPrefix("- ") { return line }
        let body = line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") ? String(line.dropFirst()) : line
        return "- " + WorkCapture.cleanTitle(body.trimmingCharacters(in: .whitespaces))
    }

    /// 레드마인에 이미 비슷한 댓글이 있는지 (Claude로 따로 올린 것). 내 댓글 낱말의 절반 넘게가 겹치면 같은 내용으로 본다.
    public static func alreadyPosted(_ note: String, journals: [RedmineAPI.Journal], since: Date) -> RedmineAPI.Journal? {
        // [작업 내용]만 견준다. [비고]는 손으로 올릴 때 많이 달라진다
        let work = note.components(separatedBy: "\n\n").first { $0.hasPrefix("[작업 내용]") } ?? note
        let mine = IssueMatch.tokens(RedmineNote.plain(work).replacingOccurrences(of: "\n", with: " "))
            .subtracting(["작업", "내용", "비고", "연동"])
        guard mine.count >= 3 else { return nil }
        return journals.filter { $0.createdOn >= since && !$0.notes.isEmpty }.first { journal in
            let theirs = IssueMatch.tokens(RedmineNote.plain(journal.notes).replacingOccurrences(of: "\n", with: " "))
            return Double(mine.intersection(theirs).count) / Double(mine.count) >= 0.5
        }
    }
}
