import Foundation
import Testing
@testable import DesignSyncCore

/// 바뀐 적 없는 화면도 마크업할 수 있게 명세·문구를 읽는 순서대로 모은다.
@Suite struct ScreenBriefTests {
    private func screen() -> ScreenSnapshot {
        ScreenSnapshot(
            frameID: "1:1", screenID: "SC-RSV-001", title: "예약 조회", menuPath: "예약 > 예약 조회", requirementID: "REQ-01",
            notes: "로그인한 회원만", items: [SpecItem(number: "1", text: "검색\n예약 번호 6자리"), SpecItem(number: "2", text: "목록")],
            texts: ["a": "조회", "b": "예약 번호", "c": "출발일", "d": "예약 번호", "e": "© KAL"],
            components: ["x": SpecComponent(name: "Button", componentID: "c1"), "y": SpecComponent(name: "Button", componentID: "c1"),
                         "z": SpecComponent(name: "Logo", componentID: SpecComponent.imagePrefix + "h")],
            places: ["a": SpecPlace(path: [], x: 0.8, y: 0.2), "b": SpecPlace(path: [], x: 0.1, y: 0.2),
                     "c": SpecPlace(path: [], x: 0.1, y: 0.1), "d": SpecPlace(path: [], x: 0.1, y: 0.5)])
    }

    @Test func textsReadTopToBottomLeftToRightOnce() {
        #expect(ScreenBrief.orderedTexts(screen()) == ["출발일", "예약 번호", "조회", "© KAL"])
    }

    @Test func componentsCountWithoutImages() {
        let components = ScreenBrief.components(screen())
        #expect(components.map(\.name) == ["Button"])
        #expect(components.first?.count == 2)
    }

    @Test func briefHasHeaderSpecAndTexts() {
        let text = ScreenBrief.text(screen(), project: "대한항공", state: "완료", link: URL(string: "https://figma.com/x"), textLimit: 2)
        #expect(text.hasPrefix("[화면] SC-RSV-001 예약 조회\n- 프로젝트: 대한항공\n- 화면 경로: 예약 > 예약 조회\n- 요구사항 ID: REQ-01"))
        #expect(text.contains("[참고]\n로그인한 회원만"))
        #expect(text.contains("[기능 명세]\n1. 검색\n   예약 번호 6자리\n2. 목록"))
        #expect(text.contains("[목업 문구]\n- 출발일\n- 예약 번호\n- 외 2개"))
        #expect(!text.contains("[최근 디자인 변경]"))
    }

    @Test func briefMarksBuiltItems() {
        let text = ScreenBrief.text(screen(), project: "Demo", state: "완료", link: nil, built: ["목록"])
        #expect(text.contains("[기능 명세] 구현 1/2\n1. 검색\n   예약 번호 6자리\n2. 목록 (구현함)"))
    }

    /// 구현 체크는 글로 가려 번호가 밀려도 남고, 시안에서 빠진 항목은 세지 않는다.
    @Test func builtChecklistFollowsItemText() {
        var history = DesignHistory(files: ["F": DesignFileRecord(name: "F", lastModified: nil, screens: ["1:1": screen()], checkedAt: [:],
                                                                   changelog: [], syncedAt: Date())])
        var current = screen()
        history.toggleBuilt(current.items[1], of: current, in: "F")
        #expect(history.built(current, in: "F") == ["목록"])
        current.items.insert(SpecItem(number: "1", text: "새 항목"), at: 0)
        #expect(history.built(current, in: "F") == ["목록"])
        current.items.removeLast()
        #expect(history.built(current, in: "F").isEmpty)
        history.toggleBuilt(current.items[0], of: current, in: "F")
        history.toggleBuilt(current.items[0], of: current, in: "F")
        #expect(history.files["F"]?.built == nil)
        history.forget(frames: ["1:1"], in: "F")
        #expect(history.files["F"]?.screens.isEmpty == true)
    }

    @Test func nodeIDFromLink() {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        #expect(FigmaFileURL.nodeID(from: "https://www.figma.com/design/\(key)/Spec?node-id=12-345&t=abc-0") == "12:345")
        #expect(FigmaFileURL.nodeID(from: "www.figma.com/design/\(key)/Spec?node-id=12%3A345") == "12:345")
        #expect(FigmaFileURL.nodeID(from: "https://www.figma.com/design/\(key)/Spec") == nil)
        #expect(FigmaFileURL.nodeID(from: "https://example.com/design/\(key)?node-id=1-2") == nil)
    }

    /// 범위 칸이 생기기 전 설정도 전체를 지켜보는 것으로 읽는다.
    @Test func sourceWithoutScopeDecodes() throws {
        let data = Data(#"{"fileKey":"F","name":"[Demo] 화면설계서"}"#.utf8)
        let source = try JSONDecoder().decode(DesignSource.self, from: data)
        #expect(source.scope.isEmpty)
        let round = try JSONDecoder().decode(DesignSource.self, from: JSONEncoder().encode(DesignSource(fileKey: "F", scope: [DesignScope(nodeID: "1:2", name: "목록")])))
        #expect(round.scope == [DesignScope(nodeID: "1:2", name: "목록")])
    }
}
