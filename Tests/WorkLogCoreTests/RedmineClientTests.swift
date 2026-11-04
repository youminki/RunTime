import Foundation
import Testing
@testable import WorkLogCore

// 레드마인 4.x가 돌려주는 꼴을 줄인 예시 (이름·내용은 지어낸 값)
private let issueJSON = #"""
{"issue":{"id":101,"project":{"id":7,"name":"예시 프로젝트"},"tracker":{"id":5,"name":"안정화"},
"status":{"id":1,"name":"할일"},"priority":{"id":2,"name":"보통"},"author":{"id":9,"name":"김작성"},
"assigned_to":{"id":3,"name":"이담당"},"parent":{"id":100},"subject":"목록 정렬 오류","description":"<p>재현 절차</p>",
"start_date":"2026-11-02","due_date":null,"done_ratio":30,"estimated_hours":null,"spent_hours":0.0,
"created_on":"2026-11-02T01:00:00Z","updated_on":"2026-11-03T02:30:00Z","closed_on":null,
"journals":[{"id":1,"user":{"id":3,"name":"이담당"},"notes":"<p>확인했습니다</p>","created_on":"2026-11-03T02:30:00Z",
"details":[{"property":"attr","name":"status_id","old_value":"1","new_value":"2"},{"property":"attr","name":"done_ratio","old_value":"0","new_value":"30"}]}],
"attachments":[{"id":11,"filename":"화면.png","filesize":2048,"content_type":"image/png","content_url":"https://example.com/attachments/download/11/a.png","author":{"id":3,"name":"이담당"},"created_on":"2026-11-03T02:00:00Z"}],
"children":[{"id":102,"tracker":{"id":5,"name":"안정화"},"subject":"하위"}],
"relations":[{"id":1,"issue_id":101,"issue_to_id":120,"relation_type":"blocks","delay":null},{"id":2,"issue_id":130,"issue_to_id":101,"relation_type":"precedes","delay":0}],
"watchers":[{"id":4,"name":"박지켜"}]}}
"""#

@Suite struct RedmineClientTests {
    @Test func decodesAFullIssue() throws {
        let issue = try Redmine.issue(Data(issueJSON.utf8))
        #expect(issue.id == 101 && issue.tracker.name == "안정화" && issue.assignedTo?.name == "이담당")
        #expect(issue.parent?.id == 100 && issue.dueDate == nil && issue.doneRatio == 30)
        #expect(issue.journals?.first?.details?.count == 2)
        #expect(issue.attachments?.first?.isImage == true)
        #expect(issue.children?.first?.subject == "하위")
        #expect(issue.watchers?.map(\.name) == ["박지켜"])
        #expect(issue.updated != nil)
    }

    @Test func describesRelationsFromEitherSide() throws {
        let relations = try #require(try Redmine.issue(Data(issueJSON.utf8)).relations)
        #expect(relations[0].describe(from: 101) == (120, "막음"))
        #expect(relations[1].describe(from: 101) == (130, "뒤따름"))
    }

    @Test func describesJournalChangesWithNames() throws {
        let issue = try Redmine.issue(Data(issueJSON.utf8))
        let statuses = [Redmine.Status(id: 1, name: "할일", isClosed: false), Redmine.Status(id: 2, name: "처리중", isClosed: false)]
        let details = try #require(issue.journals?.first?.details)
        #expect(Redmine.describe(details[0], statuses: statuses, trackers: [], priorities: [], people: []) == "상태: 할일 → 처리중")
        #expect(Redmine.describe(details[1], statuses: statuses, trackers: [], priorities: [], people: []) == "진척률: 0% → 30%")
        let person = Redmine.Detail(property: "attr", name: "assigned_to_id", oldValue: nil, newValue: "3")
        #expect(Redmine.describe(person, statuses: [], trackers: [], priorities: [], people: [Redmine.Ref(id: 3, name: "이담당")]) == "담당자: 없음 → 이담당")
        let file = Redmine.Detail(property: "attachment", name: "11", oldValue: nil, newValue: "화면.png")
        #expect(Redmine.describe(file, statuses: [], trackers: [], priorities: [], people: []) == "첨부 화면.png 추가")
    }

    @Test func filtersUseSavedQueryAsIs() {
        func query(_ filter: Redmine.Filter) -> [String: String] {
            Dictionary(uniqueKeysWithValues: filter.items.map { ($0.name, $0.value ?? "") })
        }
        #expect(query(Redmine.Filter(assignedToMe: true)) == ["sort": "updated_on:desc", "status_id": "open", "assigned_to_id": "me"])
        // 저장한 질의는 상태 조건을 덧붙이지 않는다 (질의가 닫힌 일감을 가리킬 수 있다)
        #expect(query(Redmine.Filter(queryID: 5, projectID: 7)) == ["sort": "updated_on:desc", "query_id": "5", "project_id": "7"])
        let request = Redmine.issuesRequest(base: URL(string: "https://example.com")!, key: "k", filter: Redmine.Filter(), offset: 100)
        #expect(request.url?.absoluteString.contains("offset=100") == true)
        #expect(request.value(forHTTPHeaderField: "X-Redmine-API-Key") == "k")
    }

    @Test func changeSendsOnlyEditedFields() throws {
        #expect(Redmine.Change().isEmpty)
        #expect(Redmine.Change(notes: "   ").isEmpty)
        let fields = Redmine.Change(doneRatio: 60, assignedToID: 0, dueDate: "", notes: "[작업 내용]\n- 정렬 수정").fields
        #expect(fields["done_ratio"] as? Int == 60)
        #expect(fields["assigned_to_id"] as? String == "")          // 담당자 비우기
        #expect(fields["due_date"] as? String == "")                 // 기한 비우기
        #expect((fields["notes"] as? String)?.hasPrefix("<p>[작업 내용]") == true)
        #expect(fields["status_id"] == nil)
        let request = try Redmine.updateRequest(base: URL(string: "https://example.com")!, key: "k", id: 101,
                                                change: Redmine.Change(statusID: 2))
        #expect(request.httpMethod == "PUT" && request.url?.path == "/issues/101.json")
    }

    @Test func appliesChangeBeforeTheServerAnswers() throws {
        let issue = try Redmine.issue(Data(issueJSON.utf8))
        let statuses = [Redmine.Status(id: 4, name: "테스트", isClosed: false)]
        let people = [Redmine.Ref(id: 8, name: "최새담당")]
        let after = Redmine.Change(statusID: 4, doneRatio: 100, assignedToID: 8, startDate: "", dueDate: "2026-11-07")
            .applied(to: issue, statuses: statuses, priorities: [], people: people)
        #expect(after.status.name == "테스트" && after.doneRatio == 100 && after.assignedTo?.name == "최새담당")
        #expect(after.startDate == nil && after.dueDate == "2026-11-07")
        // 모르는 상태 번호면 화면 값은 그대로 둔다 (보낸 뒤 받은 값으로 바뀐다)
        #expect(Redmine.Change(statusID: 99).applied(to: issue, statuses: statuses, priorities: [], people: []).status.name == "할일")
        #expect(Redmine.Change(assignedToID: 0).applied(to: issue, statuses: [], priorities: [], people: []).assignedTo == nil)
    }

    @Test func readsListsAndAccount() throws {
        let page = #"{"issues":[],"total_count":179,"offset":0,"limit":100}"#
        #expect(try Redmine.issues(Data(page.utf8)).total == 179)
        let members = #"{"memberships":[{"user":{"id":2,"name":"나"}},{"group":{"id":5,"name":"개발팀"}},{"user":{"id":1,"name":"가"}},{"user":{"id":2,"name":"나"}}]}"#
        #expect(try Redmine.members(Data(members.utf8)).map(\.name) == ["가", "나"])
        let me = #"{"user":{"id":182,"login":"mk","firstname":"민기","lastname":"유"}}"#
        #expect(try Redmine.currentUser(Data(me.utf8)) == Redmine.Ref(id: 182, name: "유민기"))
        #expect(Redmine.errors(Data(#"{"errors":["상태는 바꿀 수 없습니다"]}"#.utf8)) == ["상태는 바꿀 수 없습니다"])
        #expect(Redmine.errors(nil).isEmpty)
        #expect(Redmine.isStatusRejection(["상태 은(는) 목록에 포함되어 있지 않습니다"]))
        #expect(Redmine.isStatusRejection(["Status is not included in the list"]))
        #expect(!Redmine.isStatusRejection(["완료 기한은(는) 시작일보다 뒤여야 합니다"]))
        #expect(!Redmine.isStatusRejection(["개발상태 은(는) 비어있을 수 없습니다"]))
    }
}

@Suite struct RedmineTreeTests {
    private func issue(_ id: Int, parent: Int? = nil) -> Redmine.Issue {
        Redmine.Issue(id: id, project: .init(id: 1, name: "p"), tracker: .init(id: 1, name: "작업"), status: .init(id: 1, name: "할일"),
                      priority: .init(id: 2, name: "보통"), author: nil, assignedTo: nil, parent: parent.map { .init(id: $0) },
                      subject: "#\(id)", description: nil, startDate: nil, dueDate: nil, doneRatio: 0, estimatedHours: nil,
                      spentHours: nil, createdOn: nil, updatedOn: nil, closedOn: nil, journals: nil, attachments: nil,
                      children: nil, relations: nil, watchers: nil)
    }

    @Test func nestsChildrenUnderParentsInListOrder() {
        // 받은 순서: 하위가 상위보다 먼저 와도 상위 아래로 간다
        let rows = Redmine.tree([issue(3, parent: 1), issue(1), issue(2), issue(4, parent: 3), issue(5, parent: 1)])
        #expect(rows.map(\.id) == [1, 3, 4, 5, 2])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 0])
        #expect(rows.first?.hasChildren == true && rows.last?.hasChildren == false)
    }

    @Test func parentOutsideTheListMakesARoot() {
        let rows = Redmine.tree([issue(7, parent: 99), issue(8, parent: 7)])
        #expect(rows.map(\.id) == [7, 8] && rows.map(\.depth) == [0, 1])
    }

    @Test func collapsingHidesDescendants() {
        let all = [issue(1), issue(2, parent: 1), issue(3, parent: 2), issue(4)]
        #expect(Redmine.tree(all, collapsed: [1]).map(\.id) == [1, 4])
        #expect(Redmine.tree(all, collapsed: [2]).map(\.id) == [1, 2, 4])
    }

    @Test func survivesParentCycles() {
        let rows = Redmine.tree([issue(1, parent: 2), issue(2, parent: 1)])
        #expect(Set(rows.map(\.id)) == [1, 2])
        #expect(rows.count == 2)
    }
}

@Suite struct SafeHTMLTests {
    @Test func dropsElementsThatFetchOrRun() {
        #expect(RedmineNote.safeHTML("<p>a</p><script>alert(1)</script>after") == "<p>a</p>after")
        #expect(RedmineNote.safeHTML("<style>p{color:red}</style>x") == "x")
        #expect(RedmineNote.safeHTML(#"<svg><image href="http://e/x.png"/></svg>y"#) == "y")
        #expect(RedmineNote.safeHTML(#"<p>보기 <img src="http://e/a.png" alt="a>b"> 끝</p>"#) == "<p>보기 [이미지] 끝</p>")
        #expect(RedmineNote.safeHTML(#"<image src=http://e/b.png>"#) == "[이미지]")
        #expect(RedmineNote.safeHTML(#"<input type="image" src="http://e/c.png">z"#) == "z")
        #expect(RedmineNote.safeHTML(#"<td background="http://e/d.png">c</td>"#) == "<td>c</td>")
        #expect(RedmineNote.safeHTML(#"<p style="background:url(http://e/e.png)">d</p>"#) == #"<p style="background:">d</p>"#)
    }

    @Test func keepsOrdinaryMarkup() {
        let html = #"<p>[작업 내용]<br />- <strong>목록</strong> <a href="https://example.com">링크</a></p><ol><li>하나</li></ol>"#
        #expect(RedmineNote.safeHTML(html) == html)
    }
}
