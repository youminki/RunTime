import Foundation
import Testing
@testable import WorkLogCore

struct MRScreensTests {

    private let verifyNote = """
    ### AI 검증 (`a1eb0702`)

    **[빌드/테스트]**

    | 단계 | 명령 | 결과 | 시간 |
    |---|---|---|---|
    | 설치 | `npm ci` | 통과 | 0초 |

    **[화면 확인]**

    **1. 폴더 이동 후 행 선택 시 하단 액션 바** (`/data-collection/shared-files`): 확인됨

    수정 후 화면에서는 액션 바가 뜹니다.

    | 수정 전 | 수정 후 |
    |---|---|
    | (캡처 없음) | ![수정 후](/uploads/c797/after_0.png) |

    **2. 파일 상세 패널** (`/data-collection/shared-files`): 문제 있음

    | 수정 전 | 수정 후 |
    |---|---|
    | (캡처 없음) | ![수정 후](/uploads/8acf/after_1.png) |

    **3. 트리 검색 드롭다운** (`/data-collection/shared-files`): 확인됨

    | 수정 전 | 수정 후 |
    |---|---|
    | ![수정 전](/uploads/aaaa/before_2.png) | ![수정 후](/uploads/3260/after_2.png) |

    <sub>AI 검증</sub>
    """

    @Test func readsVerifyTablesAndSkipsProblems() {
        let screens = MRScreens.screens(description: "", notes: [verifyNote])
        #expect(screens.count == 2)
        #expect(screens[0].title == "폴더 이동 후 행 선택 시 하단 액션 바")
        #expect(screens[0].before == nil)
        #expect(screens[0].after == "/uploads/c797/after_0.png")
        #expect(screens[1].before == "/uploads/aaaa/before_2.png")
        #expect(screens[1].after == "/uploads/3260/after_2.png")
    }

    @Test func usesLatestNoteWithScreensAndDescription() {
        let old = "| 수정 전 | 수정 후 |\n|---|---|\n| ![a](/uploads/old/x.png) | ![b](/uploads/old/y.png) |"
        let description = "[작업 내용]\n- 입력 차단\n\n수정 전(-30 입력)\n![image](/uploads/d1/before.png)\n수정 후\n![image](/uploads/d2/after.png)"
        let screens = MRScreens.screens(description: description, notes: [old, verifyNote, "LGTM"])
        #expect(screens.first == MRScreens.Screen(title: nil, before: "/uploads/d1/before.png", after: "/uploads/d2/after.png"))
        #expect(!screens.contains { $0.before == "/uploads/old/x.png" })
        #expect(screens.count == 3)
    }

    @Test func ignoresUnlabeledAndOutsideImages() {
        let text = "![diagram](/uploads/z/diagram.png)\n![수정 후](https://example.com/a.png)\n<img src=\"/uploads/h/after.png\" alt=\"수정 후\">"
        let screens = MRScreens.parse(text)
        #expect(screens == [MRScreens.Screen(title: nil, before: nil, after: "/uploads/h/after.png")])
    }

    @Test func noteSectionStacksImagesUnderTitles() {
        let screens = [MRScreens.Screen(title: "검색 드롭다운 (`/a`)", before: "/uploads/a/b.png", after: "/uploads/a/c.png"),
                       MRScreens.Screen(title: nil, before: nil, after: "/uploads/a/d.png")]
        let files = ["0:before": "mr12-1-before.png", "0:after": "mr12-1-after.png", "1:after": "mr12-2-after.png"]
        let html = MRScreens.noteSection(screens, files: files, html: true)
        #expect(html.hasPrefix("<p>[수정 전·후 화면]</p>"))
        #expect(html.contains("<strong>1. 검색 드롭다운 (/a)</strong>"))
        #expect(html.contains("<p>수정 전<br />\n<img src=\"mr12-1-before.png\" alt=\"수정 전\" /></p>"))
        #expect(html.contains("<strong>2. 화면</strong>"))
        let plain = MRScreens.noteSection(screens, files: files, html: false)
        #expect(plain.contains("수정 후\n!mr12-1-after.png!"))
        #expect(MRScreens.noteSection(screens, files: [:], html: true).isEmpty)
        #expect(MRScreens.filename(mr: 12, index: 0, kind: .after, path: "/uploads/a/x.PNG") == "mr12-1-after.png")
    }

    @Test func capsImageCount() {
        let rows = (0..<6).map { "| ![수정 전](/uploads/\($0)/b.png) | ![수정 후](/uploads/\($0)/a.png) |" }
        let text = "| 수정 전 | 수정 후 |\n|---|---|\n" + rows.joined(separator: "\n")
        let screens = MRScreens.screens(description: text, notes: [])
        #expect(screens.flatMap(\.images).count == MRScreens.maxImages)
    }
}
