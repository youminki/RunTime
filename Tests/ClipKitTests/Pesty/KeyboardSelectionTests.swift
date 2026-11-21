import AppKit
import Testing
@testable import ClipKit

@MainActor
@Suite struct KeyboardSelectionTests {
    /// A store on a scratch directory holding five clips, with the bar just
    /// presented: `clips` is in strip order and the first one is selected.
    private func makeStore() -> (store: ClipboardStore, clips: [ClipItem]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PestyTests-\(UUID().uuidString)", isDirectory: true)

        let store = ClipboardStore(baseDirectory: directory)
        let clips = ["a", "b", "c", "d", "e"].map { ClipItem(type: .text, text: $0) }
        for clip in clips.reversed() { store.addCaptured(clip) }
        store.prepareForBarPresentation()
        return (store, clips)
    }

    private func ids(_ clips: ArraySlice<ClipItem>) -> Set<UUID> {
        Set(clips.map(\.id))
    }

    @Test func testShiftArrowGrowsThenShrinksBackToTheAnchor() {
        let (store, clips) = makeStore()

        store.extendSelection(by: 1)
        #expect(store.multiSelectedIDs == ids(clips[0...1]))
        #expect(!(store.selectionIsPointerDriven))
        store.extendSelection(by: 1)
        #expect(store.multiSelectedIDs == ids(clips[0...2]))
        #expect(store.selectedID == clips[2].id)

        store.extendSelection(by: -1)
        #expect(store.multiSelectedIDs == ids(clips[0...1]))
        store.extendSelection(by: -1)
        #expect(store.multiSelectedIDs.isEmpty)
        #expect(store.effectiveSelectionIDs == [clips[0].id])
    }

    @Test func testShiftArrowCrossesTheAnchor() {
        let (store, clips) = makeStore()
        store.moveSelection(by: 2)

        store.extendSelection(by: -1)
        #expect(store.multiSelectedIDs == ids(clips[1...2]))
        store.extendSelection(by: 1)
        #expect(store.multiSelectedIDs.isEmpty)
        #expect(store.selectedID == clips[2].id)
        store.extendSelection(by: 1)
        #expect(store.multiSelectedIDs == ids(clips[2...3]))
    }

    @Test func testShiftArrowStopsAtTheEndsOfTheStrip() {
        let (store, clips) = makeStore()

        store.extendSelection(by: -1)
        #expect(store.multiSelectedIDs.isEmpty)
        #expect(store.selectedID == clips[0].id)

        for _ in 0..<10 { store.extendSelection(by: 1) }
        #expect(store.multiSelectedIDs == ids(clips[0...4]))
        #expect(store.selectedID == clips[4].id)
    }

    @Test func testPlainArrowReturnsToASingleSelection() {
        let (store, clips) = makeStore()
        store.extendSelection(by: 1)
        store.extendSelection(by: 1)

        store.moveSelection(by: 1)
        #expect(store.multiSelectedIDs.isEmpty)
        #expect(store.selectedID == clips[3].id)

        // The clip the arrow landed on is the new anchor.
        store.extendSelection(by: -1)
        #expect(store.multiSelectedIDs == ids(clips[2...3]))
    }

    @Test func testAnchorStartsOverWhenTheBarIsPresentedAgain() {
        let (store, clips) = makeStore()
        store.moveSelection(by: 3)

        store.prepareForBarPresentation()
        store.extendSelection(by: 1)
        #expect(store.multiSelectedIDs == ids(clips[0...1]))
    }

    @Test func testSelectedItemsComeInStripOrderNotClickOrder() {
        let (store, clips) = makeStore()

        store.toggleSelection(clips[3].id)
        store.toggleSelection(clips[1].id)
        #expect(store.selectedItems.map(\.id) == [clips[0].id, clips[1].id, clips[3].id])

        store.clearMultiSelection()
        #expect(store.selectedItems.map(\.id) == [clips[1].id])
    }

    @Test func testPromotingASelectionKeepsItsOrderAtTheFront() {
        let (store, clips) = makeStore()

        store.promoteCopiedItems([clips[2], clips[4]])
        #expect(store.history.map(\.text) == ["c", "e", "a", "b", "d"])
    }
}
