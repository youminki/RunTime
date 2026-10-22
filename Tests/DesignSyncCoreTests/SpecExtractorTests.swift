import Foundation
import Testing
@testable import DesignSyncCore

/// 디자이너마다 다른 화면설계서 틀의 차이를 지어낸 화면으로 재현한다.
@Suite struct SpecExtractorTests {
    @Test func readsHeaderPanelAndMockup() throws {
        let screen = Spec.screen("10:1", screenID: "SC-PRD-LST-001", title: "상품 목록", path: "상품 관리 > 상품 목록",
                                 items: [("1", "품절 알림\n필터와 무관하게 전체 건수"), ("2", "카테고리 탭")], notes: "품절: 재고 0",
                                 texts: [("m:1", "상품 등록"), ("m:2", "가격")],
                                 components: [("m:3", "button", "c:1")])
        let found = SpecExtractor.screens(in: Spec.page("1:1", "설정", [screen]), page: Spec.page1)
        let snapshot = try #require(found.first)
        #expect(found.count == 1)
        #expect(snapshot.frameID == "10:1")
        #expect(snapshot.screenID == "SC-PRD-LST-001")
        #expect(snapshot.title == "상품 목록")
        #expect(snapshot.menuPath == "상품 관리 > 상품 목록")
        #expect(snapshot.requirementID == "")   // "-"는 비운다
        #expect(snapshot.author == "작성자A")
        #expect(snapshot.notes == "품절: 재고 0")
        #expect(snapshot.items == [SpecItem(number: "1", text: "품절 알림\n필터와 무관하게 전체 건수"), SpecItem(number: "2", text: "카테고리 탭")])
        // 헤더·패널·저작권·번호 표식은 목업 글자에 넣지 않는다
        #expect(snapshot.texts == ["m:1": "상품 등록", "m:2": "가격"])
        #expect(snapshot.components == ["m:3": SpecComponent(name: "button", componentID: "c:1")])
        #expect(snapshot.pageID == "1:1")
        #expect(snapshot.candidateID == "1:1")
    }

    @Test func hiddenPlaceholderRowsAreDropped() throws {
        let snapshot = try #require(SpecExtractor.screens(in: Spec.screen("10:1"), page: Spec.page1).first)
        #expect(snapshot.items.map(\.number) == ["1"])
        #expect(!snapshot.items.contains { $0.text.contains("화면 기능 설명") })
    }

    @Test func panelIsFoundByItsLabelNotItsLayerName() throws {
        // 설명 패널 레이어 이름을 바꾸지 않고 "Frame 14"로 두는 디자이너가 있다
        let screen = Spec.screen("10:1", items: [("1", "생성 버튼")], panelName: "Frame 14")
        let snapshot = try #require(SpecExtractor.screens(in: screen, page: Spec.page1).first)
        #expect(snapshot.items == [SpecItem(number: "1", text: "생성 버튼")])
    }

    @Test func screenIDComesFromHeaderNotLayerName() throws {
        let renamed = Spec.screen("10:1", screenID: "SC-ORD-LST-002", frameName: "Frame 1000001234")
        #expect(SpecExtractor.screens(in: renamed, page: Spec.page1).first?.screenID == "SC-ORD-LST-002")
        // 메일 템플릿처럼 화면 ID가 "-"면 프레임 이름을 쓴다
        let mail = Spec.screen("10:2", screenID: "-", frameName: "[메일] 주문 완료 안내")
        #expect(SpecExtractor.screens(in: mail, page: Spec.page1).first?.screenID == "[메일] 주문 완료 안내")
    }

    @Test func menuPathFallsBackToSectionThenPage() throws {
        let noPath = Spec.screen("10:1", path: "-")
        let inSection = Spec.section("5:1", "[완료] 상품 > 목록", [noPath])
        #expect(SpecExtractor.screens(in: Spec.page("1:1", "p", [inSection]), page: Spec.page1).first?.menuPath == "상품 > 목록")
        #expect(SpecExtractor.screens(in: noPath, page: Spec.page1).first?.menuPath == "설정")
        #expect(SpecExtractor.screens(in: Spec.page("1:1", "p", [inSection]), page: Spec.page1).first?.sectionName == "[완료] 상품 > 목록")
    }

    @Test func frameHoldingSeveralScreensYieldsEachScreen() {
        let holder = FigmaNode(id: "9:1", name: "묶음", type: "FRAME", width: 5000, height: 1400, children: [
            Spec.screen("10:1", screenID: "SC-A-001"), Spec.screen("10:2", screenID: "SC-A-002"),
        ])
        let found = SpecExtractor.screens(in: holder, page: Spec.page1)
        #expect(found.map(\.screenID) == ["SC-A-001", "SC-A-002"])
        #expect(found.allSatisfy { $0.candidateID == "9:1" })
    }

