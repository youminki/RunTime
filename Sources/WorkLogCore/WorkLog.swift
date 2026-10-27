import Foundation

/// 일감 하나의 진행 상태. 보고서에는 `(완료)`, `(60%)`, `(상시)`로 적는다.
/// 같은 끝난 일도 팀마다 `(완료)`나 `(100%)`로 달리 적어서 둘을 나눠 둔다.
public enum WorkStatus: Equatable, Hashable, Codable {
    case done
    case percent(Int)
    /// 몇 %인지 정하지 않은 진행 중. 레드마인 진척률을 0으로 되돌리지 않게 따로 둔다.
    case inProgress
    case ongoing

    /// 괄호 안에 들어가는 말.
    public var label: String {
        switch self {
        case .done: return "완료"
        case .percent(let value): return "\(value)%"
        case .inProgress: return "진행중"
        case .ongoing: return "상시"
        }
    }

    /// 레드마인 진척률. 상시 업무는 진척률을 건드리지 않는다.
    public var doneRatio: Int? {
        switch self {
        case .done: return 100
        case .percent(let value): return value
        case .inProgress, .ongoing: return nil
        }
    }

    public var isFinished: Bool { doneRatio == 100 }

    /// `완료`, `상시`, `진행중`, `60%`, `60`을 읽는다.
    public init?(label raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        switch text {
        case "완료": self = .done
        case "상시": self = .ongoing
        case "진행중", "진행 중": self = .inProgress
        default:
            let digits = text.hasSuffix("%") ? String(text.dropLast()) : text
            guard let value = Int(digits.trimmingCharacters(in: .whitespaces)), (0...100).contains(value) else { return nil }
            self = .percent(value)
        }
    }

    // 사람이 열어 봐도, Claude가 읽어도 바로 알게 JSON에도 보고서와 같은 말로 쓴다
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = WorkStatus(label: text) ?? .inProgress
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

/// 업무 일지의 한 줄.
public struct WorkEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    /// `yyyy-MM-dd`. 보고는 날짜로 묶으므로 시각 대신 날짜 문자열로 둔다.
    public var day: String
    public var project: String
    public var title: String
    public var status: WorkStatus
    /// 레드마인 일감 번호.
    public var issue: Int?
    /// 레드마인 댓글 본문. 비면 제목으로 [작업 내용]을 만든다.
    public var note: String
    /// 레드마인에 올린 때. 올린 뒤 고치면 다시 올릴 목록에 넣으려고 고친 때와 비교한다.
    public var postedAt: Date?
    public var updatedAt: Date
    /// 자동으로 가져온 줄의 출처. `mr:velox/velox-web-portal!14`, `branch:velox/velox-web-portal:feat/x`.
    /// 같은 MR·브랜치를 다시 가져와도 줄이 늘지 않게 이것으로 맞춘다.
    public var source: String?
    /// 커밋으로 만든 댓글. 사용자가 댓글을 고치지 않았을 때만 새 커밋을 더해 다시 쓴다.
    public var autoNote: String?
    /// MR에서 온 줄의 MR 설명 원문. 일감 제목을 나중에 받으면 댓글을 다시 나눌 수 있게 둔다.
    public var mrBody: String?
    /// 레드마인에 남길 작업 시간(시간). 비우면 남기지 않는다.
    public var hours: Double?
    /// 작업 시간을 레드마인에 남겼는지. 댓글을 다시 보내도 시간은 두 번 남기지 않는다.
    public var timeLogged: Bool

    public init(id: UUID = UUID(), day: String, project: String, title: String, status: WorkStatus = .done,
                issue: Int? = nil, note: String = "", postedAt: Date? = nil, updatedAt: Date = Date(),
                source: String? = nil, autoNote: String? = nil, hours: Double? = nil, timeLogged: Bool = false,
                mrBody: String? = nil) {
        self.mrBody = mrBody
        self.id = id
        self.day = day
        self.project = project
        self.title = title
        self.status = status
        self.issue = issue
        self.note = note
        self.postedAt = postedAt
        self.updatedAt = updatedAt
        self.source = source
        self.autoNote = autoNote
        self.hours = hours
        self.timeLogged = timeLogged
    }

