import Foundation

/// Claude Code에 그대로 붙여 마크업을 맡기는 글. 바뀐 것을 전·후 원문으로 적고 무엇을 할지 분명히 한다.
/// 피그마 링크가 있으면 Claude가 피그마 MCP로 화면을 읽으니, 링크로 알 수 있는 것(목업 문구 전부, 전체 명세)은 넣지 않아 글을 줄인다.
public enum ClaudePrompt {
    /// 마크업과 상관없는 화면 정보. 문구에 넣지 않는다.
    public static let skippedHeaders: Set<String> = ["작성자", "섹션"]

    /// 바뀐 화면을 반영해 달라는 글. `events`는 이 화면의 아직 반영하지 않은 변경, `done`은 이미 반영한 항목(`SpecChange.key`)이다.
    public static func changes(_ events: [DesignEvent], screen: ScreenSnapshot?, link: URL?, done: [UUID: Set<String>] = [:]) -> String {
        guard let latest = events.max(by: { $0.detectedAt < $1.detectedAt }) else { return "" }
        var lines = ["아래 피그마 화면설계서 변경을 마크업에 반영해 주세요.", ""]
        lines += header(screenID: screen?.screenID ?? latest.screenID, title: screen?.title ?? latest.title,
                        path: screen?.menuPath ?? latest.menuPath, link: link)
        let body = changeLines(events, done: done)
        lines += body.isEmpty ? ["- 남은 변경이 없습니다 (모두 반영함)"] : body
        lines += ["", request(several: false, link: link != nil)]
        return lines.joined(separator: "\n")
    }

    /// 메뉴 하나의 반영할 변경을 화면별로 묶은 글.
    public static func menu(_ screens: [(screen: ScreenSnapshot, events: [DesignEvent], link: URL?)], path: String,
                            done: [UUID: Set<String>] = [:]) -> String {
        var lines = ["아래 피그마 화면설계서 ‘\(path)’ 메뉴의 변경을 마크업에 반영해 주세요."]
        var listed = 0
        for item in screens {
            let body = changeLines(item.events, done: done)
            guard !body.isEmpty else { continue }
            listed += 1
            lines += [""] + header(screenID: item.screen.screenID, title: item.screen.title, path: item.screen.menuPath, link: item.link) + body
        }
        if listed == 0 { lines += ["", "- 남은 변경이 없습니다 (모두 반영함)"] }
        lines += ["", request(several: listed > 1, link: screens.contains { $0.link != nil })]
        return lines.joined(separator: "\n")
    }

    /// 메뉴 화면들을 처음 마크업해 달라는 글. 화면마다 참고와 남은 기능 명세만 넣고, 목업 문구·배치는 피그마 링크로 읽게 한다.
    /// 구현을 마친 화면(남은 명세가 없는 화면)은 뺀다.
    public static func menuBuild(_ screens: [(screen: ScreenSnapshot, link: URL?, built: Set<String>)], path: String) -> String {
        var lines = ["아래 피그마 화면설계서 ‘\(path)’ 메뉴의 화면들을 마크업해 주세요."]
        var listed = 0
        for item in screens {
            let left = item.screen.items.filter { !item.built.contains($0.text) }
            guard !left.isEmpty || item.screen.items.isEmpty else { continue }
            listed += 1
            lines += [""] + header(screenID: item.screen.screenID, title: item.screen.title, path: item.screen.menuPath, link: item.link)
            lines += spec(item.screen, left: left)
        }
        if listed == 0 { lines += ["", "- 남은 화면이 없습니다 (모든 기능 명세를 구현함)"] }
        lines += ["", buildRequest(link: screens.contains { $0.link != nil })]
        return lines.joined(separator: "\n")
    }

