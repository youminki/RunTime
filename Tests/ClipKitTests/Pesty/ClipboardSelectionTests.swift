import AppKit
import Testing
@testable import ClipKit

@MainActor
@Suite struct ClipboardSelectionTests {
    private func withStore(_ body: (ClipboardStore, [ClipItem]) -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pesty-selection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)
        let items = (0..<4).map { ClipItem(type: .text, text: "Clip \($0)") }
        for item in items.reversed() { store.addCaptured(item) }
        body(store, items)
    }

    @Test func testClickKeepsCardInPlaceAndArrowNavigationResumesScrolling() throws {
        try withStore { store, items in
            store.select(items[1].id)
            #expect(store.selectedID == items[1].id)
            #expect(store.selectionIsPointerDriven)

            store.moveSelection(by: 1)
            #expect(store.selectedID == items[2].id)
            #expect(!(store.selectionIsPointerDriven))
        }
    }

    @Test func testModifiedClicksPreserveMultiSelectionWithoutScrolling() throws {
        try withStore { store, items in
            store.select(items[0].id)
            store.extendSelection(to: items[2].id)
            #expect(store.multiSelectedIDs == Set(items.prefix(3).map(\.id)))
            #expect(store.selectionIsPointerDriven)

            store.toggleSelection(items[1].id)
            #expect(store.multiSelectedIDs == Set([items[0].id, items[2].id]))
            #expect(store.selectionIsPointerDriven)

            store.moveSelection(by: 1)
            #expect(store.selectedID == items[3].id)
            #expect(store.multiSelectedIDs.isEmpty)
            #expect(!(store.selectionIsPointerDriven))
        }
    }

    @Test func testProgrammaticSelectionResumesScrollingAfterClick() throws {
        try withStore { store, items in
            store.select(items[2].id)
            store.selectFirst()
            #expect(store.selectedID == items[0].id)
            #expect(!(store.selectionIsPointerDriven))

            store.select(items[3].id)
            store.selectedID = items[1].id
            #expect(!(store.selectionIsPointerDriven))
        }
    }
}
