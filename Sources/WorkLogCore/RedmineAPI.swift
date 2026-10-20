import Foundation

/// 레드마인 REST API. 앱이 직접 진척률과 댓글을 올려 Claude 토큰을 쓰지 않는다.
public enum RedmineAPI {
    public struct Issue: Equatable, Identifiable {
        public let id: Int
        public let subject: String
        public let project: String
        public let status: String
        public let doneRatio: Int

        public init(id: Int, subject: String, project: String, status: String, doneRatio: Int) {
            self.id = id
            self.subject = subject
            self.project = project
            self.status = status
            self.doneRatio = doneRatio
        }
    }

    public static func baseURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // API 키가 평문으로 나가지 않게 https만 받는다
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// 진척률과 댓글을 한 번에 올린다. 상태는 바꾸지 않는다. 진척률이 nil이면 댓글만.
    public static func updateRequest(base: URL, key: String, issue: Int, doneRatio: Int?, note: String) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("issues/\(issue).json"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Redmine-API-Key")
        var fields: [String: Any] = ["notes": note]
        if let doneRatio { fields["done_ratio"] = doneRatio }
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
        struct Named: Decodable { let name: String }
        struct Raw: Decodable {
            let id: Int
            let subject: String
            let project: Named?
            let status: Named?
            let done_ratio: Int?
        }
        struct List: Decodable { let issues: [Raw]? ; let issue: Raw? }
        let list = try JSONDecoder().decode(List.self, from: data)
        return (list.issues ?? list.issue.map { [$0] } ?? []).map {
            Issue(id: $0.id, subject: $0.subject, project: $0.project?.name ?? "", status: $0.status?.name ?? "",
                  doneRatio: $0.done_ratio ?? 0)
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
