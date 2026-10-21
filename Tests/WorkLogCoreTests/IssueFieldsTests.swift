import Foundation
import Testing
@testable import WorkLogCore

private let statuses = [
    RedmineAPI.Status(id: 1, name: "신규", isClosed: false),
    RedmineAPI.Status(id: 2, name: "진행", isClosed: false),
    RedmineAPI.Status(id: 3, name: "해결", isClosed: false),
    RedmineAPI.Status(id: 5, name: "완료", isClosed: true),
]

private func update(ratio: Int?, days: [String], needsNote: Bool = true) -> WorkReport.RedmineUpdate {
    WorkReport.RedmineUpdate(issue: 7, doneRatio: ratio, note: "n", entryIDs: [], needsNote: needsNote, days: days)
}

private func info(status: Int?, start: String? = nil, due: String? = nil) -> IssueInfo {
    IssueInfo(id: 7, subject: "s", project: "p", dueDate: due, startDate: start, statusID: status)
}

@Suite struct IssueFieldsTests {
    @Test func startsNewIssueAndFillsStartDate() {
        let fields = WorkReport.issueFields(for: update(ratio: 40, days: ["2026-10-19", "2026-10-20"]),
                                            current: info(status: 1), statuses: statuses, progressID: 2, doneID: 3)
        #expect(fields.status?.name == "진행")
        #expect(fields.startDate == "2026-10-19")
        #expect(fields.dueDate == nil)
    }

    @Test func finishingResolvesAndFillsDueDate() {
        let fields = WorkReport.issueFields(for: update(ratio: 100, days: ["2026-10-20"]),
                                            current: info(status: 2, start: "2026-10-01"), statuses: statuses, progressID: 2, doneID: 3)
        #expect(fields.status?.name == "해결")
        #expect(fields.startDate == nil)
        #expect(fields.dueDate == "2026-10-20")
    }

    @Test func neverMovesStatusBackOrOverwritesDates() {
        let fields = WorkReport.issueFields(for: update(ratio: 60, days: ["2026-10-20"]),
                                            current: info(status: 3, start: "2026-10-01", due: "2026-10-31"),
                                            statuses: statuses, progressID: 2, doneID: 3)
        #expect(fields.isEmpty)
    }

    @Test func leavesUnknownOrTimeOnlyIssuesAlone() {
        // 옛 장부는 시작일을 몰라 비어 있는 것처럼 보여도 채우지 않는다
        #expect(WorkReport.issueFields(for: update(ratio: 40, days: ["2026-10-20"]), current: info(status: nil),
                                       statuses: statuses, progressID: 2, doneID: 3).isEmpty)
        #expect(WorkReport.issueFields(for: update(ratio: 40, days: ["2026-10-20"], needsNote: false), current: info(status: 1),
                                       statuses: statuses, progressID: 2, doneID: 3).isEmpty)
    }

    @Test func keepsStartBeforeDue() {
        // 기한이 일지 첫날보다 이르면 시작일을 넣지 않는다 (레드마인이 422로 거절한다)
        let fields = WorkReport.issueFields(for: update(ratio: 40, days: ["2026-10-20"]), current: info(status: 2, due: "2026-10-10"),
                                            statuses: statuses, progressID: 2, doneID: 3)
        #expect(fields.startDate == nil)
    }

    @Test func guessesStatusesByName() {
        let guess = WorkReport.defaultStatuses(statuses)
        #expect(guess.progress == 2)
        #expect(guess.done == 5)
    }

    @Test func sendsOnlyChosenFields() throws {
        let base = try #require(RedmineAPI.baseURL("https://its.example.com"))
        let request = try RedmineAPI.updateRequest(base: base, key: "k", issue: 7, doneRatio: 100, note: "n",
                                                   fields: .init(status: statuses[2], dueDate: "2026-10-20"))
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: [String: Any]]
        #expect(body?["issue"]?["status_id"] as? Int == 3)
        #expect(body?["issue"]?["due_date"] as? String == "2026-10-20")
        #expect(body?["issue"]?["start_date"] == nil)
        let parsed = try RedmineAPI.parseStatuses(Data(#"{"issue_statuses":[{"id":5,"name":"완료","is_closed":true}]}"#.utf8))
        #expect(parsed == [statuses[3]])
    }
}

