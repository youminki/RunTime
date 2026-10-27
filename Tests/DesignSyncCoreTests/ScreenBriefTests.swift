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
}
