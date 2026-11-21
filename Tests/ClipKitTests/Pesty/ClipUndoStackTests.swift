import AppKit
import Testing
@testable import ClipKit

@Suite struct ClipUndoStackTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func placement(_ item: ClipItem, index: Int,
                           before predecessor: ClipItem? = nil,
                           after successor: ClipItem? = nil) -> ClipPlacement {
        ClipPlacement(container: .history, index: index, item: item,
                      predecessorID: predecessor?.id, successorID: successor?.id)
    }

    @Test func testBulkDeletionComesBackAsOneEntryNewestFirst() {
        var stack = ClipUndoStack()
        let a = ClipItem(type: .text, text: "a")
        let b = ClipItem(type: .text, text: "b")
        let c = ClipItem(type: .text, text: "c")
        stack.push([placement(a, index: 0)], at: start)
        stack.push([placement(b, index: 1), placement(c, index: 2)], at: start.addingTimeInterval(1))

        let first = stack.pop(at: start.addingTimeInterval(2))
        #expect(first?.placements.map(\.item.id) == [b.id, c.id])
        #expect(stack.pop(at: start.addingTimeInterval(2))?.placements.first?.item.id == a.id)
        #expect(stack.pop(at: start.addingTimeInterval(2)) == nil)
        #expect(stack.isEmpty)
    }

    @Test func testEntriesExpireAfterFiveMinutes() {
        var stack = ClipUndoStack()
        let item = ClipItem(type: .image, imageFileName: "shot.png")
        stack.push([placement(item, index: 0)], at: start)
        #expect(stack.nextExpiration == start.addingTimeInterval(300))
        #expect(stack.retainsImageFile(named: "shot.png"))

        #expect(stack.removeExpired(at: start.addingTimeInterval(299)).isEmpty)
        #expect(stack.pop(at: start.addingTimeInterval(300)) == nil)
        let expired = stack.removeExpired(at: start.addingTimeInterval(300))
        #expect(expired.first?.placements.first?.item.id == item.id)
        #expect(!(stack.retainsImageFile(named: "shot.png")))
        #expect(stack.nextExpiration == nil)
    }

    @Test func testRemoveAllHandsBackEverything() {
        var stack = ClipUndoStack()
        stack.push([placement(ClipItem(type: .text, text: "x"), index: 0)], at: start)
        stack.push([placement(ClipItem(type: .text, text: "y"), index: 0)], at: start)
        #expect(stack.removeAll().count == 2)
        #expect(stack.isEmpty)
    }

    @Test func testRestorationIndexPrefersPredecessorThenSuccessorThenIndex() {
        let a = ClipItem(type: .text, text: "a")
        let b = ClipItem(type: .text, text: "b")
        let c = ClipItem(type: .text, text: "c")
        let gone = placement(b, index: 1, before: a, after: c)

        #expect(gone.restorationIndex(in: [a, c]) == 1)
        #expect(gone.restorationIndex(in: [c, a]) == 2)
        #expect(gone.restorationIndex(in: [c]) == 0)
        #expect(gone.restorationIndex(in: []) == 0)
        #expect(placement(b, index: 7).restorationIndex(in: [a, c]) == 2)
    }
}