    /// 아직 바뀐 것이 없는 화면을 처음 마크업해 달라는 글. 구현을 마친 명세(`built`)는 빼고 남은 것만 맡긴다.
    /// 피그마 링크가 없을 때만 목업 문구와 컴포넌트를 적는다 (링크가 있으면 Claude가 피그마에서 읽는다).
    public static func build(_ screen: ScreenSnapshot, link: URL?, built: Set<String> = []) -> String {
        var lines = ["아래 피그마 화면설계서 화면을 마크업해 주세요.", ""]
        lines += header(screenID: screen.screenID, title: screen.title, path: screen.menuPath, link: link)
        lines += spec(screen, left: screen.items.filter { !built.contains($0.text) })
        if link == nil {
            let texts = ScreenBrief.orderedTexts(screen)
            if !texts.isEmpty {
                lines += ["[목업 문구] 화면 위에서 아래 순서"] + texts.prefix(150).map { "- " + $0.replacingOccurrences(of: "\n", with: " / ") }
            }
            let components = ScreenBrief.components(screen)
            if !components.isEmpty {
                lines += ["[쓰인 컴포넌트] " + components.prefix(30).map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }.joined(separator: ", ")]
            }
        }
        lines += ["", buildRequest(link: link != nil)]
        return lines.joined(separator: "\n")
    }

    /// 변경들을 화면 하나의 `[바뀐 것]`으로. 같은 항목을 여러 번 고쳤으면 처음→마지막 한 줄로 합치고,
    /// 되돌려 같아졌거나 더했다 지운 항목, 이미 반영한 항목, 번호만 밀린 명세, 마크업과 상관없는 화면 정보는 뺀다.
    static func changeLines(_ events: [DesignEvent], done: [UUID: Set<String>]) -> [String] {
        let ordered = events.sorted { $0.detectedAt < $1.detectedAt }
        let kinds = ordered.compactMap { event -> String? in
            switch event.kind {
            case .added: return "새 화면"
            case .removed: return "화면 삭제"
            case .replaced: return "새 프레임으로 교체"
            case .changed, .changelog: return nil
            }
        }
        let pending = ordered.flatMap { event in
            event.changes.filter { $0.op != .renumbered && !(done[event.id] ?? []).contains($0.key)
                && !($0.layer == .header && skippedHeaders.contains($0.label)) }
        }
        let changes = merged(pending)
        guard !changes.isEmpty || !kinds.isEmpty else { return [] }
        var lines = ["[바뀐 것]" + (kinds.isEmpty ? "" : " " + Array(Set(kinds)).sorted().joined(separator: " · "))]
        for layer in [SpecChange.Layer.spec, .text, .header, .component] {
            for change in changes where change.layer == layer { lines += describe(change) }
        }
        return lines
    }

    /// 같은 항목의 연이은 변경을 하나로 합친다. 항목은 층과 레이어 ID(없으면 이름)로 가린다.
    public static func merged(_ changes: [SpecChange]) -> [SpecChange] {
        var order: [String] = []
        var groups: [String: [SpecChange]] = [:]
        for change in changes {
            let id = change.layer.rawValue + "|" + (change.nodeID ?? change.label)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(change)
        }
        return order.compactMap { id -> SpecChange? in
            guard let group = groups[id], let first = group.first, let last = group.last else { return nil }
            guard group.count > 1 else { return first }
            let existed = first.op != .added
            let exists = last.op != .removed
            var change = last
            switch (existed, exists) {
            case (false, false): return nil
            case (false, true): change.op = .added; change.before = nil
            case (true, false): change.op = .removed; change.before = first.before; change.after = nil
            case (true, true):
                guard first.before != last.after else { return nil }
                change.op = .modified; change.before = first.before
            }
            return change
        }
    }

    private static func spec(_ screen: ScreenSnapshot, left: [SpecItem]) -> [String] {
        var lines: [String] = []
        if !screen.notes.isEmpty { lines += ["[참고]", screen.notes] }
        if !left.isEmpty {
            lines.append(left.count == screen.items.count ? "[기능 명세]" : "[남은 기능 명세] \(left.count)/\(screen.items.count) (나머지는 구현함)")
            lines += items(ScreenSnapshot(frameID: screen.frameID, screenID: screen.screenID, items: left))
        }
        return lines
    }

    private static func request(several: Bool, link: Bool) -> String {
        "[요청] " + (several ? "화면마다 " : "") + "[바뀐 것]만 반영하고 나머지는 그대로 두세요. 고칠 파일을 먼저 찾아 알려 주고"
            + (link ? ", 배치·간격은 피그마 MCP로 링크 노드를 열어 확인하세요." : ".")
            + " 끝나면 반영한 것과 확인이 필요한 것을 나눠 알려 주세요."
    }

    private static func buildRequest(link: Bool) -> String {
        "[요청] " + (link ? "피그마 MCP로 링크 노드를 열어 목업 문구·배치·간격을 확인하고, " : "")
            + "저장소의 비슷한 화면과 공통 컴포넌트 방식으로 만들어 주세요. 정해지지 않은 API·동작은 자리만 만들고 알려 주세요."
    }

    private static func header(screenID: String, title: String, path: String, link: URL?) -> [String] {
        var lines = ["[화면] \(screenID) \(title)".trimmingCharacters(in: .whitespaces) + (path.isEmpty ? "" : " (\(path))")]
        if let link { lines.append("피그마: \(link.absoluteString)") }
        return lines
    }

    private static func items(_ screen: ScreenSnapshot) -> [String] {
        screen.items.flatMap { item -> [String] in
            let body = item.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return ["\(item.number). \(body.first ?? "")"] + body.dropFirst().map { "   " + $0 }
        }
    }

    /// 변경 하나. 명세는 전·후 원문을 줄째로, 목업 요소는 화면 어디쯤인지 붙인다.
    static func describe(_ change: SpecChange) -> [String] {
        let layer = ["header": "화면 정보", "spec": "기능 명세", "text": "목업 문구", "component": "컴포넌트"][change.layer.rawValue] ?? ""
        let quote = { (text: String?) in (text ?? "").replacingOccurrences(of: "\n", with: " / ") }
        let indent = { (text: String?) in (text ?? "").split(separator: "\n").map { "    " + $0 } }
        var lines: [String]
        switch (change.layer, change.op) {
        case (.spec, .added): lines = ["- \(layer) 추가: \(change.label)"] + indent(change.after)
        case (.spec, .removed): lines = ["- \(layer) 삭제: \(change.label)"] + indent(change.before)
        case (.spec, _):
            // 긴 항목에서 몇 줄만 바뀌므로 바뀐 줄만 -/+로 적는다. 항목 전체는 [지금 기능 명세]에 있다
            lines = ["- \(layer) 수정: \(change.label) (바뀐 줄만, - 전 / + 후)"] + lineDiff(change.before, change.after).map { "    " + $0 }
        case (_, .added): lines = ["- \(layer) 추가: \"\(quote(change.after))\""]
        case (_, .removed): lines = ["- \(layer) 삭제: \"\(quote(change.before))\""]
        default:
            let name = change.layer == .header ? change.label : layer
            lines = ["- \(name) 수정: \"\(quote(change.before))\" → \"\(quote(change.after))\""]
        }
        if let place = change.place, change.layer != .spec {
            let area = Array(place.path.dropLast())
            lines[0] += " (위치: " + ([region(place)] + (area.isEmpty ? [] : [area.joined(separator: " › ")])).joined(separator: ", ") + ")"
        }
        return lines
    }

    /// 줄 단위 차이. 지운 줄은 `- `, 더한 줄은 `+ `로 원래 순서대로 섞는다.
    static func lineDiff(_ before: String?, _ after: String?) -> [String] {
        let old = (before ?? "").split(separator: "\n").map(String.init)
        let new = (after ?? "").split(separator: "\n").map(String.init)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [String] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                lines.append("- " + old[i]); i += 1
            } else if j < new.count, inserted.contains(j) {
                lines.append("+ " + new[j]); j += 1
            } else {
                i += 1; j += 1
            }
        }
        return lines
    }

    /// 화면을 셋씩 나눈 칸 이름. 레이어 이름이 자동 이름뿐일 때도 어디를 고칠지 짐작하게 한다.
    static func region(_ place: SpecPlace) -> String {
        let cx = place.x + place.width / 2, cy = place.y + place.height / 2
        let row = cy < 0.33 ? "위쪽" : cy < 0.66 ? "가운데" : "아래쪽"
        let column = cx < 0.33 ? "왼쪽" : cx < 0.66 ? "가운데" : "오른쪽"
        return row == column ? "화면 가운데" : "화면 \(row) \(column)"
    }
}
