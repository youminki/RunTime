import AppKit
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

    /// 작업 내역을 끝까지 모아 건수를 찍는다 (`--redmine-activity`). 읽기만 하며 서버 건수와 맞춰 보는 데 쓴다.
    static func activityCount() {
        Task {
            let store = RedmineStore.shared
            store.start()
            await settle(2)
            let started = Date()
            store.layout = .activity
            await settle(1)
            while store.activityLoading { await settle(0.5) }
            let times = store.activityItems.filter { if case .time = $0.kind { return true } else { return false } }.count
            print("작업 내역 \(store.activityItems.count)건 · 일감 \(store.activityProgress.total)건 · 소요시간 \(times)건 · 실패 \(store.activityFailed)건 · \(Int(Date().timeIntervalSince(started)))초")
            fflush(stdout)
            exit(0)
        }
    }

    /// 앱 창을 띄운 채 일감 창이 실제로 뜨고 닫히는지 본다 (`RUNTIME_SHEET_CHECK`). 시트는 띄워 봐야 알 수 있다.
    static func sheets() {
        Task {
            let store = RedmineStore.shared
            func sheet() -> NSWindow? { NSApp.windows.compactMap(\.attachedSheet).first }
            await settle(3)
            let id = store.issues[2].id
            store.selected = id
            await settle(1)
            let first = sheet()
            check("일감을 고르면 창이 뜬다", first != nil)
            store.move(1)
            await settle(1)
            check("앞뒤로 옮겨도 같은 창이 그대로다", sheet() === first && first != nil && store.selected != id)
            let issue = store.details[id]
            store.selected = nil
            await settle(1)
            check("닫으면 창이 사라진다", sheet() == nil)
            if let issue {
                store.selected = issue.id
                await settle(1)
                store.createChild(of: issue)
                await settle(1.2)
                check("하위 일감 창으로 넘어간다", sheet() != nil && store.creating && store.selected == nil)
            }
            var made: String??
            store.create(Redmine.NewIssue(projectID: 1, trackerID: 1, subject: "새 일감")) { error in
                made = .some(error)
                store.creating = false
            }
            await settle(2)
            check("만든 뒤 새 일감 창이 닫히고 그 일감이 열린다", made == .some(nil) && !store.creating && store.selected != nil && sheet() != nil)
            print(failures == 0 ? "창 전환 모두 통과" : "창 전환 실패 \(failures)건")
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

        var edited: Bool?
        store.editJournal(5, issue: 10, notes: "고침") { edited = $0 }
        store.deleteAttachment(9, issue: 10)
        await settle()
        check("댓글 고치기와 첨부 지우기 요청", edited == true && writes().sorted() == ["DELETE attachments/9.json", "PUT journals/5.json"])
        var hidden: Bool?
        store.comment(10, text: "비밀", files: [], isPrivate: true) { hidden = $0 }
        await settle()
        check("비공개 댓글을 보낸다", hidden == true && writes() == ["PUT issues/10.json"])
        store.update(10, Redmine.Change(trackerID: 1, estimatedHours: 8))
        await settle()
        check("트래커와 추정 시간을 고친다", writes() == ["PUT issues/10.json"] && !store.isBusy(10))
        store.selected = nil
        store.refine[.tracker] = "없는 트래커"
        check("칸 값으로 거른다", store.rows.isEmpty)
        store.refine = [:]
        store.grouping = .assignee
        check("담당자로 묶는다", store.groups.count == 1 && store.groups[0].rows.count == 2)
        store.grouping = .none
        let written = writes().count
        store.layout = .activity
        await settle(0.8)
        check("작업 내역은 읽기만 하고 끝난다", !store.activityLoading && writes().count == written)
        store.layout = .list
        store.checked = [10, 11]
        store.search = "일감 11"
        check("찾기로 가린 일감은 고칠 대상에서 빠진다", store.checkedVisible == [11])
        store.updateChecked(Redmine.Change(doneRatio: 40))
        await settle(0.8)
        check("가린 일감은 고치지 않는다", writes() == ["PUT issues/11.json"])
        store.search = ""
        store.checked = [10, 11]
        store.updateChecked(Redmine.Change(doneRatio: 50))
        await settle(0.8)
        check("고른 일감을 차례로 고친다", writes() == ["PUT issues/10.json", "PUT issues/11.json"] && store.checked.isEmpty)
        store.deleteIssue(10)
        await settle()
        check("일감을 지우면 창을 닫는다", writes() == ["DELETE issues/10.json"] && store.selected == nil)

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
