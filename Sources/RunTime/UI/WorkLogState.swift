import SwiftUI
import WorkLogCore

/// 업무 일지 창 상태. `@State` 대신 쓴다 (HoverFlag 참고).
final class WorkLogPage: ObservableObject {
    enum Mode: String, CaseIterable { case day = "하루", week = "주간", month = "월간", project = "프로젝트", issues = "내 일감" }
    enum Preview { case report, redmine }

    @Published var mode = Mode.day
    /// 하루 보고서: 퇴근 때 올리는 진행 사항, 출근 때 올리는 진행 예정 사항. 오전에 열면 예정부터 보인다.
    enum DayReport: String, CaseIterable { case plan = "진행 예정", progress = "진행 사항" }
    @Published var dayReport: DayReport = WorkLogPage.defaultReport(for: WorkDay.today())
    /// 날짜별로 고쳐 쓴 진행 예정 사항과, 고칠 때 일지에서 만든 글. 일지가 바뀌면 알아채려고 함께 둔다.
    @Published var planEdits: [String: (text: String, base: String)] = [:]
    /// 고른 날. 바꾸면 왼쪽 달력도 그 달로 간다.
    @Published var day = WorkDay.today() {
        didSet {
            calendarMonth = WorkDay.month(of: day).lowerBound
            if day != oldValue { dayReport = Self.defaultReport(for: day) }
        }
    }

    /// 오늘 오전이면 진행 예정, 그 밖에는 진행 사항 (지난날에 올릴 계획은 없다).
    static func defaultReport(for day: String) -> DayReport {
        day == WorkDay.today() && Calendar.current.component(.hour, from: Date()) < 12 ? .plan : .progress
    }

