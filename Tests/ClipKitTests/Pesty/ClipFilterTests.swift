import AppKit
import Testing
@testable import ClipKit

@Suite struct ClipFilterTests {
    private func item(_ type: ClipType,
                      text: String? = nil,
                      sourceAppName: String? = nil,
                      fileURLs: [String] = []) -> ClipItem {
        ClipItem(type: type, text: text, fileURLs: fileURLs, sourceAppName: sourceAppName)
    }

    private var mixed: [ClipItem] {
        [
            item(.text, text: "Notes about the github release"),
            item(.richText, text: "Formatted notes"),
            item(.link, text: "https://github.com/momenbasel/pesty"),
            item(.image, sourceAppName: "Screenshot"),
            item(.file, fileURLs: ["file:///tmp/Q3-Report.pdf"]),
            item(.color, text: "#5B8DEF"),
            item(.text, text: "Another note")
        ]
    }

    @Test func testNilTypeKeepsEveryClipType() {
        #expect(ClipFilter.applying(type: nil, searchText: "", to: mixed).count == 7)
    }

    @Test func testTypeFilterNarrowsToSingleTypeInOriginalOrder() {
        let result = ClipFilter.applying(type: .text, searchText: "", to: mixed)
        #expect(result.map(\.type) == [.text, .text])
        #expect(result.map(\.text) == ["Notes about the github release", "Another note"])
    }

    @Test func testTypeFilterAppliesBeforeSearch() {
        // "github" matches a text clip and a link clip, but the type filter
        // must narrow first so only the link survives.
        #expect(ClipFilter.applying(type: nil, searchText: "github", to: mixed).count == 2)
        let result = ClipFilter.applying(type: .link, searchText: "github", to: mixed)
        #expect(result.map(\.type) == [.link])
    }

    @Test func testSearchRemainsTrimmedAndCaseInsensitiveWithinAType() {
        let result = ClipFilter.applying(type: .text, searchText: "  NOTES  ", to: mixed)
        #expect(result.map(\.text) == ["Notes about the github release"])
    }

    @Test func testSearchStillMatchesMetadataForTheFilteredType() {
        // File clips are findable by file name/extension, as before.
        let result = ClipFilter.applying(type: .file, searchText: "pdf", to: mixed)
        #expect(result.count == 1)
        #expect(result.first?.type == .file)
    }

    @Test func testFilterAndSearchCanBothProduceNoResults() {
        #expect(ClipFilter.applying(type: .image, searchText: "notes", to: mixed).isEmpty)
        #expect(ClipFilter.applying(type: .text, searchText: "nothing-like-this", to: mixed).isEmpty)
        #expect(ClipFilter.applying(type: .color, searchText: "", to: []).isEmpty)
    }

    @Test func testTypeCountsCountsEachClipType() {
        let counts = ClipFilter.typeCounts(in: mixed)
        #expect(counts[.text] == 2)
        #expect(counts[.richText] == 1)
        #expect(counts[.link] == 1)
        #expect(counts[.image] == 1)
        #expect(counts[.file] == 1)
        #expect(counts[.color] == 1)
        #expect(counts.count == ClipType.allCases.count)
    }

    @Test func testTypeCountsOfEmptyCollectionIsEmpty() {
        #expect(ClipFilter.typeCounts(in: []).isEmpty)
        #expect(ClipFilter.availableTypes(in: []).isEmpty)
    }

    @Test func testAvailableTypesPreserveCanonicalOrderAndSkipMissingTypes() {
        let items = [
            item(.color, text: "#FFFFFF"),
            item(.image),
            item(.color, text: "#000000")
        ]
        #expect(ClipFilter.availableTypes(in: items) == [.image, .color])
    }

    @Test func testNextTypeFilterWalksAllAvailableTypesThenWraps() {
        let available: [ClipType] = [.text, .image, .file]
        #expect(ClipFilter.nextTypeFilter(after: nil, available: available) == .text)
        #expect(ClipFilter.nextTypeFilter(after: .text, available: available) == .image)
        #expect(ClipFilter.nextTypeFilter(after: .image, available: available) == .file)
        #expect(ClipFilter.nextTypeFilter(after: .file, available: available) == nil)
    }

    @Test func testNextTypeFilterSkipsTypesWithoutClips() {
        // .richText has no clips in this collection, so it is skipped.
        #expect(ClipFilter.nextTypeFilter(after: .text, available: [.text, .image]) == .image)
    }

    @Test func testNextTypeFilterRecoversWhenCurrentTypeIsNoLongerAvailable() {
        // The selected type's last clip was deleted while it was filtering.
        #expect(ClipFilter.nextTypeFilter(after: .color, available: [.text, .image]) == .text)
    }

    @Test func testNextTypeFilterWithoutAnyClipsIsAll() {
        #expect(ClipFilter.nextTypeFilter(after: .text, available: []) == nil)
    }
}
