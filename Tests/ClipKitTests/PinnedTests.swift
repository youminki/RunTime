import AppKit
import Testing
@testable import ClipKit

/// 고정은 보드 하나에 담고 뺀다. 빼도 기록은 그대로이고, 예전 보드 여럿은 하나로 합친다.
@MainActor
@Suite struct PinnedTests {
    private func makeStore() -> (ClipboardStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-pinned-\(UUID().uuidString)", isDirectory: true)
        return (ClipboardStore(baseDirectory: directory), directory)
    }

    @Test func removingFromBoardLeavesHistory() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = ClipItem(type: .text, text: "자주 쓰는 문장")
        store.addCaptured(clip)
        let board = store.addPinboard(name: "고정")
        store.saveToPinboard(clip, boardID: board.id)
        store.saveToPinboard(clip, boardID: board.id)
        #expect(store.pinboards.first?.items.count == 1)

        store.removeFromPinboard(clip, boardID: board.id)
        #expect(store.pinboards.first?.items.isEmpty == true)
        #expect(store.history.count == 1)

        // 없는 것을 빼도 아무 일도 없다
        store.removeFromPinboard(clip, boardID: board.id)
        #expect(store.pinboards.count == 1)
    }

    @Test func mergingBoardsKeepsEveryClipOnceAndBacksUp() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = store.addPinboard(name: "업무")
        let b = store.addPinboard(name: "개인")
        let shared = ClipItem(type: .text, text: "두 보드에 다 있는 것")
        store.saveToPinboard(shared, boardID: a.id)
        store.saveToPinboard(shared, boardID: b.id)
        store.saveToPinboard(ClipItem(type: .text, text: "개인 보드에만"), boardID: b.id)
        store.saveNow(waiting: true)

        store.mergePinboards()
        #expect(store.pinboards.count == 1)
        #expect(store.pinboards.first?.id == a.id)
        #expect(store.pinboards.first?.items.compactMap(\.text).sorted() == ["개인 보드에만", "두 보드에 다 있는 것"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("store-before-pinned.json").path))

        // 다시 불러도 그대로
        store.mergePinboards()
        #expect(store.pinboards.first?.items.count == 2)
    }
}
