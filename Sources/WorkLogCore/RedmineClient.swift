import Foundation

/// 앱 안 레드마인 화면이 쓰는 모델과 요청. 업무 일지가 쓰는 `RedmineAPI`는 보고에 필요한 칸만 읽고,
/// 이쪽은 일감 하나를 웹 화면처럼 모두 읽는다 (설명, 기록, 첨부, 하위·관계 일감, 지켜보는 사람).
/// 이 레드마인은 4.x라 일감에 `allowed_statuses`를 주지 않는다. 막힌 상태 전환은 고쳐 보다가 422로 알게 된다.
public enum Redmine {
    /// 이름이 붙은 참조 (프로젝트·트래커·상태·우선순위·사람).
    public struct Ref: Codable, Equatable, Hashable, Identifiable {
        public let id: Int
        public let name: String
        public init(id: Int, name: String) { (self.id, self.name) = (id, name) }
    }

    public struct Issue: Codable, Equatable, Identifiable {
        public let id: Int
        public var project: Ref
        public var tracker: Ref
        public var status: Ref
        public var priority: Ref
        public var author: Ref?
        public var assignedTo: Ref?
        public var parent: Parent?
        public var subject: String
        public var description: String?
        public var startDate: String?
        public var dueDate: String?
        public var doneRatio: Int
        public var estimatedHours: Double?
        public var spentHours: Double?
        public var createdOn: String?
        public var updatedOn: String?
        public var closedOn: String?
        public var journals: [Journal]?
        public var attachments: [Attachment]?
        public var children: [Child]?
        public var relations: [Relation]?
        public var watchers: [Ref]?

        public struct Parent: Codable, Equatable { public let id: Int }

        /// `updatedOn`을 날짜로. 목록을 최근 고친 순으로 둘 때 쓴다.
        public var updated: Date? { updatedOn.flatMap(Redmine.date) }
    }

    public struct Journal: Codable, Equatable, Identifiable {
        public let id: Int
        public let user: Ref?
        public let notes: String?
        public let createdOn: String
        public let details: [Detail]?

        public var created: Date? { Redmine.date(createdOn) }
    }

    /// 기록 한 줄의 칸 변경. `property`는 `attr`(일감 칸)·`attachment`·`relation`·`cf`(사용자 정의 칸).
    public struct Detail: Codable, Equatable {
        public let property: String
        public let name: String
        public let oldValue: String?
        public let newValue: String?
    }

    public struct Attachment: Codable, Equatable, Identifiable {
        public let id: Int
        public let filename: String
        public let filesize: Int
        public let contentType: String?
        public let contentUrl: String?
        public let author: Ref?
        public let createdOn: String?

        public var isImage: Bool { contentType?.hasPrefix("image/") == true }
    }

    public struct Child: Codable, Equatable, Identifiable {
        public let id: Int
        public let tracker: Ref?
        public let subject: String
        public let children: [Child]?
    }

    public struct Relation: Codable, Equatable, Identifiable {
        public let id: Int
        public let issueId: Int
        public let issueToId: Int
        public let relationType: String
        public let delay: Int?

        /// `issue`에서 본 상대 일감 번호와 관계 이름. 레드마인 웹과 같은 말을 쓴다.
        public func describe(from issue: Int) -> (other: Int, label: String) {
            let outgoing = issueId == issue
            let other = outgoing ? issueToId : issueId
            let labels: [String: (String, String)] = [
                "relates": ("관련", "관련"), "duplicates": ("중복", "중복됨"), "blocks": ("막음", "막힘"),
                "precedes": ("앞섬", "뒤따름"), "copied_to": ("복사함", "복사됨"),
            ]
            let pair = labels[relationType] ?? (relationType, relationType)
            return (other, outgoing ? pair.0 : pair.1)
        }
    }

    public struct Project: Codable, Hashable, Identifiable {
        public let id: Int
        public let name: String
        public let identifier: String
        public let parent: Ref?
        /// 이 프로젝트에서 쓰는 트래커 (새 일감에서 고른다). 레드마인 전체 트래커는 50개가 넘는다.
        public var trackers: [Ref]?
    }

