import Foundation
import Testing
@testable import DesignSyncCore

/// Claude에 붙일 글: 바뀐 것은 전·후 원문으로, 반영한 항목은 빼고, 할 일을 분명히 적는다.
@Suite struct ClaudePromptTests {
    private func event(_ changes: [SpecChange], at seconds: TimeInterval = 1_790_000_000) -> DesignEvent {
        DesignEvent(fileKey: "F", fileName: "[Demo] 화면설계서", frameID: "1:1", screenID: "SC-RSV-001", title: "예약 조회",
                    menuPath: "예약 > 예약 조회", detectedAt: Date(timeIntervalSince1970: seconds), windowStart: nil,
                    windowEnd: Date(timeIntervalSince1970: seconds), kind: .changed, changes: changes, phase: .afterDone)
    }

    @Test func changesQuoteBeforeAndAfterAndSkipApplied() {
        let spec = SpecChange(layer: .spec, op: .modified, label: "1. 검색", before: "검색\n이름, 직급", after: "검색\n이름")
        let text = SpecChange(layer: .text, op: .added, label: "", after: "엑셀 다운로드",
                              place: SpecPlace(path: ["툴바", "버튼"], x: 0.8, y: 0.05, width: 0.1, height: 0.04))
        let done = SpecChange(layer: .text, op: .removed, label: "", before: "인쇄")
        let first = event([spec, text, done])
        let prompt = ClaudePrompt.changes([first], screen: nil, link: URL(string: "https://figma.com/x"), done: [first.id: [done.key]])
        #expect(prompt.contains("[화면] SC-RSV-001 예약 조회 (예약 > 예약 조회)\n피그마: https://figma.com/x\n[바뀐 것]\n"))
        #expect(prompt.contains("- 기능 명세 수정: 1. 검색 (바뀐 줄만, - 전 / + 후)\n    - 이름, 직급\n    + 이름\n"))
        #expect(prompt.contains("- 목업 문구 추가: \"엑셀 다운로드\" (위치: 화면 위쪽 오른쪽, 툴바)"))
        #expect(!prompt.contains("인쇄"))
        #expect(prompt.contains("[요청] [바뀐 것]만 반영하고"))
        // 작성자·섹션 같은 화면 정보와 전체 명세는 마크업과 상관없어 넣지 않는다
        let author = SpecChange(layer: .header, op: .modified, label: "작성자", before: "가", after: "나")
        #expect(!ClaudePrompt.changes([event([author])], screen: nil, link: nil).contains("작성자"))
    }

    @Test func menuGroupsChangesByScreenAndSkipsDoneScreens() {
        let first = event([SpecChange(layer: .text, op: .added, label: "", after: "엑셀 다운로드")])
        let applied = SpecChange(layer: .text, op: .removed, label: "", before: "인쇄")
        let second = event([applied])
        let screen = ScreenSnapshot(frameID: "1:1", screenID: "SC-RSV-001", title: "예약 조회", menuPath: "예약 > 예약 조회",
                                    items: [SpecItem(number: "1", text: "검색")])
        let other = ScreenSnapshot(frameID: "1:2", screenID: "SC-RSV-002", title: "예약 상세", menuPath: "예약 > 예약 상세")
        let prompt = ClaudePrompt.menu([(screen, [first], URL(string: "https://figma.com/a")), (other, [second], nil)],
                                       path: "예약", done: [second.id: [applied.key]])
        #expect(prompt.hasPrefix("아래 피그마 화면설계서 ‘예약’ 메뉴의 변경을"))
        #expect(prompt.contains("[화면] SC-RSV-001 예약 조회 (예약 > 예약 조회)\n피그마: https://figma.com/a"))
        #expect(prompt.contains("엑셀 다운로드"))
        // 모두 반영한 화면과 화면마다의 전체 명세는 넣지 않는다
        #expect(!prompt.contains("SC-RSV-002"))
        #expect(!prompt.contains("[지금 기능 명세]"))
    }

    @Test func menuBuildListsRemainingSpecsAndSkipsFinishedScreens() {
        let open = ScreenSnapshot(frameID: "1:1", screenID: "SC-RSV-001", title: "예약 조회", menuPath: "예약 > 예약 조회",
                                  items: [SpecItem(number: "1", text: "검색"), SpecItem(number: "2", text: "목록")])
        let done = ScreenSnapshot(frameID: "1:2", screenID: "SC-RSV-002", title: "예약 상세", menuPath: "예약 > 예약 상세",
                                  items: [SpecItem(number: "1", text: "상세")])
        let prompt = ClaudePrompt.menuBuild([(open, URL(string: "https://figma.com/a"), ["검색"]), (done, nil, ["상세"])],
                                            path: "예약")
        #expect(prompt.contains("[화면] SC-RSV-001 예약 조회 (예약 > 예약 조회)\n피그마: https://figma.com/a"))
        #expect(prompt.contains("[남은 기능 명세] 1/2 (나머지는 구현함)\n2. 목록"))
        #expect(!prompt.contains("SC-RSV-002"))
    }

