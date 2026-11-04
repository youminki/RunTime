import Foundation
import WorkLogCore

/// `--redmine-flow`: 레드마인 화면의 일을 가짜 응답으로 끝까지 돌려 나가는 요청을 살핀다.
/// 받기·트리·고치기·댓글·첨부·관계·지켜보기·새 일감·찾기는 앱 타깃에 있어 단위 시험이 닿지 않는다. 서버에는 아무것도 보내지 않는다.
@MainActor
enum RedmineFlowCheck {
    /// 설정을 읽기 전에 불러 가짜 응답 폴더를 가리킨다.
    static func prepare() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-redmine-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func issue(_ id: Int, parent: Int? = nil, assigned: Bool = true) -> String {
            let parentText = parent.map { #""parent":{"id":\#($0)},"# } ?? ""
            let assignee = assigned ? #""assigned_to":{"id":7,"name":"나"},"# : ""
            return #"{"id":\#(id),"project":{"id":1,"name":"시험"},"tracker":{"id":1,"name":"작업"},"status":{"id":1,"name":"할일"},"priority":{"id":2,"name":"보통"},\#(parentText)\#(assignee)"subject":"일감 \#(id)","done_ratio":0,"updated_on":"2026-11-01T00:00:00Z"}"#
        }
        let files: [String: String] = [
            "issues.json": #"{"issues":[\#(issue(10, parent: 2)),\#(issue(11, parent: 2))],"total_count":2,"offset":0,"limit":100}"#,
            "issues_10.json": #"{"issue":\#(issue(10, parent: 2).dropLast()),"description":"<ul><li>a</li></ul>","watchers":[],"journals":[]}}"#,
            "issues_123.json": #"{"issue":\#(issue(123))}"#,
            "created.json": #"{"issue":\#(issue(99))}"#,
            "uploads.json": #"{"upload":{"token":"tok.1"}}"#,
            "projects.json": #"{"projects":[{"id":1,"name":"시험","identifier":"t","trackers":[{"id":1,"name":"작업"}]}],"total_count":1}"#,
            "queries.json": #"{"queries":[],"total_count":0}"#,
            "trackers.json": #"{"trackers":[{"id":1,"name":"작업"}]}"#,
            "issue_statuses.json": #"{"issue_statuses":[{"id":1,"name":"할일","is_closed":false},{"id":2,"name":"완료","is_closed":true}]}"#,
            "enumerations_issue_priorities.json": #"{"issue_priorities":[{"id":2,"name":"보통"}]}"#,
            "users_current.json": #"{"user":{"id":7,"login":"me","firstname":"나","lastname":""}}"#,
            "memberships.json": #"{"memberships":[],"total_count":0,"offset":0,"limit":100}"#,
            "search.json": #"{"results":[{"id":10,"title":"작업 #10: 일감","type":"issue","url":"u"}],"total_count":1}"#,
        ]
        for (name, text) in files { try? Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        setenv("RUNTIME_REDMINE_FIXTURES", folder.path, 1)
        setenv("RUNTIME_REDMINE_URL", "https://example.com", 1)
        setenv("RUNTIME_REDMINE_KEY", "flow", 1)
        setenv("RUNTIME_NO_KEYCHAIN", "1", 1)
        return folder
    }

    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool) {
        print((ok ? "통과  " : "실패  ") + name)
        if !ok { failures += 1 }
    }

    private static func settle(_ seconds: Double = 0.5) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 지난번 뒤로 나간 쓰기 요청.
    private static func writes() -> [String] {
        let list = RedmineStore.fixtureWrites
        RedmineStore.fixtureWrites = []
        return list
    }

    static func run(folder: URL) {
        Task {
            await flow(folder: folder)
            print(failures == 0 ? "레드마인 흐름 모두 통과" : "레드마인 흐름 실패 \(failures)건")
            try? FileManager.default.removeItem(at: folder)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func flow(folder: URL) async {
        let store = RedmineStore.shared
        store.start()
        await settle()
        check("목록과 바탕 자료를 받는다", store.issues.count == 2 && store.projects.count == 1 && store.me?.id == 7)
        check("왼쪽 내 열린 일감 수", store.myOpenCounts[1] == 2)

        store.layout = .tree
        await settle()
        check("없는 상위는 받아 보고 못 찾은 번호는 다시 묻지 않는다", store.rows.count == 2)
        store.layout = .list

        store.selected = 10
        await settle()
        check("일감 창을 받는다", store.details[10]?.watchers != nil)

        store.update(10, Redmine.Change(statusID: 2))
        check("상태를 먼저 바꿔 보인다", store.details[10]?.status.id == 2)
        var second: Bool?
        store.update(10, Redmine.Change(notes: "겹침")) { second = $0 }
        check("저장 중에 또 보내면 거절한다", second == false)
        await settle()
        check("상태 변경이 한 번 나간다", writes() == ["PUT issues/10.json"])

        var sent: Bool?
        store.comment(10, text: "댓글", files: []) { sent = $0 }
        var again: Bool?
        store.comment(10, text: "댓글", files: []) { again = $0 }
        await settle()
        check("댓글이 한 번만 나간다", sent == true && again == false && writes() == ["PUT issues/10.json"])
        check("보내기가 끝나면 다시 쓸 수 있다", !store.isBusy(10))

        let file = folder.appendingPathComponent("첨부.txt")
        try? Data("a".utf8).write(to: file)
        var attached: Bool?
        store.comment(10, text: "", files: [file]) { attached = $0 }
        await settle()
        check("첨부를 올리고 댓글에 붙인다", attached == true && writes() == ["POST uploads.json", "PUT issues/10.json"])
        var missing: Bool?
        store.comment(10, text: "", files: [folder.appendingPathComponent("없음.txt")]) { missing = $0 }
        await settle()
        check("못 읽는 첨부는 아무것도 보내지 않는다", missing == false && writes().isEmpty && !store.isBusy(10))

        var related: Bool?
        store.addRelation(10, to: 11, type: "relates") { related = $0 }
        store.removeRelation(5, issue: 10)
        store.setWatching(10, true)
        await settle()
        check("관계·지켜보기 요청", related == true
              && writes().sorted() == ["DELETE relations/5.json", "POST issues/10/relations.json", "POST issues/10/watchers.json"])

        store.selected = nil
        store.search = "#123"
        store.submitSearch()
        await settle()
        check("#번호는 그 일감을 열고 찾는 말을 비운다", store.selected == 123 && store.search.isEmpty)
        store.selected = nil

        store.search = "일감"
        store.submitSearch()
        await settle()
        check("찾는 말은 모든 프로젝트에서 찾는다", store.results.map(\.id) == [10] && store.showsResults)
        store.showsResults = false
        store.search = ""

        var created: String??
        store.create(Redmine.NewIssue(projectID: 1, trackerID: 1, subject: "새 일감")) { created = .some($0) }
        await settle(0.8)
        check("새 일감을 만들고 연다", created == .some(nil) && store.selected == 99 && writes() == ["POST issues.json"])
    }
}
