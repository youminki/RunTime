import Foundation

/// 업데이트로 받은 커밋 제목을 패치노트로 묶는다. 커밋 머리말(feat·fix 등)로 나누고,
/// 문서·테스트·빌드 커밋은 쓰는 사람과 상관없어 뺀다. 한 제목에 쉼표로 이어 쓴 변경은 줄을 나눈다.
struct PatchNotes: Equatable {
    enum Kind: Int, CaseIterable {
        case added, fixed, polished

        var title: String {
            switch self {
            case .added: return "새 기능"
            case .fixed: return "고친 점"
            case .polished: return "다듬은 점"
            }
        }

        var icon: String {
            switch self {
            case .added: return "sparkles"
            case .fixed: return "wrench.adjustable"
            case .polished: return "wand.and.stars"
            }
        }
    }

    struct Section: Equatable {
        let kind: Kind
        var items: [String]
    }

    let sections: [Section]
    /// 말풍선에 다 싣지 못한 줄 수.
    let hiddenCount: Int

    /// 말풍선이 길어지지 않게 보이는 줄은 이만큼까지.
    static let visibleLimit = 5
    private static let skipped: Set<String> = ["docs", "test", "tests", "chore", "ci", "build"]
    private static let header = try! Regex(#"^([a-zA-Z]+)(\([^)]*\))?!?:\s*(.+)$"#)
    private static let aside = try! Regex(#"\s*\([^)]*\)"#)

    /// `lines`는 커밋 메시지 첫 줄, 오래된 것부터. 보일 줄이 없으면 nil.
    static func make(from lines: [String], limit: Int = visibleLimit) -> PatchNotes? {
        var grouped: [Kind: [String]] = [:]
        for line in lines.reversed() {
            guard let (kind, text) = classify(line) else { continue }
            for item in split(text) where !(grouped[kind]?.contains(item) ?? false) {
                grouped[kind, default: []].append(item)
            }
        }
        var left = limit
        var hidden = 0
        var sections: [Section] = []
        for kind in Kind.allCases {
            let items = grouped[kind] ?? []
            guard !items.isEmpty else { continue }
            let shown = Array(items.prefix(left))
            hidden += items.count - shown.count
            left -= shown.count
            if !shown.isEmpty { sections.append(Section(kind: kind, items: shown)) }
        }
        return sections.isEmpty ? nil : PatchNotes(sections: sections, hiddenCount: hidden)
    }

    private static func classify(_ line: String) -> (Kind, String)? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("Merge "), !line.hasPrefix("Revert ") else { return nil }
        guard let match = line.firstMatch(of: header),
              let type = match.output[1].substring?.lowercased(), let text = match.output[3].substring.map(String.init)
        else { return (.polished, line) }
        if skipped.contains(type) { return nil }
        switch type {
        case "feat": return (.added, text)
        case "fix": return (.fixed, text)
        default: return (.polished, text)
        }
    }

    /// 괄호 안 덧말을 빼고 쉼표로 이은 변경을 나눈다.
    private static func split(_ text: String) -> [String] {
        text.replacing(aside, with: "")
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