    /// 같은 항목을 여러 번 고친 것은 처음→마지막 한 줄로, 되돌려 같아진 것과 더했다 지운 것은 뺀다.
    @Test func repeatedEditsMergeIntoOneLine() {
        let edits = [event([SpecChange(layer: .text, op: .modified, label: "", before: "검색", after: "조회", nodeID: "9:1"),
                            SpecChange(layer: .text, op: .added, label: "", after: "임시", nodeID: "9:2")], at: 1_790_000_000),
                     event([SpecChange(layer: .text, op: .modified, label: "", before: "조회", after: "찾기", nodeID: "9:1"),
                            SpecChange(layer: .text, op: .removed, label: "", before: "임시", nodeID: "9:2")], at: 1_790_000_600)]
        let lines = ClaudePrompt.changeLines(edits, done: [:])
        #expect(lines == ["[바뀐 것]", "- 목업 문구 수정: \"검색\" → \"찾기\""])
        let back = [event([SpecChange(layer: .text, op: .modified, label: "", before: "검색", after: "조회", nodeID: "9:1")]),
                    event([SpecChange(layer: .text, op: .modified, label: "", before: "조회", after: "검색", nodeID: "9:1")], at: 1_790_000_600)]
        #expect(ClaudePrompt.changeLines(back, done: [:]).isEmpty)
    }

    /// 피그마 링크가 있으면 Claude가 피그마에서 읽으니 목업 문구를 넣지 않는다.
    @Test func buildSkipsMockupTextsWhenLinked() {
        var screen = ScreenSnapshot(frameID: "1:1", screenID: "SC-RSV-001", title: "예약 조회", menuPath: "예약",
                                    items: [SpecItem(number: "1", text: "검색")])
        screen.texts = ["9:1": "엑셀 다운로드"]
        #expect(!ClaudePrompt.build(screen, link: URL(string: "https://figma.com/a")).contains("[목업 문구]"))
        #expect(ClaudePrompt.build(screen, link: nil).contains("엑셀 다운로드"))
    }

    /// 섹션 표시만 바뀐 변경은 마크업할 일로 세지 않는다. 작업대 건수와 문구가 어긋나지 않게 한다.
    @Test func sectionOnlyChangeNeedsNoMarkup() {
        let section = event([SpecChange(layer: .header, op: .modified, label: "섹션", before: "[수정중] 목록", after: "[완료] 목록")])
        #expect(!section.needsMarkup)
        #expect(ClaudePrompt.changeLines([section], done: [:]).isEmpty)
        #expect(event([SpecChange(layer: .header, op: .modified, label: "화면명", before: "목록", after: "조회")]).needsMarkup)
    }

    @Test func lineDiffKeepsOrder() {
        #expect(ClaudePrompt.lineDiff("a\nb\nc\nd", "a\nB\nc\nd\ne") == ["- b", "+ B", "+ e"])
    }

    @Test func buildLeavesOutBuiltItems() {
        let screen = ScreenSnapshot(frameID: "1:1", screenID: "SC-RSV-001", title: "예약 조회", menuPath: "예약 > 예약 조회",
                                    items: [SpecItem(number: "1", text: "검색"), SpecItem(number: "2", text: "목록")])
        let prompt = ClaudePrompt.build(screen, link: nil, built: ["검색"])
        #expect(prompt.contains("[남은 기능 명세] 1/2 (나머지는 구현함)\n2. 목록"))
        #expect(!prompt.contains("1. 검색"))
    }

    /// 상태 표시가 없는 화면의 변경은 작업 중이 아니라 모르는 상태로 남기고, 같은 날 것은 한 건으로 합친다.
    @Test func unmarkedScreensGetTheirOwnPhase() {
        let rules = DesignStatusRules(untaggedIsDone: nil)
        var history = DesignHistory()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func capture(_ text: String, at minutes: Double) -> DesignCapture {
            var capture = DesignCapture(fileKey: "F", fileName: "F", lastModified: "v\(minutes)", coveredPages: ["p"], present: ["1:1"],
                                        fetched: ["1:1"], screens: [ScreenSnapshot(frameID: "1:1", screenID: "SC-1", pageID: "p", sectionName: "예약",
                                                                                 items: [SpecItem(number: "1", text: text)])],
                                        changelog: nil)
            capture.rules = rules
            return capture
        }
        history.record(capture("검색", at: 0), at: start)
        let first = history.record(capture("검색 버튼", at: 1), at: start.addingTimeInterval(60))
        #expect(first.map(\.phase) == [.unmarked])
        #expect(first.first?.isImportant == true)
        history.record(capture("검색 버튼 클릭", at: 2), at: start.addingTimeInterval(120))
        #expect(history.events.count == 1)
    }
}