    @Test func hiddenScreensAreSkipped() {
        #expect(SpecExtractor.screens(in: Spec.screen("10:1", visible: false), page: Spec.page1).isEmpty)
    }

    @Test func textIsNormalized() {
        #expect(DesignText.normalize("  장바구니에\u{00A0}담기지   않은\n\n상품\u{200B} ") == "장바구니에 담기지 않은\n상품")
        #expect(DesignText.headline("첫 줄\n둘째 줄") == "첫 줄")
    }

    @Test func readsChangelogTable() {
        let table = Spec.changelog("3:1", rows: [
            ("0.1", "2026-08-20", "최초 작성"),
            ("0.2", "2026-08-27", "목록 (SC-PRD-LST-001) 체크박스 추가, 삭제 모달 (SC-PRD-DEL-003) 문구 수정"),
        ])
        let entries = SpecExtractor.changelog(in: table, page: Spec.page1)
        #expect(entries.count == 2)
        #expect(entries[1].version == "0.2")
        #expect(entries[1].date == "2026-08-27")
        #expect(entries[1].pageName == "설정")
        #expect(entries[1].screenIDs == ["SC-PRD-LST-001", "SC-PRD-DEL-003"])
        #expect(SpecExtractor.isChangelog(table))
        #expect(SpecExtractor.isChangelog(FigmaNode(id: "1", name: "제/개정 이력")))
        #expect(!SpecExtractor.isChangelog(FigmaNode(id: "1", name: "간지")))
    }

    @Test func emptyChangelogHasNoEntries() {
        #expect(SpecExtractor.changelog(in: Spec.changelog("3:1", rows: []), page: Spec.page1).isEmpty)
    }

    @Test func stripsPageNoteAndSectionStatus() {
        #expect(SpecExtractor.stripNote("회원 관리 (9/9 등급 컬럼 추가, 상세 추가)") == "회원 관리")
        #expect(SpecExtractor.stripStatus("[작업 중/보류] 상품 > 옵션 관리") == "상품 > 옵션 관리")
    }
}

@Suite struct FigmaAPITests {
    @Test func fileKeyFromURLs() {
        let key = "AbCdEfGh1jKlMnOpQrStUv"
        #expect(FigmaFileURL.fileKey(from: "https://www.figma.com/design/\(key)/-Demo-%ED%99%94?m=auto&t=abc") == key)
        #expect(FigmaFileURL.fileKey(from: "https://figma.com/file/\(key)/Demo") == key)
        #expect(FigmaFileURL.fileKey(from: "https://www.figma.com/design/\(key)/branch/BRANCHkey1234567890abcd/Demo") == "BRANCHkey1234567890abcd")
        #expect(FigmaFileURL.fileKey(from: "  \(key) ") == key)
        #expect(FigmaFileURL.fileKey(from: "https://www.figma.com/board/\(key)/Board") == nil)
        #expect(FigmaFileURL.fileKey(from: "https://example.com/design/\(key)/x") == nil)
        #expect(FigmaFileURL.link(fileKey: key, nodeID: "34:2623")?.absoluteString == "https://www.figma.com/design/\(key)?node-id=34-2623")
    }

    @Test func decodesRESTNodes() throws {
        let json = """
        {"nodes": {"10:1": {"document": {"id": "10:1", "name": "SC-1", "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 2400, "height": 1350},
            "children": [
              {"id": "10:2", "name": "renamed layer", "type": "TEXT", "characters": "실제 글"},
              {"id": "10:3", "name": "old", "type": "TEXT", "characters": "숨김", "visible": false},
              {"id": "10:4", "name": "button", "type": "INSTANCE", "componentId": "77:1", "absoluteBoundingBox": null},
              {"id": "10:5", "name": "image 1", "type": "RECTANGLE", "fills": [
                {"type": "SOLID", "color": {"r": 1, "g": 1, "b": 1, "a": 1}},
                {"type": "IMAGE", "imageRef": "hidden-ref", "visible": false},
                {"type": "IMAGE", "imageRef": "abc123", "scaleMode": "FILL"}]}
            ]}}, "9:9": null}}
        """
        let nodes = try FigmaAPI.parseNodes(Data(json.utf8))
        let node = try #require(nodes["10:1"])
        #expect(nodes["9:9"] == nil)
        #expect(node.height == 1350)
        #expect(node.children[0].text == "실제 글")   // 레이어 이름이 아니라 내용
        #expect(node.visibleTexts().compactMap(\.text) == ["실제 글"])
        #expect(node.children[2].componentId == "77:1")
        #expect(node.children[2].height == nil)
        #expect(node.children[3].imageRef == "abc123")
        #expect(node.children[0].imageRef == nil)
    }

