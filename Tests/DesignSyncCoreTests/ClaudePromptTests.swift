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
        let prompt = ClaudePrompt.changes([first], screen: nil, project: "Demo", link: URL(string: "https://figma.com/x"),
                                          done: [first.id: [done.key]])
        #expect(prompt.contains("[화면] SC-RSV-001 예약 조회\n- 프로젝트: Demo\n- 화면 경로: 예약 > 예약 조회\n- 피그마: https://figma.com/x"))
        #expect(prompt.contains("- 기능 명세 수정: 1. 검색 (바뀐 줄만, - 전 / + 후)\n    - 이름, 직급\n    + 이름\n"))
        #expect(prompt.contains("- 목업 문구 추가: \"엑셀 다운로드\" (위치: 화면 위쪽 오른쪽, 툴바)"))
        #expect(!prompt.contains("인쇄"))
        #expect(prompt.contains("[요청]\n- [바뀐 것]만 반영하고"))
    }

    @Test func lineDiffKeepsOrder() {
        #expect(ClaudePrompt.lineDiff("a\nb\nc\nd", "a\nB\nc\nd\ne") == ["- b", "+ B", "+ e"])
    }

    @Test func buildLeavesOutBuiltItems() {
        let screen = ScreenSnapshot(frameID: "1:1", screenID: "SC-RSV-001", title: "예약 조회", menuPath: "예약 > 예약 조회",
                                    items: [SpecItem(number: "1", text: "검색"), SpecItem(number: "2", text: "목록")])
        let prompt = ClaudePrompt.build(screen, project: "Demo", link: nil, built: ["검색"])
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
