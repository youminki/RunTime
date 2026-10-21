import Foundation

/// 레드마인 REST API. 앱이 직접 진척률과 댓글을 올려 Claude 토큰을 쓰지 않는다.
public enum RedmineAPI {
    public struct Issue: Equatable, Identifiable {
        public let id: Int
        public let subject: String
        public let project: String
        public let status: String
        public let doneRatio: Int
        public var tracker: String = ""
        public var parentID: Int?
        /// `yyyy-MM-dd`
        public var dueDate: String?
        public var priority: String = ""
        public var startDate: String?
        public var statusID: Int?
        public var projectID: Int?
        public var assignee: Member?

        public init(id: Int, subject: String, project: String, status: String, doneRatio: Int,
                    tracker: String = "", parentID: Int? = nil, dueDate: String? = nil, priority: String = "",
                    startDate: String? = nil, statusID: Int? = nil, projectID: Int? = nil, assignee: Member? = nil) {
            self.projectID = projectID
            self.assignee = assignee
            self.id = id
            self.subject = subject
            self.project = project
            self.status = status
            self.doneRatio = doneRatio
            self.tracker = tracker
            self.parentID = parentID
            self.dueDate = dueDate
            self.priority = priority
            self.startDate = startDate
            self.statusID = statusID
        }
    }

    /// 담당자로 고를 수 있는 사람 (프로젝트 구성원).
    public struct Member: Codable, Equatable, Identifiable, Hashable {
        public let id: Int
        public let name: String

        public init(id: Int, name: String) {
            self.id = id
            self.name = name
        }
    }

    public static func membersRequest(base: URL, key: String, project: Int) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("projects/\(project)/memberships.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    /// 구성원 가운데 사람만 (그룹 담당은 고르지 않는다), 이름 순.
    public static func parseMembers(_ data: Data) throws -> [Member] {
        struct Named: Decodable { let id: Int; let name: String }
        struct Raw: Decodable { let user: Named? }
        struct List: Decodable { let memberships: [Raw] }
        let users = try JSONDecoder().decode(List.self, from: data).memberships.compactMap(\.user)
        var seen = Set<Int>()
        return users.filter { seen.insert($0.id).inserted }.map { Member(id: $0.id, name: $0.name) }
            .sorted { $0.name < $1.name }
    }

    /// 일감 상태. 레드마인이 주는 순서가 일의 흐름 순서다 (신규 → 진행 → 해결 → 완료).
    public struct Status: Codable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        public let isClosed: Bool

        public init(id: Int, name: String, isClosed: Bool) {
            self.id = id
            self.name = name
            self.isClosed = isClosed
        }
    }

    /// 일감 댓글 기록 한 건.
    public struct Journal: Equatable, Identifiable {
        public let id: Int
        public let notes: String
        public let createdOn: Date

        public init(id: Int, notes: String, createdOn: Date) {
            self.id = id
            self.notes = notes
            self.createdOn = createdOn
        }
    }

    /// 일감 하나를 댓글 기록과 함께 (되돌리기 전에 지금 값을 본다).
    public static func issueWithJournalsRequest(base: URL, key: String, issue: Int) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("issues/\(issue).json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "include", value: "journals")]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    public static func parseJournals(_ data: Data) throws -> [Journal] {
        struct Raw: Decodable { let id: Int; let notes: String?; let created_on: String }
        struct Issue: Decodable { let journals: [Raw]? }
        struct Root: Decodable { let issue: Issue }
        let formatter = ISO8601DateFormatter()
        return try JSONDecoder().decode(Root.self, from: data).issue.journals?.compactMap { raw in
            formatter.date(from: raw.created_on).map { Journal(id: raw.id, notes: raw.notes ?? "", createdOn: $0) }
        } ?? []
    }

