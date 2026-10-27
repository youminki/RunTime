import Foundation

/// Claude Code에 그대로 붙여 마크업을 맡기는 글. 바뀐 것을 전·후 원문으로 적고 무엇을 할지 분명히 한다.
/// 요약(`DesignEvent.report`)은 사람에게 보이는 글이라 명세를 이름만 적지만, 여기서는 고칠 내용을 통째로 넣는다.
public enum ClaudePrompt {
    /// 바뀐 화면을 반영해 달라는 글. `events`는 이 화면의 아직 반영하지 않은 변경, `done`은 이미 반영한 항목(`SpecChange.key`)이다.
    public static func changes(_ events: [DesignEvent], screen: ScreenSnapshot?, project: String, link: URL?,
                               done: [UUID: Set<String>] = [:]) -> String {
        let ordered = events.sorted { $0.detectedAt < $1.detectedAt }
        guard let latest = ordered.last else { return "" }
        var lines = ["아래 피그마 화면설계서 변경을 이 저장소의 마크업에 반영해 주세요.", ""]
        lines += header(screenID: screen?.screenID ?? latest.screenID, title: screen?.title ?? latest.title,
                        path: screen?.menuPath ?? latest.menuPath, project: project, link: link)
        let format = DateFormatter()
        format.locale = Locale(identifier: "ko_KR")
        format.dateFormat = "M/d HH:mm"
        var count = 0
        for event in ordered {
            let pending = event.changes.filter { $0.op != .renumbered && !(done[event.id] ?? []).contains($0.key) }
            let kind: String? = switch event.kind {
            case .added: "새 화면"
            case .removed: "화면 삭제"
            case .replaced: "새 프레임으로 교체"
            case .changed, .changelog: nil
            }
            guard !pending.isEmpty || kind != nil else { continue }
            lines += ["", "[바뀐 것] \(format.string(from: event.detectedAt))" + (kind.map { " · " + $0 } ?? "")]
            for layer in [SpecChange.Layer.spec, .text, .header, .component] {
                for change in pending where change.layer == layer {
                    lines += describe(change)
                    count += 1
                }
            }
        }
        if count == 0 { lines += ["", "[바뀐 것]", "- 남은 변경이 없습니다 (모두 반영함)"] }
        if let screen, !screen.items.isEmpty {
            lines += ["", "[지금 기능 명세] 참고용 전체"]
            lines += items(screen)
        }
        lines += ["", "[요청]",
                  "- [바뀐 것]만 반영하고 나머지 화면은 바꾸지 마세요.",
                  "- 먼저 이 화면을 구현한 파일을 화면 ID·화면명·화면 경로·목업 문구로 찾아 어느 파일을 고칠지 알려 주세요.",
                  "- 피그마 MCP를 쓸 수 있으면 위 피그마 링크의 노드를 열어 바뀐 부분의 배치와 간격을 확인하세요.",
                  "- 끝나면 반영한 항목과, 디자인만으로 정하기 어려워 확인이 필요한 항목을 나눠 알려 주세요."]
        return lines.joined(separator: "\n")
    }

    /// 아직 바뀐 것이 없는 화면을 처음 마크업해 달라는 글. 구현을 마친 명세(`built`)는 빼고 남은 것만 맡긴다.
    public static func build(_ screen: ScreenSnapshot, project: String, link: URL?, built: Set<String> = []) -> String {
        var lines = ["아래 피그마 화면설계서 화면을 이 저장소에 마크업해 주세요.", ""]
        lines += header(screenID: screen.screenID, title: screen.title, path: screen.menuPath, project: project, link: link)
        if !screen.notes.isEmpty { lines += ["", "[참고]", screen.notes] }
        let left = screen.items.filter { !built.contains($0.text) }
        if !left.isEmpty {
            lines += ["", left.count == screen.items.count ? "[기능 명세]" : "[남은 기능 명세] \(left.count)/\(screen.items.count) (나머지는 구현함)"]
            lines += items(ScreenSnapshot(frameID: screen.frameID, screenID: screen.screenID, items: left))
        }
        let texts = ScreenBrief.orderedTexts(screen)
        if !texts.isEmpty {
            lines += ["", "[목업 문구] 화면 위에서 아래 순서"]
            lines += texts.prefix(150).map { "- " + $0.replacingOccurrences(of: "\n", with: " / ") }
        }
        let components = ScreenBrief.components(screen)
        if !components.isEmpty {
            lines += ["", "[쓰인 컴포넌트]", components.prefix(30).map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }.joined(separator: ", ")]
        }
        lines += ["", "[요청]",
                  "- 저장소에 이미 있는 공통 컴포넌트와 비슷한 화면을 먼저 찾아 같은 방식으로 만들어 주세요.",
                  "- 피그마 MCP를 쓸 수 있으면 위 피그마 링크의 노드를 열어 배치와 간격을 확인하세요.",
                  "- 기능 명세 가운데 API나 동작이 정해지지 않은 것은 자리만 만들고 따로 알려 주세요."]
        return lines.joined(separator: "\n")
    }

    private static func header(screenID: String, title: String, path: String, project: String, link: URL?) -> [String] {
        var lines = ["[화면] \(screenID) \(title)".trimmingCharacters(in: .whitespaces), "- 프로젝트: \(project)"]
        if !path.isEmpty { lines.append("- 화면 경로: \(path)") }
        if let link { lines.append("- 피그마: \(link.absoluteString)") }
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
