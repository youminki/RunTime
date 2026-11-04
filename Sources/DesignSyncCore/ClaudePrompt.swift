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
        // 할 일이 없으면 반영하라는 요청을 붙이지 않는다
        guard !body.isEmpty else { return (lines + ["- 남은 변경이 없습니다 (모두 반영함)"]).joined(separator: "\n") }
        lines += body + ["", request(several: false, link: link != nil)]
        return lines.joined(separator: "\n")
    }

    /// 메뉴 하나의 반영할 변경을 화면별로 묶은 글. 날짜 비교는 범위가 프로젝트·화면일 수 있어 `unit`으로 이름을 바꾸고,
    /// 목록에서 골라 묶은 변경처럼 범위 이름이 없으면 `path`를 비운다.
    public static func menu(_ screens: [(screen: ScreenSnapshot, events: [DesignEvent], link: URL?)], path: String,
                            unit: String = "메뉴", done: [UUID: Set<String>] = [:]) -> String {
        var lines = [path.isEmpty ? "아래 피그마 화면설계서 변경을 마크업에 반영해 주세요." : "아래 피그마 화면설계서 ‘\(path)’ \(unit)의 변경을 마크업에 반영해 주세요."]
        var listed = 0
        var linked = false
        for item in screens {
            let body = changeLines(item.events, done: done)
            guard !body.isEmpty else { continue }
            listed += 1
            linked = linked || item.link != nil
            lines += [""] + header(screenID: item.screen.screenID, title: item.screen.title, path: item.screen.menuPath, link: item.link) + body
        }
        guard listed > 0 else { return (lines + ["", "- 남은 변경이 없습니다 (모두 반영함)"]).joined(separator: "\n") }
        lines += ["", request(several: listed > 1, link: linked)]
        return lines.joined(separator: "\n")
    }

    /// 메뉴 화면들을 처음 마크업해 달라는 글. 화면마다 참고와 남은 기능 명세만 넣고, 목업 문구·배치는 피그마 링크로 읽게 한다.
    /// 구현을 마친 화면(남은 명세가 없는 화면)은 뺀다.
    public static func menuBuild(_ screens: [(screen: ScreenSnapshot, link: URL?, built: Set<String>)], path: String) -> String {
        var lines = ["아래 피그마 화면설계서 ‘\(path)’ 메뉴의 화면들을 마크업해 주세요."]
        var listed = 0
        var linked = false
        for item in screens {
            let left = item.screen.items.filter { !item.built.contains($0.text) }
            guard !left.isEmpty || item.screen.items.isEmpty else { continue }
            listed += 1
            linked = linked || item.link != nil
            lines += [""] + header(screenID: item.screen.screenID, title: item.screen.title, path: item.screen.menuPath, link: item.link)
            lines += spec(item.screen, left: left)
        }
        guard listed > 0 else { return (lines + ["", "- 남은 화면이 없습니다 (모든 기능 명세를 구현함)"]).joined(separator: "\n") }
        lines += ["", buildRequest(link: linked)]
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
        // 반영할 것이 남지 않았으면(별표·예시 데이터·내부 부품만 바뀜) 빈 글로 돌려 "반영할 변경"과 판정을 맞춘다
        guard changes.contains(where: isActionable) || !kinds.isEmpty else { return [] }
        var lines = ["[바뀐 것]" + (kinds.isEmpty ? "" : " " + Array(Set(kinds)).sorted().joined(separator: " · "))]
        for change in changes where change.layer == .spec { lines += describe(change) }
        lines += textLines(changes.filter { $0.layer == .text })
        for change in changes where change.layer == .header { lines += describe(change) }
        lines += componentLines(changes.filter { $0.layer == .component })
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
        "[요청] " + (several ? "화면마다 " : "") + "[바뀐 것]만 반영하고 나머지는 그대로 두세요. 고칠 파일을 먼저 찾아 알려 주"
            + (link ? "고, 배치·간격은 피그마 MCP로 링크 노드를 열어 확인하세요." : "세요.")
            + " 끝나면 반영한 것과 확인이 필요한 것을 나눠 알려 주세요."
    }

    private static func buildRequest(link: Bool) -> String {
        "[요청] " + (link ? "피그마 MCP로 링크 노드를 열어 목업 문구·배치·간격을 확인하고, " : "")
            + "저장소의 비슷한 화면과 공통 컴포넌트 방식으로 만들어 주세요. 정해지지 않은 API·동작은 자리만 만들고 알려 주세요."
    }

    private static func header(screenID: String, title: String, path: String, link: URL?) -> [String] {
        let name = [screenID, title].filter { !$0.isEmpty }.joined(separator: " ")
        var lines = ["[화면]" + (name.isEmpty ? "" : " " + name) + (path.isEmpty ? "" : " (\(path))")]
        if let link { lines.append("피그마: \(link.absoluteString)") }
        return lines
    }

    private static func items(_ screen: ScreenSnapshot) -> [String] {
        screen.items.flatMap { item -> [String] in
            let body = item.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return ["\(item.number). \(body.first ?? "")"] + body.dropFirst().map { "   " + $0 }
        }
    }

    /// 목업 문구는 수십 개가 한꺼번에 바뀌어 글이 길어진다. 수정만 한 줄씩(전 → 후, 화면 어디쯤),
    /// 추가·삭제는 한 줄로 모으고, 글자가 없는 표시(*, ●●●)와 표 칸의 예시 데이터는 개수만 적는다.
    static func textLines(_ changes: [SpecChange]) -> [String] {
        var lines: [String] = []
        var added: [String] = [], removed: [String] = []
        var samples = 0
        for change in changes {
            if isSampleData(change) { samples += 1; continue }
            switch change.op {
            case .added: if let text = meaningful(change.after) { added.append(text) }
            case .removed: if let text = meaningful(change.before) { removed.append(text) }
            default:
                guard meaningful(change.before) != nil || meaningful(change.after) != nil else { continue }
                let place = change.place.map { " (" + region($0) + ")" } ?? ""
                lines.append("- 목업 문구 수정: \"\(oneLine(change.before))\" → \"\(oneLine(change.after))\"" + place)
            }
        }
        if !added.isEmpty { let list = quoted(added); lines.append("- 목업 문구 추가 \(list.count)개: " + list.text) }
        if !removed.isEmpty { let list = quoted(removed); lines.append("- 목업 문구 삭제 \(list.count)개: " + list.text) }
        if samples > 0 { lines.append("- 표·목록 예시 데이터 \(samples)곳 바뀜 (값은 피그마 참고)") }
        return lines
    }

    /// 컴포넌트는 다른 컴포넌트로 바꾼 것만 한 줄씩 두고, 같은 이름의 변형 교체는 개수로, `_`로 시작하는 내부 부품은 뺀다.
    static func componentLines(_ changes: [SpecChange]) -> [String] {
        var lines: [String] = []
        var variants = 0
        for change in changes {
            switch change.op {
            case .added, .removed:
                let parts = (change.op == .added ? change.after : change.before ?? "")?
                    .components(separatedBy: ", ").filter { !$0.hasPrefix("_") } ?? []
                guard !parts.isEmpty else { continue }
                let shown = parts.prefix(8).joined(separator: ", ") + (parts.count > 8 ? " 외 \(parts.count - 8)종" : "")
                lines.append("- 컴포넌트 \(change.op == .added ? "추가" : "삭제"): " + shown)
            default:
                if change.before == change.after { variants += 1; continue }
                lines.append("- 컴포넌트 교체: \"\(oneLine(change.before))\" → \"\(oneLine(change.after))\"")
            }
        }
        if variants > 0 { lines.append("- 컴포넌트 변형(상태·크기) 교체 \(variants)곳") }
        return lines
    }

    /// 마크업할 것이 있는 변경인지. 번호 이동, 작성자·섹션 표시, 글자 없는 표시(*), 표 예시 데이터, `_` 내부 부품만의 추가·삭제는 아니다.
    /// "반영할 변경" 건수(`DesignEvent.needsMarkup`)와 Claude 문구가 같은 판정을 쓴다.
    public static func isActionable(_ change: SpecChange) -> Bool {
        guard change.op != .renumbered else { return false }
        switch change.layer {
        case .header: return !skippedHeaders.contains(change.label)
        case .spec: return true
        case .text:
            return !isSampleData(change) && (meaningful(change.before) != nil || meaningful(change.after) != nil)
        case .component:
            guard change.op == .added || change.op == .removed else { return true }
            let summary = (change.op == .added ? change.after : change.before) ?? ""
            return summary.components(separatedBy: ", ").contains { !$0.isEmpty && !$0.hasPrefix("_") }
        }
    }

    /// 표 칸 안의 글은 예시 데이터라 마크업할 글이 아니다.
    static func isSampleData(_ change: SpecChange) -> Bool { isSampleData(place: change.place) }

    public static func isSampleData(place: SpecPlace?) -> Bool {
        let path = (place?.path ?? []).joined(separator: "/").lowercased()
        return ["tbody", "body-cell", "datatable-row", "table-row"].contains { path.contains($0) }
    }

    /// 글자나 숫자가 없는 표시(필수 별표, 가림 문자)는 뺀다.
    public static func meaningful(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }

    private static func oneLine(_ text: String?) -> String { (text ?? "").replacingOccurrences(of: "\n", with: " / ") }

    /// 같은 글은 한 번만, 많으면 앞의 30개만, 한 글이 길면 60자에서 자른다. 개수는 겹친 것을 뺀 수다.
    private static func quoted(_ texts: [String]) -> (count: Int, text: String) {
        var seen = Set<String>()
        let unique = texts.filter { seen.insert($0).inserted }
        let shown = unique.prefix(30).map { text -> String in
            let line = oneLine(text)
            return "\"" + (line.count > 60 ? String(line.prefix(60)) + "…" : line) + "\""
        }.joined(separator: ", ")
        return (unique.count, shown + (unique.count > 30 ? " 외 \(unique.count - 30)개" : ""))
    }

    /// 변경 하나. 명세는 전·후 원문을 줄째로, 목업 요소는 화면 어디쯤인지 붙인다.
    static func describe(_ change: SpecChange) -> [String] {
        let layer = ["header": "화면 정보", "spec": "기능 명세", "text": "목업 문구", "component": "컴포넌트"][change.layer.rawValue] ?? ""
        let quote = { (text: String?) in (text ?? "").replacingOccurrences(of: "\n", with: " / ") }
        let indent = { (text: String?) in (text ?? "").split(separator: "\n").map { "    " + $0 } }
        var lines: [String]
        switch (change.layer, change.op) {
        case (.spec, .added): lines = ["- \(layer) 추가: \(change.label)"] + indent(dropTitle(change.after, label: change.label))
        case (.spec, .removed): lines = ["- \(layer) 삭제: \(change.label)"] + indent(dropTitle(change.before, label: change.label))
        case (.spec, _):
            // 긴 항목에서 몇 줄만 바뀌므로 바뀐 줄만 -/+로 적는다. 항목 전체는 피그마 링크로 읽게 한다
            lines = ["- \(layer) 수정: \(change.label) (바뀐 줄만, - 전 / + 후)"] + lineDiff(change.before, change.after).map { "    " + $0 }
        case (.header, .modified) where (change.before ?? "").contains("\n") || (change.after ?? "").contains("\n"):
            // 참고처럼 긴 여러 줄 글은 전·후를 통째로 적으면 길어 바뀐 줄만 적는다
            lines = ["- \(change.label) 수정 (바뀐 줄만, - 전 / + 후)"] + lineDiff(change.before, change.after).map { "    " + $0 }
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

    /// 명세 항목 글의 첫 줄이 제목(`7. 데이터 미리보기`의 `데이터 미리보기`)과 같으면 겹치므로 뺀다.
    static func dropTitle(_ text: String?, label: String) -> String? {
        guard let text else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 번호(`7.`, `9.1.`)를 뗀 제목과 첫 줄이 똑같을 때만 뺀다
        let title = label.replacingOccurrences(of: #"^[\d.]+\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty, first == title { lines.removeFirst() }
        return lines.joined(separator: "\n")
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
