import Foundation
import Testing
@testable import DesignSyncCore

@Suite struct DesignHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private var t1: Date { t0.addingTimeInterval(3600) }
    private var t2: Date { t0.addingTimeInterval(7200) }

    private func snap(_ frame: String, id: String = "SC-1", items: [(String, String)] = [("1", "검색")], page: String = "1:1",
                      path: String = "설정 > 목록", candidate: String? = nil) -> ScreenSnapshot {
        ScreenSnapshot(frameID: frame, candidateID: candidate, screenID: id, title: "목록", menuPath: path, pageID: page,
                       items: items.map { SpecItem(number: $0.0, text: $0.1) })
    }

    private func capture(_ screens: [ScreenSnapshot], present: [String]? = nil, fetched: [String]? = nil,
                         pages: [String] = ["1:1"], modified: String = "2026-09-21T13:30:00Z",
                         changelog: [ChangelogEntry]? = nil) -> DesignCapture {
        let ids = screens.map(\.candidateID)
        return DesignCapture(fileKey: "F", fileName: "데모", lastModified: modified, coveredPages: Set(pages),
                             present: Set(present ?? ids), fetched: Set(fetched ?? ids), screens: screens, changelog: changelog)
    }

    @Test func firstCaptureOnlySetsBaseline() {
        var history = DesignHistory()
        #expect(history.record(capture([snap("10:1")]), at: t0).isEmpty)
        #expect(history.files["F"]?.screens.count == 1)
    }

    @Test func changedScreenRecordsWindowFromLastCheckToLastEdit() throws {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t0)
        let lastEdit = t0.addingTimeInterval(1800)
        let modified = ISO8601DateFormatter().string(from: lastEdit)
        let events = history.record(capture([snap("10:1", items: [("1", "검색"), ("2", "초기화 버튼")])], modified: modified), at: t1)
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.kind == .changed)
        #expect(event.windowStart == t0)
        #expect(event.windowEnd == lastEdit)
        #expect(event.summary == "명세 1")
        #expect(history.events == events)
        #expect(history.unseenCount == 1)
    }

    @Test func unchangedScreenRecordsNothing() {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t0)
        #expect(history.record(capture([snap("10:1")]), at: t1).isEmpty)
    }

    @Test func newFrameWithSameScreenIDReplacesTheOldOne() throws {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t0)
        let events = history.record(capture([snap("20:1", items: [("1", "검색 (Enter 키 포함)")])]), at: t1)
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.kind == .replaced)
        #expect(event.frameID == "20:1")
        #expect(event.changes.map(\.op) == [.modified])
        #expect(history.files["F"]?.screens.keys.sorted() == ["20:1"])
    }

    @Test func addedAndRemovedScreens() {
        var history = DesignHistory()
        history.record(capture([snap("10:1"), snap("11:1", id: "SC-2")]), at: t0)
        let events = history.record(capture([snap("10:1"), snap("12:1", id: "SC-3")]), at: t1)
        #expect(events.map(\.kind) == [.added, .removed])
        #expect(events.map(\.screenID) == ["SC-3", "SC-2"])
    }

    @Test func screensOnPagesNotLookedAtAreKept() {
        var history = DesignHistory()
        history.record(capture([snap("10:1"), snap("30:1", id: "SC-9", page: "2:1")], pages: ["1:1", "2:1"]), at: t0)
        #expect(history.record(capture([snap("10:1")], pages: ["1:1"]), at: t1).isEmpty)
        #expect(history.files["F"]?.screens["30:1"] != nil)
    }

    @Test func screensNotFetchedAreAssumedUnchanged() {
        var history = DesignHistory()
        history.record(capture([snap("10:1"), snap("11:1", id: "SC-2")]), at: t0)
        // 11:1은 지켜보는 메뉴가 아니라 받지 않았지만 파일에는 그대로 있다
        let events = history.record(capture([snap("10:1")], present: ["10:1", "11:1"], fetched: ["10:1"]), at: t1)
        #expect(events.isEmpty)
        #expect(history.files["F"]?.screens["11:1"] != nil)
    }

    @Test func screenThatLeftItsHolderFrameIsRemoved() {
        var history = DesignHistory()
        history.record(capture([snap("10:1", candidate: "9:1"), snap("10:2", id: "SC-2", candidate: "9:1")]), at: t0)
        let events = history.record(capture([snap("10:1", candidate: "9:1")], present: ["9:1"], fetched: ["9:1"]), at: t1)
        #expect(events.map(\.kind) == [.removed])
        #expect(events.first?.screenID == "SC-2")
    }

    @Test func candidatesWithoutScreensAreIgnoredNextTime() {
        var history = DesignHistory()
        history.record(capture([snap("10:1")], present: ["10:1", "7:1"], fetched: ["10:1", "7:1"]), at: t0)
        let file = history.files["F"]!
        #expect(Set(file.ignored.keys) == ["7:1"])
        #expect(file.candidatesToFetch(["10:1", "7:1", "8:1"], menus: []) == ["10:1", "8:1"])
        // 메뉴를 고르면 그 메뉴 화면과 처음 보는 후보만
        #expect(file.candidatesToFetch(["10:1", "8:1"], menus: ["다른 메뉴"]) == ["8:1"])
        #expect(file.candidatesToFetch(["10:1", "8:1"], menus: ["설정 > 목록"]) == ["10:1", "8:1"])
    }

    @Test func changelogRowsBecomeEvents() throws {
        var history = DesignHistory()
        let first = ChangelogEntry(pageName: "설정", version: "0.1", date: "2026-08-20", text: "최초 작성")
        history.record(capture([snap("10:1")], changelog: [first]), at: t0)
        let added = ChangelogEntry(pageName: "설정", version: "0.2", date: "2026-09-01", text: "목록 (SC-SET-001) 정렬 변경")
        let events = history.record(capture([snap("10:1")], changelog: [first, added]), at: t1)
        let event = try #require(events.first)
        #expect(event.kind == .changelog)
        #expect(event.screenID == "SC-SET-001")
        #expect(event.title == "v0.2 2026-09-01")
        #expect(event.note == "목록 (SC-SET-001) 정렬 변경")
        // 같은 줄은 다시 남기지 않는다
        #expect(history.record(capture([snap("10:1")], changelog: [first, added]), at: t2).isEmpty)
    }

    @Test func confirmingUnchangedMovesWindowStart() throws {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t0)
        history.confirmUnchanged(fileKey: "F", at: t1)
        // 그 뒤 t1과 t2 사이에 파일이 고쳐졌다
        let edited = ISO8601DateFormatter().string(from: t2.addingTimeInterval(-60))
        let event = try #require(history.record(capture([snap("10:1", items: [("1", "검색 결과 없음 안내")])], modified: edited), at: t2).first)
        #expect(event.windowStart == t1)
    }

    @Test func menusCountUnseenAndDaysGroupNewestFirst() {
        var history = DesignHistory()
        history.record(capture([snap("10:1"), snap("11:1", id: "SC-2", path: "설정 > 상세")]), at: t0)
        let events = history.record(capture([snap("10:1", items: [("1", "검색 버튼 위치 변경")]),
                                             snap("11:1", id: "SC-2", items: [("1", "삭제 확인")], path: "설정 > 상세")]), at: t1)
        history.seen.insert(events[0].id)
        let menus = history.menus()
        #expect(menus.map(\.path) == ["설정 > 목록", "설정 > 상세"])
        #expect(menus.map(\.unseen) == [0, 1])
        #expect(menus.map(\.screenCount) == [1, 1])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let days = DesignHistory.days(history.events, calendar: calendar)
        #expect(days.count == 1)
        #expect(days[0].events.map(\.screenID) == ["SC-1", "SC-2"])
    }

    @Test func forgetRemovesFileAndItsEvents() {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t0)
        let events = history.record(capture([snap("10:1", items: [("1", "바뀜")])]), at: t1)
        history.seen.insert(events[0].id)
        history.forget(fileKey: "F")
        #expect(history.files.isEmpty)
        #expect(history.events.isEmpty)
        #expect(history.seen.isEmpty)
    }

    @Test func pruneDropsOldEvents() {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t0)
        history.record(capture([snap("10:1", items: [("1", "바뀜")])]), at: t1)
        history.prune(now: t1.addingTimeInterval(Double(DesignHistory.keepDays + 1) * 86_400))
        #expect(history.events.isEmpty)
    }

    @Test func reportFollowsCompanyFormat() {
        let event = DesignEvent(fileKey: "F", fileName: "데모", frameID: "10:1", screenID: "SC-PRD-LST-001", title: "상품 목록",
                                menuPath: "상품 관리 > 상품 목록", detectedAt: t0, windowStart: nil, windowEnd: t0, kind: .changed,
                                changes: [
                                    SpecChange(layer: .spec, op: .added, label: "8. 품절 보기 필터", after: "품절 보기 필터"),
                                    SpecChange(layer: .text, op: .modified, label: "판매 가격", before: "가격", after: "판매 가격"),
                                    SpecChange(layer: .header, op: .modified, label: "화면명", before: "목록", after: "상품 목록"),
                                ])
        #expect(event.report == """
        [디자인 변경] SC-PRD-LST-001 상품 목록
        - 화면 경로: 상품 관리 > 상품 목록
        - 명세 추가: 8. 품절 보기 필터
        - 문구 수정: 가격 → 판매 가격
        - 화면명 수정: 목록 → 상품 목록
        """)
        #expect(event.summary == "명세 1 · 문구 1 · 화면 정보 1")
    }

    @Test func shiftedNumbersAreNotCountedAsChanges() {
        let event = DesignEvent(fileKey: "F", fileName: "데모", frameID: "1", screenID: "SC-1", title: "목록", menuPath: "",
                                detectedAt: t0, windowStart: nil, windowEnd: t0, kind: .changed, changes: [
                                    SpecChange(layer: .spec, op: .added, label: "2. 구분 탭", after: "구분 탭"),
                                    SpecChange(layer: .spec, op: .renumbered, label: "3. 정렬", before: "2", after: "3"),
                                    SpecChange(layer: .spec, op: .renumbered, label: "4. 페이징", before: "3", after: "4"),
                                ])
        #expect(event.summary == "명세 1")
        #expect(event.report.hasSuffix("- 명세 추가: 2. 구분 탭\n- 명세 번호 이동 2건"))
        var onlyShifted = event
        onlyShifted.changes.removeFirst()
        #expect(onlyShifted.summary == "명세 번호 이동 2")
    }

    @Test func historyFileRoundTrips() throws {
        var history = DesignHistory()
        history.record(capture([snap("10:1")]), at: t0)
        history.record(capture([snap("10:1", items: [("1", "바뀜")])]), at: t1.addingTimeInterval(0.5))
        let decoded = try DesignHistoryFile.decode(DesignHistoryFile.encode(history))
        #expect(decoded == history)
    }

    @Test func parsesFigmaTimestamps() {
        #expect(DesignHistory.date("2026-10-19T08:21:33Z") != nil)
        #expect(DesignHistory.date("2026-10-19T08:21:33.120Z") != nil)
        #expect(DesignHistory.date("어제") == nil)
    }
}
