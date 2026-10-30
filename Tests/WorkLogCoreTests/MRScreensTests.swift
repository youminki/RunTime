import Foundation
import Testing
@testable import WorkLogCore

struct MRScreensTests {

    private let verifyNote = """
    ### AI 검증 (`a1eb0702`)

    **[빌드/테스트]**

    | 단계 | 명령 | 결과 | 시간 |
    |---|---|---|---|
    | 설치 | `npm ci` | 통과 | 0초 |

    **[화면 확인]**

    **1. 폴더 이동 후 행 선택 시 하단 액션 바** (`/data-collection/shared-files`): 확인됨

    수정 후 화면에서는 액션 바가 뜹니다.

    | 수정 전 | 수정 후 |
    |---|---|
    | (캡처 없음) | ![수정 후](/uploads/c797/after_0.png) |

    **2. 파일 상세 패널** (`/data-collection/shared-files`): 문제 있음

    | 수정 전 | 수정 후 |
    |---|---|
    | (캡처 없음) | ![수정 후](/uploads/8acf/after_1.png) |

    **3. 트리 검색 드롭다운** (`/data-collection/shared-files`): 확인됨

    | 수정 전 | 수정 후 |
    |---|---|
    | ![수정 전](/uploads/aaaa/before_2.png) | ![수정 후](/uploads/3260/after_2.png) |

    <sub>AI 검증</sub>
    """

    @Test func readsVerifyTablesAndSkipsProblems() {
        let screens = MRScreens.screens(description: "", notes: [verifyNote])
        #expect(screens.count == 2)
        #expect(screens[0].title == "폴더 이동 후 행 선택 시 하단 액션 바")
        #expect(screens[0].before == nil)
        #expect(screens[0].after == "/uploads/c797/after_0.png")
        #expect(screens[1].before == "/uploads/aaaa/before_2.png")
        #expect(screens[1].after == "/uploads/3260/after_2.png")
    }

    @Test func usesLatestNoteWithScreensAndDescription() {
        let old = "| 수정 전 | 수정 후 |\n|---|---|\n| ![a](/uploads/old/x.png) | ![b](/uploads/old/y.png) |"
        let description = "[작업 내용]\n- 입력 차단\n\n수정 전(-30 입력)\n![image](/uploads/d1/before.png)\n수정 후\n![image](/uploads/d2/after.png)"
        let screens = MRScreens.screens(description: description, notes: [old, verifyNote, "LGTM"])
        #expect(screens.first == MRScreens.Screen(title: nil, before: "/uploads/d1/before.png", after: "/uploads/d2/after.png"))
        #expect(!screens.contains { $0.before == "/uploads/old/x.png" })
        #expect(screens.count == 3)
    }

    @Test func ignoresUnlabeledAndOutsideImages() {
        let text = "![diagram](/uploads/z/diagram.png)\n![수정 후](https://example.com/a.png)\n<img src=\"/uploads/h/after.png\" alt=\"수정 후\">"
        let screens = MRScreens.parse(text)
        #expect(screens == [MRScreens.Screen(title: nil, before: nil, after: "/uploads/h/after.png")])
    }

    @Test func noteSectionStacksImagesUnderTitles() {
        let screens = [MRScreens.Screen(title: "검색 드롭다운 (`/a`)", before: "/uploads/a/b.png", after: "/uploads/a/c.png"),
                       MRScreens.Screen(title: nil, before: nil, after: "/uploads/a/d.png")]
        let files = ["0:before": "mr12-1-before.png", "0:after": "mr12-1-after.png", "1:after": "mr12-2-after.png"]
        let html = MRScreens.noteSection(screens, files: files, html: true)
        #expect(html.hasPrefix("<p>[수정 전·후 화면]</p>"))
        #expect(html.contains("<strong>1. 검색 드롭다운 (/a)</strong>"))
        #expect(html.contains("<p>수정 전<br />\n<img src=\"mr12-1-before.png\" alt=\"수정 전\" /></p>"))
        #expect(html.contains("<strong>2. 화면</strong>"))
        let plain = MRScreens.noteSection(screens, files: files, html: false)
        #expect(plain.contains("수정 후\n!mr12-1-after.png!"))
        #expect(MRScreens.noteSection(screens, files: [:], html: true).isEmpty)
        #expect(MRScreens.filename(mr: 12, index: 0, kind: .after, path: "/uploads/a/x.PNG") == "mr12-1-after.png")
    }

