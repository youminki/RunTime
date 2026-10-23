import Foundation
import Testing
@testable import DesignSyncCore

/// 목업 요소의 자리(레이어 경로, 화면 안 위치)와 반영 완료 기록.
struct ChangePlaceTests {

    /// 화면(0,0 2000×1000) 안에 `검색 영역 > Frame 3 > 버튼` 구조.
    private func screen(button: String, extra: Bool = false) -> FigmaNode {
        var buttons = [FigmaNode(id: "m:btn", name: "버튼", type: "TEXT", characters: button, x: 500, y: 100, width: 200, height: 50)]
        if extra { buttons.append(FigmaNode(id: "m:new", name: "새 글", type: "TEXT", characters: "초기화", x: 800, y: 100, width: 100, height: 50)) }
        let mockup = FigmaNode(id: "m", name: "검색 영역", type: "FRAME", x: 0, y: 0, width: 2000, height: 1000, children: [
            FigmaNode(id: "m:f", name: "Frame 3", type: "FRAME", children: buttons),
            FigmaNode(id: "m:i", name: "Select/Default", type: "INSTANCE", componentId: "c1", x: 1000, y: 500, width: 400, height: 100),
        ])
        let base = Spec.screen("10:1")
        return FigmaNode(id: base.id, name: base.name, type: base.type, x: 0, y: 0, width: 2000, height: 1000,
                         children: base.children.filter { !$0.id.hasSuffix(":page") } + [mockup])
    }

    @Test func recordsLayerPathAndRelativeBox() throws {
        let snapshot = try #require(SpecExtractor.screens(in: screen(button: "조회"), page: Spec.page1).first)
        let button = try #require(snapshot.places?["m:btn"])
        // 자동 이름(Frame 3)은 경로에서 빠진다
        #expect(button.path == ["검색 영역", "조회"])
        let close = { (a: Double, b: Double) in abs(a - b) < 0.000_1 }
        #expect(close(button.x, 0.25) && close(button.y, 0.1) && close(button.width, 0.1) && close(button.height, 0.05))
        #expect(snapshot.places?["m:i"]?.path == ["검색 영역", "Select/Default"])
    }

    @Test func changesCarryNodeAndPlace() throws {
        let old = try #require(SpecExtractor.screens(in: screen(button: "조회"), page: Spec.page1).first)
        let new = try #require(SpecExtractor.screens(in: screen(button: "검색", extra: true), page: Spec.page1).first)
        let changes = SpecDiff.changes(from: old, to: new)
        let modified = try #require(changes.first { $0.layer == .text && $0.op == .modified })
        #expect(modified.nodeID == "m:btn")
        #expect(modified.place?.path == ["검색 영역", "검색"])
        let added = try #require(changes.first { $0.layer == .text && $0.op == .added })
        #expect(added.nodeID == "m:new" && added.place?.hasBox == true)
        // 위치는 요약 글에도 붙는다
        #expect(DesignEvent.line(modified) == "문구 수정: 조회 → 검색 (위치: 검색 영역)")
    }

    @Test func snapshotsWithoutPlacesStillDiff() {
        let old = ScreenSnapshot(frameID: "1", screenID: "A", texts: ["t": "조회"])
        let new = ScreenSnapshot(frameID: "1", screenID: "A", texts: ["t": "검색"])
        let change = SpecDiff.changes(from: old, to: new).first
        #expect(change?.nodeID == "t" && change?.place == nil)
        #expect(DesignEvent.line(change!) == "문구 수정: 조회 → 검색")
    }

    @Test func appliedEventsCountAsSeenAndProgressIsTracked() throws {
        let change = SpecChange(layer: .text, op: .modified, label: "검색", before: "조회", after: "검색", nodeID: "t")
        let event = DesignEvent(fileKey: "f", fileName: "F", frameID: "1", screenID: "A", title: "목록", menuPath: "a",
                                detectedAt: Date(), windowStart: nil, windowEnd: Date(), kind: .changed,
                                changes: [change, SpecChange(layer: .spec, op: .renumbered, label: "1. x", before: "1", after: "2")],
                                phase: .afterDone)
        var history = DesignHistory(events: [event])
        #expect(history.unseenCount == 1)
        #expect(history.progress(event) == (0, 1))
        history.checked[event.id.uuidString] = [change.key]
        #expect(history.progress(event) == (1, 1))
        history.applied.insert(event.id)
        #expect(history.isSeen(event) && history.unseenCount == 0)
        // 저장하고 다시 읽어도 남고, 지워진 변경의 기록은 함께 지운다
        let reread = try DesignHistoryFile.decode(DesignHistoryFile.encode(history))
        #expect(reread.applied == [event.id] && reread.checkedKeys(event) == [change.key])
        history.forget(fileKey: "f")
        #expect(history.applied.isEmpty && history.checked.isEmpty)
    }

    @Test func readsHistoryWrittenBeforeAppliedState() throws {
        let data = Data(#"{"files":{},"events":[],"seen":[]}"#.utf8)
        let history = try DesignHistoryFile.decode(data)
        #expect(history.applied.isEmpty && history.checked.isEmpty)
    }
}
