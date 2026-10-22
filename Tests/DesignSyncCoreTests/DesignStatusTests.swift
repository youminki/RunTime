import Foundation
import Testing
@testable import DesignSyncCore

/// 완료된 시안에 생긴 변경만 알리려고 화면 상태를 가리고, 작업 중 변경은 하루 한 건으로 합친다.
@Suite struct DesignStatusTests {
    private func screen(_ path: String, title: String = "", section: String, id: String = "SC-1") -> ScreenSnapshot {
        ScreenSnapshot(frameID: "1", screenID: id, title: title, menuPath: path, sectionName: section)
    }

    @Test func singleTagAppliesToEveryScreen() {
        let rules = DesignStatusRules()
        #expect(DesignStatus.state(of: screen("상품 > 목록", section: "[완료] 상품"), rules: rules) == .done)
        #expect(DesignStatus.state(of: screen("상품 > 목록", section: "[수정중] 상품"), rules: rules) == .working)
        #expect(DesignStatus.state(of: screen("상품 > 목록", section: "[작업 중/보류] 상품"), rules: rules) == .working)
    }

    /// 한 섹션에 상태가 둘 이상 섞인 실제 꼴을 지어낸 메뉴로 옮겼다.
    @Test func mixedSectionPicksTheSegmentThatMatchesTheScreen() {
        let rules = DesignStatusRules()
        let section = "[완료] 상품 > 상품 목록 / [수정중] 상품 등록 (옵션 선택 후)"
        #expect(DesignStatus.state(of: screen("상품 > 상품 목록", title: "상품 목록", section: section), rules: rules) == .done)
        #expect(DesignStatus.state(of: screen("상품 > 상품 목록 > 상품 등록", title: "상품 등록", section: section), rules: rules) == .working)
        // 탭 단위 상태: 경로는 앞 구간과 같아도 화면명 뒷부분이 뒤 구간 이름이다
        let tabs = "[완료] 상품 > 상품 상세 / [수정중] 옵션·재고 정보 탭"
        #expect(DesignStatus.state(of: screen("상품 > 상품 상세", title: "상품 상세 : (2)재고 정보", section: tabs), rules: rules) == .working)
        #expect(DesignStatus.state(of: screen("상품 > 상품 상세", title: "상품 상세 : (1)개요", section: tabs), rules: rules) == .done)
        #expect(DesignStatus.state(of: screen("상품 > 상품 상세", title: "상품 상세 : (3)리뷰 - 정보 수정", section: tabs), rules: rules) == .done)
        let plus = "[작업예정] 주문 관리 > 통계 + [완료] 주문 관리 > 통계 > 취소 내역"
        #expect(DesignStatus.state(of: screen("주문 관리 > 통계", section: plus), rules: rules) == .working)
        #expect(DesignStatus.state(of: screen("주문 관리 > 통계 > 취소 내역 목록", title: "취소 내역 목록", section: plus), rules: rules) == .done)
    }

    @Test func untaggedScreensFollowTheRule() {
        let plain = screen("상품 > 목록", section: "상품_v0.4")
        #expect(DesignStatus.state(of: plain, rules: DesignStatusRules(untaggedIsDone: true)) == .done)
        #expect(DesignStatus.state(of: plain, rules: DesignStatusRules(untaggedIsDone: false)) == .unknown)
    }

    @Test func manualStatusWinsAndTheMostSpecificPathWins() {
        let s = screen("상품 > 목록 > 상세", section: "[완료] 상품")
        #expect(DesignStatus.state(of: s, rules: DesignStatusRules(overrides: ["상품": false])) == .working)
        #expect(DesignStatus.state(of: s, rules: DesignStatusRules(overrides: ["상품": false, "상품 > 목록": true])) == .done)
        #expect(DesignStatus.state(of: s, rules: DesignStatusRules(overrides: ["상품": true, "screen:SC-1": false])) == .working)
        // `상품 관리`는 `상품`의 하위가 아니다
        #expect(DesignStatus.state(of: screen("상품 관리 > 목록", section: "[완료] 상품 관리"), rules: DesignStatusRules(overrides: ["상품": false])) == .done)
    }

