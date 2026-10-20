import Foundation

/// 업무 일지를 보고서 글로 바꾸고, 붙여 넣은 보고서를 다시 읽는다.
public enum WorkReport {

    // MARK: 일일·주간 보고

    /// 사내 일일보고 꼴.
    /// ```
    /// 1. uxhub
    /// - QA 수정사항 7건 반영 (완료)
    /// ```
    /// `doneFirst`면 프로젝트마다 상시 → 완료 → 진행 중 순서로 놓는다 (회의·보고를 먼저 적는 관례).
    public static func daily(_ entries: [WorkEntry], in log: WorkLog, doneFirst: Bool = false) -> String {
        numbered(doneFirst ? ordered(entries) : entries, in: log)
    }

    /// 상시 → 완료 → 진행 중(많이 한 것 먼저). 같은 무리 안에서는 원래 순서.
    public static func ordered(_ entries: [WorkEntry]) -> [WorkEntry] {
        func rank(_ status: WorkStatus) -> (Int, Int) {
            switch status {
            case .ongoing: return (0, 0)
            case .done, .percent(100): return (1, 0)
            case .percent(let value): return (2, -value)
            case .inProgress: return (3, 0)
            }
        }
        return entries.enumerated().sorted { a, b in
            let ra = rank(a.element.status), rb = rank(b.element.status)
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        .map(\.element)
    }

    /// 한 주 동안 같은 일은 한 줄로 모으고 마지막 상태를 적는다. 화요일 60%, 목요일 완료면 완료 한 줄만 남는다.
    /// `nextWeekPlan`이면 끝나지 않은 일을 `[차주 계획]`으로 한 번 더 적는다.
    public static func weekly(_ entries: [WorkEntry], in log: WorkLog, week: ClosedRange<String>,
                              doneFirst: Bool = false, nextWeekPlan: Bool = false) -> String {
        let body = period(entries, in: log, doneFirst: doneFirst,
                          header: "[주간 진행 사항] \(shortDate(week.lowerBound)) ~ \(shortDate(week.upperBound))")
        guard nextWeekPlan, !body.isEmpty else { return body }
        let open = merged(entries).filter { !$0.status.isFinished && $0.status != .ongoing }
        guard !open.isEmpty else { return body }
        return body + "\n\n[차주 계획]\n" + numbered(open, in: log)
    }

    /// 한 달치를 주간 보고와 같은 규칙으로 모은다. 머리는 `[월간 진행 사항] 2026년 10월`.
    public static func monthly(_ entries: [WorkEntry], in log: WorkLog, month: ClosedRange<String>) -> String {
        let parts = month.lowerBound.split(separator: "-")
        let title = parts.count == 3 ? "\(parts[0])년 \(Int(parts[1]) ?? 0)월" : month.lowerBound
        return period(entries, in: log, doneFirst: false, header: "[월간 진행 사항] \(title)")
    }

    private static func period(_ entries: [WorkEntry], in log: WorkLog, doneFirst: Bool, header: String) -> String {
        let lines = merged(entries)
        let body = numbered(doneFirst ? ordered(lines) : lines, in: log)
        return body.isEmpty ? "" : header + "\n" + body
    }

    /// 같은 프로젝트의 같은 제목을 하나로 모은다. 순서는 처음 나온 날을 따르고 상태와 일감 번호는 마지막 날 것을 쓴다.
    public static func merged(_ entries: [WorkEntry]) -> [WorkEntry] {
        var order: [String] = []
        var latest: [String: WorkEntry] = [:]
        for entry in entries.sorted(by: { $0.day < $1.day }) {
            let key = entry.project + "\u{1F}" + normalized(entry.title)
            if latest[key] == nil { order.append(key) }
            var merged = entry
            if merged.issue == nil { merged.issue = latest[key]?.issue }
            latest[key] = merged
        }
        return order.compactMap { latest[$0] }
    }

    /// 한 일감이 이 주 며칠에 걸쳐 어떻게 나아갔는지. 예: `60% → 완료`.
    public static func progression(of entry: WorkEntry, in entries: [WorkEntry]) -> [WorkStatus] {
        let key = normalized(entry.title)
        var steps: [WorkStatus] = []
        for item in entries.sorted(by: { $0.day < $1.day })
        where item.project == entry.project && normalized(item.title) == key && steps.last != item.status {
            steps.append(item.status)
        }
        return steps
    }

    private static func numbered(_ entries: [WorkEntry], in log: WorkLog) -> String {
        // 막 지운 빈 줄은 보고서에 넣지 않는다
        let entries = entries.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        return log.orderedProjects(of: entries).enumerated().map { index, project in
            let lines = entries.filter { $0.project == project }.map { "- \(line($0))" }
            return (["\(index + 1). \(project)"] + lines).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    public static func line(_ entry: WorkEntry) -> String {
        "\(entry.title.trimmingCharacters(in: .whitespaces)) (\(entry.status.label))"
    }

    private static func normalized(_ title: String) -> String {
        title.lowercased().filter { !$0.isWhitespace }
    }

    /// `2026-10-20` → `10.20`
    public static func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return key }
        return "\(month).\(day)"
    }

    // MARK: 레드마인

    /// 레드마인 일감 하나에 올릴 것.
    public struct RedmineUpdate: Equatable {
        public let issue: Int
        public let doneRatio: Int?
        public let note: String
        public let entryIDs: [UUID]
        /// 댓글·진척률을 보내야 하는지. 시간만 남기면 될 때는 false라 댓글을 또 올리지 않는다.
        public var needsNote = true
        /// 아직 남기지 않은 작업 시간. 레드마인 소요 시간은 날짜마다 따로라 날마다 한 건씩 남긴다.
        public var timeEntries: [TimeEntry] = []
        /// 이 일감 줄이 적힌 날들.
        public var days: [String] = []

        public var hours: Double? {
            let total = timeEntries.map(\.hours).reduce(0, +)
            return total > 0 ? total : nil
        }
    }

    public struct TimeEntry: Equatable {
        public let day: String
        public let hours: Double
        public let entryIDs: [UUID]
    }

    /// 일감 번호별로 모은다. 같은 일감에 여러 줄이 있으면 [작업 내용]에 모두 적고 진척률은 가장 늦은 줄을 쓴다.
    public static func redmineUpdates(_ entries: [WorkEntry]) -> [RedmineUpdate] {
        var order: [Int] = []
        var grouped: [Int: [WorkEntry]] = [:]
        for entry in entries.sorted(by: { $0.day < $1.day }) {
            guard let issue = entry.issue else { continue }
            if grouped[issue] == nil { order.append(issue) }
            grouped[issue, default: []].append(entry)
        }
        return order.map { issue in
            let items = grouped[issue] ?? []
            let lastDay = items.last?.day
            let ratio = items.filter { $0.day == lastDay }.compactMap(\.status.doneRatio).max()
            let timed = items.filter(\.needsTime)
            let timeEntries = Dictionary(grouping: timed, by: \.day).sorted { $0.key < $1.key }.map { day, rows in
                TimeEntry(day: day, hours: rows.compactMap(\.hours).reduce(0, +), entryIDs: rows.map(\.id))
            }
            // 댓글은 보내야 할 줄만으로 만든다 (시간만 남은 줄의 내용을 또 올리지 않게)
            let noteItems = items.filter(\.needsRedmine)
            return RedmineUpdate(issue: issue, doneRatio: ratio, note: comment(noteItems.isEmpty ? items : noteItems),
                                 entryIDs: items.map(\.id), needsNote: !noteItems.isEmpty, timeEntries: timeEntries,
                                 days: Array(Set(items.map(\.day))).sorted())
        }
    }

    /// 직접 쓴 댓글이 있으면 그대로 쓰고, 없으면 제목으로 [작업 내용]을 만든다.
    public static func comment(_ entries: [WorkEntry]) -> String {
        let written = entries.map { $0.note.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let untitled = entries.filter { $0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var parts = written
        if !untitled.isEmpty {
            var seen = Set<String>()
            let lines = untitled.map(\.title).filter { seen.insert(normalized($0)).inserted }.map { "- \($0)" }
            parts.insert((["[작업 내용]"] + lines).joined(separator: "\n"), at: 0)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Claude에게 그대로 붙여 넣는 글. git을 다시 훑지 않고 이 글만 보고 올리게 해 토큰을 아낀다.
    public static func redmineRequest(_ updates: [RedmineUpdate]) -> String {
        guard !updates.isEmpty else { return "" }
        let head = "레드마인 일감에 아래 진척률과 댓글을 반영해 줘. 상태는 바꾸지 말고, 댓글은 고치지 말고 그대로 올려."
        let blocks = updates.map { update in
            let ratio = update.doneRatio.map { "진척률 \($0)%" } ?? "진척률 그대로"
            return "#\(update.issue) \(ratio)\n\(update.note)"
        }
        return ([head] + blocks).joined(separator: "\n\n---\n")
    }

    // MARK: 붙여 넣기

    /// 이미 써 둔 보고서를 읽는다. `1.uxhub`, `2. VeloX` 같은 번호 줄이 프로젝트, `- 내용 (완료)`가 일이다.
    /// 줄 안의 `#12345`는 일감 번호로 떼어 낸다. `[금일 진행 사항]` 같은 머리줄은 건너뛴다.
    public static func parse(_ text: String, day: String, now: Date = Date()) -> [WorkEntry] {
        var project: String?
        var entries: [WorkEntry] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("[") else { continue }
            if let name = projectName(line) {
                project = name
                continue
            }
            guard let first = line.first, "-•·*".contains(first), let project else { continue }
            var body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            var status = WorkStatus.done
            if body.hasSuffix(")"), let open = body.lastIndex(of: "(") {
                let inside = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
                if let parsed = WorkStatus(label: inside) {
                    status = parsed
                    body = String(body[..<open]).trimmingCharacters(in: .whitespaces)
                }
            }
            let (title, issue) = splitIssue(body)
            guard !title.isEmpty else { continue }
            entries.append(WorkEntry(day: day, project: project, title: title, status: status, issue: issue, updatedAt: now))
        }
        return entries
    }

    /// `1.uxhub`, `2) VeloX` → 프로젝트 이름.
    private static func projectName(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        // 프로젝트 번호는 한두 자리. `2026.10.20 보고` 같은 날짜 줄은 프로젝트로 읽지 않는다
        guard (1...2).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, ".)".contains(mark), rest.dropFirst().first?.isNumber != true else { return nil }
        let name = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 제목에서 `#12345`를 떼어 낸다.
    public static func splitIssue(_ text: String) -> (title: String, issue: Int?) {
        guard let range = text.range(of: #"#(\d{2,7})"#, options: .regularExpression) else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        let issue = Int(text[range].dropFirst())
        var title = text
        title.removeSubrange(range)
        title = title.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return (title, issue)
    }
}
