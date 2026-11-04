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

    /// 마크업할 때 보는 목업 글 한 줄. `before`가 있으면 반영하지 않은 변경으로 바뀐 글이다.
    public struct MockupText: Equatable, Sendable, Identifiable {
        public enum Kind: Sendable { case same, changed, added, removed }
        public let id: String
        public let text: String
        public let before: String?
        public let kind: Kind
    }

    /// 목업 글을 마크업하기 좋게 나눈다. 바뀐 글은 맨 위, 나머지는 화면 위쪽·가운데·아래쪽 순서로 두고,
    /// 별표 같은 표시는 빼고 표 칸의 예시 데이터는 따로 센다. `changes`는 반영하지 않은 목업 문구 변경이다.
    public static func mockup(_ screen: ScreenSnapshot, changes: [SpecChange]) -> (changed: [MockupText], areas: [(name: String, texts: [MockupText])], samples: Int) {
        let places = screen.places ?? [:]
        // 같은 글을 여러 번 고쳤으면 Claude 문구처럼 처음 → 마지막 하나로 합친다 (`changes`는 오래된 것부터)
        let merged = ClaudePrompt.merged(changes.filter { $0.layer == .text && !ClaudePrompt.isSampleData($0) })
        var touched: [String: SpecChange] = [:]
        for change in merged { if let id = change.nodeID { touched[id] = change } }
        let row = { (id: String) in places[id].map { ($0.y * 200).rounded() } ?? .infinity }
        let ids = screen.texts.keys.sorted { a, b in
            let ra = row(a), rb = row(b)
            if ra != rb { return ra < rb }
            let xa = places[a]?.x ?? .infinity, xb = places[b]?.x ?? .infinity
            return xa != xb ? xa < xb : a < b
        }
        var changed: [MockupText] = []
        var buckets: [String: [MockupText]] = [:]
        var samples = 0
        var seen = Set<String>()
        for id in ids {
            guard let text = ClaudePrompt.meaningful(screen.texts[id]) else { continue }
            if let change = touched[id] {
                changed.append(MockupText(id: id, text: text, before: change.op == .added ? nil : change.before?.trimmingCharacters(in: .whitespacesAndNewlines),
                                          kind: change.op == .added ? .added : .changed))
                continue
            }
            if ClaudePrompt.isSampleData(place: places[id]) { samples += 1; continue }
            guard seen.insert(text).inserted else { continue }
            let area = places[id].map { $0.y + $0.height / 2 < 0.33 ? "화면 위쪽" : $0.y + $0.height / 2 < 0.66 ? "화면 가운데" : "화면 아래쪽" } ?? "자리 모름"
            buckets[area, default: []].append(MockupText(id: id, text: text, before: nil, kind: .same))
        }
        // 지운 글은 지금 시안에 없어 변경에서 가져온다
        for (index, change) in merged.enumerated() where change.op == .removed {
            if let text = ClaudePrompt.meaningful(change.before) {
                changed.append(MockupText(id: "removed:\(index):" + (change.nodeID ?? text), text: text, before: text, kind: .removed))
            }
        }
        let areas = ["화면 위쪽", "화면 가운데", "화면 아래쪽", "자리 모름"].compactMap { name in buckets[name].map { (name: name, texts: $0) } }
        return (changed, areas, samples)
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
                            recent: [DesignEvent] = [], built: Set<String> = [], textLimit: Int = 200) -> String {
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
            let done = screen.items.filter { built.contains($0.text) }.count
            lines += ["", done == 0 ? "[기능 명세]" : "[기능 명세] 구현 \(done)/\(screen.items.count)"]
            for item in screen.items {
                let body = item.text.split(separator: "\n", omittingEmptySubsequences: false)
                // 구현을 마친 항목에 표시해 남은 일만 맡길 수 있게 한다
                let mark = built.contains(item.text) ? " (구현함)" : ""
                lines.append("\(item.number). \(body.first.map(String.init) ?? "")\(mark)")
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