    @Test func capsImageCount() {
        let rows = (0..<6).map { "| ![수정 전](/uploads/\($0)/b.png) | ![수정 후](/uploads/\($0)/a.png) |" }
        let text = "| 수정 전 | 수정 후 |\n|---|---|\n" + rows.joined(separator: "\n")
        let screens = MRScreens.limited(MRScreens.screens(description: text, notes: []))
        #expect(screens.flatMap(\.images).count == MRScreens.maxImages)
    }

    // MARK: 일감마다 나누기

    /// 한 MR이 두 일감을 다룰 때: #37742 대표, #37743 따로 나눈 줄.
    private func twoIssueLog(body: String) -> WorkLog {
        var log = WorkLog(projects: ["p"])
        log.issues["37742"] = IssueInfo(id: 37742, subject: "상품 신청 내역", project: "p", path: [], fetchedAt: Date())
        log.issues["37743"] = IssueInfo(id: 37743, subject: "회원 탈퇴 팝업", project: "p", path: [], fetchedAt: Date())
        log.entries = [
            WorkEntry(day: "2026-10-30", project: "p", title: "a", issue: 37742, source: "mr:g/web!14", mrBody: body),
            WorkEntry(day: "2026-10-30", project: "p", title: "b", issue: 37743, source: "mr:g/web!14#37743", mrBody: body),
        ]
        return log
    }

    @Test func readsIssueNumbersNearImages() {
        let text = """
        #37742 상품 신청 내역
        ![수정 전](/uploads/a/1.png)
        ![수정 후](/uploads/a/2.png)

        #37743 회원 탈퇴
        ### 탈퇴 팝업
        ![수정 후](/uploads/b/1.png)

        ### 검색 (#37742)
        - 입력 막기 (#37743)
        ![수정 후](/uploads/c/1.png)
        """
        let screens = MRScreens.parse(text)
        #expect(screens.map(\.issues) == [[37742], [37743], [37743]])
        #expect(screens[0].before != nil && screens[0].after != nil)
        #expect(screens[0].title == "상품 신청 내역")
        // 바로 위 줄의 번호가 항목 제목 번호보다 앞선다
        #expect(screens[2].title == "검색")
    }

    @Test func splitsScreensAcrossIssuesOfOneMR() {
        let body = """
        [일감]
        - #37742 상품 신청 내역
        - #37743 회원 탈퇴 팝업

        [작업 내용]
        - 신청 내역 필터 정렬 (#37742)
        - 탈퇴 사유 입력 막기 (#37743)
        """
        let log = twoIssueLog(body: body)
        let split = MRScreens.splits(log)["g/web!14"]
        #expect(split?.primary == 37742)
        #expect(split?.issues == [37742, 37743])
        guard let split else { return }
        let screens = [
            MRScreens.Screen(title: "필터 정렬", before: "/uploads/1/b.png", after: "/uploads/1/a.png"),
            MRScreens.Screen(title: "탈퇴 사유 입력", before: nil, after: "/uploads/2/a.png"),
            MRScreens.Screen(title: "공통 헤더", before: nil, after: "/uploads/3/a.png"),
            MRScreens.Screen(title: nil, before: nil, after: "/uploads/4/a.png", issues: [37743]),
            MRScreens.Screen(title: nil, before: nil, after: "/uploads/5/a.png", issues: [99999]),
        ]
        let first = MRScreens.share(screens, issue: 37742, split: split)
        let second = MRScreens.share(screens, issue: 37743, split: split)
        #expect(first.map(\.after) == ["/uploads/1/a.png", "/uploads/3/a.png"])
        #expect(second.map(\.after) == ["/uploads/2/a.png", "/uploads/4/a.png"])
        #expect(MRScreens.owners(screens[0], split: split).match == .title)
        #expect(MRScreens.owners(screens[2], split: split).match == .primary)
        #expect(MRScreens.owners(screens[3], split: split).match == .number)
        // 일지에 없는 일감 번호가 적힌 화면은 어디에도 붙지 않는다
        #expect(MRScreens.owners(screens[4], split: split).issues.isEmpty)
    }

