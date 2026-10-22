import Foundation
import Testing
@testable import WorkLogCore

struct RatioEditTests {

    private func update(_ status: WorkStatus) -> WorkReport.RedmineUpdate {
        let entry = WorkEntry(day: "2026-10-22", project: "P", title: "일", status: status, issue: 1, note: "- 일")
        return WorkReport.redmineUpdates([entry])[0]
    }

    @Test func inProgressGetsDefaultRatioButOngoingDoesNot() {
        #expect(update(.inProgress).inProgress)
        #expect(update(.inProgress).withInProgressRatio(30).doneRatio == 30)
        #expect(update(.ongoing).withInProgressRatio(30).doneRatio == nil)
        #expect(update(.percent(60)).withInProgressRatio(30).doneRatio == 60)
        #expect(update(.inProgress).withInProgressRatio(nil).doneRatio == nil)
    }

    @Test func pickedRatioWins() {
        let edit = WorkReport.IssueEdit(doneRatio: 100)
        #expect(!edit.isEmpty)
        #expect(edit.applied(to: update(.inProgress).withInProgressRatio(30)).doneRatio == 100)
        #expect(edit.applied(to: update(.percent(60))).doneRatio == 100)
        #expect(WorkReport.IssueEdit().applied(to: update(.percent(60))).doneRatio == 60)
    }

    @Test func pickingHundredMovesStatusToDone() {
        let statuses = [RedmineAPI.Status(id: 1, name: "할일", isClosed: false), RedmineAPI.Status(id: 2, name: "처리중", isClosed: false),
                        RedmineAPI.Status(id: 5, name: "완료", isClosed: true)]
        var current = IssueInfo(id: 1, subject: "일", project: "P")
        current.statusID = 1
        current.status = "할일"
        let edited = WorkReport.IssueEdit(doneRatio: 100).applied(to: update(.inProgress))
        let fields = WorkReport.issueFields(for: edited, current: current, statuses: statuses, progressID: 2, doneID: 5)
        #expect(fields.status?.id == 5)
    }
}