    @Test func coversOnlyWholePathSegments() {
        #expect(DesignStatus.covers("상품", "상품"))
        #expect(DesignStatus.covers("상품", "상품 > 목록"))
        #expect(!DesignStatus.covers("상품", "상품 관리 > 목록"))
        #expect(DesignSource(fileKey: "F", alerts: ["상품"]).alerts("상품 > 목록 > 새 화면"))
        #expect(!DesignSource(fileKey: "F", alerts: ["상품 > 목록"]).alerts("상품 > 상세"))
    }
}

@Suite struct DesignPhaseTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func snap(_ frame: String, text: String, section: String, path: String = "상품 > 목록", id: String = "SC-1") -> ScreenSnapshot {
        ScreenSnapshot(frameID: frame, screenID: id, title: "목록", menuPath: path, pageID: "1:1", sectionName: section,
                       items: [SpecItem(number: "1", text: text)])
    }

    private func capture(_ screens: [ScreenSnapshot], at date: Date, rules: DesignStatusRules = DesignStatusRules()) -> DesignCapture {
        var capture = DesignCapture(fileKey: "F", fileName: "데모", lastModified: ISO8601DateFormatter().string(from: date),
                                    coveredPages: ["1:1"], present: Set(screens.map(\.candidateID)),
                                    fetched: Set(screens.map(\.candidateID)), screens: screens, changelog: nil)
        capture.rules = rules
        return capture
    }

    private var seoul: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    @Test func phasesFollowTheStateBeforeAndAfter() {
        var history = DesignHistory()
        history.record(capture([snap("1", text: "검색", section: "[완료] 상품"), snap("2", text: "필터", section: "[수정중] 상품", id: "SC-2"),
                                snap("3", text: "정렬", section: "[수정중] 상품", id: "SC-3")], at: t0), at: t0, calendar: seoul)
        let t1 = t0.addingTimeInterval(60)
        let events = history.record(capture([snap("1", text: "검색 버튼", section: "[완료] 상품"),
                                             snap("2", text: "필터 초기화", section: "[수정중] 상품", id: "SC-2"),
                                             snap("3", text: "정렬", section: "[완료] 상품", id: "SC-3")], at: t1), at: t1, calendar: seoul)
        #expect(events.map(\.phase) == [.afterDone, .working, .completed])
        #expect(events.map(\.isImportant) == [true, false, true])
        // 확인 안 함 건수는 작업 중 변경을 세지 않는다
        #expect(history.unseenCount == 2)
        #expect(history.menus().first?.unseen == 2)
    }

    @Test func newScreenInADoneMenuIsAdditionalWork() {
        // 완료로 정한 메뉴에 새 화면이 생기면 추가 작업이라 완료 후 변경으로 본다
        let rules = DesignStatusRules(overrides: ["상품 > 목록": true], untaggedIsDone: false)
        var history = DesignHistory()
        history.record(capture([snap("1", text: "검색", section: "")], at: t0, rules: rules), at: t0, calendar: seoul)
        let t1 = t0.addingTimeInterval(60)
        let added = history.record(capture([snap("1", text: "검색", section: ""), snap("2", text: "새 탭", section: "", id: "SC-2"),
                                            snap("3", text: "새 모달", section: "", path: "상품 > 등록", id: "SC-3")], at: t1, rules: rules),
                                   at: t1, calendar: seoul)
        #expect(added.map(\.screenID) == ["SC-2", "SC-3"])
        #expect(added.map(\.phase) == [.afterDone, .working])
    }

    @Test func workingChangesOnTheSameDayBecomeOneEvent() throws {
        var history = DesignHistory()
        let start = seoul.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))!
        history.record(capture([snap("1", text: "검색", section: "[수정중] 상품")], at: start), at: start, calendar: seoul)
        let t1 = start.addingTimeInterval(3600)
        let first = history.record(capture([snap("1", text: "검색 버튼", section: "[수정중] 상품")], at: t1), at: t1, calendar: seoul)
        #expect(first.count == 1)
        let t2 = start.addingTimeInterval(7200)
        // 같은 날 또 바뀌면 새 건을 만들지 않고 그날 처음 상태와 견준 한 건으로 고친다
        #expect(history.record(capture([snap("1", text: "검색 버튼 (Enter)", section: "[수정중] 상품")], at: t2), at: t2, calendar: seoul).isEmpty)
        let event = try #require(history.events.only)
        #expect(event.changes.first?.before == "검색")
        #expect(event.changes.first?.after == "검색 버튼 (Enter)")
        #expect(event.detectedAt == t2)
        #expect(event.windowStart == start)
        // 처음 상태로 되돌리면 그날 건은 없어진다
        let t3 = start.addingTimeInterval(10800)
        history.record(capture([snap("1", text: "검색", section: "[수정중] 상품")], at: t3), at: t3, calendar: seoul)
        #expect(history.events.isEmpty)
    }

    @Test func seenOrNextDayWorkingChangesStartANewEvent() {
        var history = DesignHistory()
        let start = seoul.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))!
        history.record(capture([snap("1", text: "a", section: "[수정중] 상품")], at: start), at: start, calendar: seoul)
        let t1 = start.addingTimeInterval(3600)
        let first = history.record(capture([snap("1", text: "ab", section: "[수정중] 상품")], at: t1), at: t1, calendar: seoul)
        history.seen.insert(first[0].id)
        let t2 = start.addingTimeInterval(7200)
        #expect(history.record(capture([snap("1", text: "abc", section: "[수정중] 상품")], at: t2), at: t2, calendar: seoul).count == 1)
        let nextDay = start.addingTimeInterval(86_400)
        #expect(history.record(capture([snap("1", text: "abcd", section: "[수정중] 상품")], at: nextDay), at: nextDay, calendar: seoul).count == 1)
        #expect(history.events.count == 3)
    }

    @Test func doneChangesAreNeverMerged() {
        var history = DesignHistory()
        history.record(capture([snap("1", text: "a", section: "[완료] 상품")], at: t0), at: t0, calendar: seoul)
        let t1 = t0.addingTimeInterval(60)
        history.record(capture([snap("1", text: "ab", section: "[완료] 상품")], at: t1), at: t1, calendar: seoul)
        let t2 = t0.addingTimeInterval(120)
        #expect(history.record(capture([snap("1", text: "abc", section: "[완료] 상품")], at: t2), at: t2, calendar: seoul).count == 1)
        #expect(history.events.count == 2)
    }

    @Test func changelogLinksToItsTable() {
        let table = Spec.changelog("3:1", rows: [("0.2", "2026-09-01", "목록 수정")])
        #expect(SpecExtractor.changelog(in: table, page: Spec.page1).first?.frameID == "3:1")
    }

    /// 단계·알림 칸이 생기기 전에 저장한 기록과 설정도 그대로 읽힌다 (이미 쓰고 있는 사람의 기록을 잃지 않게).
    @Test func olderRecordsAndSettingsStillDecode() throws {
        let source = try JSONDecoder().decode(DesignSource.self, from: Data(#"{"fileKey":"F","name":"데모","menus":[],"skippedPages":[]}"#.utf8))
        #expect(source.alerts.isEmpty && source.statusOverrides.isEmpty && source.hiddenMenus.isEmpty && !source.isHidden)
        #expect(DesignSource(fileKey: "F", hiddenMenus: ["상품 > 목록"]).hides("상품 > 목록 > 상세"))
        #expect(!DesignSource(fileKey: "F", hiddenMenus: ["상품 > 목록"]).hides("상품 > 상세"))
        #expect(DesignSource(fileKey: "F", isHidden: true).hides("아무 경로"))
        let old = """
        {"files":{"F":{"name":"데모","lastModified":"x","screens":{},"checkedAt":{},"fetchedVersion":{},"syncedAt":"2026-10-22T00:00:00.000Z",
          "ignored":{},"changelog":[{"pageID":"1:1","pageName":"p","date":"2026-01-01","order":0,"text":"t"}]}},
         "events":[{"id":"2E9B6A3C-6F7B-4B8B-9C66-7E1C2D3A4B5C","fileKey":"F","fileName":"데모","screenID":"SC-1","title":"t","menuPath":"p",
           "detectedAt":"2026-10-22T00:00:00.000Z","windowEnd":"2026-10-22T00:00:00.000Z","kind":"changed","changes":[]}],
         "seen":[]}
        """
        let history = try DesignHistoryFile.decode(Data(old.utf8))
        #expect(history.events.first?.phase == nil)
        #expect(history.events.first?.isImportant == true)
        #expect(history.files["F"]?.changelog.first?.frameID == nil)
        #expect(history.files["F"]?.mergeBase == nil)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