    /// 레드마인에 저장한 질의. `projectId`가 있으면 그 프로젝트에서만 쓴다.
    public struct Query: Codable, Hashable, Identifiable {
        public let id: Int
        public let name: String
        public let isPublic: Bool?
        public let projectId: Int?
    }

    public struct Status: Codable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        public let isClosed: Bool?
    }

    struct Page: Decodable { let issues: [Issue]; let totalCount: Int?; let offset: Int?; let limit: Int? }
    struct One: Decodable { let issue: Issue }
    struct Projects: Decodable { let projects: [Project] }
    struct Queries: Decodable { let queries: [Query] }
    struct Statuses: Decodable { let issueStatuses: [Status] }
    struct Trackers: Decodable { let trackers: [Ref] }
    struct Priorities: Decodable { let issuePriorities: [Ref] }
    struct Memberships: Decodable {
        struct Member: Decodable { let user: Ref? }
        let memberships: [Member]
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// 레드마인 시각(`2026-11-03T09:12:00Z`)을 날짜로.
    public static func date(_ text: String) -> Date? {
        isoFormatter.date(from: text)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    /// 422 까닭이 상태 전환을 막은 것인지. 필수 칸·날짜 같은 다른 검증 오류로 막혔을 때 전환을 막힘으로 기억하지 않게 한다.
    public static func isStatusRejection(_ reasons: [String]) -> Bool {
        // `개발상태 은(는) 비어 있을 수 없습니다` 같은 사용자 정의 칸 오류는 상태 전환이 아니다
        reasons.contains { $0.hasPrefix("상태 ") || $0.hasPrefix("상태은") || $0.hasPrefix("상태는") || $0.lowercased().hasPrefix("status ") }
    }

    // MARK: 읽기

    public static func issues(_ data: Data) throws -> (issues: [Issue], total: Int) {
        let page = try decoder.decode(Page.self, from: data)
        return (page.issues, page.totalCount ?? page.issues.count)
    }

    public static func issue(_ data: Data) throws -> Issue { try decoder.decode(One.self, from: data).issue }
    public static func projects(_ data: Data) throws -> [Project] { try decoder.decode(Projects.self, from: data).projects }
    public static func queries(_ data: Data) throws -> [Query] { try decoder.decode(Queries.self, from: data).queries }
    public static func statuses(_ data: Data) throws -> [Status] { try decoder.decode(Statuses.self, from: data).issueStatuses }
    public static func trackers(_ data: Data) throws -> [Ref] { try decoder.decode(Trackers.self, from: data).trackers }
    public static func priorities(_ data: Data) throws -> [Ref] { try decoder.decode(Priorities.self, from: data).issuePriorities }

    /// 프로젝트 구성원 가운데 사람만 (그룹 구성원은 `group`으로 와서 담당자로 고르지 않는다). 이름순, 겹침 없이.
    public static func members(_ data: Data) throws -> [Ref] {
        let people = try decoder.decode(Memberships.self, from: data).memberships.compactMap(\.user)
        var seen = Set<Int>()
        return people.filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }

    /// 내 계정. 이름은 웹처럼 성과 이름을 붙여 쓴다 (`유민기`).
    public static func currentUser(_ data: Data) throws -> Ref {
        struct User: Decodable { let id: Int; let firstname: String?; let lastname: String?; let login: String? }
        struct Root: Decodable { let user: User }
        let user = try decoder.decode(Root.self, from: data).user
        let name = [user.lastname, user.firstname].compactMap { $0 }.joined()
        return Ref(id: user.id, name: name.isEmpty ? user.login ?? "#\(user.id)" : name)
    }

    /// 레드마인이 거절한 까닭 (`{"errors":[…]}`).
    public static func errors(_ data: Data?) -> [String] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["errors"] as? [String] ?? []
    }

    // MARK: 요청

    /// 목록을 거르는 조건. 레드마인 `/issues.json` 매개변수 그대로.
    public struct Filter: Equatable, Hashable {
        public var queryID: Int?
        public var projectID: Int?
        public var assignedToMe = false
        public var authoredByMe = false
        /// `open`, `closed`, `*`, 또는 상태 번호.
        public var status = "open"
        public var trackerID: Int?
        public var sort = "updated_on:desc"

        public init(queryID: Int? = nil, projectID: Int? = nil, assignedToMe: Bool = false, authoredByMe: Bool = false,
                    status: String = "open", trackerID: Int? = nil, sort: String = "updated_on:desc") {
            (self.queryID, self.projectID, self.assignedToMe, self.authoredByMe) = (queryID, projectID, assignedToMe, authoredByMe)
            (self.status, self.trackerID, self.sort) = (status, trackerID, sort)
        }

        var items: [URLQueryItem] {
            var items: [URLQueryItem] = [URLQueryItem(name: "sort", value: sort)]
            if let queryID {
                // 저장한 질의는 그 질의의 조건을 쓴다. 상태 조건을 덧붙이면 질의가 가리키는 닫힌 일감이 빠진다
                items.append(URLQueryItem(name: "query_id", value: "\(queryID)"))
            } else {
                items.append(URLQueryItem(name: "status_id", value: status))
            }
            if let projectID { items.append(URLQueryItem(name: "project_id", value: "\(projectID)")) }
            if assignedToMe { items.append(URLQueryItem(name: "assigned_to_id", value: "me")) }
            if authoredByMe { items.append(URLQueryItem(name: "author_id", value: "me")) }
            if let trackerID { items.append(URLQueryItem(name: "tracker_id", value: "\(trackerID)")) }
            return items
        }
    }

    static func request(_ base: URL, _ path: String, key: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        return request
    }

    public static func issuesRequest(base: URL, key: String, filter: Filter, offset: Int = 0, limit: Int = 100) -> URLRequest {
        request(base, "issues.json", key: key, query: filter.items + [
            URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "\(limit)"),
        ])
    }

    public static func issueRequest(base: URL, key: String, id: Int) -> URLRequest {
        request(base, "issues/\(id).json", key: key,
                query: [URLQueryItem(name: "include", value: "journals,attachments,children,relations,watchers")])
    }

    public static func projectsRequest(base: URL, key: String) -> URLRequest {
        request(base, "projects.json", key: key, query: [URLQueryItem(name: "limit", value: "100"),
                                                         URLQueryItem(name: "include", value: "trackers")])
    }

    public static func queriesRequest(base: URL, key: String) -> URLRequest {
        request(base, "queries.json", key: key, query: [URLQueryItem(name: "limit", value: "100")])
    }

    public static func statusesRequest(base: URL, key: String) -> URLRequest { request(base, "issue_statuses.json", key: key) }
    public static func currentUserRequest(base: URL, key: String) -> URLRequest { request(base, "users/current.json", key: key) }
    public static func trackersRequest(base: URL, key: String) -> URLRequest { request(base, "trackers.json", key: key) }
    public static func prioritiesRequest(base: URL, key: String) -> URLRequest {
        request(base, "enumerations/issue_priorities.json", key: key)
    }

    public static func membersRequest(base: URL, key: String, project: Int) -> URLRequest {
        request(base, "projects/\(project)/memberships.json", key: key, query: [URLQueryItem(name: "limit", value: "100")])
    }

    /// 일감 칸 고치기. 바꿀 칸만 담는다. 댓글(`notes`)은 HTML로 넘긴다 (이 레드마인은 HTML로 저장한다).
    public struct Change: Equatable {
        public var statusID: Int?
        public var doneRatio: Int?
        public var priorityID: Int?
        /// 0이면 담당자를 비운다.
        public var assignedToID: Int?
        /// 빈 글자면 그 날짜를 비운다.
        public var startDate: String?
        public var dueDate: String?
        public var subject: String?
        /// 평문으로 받아 HTML로 넘긴다. `descriptionRaw`면 쓴 그대로 넘긴다 (서식 있는 설명, 평문 레드마인).
        public var description: String?
        public var descriptionRaw = false
        public var notes: String?
        /// 먼저 올려 받은 첨부 토큰.
        public var uploads: [RedmineAPI.Upload] = []
        /// 평문을 쓰는 레드마인이면 쓴 그대로 넘긴다.
        public var notesRaw = false

        public init(statusID: Int? = nil, doneRatio: Int? = nil, priorityID: Int? = nil, assignedToID: Int? = nil,
                    startDate: String? = nil, dueDate: String? = nil, subject: String? = nil, description: String? = nil,
                    descriptionRaw: Bool = false, notes: String? = nil, notesRaw: Bool = false, uploads: [RedmineAPI.Upload] = []) {
            (self.statusID, self.doneRatio, self.priorityID, self.assignedToID) = (statusID, doneRatio, priorityID, assignedToID)
            (self.startDate, self.dueDate, self.subject, self.description, self.notes) = (startDate, dueDate, subject, description, notes)
            (self.descriptionRaw, self.notesRaw, self.uploads) = (descriptionRaw, notesRaw, uploads)
        }

        private var descriptionValue: String? {
            description.map { descriptionRaw || $0.isEmpty ? $0 : RedmineNote.html($0) }
        }

        public var isEmpty: Bool { fields.isEmpty }

        public var fields: [String: Any] {
            var fields: [String: Any] = [:]
            if let statusID { fields["status_id"] = statusID }
            if let doneRatio { fields["done_ratio"] = doneRatio }
            if let priorityID { fields["priority_id"] = priorityID }
            if let assignedToID { fields["assigned_to_id"] = assignedToID == 0 ? "" : "\(assignedToID)" }
            if let startDate { fields["start_date"] = startDate }
            if let dueDate { fields["due_date"] = dueDate }
            if let subject { fields["subject"] = subject }
            if let descriptionValue { fields["description"] = descriptionValue }
            if !uploads.isEmpty {
                fields["uploads"] = uploads.map { ["token": $0.token, "filename": $0.filename, "content_type": $0.contentType] }
            }
            if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["notes"] = notesRaw ? notes : RedmineNote.html(notes) }
            return fields
        }

        /// 보내기 전에 화면 값을 먼저 바꿔 둔다 (웹처럼 새로고침을 기다리지 않게). 실패하면 원래 값으로 되돌린다.
        public func applied(to issue: Issue, statuses: [Status], priorities: [Ref], people: [Ref]) -> Issue {
            var copy = issue
            if let statusID, let status = statuses.first(where: { $0.id == statusID }) { copy.status = Ref(id: status.id, name: status.name) }
            if let doneRatio { copy.doneRatio = doneRatio }
            if let priorityID, let priority = priorities.first(where: { $0.id == priorityID }) { copy.priority = priority }
            if let assignedToID { copy.assignedTo = assignedToID == 0 ? nil : people.first { $0.id == assignedToID } ?? copy.assignedTo }
            if let startDate { copy.startDate = startDate.isEmpty ? nil : startDate }
            if let dueDate { copy.dueDate = dueDate.isEmpty ? nil : dueDate }
            if let subject { copy.subject = subject }
            if let descriptionValue { copy.description = descriptionValue.isEmpty ? nil : descriptionValue }
            return copy
        }
    }

    public static func updateRequest(base: URL, key: String, id: Int, change: Change) throws -> URLRequest {
        var request = request(base, "issues/\(id).json", key: key)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["issue": change.fields])
        return request
    }

    /// 관계 종류. 레드마인 값과 웹의 이름.
    public static let relationTypes: [(value: String, label: String)] = [
        ("relates", "관련"), ("blocks", "막음"), ("precedes", "앞섬"), ("duplicates", "중복"), ("copied_to", "복사함"),
    ]

    private static func json(_ request: URLRequest, method: String, body: [String: Any]?) throws -> URLRequest {
        var request = request
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    public static func addRelationRequest(base: URL, key: String, issue: Int, to: Int, type: String) throws -> URLRequest {
        try json(request(base, "issues/\(issue)/relations.json", key: key), method: "POST",
                 body: ["relation": ["issue_to_id": to, "relation_type": type]])
    }

    public static func removeRelationRequest(base: URL, key: String, relation: Int) throws -> URLRequest {
        try json(request(base, "relations/\(relation).json", key: key), method: "DELETE", body: nil)
    }

    public static func watchRequest(base: URL, key: String, issue: Int, user: Int, on: Bool) throws -> URLRequest {
        on ? try json(request(base, "issues/\(issue)/watchers.json", key: key), method: "POST", body: ["user_id": user])
            : try json(request(base, "issues/\(issue)/watchers/\(user).json", key: key), method: "DELETE", body: nil)
    }

    /// 찾기 결과 한 줄.
    public struct Found: Decodable, Equatable, Identifiable {
        public let id: Int
        public let title: String
        public let type: String
        public let url: String?

        public var isIssue: Bool { type.hasPrefix("issue") }
    }

    public static func searchRequest(base: URL, key: String, query: String) -> URLRequest {
        request(base, "search.json", key: key, query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "issues", value: "1"),
                                                       URLQueryItem(name: "limit", value: "50")])
    }

    public static func found(_ data: Data) throws -> [Found] {
        struct Results: Decodable { let results: [Found] }
        return try decoder.decode(Results.self, from: data).results.filter(\.isIssue)
    }

    /// 찾기 결과의 전체 건수 (한 번에 50건만 받는다).
    public static func foundTotal(_ data: Data) -> Int {
        struct Page: Decodable { let totalCount: Int? }
        return (try? decoder.decode(Page.self, from: data))?.totalCount ?? 0
    }

    /// `#123`이나 `123`처럼 번호만 쓴 찾는 말의 일감 번호.
    public static func issueNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return Int(trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed).flatMap { $0 > 0 ? $0 : nil }
    }

    /// 새 일감. 설명은 평문으로 받아 HTML로 넘긴다 (이 레드마인은 HTML로 저장한다).
    public struct NewIssue: Equatable {
        public var projectID: Int
        public var trackerID: Int
        public var subject: String
        public var description = ""
        public var priorityID: Int?
        public var assignedToID: Int?
        public var parentID: Int?
        public var startDate: String?
        public var dueDate: String?

        /// 평문을 쓰는 레드마인이면 쓴 그대로 넘긴다.
        public var descriptionRaw = false

        public init(projectID: Int, trackerID: Int, subject: String) {
            (self.projectID, self.trackerID, self.subject) = (projectID, trackerID, subject)
        }

        public var isValid: Bool { !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        public var fields: [String: Any] {
            var fields: [String: Any] = ["project_id": projectID, "tracker_id": trackerID,
                                         "subject": subject.trimmingCharacters(in: .whitespacesAndNewlines)]
            if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields["description"] = descriptionRaw ? description : RedmineNote.html(description)
            }
            if let priorityID { fields["priority_id"] = priorityID }
            if let assignedToID { fields["assigned_to_id"] = assignedToID }
            if let parentID { fields["parent_issue_id"] = parentID }
            if let startDate { fields["start_date"] = startDate }
            if let dueDate { fields["due_date"] = dueDate }
            return fields
        }
    }

    public static func createRequest(base: URL, key: String, issue: NewIssue) throws -> URLRequest {
        var request = request(base, "issues.json", key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["issue": issue.fields])
        return request
    }

    /// 웹에서 여는 주소 (API가 없는 화면, 첨부 원본).
    public static func webURL(base: URL, issue: Int) -> URL { base.appendingPathComponent("issues/\(issue)") }

    // MARK: 보이기

    /// 기록 한 줄의 칸 변경을 사람이 읽는 말로. 이름을 모르는 번호는 번호로 둔다.
    public static func describe(_ detail: Detail, statuses: [Status], trackers: [Ref], priorities: [Ref], people: [Ref]) -> String {
        func name(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return "없음" }
            guard let id = Int(value) else { return value }
            switch detail.name {
            case "status_id": return statuses.first { $0.id == id }?.name ?? value
            case "tracker_id": return trackers.first { $0.id == id }?.name ?? value
            case "priority_id": return priorities.first { $0.id == id }?.name ?? value
            case "assigned_to_id": return people.first { $0.id == id }?.name ?? "#\(value)"
            case "done_ratio": return "\(id)%"
            case "parent_id": return "#\(id)"
            default: return value
            }
        }
        switch detail.property {
        case "attachment": return detail.newValue.map { "첨부 \($0) 추가" } ?? "첨부 \(detail.oldValue ?? "") 삭제"
        case "relation": return "관계 \(detail.name) #\(detail.newValue ?? detail.oldValue ?? "")"
        case "cf": return "사용자 정의 칸: \(name(detail.oldValue)) → \(name(detail.newValue))"
        default: break
        }
        let labels = ["status_id": "상태", "done_ratio": "진척률", "assigned_to_id": "담당자", "priority_id": "우선순위",
                      "tracker_id": "트래커", "start_date": "시작일", "due_date": "완료 기한", "subject": "제목",
                      "description": "설명", "parent_id": "상위 일감", "estimated_hours": "추정 시간", "fixed_version_id": "목표 버전",
                      "category_id": "범주", "is_private": "비공개"]
        let label = labels[detail.name] ?? detail.name
        if detail.name == "description" { return "설명을 고침" }
        return "\(label): \(name(detail.oldValue)) → \(name(detail.newValue))"
    }
}

