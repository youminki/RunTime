import Foundation

/// 바뀐 것이 없어도 화면 하나를 마크업할 때 보는 내용. 상세 화면과 작업용 복사가 같은 순서로 읽는다.
public enum ScreenBrief {
    /// 목업 문구를 화면에서 읽는 순서(위→아래, 왼쪽→오른쪽)로, 같은 글은 한 번만.
    /// 표는 같은 칸 글이 줄마다 되풀이돼서 처음 나온 자리만 남긴다.
    public static func orderedTexts(_ screen: ScreenSnapshot) -> [String] {
        let places = screen.places ?? [:]
        // 줄 높이 안팎(화면 높이의 0.5%)으로 위치를 묶어야 같은 줄 글이 왼쪽부터 읽힌다
        let row = { (id: String) in places[id].map { ($0.y * 200).rounded() } ?? .infinity }
        let ids = screen.texts.keys.sorted { a, b in
            let ra = row(a), rb = row(b)
            if ra != rb { return ra < rb }
            let xa = places[a]?.x ?? .infinity, xb = places[b]?.x ?? .infinity
            return xa != xb ? xa < xb : a < b
        }
        var seen = Set<String>()
        return ids.compactMap { screen.texts[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 목업에 쓴 컴포넌트 이름과 개수. 많이 쓴 것부터.
    public static func components(_ screen: ScreenSnapshot) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for component in screen.components.values where !component.isImage { counts[component.name, default: 0] += 1 }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// 마크업을 맡기거나 MR에 붙일 글. 회사 양식대로 대괄호 머리와 줄 항목으로 쓴다.
    public static func text(_ screen: ScreenSnapshot, project: String, state: String, link: URL?,
                            recent: [DesignEvent] = [], textLimit: Int = 200) -> String {
        var lines = ["[화면] \(screen.screenID) \(screen.title)".trimmingCharacters(in: .whitespaces)]
        lines.append("- 프로젝트: \(project)")
        if !screen.menuPath.isEmpty { lines.append("- 화면 경로: \(screen.menuPath)") }
        if !screen.requirementID.isEmpty { lines.append("- 요구사항 ID: \(screen.requirementID)") }
        lines.append("- 시안 상태: \(state)")
        if let link { lines.append("- 피그마: \(link.absoluteString)") }
        if !screen.notes.isEmpty {
            lines += ["", "[참고]", screen.notes]
        }
        if !screen.items.isEmpty {
            lines += ["", "[기능 명세]"]
            for item in screen.items {
                let body = item.text.split(separator: "\n", omittingEmptySubsequences: false)
                lines.append("\(item.number). \(body.first.map(String.init) ?? "")")
                lines += body.dropFirst().map { "   " + $0 }
            }
        }
        let texts = orderedTexts(screen)
        if !texts.isEmpty {
            lines += ["", "[목업 문구]"]
            lines += texts.prefix(textLimit).map { "- " + $0.replacingOccurrences(of: "\n", with: " / ") }
            if texts.count > textLimit { lines.append("- 외 \(texts.count - textLimit)개") }
        }
        if !recent.isEmpty {
            lines += ["", "[최근 디자인 변경]"]
            let format = DateFormatter()
            format.locale = Locale(identifier: "ko_KR")
            format.dateFormat = "M/d"
            for event in recent.prefix(5) {
                lines.append("- \(format.string(from: event.detectedAt)) \(event.summary)")
                for change in event.changes where change.op != .renumbered { lines.append("  - " + DesignEvent.line(change)) }
            }
        }
        return lines.joined(separator: "\n")
    }
}
