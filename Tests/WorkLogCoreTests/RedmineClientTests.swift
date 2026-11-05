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

    /// 평문으로 고칠 수 있는 설명만 평문을 준다. 나머지는 nil이라 HTML 그대로 고친다.
    @Test func descriptionEditableOnlyWhenLossless() {
        #expect(RedmineNote.editable("<p>첫 문단</p>\n<p>둘째<br />\n줄</p>") == "첫 문단\n\n둘째\n줄")
        #expect(RedmineNote.editable("평문 설명") == "평문 설명")
        #expect(RedmineNote.editable("") == "")
        #expect(RedmineNote.editable("<p>a &lt; b &amp; c</p>") == "a < b & c")
        for html in ["<ul><li>하나</li><li>둘</li></ul>", "<table><tr><td>a</td></tr></table>",
                     #"<a href="https://x.y/z">링크</a>"#, #"<p><img src="a.png"></p>"#, #"<p style="color:red">a</p>"#,
                     "&ldquo;인용&rdquo;", "a < b 이고 c > d 이다", "&lt;p&gt;태그 설명"] {
            #expect(RedmineNote.editable(html) == nil, "\(html)")
        }
        #expect(Redmine.Change(notes: "a\nb", notesRaw: true).fields["notes"] as? String == "a\nb")
        var plain = Redmine.NewIssue(projectID: 1, trackerID: 1, subject: "s")
        plain.description = "a\nb"
        plain.descriptionRaw = true
        #expect(plain.fields["description"] as? String == "a\nb")
        let raw = Redmine.Change(description: "<ul><li>a</li></ul>", descriptionRaw: true)
        #expect(raw.fields["description"] as? String == "<ul><li>a</li></ul>")
        #expect(Redmine.Change(description: "a").fields["description"] as? String == "<p>a</p>")
    }

    @Test func activityMergesIssueHistory() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let text = #"{"id":7,"project":{"id":1,"name":"p"},"tracker":{"id":1,"name":"t"},"status":{"id":1,"name":"s"},"priority":{"id":2,"name":"n"},"author":{"id":1,"name":"가"},"subject":"일감","done_ratio":0,"created_on":"2026-11-02T00:00:00Z","journals":[{"id":1,"user":{"id":2,"name":"나"},"notes":"옛 댓글","created_on":"2026-10-01T00:00:00Z"},{"id":2,"user":{"id":2,"name":"나"},"notes":"","created_on":"2026-11-03T00:00:00Z","details":[{"property":"attr","name":"status_id"}]},{"id":3,"user":{"id":3,"name":"다"},"notes":"새 댓글","created_on":"2026-11-04T00:00:00Z"},{"id":4,"user":{"id":3,"name":"다"},"notes":"","created_on":"2026-11-04T01:00:00Z"}]}"#
        let issue = try decoder.decode(Redmine.Issue.self, from: Data(text.utf8))
        let since = try #require(Redmine.date("2026-11-01T00:00:00Z"))
        let items = Redmine.activity([issue], since: since)
        #expect(items.map(\.id) == ["7-3", "7-2", "7-new"])
        #expect(items[0].user == "다" && items[0].notes == "새 댓글" && items[2].created)
    }

    @Test func bodyImagesMatchAttachments() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let list = try decoder.decode([Redmine.Attachment].self, from: Data(#"[{"id":1,"filename":"a b.png","filesize":1,"content_type":"image/png"},{"id":2,"filename":"c.pdf","filesize":1,"content_type":"application/pdf"}]"#.utf8))
        let html = #"<p><img alt="x" src="a%20b.png" /><img src='https://h/attachments/download/2/c.pdf'><img src="없음.png"></p>"#
        #expect(RedmineNote.imageSources(html).count == 3)
        #expect(Redmine.images(in: html, attachments: list).map(\.id) == [1])
    }

    @Test func commentAndIssueExtras() throws {
        let base = URL(string: "https://example.com")!
        let change = Redmine.Change(notes: "a", privateNotes: true, trackerID: 3, estimatedHours: 2.5)
        #expect(change.fields["private_notes"] as? Bool == true && change.fields["tracker_id"] as? Int == 3)
        #expect(change.fields["estimated_hours"] as? String == "2.5")
        #expect(Redmine.Change(estimatedHours: 0).fields["estimated_hours"] as? String == "")
        #expect(try Redmine.deleteIssueRequest(base: base, key: "k", id: 9).httpMethod == "DELETE")
        #expect(try Redmine.deleteAttachmentRequest(base: base, key: "k", id: 9).url?.path == "/attachments/9.json")
        let edit = try Redmine.editJournalRequest(base: base, key: "k", journal: 5, notes: "")
        #expect(edit.httpMethod == "PUT" && edit.url?.path == "/journals/5.json")
        let journal = #"{"id":1,"created_on":"2026-11-01T00:00:00Z","private_notes":true,"details":[{"property":"attachment","name":"77","new_value":"a.png"},{"property":"attachment","name":"78","old_value":"b.png"},{"property":"attr","name":"status_id"}]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parsed = try decoder.decode(Redmine.Journal.self, from: Data(journal.utf8))
        #expect(parsed.attachmentIDs == [77] && parsed.privateNotes == true)
    }

    @Test func requestsForRelationsWatchersAndSearch() throws {
        let base = URL(string: "https://example.com")!
        let add = try Redmine.addRelationRequest(base: base, key: "k", issue: 1, to: 2, type: "blocks")
        #expect(add.httpMethod == "POST" && add.url?.path == "/issues/1/relations.json")
        let remove = try Redmine.removeRelationRequest(base: base, key: "k", relation: 9)
        #expect(remove.httpMethod == "DELETE" && remove.url?.path == "/relations/9.json")
        #expect(try Redmine.watchRequest(base: base, key: "k", issue: 1, user: 3, on: true).url?.path == "/issues/1/watchers.json")
        #expect(try Redmine.watchRequest(base: base, key: "k", issue: 1, user: 3, on: false).url?.path == "/issues/1/watchers/3.json")
        #expect(Redmine.issueNumber(" #123 ") == 123 && Redmine.issueNumber("123") == 123)
        #expect(Redmine.issueNumber("API") == nil && Redmine.issueNumber("#0") == nil)
        let found = #"{"results":[{"id":1,"title":"작업 #1: 목록","type":"issue","url":"u"},{"id":2,"title":"닫힘","type":"issue-closed","url":"u"},{"id":3,"title":"위키","type":"wiki-page","url":"u"}]}"#
        #expect(try Redmine.found(Data(found.utf8)).map(\.id) == [1, 2])
        #expect(Redmine.foundTotal(Data(#"{"results":[],"total_count":120}"#.utf8)) == 120)
        let upload = RedmineAPI.Upload(token: "t", filename: "a.png", contentType: "image/png")
        let change = Redmine.Change(notes: "", uploads: [upload])
        #expect(!change.isEmpty && (change.fields["uploads"] as? [[String: String]])?.first?["token"] == "t")
        #expect(Redmine.Change(description: "").fields["description"] as? String == "")
    }

    @Test func newIssueSendsOnlyWhatWasFilled() throws {
        var issue = Redmine.NewIssue(projectID: 7, trackerID: 5, subject: "  목록 오류  ")
        #expect(issue.isValid)
        #expect(issue.fields["subject"] as? String == "목록 오류")
        #expect(issue.fields["description"] == nil && issue.fields["parent_issue_id"] == nil)
        issue.description = "재현 절차"
        issue.parentID = 100
        issue.dueDate = "2026-11-07"
        #expect((issue.fields["description"] as? String)?.hasPrefix("<p>") == true)
        #expect(issue.fields["parent_issue_id"] as? Int == 100)
        let request = try Redmine.createRequest(base: URL(string: "https://example.com")!, key: "k", issue: issue)
        #expect(request.httpMethod == "POST" && request.url?.path == "/issues.json")
        #expect(!Redmine.NewIssue(projectID: 7, trackerID: 5, subject: "   ").isValid)
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

    /// 내 일감의 상위는 남의 일감이라 목록에 없다. 상위를 끼워 넣어야 트리가 트리로 보인다.
    @Test func insertsParentsAsContext() {
        let mine = [issue(10, parent: 2), issue(20, parent: 3), issue(11, parent: 2)]
        // 상위 1 아래 2·3, 쓰이지 않는 상위 9는 뺀다
        let context = [issue(1), issue(2, parent: 1), issue(3, parent: 1), issue(9)]
        let rows = Redmine.tree(mine, context: context)
        #expect(rows.map(\.id) == [1, 2, 10, 11, 3, 20])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 1, 2])
        #expect(rows.map(\.isContext) == [true, true, false, false, true, false])
        #expect(Redmine.tree(mine, context: context, collapsed: [2]).map(\.id) == [1, 2, 3, 20])
    }

    @Test func keepsListOrderAcrossBranches() {
        let mine = [issue(20, parent: 3), issue(10, parent: 2)]
        let rows = Redmine.tree(mine, context: [issue(2), issue(3)])
        #expect(rows.map(\.id) == [3, 20, 2, 10])
    }

    @Test func timelineBars() {
        let from = Redmine.dayNumber("2026-11-02")!
        #expect(Redmine.monday(of: from) == from)
        #expect(Redmine.monday(of: Redmine.dayNumber("2026-11-08")!) == from)
        #expect(Redmine.dayNumber("2026-02-30") == nil && Redmine.dayNumber(nil) == nil)
        #expect(Redmine.bar(start: "2026-11-03", due: "2026-11-05", from: from, days: 14) == .init(offset: 1, length: 3))
        // 한쪽 날짜만, 뒤바뀐 날짜, 창에 걸친 기간, 창 밖
        #expect(Redmine.bar(start: nil, due: "2026-11-04", from: from, days: 14) == .init(offset: 2, length: 1))
        #expect(Redmine.bar(start: "2026-11-05", due: "2026-11-03", from: from, days: 14) == .init(offset: 3, length: 1))
        #expect(Redmine.bar(start: "2026-10-01", due: "2026-12-31", from: from, days: 14) == .init(offset: 0, length: 14))
        #expect(Redmine.bar(start: "2026-11-16", due: "2026-11-20", from: from, days: 14) == nil)
        #expect(Redmine.bar(start: "2026-10-01", due: "2026-11-01", from: from, days: 14) == nil)
        #expect(Redmine.bar(start: nil, due: nil, from: from, days: 14) == nil)
        #expect(Redmine.weeks(from: from, days: 14).map(\.label) == ["11.2", "11.9"])
        #expect(Redmine.weeks(from: from + 1, days: 14).map(\.offset) == [6, 13])
    }

    /// 앱이 받는 최대치(1000건)를 그리는 동안 트리를 만들어도 한 프레임을 넘기지 않아야 한다.
    @Test func treeStaysFastAtListLimit() {
        let parents = (1...200).map { issue($0) }
        let list = (1001...2000).map { issue($0, parent: ($0 % 200) + 1) }
        let started = Date()
        for _ in 0..<10 { #expect(Redmine.tree(list, context: parents).count == 1200) }
        #expect(Date().timeIntervalSince(started) / 10 < 0.016)
    }

    /// 빠른 거르기로 목록 안 상위가 빠져도 하위가 맨 위로 올라가지 않는다.
    @Test func filteredOutParentStaysAsContext() {
        let rows = Redmine.tree([issue(2, parent: 1)], context: [issue(1), issue(2, parent: 1)])
        #expect(rows.map(\.id) == [1, 2] && rows.map(\.isContext) == [true, false])
    }

    @Test func findsParentsStillToFetch() {
        let list = [issue(10, parent: 2), issue(11, parent: 10), issue(12, parent: 3)]
        #expect(Redmine.missingParents(list, known: [3]) == [2])
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

    @Test func decodesEntitiesAndShortensLinks() {
        #expect(RedmineNote.decodeEntities("&quot;a&quot; &middot; b &amp;lt;") == "\"a\" · b &lt;")
        #expect(RedmineNote.plain("<p>a &quot;b&quot;</p>") == "a \"b\"")
        let long = URL(string: "https://www.figma.com/design/abcdefghijklmnopqrstuvwxyz/-UxHub-%ED%99%94%EB%A9%B4?node-id=1")!
        #expect(RedmineNote.linkLabel(long) == "Figma 열기")
        let other = URL(string: "https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")!
        #expect(RedmineNote.linkLabel(other) == "example.com/aaaaaaaaaaaaaaaaaaaaaaa…")
        let short = URL(string: "https://example.com/a")!
        #expect(RedmineNote.linkLabel(short) == "https://example.com/a")
    }

    @Test func keepsOrdinaryMarkup() {
        let html = #"<p>[작업 내용]<br />- <strong>목록</strong> <a href="https://example.com">링크</a></p><ol><li>하나</li></ol>"#
        #expect(RedmineNote.safeHTML(html) == html)
    }
}