    /// 일감 번호가 있고, 아직 올리지 않았거나 올린 뒤 고쳤다.
    /// 댓글은 보냈지만 정한 작업 시간을 아직 남기지 않았다 (시간만 실패했거나 나중에 시간을 넣었을 때).
    public var needsTime: Bool {
        issue != nil && !timeLogged && (hours ?? 0) > 0
    }

    public var needsRedmine: Bool {
        guard issue != nil else { return false }
        guard let postedAt else { return true }
        return updatedAt > postedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        day = try c.decode(String.self, forKey: .day)
        project = try c.decode(String.self, forKey: .project)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decodeIfPresent(WorkStatus.self, forKey: .status) ?? .done
        issue = try c.decodeIfPresent(Int.self, forKey: .issue)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        postedAt = try c.decodeIfPresent(Date.self, forKey: .postedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        autoNote = try c.decodeIfPresent(String.self, forKey: .autoNote)
        mrBody = try c.decodeIfPresent(String.self, forKey: .mrBody)
        hours = try c.decodeIfPresent(Double.self, forKey: .hours)
        timeLogged = try c.decodeIfPresent(Bool.self, forKey: .timeLogged) ?? false
    }
}

/// 정한 요일마다 넣는 일.
public struct RecurringWork: Codable, Equatable, Identifiable {
    public var id: UUID
    public var project: String
    public var title: String
    public var status: WorkStatus
    public var issue: Int?
    /// 그레고리력 요일 (1 일요일 … 7 토요일).
    public var weekdays: Set<Int>

    public init(id: UUID = UUID(), project: String, title: String, status: WorkStatus = .ongoing,
                issue: Int? = nil, weekdays: Set<Int>) {
        self.id = id
        self.project = project
        self.title = title
        self.status = status
        self.issue = issue
        self.weekdays = weekdays
    }
}

/// 업무 일지 파일 전체. 프로젝트 순서가 보고서 번호 순서다.
public struct WorkLog: Codable, Equatable {
    public var projects: [String]
    public var entries: [WorkEntry]
    /// GitLab 묶음 이름 → 보고서에 쓰는 프로젝트 이름. 예: `velox` → `VeloX`. 프로젝트 이름을 바꾸면 따라 바뀐다.
    public var aliases: [String: String]
    /// 지운 자동 줄(`날짜|출처`). 다음에 가져올 때 되살리지 않는다.
    public var dismissed: Set<String>
    /// 정한 요일마다 저절로 넣는 일 (주간 회의 같은 상시 업무).
    public var recurring: [RecurringWork]
    /// 레드마인 일감 장부 (번호 문자열 → 정보). JSON에서 번호를 키로 쓰려고 문자열로 둔다.
    public var issues: [String: IssueInfo]
    /// 레드마인 프로젝트 이름 → 보고서 프로젝트 이름. 예: `목포 데이터밸류 체인 구축` → `uxhub`.
    public var redmineProjects: [String: String]
    /// 목록에서 숨긴 일지 프로젝트와 레드마인 프로젝트. 보는 것만 가리고 기록과 보고서에는 그대로 남는다.
    public var hiddenProjects: Set<String>
    public var hiddenRedmineProjects: Set<String>
    /// 앱이 레드마인에 보낸 기록 (최근 것부터 쌓고 오래된 것은 버린다). 되돌리기에 쓴다.
    public var sent: [RedmineSent]

    public init(projects: [String] = [], entries: [WorkEntry] = [], aliases: [String: String] = [:],
                dismissed: Set<String> = [], recurring: [RecurringWork] = []) {
        self.projects = projects
        self.entries = entries
        self.aliases = aliases
        self.dismissed = dismissed
        self.recurring = recurring
        self.issues = [:]
        self.redmineProjects = [:]
        self.hiddenProjects = []
        self.hiddenRedmineProjects = []
        self.sent = []
    }

    public func issue(_ id: Int?) -> IssueInfo? {
        id.flatMap { issues[String($0)] }
    }

