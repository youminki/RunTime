import Foundation
import Testing
@testable import WorkLogCore

private func issue(_ id: Int, _ subject: String, tracker: String, parent: Int?, project: String = "목포") -> RedmineAPI.Issue {
    RedmineAPI.Issue(id: id, subject: subject, project: project, status: "할일", doneRatio: 0, tracker: tracker, parentID: parent)
}

/// 실제 레드마인 꼴: 구현 > 메뉴 > 화면 > API 연동, 시험 > 기능 테스트 > [수정][메뉴] …
private let tree: [Int: RedmineAPI.Issue] = [
    1: issue(1, "구현", tracker: "구현", parent: nil),
    2: issue(2, "데이터 수집", tracker: "큰틀", parent: 1),
    3: issue(3, "파이프라인 생성", tracker: "큰틀", parent: 2),
    9: issue(9, "시험", tracker: "시험", parent: nil),
    10: issue(10, "기능 테스트", tracker: "큰틀", parent: 9),
]

@Suite struct IssueBookTests {
    @Test func buildsReportTitleFromHierarchy() {
        let api = IssueInfo.build(issue(4, "API 연동", tracker: "작업", parent: 3), lookup: tree, assigned: true)
        #expect(api.path == ["데이터 수집", "파이프라인 생성"])
        #expect(api.reportTitle == "데이터 수집 > 파이프라인 생성 API 연동")
        #expect(!api.isQA)
        let qa = IssueInfo.build(issue(11, "[수정][데이터셋관리] 이력 저장 기간 음수 입력 방지", tracker: "작업", parent: 10),
                                 lookup: tree, assigned: true)
        #expect(qa.isQA)
        #expect(IssueInfo.cleanSubject(qa.subject) == "이력 저장 기간 음수 입력 방지")
        let coded = IssueInfo.build(issue(6, "API 연동", tracker: "작업", parent: 7),
                                    lookup: tree.merging([7: issue(7, "[FN-HUBADM-02] 운영 현황 조회", tracker: "큰틀", parent: 2)]) { a, _ in a },
                                    assigned: true)
        #expect(coded.reportTitle == "데이터 수집 > 운영 현황 조회 API 연동")
        let other = IssueInfo.build(issue(5, "목록 정렬 기준 변경", tracker: "작업", parent: 3), lookup: tree, assigned: false)
        #expect(other.reportTitle == "데이터 수집 > 파이프라인 생성 > 목록 정렬 기준 변경")
    }

    @Test func dailyReportFollowsRedmineIssuesAndCountsQA() {
        var log = WorkLog(projects: ["uxhub", "VeloX"])
        for (id, subject, parent) in [(4, "API 연동", 3), (11, "[수정][A] 가", 10), (12, "[수정][B] 나", 10), (13, "[추가][C] 다", 10)] {
            let info = IssueInfo.build(issue(id, subject, tracker: "작업", parent: parent), lookup: tree, assigned: true)
            log.issues[String(id)] = info
        }
        log.entries = [
            WorkEntry(day: "2026-10-20", project: "uxhub", title: "fix: 메뉴 위치", issue: 11),
            WorkEntry(day: "2026-10-20", project: "uxhub", title: "fix: 소수점", issue: 12),
            WorkEntry(day: "2026-10-20", project: "uxhub", title: "fix: 같은 QA 다른 커밋", issue: 12),
            WorkEntry(day: "2026-10-20", project: "uxhub", title: "사용자 포털 이용안내 기획 변경사항 반영"),
            WorkEntry(day: "2026-10-20", project: "VeloX", title: "feat: 생성 화면", status: .percent(60), issue: 4),
            WorkEntry(day: "2026-10-20", project: "VeloX", title: "feat: 생성 API", issue: 4),
        ]
        #expect(WorkReport.daily(log.entries, in: log, byIssue: true) == """
        1. uxhub
        - QA 수정사항 2건 반영 (완료)
        - 사용자 포털 이용안내 기획 변경사항 반영 (완료)
        2. VeloX
        - 데이터 수집 > 파이프라인 생성 API 연동 (100%)
        """)
        log.entries.append(WorkEntry(day: "2026-10-20", project: "uxhub", title: "다", status: .percent(50), issue: 13))
        #expect(WorkReport.daily(log.entries, in: log, byIssue: true).contains("- QA 수정사항 3건 반영 (70%)"))
        // 막 지운 빈 줄은 일감이 있어도 빠진다
        log.entries.append(WorkEntry(day: "2026-10-20", project: "VeloX", title: " ", issue: 99))
        #expect(!WorkReport.daily(log.entries, in: log, byIssue: true).contains("99"))
        let pending = WorkLog(projects: ["u"], entries: [WorkEntry(day: "2026-10-20", project: "u", title: "x", status: .inProgress, issue: 11)])
        var book = pending
        book.issues = log.issues
        #expect(WorkReport.daily(book.entries, in: book, byIssue: true).contains("QA 수정사항 1건 반영 (진행중)"))
    }

    @Test func reportProjectLearnsFromEarlierEntries() {
        var log = WorkLog()
        let a = IssueInfo.build(issue(4, "API 연동", tracker: "작업", parent: 3, project: "경북대"), lookup: tree, assigned: true)
        let b = IssueInfo.build(issue(5, "마크업", tracker: "작업", parent: 3, project: "경북대"), lookup: tree, assigned: true)
        log.issues = ["4": a, "5": b]
        #expect(log.reportProject(for: b) == "경북대")
        log.entries = [WorkEntry(day: "2026-10-20", project: "VeloX", title: "x", issue: 4)]
        #expect(log.reportProject(for: b) == "VeloX")
        log.redmineProjects["경북대"] = "velox"
        #expect(log.reportProject(for: b) == "velox")
    }

    @Test func issueBookSurvivesSaveAndMerge() throws {
        var log = WorkLog()
        log.issues["4"] = IssueInfo(id: 4, subject: "API 연동", project: "p", path: ["메뉴"], fetchedAt: Date(timeIntervalSince1970: 10))
        let decoded = try WorkLogFile.decode(WorkLogFile.encode(log))
        #expect(decoded.issues["4"]?.path == ["메뉴"])
        var disk = log
        disk.issues["4"]?.doneRatio = 50
        disk.issues["4"]?.fetchedAt = Date(timeIntervalSince1970: 20)
        #expect(WorkLog.merge(mine: log, base: log, disk: disk).issues["4"]?.doneRatio == 50)
    }

    @Test func suggestsIssueForUnlinkedLine() {
        let a = IssueInfo(id: 1, subject: "API 연동", project: "p", path: ["데이터 수집", "데스티네이션 관리"])
        let b = IssueInfo(id: 2, subject: "API 연동", project: "p", path: ["데이터 수집", "소스 관리"])
        let c = IssueInfo(id: 3, subject: "마크업", project: "p", path: ["데이터 수집", "데스티네이션 관리"])
        let found = IssueMatch.suggest("데스티네이션 관리 API 연동", in: [a, b, c])
        #expect(found.first?.id == 1)
        #expect(!found.contains { $0.id == 2 })   // 일 이름만 겹치면 고르지 않는다
    }

    @Test func clearingReportNameSurvivesMerge() {
        var base = WorkLog()
        base.redmineProjects = ["경북대": "VeloX"]
        var mine = base
        mine.redmineProjects = [:]
        #expect(WorkLog.merge(mine: mine, base: base, disk: base).redmineProjects.isEmpty)
    }
}