    @Test func singleIssueTakesUnmarkedScreens() {
        let screens = [MRScreens.Screen(title: "목록", before: nil, after: "/uploads/1/a.png"),
                       MRScreens.Screen(title: nil, before: nil, after: "/uploads/2/a.png", issues: [5])]
        #expect(MRScreens.share(screens, issue: 5, split: .single(5)).count == 2)
        #expect(MRScreens.share(screens, issue: 6, split: .single(6)).count == 1)
    }

    @Test func capsImagesPerIssueNotPerMR() {
        let screens = (0..<6).map { MRScreens.Screen(title: nil, before: "/uploads/\($0)/b.png", after: "/uploads/\($0)/a.png",
                                                       issues: [$0 < 3 ? 1 : 2]) }
        let split = MRScreens.Split(primary: 1, issues: [1, 2])
        #expect(MRScreens.screens(description: "", notes: []).isEmpty)
        #expect(MRScreens.limited(MRScreens.share(screens, issue: 2, split: split)).flatMap(\.images).count == 6)
    }

    /// MR !111 꼴: 두 일감 본문에 같은 낱말(승인, 이용)이 섞여도 일감 이름이 겹치는 쪽으로 간다.
    /// 낱말 하나만 우연히 겹친 화면(버킷 생성 대화상자)은 대표 일감이 받는다.
    @Test func prefersIssueNamesAndIgnoresChanceOverlap() {
        let body = """
        [일감]
        - #37740 상품 신청 내역 > 마크업
        - #37735 상품 이용 승인 관리 > 마크업

        #37740 상품 신청 내역 > 마크업
        [작업 내용]
        - 상품 신청 상세의 승인 건 이용 중지

        #37735 상품 이용 승인 관리 > 마크업
        [작업 내용]
        - 체크 일괄 승인·반려, 위젯 추가 대화상자
        """
        var log = WorkLog(projects: ["p"])
        log.entries = [
            WorkEntry(day: "2026-10-30", project: "p", title: "a", issue: 37740, source: "mr:g/web!111", mrBody: body),
            WorkEntry(day: "2026-10-30", project: "p", title: "b", issue: 37735, source: "mr:g/web!111#37735", mrBody: body),
        ]
        guard let split = MRScreens.splits(log)["g/web!111"] else { Issue.record("split 없음"); return }
        func owner(_ title: String) -> [Int] {
            MRScreens.owners(MRScreens.Screen(title: title, before: nil, after: "/uploads/x/a.png"), split: split).issues
        }
        #expect(owner("상품 이용 승인 관리 - 한 건 반려 확인 창") == [37735])
        #expect(owner("상품 신청 내역 - 승인 건 신청 상세 모달") == [37740])
        #expect(owner("버킷 생성 대화상자와 예약 이름 오류") == [37740])
        #expect(MRScreens.stems(["대화상자와", "레벨까지", "추가", "결과"]) == ["대화상자", "레벨", "추가", "결과"])
    }

