import Foundation
import Testing
@testable import DesignSyncCore

private let place = SpecPlace(path: ["Row", "시스템"], x: 0.1, y: 0.2, width: 0.3, height: 0.04)

private func screen(_ frame: String, places: [String: SpecPlace]? = ["1:2": place]) -> ScreenSnapshot {
    ScreenSnapshot(frameID: frame, screenID: "SC-\(frame)", texts: ["1:2": "시스템"], places: places)
}

private func history(_ frames: [String], key: String = "fileA") -> DesignHistory {
    let screens = Dictionary(uniqueKeysWithValues: frames.map { ($0, screen($0)) })
    let file = DesignFileRecord(name: "파일", lastModified: "v1", screens: screens, checkedAt: [:], changelog: [], syncedAt: Date())
    return DesignHistory(files: [key: file])
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Suite struct DesignPlaceFileTests {
    @Test func folderSitsNextToTheHistory() {
        let url = URL(fileURLWithPath: "/tmp/x/design-history.json")
        #expect(DesignPlaceFile.folder(for: url).path == "/tmp/x/design-history-places")
    }

    @Test func detachThenAttachRestoresPlaces() {
        let original = history(["10:1", "10:2"])
        var light = original
        let moved = DesignPlaceFile.detach(&light)
        #expect(moved.count == 2)
        #expect(light.files["fileA"]?.screens.values.allSatisfy { $0.places == nil } == true)
        DesignPlaceFile.attach(Dictionary(uniqueKeysWithValues: moved.map { ($0.frameID, $0.places) }), to: &light, fileKey: "fileA")
        #expect(light == original)
    }

    @Test func oldHistoryMovesPlacesOutAndKeepsThem() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("design-history.json")
        try DesignHistoryFile.save(history(["10:1", "10:2"]), to: url)

        let loaded = try DesignHistoryFile.loadDetachingPlaces(url)
        #expect(loaded.files["fileA"]?.screens.values.allSatisfy { $0.places == nil } == true)
        // 가벼워진 기록을 저장해 다음에는 옮길 것이 없다
        #expect(try DesignHistoryFile.load(url) == loaded)
        let places = DesignPlaceFile.folder(for: url)
        #expect(DesignPlaceFile.read("fileA", "10:1", in: places) == ["1:2": place])
        #expect(DesignPlaceFile.readAll("fileA", frames: ["10:1", "10:2", "없음"], in: places).count == 2)
        // 다시 읽어도 그대로다
        #expect(try DesignHistoryFile.loadDetachingPlaces(url) == loaded)
    }

    @Test func placesStayInHistoryWhenTheyCannotBeWritten() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("design-history.json")
        try DesignHistoryFile.save(history(["10:1"]), to: url)
        // 자리 폴더 자리에 파일이 있으면 그 안에 쓸 수 없다
        try Data().write(to: DesignPlaceFile.folder(for: url).deletingLastPathComponent().appendingPathComponent("design-history-places"))

        let loaded = try DesignHistoryFile.loadDetachingPlaces(url)
        #expect(loaded.files["fileA"]?.screens["10:1"]?.places == ["1:2": place])
        #expect(try DesignHistoryFile.load(url).files["fileA"]?.screens["10:1"]?.places == ["1:2": place])
    }

    @Test func pruneRemovesPlacesOfDroppedScreensAndFiles() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try DesignPlaceFile.write(["1:2": place], "fileA", "10:1", in: folder)
        try DesignPlaceFile.write(["1:2": place], "fileA", "10:2", in: folder)
        try DesignPlaceFile.write(["1:2": place], "gone", "10:1", in: folder)

        DesignPlaceFile.prune(keeping: history(["10:1"]), in: folder)
        #expect(DesignPlaceFile.read("fileA", "10:1", in: folder) != nil)
        #expect(DesignPlaceFile.read("fileA", "10:2", in: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("gone").path))
    }

    @Test func attachDoesNotOverwriteFreshPlaces() {
        var mixed = history(["10:1"])
        let fresh = SpecPlace(path: ["새"], x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        mixed.files["fileA"]?.screens["10:1"]?.places = ["1:2": fresh]
        DesignPlaceFile.attach(["10:1": ["1:2": place]], to: &mixed, fileKey: "fileA")
        #expect(mixed.files["fileA"]?.screens["10:1"]?.places == ["1:2": fresh])
    }
}
