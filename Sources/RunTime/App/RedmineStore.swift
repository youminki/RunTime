import Foundation
import WorkLogCore

/// 앱 안 레드마인 화면의 데이터. 목록과 상세가 같은 일감 값을 보아, 칸을 고치면 두 곳이 함께 바뀐다
/// (웹처럼 뒤로 가서 새로고침할 일이 없다). 고치는 즉시 화면 값을 바꾸고 보내며, 실패하면 그 칸만 되돌린다.
/// 메인 스레드에서만 쓴다.
final class RedmineStore: ObservableObject {
    static let shared = RedmineStore()

    /// 왼쪽에서 고르는 범위: 내 일감, 내가 등록한 일감, 프로젝트 전체, 저장한 질의.
    enum Scope: Hashable {
        case mine, authored
        case project(Redmine.Project)
        case query(Redmine.Query)

        var title: String {
            switch self {
            case .mine: return "내 일감"
            case .authored: return "내가 등록한 일감"
            case .project(let project): return project.name
            case .query(let query): return query.name
            }
        }
    }

    /// 열림·닫힘 상태로 거르기. 저장한 질의는 질의 조건을 그대로 쓴다.
    enum StatusFilter: String, CaseIterable {
        case open = "열린 일감", closed = "닫힌 일감", all = "모든 일감"
        var parameter: String { self == .open ? "open" : self == .closed ? "closed" : "*" }
    }

    /// 받은 목록을 한 번 더 걸러 보는 빠른 거르기 (다시 받지 않는다).
    enum Quick: String, CaseIterable {
        case all = "전체", stabilization = "안정화", qa = "QA·결함", dueSoon = "기한 임박", unassigned = "담당 없음"
    }

    /// 목록 칸. 머리를 누르면 그 칸으로 정렬한다.
    enum Column: String, CaseIterable {
        case id = "#", tracker = "트래커", status = "상태", priority = "우선순위", subject = "제목",
             assignee = "담당자", ratio = "진척률", due = "기한", updated = "고친 날"
    }

    @Published var scope: Scope = .mine { didSet { if scope != oldValue { reset() } } }
    @Published var statusFilter: StatusFilter = .open { didSet { if statusFilter != oldValue { reset() } } }
    @Published var quick: Quick = .all
    @Published var sort: Column = .updated
    @Published var ascending = false
    /// 상위·하위 일감을 들여 써서 보인다.
    @Published var treeMode = false
    @Published var collapsed: Set<Int> = []

    var filter: Redmine.Filter {
        switch scope {
        case .mine: return Redmine.Filter(assignedToMe: true, status: statusFilter.parameter)
        case .authored: return Redmine.Filter(authoredByMe: true, status: statusFilter.parameter)
        case .project(let project): return Redmine.Filter(projectID: project.id, status: statusFilter.parameter)
        case .query(let query): return Redmine.Filter(queryID: query.id, projectID: query.projectId)
        }
    }

    /// 범위나 상태 거르기가 바뀌면 받는 동안 옛 목록이 새 제목 아래 보이지 않게 비우고 다시 받는다.
    private func reset() {
        issues = []
        total = 0
        collapsed = []
        load()
    }

    @Published var search = ""
    @Published private(set) var issues: [Redmine.Issue] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var selected: Int? { didSet { if let selected, selected != oldValue { loadDetail(selected) } } }
    /// 상세까지 받은 일감. 목록에서 고치면 여기도 함께 바뀐다.
    @Published private(set) var details: [Int: Redmine.Issue] = [:]
    @Published private(set) var loadingDetail: Int?
    /// 상세를 받지 못한 일감과 까닭 (상세 자리에 다시 받기와 함께 보인다).
    @Published private(set) var detailErrors: [Int: String] = [:]
    /// 보내는 중인 일감 (그 일감의 칸을 잠깐 막는다).
    @Published private(set) var saving: Set<Int> = []

    @Published private(set) var projects: [Redmine.Project] = []
    @Published private(set) var queries: [Redmine.Query] = []
    @Published private(set) var statuses: [Redmine.Status] = []
    @Published private(set) var trackers: [Redmine.Ref] = []
    @Published private(set) var priorities: [Redmine.Ref] = []
    /// 시간 기록에 고르는 활동.
    @Published private(set) var activities: [RedmineAPI.Activity] = []
    /// 내 계정 ("나에게" 담당자로 둘 때).
    @Published private(set) var me: Redmine.Ref?
    /// 프로젝트별 담당자로 고를 수 있는 사람.
    @Published private(set) var people: [Int: [Redmine.Ref]] = [:]
    @Published var flash: String?
    /// 새 일감 창이 열려 있는지.
    @Published var creating = false

