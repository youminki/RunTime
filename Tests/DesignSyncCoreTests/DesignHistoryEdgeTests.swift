import Foundation
import Testing
@testable import DesignSyncCore

/// 틀을 풀거나, 헤더를 잠깐 숨기거나, 메뉴를 골라 받을 때 틀린 변경이 남지 않는지 본다.
@Suite struct DesignHistoryEdgeTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private var t1: Date { t0.addingTimeInterval(3600) }
    private var t2: Date { t0.addingTimeInterval(7200) }

    private func snap(_ frame: String, id: String = "SC-1", text: String = "검색", path: String = "상품 > 목록",
                      candidate: String? = nil, page: String = "1:1") -> ScreenSnapshot {
        ScreenSnapshot(frameID: frame, candidateID: candidate, screenID: id, title: "목록", menuPath: path, pageID: page,
                       items: [SpecItem(number: "1", text: text)])
    }

    private func capture(_ screens: [ScreenSnapshot], present: [String]? = nil, fetched: [String]? = nil,
                         modified: String = "2026-09-21T13:30:00Z", changelog: [ChangelogEntry]? = nil,
                         menus: Set<String> = []) -> DesignCapture {
        let ids = screens.map(\.candidateID)
        return DesignCapture(fileKey: "F", fileName: "데모", lastModified: modified, coveredPages: ["1:1"],
                             present: Set(present ?? ids), fetched: Set(fetched ?? ids), screens: screens,
                             changelog: changelog, menus: menus)
    }

    @Test func screenReadFromANewHolderIsNotRemoved() {
        var history = DesignHistory()
        history.record(capture([snap("10:1", candidate: "9:1"), snap("10:2", id: "SC-2", candidate: "9:1")]), at: t0)
        // 디자이너가 틀 9:1을 풀어 두 화면이 각각 후보가 됐다
        let events = history.record(capture([snap("10:1"), snap("10:2", id: "SC-2", text: "검색 버튼")]), at: t1)
        #expect(events.map(\.kind) == [.changed])
        #expect(history.files["F"]?.screens.keys.sorted() == ["10:1", "10:2"])
        #expect(history.files["F"]?.screens["10:1"]?.candidateID == "10:1")
    }

    @Test func candidateThatOnceHeldAScreenIsNotIgnored() {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t0)
        // 헤더를 잠깐 숨겨 화면을 못 찾았다
        let gone = history.record(capture([], present: ["10:1"], fetched: ["10:1"]), at: t1)
        #expect(gone.map(\.kind) == [.removed])
        #expect(history.files["F"]?.ignored.isEmpty == true)
        #expect(history.files["F"]?.candidatesToFetch(["10:1"], menus: []) == ["10:1"])
        // 헤더를 되살리면 다시 잡힌다
        #expect(history.record(capture([snap("10:1")]), at: t2).map(\.kind) == [.added])
    }

    @Test func ignoredCandidatesAreRetriedAfterAWeek() {
        var history = DesignHistory()
        history.record(capture([snap("10:1")], present: ["10:1", "7:1"], fetched: ["10:1", "7:1"]), at: t0)
        #expect(history.files["F"]?.ignored["7:1"] == t0)
        let later = t0.addingTimeInterval((DesignFileRecord.ignoreDays + 1) * 86_400)
        history.record(capture([snap("10:1")], present: ["10:1", "7:1"], fetched: ["10:1"]), at: later)
        #expect(history.files["F"]?.ignored.isEmpty == true)
    }

    @Test func unchangedFileDoesNotAdvanceScreensThatWereNotFetched() throws {
        var history = DesignHistory()
        history.record(capture([snap("10:1"), snap("11:1", id: "SC-2", path: "상품 > 상세")],
                               modified: "2026-09-21T10:00:00Z"), at: t0)
        // 메뉴를 골라 11:1은 받지 않은 채 파일이 바뀌었다
        history.record(capture([snap("10:1")], present: ["10:1", "11:1"], fetched: ["10:1"],
                               modified: "2026-09-21T13:00:00Z", menus: ["상품 > 목록"]), at: t1)
        history.confirmUnchanged(fileKey: "F", at: t2)
        let file = try #require(history.files["F"])
        #expect(file.checkedAt["10:1"] == t2)
        #expect(file.checkedAt["11:1"] == t0)
    }

    @Test func windowStartNeverPassesWindowEnd() throws {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t1)
        // 파일을 마지막으로 고친 때가 직전 확인보다 앞선다고 나와도 구간은 거꾸로 서지 않는다
        let event = try #require(history.record(capture([snap("10:1", text: "검색 버튼")],
                                                        modified: ISO8601DateFormatter().string(from: t0)), at: t2).first)
        #expect(event.windowStart! <= event.windowEnd)
    }

    @Test func menusFilterEventsButKeepBaselinesFresh() {
        var history = DesignHistory()
        history.record(capture([snap("10:1"), snap("11:1", id: "SC-2", path: "주문 > 목록")]), at: t0)
        let events = history.record(capture([snap("10:1", text: "검색 버튼"), snap("11:1", id: "SC-2", text: "기간", path: "주문 > 목록"),
                                             snap("12:1", id: "SC-3", path: "주문 > 상세")], menus: ["상품 > 목록"]), at: t1)
        #expect(events.map(\.screenID) == ["SC-1"])
        // 지켜보지 않는 화면도 기준은 새로 맞춰, 나중에 메뉴를 넓혀도 옛 변경이 한꺼번에 나오지 않는다
        #expect(history.files["F"]?.screens["11:1"]?.items.first?.text == "기간")
        #expect(history.files["F"]?.screens["12:1"] != nil)
    }

    @Test func changelogRowsFollowTheMenusFilter() {
        var history = DesignHistory()
        let screens = [snap("10:1", id: "SC-PRD-LST-001"), snap("11:1", id: "SC-ORD-LST-001", path: "주문 > 목록")]
        history.record(capture(screens, changelog: []), at: t0)
        let mine = ChangelogEntry(pageID: "1:1", pageName: "상품", version: "0.2", date: "2026-09-01", text: "목록 (SC-PRD-LST-001) 수정")
        let other = ChangelogEntry(pageID: "1:1", pageName: "상품", version: "0.3", date: "2026-09-02", text: "주문 (SC-ORD-LST-001) 수정")
        let events = history.record(capture(screens, changelog: [mine, other], menus: ["상품 > 목록"]), at: t1)
        #expect(events.map(\.note) == ["목록 (SC-PRD-LST-001) 수정"])
    }

    @Test func changelogRowsWithSameDateAreNotRepeated() {
        var history = DesignHistory()
        let a = ChangelogEntry(pageID: "1:1", pageName: "상품", version: nil, date: "2026-09-01", order: 0, text: "목록 수정")
        let b = ChangelogEntry(pageID: "1:1", pageName: "상품", version: nil, date: "2026-09-01", order: 1, text: "상세 수정")
        history.record(capture([snap("10:1")], changelog: [a]), at: t0)
        #expect(history.record(capture([snap("10:1")], changelog: [a, b]), at: t1).count == 1)
        #expect(history.record(capture([snap("10:1")], changelog: [a, b]), at: t2).isEmpty)
    }

    @Test func missingChangelogKeepsTheOldOne() {
        var history = DesignHistory()
        let a = ChangelogEntry(pageID: "1:1", pageName: "상품", version: "0.1", date: "2026-09-01", text: "최초 작성")
        history.record(capture([snap("10:1")], changelog: [a]), at: t0)
        history.record(capture([snap("10:1")], changelog: nil), at: t1)
        #expect(history.files["F"]?.changelog == [a])
        #expect(history.record(capture([snap("10:1")], changelog: [a]), at: t2).isEmpty)
    }

    @Test func pageRenameDoesNotRepeatChangelog() {
        let table = Spec.changelog("3:1", rows: [("0.1", "2026-08-20", "최초 작성")])
        let before = SpecExtractor.changelog(in: table, page: SpecExtractor.Page(id: "1:1", name: "상품 (9/1 수정)"))
        let after = SpecExtractor.changelog(in: table, page: SpecExtractor.Page(id: "1:1", name: "상품 관리 (10/2 수정)"))
        var history = DesignHistory()
        history.record(capture([snap("10:1")], changelog: before), at: t0)
        #expect(history.record(capture([snap("10:1")], changelog: after), at: t1).isEmpty)
    }

    @Test func holderWithScreensOfSeveralMenusIsFetchedForEither() {
        var history = DesignHistory()
        history.record(capture([snap("10:1", candidate: "9:1"), snap("10:2", id: "SC-2", path: "주문 > 목록", candidate: "9:1")]), at: t0)
        let file = history.files["F"]!
        for _ in 0..<5 {
            #expect(file.candidatesToFetch(["9:1"], menus: ["주문 > 목록"]) == ["9:1"])
            #expect(file.candidatesToFetch(["9:1"], menus: ["상품 > 목록"]) == ["9:1"])
        }
        #expect(file.candidatesToFetch(["9:1"], menus: ["회원 > 목록"]).isEmpty)
    }

    @Test func screenIDsWithOtherPrefixesAreFound() {
        let entry = ChangelogEntry(pageName: "p", version: nil, date: "2026-01-01", text: "목록 (UI-ORD-LST-01), 상세 (SC-ORD-DTL-001) 수정 API-1")
        #expect(entry.screenIDs == ["UI-ORD-LST-01", "SC-ORD-DTL-001"])
    }

    @Test func candidatesInsideGroupsAreFound() {
        let group = FigmaNode(id: "4:1", name: "Group 1", type: "GROUP", children: [Spec.screen("10:1"), Spec.screen("10:2")])
        let found = FigmaAPI.candidates(in: Spec.page("1:1", "상품", [group]), pageID: "1:1")
        #expect(found.map(\.id) == ["10:1", "10:2"])
    }
}
