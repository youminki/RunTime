import Foundation
import Testing
@testable import WorkLogCore

/// 실제 MR 설명(cdh-web-admin !106·!108·!110)과 그 일감에 손으로 올린 레드마인 댓글을 대조한다 (2026-10-20).
@Suite struct RedmineCommentTests {
    private let mr106 = """
    [작업 내용]
    - 차트 툴팁·데이터 레이블 숫자의 소수 끝 0 제거(18.90000 → 18.9, #37828)
    - 기본 서식 [.]00000 을 찍을 때 .[00000] 으로 바꿔 이미 저장된 위젯에도 적용
    - 0.00 처럼 자릿수를 정한 서식은 그대로 유지
    - 쿼리 등록·상세의 파라미터 단추, 파라미터 줄, 파라미터 모달 주석 처리(#37817)

    [확인 방법]
    - 쿼리 상세에서 소수 값이 있는 막대·버블 위젯의 툴팁 확인

    [비고]
    - 파라미터 로직은 남겨 두어 저장된 파라미터가 있는 쿼리는 저장값으로 실행됨
    """

    @Test func splitsMR106LikeTheHandWrittenComment() {
        let subjects = [37828: "위젯 소수점 불필요한 0 제거", 37817: "파라미터 기능 제거"]
        let mine = RedmineComment.fromMR(mr106, mr: 106, issue: 37828, subjects: subjects, siblings: [37817])
        #expect(mine == """
        [작업 내용]
        - 차트 툴팁·데이터 레이블 숫자의 소수 끝 0 제거(18.90000 → 18.9)
        - 기본 서식 [.]00000 을 찍을 때 .[00000] 으로 바꿔 이미 저장된 위젯에도 적용
        - 0.00 처럼 자릿수를 정한 서식은 그대로 유지

        [비고]
        - MR !106
        """)
        let other = RedmineComment.fromMR(mr106, mr: 106, issue: 37817, subjects: subjects, siblings: [37828])
        #expect(other.contains("- 쿼리 등록·상세의 파라미터 단추, 파라미터 줄, 파라미터 모달 주석 처리\n"))
        #expect(!other.contains("소수 끝 0"))
        #expect(other.contains("- 파라미터 로직은 남겨 두어"))
        #expect(!other.contains("[확인 방법]"))
    }

    @Test func keepsOtherIssueLinesWhenTheyHaveNoEntry() {
        // 따로 줄이 없는 일감 줄은 잃지 않게 남긴다 (번호만 뗀다)
        let note = RedmineComment.fromMR(mr106, mr: 106, issue: 37828)
        #expect(note.contains("파라미터 모달 주석 처리\n"))
        #expect(!note.contains("#"))
    }

    @Test func dropsReferenceListAndGuessesOwnerBySubject() {
        let mr110 = """
        [작업 내용]
        - 이력 저장 기간 칸 음수·소수 입력 차단, 1일 미만 저장 차단
        - 인스턴스 0건인 Agent의 Agent 시작 버튼 비활성화와 안내 툴팁
        - 소속 Agent가 실행 중인 환경변수의 미사용 전환 확인 창에 수집 유지 안내 추가
        [확인 방법]
        - 데이터 셋 등록에서 이력 저장 유형 PARTIAL 선택 후 기간에 -30 입력 시 30만 입력됨
        [비고]
        - 레드마인 #37856, #37857, #37862
        """
        let subjects = [37856: "이력 저장 기간 -(음수) 입력 방지", 37857: "인스턴스 없을 시 시작 불가하게 수정",
                        37862: "미사용 전환 시 컨펌창 문구 추가"]
        let note = RedmineComment.fromMR(mr110, mr: 110, issue: 37857, subjects: subjects, siblings: [37856, 37862])
        #expect(note == "[작업 내용]\n- 인스턴스 0건인 Agent의 Agent 시작 버튼 비활성화와 안내 툴팁\n\n[비고]\n- MR !110")
        #expect(RedmineComment.allIssueRefs([mr110]) == [37856, 37857, 37862])
    }

    @Test func turnsCommitListIntoWorkItems() {
        let note = RedmineComment.fromMR("fix: Southbound 중복 표시를 고친다\ntest: 포트 시험을 더한다", mr: 100, issue: nil)
        #expect(note == "[작업 내용]\n- Southbound 중복 표시를 고친다\n- 포트 시험을 더한다\n\n[비고]\n- MR !100")
    }

    @Test func isStableWhenAppliedTwiceAndKeepsColorCodes() {
        let once = RedmineComment.fromMR(mr106, mr: 106, issue: 37828, siblings: [37817])
        #expect(RedmineComment.fromMR(once, mr: 106, issue: 37828, siblings: [37817]) == once)
        #expect(RedmineComment.fromMR("[작업 내용]\n- 글자색 #333 적용", mr: nil, issue: 1).contains("#333"))
    }

    @Test func splitsOldEntriesInTheLog() {
        var log = WorkLog(projects: ["cdh"])
        log.issues["37817"] = IssueInfo(id: 37817, subject: "[수정][SQL 위젯 관리] 파라미터 기능 제거", project: "목포")
        log.issues["37828"] = IssueInfo(id: 37828, subject: "[수정][SQL 위젯 관리] 위젯 소수점 불필요한 0 제거", project: "목포")
        log.entries = [WorkEntry(day: "2026-10-20", project: "cdh", title: "차트 숫자 소수 끝 0 제거", issue: 37828, note: mr106,
                                 source: "mr:cdh/cdh-web-admin!106")]
        #expect(WorkCapture.tidyMRNotes(&log) > 0)
        #expect(log.entries.count == 2)
        let sibling = log.entries[1]
        #expect(sibling.issue == 37817)
        #expect(sibling.source == "mr:cdh/cdh-web-admin!106#37817")
        #expect(sibling.title == "파라미터 기능 제거")
        // 손으로 올린 #37828 댓글처럼: 위 번호 줄을 잇는 설명은 그 일감에, 파라미터 [비고]는 #37817에
        #expect(log.entries[0].note == """
        [작업 내용]
        - 차트 툴팁·데이터 레이블 숫자의 소수 끝 0 제거(18.90000 → 18.9)
        - 기본 서식 [.]00000 을 찍을 때 .[00000] 으로 바꿔 이미 저장된 위젯에도 적용
        - 0.00 처럼 자릿수를 정한 서식은 그대로 유지

        [비고]
        - MR !106
        """)
        #expect(sibling.note.hasPrefix("[작업 내용]\n- 쿼리 등록·상세의 파라미터 단추"))
        #expect(sibling.note.contains("- 파라미터 로직은 남겨 두어"))
        #expect(WorkCapture.tidyMRNotes(&log) == 0)
        // 보낼 글도 같은 꼴
        let updates = WorkReport.redmineUpdates(log.entries, log: log)
        #expect(updates.map(\.issue) == [37828, 37817])
        #expect(updates[0].note.hasSuffix("[비고]\n- MR !106"))
    }

    @Test func resplitsWhenSubjectsArriveButKeepsUserEdits() {
        let raw = "[작업 내용]\n- 이력 저장 기간 음수 입력 차단\n- 인스턴스 0건 Agent 시작 버튼 잠금\n[비고]\n- 레드마인 #37856, #37857"
        var log = WorkLog(projects: ["cdh"])
        log.entries = [WorkEntry(day: "2026-10-21", project: "cdh", title: "음수 차단", issue: 37856, note: raw, source: "mr:cdh/a!110")]
        WorkCapture.tidyMRNotes(&log)
        #expect(log.entries.count == 2)
        // 제목을 모를 때는 두 줄 다 남는다
        #expect(log.entries[0].note.contains("인스턴스"))
        log.issues["37856"] = IssueInfo(id: 37856, subject: "[수정] 이력 저장 기간 음수 입력 방지", project: "목포")
        log.issues["37857"] = IssueInfo(id: 37857, subject: "[추가] 인스턴스 없을 시 시작 불가하게 수정", project: "목포")
        log.entries[1].note += "\n- 직접 덧붙임"   // 사용자가 고친 댓글은 다시 만들지 않는다
        WorkCapture.tidyMRNotes(&log)
        #expect(log.entries[0].note == "[작업 내용]\n- 이력 저장 기간 음수 입력 차단\n\n[비고]\n- MR !110")
        #expect(log.entries[1].note.hasSuffix("- 직접 덧붙임"))
    }

    @Test func dropsDeveloperNotesFromRemarks() {
        let note = RedmineComment.fromMR("[작업 내용]\n- 숫자 칸 음수 차단\n[비고]\n- AppForm 숫자 칸을 바꿈\n- 백엔드 확인 필요", mr: 1, issue: 5)
        #expect(note == "[작업 내용]\n- 숫자 칸 음수 차단\n\n[비고]\n- MR !1\n- 백엔드 확인 필요")
    }

    @Test func findsCommentAlreadyPostedThroughClaude() {
        let ours = "[작업 내용]\n- 쿼리 조회 결과 표의 컬럼 최소 너비 120px 적용\n- 컬럼 너비 합이 결과 영역을 넘으면 표만 가로 스크롤\n- 말줄임된 칸에만 마우스를 올리면 전체 값을 툴팁으로 노출"
        let posted = RedmineAPI.Journal(id: 83741, notes: "<p>[작업 내용]<br />\n- 조회 결과 표 컨럼 최소 너비 120px 적용<br />\n- 컨럼 너비 합이 결과 영역을 넘으면 표만 가로 스크롤<br />\n- 말줄임된 칸에만 마우스를 올리면 전체 값 툴팁 노출</p>",
                                        createdOn: Date(timeIntervalSince1970: 2000))
        let unrelated = RedmineAPI.Journal(id: 1, notes: "<p>디자인 확인 부탁드립니다</p>", createdOn: Date(timeIntervalSince1970: 2000))
        #expect(RedmineComment.alreadyPosted(ours, journals: [unrelated, posted], since: Date(timeIntervalSince1970: 1000))?.id == 83741)
        #expect(RedmineComment.alreadyPosted(ours, journals: [posted], since: Date(timeIntervalSince1970: 3000)) == nil)
    }

    /// cdh-web-admin !112 (2026-10-21). 맨 위 [일감]에 일감 번호와 이름을 적었다.
    private let mr112 = """
    [일감]
    - #37742 상품 신청 내역 > API 연동
    - #37737 상품 이용 승인 관리 > API 연동

    [작업 내용]
    - provider 스웨거 타입 재생성(v2 이용 신청 API 추가)
    - 상품 신청 내역 목업 제거, v2 목록·상세·처리 이력·이용 중지 연동
    - 상품 이용 승인 관리 목록·승인·반려를 v2 로 전환

    [비고]
    - 신청 취소(CANCEL)는 시안에 없어 기획 확인 전까지 회색 태그로 임시 표시
    """

    @Test func readsIssueSectionAndKeepsItOutOfTheComment() {
        #expect(RedmineComment.listedIssues(mr112).map(\.id) == [37742, 37737])
        #expect(RedmineComment.listedIssues(mr112).first?.title == "상품 신청 내역 > API 연동")
        #expect(RedmineComment.listedIssues("[작업 내용]\n- #37742 고침").isEmpty)
        #expect(WorkCapture.issueNumber(in: ["상품 신청 내역 v2 API 연동", mr112]) == 37742)
        let note = RedmineComment.fromMR(mr112, mr: 112, issue: 37742)
        #expect(!note.contains("[일감]"))
        #expect(!note.contains("#"))
    }

    @Test func registersEveryListedIssueEvenWhenTheBookDoesNotKnowIt() {
        var log = WorkLog(projects: ["cdh"])
        log.entries = [WorkEntry(day: "2026-10-21", project: "cdh", title: "상품 신청 내역 v2 API 연동", issue: 37742, note: mr112,
                                 source: "mr:cdh/cdh-web-admin!112")]
        WorkCapture.tidyMRNotes(&log)
        #expect(log.entries.map(\.issue) == [37742, 37737])
        // 장부에 없는 일감도 [일감]에 적은 이름으로 줄 제목을 단다
        #expect(log.entries[1].title == "상품 이용 승인 관리 > API 연동")
        // 잎 이름이 같아도(API 연동) [일감] 이름의 화면 낱말로 줄 주인을 가른다. 어느 쪽인지 모를 줄은 둘 다 남는다
        #expect(log.entries[0].note == """
        [작업 내용]
        - provider 스웨거 타입 재생성(v2 이용 신청 API 추가)
        - 상품 신청 내역 목업 제거, v2 목록·상세·처리 이력·이용 중지 연동

        [비고]
        - MR !112
        - 신청 취소(CANCEL)는 시안에 없어 기획 확인 전까지 회색 태그로 임시 표시
        """)
        #expect(log.entries[1].note == """
        [작업 내용]
        - provider 스웨거 타입 재생성(v2 이용 신청 API 추가)
        - 상품 이용 승인 관리 목록·승인·반려를 v2 로 전환

        [비고]
        - MR !112
        """)
        #expect(WorkCapture.tidyMRNotes(&log) == 0)
    }

    @Test func keepsALineForTheSameIssueFromAnotherMR() {
        // 같은 날 #37737 줄이 이미 있어도 !112가 다룬 #37737 줄을 따로 둔다. 보낼 때는 일감별로 한 댓글로 모인다
        var log = WorkLog(projects: ["cdh"])
        log.entries = [
            WorkEntry(day: "2026-10-21", project: "cdh", title: "승인 확인 창 시안 반영", issue: 37737,
                      note: "[작업 내용]\n- 승인 확인 창 시안 반영", source: "mr:cdh/cdh-web-admin!111"),
            WorkEntry(day: "2026-10-21", project: "cdh", title: "상품 신청 내역 v2 API 연동", issue: 37742, note: mr112,
                      source: "mr:cdh/cdh-web-admin!112"),
        ]
        WorkCapture.tidyMRNotes(&log)
        #expect(log.entries.filter { $0.issue == 37737 }.count == 2)
        let updates = WorkReport.redmineUpdates(log.entries, log: log)
        #expect(updates.filter { $0.issue == 37737 }.count == 1)
        let approval = updates.first { $0.issue == 37737 }?.note ?? ""
        #expect(approval.contains("승인 확인 창 시안 반영"))
        #expect(approval.contains("목록·승인·반려를 v2 로 전환"))
    }

    /// 일감별 묶음으로 쓴 MR (2026-10-21부터 쓰는 꼴).
    private let perIssue = """
    [일감]
    - #37742 상품 신청 내역 > API 연동
    - #37737 상품 이용 승인 관리 > API 연동

    [작업 내용]
    - provider 스웨거 타입 재생성

    #37742 상품 신청 내역 > API 연동
    [작업 내용]
    - 목업 제거, v2 목록·상세·처리 이력·이용 중지 연동
    [연동 API]
    - GET /api/cdh/v2/marketplace/provider/dataset/usage : 목록
    [비고]
    - 신청 취소 태그 임시 표시

    #37737 상품 이용 승인 관리 > API 연동
    [작업 내용]
    - 승인 관리를 v2 로 전환
    [연동 API]
    - POST /api/cdh/v2/marketplace/provider/dataset/usage/approve : 승인
    [확인 방법]
    - 승인 창 확인
    """

    @Test func usesPerIssueBlocksAsWritten() {
        #expect(RedmineComment.listedIssues(perIssue).map(\.id) == [37742, 37737])
        let mine = RedmineComment.fromMR(perIssue, mr: 112, issue: 37742, siblings: [37737])
        #expect(mine == """
        [작업 내용]
        - provider 스웨거 타입 재생성
        - 목업 제거, v2 목록·상세·처리 이력·이용 중지 연동

        [연동 API]
        - GET /api/cdh/v2/marketplace/provider/dataset/usage : 목록

        [비고]
        - MR !112
        - 신청 취소 태그 임시 표시
        """)
        let other = RedmineComment.fromMR(perIssue, mr: 112, issue: 37737, siblings: [37742])
        #expect(other == """
        [작업 내용]
        - provider 스웨거 타입 재생성
        - 승인 관리를 v2 로 전환

        [연동 API]
        - POST /api/cdh/v2/marketplace/provider/dataset/usage/approve : 승인

        [비고]
        - MR !112
        """)
        // 장부에 넣으면 일감마다 줄이 생기고 묶음 머리가 줄 제목이 된다
        var log = WorkLog(projects: ["cdh"])
        log.entries = [WorkEntry(day: "2026-10-21", project: "cdh", title: "v2 API 연동", issue: 37742, note: perIssue,
                                 source: "mr:cdh/cdh-web-admin!112")]
        WorkCapture.tidyMRNotes(&log)
        #expect(log.entries.map(\.issue) == [37742, 37737])
        #expect(log.entries[1].title == "상품 이용 승인 관리 > API 연동")
        #expect(log.entries[1].note == other)
    }
}