    /// MR !132 꼴: AI 리뷰가 커밋마다 바뀐 부분만 다시 찍으면 앞 댓글 화면에 더한다.
    /// 표 위 문장에 다른 일감 번호가 나와도 단서로 쓰지 않고, 판단 어려움 항목은 붙이지 않는다.
    @Test func mergesIncrementalVerifyNotes() {
        let first = """
        ### AI 리뷰 (`b893`)
        **1. RPM 입력 제한** (`/a`): 확인됨

        | 수정 전 | 수정 후 |
        |---|---|
        | ![수정 전](/uploads/1/b.png) | ![수정 후](/uploads/1/a.png) |

        **2. 반영 이력의 중단 태그** (`/b`): 확인됨

        | 수정 전 | 수정 후 |
        |---|---|
        | ![수정 전](/uploads/2/b.png) | ![수정 후](/uploads/2/a.png) |
        """
        let second = """
        ### AI 리뷰 (`2db0`)
        `b893` 이후 추가된 커밋의 변경만 리뷰했습니다.
        **1. RPM 칸에 쉼표 포함 값 붙여넣기** (`/a`): 확인됨

        이번 캡처로는 -5, 1e3 입력 차단과 Resolved Time 상한, 반영 이력의 중단 태그(#38059)는 확인되지 않았습니다.

        | 수정 전 | 수정 후 |
        |---|---|
        | ![수정 전](/uploads/3/b.png) | ![수정 후](/uploads/3/a.png) |
        """
        let third = """
        ### AI 리뷰 (`4646`)
        `2db0` 이후 추가된 커밋의 변경만 리뷰했습니다.
        **1. 데이터 모델 선택 창 로딩 표시** (`/c`): 판단 어려움

        | 수정 전 | 수정 후 |
        |---|---|
        | ![수정 전](/uploads/4/b.png) | ![수정 후](/uploads/4/a.png) |
        """
        let screens = MRScreens.screens(description: "", notes: [first, second, "LGTM", third])
        #expect(screens.map(\.after) == ["/uploads/1/a.png", "/uploads/2/a.png", "/uploads/3/a.png", "/uploads/4/a.png"])
        #expect(screens[2].issues.isEmpty)
        // 판단 어려움 화면은 받아 두되 고를 때만 붙는다
        #expect(screens.map(\.unsure) == [false, false, false, true])
        let split = MRScreens.Split.single(1)
        #expect(MRScreens.share(screens, issue: 1, split: split).count == 3)
        #expect(MRScreens.share(screens, issue: 1, split: split, picks: .init(chosen: ["/uploads/4/b.png": true])).count == 4)
        // 처음부터 다시 검증한 댓글은 앞 화면을 갈아 치운다
        #expect(MRScreens.screens(description: "", notes: [first, verifyNote]).count == 2)
    }

    @Test func picksExcludeAndMoveScreens() {
        let split = MRScreens.Split(primary: 1, issues: [1, 2])
        let screens = [MRScreens.Screen(title: nil, before: nil, after: "/uploads/a/1.png"),
                       MRScreens.Screen(title: nil, before: "/uploads/b/0.png", after: "/uploads/b/1.png")]
        let picks = MRScreens.Picks(chosen: ["/uploads/a/1.png": false], moves: ["/uploads/b/0.png": 2])
        #expect(MRScreens.share(screens, issue: 1, split: split, picks: picks).isEmpty)
        #expect(MRScreens.owned(screens, issue: 1, split: split, picks: picks).count == 1)
        #expect(MRScreens.share(screens, issue: 2, split: split, picks: picks).map(\.after) == ["/uploads/b/1.png"])
        #expect(MRScreens.owners(screens[1], split: split, picks: picks).match == .moved)
        // 그 MR 줄이 없는 일감으로는 옮기지 않는다
        let stray = MRScreens.Picks(moves: ["/uploads/b/0.png": 9])
        #expect(MRScreens.owners(screens[1], split: split, picks: stray).issues == [1])
    }

    /// 이어 검증한 댓글에 같은 제목 화면이 여럿이면 앞 댓글의 그 제목 화면을 모두 바꾼다.
    @Test func incrementalNoteReplacesWholeTitleGroup() {
        func note(_ head: String, _ rows: [String]) -> String {
            head + "\n**1. 목록** (`/a`): 확인됨\n\n| 수정 전 | 수정 후 |\n|---|---|\n"
                + rows.map { "| ![수정 전](/uploads/\($0)/b.png) | ![수정 후](/uploads/\($0)/a.png) |" }.joined(separator: "\n")
                + "\n\n**2. 상세** (`/b`): 확인됨\n\n| 수정 전 | 수정 후 |\n|---|---|\n| ![수정 전](/uploads/d/b.png) | ![수정 후](/uploads/d/a.png) |"
        }
        let first = note("### AI 리뷰", ["old1", "old2"])
        let second = "`x` 이후 추가된 커밋의 변경만 리뷰했습니다.\n**1. 목록** (`/a`): 확인됨\n\n| 수정 전 | 수정 후 |\n|---|---|\n"
            + "| ![수정 전](/uploads/new1/b.png) | ![수정 후](/uploads/new1/a.png) |\n| ![수정 전](/uploads/new2/b.png) | ![수정 후](/uploads/new2/a.png) |"
        let screens = MRScreens.screens(description: "", notes: [first, second])
        #expect(screens.map(\.after) == ["/uploads/new1/a.png", "/uploads/new2/a.png", "/uploads/d/a.png"])
    }
}