    /// 레드마인 일감을 적을 때 쓸 보고서 프로젝트. 정해 둔 이름, 같은 레드마인 프로젝트 일감을 적은 일지 프로젝트, 레드마인 이름 순.
    public func reportProject(for info: IssueInfo) -> String {
        if let name = redmineProjects[info.project], !name.isEmpty { return name }
        let sameProject = Set(issues.values.filter { $0.project == info.project }.map(\.id))
        if let used = entries.last(where: { $0.issue.map(sameProject.contains) == true })?.project { return used }
        return info.project
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
        entries = try c.decodeIfPresent([WorkEntry].self, forKey: .entries) ?? []
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        dismissed = try c.decodeIfPresent(Set<String>.self, forKey: .dismissed) ?? []
        recurring = try c.decodeIfPresent([RecurringWork].self, forKey: .recurring) ?? []
        issues = try c.decodeIfPresent([String: IssueInfo].self, forKey: .issues) ?? [:]
        redmineProjects = try c.decodeIfPresent([String: String].self, forKey: .redmineProjects) ?? [:]
        hiddenProjects = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenProjects) ?? []
        hiddenRedmineProjects = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenRedmineProjects) ?? []
        sent = try c.decodeIfPresent([RedmineSent].self, forKey: .sent) ?? []
    }

    /// 그날 요일에 맞는 고정 업무를 넣는다. 이미 있거나 그날 지운 것은 건너뛴다.
    @discardableResult
    public mutating func applyRecurring(on day: String, now: Date = Date()) -> Int {
        guard let date = WorkDay.date(day) else { return 0 }
        let weekday = WorkDay.calendar.component(.weekday, from: date)
        var added = 0
        for item in recurring where item.weekdays.contains(weekday) {
            let source = "recurring:\(item.id.uuidString)"
            // 고정 업무를 지웠다 다시 만들면 id가 바뀌므로, 같은 프로젝트에 같은 제목 줄이 그날 있으면(손으로 적은 것 포함) 넣지 않는다
            let title = Self.titleKey(item.title)
            guard !dismissed.contains(day + "|" + source),
                  !entries.contains(where: { $0.day == day && ($0.source == source
                      || ($0.project == item.project && Self.titleKey($0.title) == title)) }) else { continue }
            register(project: item.project)
            entries.append(WorkEntry(day: day, project: item.project, title: item.title, status: item.status,
                                     issue: item.issue, updatedAt: now, source: source))
            added += 1
        }
        return added
    }

    /// 줄을 지운다. 자동으로 가져온 줄이면 다시 가져오지 않게 적어 둔다.
    public mutating func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let source = entries[index].source { dismissed.insert(entries[index].day + "|" + source) }
        entries.remove(at: index)
    }

    public func entries(on day: String) -> [WorkEntry] {
        entries.filter { $0.day == day }
    }

    public func entries(in days: ClosedRange<String>) -> [WorkEntry] {
        entries.filter { days.contains($0.day) }
    }

    /// 기록이 있는 날, 최근부터.
    public var days: [String] {
        Array(Set(entries.map(\.day))).sorted(by: >)
    }

    /// 등록된 순서를 먼저 두고, 목록에 없는 프로젝트는 처음 나온 순서로 뒤에 붙인다.
    public func orderedProjects(of entries: [WorkEntry]) -> [String] {
        let used = Set(entries.map(\.project))
        var order = projects.filter(used.contains)
        for entry in entries where !order.contains(entry.project) { order.append(entry.project) }
        return order
    }

    /// 등록한 프로젝트 전부. 아직 줄이 없는 새 프로젝트도 들어가고, 목록에 없이 줄에만 있는 프로젝트는 뒤에 붙는다.
    public var allProjects: [String] {
        var order = projects
        for entry in entries where !order.contains(entry.project) { order.append(entry.project) }
        return order
    }

    /// 숨기지 않은 프로젝트 (왼쪽 목록, 적을 프로젝트 고르기에 쓴다).
    public var visibleProjects: [String] {
        allProjects.filter { !hiddenProjects.contains($0) }
    }

    /// 내용·댓글·프로젝트·일감 번호에서 찾는다. 낱말마다 모두 맞아야 하고, `ㄷㅇㅌ`처럼 초성만 쳐도 된다. 최근 날부터.
    public func search(_ query: String) -> [WorkEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let text = [entry.title, entry.note, entry.project, entry.issue.map { "#\($0)" } ?? ""]
                .joined(separator: " ").lowercased()
            let initials = Self.initials(text)
            return words.allSatisfy { word in
                text.contains(word) || (Self.isInitialsOnly(word) && initials.contains(word))
            }
        }
        .sorted { $0.day > $1.day }
    }

    private static let choseong: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")

    /// 한글 음절을 초성으로 바꾼다. 다른 글자는 그대로 둔다.
    static func initials(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            guard (0xAC00...0xD7A3).contains(scalar.value) else { return Character(scalar) }
            return choseong[Int(scalar.value - 0xAC00) / 588]
        })
    }

    static func isInitialsOnly(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { choseong.contains($0) }
    }

    public mutating func register(project: String) {
        let name = project.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !projects.contains(name) else { return }
        projects.append(name)
    }

    /// 앞선 날에서 이어 쓸 줄: 끝나지 않았고, 그날 같은 제목이 없고, 고정 업무가 아닌 것.
    /// 고정 업무는 정한 요일에만 들어가야 해서 옮기지 않는다.
    public func carryCandidates(from source: String, to target: String) -> [WorkEntry] {
        let today = entries(on: target)
        let existing = Set(today.map { $0.project + "\u{1F}" + $0.title })
        // 오늘 가져오기가 같은 브랜치 줄을 이미 만들었으면(제목은 오늘 첫 커밋이라 다르다) 그 줄을 다시 옮기지 않는다.
        // 오늘 지운 줄도 되살리지 않는다
        let sources = Set(today.compactMap(\.source))
        return entries(on: source).filter {
            !$0.status.isFinished && $0.source?.hasPrefix("recurring:") != true
                && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                && !existing.contains($0.project + "\u{1F}" + $0.title)
                && !($0.source.map { sources.contains($0) || dismissed.contains(target + "|" + $0) } ?? false)
        }
    }

    /// 같은 제목인지 볼 때 쓰는 꼴 (대소문자·빈칸 무시).
    static func titleKey(_ title: String) -> String { title.lowercased().filter { !$0.isWhitespace } }

    /// 앞선 날에서 끝나지 않은 일을 이어 쓴다.
    @discardableResult
    public mutating func carryOver(from source: String, to target: String, now: Date = Date()) -> Int {
        let carried = carryCandidates(from: source, to: target)
        entries += carried.map {
            // 이미 보낸 댓글을 옮기면 같은 댓글이 다시 보낼 목록에 오른다. 보내지 않은 댓글만 옮긴다
            let posted = $0.postedAt != nil
            // 출처도 옮겨야 그 브랜치를 다시 가져오거나 머지됐을 때 이 줄을 찾는다
            return WorkEntry(day: target, project: $0.project, title: $0.title, status: $0.status,
                             issue: $0.issue, note: posted ? "" : $0.note, updatedAt: now, source: $0.source,
                             autoNote: posted ? nil : $0.autoNote)
        }
        return carried.count
    }

    /// 줄은 id로 맞춘다. 이 창에서 고치거나 더한 줄은 내 것을, 지운 줄은 지우고, 나머지는 파일 것을 쓴다.
    public static func merge(mine: WorkLog, base: WorkLog, disk: WorkLog) -> WorkLog {
        let baseByID = Dictionary(base.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mineIDs = Set(mine.entries.map(\.id))
        let deleted = Set(base.entries.map(\.id)).subtracting(mineIDs)
        let changed = Dictionary(mine.entries.filter { baseByID[$0.id] != $0 }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var merged = disk
        merged.entries = disk.entries.filter { !deleted.contains($0.id) }.map { changed[$0.id] ?? $0 }
        let onDisk = Set(disk.entries.map(\.id))
        merged.entries += mine.entries.filter { changed[$0.id] != nil && !onDisk.contains($0.id) && baseByID[$0.id] == nil }
        merged.dismissed.formUnion(mine.dismissed)
        if mine.recurring != base.recurring { merged.recurring = mine.recurring }
        // 장부는 나중에 받은 것이 맞다. 이 창에서 받은 것을 파일 것 위에 얹는다
        merged.issues.merge(mine.issues) { disk, mine in mine.fetchedAt >= disk.fetchedAt ? mine : disk }
        // 지운 이름도 되살아나지 않게 바뀌었으면 통째로 내 것을 쓴다
        if mine.redmineProjects != base.redmineProjects { merged.redmineProjects = mine.redmineProjects }
        if mine.hiddenProjects != base.hiddenProjects { merged.hiddenProjects = mine.hiddenProjects }
        if mine.hiddenRedmineProjects != base.hiddenRedmineProjects { merged.hiddenRedmineProjects = mine.hiddenRedmineProjects }
        // 보낸 기록은 번호로 합치고, 이 창에서 고친 것(되돌림)을 얹는다
        if mine.sent != base.sent {
            let baseSent = Dictionary(base.sent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var byID = Dictionary(merged.sent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for record in mine.sent where baseSent[record.id] != record { byID[record.id] = record }
            merged.sent = byID.values.sorted { $0.sentAt > $1.sentAt }
        }
        if mine.aliases != base.aliases { merged.aliases.merge(mine.aliases) { _, mine in mine } }
        if mine.projects != base.projects {
            merged.projects = mine.projects + disk.projects.filter { !mine.projects.contains($0) }
        }
        return merged
    }

    /// `target` 앞에서 기록이 있는 가장 가까운 날.
    public func previousDay(before target: String) -> String? {
        days.first { $0 < target }
    }
}

/// 날짜 문자열 계산. 사용자 달력 설정(불기·일본력 등)과 상관없이 같은 날을 같은 문자열로 만든다.
public enum WorkDay {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2   // 주간 보고는 월요일부터
        return calendar
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 보내는 큐와 메인 스레드가 함께 부르므로 시간대를 바꾸고 쓰는 동안 잠근다.
    private static let formatterLock = NSLock()

    public static func key(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    public static func date(_ key: String) -> Date? {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        formatter.timeZone = .current
        return formatter.date(from: key)
    }

    public static func today() -> String { key(Date()) }

    /// `yyyy-MM-dd`로 정확히 쓴 실제 날짜만. `2026-1-5`나 `2026-02-30`처럼 너그럽게 읽히는 글은 거른다.
    public static func isValid(_ key: String) -> Bool {
        date(key).map(self.key) == key
    }

    public static func adding(_ days: Int, to key: String) -> String {
        guard let date = date(key), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return key }
        return self.key(moved)
    }

    public static func addingMonths(_ months: Int, to key: String) -> String {
        guard let date = date(key), let moved = calendar.date(byAdding: .month, value: months, to: date) else { return key }
        return self.key(moved)
    }

    /// 그 날이 든 달의 1일부터 말일까지.
    public static func month(of key: String) -> ClosedRange<String> {
        guard let date = date(key), let interval = calendar.dateInterval(of: .month, for: date) else { return key...key }
        let start = self.key(interval.start)
        return start...self.key(interval.end.addingTimeInterval(-1))
    }

    /// 달력에 그릴 날들. 그 달 1일이 든 주의 월요일부터 말일이 든 주의 일요일까지 (4~6주).
    public static func calendarDays(of key: String) -> [String] {
        let month = month(of: key)
        let first = week(of: month.lowerBound).lowerBound
        let last = week(of: month.upperBound).upperBound
        var days: [String] = []
        var day = first
        while day <= last && days.count < 42 {
            days.append(day)
            day = adding(1, to: day)
        }
        return days
    }

    /// 그 날이 든 주의 월요일부터 일요일까지.
    public static func week(of key: String) -> ClosedRange<String> {
        guard let date = date(key), let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return key...key }
        let start = self.key(interval.start)
        return start...adding(6, to: start)
    }
}
