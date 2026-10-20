import Foundation
import Testing
@testable import WorkLogCore

private let sample = """
1.uxhub
- QA 수정사항 7건 반영 (완료)
- 사용자 포털 이용안내 기획 변경사항 반영 (완료)
2. VeloX
- 데이터 수집 > 파이프라인 생성 API 연동 (100%)
- 데이터 수집 > 파이프라인 목록 및 상태조회 API 연동 #4521 (60%)
"""

@Suite struct WorkReportTests {
    @Test func parsesPastedReport() {
        let entries = WorkReport.parse(sample, day: "2026-10-20")
        #expect(entries.map(\.project) == ["uxhub", "uxhub", "VeloX", "VeloX"])
        #expect(entries[0].title == "QA 수정사항 7건 반영")
        #expect(entries[0].status == .done)
        #expect(entries[2].status == .percent(100))
        #expect(entries[3].issue == 4521)
        #expect(entries[3].title == "데이터 수집 > 파이프라인 목록 및 상태조회 API 연동")
    }

    @Test func keepsDoneAndHundredPercentApart() {
        let log = WorkLog(projects: ["uxhub", "VeloX"], entries: WorkReport.parse(sample, day: "2026-10-20"))
        #expect(WorkReport.daily(log.entries, in: log) == """
        1. uxhub
        - QA 수정사항 7건 반영 (완료)
        - 사용자 포털 이용안내 기획 변경사항 반영 (완료)
        2. VeloX
        - 데이터 수집 > 파이프라인 생성 API 연동 (100%)
        - 데이터 수집 > 파이프라인 목록 및 상태조회 API 연동 (60%)
        """)
    }

    @Test func followsRegisteredProjectOrder() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "B", title: "b"),
            WorkEntry(day: "2026-10-20", project: "A", title: "a"),
        ]
        let log = WorkLog(projects: ["A"], entries: entries)
        #expect(WorkReport.daily(entries, in: log) == "1. A\n- a (완료)\n2. B\n- b (완료)")
    }

    @Test func weeklyKeepsLastStatusOfSameWork() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "VeloX", title: "파이프라인 생성 API 연동", status: .percent(60), issue: 7),
            WorkEntry(day: "2026-10-21", project: "VeloX", title: "QA 반영", status: .done),
            WorkEntry(day: "2026-10-22", project: "VeloX", title: "파이프라인  생성 API 연동", status: .percent(100)),
        ]
        let log = WorkLog(projects: ["VeloX"], entries: entries)
        let week = WorkDay.week(of: "2026-10-21")
        #expect(week == "2026-10-19"..."2026-10-25")
        #expect(WorkReport.weekly(entries, in: log, week: week) == """
        [주간 진행 사항] 10.19 ~ 10.25
        1. VeloX
        - 파이프라인  생성 API 연동 (100%)
        - QA 반영 (완료)
        """)
        let merged = WorkReport.merged(entries)
        #expect(merged.first?.issue == 7)
        #expect(WorkReport.progression(of: merged[0], in: entries) == [.percent(60), .percent(100)])
    }

    @Test func groupsRedmineUpdatesByIssue() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "VeloX", title: "생성 API 연동", status: .percent(40), issue: 10),
            WorkEntry(day: "2026-10-21", project: "VeloX", title: "수정 API 연동", status: .percent(80), issue: 10),
            WorkEntry(day: "2026-10-21", project: "VeloX", title: "회의", status: .ongoing),
            WorkEntry(day: "2026-10-21", project: "uxhub", title: "QA", issue: 11, note: "[작업 내용]\n- QA 7건"),
        ]
        let updates = WorkReport.redmineUpdates(entries)
        #expect(updates.map(\.issue) == [10, 11])
        #expect(updates[0].doneRatio == 80)
        #expect(updates[0].note == "[작업 내용]\n- 생성 API 연동\n- 수정 API 연동")
        #expect(updates[1].note == "[작업 내용]\n- QA 7건")
        let request = WorkReport.redmineRequest(updates)
        #expect(request.contains("#10 진척률 80%\n[작업 내용]"))
    }

    @Test func entryNeedsRedmineAgainAfterEdit() {
        var entry = WorkEntry(day: "2026-10-20", project: "A", title: "a", issue: 1, updatedAt: Date(timeIntervalSince1970: 10))
        #expect(entry.needsRedmine)
        entry.postedAt = Date(timeIntervalSince1970: 20)
        #expect(!entry.needsRedmine)
        entry.updatedAt = Date(timeIntervalSince1970: 30)
        #expect(entry.needsRedmine)
    }

    @Test func carriesOverUnfinishedWork() {
        var log = WorkLog(entries: [
            WorkEntry(day: "2026-10-20", project: "A", title: "끝남"),
            WorkEntry(day: "2026-10-20", project: "A", title: "진행", status: .percent(50), issue: 3),
            WorkEntry(day: "2026-10-20", project: "A", title: "상시", status: .ongoing),
        ])
        #expect(log.previousDay(before: "2026-10-22") == "2026-10-20")
        #expect(log.carryOver(from: "2026-10-20", to: "2026-10-22") == 2)
        #expect(log.carryOver(from: "2026-10-20", to: "2026-10-22") == 0)
        #expect(log.entries(on: "2026-10-22").map(\.title) == ["진행", "상시"])
    }

    @Test func statusRoundTripsAsReportLabel() throws {
        let entry = WorkEntry(day: "2026-10-20", project: "A", title: "a", status: .percent(30))
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(json.contains(#""status":"30%""#))
        #expect(try JSONDecoder().decode(WorkEntry.self, from: Data(json.utf8)).status == .percent(30))
        #expect(WorkStatus(label: "진행중") == .inProgress)
        #expect(WorkStatus.inProgress.doneRatio == nil)
        #expect(WorkDay.isValid("2026-10-20"))
        #expect(!WorkDay.isValid("2026-1-5"))
        #expect(!WorkDay.isValid("2026-02-30"))
        #expect(WorkStatus(label: "120%") == nil)
    }
}

@Suite struct WorkLogCommandTests {
    @Test func addsAndReportsWithoutReadingJSON() {
        var log = WorkLog()
        let now = Date(timeIntervalSince1970: 100)
        let added = WorkLogCommand.run(["add", "VeloX", "파이프라인 삭제 API 연동 #88", "70%"], log: &log, today: "2026-10-20", now: now)
        #expect(added.changed)
        #expect(log.entries.first?.issue == 88)
        #expect(WorkLogCommand.run(["day"], log: &log, today: "2026-10-20").output == "1. VeloX\n- 파이프라인 삭제 API 연동 (70%)")
        #expect(WorkLogCommand.run(["redmine"], log: &log, today: "2026-10-20").output.contains("#88 진척률 70%"))
        let posted = WorkLogCommand.run(["posted", "#88"], log: &log, today: "2026-10-20", now: Date(timeIntervalSince1970: 200))
        #expect(posted.output == "1줄을 올림으로 표시")
        #expect(WorkLogCommand.run(["redmine"], log: &log, today: "2026-10-20").output == "올릴 일감 없음")
    }

    @Test func importsFromStandardInput() {
        var log = WorkLog()
        let result = WorkLogCommand.run(["import", "2026-10-21"], log: &log, stdin: { sample })
        #expect(result.output == "2026-10-21에 4줄 넣음")
        #expect(log.projects == ["uxhub", "VeloX"])
        #expect(WorkLogCommand.run(["day", "10/21"], log: &log).failed)
    }

    @Test func savedFileKeepsReadableStatus() throws {
        let log = WorkLog(projects: ["A"], entries: [WorkEntry(day: "2026-10-20", project: "A", title: "a", status: .ongoing)])
        let text = String(decoding: try WorkLogFile.encode(log), as: UTF8.self)
        #expect(text.contains(#""status" : "상시""#))
    }

    @Test func addKeepsUnquotedWordsAndPostedStaysInScope() {
        var log = WorkLog()
        _ = WorkLogCommand.run(["add", "VeloX", "삭제", "API", "연동", "70%", "#9"], log: &log, today: "2026-10-20")
        _ = WorkLogCommand.run(["add", "VeloX", "예전 일", "#9", "--day", "2026-10-19"], log: &log, today: "2026-10-20")
        #expect(log.entries.first?.title == "삭제 API 연동")
        #expect(WorkLogCommand.run(["add", "A", "b", "--day", "2026-1-5"], log: &log).failed)
        _ = WorkLogCommand.run(["posted", "9"], log: &log, today: "2026-10-20")
        #expect(log.entries.filter(\.needsRedmine).map(\.day) == ["2026-10-19"])
    }

    @Test func skipsDateHeadlines() {
        #expect(WorkReport.parse("2026.10.20 보고\n1. A\n- a", day: "2026-10-20").map(\.project) == ["A"])
    }

    @Test func keepsMillisecondsSoPostThenEditIsSeen() throws {
        var entry = WorkEntry(day: "2026-10-20", project: "A", title: "a", issue: 1,
                              postedAt: Date(timeIntervalSince1970: 10.2), updatedAt: Date(timeIntervalSince1970: 10.5))
        let decoded = try WorkLogFile.decode(WorkLogFile.encode(WorkLog(entries: [entry])))
        #expect(decoded.entries.first?.needsRedmine == true)
        entry.updatedAt = Date(timeIntervalSince1970: 10.1)
        #expect(!entry.needsRedmine)
    }

    @Test func mergeKeepsBothSidesEdits() {
        let a = WorkEntry(day: "2026-10-20", project: "A", title: "a")
        let b = WorkEntry(day: "2026-10-20", project: "A", title: "b")
        let base = WorkLog(projects: ["A"], entries: [a, b])
        var mine = base
        mine.entries[0].title = "a2"            // 창에서 고침
        mine.entries.remove(at: 1)              // 창에서 지움
        mine.entries.append(WorkEntry(day: "2026-10-20", project: "A", title: "c"))
        var disk = base
        disk.entries.append(WorkEntry(day: "2026-10-20", project: "B", title: "cli"))   // 명령으로 넣음
        disk.projects.append("B")
        let merged = WorkLog.merge(mine: mine, base: base, disk: disk)
        #expect(merged.entries.map(\.title) == ["a2", "cli", "c"])
        #expect(merged.projects == ["A", "B"])
    }

    @Test func newProjectIsListedBeforeItHasLines() {
        var log = WorkLog(entries: [WorkEntry(day: "2026-10-20", project: "A", title: "a")])
        log.register(project: "새 프로젝트")
        #expect(log.allProjects == ["새 프로젝트", "A"])
    }

    @Test func monthCalendarAndReport() {
        #expect(WorkDay.month(of: "2026-10-20") == "2026-10-01"..."2026-10-31")
        let days = WorkDay.calendarDays(of: "2026-10-20")
        #expect(days.first == "2026-09-28")   // 10월 1일(목)이 든 주의 월요일
        #expect(days.last == "2026-11-01")
        #expect(days.count % 7 == 0)
        let log = WorkLog(entries: [WorkEntry(day: "2026-10-02", project: "A", title: "a")])
        #expect(WorkReport.monthly(log.entries, in: log, month: WorkDay.month(of: "2026-10-20")) == "[월간 진행 사항] 2026년 10월\n1. A\n- a (완료)")
    }

    @Test func searchesWithInitialConsonants() {
        let log = WorkLog(entries: [
            WorkEntry(day: "2026-10-19", project: "VeloX", title: "데이터 수집 API 연동", issue: 4512),
            WorkEntry(day: "2026-10-20", project: "cdh", title: "차트 숫자 정리", note: "[작업 내용]\n- 툴팁"),
        ])
        #expect(log.search("ㄷㅇㅌ").map(\.title) == ["데이터 수집 API 연동"])
        #expect(log.search("api velox").count == 1)
        #expect(log.search("#4512").count == 1)
        #expect(log.search("툴팁").map(\.project) == ["cdh"])
        #expect(log.search("").isEmpty)
    }
}