    /// 댓글 글을 비운다. 칸 변경이 없는 기록이면 레드마인이 기록째 지운다 (레드마인 5 이상).
    public static func clearJournalRequest(base: URL, key: String, journal: Int) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("journals/\(journal).json"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["journal": ["notes": ""]])
        return request
    }

    /// 되돌리기: 댓글 없이 칸만 고친다. 날짜를 빈 글자로 주면 그 칸을 비운다.
    public static func revertRequest(base: URL, key: String, issue: Int, doneRatio: Int?, statusID: Int?,
                                     startDate: String?, dueDate: String?, assigneeID: Int? = nil) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("issues/\(issue).json"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        var fields: [String: Any] = [:]
        if let doneRatio { fields["done_ratio"] = doneRatio }
        if let statusID { fields["status_id"] = statusID }
        if let startDate { fields["start_date"] = startDate }
        if let dueDate { fields["due_date"] = dueDate }
        if let assigneeID { fields["assigned_to_id"] = assigneeID }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["issue": fields])
        return request
    }

    public static func deleteTimeEntryRequest(base: URL, key: String, id: Int) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("time_entries/\(id).json"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    /// 작업 시간을 남긴 응답에서 번호를 읽는다 (되돌릴 때 지우려고).
    public static func parseTimeEntryID(_ data: Data) -> Int? {
        struct Entry: Decodable { let id: Int }
        struct Root: Decodable { let time_entry: Entry }
        return (try? JSONDecoder().decode(Root.self, from: data))?.time_entry.id
    }

    public static func statusesRequest(base: URL, key: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("issue_statuses.json"))
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    public static func parseStatuses(_ data: Data) throws -> [Status] {
        struct Raw: Decodable { let id: Int; let name: String; let is_closed: Bool? }
        struct List: Decodable { let issue_statuses: [Raw] }
        return try JSONDecoder().decode(List.self, from: data).issue_statuses
            .map { Status(id: $0.id, name: $0.name, isClosed: $0.is_closed ?? false) }
    }

    /// 나에게 배정된 열린 일감 한 쪽 (100개씩). `offset`으로 다음 쪽.
    public static func myIssuesRequest(base: URL, key: String, offset: Int) -> URLRequest {
        var request = myIssuesRequest(base: base, key: key)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "offset", value: String(offset))]
        request.url = components.url
        return request
    }

    /// 번호로 여러 일감을 한 번에 (닫힌 것도). 부모 일감 이름을 받아 보고서 이름을 만드는 데 쓴다.
    public static func issuesRequest(base: URL, key: String, ids: [Int]) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("issues.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "issue_id", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "status_id", value: "*"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    /// 목록 응답의 전체 개수 (쪽을 더 받을지 정한다).
    public static func totalCount(_ data: Data) -> Int? {
        struct Count: Decodable { let total_count: Int? }
        return (try? JSONDecoder().decode(Count.self, from: data))?.total_count
    }

    public static func baseURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // API 키가 평문으로 나가지 않게 https만 받는다
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// 진척률과 댓글을 한 번에 올린다. 진척률이 nil이면 댓글만. 상태·시작일·완료 기한은 넘긴 것만 바꾼다.
    public static func updateRequest(base: URL, key: String, issue: Int, doneRatio: Int?, note: String,
                                     fields extra: WorkReport.IssueFields = .init()) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("issues/\(issue).json"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        var fields: [String: Any] = ["notes": note]
        if let doneRatio { fields["done_ratio"] = doneRatio }
        if let status = extra.status { fields["status_id"] = status.id }
        if let assignee = extra.assignee { fields["assigned_to_id"] = assignee.id }
        if let start = extra.startDate { fields["start_date"] = start }
        if let due = extra.dueDate { fields["due_date"] = due }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["issue": fields])
        return request
    }

    /// 나에게 배정된 열린 일감 (일감 고르기와 지금 진척률 보기에 쓴다).
    public static func myIssuesRequest(base: URL, key: String) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("issues.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "assigned_to_id", value: "me"),
            URLQueryItem(name: "status_id", value: "open"),
            URLQueryItem(name: "sort", value: "updated_on:desc"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    /// 작업 시간 남기기. 작업 분류(activity)는 레드마인마다 달라 설정에서 고른 값을 쓴다.
    public static func timeEntryRequest(base: URL, key: String, issue: Int, spentOn: String, hours: Double,
                                        activityID: Int?, comments: String) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("time_entries.json"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        var fields: [String: Any] = ["issue_id": issue, "spent_on": spentOn, "hours": hours,
                                     "comments": String(comments.prefix(255))]
        if let activityID { fields["activity_id"] = activityID }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["time_entry": fields])
        return request
    }

    public struct Activity: Equatable, Identifiable {
        public let id: Int
        public let name: String
        public let isDefault: Bool
    }

    public static func activitiesRequest(base: URL, key: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("enumerations/time_entry_activities.json"))
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    public static func parseActivities(_ data: Data) throws -> [Activity] {
        struct Raw: Decodable { let id: Int; let name: String; let is_default: Bool?; let active: Bool? }
        struct List: Decodable { let time_entry_activities: [Raw] }
        return try JSONDecoder().decode(List.self, from: data).time_entry_activities
            .filter { $0.active != false }
            .map { Activity(id: $0.id, name: $0.name, isDefault: $0.is_default ?? false) }
    }

    public static func issueRequest(base: URL, key: String, issue: Int) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("issues/\(issue).json"))
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    public static func parseIssues(_ data: Data) throws -> [Issue] {
        struct Named: Decodable { let name: String; let id: Int? }
        struct Person: Decodable { let name: String; let id: Int }
        struct Ref: Decodable { let id: Int }
        struct Raw: Decodable {
            let id: Int
            let subject: String
            let project: Named?
            let status: Named?
            let tracker: Named?
            let priority: Named?
            let parent: Ref?
            let done_ratio: Int?
            let due_date: String?
            let start_date: String?
            let assigned_to: Person?
        }
        struct List: Decodable { let issues: [Raw]? ; let issue: Raw? }
        let list = try JSONDecoder().decode(List.self, from: data)
        return (list.issues ?? list.issue.map { [$0] } ?? []).map {
            Issue(id: $0.id, subject: $0.subject, project: $0.project?.name ?? "", status: $0.status?.name ?? "",
                  doneRatio: $0.done_ratio ?? 0, tracker: $0.tracker?.name ?? "", parentID: $0.parent?.id,
                  dueDate: $0.due_date, priority: $0.priority?.name ?? "", startDate: $0.start_date, statusID: $0.status?.id,
                  projectID: $0.project?.id, assignee: $0.assigned_to.map { Member(id: $0.id, name: $0.name) })
        }
    }

    /// MCP 설정(`~/.claude.json`)의 redmine 서버 주소와 키. 처음 한 번 옮겨 오는 데만 쓴다.
    public static func mcpCredentials(in data: Data) -> (url: String, key: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: (String, String)?
        func walk(_ node: Any) {
            guard found == nil else { return }
            if let dict = node as? [String: Any] {
                if let servers = dict["mcpServers"] as? [String: Any] {
                    for (name, server) in servers where name.lowercased().contains("redmine") {
                        if let env = (server as? [String: Any])?["env"] as? [String: Any],
                           let url = env["REDMINE_URL"] as? String, let key = env["REDMINE_API_KEY"] as? String,
                           !url.isEmpty, !key.isEmpty {
                            found = (url, key)
                            return
                        }
                    }
                }
                dict.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)
        return found
    }
}
