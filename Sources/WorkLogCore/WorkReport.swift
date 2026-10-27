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
    /// `byIssue`면 레드마인 일감 이름으로 적고 QA 건은 `QA 수정사항 N건 반영` 한 줄로 모은다.
    /// `grouped`면 같은 메뉴 경로(`데이터 수집 > 공유 파일 관리 > …`) 줄을 경로 한 줄 아래로 묶는다 (`grouping` 참고).
    public static func daily(_ entries: [WorkEntry], in log: WorkLog, doneFirst: Bool = false, byIssue: Bool = false,
                             grouped: Bool = false) -> String {
        let lines = byIssue ? issueLines(entries, in: log) : entries
        return numbered(doneFirst ? ordered(lines) : lines, in: log, grouped: grouped)
    }

    /// 일일보고 머리줄. 오늘이면 `[10/27 금일 진행 사항]`, 출근 때 올리는 계획은 `[10/27 금일 진행 예정 사항]`.
    /// 지난날을 보고 있으면 `금일` 없이 `[10/24 진행 사항]`.
    public static func dayHeader(_ day: String, plan: Bool = false, today: String = WorkDay.today()) -> String {
        let parts = day.split(separator: "-")
        let date = parts.count == 3 ? "\(parts[1])/\(parts[2])" : day
        return "[\(date) \(day == today ? "금일 " : "")진행\(plan ? " 예정" : "") 사항]"
    }

    /// 진행 예정 사항에 프로젝트마다 적는 한 줄 (사내 관례로 늘 같은 말을 쓴다).
    public static let planLine = "마크업 및 API 연동"

    /// 출근 때 올리는 오늘 할 일. 오늘 적은 일과 앞선 날 끝나지 않은 일이 있는 프로젝트마다 `planLine` 한 줄.
    /// ```
    /// 1. UxHub
    /// - 마크업 및 API 연동
    /// 2. VeloX
    /// - 마크업 및 API 연동
    /// ```
    /// 상시(회의 등)만 있는 프로젝트는 뺀다.
    public static func plan(day: String, in log: WorkLog) -> String {
        let carried = log.previousDay(before: day).map { log.carryCandidates(from: $0, to: day) } ?? []
        let rows = (log.entries(on: day) + carried).filter {
            $0.status != .ongoing && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return log.orderedProjects(of: rows).enumerated()
            .map { "\($0.offset + 1). \($0.element)\n- \(planLine)" }
            .joined(separator: "\n")
    }

    /// 레드마인 일감 기준 보고 줄. 같은 일감은 한 줄(가장 많이 한 상태), QA 건은 프로젝트마다 한 줄로 앞에 둔다.
    /// 장부에 없는 일감과 일감 없는 줄(회의 등)은 그대로 둔다.
    public static func issueLines(_ entries: [WorkEntry], in log: WorkLog) -> [WorkEntry] {
        var result: [WorkEntry] = []
        for project in log.orderedProjects(of: entries) {
            // 막 지운 빈 줄은 일감 이름으로 바뀌어 보고서에 나오지 않게 먼저 뺀다
            let rows = entries.filter { $0.project == project && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            var qa: [Int: WorkStatus] = [:]
            var issueIndex: [Int: Int] = [:]
            var lines: [WorkEntry] = []
            for entry in rows {
                guard let issue = entry.issue, let info = log.issue(issue) else {
                    lines.append(entry)
                    continue
                }
                if info.isQA {
                    qa[issue] = best(qa[issue], entry.status)
                    continue
                }
                if let index = issueIndex[issue] {
                    lines[index].status = best(lines[index].status, entry.status)
                    continue
                }
                var line = entry
                line.title = info.reportTitle
                issueIndex[issue] = lines.count
                lines.append(line)
            }
            // 화면 기능 일감은 끝나면 (100%)로 적는다 (보고 관례: 기능 연동은 %, QA·기획 반영은 완료)
            for (issue, index) in issueIndex where lines[index].status == .done {
                if let info = log.issue(issue), IssueInfo.isWorkName(IssueInfo.cleanSubject(info.subject)) {
                    lines[index].status = .percent(100)
                }
            }
            if !qa.isEmpty, let first = rows.first {
                let finished = qa.values.filter(\.isFinished).count
                // 끝난 비율을 10% 단위로 반올림하되, 다 끝나지 않았으면 100%로 올리지 않는다
                let ratio = min(90, Int((Double(finished) / Double(qa.count) * 10).rounded()) * 10)
                let status: WorkStatus = finished == qa.count ? .done : finished == 0 ? .inProgress : .percent(max(10, ratio))
                let line = WorkEntry(day: first.day, project: project, title: "QA 수정사항 \(qa.count)건 반영", status: status,
                                     updatedAt: first.updatedAt)
                lines.insert(line, at: 0)
            }
            result += lines
        }
        return result
    }

    /// 둘 가운데 더 나아간 상태. 상시는 상시끼리만 남는다.
    private static func best(_ a: WorkStatus?, _ b: WorkStatus) -> WorkStatus {
        guard let a else { return b }
        func value(_ s: WorkStatus) -> Int {
            switch s {
            case .done: return 101
            case .percent(let v): return v
            case .inProgress: return 1
            case .ongoing: return 0
            }
        }
        if a == .done || b == .done { return .done }
        return value(a) >= value(b) ? a : b
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
                              doneFirst: Bool = false, nextWeekPlan: Bool = false, byIssue: Bool = false,
                              grouped: Bool = false) -> String {
        let body = period(entries, in: log, doneFirst: doneFirst, byIssue: byIssue, grouped: grouped,
                          header: "[주간 진행 사항] \(shortDate(week.lowerBound)) ~ \(shortDate(week.upperBound))")
        guard nextWeekPlan, !body.isEmpty else { return body }
        let lines = byIssue ? issueLines(merged(entries), in: log) : merged(entries)
        let open = lines.filter { !$0.status.isFinished && $0.status != .ongoing }
        guard !open.isEmpty else { return body }
        return body + "\n\n[차주 계획]\n" + numbered(open, in: log, grouped: grouped)
    }

    /// 한 달치를 주간 보고와 같은 규칙으로 모은다. 머리는 `[월간 진행 사항] 2026년 10월`.
    public static func monthly(_ entries: [WorkEntry], in log: WorkLog, month: ClosedRange<String>, byIssue: Bool = false,
                               grouped: Bool = false) -> String {
        let parts = month.lowerBound.split(separator: "-")
        let title = parts.count == 3 ? "\(parts[0])년 \(Int(parts[1]) ?? 0)월" : month.lowerBound
        return period(entries, in: log, doneFirst: false, byIssue: byIssue, grouped: grouped, header: "[월간 진행 사항] \(title)")
    }

    private static func period(_ entries: [WorkEntry], in log: WorkLog, doneFirst: Bool, byIssue: Bool, grouped: Bool,
                               header: String) -> String {
        let lines = byIssue ? issueLines(merged(entries), in: log) : merged(entries)
        let body = numbered(doneFirst ? ordered(lines) : lines, in: log, grouped: grouped)
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

    private static func numbered(_ entries: [WorkEntry], in log: WorkLog, grouped: Bool = false) -> String {
        // 막 지운 빈 줄은 보고서에 넣지 않는다
        let entries = entries.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        return log.orderedProjects(of: entries).enumerated().map { index, project in
            let rows = entries.filter { $0.project == project }
            let lines = grouped ? groupedLines(rows) : rows.map { "- \(line($0))" }
            return (["\(index + 1). \(project)"] + lines).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// 경로 앞부분이 같은 줄이 둘 이상이면 경로를 한 번만 적고 끝 이름을 그 아래 `  · `로 늘어놓는다.
    /// ```
    /// - 데이터 수집 > 수집 파이프라인 관리
    ///   · 작업 제어 API 연동 (100%)
    ///   · 로그 조회 API 연동 (100%)
    /// ```
    /// 묶음은 첫 줄이 있던 자리에 두어 상시 → 완료 → 진행 순서를 되도록 지킨다.
    static func groupedLines(_ rows: [WorkEntry]) -> [String] {
        let groups = grouping(rows)
        var printed: Set<String> = []
        var lines: [String] = []
        for row in rows {
            guard let (path, _) = split(row.title), let members = groups[path], members.count > 1 else {
                lines.append("- \(line(row))")
                continue
            }
            guard printed.insert(path).inserted else { continue }
            lines.append("- \(path)")
            for member in members {
                let leaf = split(member.title)?.leaf ?? member.title
                lines.append("  · \(leaf) (\(member.status.label))")
            }
        }
        return lines
    }

    /// 경로 앞부분마다 그 경로를 쓰는 줄 (원래 순서).
    private static func grouping(_ rows: [WorkEntry]) -> [String: [WorkEntry]] {
        var groups: [String: [WorkEntry]] = [:]
        for row in rows {
            if let (path, _) = split(row.title) { groups[path, default: []].append(row) }
        }
        return groups
    }

    /// `A > B > 끝 이름` → (`A > B`, `끝 이름`). 경로가 없으면 nil.
    private static func split(_ title: String) -> (path: String, leaf: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: " > ", options: .backwards) else { return nil }
        let path = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let leaf = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty || leaf.isEmpty ? nil : (path, leaf)
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
        public var doneRatio: Int?
        public let note: String
        public let entryIDs: [UUID]
        /// 댓글·진척률을 보내야 하는지. 시간만 남기면 될 때는 false라 댓글을 또 올리지 않는다.
        public var needsNote = true
        /// 아직 남기지 않은 작업 시간. 레드마인 소요 시간은 날짜마다 따로라 날마다 한 건씩 남긴다.
        public var timeEntries: [TimeEntry] = []
        /// 이 일감 줄이 적힌 날들.
        public var days: [String] = []
        /// 마지막 날 줄이 몇 %인지 정하지 않은 진행중이다. 설정의 진행중 진척률을 얹을 수 있다 (상시 업무는 아니다).
        public var inProgress = false

        /// 진행중 일감에 설정한 기본 진척률을 얹는다. 직접 고른 진척률은 이 뒤에 얹는다.
        public func withInProgressRatio(_ ratio: Int?) -> RedmineUpdate {
            guard inProgress, doneRatio == nil, let ratio else { return self }
            var copy = self
            copy.doneRatio = ratio
            return copy
        }

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
    /// `log`를 주면 MR에서 온 댓글을 레드마인 꼴로 다듬는다 (리뷰어용 섹션·일감 번호를 빼고, 따로 줄이 있는 일감 줄은 그쪽으로).
    public static func redmineUpdates(_ entries: [WorkEntry], log: WorkLog? = nil) -> [RedmineUpdate] {
        var order: [Int] = []
        var grouped: [Int: [WorkEntry]] = [:]
        let entries = log.map { log in entries.map { tidied($0, in: log) } } ?? entries
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
            let inProgress = ratio == nil && items.contains { $0.day == lastDay && $0.status == .inProgress }
            return RedmineUpdate(issue: issue, doneRatio: ratio, note: comment(noteItems.isEmpty ? items : noteItems),
                                 entryIDs: items.map(\.id), needsNote: !noteItems.isEmpty, timeEntries: timeEntries,
                                 days: Array(Set(items.map(\.day))).sorted(), inProgress: inProgress)
        }
    }

    /// 진척률과 함께 바꿀 일감 칸. 비어 있으면 댓글과 진척률만 보낸다.
    /// 날짜는 `yyyy-MM-dd`, 빈 글자면 그 칸을 비운다.
    public struct IssueFields: Equatable {
        public var status: RedmineAPI.Status?
        public var startDate: String?
        public var dueDate: String?
        public var assignee: RedmineAPI.Member?

        public init(status: RedmineAPI.Status? = nil, startDate: String? = nil, dueDate: String? = nil,
                    assignee: RedmineAPI.Member? = nil) {
            self.status = status
            self.startDate = startDate
            self.dueDate = dueDate
            self.assignee = assignee
        }

        public var isEmpty: Bool { status == nil && startDate == nil && dueDate == nil && assignee == nil }

        /// 자동으로 정한 칸 위에 직접 고른 칸을 얹고, 지금 값과 같은 칸은 뺀다 (바뀌지 않는 칸을 보내지 않게).
        public static func merged(auto: IssueFields, edit: IssueEdit?, current: IssueInfo?,
                                  statuses: [RedmineAPI.Status]) -> IssueFields {
            var fields = auto
            if let edit {
                if let id = edit.statusID { fields.status = statuses.first { $0.id == id } }
                if let start = edit.startDate { fields.startDate = start }
                if let due = edit.dueDate { fields.dueDate = due }
                if let assignee = edit.assignee { fields.assignee = assignee }
            }
            if fields.status?.id == current?.statusID { fields.status = nil }
            if fields.startDate == (current?.startDate ?? "") { fields.startDate = nil }
            if fields.dueDate == (current?.dueDate ?? "") { fields.dueDate = nil }
            if fields.assignee?.id == current?.assignee?.id { fields.assignee = nil }
            return fields
        }

        /// 보낸 뒤의 시작일이 기한보다 늦으면 레드마인이 422로 거절한다. 미리 알린다.
        public func problem(current: IssueInfo?) -> String? {
            let start = startDate ?? current?.startDate ?? ""
            let due = dueDate ?? current?.dueDate ?? ""
            guard !start.isEmpty, !due.isEmpty, start > due else { return nil }
            return "시작일이 완료 기한보다 늦습니다"
        }
    }

    /// 직접 고른 칸. nil은 고르지 않음(자동), 날짜의 빈 글자는 비우기.
    public struct IssueEdit: Codable, Equatable {
        public var statusID: Int?
        public var startDate: String?
        public var dueDate: String?
        public var assignee: RedmineAPI.Member?
        /// 직접 고른 진척률. 일지 줄의 상태(완료·60% 등)로 정한 값보다 앞선다.
        public var doneRatio: Int?

        public init(statusID: Int? = nil, startDate: String? = nil, dueDate: String? = nil, assignee: RedmineAPI.Member? = nil,
                    doneRatio: Int? = nil) {
            self.statusID = statusID
            self.startDate = startDate
            self.dueDate = dueDate
            self.assignee = assignee
            self.doneRatio = doneRatio
        }

        public var isEmpty: Bool { statusID == nil && startDate == nil && dueDate == nil && assignee == nil && doneRatio == nil }

        /// 직접 고른 진척률을 얹은 보낼 것. 진척률로 정하는 상태(100%면 완료)도 이 값을 따른다.
        public func applied(to update: RedmineUpdate) -> RedmineUpdate {
            guard let doneRatio else { return update }
            var copy = update
            copy.doneRatio = doneRatio
            return copy
        }
    }

    /// 일지를 보고 일감 상태·시작일·완료 기한을 맞춘다.
    /// 상태는 처음 상태(할일·신규) → 진행 → 완료 순으로 앞으로만 옮긴다. 레드마인의 상태 목록 순서는 일의 흐름과 다를 수 있어
    /// (할일, 처리중, 코드리뷰, 테스트, 완료, … 해결) 순서 대신 이 세 칸만 본다. 테스트·반려처럼 그 밖의 상태면 건드리지 않는다.
    /// 날짜는 비어 있을 때만 채운다. 지금 값을 모르는 일감(옛 장부)은 아무것도 바꾸지 않는다. 빈 칸으로 알고 덮어쓰면 안 되니까.
    public static func issueFields(for update: RedmineUpdate, current: IssueInfo?, statuses: [RedmineAPI.Status],
                                   progressID: Int?, doneID: Int?) -> IssueFields {
        guard let current, let currentID = current.statusID, update.needsNote else { return IssueFields() }
        let finished = update.doneRatio == 100
        var fields = IssueFields()
        func rank(_ id: Int) -> Int? {
            if id == doneID { return 2 }
            if id == progressID { return 1 }
            if let status = statuses.first(where: { $0.id == id }), isInitial(status, in: statuses) { return 0 }
            return nil
        }
        if let targetID = finished ? doneID : progressID,
           let target = statuses.first(where: { $0.id == targetID }),
           let from = rank(currentID), let to = rank(targetID), to > from {
            fields.status = target
        }
        let due = current.dueDate ?? (finished ? update.days.last : nil)
        if current.startDate == nil, let first = update.days.first, due.map({ first <= $0 }) ?? true {
            fields.startDate = first
        }
        if finished, current.dueDate == nil, let last = update.days.last,
           (current.startDate ?? fields.startDate).map({ $0 <= last }) ?? true {
            fields.dueDate = last
        }
        return fields
    }

    /// 새 일감이 처음 받는 상태 (목록 맨 앞이거나 할일·신규).
    static func isInitial(_ status: RedmineAPI.Status, in statuses: [RedmineAPI.Status]) -> Bool {
        let name = status.name.lowercased()
        return status.id == statuses.first?.id || ["할일", "신규", "new", "todo", "to do"].contains(name)
    }

    /// 상태 이름으로 진행·완료 상태를 어림한다 (설정에서 고르지 않았을 때). 완료는 `완료`를 `해결`보다 먼저 본다.
    public static func defaultStatuses(_ statuses: [RedmineAPI.Status]) -> (progress: Int?, done: Int?) {
        func find(_ words: [String], closed: Bool? = nil) -> Int? {
            for word in words {
                if let hit = statuses.first(where: { (closed == nil || $0.isClosed == closed) && $0.name.lowercased().contains(word) }) {
                    return hit.id
                }
            }
            return nil
        }
        return (find(["처리중", "진행", "in progress", "progress", "doing"], closed: false),
                find(["완료", "done"]) ?? find(["해결", "resolved", "closed"]))
    }

    /// MR에서 온 댓글을 보내기 전에 한 번 더 다듬는다. 원문에서 만든 댓글은 이미 다듬어져 있고,
    /// 사용자가 고친 댓글도 리뷰어용 섹션과 일감 번호만은 뗀다.
    static func tidied(_ entry: WorkEntry, in log: WorkLog) -> WorkEntry {
        guard let source = entry.source, source.hasPrefix("mr:"), !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.note != entry.autoNote else { return entry }
        let base = String(source.split(separator: "#").first ?? Substring(source))
        let siblings = Set(log.entries.filter { ($0.source == base || $0.source?.hasPrefix(base + "#") == true) && $0.day == entry.day }.compactMap(\.issue))
        var copy = entry
        copy.note = RedmineComment.fromMR(entry.note, mr: WorkCapture.mrNumber(source), issue: entry.issue,
                                          subjects: WorkCapture.subjects(for: Array(siblings), in: log), siblings: siblings)
        return copy
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
    /// `html`이면 댓글을 레드마인에 실릴 HTML 그대로 넣어, Claude가 꼴을 바꾸다 줄바꿈을 잃지 않게 한다.
    public static func redmineRequest(_ updates: [RedmineUpdate], fields: [Int: IssueFields] = [:], html: Bool = false) -> String {
        guard !updates.isEmpty else { return "" }
        let head = html
            ? "레드마인 일감에 아래 진척률과 댓글을 반영해 줘. 적힌 칸 말고는 바꾸지 말고, 댓글은 HTML이니 고치지 말고 notes에 그대로 넣어 (줄바꿈을 지우지 마)."
            : "레드마인 일감에 아래 진척률과 댓글을 반영해 줘. 적힌 칸 말고는 바꾸지 말고, 댓글은 고치지 말고 그대로 올려."
        let blocks = updates.map { update in
            var parts = [update.doneRatio.map { "진척률 \($0)%" } ?? "진척률 그대로"]
            let extra = fields[update.issue] ?? IssueFields()
            if let status = extra.status { parts.append("상태 \(status.name)") }
            if let start = extra.startDate { parts.append(start.isEmpty ? "시작일 비우기" : "시작일 \(start)") }
            if let due = extra.dueDate { parts.append(due.isEmpty ? "완료 기한 비우기" : "완료 기한 \(due)") }
            if let assignee = extra.assignee { parts.append("담당자 \(assignee.name)(id \(assignee.id))") }
            return "#\(update.issue) \(parts.joined(separator: " · "))\n\(html ? RedmineNote.html(update.note) : update.note)"
        }
        return ([head] + blocks).joined(separator: "\n\n---\n")
    }

    // MARK: 붙여 넣기

    /// 이미 써 둔 보고서를 읽는다. `1.uxhub`, `2. VeloX` 같은 번호 줄이 프로젝트, `- 내용 (완료)`가 일이다.
    /// 줄 안의 `#12345`는 일감 번호로 떼어 낸다. `[금일 진행 사항]` 같은 머리줄은 건너뛴다.
    /// 묶어 쓴 보고서(`- 경로` 아래 들여 쓴 `· 끝 이름 (상태)`)는 경로를 다시 붙여 한 줄씩 읽는다.
    public static func parse(_ text: String, day: String, now: Date = Date()) -> [WorkEntry] {
        var project: String?
        var entries: [WorkEntry] = []
        let rawLines = text.components(separatedBy: .newlines)
        var group: String?
        for (index, raw) in rawLines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("[") else { continue }
            if let name = projectName(line) {
                project = name
                group = nil
                continue
            }
            guard let first = line.first, "-•·*".contains(first), let project else { continue }
            let indented = raw.first?.isWhitespace == true
            if !indented {
                group = nil
                // 묶어 쓴 꼴(`- 경로` 다음 줄이 들여 쓴 `· `)일 때만 경로 머리로 읽는다.
                // 상태나 일감 번호가 붙은 줄 아래의 `  - 세부` 같은 하위 글머리는 그대로 따로 읽는다
                let head = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let next = rawLines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let next, next.first?.isWhitespace == true,
                   next.trimmingCharacters(in: .whitespaces).hasPrefix("·"),
                   !head.hasSuffix(")"), splitIssue(head).issue == nil {
                    group = head
                    continue
                }
            }
            var body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if indented, let group { body = group + " > " + body }
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