@Suite struct HiddenProjectTests {
    @Test func hidesFromListButKeepsRecordsAndOldFiles() throws {
        var log = WorkLog(projects: ["a", "b"])
        log.hiddenProjects = ["b"]
        log.hiddenRedmineProjects = ["목포"]
        #expect(log.visibleProjects == ["a"])
        #expect(log.allProjects == ["a", "b"])
        let decoded = try WorkLogFile.decode(WorkLogFile.encode(log))
        #expect(decoded.hiddenProjects == ["b"])
        #expect(decoded.hiddenRedmineProjects == ["목포"])
        // 숨기기가 없던 옛 파일도 읽는다
        let old = try WorkLogFile.decode(Data(#"{"projects":["a"],"entries":[]}"#.utf8))
        #expect(old.hiddenProjects.isEmpty)
    }
}

@Suite struct HiddenMergeTests {
    @Test func keepsHidingWhenFileChangedMeanwhile() {
        let base = WorkLog(projects: ["a", "b"])
        var mine = base
        mine.hiddenProjects = ["b"]
        mine.hiddenRedmineProjects = ["목포"]
        var disk = base
        disk.projects.append("c")
        let merged = WorkLog.merge(mine: mine, base: base, disk: disk)
        #expect(merged.hiddenProjects == ["b"])
        #expect(merged.hiddenRedmineProjects == ["목포"])
        #expect(merged.projects.contains("c"))
    }
}


/// 회사 레드마인의 실제 상태 목록 (2026-10-21). 목록 순서가 일의 흐름과 다르다.
private let company = [
    RedmineAPI.Status(id: 1, name: "할일", isClosed: false), RedmineAPI.Status(id: 2, name: "처리중", isClosed: false),
    RedmineAPI.Status(id: 7, name: "코드리뷰", isClosed: true), RedmineAPI.Status(id: 8, name: "테스트", isClosed: false),
    RedmineAPI.Status(id: 5, name: "완료", isClosed: true), RedmineAPI.Status(id: 6, name: "거절", isClosed: true),
    RedmineAPI.Status(id: 4, name: "반려", isClosed: false), RedmineAPI.Status(id: 3, name: "해결", isClosed: false),
]

@Suite struct CompanyRedmineTests {
    @Test func guessesCompanyStatuses() {
        let guess = WorkReport.defaultStatuses(company)
        #expect(guess.progress == 2)
        #expect(guess.done == 5)
    }

    @Test func finishingTodoMatchesHowCommentsWerePosted() {
        // 손으로 올린 #37827처럼: 할일 → 완료, 시작일·기한을 그날로
        let fields = WorkReport.issueFields(for: update(ratio: 100, days: ["2026-10-20"]), current: info(status: 1),
                                            statuses: company, progressID: 2, doneID: 5)
        #expect(fields.status?.name == "완료")
        #expect(fields.startDate == "2026-10-20")
        #expect(fields.dueDate == "2026-10-20")
    }

    @Test func leavesReviewTestAndRejectedAlone() {
        for status in [8, 4, 7] {
            let fields = WorkReport.issueFields(for: update(ratio: 100, days: ["2026-10-20"]),
                                                current: info(status: status, start: "2026-10-01", due: "2026-10-31"),
                                                statuses: company, progressID: 2, doneID: 5)
            #expect(fields.status == nil)
        }
        let progress = WorkReport.issueFields(for: update(ratio: 50, days: ["2026-10-20"]), current: info(status: 2, start: "2026-10-01"),
                                              statuses: company, progressID: 2, doneID: 5)
        #expect(progress.isEmpty)
    }
}

@Suite struct RedmineNoteTests {
    @Test func matchesHandWrittenHTML() {
        let note = "[작업 내용]\n- 차트 툴팁 0 제거(18.90000 → 18.9)\n- 이미 저장된 위젯도 적용\n\n[비고]\n- MR !106 dev 머지"
        #expect(RedmineNote.html(note) == """
        <p>[작업 내용]<br />
        - 차트 툴팁 0 제거(18.90000 → 18.9)<br />
        - 이미 저장된 위젯도 적용</p>
        <p>[비고]<br />
        - MR !106 dev 머지</p>
        """)
    }

    @Test func splitsSectionsWithoutBlankLinesAndEscapes() {
        let html = RedmineNote.html("[작업 내용]\n- a<b & c\n[연동 API]\n- GET /api/x")
        #expect(html == "<p>[작업 내용]<br />\n- a&lt;b &amp; c</p>\n<p>[연동 API]<br />\n- GET /api/x</p>")
        #expect(RedmineNote.html("<p>이미 HTML</p>") == "<p>이미 HTML</p>")
        #expect(RedmineNote.plain(html) == "[작업 내용]\n- a<b & c\n[연동 API]\n- GET /api/x")
    }
}

@Suite struct RedmineUndoTests {
    private let record = RedmineSent(issue: 7, sentAt: Date(timeIntervalSince1970: 1000), entryIDs: [], note: "<p>[작업 내용]<br />\n- a</p>",
                                     before: .init(doneRatio: 0, statusID: 1, startDate: nil, dueDate: "2026-10-31"),
                                     after: .init(doneRatio: 100, statusID: 5, startDate: "2026-10-20"))

    @Test func restoresOnlyWhatAppStillOwns() {
        // 진척률은 그 뒤 다른 사람이 90으로 바꿔 두고, 상태와 시작일만 되돌린다
        let revert = record.revert(current: .init(doneRatio: 90, statusID: 5, startDate: "2026-10-20", dueDate: "2026-10-31"))
        #expect(revert.doneRatio == nil)
        #expect(revert.statusID == 1)
        #expect(revert.startDate == "")
        #expect(revert.dueDate == nil)
    }

    @Test func findsTheSentJournal() {
        let journals = [
            RedmineAPI.Journal(id: 1, notes: "<p>[작업 내용]<br />\n- a</p>", createdOn: Date(timeIntervalSince1970: 0)),
            RedmineAPI.Journal(id: 2, notes: "", createdOn: Date(timeIntervalSince1970: 1001)),
            RedmineAPI.Journal(id: 3, notes: "<p>[작업 내용]<br />\n- a</p>", createdOn: Date(timeIntervalSince1970: 1002)),
        ]
        #expect(record.matchJournal(journals)?.id == 3)
    }

    @Test func readsJournalsAndRequests() throws {
        let data = Data(#"{"issue":{"id":7,"subject":"s","journals":[{"id":83741,"notes":"<p>x</p>","created_on":"2026-10-20T02:58:57Z"}]}}"#.utf8)
        #expect(try RedmineAPI.parseJournals(data).map(\.id) == [83741])
        let base = try #require(RedmineAPI.baseURL("https://its.example.com"))
        let clear = try RedmineAPI.clearJournalRequest(base: base, key: "k", journal: 83741)
        #expect(clear.url?.path == "/journals/83741.json")
        #expect(clear.httpMethod == "PUT")
        let revert = try RedmineAPI.revertRequest(base: base, key: "k", issue: 7, doneRatio: nil, statusID: 1, startDate: "", dueDate: nil)
        let body = try JSONSerialization.jsonObject(with: revert.httpBody!) as? [String: [String: Any]]
        #expect(body?["issue"]?["status_id"] as? Int == 1)
        #expect(body?["issue"]?["start_date"] as? String == "")
        #expect(body?["issue"]?["notes"] == nil)
        #expect(RedmineAPI.parseTimeEntryID(Data(#"{"time_entry":{"id":55}}"#.utf8)) == 55)
    }
}

@Suite struct IssueEditTests {
    private let me = RedmineAPI.Member(id: 182, name: "유민기")
    private let other = RedmineAPI.Member(id: 200, name: "최승희")

    @Test func pickedFieldsBeatAutoAndSameValuesDrop() {
        var current = info(status: 1, start: "2026-10-01")
        current.assignee = me
        let auto = WorkReport.IssueFields(status: company[4], startDate: nil, dueDate: "2026-10-20")
        let edit = WorkReport.IssueEdit(statusID: 8, startDate: "2026-10-01", dueDate: "", assignee: other)
        let fields = WorkReport.IssueFields.merged(auto: auto, edit: edit, current: current, statuses: company)
        #expect(fields.status?.name == "테스트")
        #expect(fields.startDate == nil)   // 지금과 같아 보내지 않는다
        #expect(fields.dueDate == nil)     // 비어 있는 기한을 비우는 것도 바뀌지 않음
        #expect(fields.assignee == other)
        let same = WorkReport.IssueFields.merged(auto: .init(), edit: .init(assignee: me), current: current, statuses: company)
        #expect(same.isEmpty)
    }

    @Test func warnsWhenStartAfterDue() {
        let fields = WorkReport.IssueFields(startDate: "2026-10-25")
        #expect(fields.problem(current: info(status: 1, due: "2026-10-20")) != nil)
        #expect(WorkReport.IssueFields(startDate: "2026-10-10").problem(current: info(status: 1, due: "2026-10-20")) == nil)
    }

    @Test func sendsAndRevertsAssigneeAndClearedDates() throws {
        let base = try #require(RedmineAPI.baseURL("https://its.example.com"))
        let request = try RedmineAPI.updateRequest(base: base, key: "k", issue: 7, doneRatio: nil, note: "n",
                                                   fields: .init(dueDate: "", assignee: other))
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: [String: Any]]
        #expect(body?["issue"]?["assigned_to_id"] as? Int == 200)
        #expect(body?["issue"]?["due_date"] as? String == "")
        let record = RedmineSent(issue: 7, entryIDs: [], note: "", before: .init(dueDate: "2026-10-31", assignee: me),
                                 after: .init(dueDate: "", assignee: other))
        // 레드마인은 비운 날짜를 null로 돌려준다
        let revert = record.revert(current: .init(dueDate: nil, assignee: other))
        #expect(revert.dueDate == "2026-10-31")
        #expect(revert.assigneeID == 182)
        let issues = try RedmineAPI.parseIssues(Data(#"{"issue":{"id":7,"subject":"s","project":{"id":360,"name":"p"},"assigned_to":{"id":182,"name":"유민기"},"start_date":null}}"#.utf8))
        #expect(issues.first?.assignee == me)
        #expect(issues.first?.projectID == 360)
        let members = try RedmineAPI.parseMembers(Data(#"{"memberships":[{"user":{"id":200,"name":"최승희"}},{"group":{"id":5,"name":"개발"}},{"user":{"id":182,"name":"유민기"}}]}"#.utf8))
        #expect(members == [me, other])
    }
}
