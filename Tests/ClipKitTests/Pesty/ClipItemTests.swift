import AppKit
import Testing
@testable import ClipKit

@Suite struct ClipItemTests {
    @Test func testCodableRoundTripPreservesClipMetadata() throws {
        let original = ClipItem(
            id: UUID(uuidString: "61F39299-3C8E-45AE-90BA-C53889BF9304")!,
            type: .link,
            text: "https://example.com/path",
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            customTitle: "Example",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipItem.self, from: encoded)

        #expect(decoded == original)
        #expect(decoded.displayTitle == "Example")
    }
}