    /// 자정을 넘겨 창을 켜 둔 채면 어제 보던 화면에 머물러 새로 적는 줄이 어제로 들어간다. 오늘로 옮긴다
    private lazy var dayChange: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
        guard let self else { return }
        let yesterday = WorkDay.adding(-1, to: WorkDay.today())
        if self.day == yesterday { self.resetToToday() }
    }
    /// 왼쪽 달력에 보이는 달의 1일. 달력 화살표로는 고른 날을 두고 달력만 넘긴다.
    @Published var calendarMonth = WorkDay.month(of: WorkDay.today()).lowerBound
    @Published var search = ""
    /// 달력에서 이 프로젝트만 보인다. nil이면 모두.
    @Published var calendarProject: String?
    /// 사이드바에서 끌고 있는 프로젝트.
    @Published var draggingProject: String?
    /// 끌어서 정한 칸 너비. nil이면 창 너비에 맞춘 자동 너비를 쓴다.
    @Published var sidebarWidth: CGFloat? = WorkLogPage.stored("workLog.sidebarWidth") {
        didSet { WorkLogPage.store(sidebarWidth, "workLog.sidebarWidth") }
    }
    @Published var previewWidth: CGFloat? = WorkLogPage.stored("workLog.previewWidth") {
        didSet { WorkLogPage.store(previewWidth, "workLog.previewWidth") }
    }
    @Published var calendarDetailWidth: CGFloat? = WorkLogPage.stored("calendar.detailWidth") {
        didSet { WorkLogPage.store(calendarDetailWidth, "calendar.detailWidth") }
    }

    private static func stored(_ key: String) -> CGFloat? {
        (UserDefaults.standard.object(forKey: key) as? Double).map { CGFloat($0) }
    }

    private static func store(_ value: CGFloat?, _ key: String) {
        if let value { UserDefaults.standard.set(Double(value), forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
    @Published var project: String?
    @Published var preview = Preview.report
    /// 레드마인 칸에서 이번에 보내지 않으려고 체크를 푼 일감. 새로 생긴 일감은 골라진 채로 나온다.
    @Published var redmineSkipped: Set<Int> = []
    /// MR 수정 전·후 화면을 붙이지 않고 보낼 일감.
    @Published var redmineNoScreens: Set<Int> = []
    /// 수정 전·후 화면을 모두 펼쳐 본 일감 (화면이 많으면 앞 몇 개만 보인다).
    @Published var expandedScreens: Set<Int> = []
    /// 미리보기에서 고른 화면과 다른 일감으로 옮긴 화면. 보낼 때 그대로 따른다.
    @Published var screenPicks = MRScreens.Picks()
    /// 댓글은 빼고 진척률·칸만 보낼 일감. 같은 댓글이 이미 있으면 저절로 들어간다.
    @Published var redmineNoNote: Set<Int> = []
    /// 진척률 고르기 창을 띄운 일감.
    @Published var ratioEditing: Int?
    /// 이미 올라간 것 같아 체크를 한 번 풀어 준 일감 (다시 고른 것을 또 풀지 않게).
    @Published var hintApplied: Set<Int> = []
    /// 레드마인 칸에서 댓글을 다 펼쳐 본 일감과, 댓글을 고치려고 연 일감.
    @Published var expandedNotes: Set<Int> = []
    @Published var noteEditing: Int?
    /// 보내기 전에 확인 창에 띄운 일감 (확인하면 이것을 다 보낸다). 진척률이 내려가는 일감도 이 창에서 알린다.
    @Published var confirmingSend: [Int]?
    /// 레드마인 칸에서 보낸 기록을 보는 중인지와, 되돌릴지 묻는 중인 기록.
    @Published var redmineHistory = false
    /// 카드에서 직접 고른 상태·날짜·담당자 (일감 번호 → 고른 칸). 보내면 비운다.
    @Published var issueEdits: [Int: WorkReport.IssueEdit] = [:]
    @Published var fieldEditing: Int?
    /// 내 일감에서 바로 고치는 일감과 고르는 중인 칸.
    @Published var boardEditing: Int?
    @Published var boardDraft = WorkReport.IssueEdit()
    /// 내 일감 고치기 창에서 저장 전에 바뀔 칸을 한 번 더 보여 주는 중인지.
    @Published var boardConfirming = false
    @Published var confirmingUndo: RedmineSent?
    @Published var editing: UUID?
    @Published var statusPicking: UUID?
    @Published var drafts: [String: String] = [:]
    /// 기록은 없지만 적으려고 열어 둔 프로젝트 묶음.
    @Published var openProjects: Set<String> = []
    @Published var addingProject = false
    /// 왼쪽 목록 아래 숨긴 프로젝트 묶음을 펼쳤는지.
    @Published var showsHidden = false
    @Published var newProject = ""
    @Published var renaming: String?
    /// 기간을 정하는 창을 띄운 프로젝트.
    @Published var periodEditing: String?
    @Published var renameText = ""
    @Published var importing = false
    @Published var importText = ""
    /// 하루 보기에서 글을 고치는 줄과 그 줄이 있던 경로 묶음 ("" = 묶음 없음).
    @Published var pinnedPaths: [UUID: String] = [:]
    /// 연동 설정을 열어 달라는 신호. 앱 창이 받아 설정 화면의 업무 일지 칸으로 옮기고 다시 끈다.
    @Published var showsSettings = false
    /// 저장하기 전 API 키·웹훅. 저장하면 비운다.
    @Published var keyDraft = ""
    /// 고정 업무 새로 만들기 칸.
    @Published var recurringProject = ""
    @Published var recurringTitle = ""
    @Published var recurringDays: Set<Int> = [2]
    @Published var confirmingTeams = false
    @Published var teamsTestResult: String?
    @Published var teamsTestFailed = false
    /// 접어 둔 묶음 (프로젝트 이름, 날짜).
    @Published var collapsed: Set<String> = []
    /// 내 일감 보기: 찾는 말과 거르기.
    @Published var issueQuery = ""
    @Published var issueFilter = IssueFilter.all
    @Published var renamingRedmine: String?
    @Published var redmineRenameText = ""

    enum IssueFilter: String, CaseIterable {
        case all = "전체", working = "진행 중", due = "기한 임박", logged = "오늘 적은"
    }
    /// 설정 창에서 고른 칸.
    @Published var settingsSection = SettingsSection.gitlab

    enum SettingsSection: String, CaseIterable {
        case gitlab = "GitLab", redmine = "레드마인", teams = "팀즈", recurring = "고정 업무", shortcuts = "단축키·알림"

        var icon: String {
            switch self {
            case .gitlab: return "arrow.triangle.merge"
            case .redmine: return "paperplane"
            case .teams: return "bubble.left.and.bubble.right"
            case .recurring: return "repeat"
            case .shortcuts: return "keyboard"
            }
        }
    }

    /// 프로젝트 이름을 바꾸면 창에 열어 둔 묶음·쓰던 글·접힘도 새 이름으로 옮긴다 (기록 없는 묶음이 사라지지 않게).
    func renamed(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        if openProjects.remove(old) != nil { openProjects.insert(name) }
        if let draft = drafts.removeValue(forKey: old) { drafts[name] = draft }
        if collapsed.remove("day:" + old) != nil { collapsed.insert("day:" + name) }
        if project == old { project = name }
    }

    /// 프로젝트 보기에서 고른 프로젝트. 없거나 사라졌으면 숨기지 않은 첫 프로젝트.
    func selectedProject(in log: WorkLog) -> String? {
        if let project, log.allProjects.contains(project) { return project }
        return log.visibleProjects.first ?? log.allProjects.first
    }

    func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    /// "모두 접기"를 누른 뒤면 true. 묶음마다 `collapsed`는 이 기준에서 거꾸로 둔 것이다.
    @Published var foldAll = false

    func isCollapsed(_ key: String) -> Bool { foldAll != collapsed.contains(key) }

    /// 기준과 상관없이 이 묶음을 편다 (새로 연 카드 등).
    func expand(_ key: String) {
        if foldAll { collapsed.insert(key) } else { collapsed.remove(key) }
    }

    func setAllCollapsed(_ folded: Bool) {
        foldAll = folded
        collapsed = []
    }
    @Published var toast: String?
    /// 업무 일지를 열며 GitLab·레드마인을 마지막으로 받은 때.
    var lastAutoSync: Date?
    private var toastWork: DispatchWorkItem?

    /// 지금 보기 단위로 앞뒤로 간다 (하루·주·달).
    func step(_ direction: Int) {
        switch mode {
        case .week: day = WorkDay.adding(7 * direction, to: day)
        case .month: day = WorkDay.addingMonths(direction, to: WorkDay.month(of: day).lowerBound)
        default: day = WorkDay.adding(direction, to: day)
        }
    }

    func flash(_ message: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    /// 창을 다시 열면 오늘로 돌아온다. 자정을 넘겨 켜 둔 창이 어제에 머물지 않게.
    func resetToToday() {
        _ = dayChange
        day = WorkDay.today()
        dayReport = Self.defaultReport(for: day)
        editing = nil
        statusPicking = nil
    }
}

// MARK: - 글·날짜

enum WorkLogFormat {
    static let quickStatuses: [WorkStatus] = [.done, .percent(100), .percent(80), .percent(50), .percent(30), .inProgress, .ongoing]

    static func color(_ project: String) -> Color { WL.projectColor(project) }

    static func same(_ a: String, _ b: String) -> Bool {
        a.lowercased().filter { !$0.isWhitespace } == b.lowercased().filter { !$0.isWhitespace }
    }

    /// 새 줄 끝의 `(60%)`, `(상시)`를 상태로 읽는다.
    static func splitStatus(_ text: String) -> (title: String, status: WorkStatus) {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "("),
              let status = WorkStatus(label: String(text[text.index(after: open)..<text.index(before: text.endIndex)]))
        else { return (text, .done) }
        return (String(text[..<open]).trimmingCharacters(in: .whitespaces), status)
    }

    /// `화면 > 기능 > 할 일`을 앞 경로와 마지막 이름으로 나눈다. 읽기 전용 줄에서 이름만 크게 보이고 경로는 아래 작은 글로 둔다.
    static func breadcrumb(_ title: String) -> (path: String?, leaf: String) {
        guard let range = title.range(of: " > ", options: .backwards) else { return (nil, title) }
        let leaf = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let path = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return leaf.isEmpty || path.isEmpty ? (nil, title) : (path, leaf)
    }

    /// 같은 메뉴 경로를 쓰는 줄 묶음. 둘 이상이 같은 경로면 경로를 묶음 제목으로 올리고(`path`), 혼자면 경로 없이 둔다.
    struct PathGroup: Identifiable {
        let id: String
        let path: String?
        let entries: [WorkEntry]
    }

    /// 보고서의 "같은 메뉴는 묶어 쓰기"와 같은 규칙으로 화면 줄도 묶는다. 묶음은 첫 줄이 있던 자리에 둔다.
    /// `pinned`는 글을 고치고 있는 줄의 묶음 경로("" = 묶음 없음). 치는 도중 다른 묶음으로 옮겨 가 초점이 풀리지 않게 고정한다.
    static func pathGroups(_ entries: [WorkEntry], pinned: [UUID: String] = [:]) -> [PathGroup] {
        func pathOf(_ entry: WorkEntry) -> String? {
            if let fixed = pinned[entry.id] { return fixed.isEmpty ? nil : fixed }
            return breadcrumb(entry.title).path
        }
        var counts: [String: Int] = [:]
        for entry in entries { if let path = pathOf(entry) { counts[path, default: 0] += 1 } }
        // 고친 줄이 묶음을 떠나 혼자 남은 경로도 고치는 동안은 묶음 제목을 지킨다
        // 지운 줄의 고정은 세지 않는다 (고치다 지우면 초점 해제 소식이 오지 않을 수 있다)
        let present = Set(entries.map(\.id))
        for (id, path) in pinned where !path.isEmpty && present.contains(id) { counts[path, default: 0] += 1 }
        var groups: [PathGroup] = []
        var index: [String: Int] = [:]
        for entry in entries {
            guard let path = pathOf(entry), counts[path, default: 0] > 1 else {
                groups.append(PathGroup(id: entry.id.uuidString, path: nil, entries: [entry]))
                continue
            }
            if let at = index[path] {
                groups[at] = PathGroup(id: groups[at].id, path: path, entries: groups[at].entries + [entry])
            } else {
                index[path] = groups.count
                groups.append(PathGroup(id: "path:" + path, path: path, entries: [entry]))
            }
        }
        return groups
    }

    /// 레드마인에서 함께 바뀔 칸을 짧은 말로: `할일 → 완료`, `시작 10.21`, `담당 홍길동`.
    static func fieldChanges(_ fields: WorkReport.IssueFields, current: IssueInfo?) -> [String] {
        var parts: [String] = []
        if let status = fields.status { parts.append("\(current?.status ?? "") → \(status.name)") }
        if let start = fields.startDate { parts.append(start.isEmpty ? "시작일 비움" : "시작 \(WorkReport.shortDate(start))") }
        if let due = fields.dueDate { parts.append(due.isEmpty ? "기한 비움" : "기한 \(WorkReport.shortDate(due))") }
        if let assignee = fields.assignee { parts.append("담당 \(assignee.name)") }
        return parts
    }

    static func template(for entry: WorkEntry) -> String {
        "[작업 내용]\n- \(entry.title)\n\n[연동 API]\n- \n\n[비고]\n- "
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = format
        return f
    }

    private static let dayFormatter = formatter("M월 d일 (E)")
    private static let longDayFormatter = formatter("M월 d일 EEEE")
    private static let weekdayFormatter = formatter("E")
    private static let numberFormatter = formatter("d")
    private static let timeFormatter = formatter("M/d HH:mm")
    private static let clockFormatter = formatter("HH:mm")

    static func dayTitle(_ key: String) -> String {
        WorkDay.date(key).map { dayFormatter.string(from: $0) } ?? key
    }

    /// 머리 제목: `10월 20일 화요일`
    static func longDay(_ key: String) -> String {
        WorkDay.date(key).map { longDayFormatter.string(from: $0) } ?? key
    }

    static func weekday(_ key: String) -> String {
        WorkDay.date(key).map { weekdayFormatter.string(from: $0) } ?? ""
    }

    static func dayNumber(_ key: String) -> String {
        WorkDay.date(key).map { numberFormatter.string(from: $0) } ?? ""
    }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// 오늘이면 `14:20`, 아니면 `10/19 14:20`.
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? clockFormatter.string(from: date) : timeFormatter.string(from: date)
    }

    /// `2026년 10월`
    static func monthTitle(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]) else { return key }
        return "\(parts[0])년 \(month)월"
    }

    /// `10.20 (화)`
    static func shortDay(_ key: String) -> String {
        "\(WorkReport.shortDate(key)) (\(weekday(key)))"
    }

    /// `10월 19일 ~ 25일`, 달이 바뀌면 `9월 29일 ~ 10월 5일`.
    static func weekTitle(_ key: String) -> String {
        let week = WorkDay.week(of: key)
        let start = dayTitle(week.lowerBound).components(separatedBy: " (").first ?? ""
        let endParts = (dayTitle(week.upperBound).components(separatedBy: " (").first ?? "").components(separatedBy: " ")
        let sameMonth = week.lowerBound.prefix(7) == week.upperBound.prefix(7)
        return "\(start) ~ \(sameMonth ? endParts.last ?? "" : endParts.joined(separator: " "))"
    }

    /// 요일 이름 (그레고리력 1 일요일 … 7 토요일), 월요일부터.
    static let weekdays: [(number: Int, name: String)] = [(2, "월"), (3, "화"), (4, "수"), (5, "목"), (6, "금"), (7, "토"), (1, "일")]

    /// 달력 날짜 색: 공휴일·일요일은 빨강, 토요일은 파랑 (macOS 달력처럼). 평일은 nil.
    static func dayTint(_ key: String) -> Color? {
        if KoreanHolidays.name(on: key) != nil { return Palette.red }
        guard let date = WorkDay.date(key) else { return nil }
        switch Calendar(identifier: .gregorian).component(.weekday, from: date) {
        case 1: return Palette.red
        case 7: return Palette.blue
        default: return nil
        }
    }

    /// 요일 머리 색 (`weekdays`의 number: 1 일요일, 7 토요일).
    static func weekdayTint(_ number: Int) -> Color? {
        number == 1 ? Palette.red : number == 7 ? Palette.blue : nil
    }
}
