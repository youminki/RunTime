import AppKit
import Testing
@testable import ClipKit

@MainActor
@Suite struct ClipComposerTests {
    private func boldRTF(_ string: String) -> Data {
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length))!
    }

    @Test func testTextClipsJoinIntoOnePlainStep() {
        let steps = ClipComposer.steps(for: [
            ClipItem(type: .text, text: "first"),
            ClipItem(type: .link, text: "https://example.com"),
            ClipItem(type: .color, colorHex: "#5B8DEF")
        ])

        #expect(steps.count == 1)
        #expect(steps.first?.type == .text)
        #expect(steps.first?.text == "first\nhttps://example.com\n#5B8DEF")
        #expect(steps.first?.rtfData == nil)
    }

    @Test func testFormattingSurvivesNextToPlainText() throws {
        let steps = ClipComposer.steps(for: [
            ClipItem(type: .richText, text: "bold", rtfData: boldRTF("bold")),
            ClipItem(type: .text, text: "plain")
        ])

        #expect(steps.count == 1)
        #expect(steps.first?.type == .richText)
        #expect(steps.first?.text == "bold\nplain")
        let rich = try #require(steps.first?.rtfData.flatMap {
            NSAttributedString(rtf: $0, documentAttributes: nil)
        })
        #expect(rich.string == "bold\nplain")
        let traits: (Int) -> NSFontDescriptor.SymbolicTraits = { index in
            (rich.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?
                .fontDescriptor.symbolicTraits ?? []
        }
        #expect(traits(0).contains(.bold))
        #expect(!(traits(5).contains(.bold)))
    }

    @Test func testMixedSelectionPastesInStepsWithTextSetApart() {
        let image = ClipItem(type: .image, imageFileName: "shot.png")
        let steps = ClipComposer.steps(for: [
            ClipItem(type: .text, text: "one"),
            ClipItem(type: .text, text: "two"),
            image,
            ClipItem(type: .text, text: "three")
        ])

        #expect(steps.map(\.type) == [.text, .image, .text])
        #expect(steps[0].text == "one\ntwo\n")
        #expect(steps[1] == image)
        #expect(steps[2].text == "\nthree")
    }

    @Test func testImagesNeverMerge() {
        let first = ClipItem(type: .image, imageFileName: "a.png")
        let second = ClipItem(type: .image, imageFileName: "b.png")

        #expect(ClipComposer.steps(for: [first, second]) == [first, second])
    }

    @Test func testNeighbouringFilesBecomeOneFileList() {
        let report = ClipItem(type: .file, text: "report.pdf", fileURLs: ["file:///tmp/report.pdf"])
        let notes = ClipItem(type: .file, text: "notes.txt", fileURLs: ["file:///tmp/notes.txt"])
        let image = ClipItem(type: .image, imageFileName: "shot.png")

        let together = ClipComposer.steps(for: [report, notes])
        #expect(together.count == 1)
        #expect(together.first?.type == .file)
        #expect(together.first?.fileURLs == ["file:///tmp/report.pdf", "file:///tmp/notes.txt"])
        #expect(together.first?.text == "report.pdf, notes.txt")

        #expect(ClipComposer.steps(for: [report, image, notes]) == [report, image, notes])
    }

    @Test func testPlainTextKeepsOnlyWhatHasText() {
        let items = [
            ClipItem(type: .richText, text: "bold", rtfData: boldRTF("bold")),
            ClipItem(type: .image, imageFileName: "shot.png"),
            ClipItem(type: .file, text: "report.pdf", fileURLs: ["file:///tmp/report.pdf"])
        ]

        let steps = ClipComposer.steps(for: items, format: .plainText)
        #expect(steps.count == 1)
        #expect(steps.first?.type == .text)
        #expect(steps.first?.text == "bold\n/tmp/report.pdf")
        #expect(steps.first?.rtfData == nil)

        let images = [ClipItem(type: .image, imageFileName: "a.png"),
                      ClipItem(type: .image, imageFileName: "b.png")]
        #expect(ClipComposer.steps(for: images, format: .plainText).isEmpty)
    }

    @Test func testMarkdownConvertsEachClipAndFallsBackToItsText() {
        let steps = ClipComposer.steps(for: [
            ClipItem(type: .richText, text: "bold", rtfData: boldRTF("bold")),
            ClipItem(type: .text, text: "plain")
        ], format: .markdown)

        #expect(steps.count == 1)
        #expect(steps.first?.text == "**bold**\nplain")
    }

    @Test func testSeveralStepsAreCopiedAsSeparatePasteboardItems() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pesty.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let steps = [
            ClipItem(type: .text, text: "caption\n"),
            ClipItem(type: .file, text: "report.pdf", fileURLs: ["file:///tmp/report.pdf"])
        ]

        let before = pasteboard.changeCount
        #expect(PasteService.copy(steps, to: pasteboard) != before)

        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "caption\n")
        #expect(items.last?.string(forType: .fileURL) == "file:///tmp/report.pdf")
    }

    @Test func testOneStepIsCopiedLikeAnyOtherClip() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pesty.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let steps = ClipComposer.steps(for: [
            ClipItem(type: .text, text: "one"),
            ClipItem(type: .text, text: "two")
        ])

        PasteService.copy(steps, to: pasteboard)

        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.string(forType: .string) == "one\ntwo")
    }
}