    @Test func swappedScreenshotIsReported() {
        let old = ["5": SpecComponent(name: "image 163", componentID: SpecComponent.imagePrefix + "a")]
        let new = ["5": SpecComponent(name: "image 163", componentID: SpecComponent.imagePrefix + "b")]
        #expect(SpecDiff.components(old, new).map(\.label) == ["이미지 교체"])
    }

    @Test func parsesFileInfo() throws {
        let json = """
        {"name": "[Demo] 화면설계서", "lastModified": "2026-10-19T08:21:33Z", "version": "1",
         "document": {"id": "0:0", "name": "Document", "type": "DOCUMENT", "children": [
            {"id": "0:1", "name": "공통", "type": "CANVAS"}, {"id": "34:1", "name": "API (10/19 수정)", "type": "CANVAS"}]}}
        """
        let info = try FigmaAPI.parseFile(Data(json.utf8))
        #expect(info.name == "[Demo] 화면설계서")
        #expect(info.pages.map(\.id) == ["0:1", "34:1"])
        #expect(throws: FigmaAPI.Failure.malformed) { try FigmaAPI.parseFile(Data("{}".utf8)) }
    }

    @Test func classifiesFailures() {
        #expect(FigmaAPI.failure(status: 200, retryAfter: nil) == nil)
        #expect(FigmaAPI.failure(status: 403, retryAfter: nil) == .forbidden(nil))
        #expect(FigmaAPI.failure(status: 429, retryAfter: " 30") == .rateLimited(retryAfter: 30))
        #expect(FigmaAPI.failure(status: 502, retryAfter: nil) == .server(502))
    }

    /// 2026-10-22 실제 응답 본문. 403 하나로 틀린 토큰, 범위 부족, 파일 권한 없음이 다 온다.
    @Test func readsTheReasonOutOf403() {
        let invalid = Data(#"{"status":403,"err":"Invalid token"}"#.utf8)
        #expect(FigmaAPI.failure(status: 403, retryAfter: nil, body: invalid) == .unauthorized)
        let scope = Data(#"{"status":403,"error":true,"message":"Invalid scope: [\"file_content:read\"]. This endpoint requires the file_read or files:read or current_user:read scope."}"#.utf8)
        let failure = FigmaAPI.failure(status: 403, retryAfter: nil, body: scope)
        #expect(failure == .missingScope(required: "file_read or files:read or current_user:read"))
        #expect(failure?.message.contains("파일을 볼 권한") == false)
        let denied = Data(#"{"status":403,"err":"Forbidden"}"#.utf8)
        #expect(FigmaAPI.failure(status: 403, retryAfter: nil, body: denied) == .forbidden("Forbidden"))
        #expect(FigmaAPI.failure(status: 401, retryAfter: nil, body: Data("{}".utf8)) == .unauthorized)
    }

    @Test func requestsCarryTokenAndIDs() {
        let request = FigmaAPI.nodesRequest(fileKey: "k", ids: ["1:2", "3:4"], depth: 3, token: "secret")
        #expect(request.value(forHTTPHeaderField: "X-Figma-Token") == "secret")
        #expect(request.url?.absoluteString == "https://api.figma.com/v1/files/k/nodes?ids=1:2,3:4&depth=3")
    }

    @Test func candidatesSkipCoverAndSmallFrames() {
        let page = Spec.page("1:1", "설정", [
            Spec.section("2:1", "간지", [Spec.frame("2:2", "간지", height: 1080, []), Spec.changelog("2:3", rows: [])]),
            Spec.section("3:1", "[완료] 설정 > 목록", [Spec.screen("10:1"), Spec.frame("3:2", "메모", height: 200, [])]),
            Spec.screen("11:1"),
        ])
        let found = FigmaAPI.candidates(in: page, pageID: "1:1")
        #expect(found.map(\.id) == ["2:3", "10:1", "11:1"])
        #expect(found[0].isChangelog)
        #expect(found[1].sectionName == "[완료] 설정 > 목록")
    }

    @Test func skipsDividerAndCommonPages() {
        #expect(FigmaAPI.isSkippedPage("---"))
        #expect(FigmaAPI.isSkippedPage("공통 컴포넌트"))
        #expect(FigmaAPI.isSkippedPage("bak"))
        #expect(!FigmaAPI.isSkippedPage("상품 관리"))
        #expect(!FigmaAPI.isSkippedPage("주문 관리 (10/19 수정)"))
    }
}
