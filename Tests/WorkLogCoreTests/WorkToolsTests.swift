import Foundation
import Testing
@testable import WorkLogCore

@Suite struct WorkToolsTests {
    @Test func ordersOngoingDoneThenProgress() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "A", title: "진행", status: .percent(30)),
            WorkEntry(day: "2026-10-20", project: "A", title: "끝", status: .done),
            WorkEntry(day: "2026-10-20", project: "A", title: "회의", status: .ongoing),
            WorkEntry(day: "2026-10-20", project: "A", title: "많이", status: .percent(80)),
        ]
        let log = WorkLog(projects: ["A"], entries: entries)
        #expect(WorkReport.daily(entries, in: log, doneFirst: true)
                == "1. A\n- 회의 (상시)\n- 끝 (완료)\n- 많이 (80%)\n- 진행 (30%)")
    }

    @Test func weeklyAddsNextWeekPlan() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "A", title: "끝", status: .done),
            WorkEntry(day: "2026-10-21", project: "A", title: "이어서", status: .percent(60)),
        ]
        let log = WorkLog(projects: ["A"], entries: entries)
        let text = WorkReport.weekly(entries, in: log, week: WorkDay.week(of: "2026-10-20"), nextWeekPlan: true)
        #expect(text.hasSuffix("[차주 계획]\n1. A\n- 이어서 (60%)"))
    }

    @Test func recurringWorkIsAddedOncePerMatchingDay() {
        var log = WorkLog()
        log.recurring = [RecurringWork(project: "uxhub", title: "주간 회의", weekdays: [2])]   // 월요일
        #expect(log.applyRecurring(on: "2026-10-19") == 1)
        #expect(log.applyRecurring(on: "2026-10-19") == 0)
        #expect(log.applyRecurring(on: "2026-10-20") == 0)   // 화요일
        log.remove(log.entries[0].id)
        #expect(log.applyRecurring(on: "2026-10-19") == 0)   // 지운 날은 되살리지 않는다
    }

    @Test func estimatesHoursFromClaudeCodeFolders() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "velox", title: "a", issue: 1, source: "mr:velox/velox-web-portal!14"),
            WorkEntry(day: "2026-10-20", project: "velox", title: "b", issue: 2, source: "branch:velox/velox-web-portal:feat/b"),
            WorkEntry(day: "2026-10-20", project: "cdh", title: "c", issue: 3, source: "mr:cdh/cdh-web-admin!109"),
            WorkEntry(day: "2026-10-20", project: "cdh", title: "회의"),
        ]
        let hours = WorkTime.suggest(entries, minutesByFolder: ["velox-web-portal": 190, "cdh-web-admin": 10])
        #expect(hours == [1: 1.5, 2: 1.5, 3: 0.25])
        #expect(WorkTime.label(1.5) == "1.5h")
        #expect(WorkTime.label(2) == "2h")
    }

    @Test func redmineUpdateCarriesUnloggedHoursOnly() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "A", title: "a", issue: 5, hours: 1.5),
            WorkEntry(day: "2026-10-21", project: "A", title: "b", issue: 5, hours: 2, timeLogged: true),
        ]
        let update = WorkReport.redmineUpdates(entries)[0]
        #expect(update.hours == 1.5)
        #expect(update.timeEntries == [WorkReport.TimeEntry(day: "2026-10-20", hours: 1.5, entryIDs: [entries[0].id])])
    }

    @Test func timeIsSplitPerDayAndRetriedWithoutResendingComment() {
        var monday = WorkEntry(day: "2026-10-19", project: "A", title: "a", issue: 5, hours: 1)
        let tuesday = WorkEntry(day: "2026-10-20", project: "A", title: "b", issue: 5, hours: 2)
        #expect(WorkReport.redmineUpdates([monday, tuesday])[0].timeEntries.map(\.day) == ["2026-10-19", "2026-10-20"])
        // 댓글은 보냈고 시간만 남지 않았다
        monday.postedAt = Date(timeIntervalSinceNow: 60)
        let pending = WorkReport.redmineUpdates([monday])[0]
        #expect(!pending.needsNote)
        #expect(pending.hours == 1)
    }

    @Test func estimateSubtractsHoursAlreadyLogged() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "v", title: "오전", issue: 1, source: "mr:v/repo!1", hours: 2, timeLogged: true),
            WorkEntry(day: "2026-10-20", project: "v", title: "오후", issue: 1, source: "branch:v/repo:x"),
        ]
        #expect(WorkTime.remaining(entries, minutesByFolder: ["repo": 240]) == [1: 2])
        #expect(WorkTime.remaining(entries, minutesByFolder: ["repo": 120]).isEmpty)
        #expect(WorkTime.suggest(entries, minutesByFolder: ["repo-feature": 60]) == [1: 1])   // worktree 폴더
    }

    @Test func buildsTimeEntryAndTeamsCard() throws {
        let base = try #require(RedmineAPI.baseURL("https://its.example.com"))
        let request = try RedmineAPI.timeEntryRequest(base: base, key: "k", issue: 5, spentOn: "2026-10-20",
                                                      hours: 1.5, activityID: 9, comments: "API 연동")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: [String: Any]]
        #expect(request.url?.path == "/time_entries.json")
        #expect(body?["time_entry"]?["hours"] as? Double == 1.5)
        #expect(body?["time_entry"]?["activity_id"] as? Int == 9)
        let activities = try RedmineAPI.parseActivities(Data(#"{"time_entry_activities":[{"id":9,"name":"개발","is_default":true},{"id":10,"name":"옛","active":false}]}"#.utf8))
        #expect(activities.map(\.id) == [9])

        let card = try JSONSerialization.jsonObject(with: TeamsWebhook.payload("[주간 진행 사항] 10.19 ~ 10.25\n1. A\n- a (완료)", title: "주간 보고")) as? [String: Any]
        let attachment = (card?["attachments"] as? [[String: Any]])?.first
        #expect(attachment?["contentType"] as? String == "application/vnd.microsoft.card.adaptive")
        let blocks = ((attachment?["content"] as? [String: Any])?["body"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        #expect(blocks == ["주간 보고", "[주간 진행 사항] 10.19 ~ 10.25", "1. A", "- a (완료)"])
        #expect(TeamsWebhook.isValid("https://prod-12.koreacentral.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?sig=x"))
        #expect(!TeamsWebhook.isValid("https://example.com/hook"))
        #expect(!TeamsWebhook.isValid("https://evil-office.com/hook"))
        #expect(TeamsWebhook.isValid("https://default9cc8.a6.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/x/triggers/manual/paths/invoke?api-version=1"))
        #expect(TeamsWebhook.failure(status: 401, body: Data(#"{"error":{"code":"DirectApiAuthorizationRequired"}}"#.utf8)).contains("누구나"))
        let company = "https://default9cc8af3ec399451c923a3b56304249.a6.environment.api.powerplatform.com:443/powerautomate/automations/direct/cu/20/workflows/65545a98097d4686a3fa3f2142640901/triggers/manual/paths/invoke?api-version=1"
        let anyone = company + "&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=abc"
        #expect(TeamsWebhook.needsAnyone(company))
        #expect(!TeamsWebhook.needsAnyone(anyone))
        #expect(TeamsWebhook.workflowID(company) == TeamsWebhook.workflowID(anyone))
        #expect(TeamsWebhook.flowEditURL(company)?.absoluteString
                == "https://make.powerautomate.com/environments/Default-9cc8af3e-c399-451c-923a-3b56304249a6/flows/65545a98-097d-4686-a3fa-3f2142640901/details")
    }
}