extension Redmine {
    /// 트리 보기의 한 줄. `depth`만큼 들여 쓰고, `hasChildren`이면 접고 펼 수 있다.
    /// `isContext`는 목록 조건에는 안 맞지만 하위 일감의 자리를 보이려고 넣은 상위 일감이다.
    public struct TreeRow: Equatable, Identifiable {
        public let issue: Issue
        public let depth: Int
        public let hasChildren: Bool
        public var isContext = false
        public var id: Int { issue.id }

        public init(issue: Issue, depth: Int, hasChildren: Bool, isContext: Bool = false) {
            (self.issue, self.depth, self.hasChildren, self.isContext) = (issue, depth, hasChildren, isContext)
        }
    }

    /// 목록을 상위·하위 일감 순서로 편다. 내 일감의 상위는 남에게 배정돼 목록에 없는 일이 많아,
    /// `context`로 받은 상위 일감을 끼워 넣는다 (목록 일감을 품은 것만 남긴다).
    /// 형제끼리는 목록 순서를 지키고, `collapsed`에 든 일감의 하위는 뺀다.
    public static func tree(_ issues: [Issue], context: [Issue] = [], collapsed: Set<Int> = []) -> [TreeRow] {
        let listed = Set(issues.map(\.id))
        let all = issues + context.filter { !listed.contains($0.id) }
        let ids = Set(all.map(\.id))
        var children: [Int: [Issue]] = [:]
        var roots: [Issue] = []
        for issue in all {
            if let parent = issue.parent?.id, ids.contains(parent), parent != issue.id {
                children[parent, default: []].append(issue)
            } else {
                roots.append(issue)
            }
        }
        // 목록 순서를 지키도록 묶음마다 그 안에서 가장 앞선 목록 일감의 자리를 잰다. 목록 일감이 없는 상위는 뺀다
        let position = Dictionary(issues.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var rank: [Int: Int] = [:]
        var ranking = Set<Int>()
        func measure(_ issue: Issue) -> Int {
            if let known = rank[issue.id] { return known }
            guard ranking.insert(issue.id).inserted else { return Int.max }
            let best = (children[issue.id] ?? []).map(measure).min() ?? Int.max
            let value = min(position[issue.id] ?? Int.max, best)
            rank[issue.id] = value
            return value
        }
        for issue in all { _ = measure(issue) }
        func ordered(_ list: [Issue]) -> [Issue] {
            list.filter { rank[$0.id] != Int.max }.sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
        }
        var rows: [TreeRow] = []
        var visited = Set<Int>()
        func walk(_ issue: Issue, depth: Int) {
            // 상위 관계가 고리를 이루는 망가진 자료에서 끝없이 돌지 않게
            guard visited.insert(issue.id).inserted else { return }
            let kids = ordered(children[issue.id] ?? [])
            rows.append(TreeRow(issue: issue, depth: depth, hasChildren: !kids.isEmpty, isContext: !listed.contains(issue.id)))
            guard !collapsed.contains(issue.id) else { return }
            for kid in kids { walk(kid, depth: depth + 1) }
        }
        for root in ordered(roots) { walk(root, depth: 0) }
        // 접힌 상위 아래 모든 깊이의 하위는 일부러 뺀 것이다
        var hidden = Set<Int>()
        var stack = Array(collapsed)
        while let parent = stack.popLast() {
            for kid in children[parent] ?? [] where hidden.insert(kid.id).inserted { stack.append(kid.id) }
        }
        // 고리에만 든 일감(상위가 서로를 가리킴)도 빠지지 않게 끝에 붙인다
        for issue in issues where !visited.contains(issue.id) && !hidden.contains(issue.id) {
            walk(issue, depth: 0)
        }
        return rows
    }

    /// `yyyy-MM-dd`를 1970-01-01부터 센 날수로. 일정 보기는 날짜를 정수로만 다룬다.
    public static func dayNumber(_ text: String?) -> Int? {
        let parts = (text ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return Int(date.timeIntervalSince1970 / 86_400)
    }

    /// 그 날이 든 주의 월요일.
    public static func monday(of day: Int) -> Int { day - (((day + 3) % 7) + 7) % 7 }

    /// 일정 보기의 막대 한 개. `offset`은 창 첫날부터의 날수다.
    public struct Bar: Equatable {
        public let offset: Int
        public let length: Int

        public init(offset: Int, length: Int) { (self.offset, self.length) = (offset, length) }
    }

    /// 일감 기간을 `from`부터 `days`일 창에 맞춘 막대. 한쪽 날짜만 있으면 그 하루, 창 밖이면 nil.
    public static func bar(start: String?, due: String?, from: Int, days: Int) -> Bar? {
        guard let first = dayNumber(start) ?? dayNumber(due), let end = dayNumber(due) ?? dayNumber(start) else { return nil }
        let last = max(first, end)
        guard last >= from, first < from + days else { return nil }
        let offset = max(first, from) - from
        return Bar(offset: offset, length: min(last, from + days - 1) - from - offset + 1)
    }

    /// 창 안의 월요일마다 자리와 `M.d` 이름.
    public static func weeks(from: Int, days: Int) -> [(offset: Int, label: String)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var day = monday(of: from)
        if day < from { day += 7 }
        var result: [(offset: Int, label: String)] = []
        while day < from + days {
            let parts = calendar.dateComponents([.month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
            result.append((day - from, "\(parts.month ?? 0).\(parts.day ?? 0)"))
            day += 7
        }
        return result
    }

    /// 목록 일감의 상위 가운데 아직 받지 않은 번호.
    public static func missingParents(_ issues: [Issue], known: Set<Int>) -> [Int] {
        Array(Set(issues.compactMap(\.parent?.id)).subtracting(known).subtracting(issues.map(\.id))).sorted()
    }

    /// 번호로 일감 여럿 받기 (닫힌 일감도).
    public static func issuesRequest(base: URL, key: String, ids: [Int]) -> URLRequest {
        request(base, "issues.json", key: key, query: [
            URLQueryItem(name: "issue_id", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "status_id", value: "*"), URLQueryItem(name: "limit", value: "100"),
        ])
    }
}