    private var settings: WorkLogSettings { .shared }
    private var started = false
    /// 목록 요청이 겹치면 늦게 온 옛 응답이 새 보기를 덮지 않게 한다.
    private var listToken = 0

    var ready: Bool { settings.redmineReady }

    private var credentials: (URL, String)? {
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else { return nil }
        return (base, key)
    }

    /// 화면을 처음 열 때. 프로젝트·질의·상태 같은 바탕 목록과 첫 보기를 받는다.
    func start() {
        guard !started else { return }
        started = true
        loadMeta()
        load()
    }

    func refresh() {
        // 구성원 목록은 받지 못해 비어 있을 수 있어 다시 받는다
        people = [:]
        loadMeta()
        load()
        if let selected { loadDetail(selected) }
    }

    // MARK: 받기

    private func fetch(_ request: URLRequest, done: @escaping (Data?, Int, Error?) -> Void) {
        if let folder = ProcessInfo.processInfo.environment["RUNTIME_REDMINE_FIXTURES"], !folder.isEmpty {
            Self.serveFixture(request, folder: folder, done: done)
            return
        }
        // 사내망 밖처럼 레드마인에 닿지 않으면 기본 60초를 기다리지 않고 20초 뒤 까닭을 보인다
        var request = request
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { done(data, status, error) }
        }.resume()
    }

    /// 점검용: 레드마인 대신 폴더의 응답 파일로 답한다 (`issues/101.json` → `issues_101.json`, 없으면 끝 이름).
    /// 고치기(PUT)는 받은 것으로 친다. 사내망 밖에서도 화면과 고치기 흐름을 볼 수 있다.
    private static func serveFixture(_ request: URLRequest, folder: String, done: @escaping (Data?, Int, Error?) -> Void) {
        let path = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if request.httpMethod == "PUT" { return done(Data(), 204, nil) }
            if request.httpMethod == "POST" {
                let sample = path == "issues.json" ? FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent("created.json")) : nil
                return done(sample ?? Data("{}".utf8), 201, nil)
            }
            let names = [path.replacingOccurrences(of: "/", with: "_"), (path as NSString).lastPathComponent]
            for name in names {
                if let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(name)) {
                    return done(data, 200, nil)
                }
            }
            done(nil, 404, nil)
        }
    }

    private func loadMeta() {
        guard let (base, key) = credentials else { return }
        fetch(Redmine.projectsRequest(base: base, key: key)) { [weak self] data, _, _ in
            if let data, let list = try? Redmine.projects(data) { self?.projects = list }
        }
        fetch(Redmine.queriesRequest(base: base, key: key)) { [weak self] data, _, _ in
            if let data, let list = try? Redmine.queries(data) { self?.queries = list }
        }
        fetch(Redmine.statusesRequest(base: base, key: key)) { [weak self] data, _, _ in
            if let data, let list = try? Redmine.statuses(data) { self?.statuses = list }
        }
        fetch(Redmine.trackersRequest(base: base, key: key)) { [weak self] data, _, _ in
            if let data, let list = try? Redmine.trackers(data) { self?.trackers = list }
        }
        fetch(Redmine.prioritiesRequest(base: base, key: key)) { [weak self] data, _, _ in
            if let data, let list = try? Redmine.priorities(data) { self?.priorities = list }
        }
        fetch(RedmineAPI.activitiesRequest(base: base, key: key)) { [weak self] data, _, _ in
            if let data, let list = try? RedmineAPI.parseActivities(data) { self?.activities = list }
        }
        fetch(Redmine.currentUserRequest(base: base, key: key)) { [weak self] data, _, _ in
            if let data, let user = try? Redmine.currentUser(data) { self?.me = user }
        }
    }

    /// 지금 보기의 일감을 모두 받는다 (100개씩 이어서, 500개까지).
    func load() {
        guard let (base, key) = credentials else {
            error = "레드마인을 연결하지 않았습니다"
            return
        }
        listToken += 1
        let token = listToken
        loading = true
        error = nil
        var collected: [Redmine.Issue] = []
        func page(_ offset: Int) {
            fetch(Redmine.issuesRequest(base: base, key: key, filter: filter, offset: offset)) { [weak self] data, status, failure in
                guard let self, token == self.listToken else { return }
                guard status == 200, let data, let result = try? Redmine.issues(data) else {
                    self.loading = false
                    self.error = Self.message(status: status, error: failure, data: data)
                    return
                }
                // 받는 사이 누가 고쳐 순서가 바뀌면 같은 일감이 다음 쪽에 또 나온다
                let seen = Set(collected.map(\.id))
                let fresh = result.issues.filter { !seen.contains($0.id) }
                collected += fresh
                // 프로젝트 전체는 수백 건이라 1000건까지 받는다 (더 많으면 거르기를 좁히라고 알린다)
                // 다음 쪽은 서버 위치로 센다. 겹침을 뺀 건수로 세면 같은 쪽을 끝없이 다시 받는다
                let next = offset + result.issues.count
                if next < result.total, collected.count < 1000, !fresh.isEmpty {
                    page(next)
                } else {
                    self.loading = false
                    self.total = result.total
                    // 보내는 중인 일감은 먼저 바꿔 둔 화면 값을 지킨다 (서버의 옛 값으로 깜빡이지 않게)
                    self.issues = collected.map { fresh in
                        self.saving.contains(fresh.id) ? self.issues.first { $0.id == fresh.id } ?? fresh : fresh
                    }
                    // 상세를 받아 둔 일감은 목록 값으로 덮지 않는다 (기록·첨부가 빠진 목록 값이라)
                    for issue in collected where self.details[issue.id] != nil { self.merge(issue) }
                }
            }
        }
        page(0)
    }

    func loadDetail(_ id: Int) {
        guard let (base, key) = credentials else {
            detailErrors[id] = "레드마인 주소나 API 키를 읽지 못했습니다. 설정 > 업무 일지에서 확인하세요"
            return
        }
        loadingDetail = id
        detailErrors[id] = nil
        fetch(Redmine.issueRequest(base: base, key: key, id: id)) { [weak self] data, status, failure in
            guard let self else { return }
            if self.loadingDetail == id { self.loadingDetail = nil }
            // 보내는 중에 온 옛 응답은 먼저 바꿔 둔 화면 값을 덮어 깜빡이게 해 버린다. 보낸 뒤 다시 받는다
            guard !self.saving.contains(id) else { return }
            guard status == 200, let data, let issue = try? Redmine.issue(data) else {
                self.detailErrors[id] = Self.message(status: status, error: failure, data: data)
                return
            }
            self.details[id] = issue
            self.replaceInList(issue)
            self.loadPeople(project: issue.project.id)
            HTMLCache.shared.warm(([issue.description] + (issue.journals ?? []).map(\.notes)).compactMap { $0 }) { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    /// 프로젝트 구성원 (담당자 고르기). 100명씩 이어 받고, 받지 못하면 다음에 다시 받게 비워 둔다.
    func loadPeople(project: Int) {
        guard people[project] == nil, let (base, key) = credentials else { return }
        people[project] = []
        var collected: [Redmine.Ref] = []
        func page(_ offset: Int) {
            var request = Redmine.membersRequest(base: base, key: key, project: project)
            if var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "offset", value: "\(offset)")]
                request.url = components.url
            }
            fetch(request) { [weak self] data, status, _ in
                guard let self else { return }
                guard status == 200, let data, let list = try? Redmine.members(data) else {
                    self.people[project] = collected.isEmpty ? nil : collected.sorted { $0.name < $1.name }
                    return
                }
                let known = Set(collected.map(\.id))
                collected += list.filter { !known.contains($0.id) }
                // 서버가 쪽마다 주는 수만큼 넘긴다 (관리자가 쪽 크기를 100보다 작게 두었을 수 있다)
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let total = object?["total_count"] as? Int ?? 0
                let given = (object?["memberships"] as? [Any])?.count ?? 0
                if given > 0, offset + given < total, offset < 1000 { page(offset + given) } else { self.people[project] = collected.sorted { $0.name < $1.name } }
            }
        }
        page(0)
    }

    // MARK: 고치기

    /// 칸을 고친다. 화면 값을 먼저 바꾸고 보내고, 레드마인이 받지 않으면 원래 값으로 되돌리고 까닭을 알린다.
    /// 끝나면 기록(누가 무엇을 바꿨는지)이 붙은 상세를 다시 받는다.
    func update(_ id: Int, _ change: Redmine.Change, done: ((Bool) -> Void)? = nil) {
        // 보내는 중에 또 보내면 같은 댓글이 두 번 올라가고, 되돌릴 값도 틀어진다
        guard !change.isEmpty, !saving.contains(id), let (base, key) = credentials,
              let request = try? Redmine.updateRequest(base: base, key: key, id: id, change: change) else { return }
        let before = details[id] ?? issues.first { $0.id == id }
        if let before {
            let after = change.applied(to: before, statuses: statuses, priorities: priorities, people: people[before.project.id] ?? [])
            if details[id] != nil { details[id] = after }
            replaceInList(after)
        }
        saving.insert(id)
        fetch(request) { [weak self] data, status, failure in
            guard let self else { return }
            self.saving.remove(id)
            guard (200..<300).contains(status) else {
                if let before {
                    if self.details[id] != nil { self.details[id] = before }
                    self.replaceInList(before)
                }
                // 이 레드마인은 워크플로가 허용하는 상태를 알려 주지 않아, 막힌 전환은 고쳐 보고서야 안다. 다음부터 고르지 않게 기억한다.
                // 필수 칸·날짜 같은 다른 까닭의 422까지 기억하면 일지 보내기에서 그 전환을 조용히 빼게 되어 상태 까닭일 때만
                if status == 422, Redmine.isStatusRejection(Redmine.errors(data)), let to = change.statusID, let from = before?.status.id {
                    WorkLogSync.shared.rememberBlocked(from: from, to: to)
                }
                self.flash = "#\(id)을 고치지 못했습니다: " + Self.message(status: status, error: failure, data: data)
                // 보내는 사이 다른 사람이 고쳤을 수 있어 옛 값으로 둔 채 두지 않고 지금 값을 다시 받는다
                if self.details[id] != nil || self.selected == id { self.loadDetail(id) }
                done?(false)
                return
            }
            self.loadDetail(id)
            done?(true)
        }
    }

    /// 새 일감을 만든다. 되면 목록 맨 앞에 넣고 그 일감을 연다. 실패 까닭은 창에 그대로 보이게 돌려준다.
    func create(_ issue: Redmine.NewIssue, done: @escaping (String?) -> Void) {
        guard let (base, key) = credentials, let request = try? Redmine.createRequest(base: base, key: key, issue: issue) else {
            return done("레드마인 주소나 API 키를 읽지 못했습니다")
        }
        fetch(request) { [weak self] data, status, failure in
            guard let self else { return }
            guard status == 201, let data, let made = try? Redmine.issue(data) else {
                return done(Self.message(status: status, error: failure, data: data))
            }
            self.issues.insert(made, at: 0)
            self.total += 1
            done(nil)
            self.selected = made.id
        }
    }

    /// 소요 시간을 남긴다. 되면 일감을 다시 받아 소요 시간을 맞춘다.
    func logTime(_ id: Int, day: String, hours: Double, activityID: Int?, comment: String, done: @escaping (String?) -> Void) {
        guard let (base, key) = credentials,
              let request = try? RedmineAPI.timeEntryRequest(base: base, key: key, issue: id, spentOn: day, hours: hours,
                                                             activityID: activityID, comments: comment) else {
            return done("레드마인 주소나 API 키를 읽지 못했습니다")
        }
        fetch(request) { [weak self] data, status, failure in
            guard let self else { return }
            guard (200..<300).contains(status) else { return done(Self.message(status: status, error: failure, data: data)) }
            self.loadDetail(id)
            done(nil)
        }
    }

    /// 이 일감에서 막힌 적이 있는 상태로 바꾸려는지.
    func isBlocked(from: Int, to: Int) -> Bool {
        WorkLogSync.shared.blockedTransitions.contains(WorkLogSync.transitionKey(from, to))
    }

    private func replaceInList(_ issue: Redmine.Issue) {
        if let index = issues.firstIndex(where: { $0.id == issue.id }) {
            // 목록 값에는 기록·첨부가 없어 칸 값만 옮긴다
            var listed = issue
            listed.journals = nil
            listed.attachments = nil
            issues[index] = listed
        }
    }

    private func merge(_ listed: Redmine.Issue) {
        guard let detail = details[listed.id], let newer = listed.updated, newer > (detail.updated ?? .distantPast) else { return }
        // 다른 사람이 고쳤다. 기록까지 새로 받는다
        loadDetail(listed.id)
    }

    // MARK: 보이기

    private static let qaTrackers: Set<String> = ["결함", "시험", "테스트케이스", "회귀 테스트", "경험기반 테스트", "문서기반 테스트"]

    private func matches(_ issue: Redmine.Issue, _ quick: Quick) -> Bool {
        switch quick {
        case .all: return true
        case .stabilization: return issue.tracker.name == "안정화"
        case .qa: return Self.qaTrackers.contains(issue.tracker.name)
        case .unassigned: return issue.assignedTo == nil
        case .dueSoon:
            let soon = WorkDay.adding(3, to: WorkDay.today())
            let closed = Set(statuses.filter { $0.isClosed == true }.map(\.id))
            return (issue.dueDate ?? "9999") <= soon && issue.doneRatio < 100 && !closed.contains(issue.status.id)
        }
    }

    /// 빠른 거르기마다 건수 (칩 옆에 보인다).
    func count(_ quick: Quick) -> Int { issues.filter { matches($0, quick) }.count }

    /// 지금 보일 줄: 빠른 거르기 → 찾는 말 → 정렬 → (트리면) 상위·하위로 편다.
    var rows: [Redmine.TreeRow] {
        let words = search.lowercased().split(separator: " ")
        let filtered = issues.filter { issue in
            guard matches(issue, quick) else { return false }
            guard !words.isEmpty else { return true }
            let text = "#\(issue.id) \(issue.subject) \(issue.project.name) \(issue.tracker.name) \(issue.status.name) \(issue.assignedTo?.name ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let sorted = filtered.sorted { a, b in
            let order = compare(a, b)
            return order == .orderedSame ? a.id > b.id : (order == .orderedAscending) == ascending
        }
        return treeMode ? Redmine.tree(sorted, collapsed: collapsed)
            : sorted.map { Redmine.TreeRow(issue: $0, depth: 0, hasChildren: false) }
    }

    private func compare(_ a: Redmine.Issue, _ b: Redmine.Issue) -> ComparisonResult {
        func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending }
        switch sort {
        case .id: return order(a.id, b.id)
        case .tracker: return order(a.tracker.name, b.tracker.name)
        case .status: return order(a.status.id, b.status.id)
        case .priority: return order(a.priority.id, b.priority.id)
        case .subject: return a.subject.localizedStandardCompare(b.subject)
        case .assignee: return order(a.assignedTo?.name ?? "\u{FFFF}", b.assignedTo?.name ?? "\u{FFFF}")
        case .ratio: return order(a.doneRatio, b.doneRatio)
        // 기한 없는 일감은 오름차순일 때 맨 뒤로
        case .due: return order(a.dueDate ?? "9999-99-99", b.dueDate ?? "9999-99-99")
        case .updated: return order(a.updatedOn ?? "", b.updatedOn ?? "")
        }
    }

    /// 머리를 누르면 그 칸으로, 같은 칸을 다시 누르면 순서를 뒤집는다.
    func sort(by column: Column) {
        if sort == column { ascending.toggle() } else {
            sort = column
            ascending = [.id, .subject, .due, .tracker, .assignee].contains(column)
        }
    }

    /// 상세 창에서 ↑↓로 앞뒤 일감으로 옮긴다.
    func move(_ step: Int) {
        let ids = rows.map(\.id)
        guard let current = selected, let index = ids.firstIndex(of: current) else { return }
        let next = index + step
        if ids.indices.contains(next) { selected = ids[next] }
    }

    static func message(status: Int, error: Error?, data: Data?) -> String {
        let reasons = Redmine.errors(data)
        if !reasons.isEmpty { return reasons.joined(separator: ", ") }
        switch status {
        case 0:
            if let error = error as? URLError, [.timedOut, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost].contains(error.code) {
                return "레드마인에 닿지 않습니다. 사내망(VPN)에 연결돼 있는지 확인하세요"
            }
            return error.map { ($0 as NSError).localizedDescription } ?? "응답이 없습니다"
        case 401: return "API 키가 맞지 않습니다 (401)"
        case 403: return "이 일을 할 권한이 없습니다 (403)"
        case 404: return "없는 일감이거나 볼 수 없습니다 (404)"
        case 422: return "레드마인이 값을 받지 않았습니다 (422)"
        default: return "HTTP \(status)"
        }
    }
}
