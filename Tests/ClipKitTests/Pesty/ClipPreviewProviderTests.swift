import AppKit
import Testing
@testable import ClipKit

@MainActor
@Suite struct ClipPreviewProviderTests {
    @Test func testOnlySingleImageFilesShowAsImages() {
        let png = ClipItem(type: .file, fileURLs: ["file:///tmp/shot.png"])
        let pdf = ClipItem(type: .file, fileURLs: ["file:///tmp/report.pdf"])
        let two = ClipItem(type: .file, fileURLs: ["file:///tmp/a.png", "file:///tmp/b.png"])

        #expect(ClipPreviewProvider.imageFileURL(for: png)?.path == "/tmp/shot.png")
        #expect(ClipPreviewProvider.imageFileURL(for: pdf) == nil)
        #expect(ClipPreviewProvider.imageFileURL(for: two) == nil)
        #expect(ClipPreviewProvider.showsImage(ClipItem(type: .image, imageFileName: "x.png")))
        #expect(!(ClipPreviewProvider.showsImage(pdf)))
    }

    @Test func testFileInfoReportsMissingFilesOnlyOnENOENT() async {
        let present = ClipItem(type: .file, fileURLs: ["file:///bin/ls"])
        let gone = ClipItem(type: .file, fileURLs: ["file:///nonexistent/\(UUID().uuidString).pdf"])

        let presentInfo = await ClipPreviewProvider.fileInfo(for: present)
        #expect(presentInfo?.isMissing == false)
        #expect(presentInfo?.icon != nil)

        let goneInfo = await ClipPreviewProvider.fileInfo(for: gone)
        #expect(goneInfo?.isMissing == !ClipboardStore.isSandboxed)
        #expect(goneInfo?.icon != nil)

        let text = await ClipPreviewProvider.fileInfo(for: ClipItem(type: .text, text: "x"))
        #expect(text == nil)
    }
}
