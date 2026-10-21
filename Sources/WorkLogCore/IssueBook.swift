import Foundation

/// 레드마인 일감을 보고서 이름으로 옮기는 장부. 일지 파일에 함께 두어 레드마인이 닿지 않을 때도 보고서를 만든다.
///
/// 일감은 `구현 > 데이터 수집(메뉴) > 공유 파일 관리(화면) > API 연동` 꼴로 쌓여 있어,
/// 보고서에는 맨 위 묶음을 빼고 `데이터 수집 > 공유 파일 관리 API 연동`으로 적는다.
/// `시험 > 기능 테스트 > [수정][메뉴] …` 아래 일감은 QA 수정사항으로 세어 `QA 수정사항 N건 반영` 한 줄로 모은다.
public struct IssueInfo: Codable, Equatable, Identifiable {
    public var id: Int
    public var subject: String
    /// 레드마인 프로젝트 이름.
    public var project: String
    public var tracker: String
    public var status: String
    public var doneRatio: Int
    public var dueDate: String?
    /// `yyyy-MM-dd`. 옛 일지 파일에는 없다.
    public var startDate: String?
    public var statusID: Int?
    public var projectID: Int?
    public var assignee: RedmineAPI.Member?
    public var priority: String
    /// 맨 위 묶음을 뺀 조상 일감 이름 (위에서 아래로). `["데이터 수집", "공유 파일 관리"]`
    public var path: [String]
    public var isQA: Bool
    /// 나에게 배정돼 열려 있는지 (내 일감 목록에 보일지).
    public var assigned: Bool
    public var fetchedAt: Date

    public init(id: Int, subject: String, project: String, tracker: String = "", status: String = "", doneRatio: Int = 0,
                dueDate: String? = nil, priority: String = "", path: [String] = [], isQA: Bool = false,
                assigned: Bool = false, fetchedAt: Date = Date(), startDate: String? = nil, statusID: Int? = nil,
                projectID: Int? = nil, assignee: RedmineAPI.Member? = nil) {
        self.projectID = projectID
        self.assignee = assignee
        self.startDate = startDate
        self.statusID = statusID
        self.id = id
        self.subject = subject
        self.project = project
        self.tracker = tracker
        self.status = status
        self.doneRatio = doneRatio
        self.dueDate = dueDate
        self.priority = priority
        self.path = path
        self.isQA = isQA
        self.assigned = assigned
        self.fetchedAt = fetchedAt
    }

    /// 보고서 한 줄 이름. 잎 일감이 `API 연동`·`마크업`처럼 짧은 일 이름이면 화면 이름 뒤에 붙인다.
    /// `[FN-HUBADM-02]` 같은 기능 번호와 `[수정]` 머리는 보고서에 군더더기라 뗀다.
    public var reportTitle: String {
        let leaf = Self.cleanSubject(subject)
        guard let screen = path.last else { return leaf }
        let parents = path.dropLast()
        let tail = Self.isWorkName(leaf) ? "\(screen) \(leaf)" : "\(screen) > \(leaf)"
        return (parents + [tail]).joined(separator: " > ")
    }

    /// 화면 묶음 이름 (내 일감에서 묶어 보일 때).
    public var group: String { path.isEmpty ? "기타" : path.joined(separator: " > ") }

    /// `[수정][데이터셋관리] 이력 저장 기간…` → `이력 저장 기간…` (QA 건 이름은 대괄호 머리가 군더더기다)
    public static func cleanSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? subject : text
    }

    /// 일의 종류만 적은 잎 일감 이름.
    public static func isWorkName(_ text: String) -> Bool {
        let names = ["API 연동", "마크업", "퍼블리싱", "화면 개발", "화면개발", "기능 개발", "개발", "연동", "설계", "화면설계", "디자인"]
        return names.contains(text) || (text.count <= 8 && (text.hasSuffix("연동") || text.hasSuffix("마크업")))
    }

    /// 조상 사슬로 장부 한 줄을 만든다. 맨 위(부모가 없는) 일감은 `구현`·`시험` 같은 큰 갈래라 이름에서 뺀다.
    public static func build(_ issue: RedmineAPI.Issue, lookup: [Int: RedmineAPI.Issue], assigned: Bool,
                             now: Date = Date()) -> IssueInfo {
        var chain: [RedmineAPI.Issue] = []
        var next = issue.parentID
        var seen = Set<Int>()
        while let id = next, let parent = lookup[id], seen.insert(id).inserted {
            chain.insert(parent, at: 0)
            next = parent.parentID
        }
        let rootless = chain.first?.parentID == nil ? Array(chain.dropFirst()) : chain
        let qa = issue.tracker == "결함" || chain.contains { $0.tracker == "시험" || $0.subject.contains("테스트") || $0.subject.uppercased().contains("QA") }
        return IssueInfo(id: issue.id, subject: issue.subject, project: issue.project, tracker: issue.tracker,
                         status: issue.status, doneRatio: issue.doneRatio, dueDate: issue.dueDate, priority: issue.priority,
                         path: rootless.map { cleanSubject($0.subject) }, isQA: qa, assigned: assigned, fetchedAt: now,
                         startDate: issue.startDate, statusID: issue.statusID, projectID: issue.projectID, assignee: issue.assignee)
    }
}

/// 일감 번호가 없는 줄에 맞을 만한 일감을 고른다. 낱말이 겹치는 정도로 매긴다.
public enum IssueMatch {
    public static func suggest(_ title: String, in issues: [IssueInfo], limit: Int = 3) -> [IssueInfo] {
        let words = tokens(title)
        guard !words.isEmpty else { return [] }
        let scored = issues.compactMap { info -> (IssueInfo, Double)? in
            let target = tokens(info.reportTitle)
            let shared = words.intersection(target)
            // 일 이름(API, 연동, 마크업)만 겹치면 아무 일감이나 걸려 화면 낱말이 하나는 겹쳐야 한다
            guard shared.contains(where: { !generic.contains($0) }) else { return nil }
            return (info, Double(shared.count) / Double(words.count))
        }
        return scored.filter { $0.1 >= 0.3 }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id > $1.0.id }.prefix(limit).map(\.0)
    }

    private static let generic: Set<String> = ["api", "연동", "마크업", "화면", "수정", "추가", "반영", "개선", "목록", "상세", "관리"]

    static func tokens(_ text: String) -> Set<String> {
        Set(IssueInfo.cleanSubject(text).lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 })
    }
}
