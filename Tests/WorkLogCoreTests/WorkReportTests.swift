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

    @Test func writesMorningPlanFromUnfinishedWork() {
        let yesterday = WorkReport.parse("""
        1. UxHub
        - QA 수정사항 3건 반영 (완료)
        - 사용자포털 마이페이지 마크업 수정 (80%)
        2. VeloX
        - 데이터 탐색 > 쿼리 목록 마크업 (80%)
        - 데이터 탐색 > BI 대시보드 마크업 (진행중)
        """, day: "2026-10-26")
        let today = [WorkEntry(day: "2026-10-27", project: "UxHub", title: "사용자포털 마이페이지 마크업 수정", status: .inProgress),
                     WorkEntry(day: "2026-10-27", project: "UxHub", title: "버그수정", status: .inProgress),
                     WorkEntry(day: "2026-10-27", project: "UxHub", title: "배포", status: .done)]
        let log = WorkLog(projects: ["UxHub", "VeloX"], entries: yesterday + today)
        #expect(WorkReport.dayHeader("2026-10-27", today: "2026-10-27") == "[10/27 금일 진행 사항]")
        #expect(WorkReport.dayHeader("2026-10-27", plan: true, today: "2026-10-27") == "[10/27 금일 진행 예정 사항]")
        #expect(WorkReport.dayHeader("2026-10-24", today: "2026-10-27") == "[10/24 진행 사항]")
        // UxHub는 앞선 날 QA를 고쳐서 이어서 QA를 적는다
        #expect(WorkReport.plan(day: "2026-10-27", in: log) == """
        1. UxHub
        - QA 수정사항 반영
        2. VeloX
        - 마크업 및 API 연동
        """)
        // 상시만 있는 날은 비운다
        let meetings = WorkLog(projects: ["UxHub"], entries: [WorkEntry(day: "2026-10-28", project: "UxHub", title: "주간 회의", status: .ongoing)])
        #expect(WorkReport.plan(day: "2026-10-28", in: meetings).isEmpty)
    }

    /// 기간을 정한 프로젝트는 줄이 없어도 그 기간 동안 늘 들어가고, 보고서 순서를 따른다.
    @Test func planKeepsProjectsInPeriod() {
        var log = WorkLog(projects: ["UxHub", "VeloX", "옛 프로젝트", "숨김"])
        log.projectPeriods = ["VeloX": ProjectPeriod(start: "2026-10-01", end: "2026-12-31"),
                              "옛 프로젝트": ProjectPeriod(end: "2026-09-30"),
                              "숨김": ProjectPeriod(start: "2026-10-01")]
        log.hiddenProjects = ["숨김"]
        log.entries = [WorkEntry(day: "2026-10-28", project: "UxHub", title: "버그수정", status: .done)]
        #expect(WorkReport.plan(day: "2026-10-28", in: log) == """
        1. UxHub
        - 마크업 및 API 연동
        2. VeloX
        - 마크업 및 API 연동
        """)
        // 줄이 없는 날도 기간 중인 프로젝트는 남는다
        #expect(WorkReport.plan(day: "2026-10-29", in: log) == "1. VeloX\n- 마크업 및 API 연동")
        #expect(WorkReport.plan(day: "2027-01-02", in: log).isEmpty)
        #expect(ProjectPeriod(start: "2026-10-01").contains("2026-10-01"))
        // 직접 정하지 않은 프로젝트는 레드마인 내 일감(배정·열림)으로 잡는다. 기한이 지나도 열려 있으면 들어간다
        log.redmineProjects = ["목포 데이터밸류": "UxHub"]
        log.issues = ["1": IssueInfo(id: 1, subject: "마크업", project: "목포 데이터밸류", dueDate: "2026-11-30", assigned: true, startDate: "2026-11-02"),
                      "2": IssueInfo(id: 2, subject: "API 연동", project: "목포 데이터밸류", dueDate: "2026-10-20", assigned: true, startDate: "2026-10-05"),
                      "3": IssueInfo(id: 3, subject: "끝난 일", project: "목포 데이터밸류", dueDate: "2027-03-01", assigned: false, startDate: "2026-01-01")]
        #expect(log.autoPeriods()["UxHub"] == WorkLog.AutoPeriod(period: ProjectPeriod(start: "2026-10-05", end: "2026-11-30"), issues: 2))
        #expect(log.projectsInPeriod(on: "2026-10-04") == ["VeloX"])
        #expect(log.projectsInPeriod(on: "2027-01-02") == ["UxHub"])
        log.projectPeriods["UxHub"] = ProjectPeriod(end: "2026-10-31")   // 직접 정한 기간이 앞선다
        #expect(log.projectsInPeriod(on: "2027-01-02").isEmpty)
        #expect(!ProjectPeriod(end: "2026-09-30").contains("2026-10-01"))
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

    @Test func groupsLinesThatShareAPath() {
        let entries = [
            WorkEntry(day: "2026-10-20", project: "VeloX", title: "QA 수정사항 3건 반영"),
            WorkEntry(day: "2026-10-20", project: "VeloX", title: "데이터 수집 > 수집 관리 > 작업 제어 API 연동", status: .percent(100)),
            WorkEntry(day: "2026-10-20", project: "VeloX", title: "공유 > 파일 목록 마크업", status: .percent(60)),
            WorkEntry(day: "2026-10-20", project: "VeloX", title: "데이터 수집 > 수집 관리 > 로그 조회 API 연동", status: .percent(100)),
        ]
        let log = WorkLog(projects: ["VeloX"], entries: entries)
        let text = WorkReport.daily(entries, in: log, grouped: true)
        #expect(text == """
        1. VeloX
        - QA 수정사항 3건 반영 (완료)
        - 데이터 수집 > 수집 관리
          · 작업 제어 API 연동 (100%)
          · 로그 조회 API 연동 (100%)
        - 공유 > 파일 목록 마크업 (60%)
        """)
        // 묶어 쓴 보고서를 붙여 넣어도 원래 줄로 읽는다
        let parsed = WorkReport.parse(text, day: "2026-10-20")
        #expect(parsed.map(\.title) == ["QA 수정사항 3건 반영", "데이터 수집 > 수집 관리 > 작업 제어 API 연동",
                                        "데이터 수집 > 수집 관리 > 로그 조회 API 연동", "공유 > 파일 목록 마크업"])
        #expect(parsed[1].status == .percent(100))
        #expect(parsed[3].status == .percent(60))
    }

    @Test func keepsPlainSubBulletsApart() {
        let text = """
        1. VeloX
        - 로그인 개선 #123 (60%)
          - 세부 내용 (완료)
        - 회의
          · 주간 회의 (완료)
        """
        let parsed = WorkReport.parse(text, day: "2026-10-20")
        #expect(parsed.map(\.title) == ["로그인 개선", "세부 내용", "회의 > 주간 회의"])
        #expect(parsed[0].issue == 123)
        #expect(parsed[0].status == .percent(60))
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

    @Test func carryOverSkipsRecurringAndPostedNotes() {
        var log = WorkLog(entries: [
            WorkEntry(day: "2026-10-19", project: "A", title: "주간 회의", status: .ongoing, source: "recurring:1"),
            WorkEntry(day: "2026-10-19", project: "A", title: "보냄", status: .percent(60), issue: 3,
                      note: "[작업 내용]\n- 목록 연결", postedAt: Date(timeIntervalSince1970: 20),
                      updatedAt: Date(timeIntervalSince1970: 10)),
            WorkEntry(day: "2026-10-19", project: "A", title: "안 보냄", status: .percent(30), note: "메모"),
        ])
        #expect(log.carryOver(from: "2026-10-19", to: "2026-10-20") == 2)
        let carried = log.entries(on: "2026-10-20")
        #expect(carried.map(\.title) == ["보냄", "안 보냄"])
        #expect(carried.map(\.note) == ["", "메모"])
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

@Suite struct CompactReportTests {
    private func row(_ project: String, _ title: String, _ status: WorkStatus = .done, issue: Int? = nil, source: String? = nil) -> WorkEntry {
        WorkEntry(day: "2026-11-03", project: project, title: title, status: status, issue: issue, source: source)
    }

    /// MR·일감에서 가져온 하루가 사람이 쓰는 길이로 줄어든다.
    @Test func shortensADayLikeAPersonWould() {
        let entries = [
            row("VeloX", "데이터 탐색 > SQL 편집기 > 쿼리 실행 API 연동", .percent(100), issue: 1, source: "mr:g/web!1#1"),
            row("VeloX", "데이터 탐색 > SQL 편집기 > 결과 다운로드 API 연동", .percent(100), issue: 2, source: "mr:g/web!1#2"),
            row("VeloX", "데이터 탐색 > BI 대시보드 > 대시보드 목록 API 연동", .percent(100), issue: 3, source: "mr:g/web!1#3"),
            row("VeloX", "데이터 탐색 > BI 대시보드 > 대시보드 공유 API 연동", .percent(60), issue: 4, source: "mr:g/web!1#4"),
            row("VeloX", "편집기 라이브러리 교체", .inProgress, source: "branch:g/web:feature/editor"),
            row("UxHub", "API 게이트웨이 주소 컨테이너 환경변수 적용 (목포)", source: "mr:g/admin!1"),
            row("UxHub", "사용자포털 API 게이트웨이 · MQTT 주소 컨테이너 환경변수 적용 (목포)", source: "mr:g/user!1"),
            row("UxHub", "API 게이트웨이 주소 컨테이너 환경변수 적용", source: "mr:g/admin!2"),
            row("UxHub", "API 게이트웨이 주소 컨테이너 환경변수 적용 되돌리기", source: "mr:g/admin!3"),
            row("UxHub", "목포 API 게이트웨이 주소 적용", source: "mr:g/admin!4"),
            row("UxHub", "대시보드 > 대시보드 관리 > 대시보드 목록 마크업", .percent(100), issue: 5, source: "mr:g/admin!5#5"),
            row("UxHub", "대시보드 > 대시보드 관리 > 대시보드 생성/수정 마크업", .percent(100), issue: 6, source: "mr:g/admin!5#6"),
            row("UxHub", "주간 회의", .ongoing),
        ]
        let log = WorkLog(projects: ["UxHub", "VeloX"], entries: entries)
        #expect(WorkReport.daily(entries, in: log, doneFirst: true, compact: true) == """
        1. UxHub
        - 주간 회의 (상시)
        - 목포 API 게이트웨이 주소 적용 (완료)
        - 대시보드 > 대시보드 관리 마크업 (100%)
        2. VeloX
        - 데이터 탐색 > SQL 편집기 API 연동 (100%)
        - 데이터 탐색 > BI 대시보드 API 연동 (60%)
        - 편집기 라이브러리 교체 (진행중)
        """)
        // 끄면 예전처럼 다 적는다
        #expect(WorkReport.daily(entries, in: log).components(separatedBy: "\n").count == entries.count + 2)
    }

    @Test func undoesRevertsOnlyForTheirTarget() {
        #expect(WorkReport.revertedTitle("주소 적용 되돌리기") == "주소 적용")
        #expect(WorkReport.revertedTitle("Revert \"주소 적용\"") == "주소 적용")
        #expect(WorkReport.revertedTitle("설정 원복") == "설정")
        #expect(WorkReport.revertedTitle("되돌리기 버튼 추가") == nil)
        let entries = [row("A", "로그인 개선", source: "mr:g/a!1"), row("A", "주소 적용", source: "mr:g/a!2"),
                       row("A", "주소 적용 되돌리기", source: "mr:g/a!3")]
        #expect(WorkReport.compacted(entries).map(\.title) == ["로그인 개선"])
    }

    @Test func menuTitleNeedsAPathAndAKindOfWork() {
        #expect(WorkReport.menuTitle("데이터 탐색 > SQL 편집기 > 쿼리 실행 API 연동") == "데이터 탐색 > SQL 편집기 API 연동")
        #expect(WorkReport.menuTitle("A > B > C > 목록 마크업") == "A > B 마크업")
        #expect(WorkReport.menuTitle("A > B > 목록") == nil)            // 일 종류가 없다
        #expect(WorkReport.menuTitle("데이터 탐색 > 쿼리 목록 API 연동") == nil)   // 이미 짧다
        #expect(WorkReport.menuTitle("A > B > 재연동") == nil)          // 낱말 끝이 아니다
    }

    /// 직접 적은 줄은 비슷해도 모으지 않고, 주제 낱말이 셋 넘게 겹칠 때만 같은 일로 본다.
    @Test func keepsHandWrittenAndDifferentWork() {
        let entries = [
            row("A", "로그인 화면 수정"), row("A", "로그인 화면 수정 마무리"),
            row("A", "로그인 API 연동", .inProgress, source: "mr:g/a!1"), row("A", "회원가입 API 연동", source: "mr:g/a!2"),
            row("A", "대시보드 차트 버그", source: "mr:g/a!3"), row("A", "대시보드 차트 색상", source: "mr:g/a!4"),
            row("A", "v1.2 배포 설정 서버 주소", source: "mr:g/a!5"), row("A", "v1.3 배포 설정 서버 주소", source: "mr:g/a!6"),
        ]
        #expect(WorkReport.compacted(entries) == entries)
    }

    /// 같은 일을 여러 MR로 나눴으면 가장 짧은 제목 하나로, 하나라도 덜 끝났으면 그 상태로 적는다.
    @Test func mergesTheSameWorkSplitAcrossMRs() {
        let entries = [
            row("A", "API 게이트웨이 주소 컨테이너 환경변수 적용 (목포)", source: "mr:g/a!1"),
            row("A", "로그인 화면 수정", source: "mr:g/a!2"),
            row("A", "목포 API 게이트웨이 주소 적용", .percent(80), source: "mr:g/a!3"),
            row("A", "사용자포털 목포 API 게이트웨이 주소 적용과 MQTT 수신 방식 주석 처리", source: "mr:g/a!4"),
        ]
        let result = WorkReport.compacted(entries)
        // MQTT 수신 방식처럼 다른 일까지 적은 긴 줄은 짧은 줄에 묻히지 않게 따로 둔다
        #expect(result.map(\.title) == ["목포 API 게이트웨이 주소 적용", "로그인 화면 수정",
                                        "사용자포털 목포 API 게이트웨이 주소 적용과 MQTT 수신 방식 주석 처리"])
        #expect(result[0].status == .percent(80))
        #expect(result[0].id == entries[0].id)
        #expect(!WorkReport.similar(WorkReport.words("Step 1 검색 필터 정렬"), WorkReport.words("Step 2 검색 필터 정렬")))
    }

    /// 진행 중 브랜치는 끝난 줄과 같은 일일 때만 뺀다. 회의만 있는 날이나 상관없는 작업이면 그날 한 일이라 남긴다.
    @Test func keepsBranchesThatAreOtherWork() {
        let branch = row("A", "편집기 라이브러리 CodeMirror 교체", .inProgress, source: "branch:g/a:feature/x")
        #expect(WorkReport.compacted([branch]).count == 1)
        #expect(WorkReport.compacted([row("A", "주간 회의", .ongoing), branch]).count == 2)
        #expect(WorkReport.compacted([row("A", "로그인 화면 수정", source: "mr:g/a!1"), branch]).count == 2)
        let same = row("A", "편집기 라이브러리 CodeMirror 교체 마무리", source: "mr:g/a!2")
        #expect(WorkReport.compacted([same, branch]).map(\.title) == [same.title])
    }

    /// 되돌린 대상이 없거나 직접 적은 원복이면 그 자체가 한 일이라 남긴다. 되돌린 뒤 다시 적용했으면 다시 적용한 줄을 남긴다.
    @Test func keepsRevertsThatAreWork() {
        let alone = [row("A", "주소 적용 되돌리기", source: "mr:g/a!1")]
        #expect(WorkReport.compacted(alone).count == 1)
        let typed = [row("A", "DB 설정"), row("A", "DB 설정 원복")]
        #expect(WorkReport.compacted(typed).count == 2)
        // 직접 적은 줄은 MR 되돌리기의 대상도 되지 않는다
        let mixed = [row("A", "주소 적용"), row("A", "주소 적용 되돌리기", source: "mr:g/a!9")]
        #expect(WorkReport.compacted(mixed).count == 2)
        let applied = WorkEntry(day: "2026-11-05", project: "A", title: "주소 적용", source: "mr:g/a!3")
        let reverted = WorkEntry(day: "2026-11-04", project: "A", title: "주소 적용 되돌리기", source: "mr:g/a!2")
        #expect(WorkReport.compacted([reverted, applied]).map(\.title) == ["주소 적용"])
        let log = WorkLog(projects: ["A"], entries: [WorkEntry(day: "2026-11-03", project: "A", title: "주소 적용", source: "mr:g/a!1"),
                                                      reverted, applied])
        #expect(WorkReport.weekly(log.entries, in: log, week: "2026-11-02"..."2026-11-08", compact: true)
                == "[주간 진행 사항] 11.2 ~ 11.8\n1. A\n- 주소 적용 (완료)")
        // 같은 날 적용 → 되돌리기 → 다시 적용도 주간 보고에 남는다
        let sameDay = WorkLog(projects: ["A"], entries: [
            WorkEntry(day: "2026-11-04", project: "A", title: "주소 적용", source: "mr:g/a!1"),
            WorkEntry(day: "2026-11-04", project: "A", title: "주소 적용 되돌리기", source: "mr:g/a!2"),
            WorkEntry(day: "2026-11-04", project: "A", title: "주소 적용", source: "mr:g/a!3"),
        ])
        #expect(WorkReport.weekly(sameDay.entries, in: sameDay, week: "2026-11-02"..."2026-11-08", compact: true)
                == "[주간 진행 사항] 11.2 ~ 11.8\n1. A\n- 주소 적용 (완료)")
        #expect(WorkReport.daily(sameDay.entries, in: sameDay, compact: true) == "1. A\n- 주소 적용 (완료)")
    }

    @Test func meetingsAreNotMergedIntoMenus() {
        let entries = [row("A", "기획 > 회의 > 주간 회의 개발", .ongoing),
                       row("A", "기획 > 회의 > 회의록 화면 개발", .percent(50), issue: 1)]
        #expect(WorkReport.compacted(entries).map(\.status) == [.ongoing, .percent(50)])
    }

    @Test func planSaysQAAfterAQADay() {
        var log = WorkLog(projects: ["UxHub", "VeloX"])
        log.projectPeriods = ["UxHub": ProjectPeriod(start: "2026-11-01"), "VeloX": ProjectPeriod(start: "2026-11-01")]
        log.issues = ["7": IssueInfo(id: 7, subject: "검색 결과 오류", project: "p", isQA: true)]
        log.entries = [WorkEntry(day: "2026-11-02", project: "UxHub", title: "검색 결과 오류", issue: 7),
                       WorkEntry(day: "2026-11-02", project: "VeloX", title: "목록 API 연동", status: .percent(50))]
        #expect(WorkReport.plan(day: "2026-11-03", in: log) == """
        1. UxHub
        - QA 수정사항 반영
        2. VeloX
        - 마크업 및 API 연동
        """)
        #expect(WorkReport.isQA(WorkEntry(day: "d", project: "p", title: "QA 수정사항 2건 반영"), in: log))
        #expect(WorkReport.isQA(WorkEntry(day: "d", project: "p", title: "[QA] 목록 오류"), in: log))
        #expect(WorkReport.isQA(WorkEntry(day: "d", project: "p", title: "qa수정"), in: log))
        #expect(!WorkReport.isQA(WorkEntry(day: "d", project: "p", title: "QAT 환경 구성"), in: log))
        #expect(WorkReport.isQA(WorkEntry(day: "d", project: "p", title: "QA: 정렬 오류"), in: log))
    }
}
