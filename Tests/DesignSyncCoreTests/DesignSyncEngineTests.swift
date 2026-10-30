import Foundation
import Testing
@testable import DesignSyncCore

/// 피그마 응답을 흉내 내는 가짜 서버. 받은 요청 경로를 적어 둬서 몇 번 불렀는지 본다.
private final class FakeFigma: @unchecked Sendable {
    var lastModified = "2026-10-20T01:00:00Z"
    var pages: [FigmaNode] = []
    private(set) var requests: [String] = []
    private let lock = NSLock()

    func transport(_ request: URLRequest) async throws -> Data {
        guard let url = request.url else { throw URLError(.badURL) }
        lock.withLock { requests.append(url.path) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ids = query.first { $0.name == "ids" }?.value?.split(separator: ",").map(String.init) ?? []
        if url.path.hasSuffix("/nodes") {
            var nodes: [String: Any] = [:]
            for id in ids { nodes[id] = find(id).map { ["document": json($0)] } ?? NSNull() }
            return try JSONSerialization.data(withJSONObject: ["nodes": nodes])
        }
        let document: [String: Any] = ["id": "0:0", "name": "Document", "type": "DOCUMENT",
                                       "children": pages.map { ["id": $0.id, "name": $0.name, "type": "CANVAS"] }]
        return try JSONSerialization.data(withJSONObject: ["name": "데모 화면설계서", "lastModified": lastModified, "document": document])
    }

    var count: Int { lock.withLock { requests.count } }

    private func find(_ id: String) -> FigmaNode? {
        func search(_ node: FigmaNode) -> FigmaNode? {
            if node.id == id { return node }
            for child in node.children { if let hit = search(child) { return hit } }
            return nil
        }
        for page in pages { if let hit = search(page) { return hit } }
        return nil
    }

    private func json(_ node: FigmaNode) -> [String: Any] {
        var object: [String: Any] = ["id": node.id, "name": node.name, "type": node.type, "visible": node.visible,
                                     "children": node.children.map(json)]
        if let characters = node.characters { object["characters"] = characters }
        if let component = node.componentId { object["componentId"] = component }
        if let width = node.width, let height = node.height {
            object["absoluteBoundingBox"] = ["x": 0, "y": 0, "width": width, "height": height]
        }
        return object
    }
}

@Suite struct DesignSyncEngineTests {
    private func page(items: [(String, String)]) -> FigmaNode {
        Spec.page("1:1", "설정 (10/19 수정)", [
            Spec.section("2:1", "간지", [Spec.changelog("2:3", rows: [("0.1", "2026-08-20", "최초 작성")])]),
            Spec.section("3:1", "설정_v0.4", [Spec.screen("10:1", screenID: "SC-SET-001", items: items),
                                              Spec.frame("3:9", "상태 화면", height: 1080, [Spec.text("3:10", "빈 목록")])]),
        ])
    }

    @Test func capturesScreensAndSkipsUnchangedFile() async throws {
        let figma = FakeFigma()
        figma.pages = [Spec.page("0:1", "---", []), page(items: [("1", "검색")])]
        let source = DesignSource(fileKey: "Demo")
        var history = DesignHistory()

        guard case .captured(let first) = try await DesignSyncEngine.run(source: source, token: "t", known: nil, transport: figma.transport)
        else { Issue.record("처음에는 받아야 한다"); return }
        #expect(first.screens.map(\.screenID) == ["SC-SET-001"])
        #expect(first.changelog?.map(\.version) == ["0.1"])
        #expect(first.coveredPages == ["1:1"])   // 구분선 페이지는 보지 않는다
        #expect(first.present == ["10:1", "3:9"])
        history.record(first, at: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(history.files["Demo"].map { Set($0.ignored.keys) } == ["3:9"])

        // 파일이 그대로면 파일 정보 한 번만 묻는다
        let before = figma.count
        guard case .unchanged = try await DesignSyncEngine.run(source: source, token: "t", known: history.files["Demo"],
                                                              transport: figma.transport)
        else { Issue.record("바뀌지 않은 파일은 받지 않아야 한다"); return }
        #expect(figma.count == before + 1)

        // 고쳐지면 화면이 아니었던 프레임은 다시 받지 않고 바뀐 것을 찾는다
        figma.lastModified = "2026-10-21T02:00:00Z"
        figma.pages = [page(items: [("1", "검색"), ("2", "초기화")])]
        guard case .captured(let second) = try await DesignSyncEngine.run(source: source, token: "t", known: history.files["Demo"],
                                                                         transport: figma.transport)
        else { Issue.record("고쳐진 파일은 받아야 한다"); return }
        #expect(second.fetched == ["10:1"])
        let events = history.record(second, at: Date(timeIntervalSince1970: 1_790_100_000))
        #expect(events.map(\.kind) == [.changed])
        #expect(events.first?.changes.map(\.op) == [.added])
    }
}

/// 링크로 고른 화면만 지켜볼 때.
@Suite struct DesignScopeTests {
    private func pages(order: [(String, String)] = [("1", "검색")], delivery: [(String, String)] = [("1", "조회")]) -> [FigmaNode] {
        [Spec.page("1:1", "주문", [Spec.section("2:1", "주문_v1", [Spec.screen("10:1", screenID: "SC-ORD-001", path: "주문 > 목록", items: order)])]),
         Spec.page("1:2", "배송", [
            Spec.section("3:1", "배송_v1", [Spec.screen("20:1", screenID: "SC-DLV-001", path: "배송 > 조회", items: delivery),
                                            Spec.screen("20:2", screenID: "SC-DLV-002", path: "배송 > 상세")]),
            Spec.section("4:1", "간지", [Spec.changelog("4:3", rows: [("0.1", "2026-08-20", "최초 작성")])]),
         ])]
    }

    @Test func fetchesOnlyTheLinkedScreenAndRemembersItsPage() async throws {
        let figma = FakeFigma()
        figma.pages = pages()
        var source = DesignSource(fileKey: "Demo", scope: [DesignScope(nodeID: "20:1", name: "SC-DLV-001")])
        var history = DesignHistory()

        guard case .captured(let first) = try await DesignSyncEngine.run(source: source, token: "t", known: nil, transport: figma.transport)
        else { Issue.record("처음에는 받아야 한다"); return }
        #expect(first.screens.map(\.screenID) == ["SC-DLV-001"])
        #expect(first.coveredPages == ["1:2"])
        // 같은 페이지의 다른 화면은 있는 것으로만 치고 받지 않는다
        #expect(first.present == ["20:1", "20:2"])
        #expect(first.fetched == ["20:1"])
        #expect(first.resolved == [DesignScope(nodeID: "20:1", name: "SC-DLV-001", pageID: "1:2", frames: ["20:1"])])
        #expect(first.missing.isEmpty)
        #expect(first.changelog?.count == 1)
        history.record(first, at: Date(timeIntervalSince1970: 1_790_000_000))
        source.scope = first.resolved

        // 다음에는 찾아 둔 페이지만 살펴본다: 파일 정보, 페이지 뼈대 하나, 화면과 이력 한 묶음
        figma.lastModified = "2026-10-21T02:00:00Z"
        figma.pages = pages(order: [("1", "검색"), ("2", "초기화")], delivery: [("1", "조회"), ("2", "엑셀 다운로드")])
        let before = figma.count
        guard case .captured(let second) = try await DesignSyncEngine.run(source: source, token: "t", known: history.files["Demo"],
                                                                         transport: figma.transport)
        else { Issue.record("고쳐진 파일은 받아야 한다"); return }
        #expect(figma.count == before + 3)
        let events = history.record(second, at: Date(timeIntervalSince1970: 1_790_100_000))
        // 지켜보지 않는 주문 화면의 변경과 같은 페이지 다른 화면은 남지 않는다
        #expect(events.map(\.screenID) == ["SC-DLV-001"])
        #expect(history.files["Demo"].map { Set($0.screens.keys) } == ["20:1"])
    }

    @Test func newlyLinkedScreenStartsAsBaseline() async throws {
        let figma = FakeFigma()
        figma.pages = pages()
        var source = DesignSource(fileKey: "Demo", scope: [DesignScope(nodeID: "20:1")])
        var history = DesignHistory()
        guard case .captured(let first) = try await DesignSyncEngine.run(source: source, token: "t", known: nil, transport: figma.transport)
        else { Issue.record("처음에는 받아야 한다"); return }
        history.record(first, at: Date(timeIntervalSince1970: 1_790_000_000))
        source.scope = first.resolved + [DesignScope(nodeID: "10:1")]
        history.files["Demo"]?.lastModified = nil

        guard case .captured(let second) = try await DesignSyncEngine.run(source: source, token: "t", known: history.files["Demo"],
                                                                         transport: figma.transport)
        else { Issue.record("링크를 더하면 다시 받아야 한다"); return }
        #expect(second.fresh == ["10:1"])
        let events = history.record(second, at: Date(timeIntervalSince1970: 1_790_100_000))
        // 이제 막 지켜보기 시작한 화면은 새 화면 변경이 아니다
        #expect(events.isEmpty)
        #expect(history.files["Demo"].map { Set($0.screens.keys) } == ["10:1", "20:1"])
    }

    @Test func sectionPageAndWrappedScreenLinks() async throws {
        let figma = FakeFigma()
        figma.pages = pages() + [Spec.page("1:3", "공통", [
            Spec.frame("5:1", "틀", height: 3000, [Spec.screen("30:1", screenID: "SC-CMN-001", path: "공통 > 팝업"),
                                                   Spec.screen("30:2", screenID: "SC-CMN-002", path: "공통 > 알림")]),
        ])]
        // 섹션 링크는 그 안의 화면 전부
        let section = DesignSource(fileKey: "Demo", scope: [DesignScope(nodeID: "3:1")])
        guard case .captured(let bySection) = try await DesignSyncEngine.run(source: section, token: "t", known: nil, transport: figma.transport)
        else { Issue.record("받아야 한다"); return }
        #expect(Set(bySection.screens.map(\.screenID)) == ["SC-DLV-001", "SC-DLV-002"])

        // 공통처럼 기본으로 건너뛰는 페이지도 링크로 고르면 보고, 틀 안쪽 화면 링크는 그 틀을 받아 찾는다
        let wrapped = DesignSource(fileKey: "Demo", scope: [DesignScope(nodeID: "30:2"), DesignScope(nodeID: "99:9")])
        guard case .captured(let byInner) = try await DesignSyncEngine.run(source: wrapped, token: "t", known: nil, transport: figma.transport)
        else { Issue.record("받아야 한다"); return }
        #expect(byInner.screens.contains { $0.screenID == "SC-CMN-002" })
        #expect(byInner.resolved.first?.frames == ["30:2"])
        #expect(byInner.missing == ["99:9"])
    }
}

/// 화면 하나를 견줄 때는 그 페이지만 살펴 받는다.
@Suite struct DesignCompareFillTests {
    @Test func outlinesOnlyTheChosenPages() async throws {
        let figma = FakeFigma()
        figma.pages = [Spec.page("1:1", "주문", [Spec.section("2:1", "주문_v1", [Spec.screen("10:1", screenID: "SC-ORD-001", items: [("1", "검색")])])]),
                       Spec.page("1:2", "배송", [Spec.section("3:1", "배송_v1", [Spec.screen("20:1", screenID: "SC-DLV-001", items: [("1", "조회")])])])]
        var snapshot = VersionSnapshot(fileKey: "Demo", version: "v1")
        try await DesignCompare.fill(&snapshot, pageIDs: ["1:1"], token: "t", wanted: { _ in true }, transport: figma.transport)
        #expect(figma.count == 2)
        #expect(snapshot.allScreens.map(\.screenID) == ["SC-ORD-001"])
        #expect(snapshot.outlines("1:1") && !snapshot.outlines("1:2"))

        try await DesignCompare.fill(&snapshot, pageIDs: ["1:1"], token: "t", wanted: { _ in true }, transport: figma.transport)
        #expect(figma.count == 2)

        try await DesignCompare.fill(&snapshot, token: "t", wanted: { _ in true }, transport: figma.transport)
        #expect(figma.count == 5)
        #expect(snapshot.outlined == nil)
        #expect(Set(snapshot.allScreens.map(\.screenID)) == ["SC-ORD-001", "SC-DLV-001"])
    }
}

/// 메뉴 하나만 받을 때.
@Suite struct DesignMenuFetchTests {
    private func pages(order: [(String, String)] = [("1", "검색")], delivery: [(String, String)] = [("1", "조회")],
                       history: [(String, String, String)] = [("0.1", "2026-08-20", "최초 작성")]) -> [FigmaNode] {
        [Spec.page("1:1", "주문", [
            Spec.section("2:1", "주문_v1", [Spec.screen("10:1", screenID: "SC-ORD-001", path: "주문 > 목록", items: order)]),
            Spec.section("2:5", "간지", [Spec.changelog("2:6", rows: [("0.1", "2026-08-20", "주문 작성")])]),
         ]),
         Spec.page("1:2", "배송", [
            Spec.section("3:1", "배송_v1", [Spec.screen("20:1", screenID: "SC-DLV-001", path: "배송 > 조회", items: delivery),
                                            Spec.screen("20:2", screenID: "SC-DLV-002", path: "배송 > 상세")]),
            Spec.section("4:1", "간지", [Spec.changelog("4:3", rows: history)]),
         ])]
    }

    @Test func fetchesOnlyTheMenuPageAndKeepsTheProjectBaseline() async throws {
        let figma = FakeFigma()
        figma.pages = pages()
        let source = DesignSource(fileKey: "Demo")
        var history = DesignHistory()
        guard case .captured(let first) = try await DesignSyncEngine.run(source: source, token: "t", known: nil, transport: figma.transport)
        else { Issue.record("처음에는 받아야 한다"); return }
        history.record(first, at: Date(timeIntervalSince1970: 1_790_000_000))
        let baseline = history.files["Demo"]

        // 두 메뉴가 다 바뀌어도 배송만 받으면 배송 페이지만 보고 배송 화면만 남는다
        figma.lastModified = "2026-10-21T02:00:00Z"
        figma.pages = pages(order: [("1", "검색"), ("2", "초기화")], delivery: [("1", "조회"), ("2", "엑셀 다운로드")],
                            history: [("0.1", "2026-08-20", "최초 작성"), ("0.2", "2026-10-21", "엑셀 추가")])
        let before = figma.count
        guard case .captured(let menu) = try await DesignSyncEngine.runMenu(source: source, paths: ["배송"], token: "t",
                                                                           known: history.files["Demo"], transport: figma.transport)
        else { Issue.record("바뀐 메뉴는 받아야 한다"); return }
        #expect(figma.count == before + 3)   // 파일 정보, 배송 페이지 뼈대, 화면 한 묶음
        #expect(menu.coveredPages == ["1:2"])
        #expect(menu.partial)
        let events = history.record(menu, at: Date(timeIntervalSince1970: 1_790_100_000))
        #expect(Set(events.map(\.kind)) == [.changed, .changelog])
        #expect(events.filter { $0.kind == .changed }.map(\.screenID) == ["SC-DLV-001"])
        // 파일 기준은 그대로라 다음 프로젝트 가져오기가 주문 변경을 놓치지 않는다
        #expect(history.files["Demo"]?.lastModified == baseline?.lastModified)
        #expect(history.files["Demo"]?.syncedAt == baseline?.syncedAt)
        #expect(history.files["Demo"]?.changelog.filter { $0.pageID == "1:1" }.count == 1)

        // 그대로인 메뉴는 파일 정보만 묻는다
        let again = figma.count
        guard case .unchanged = try await DesignSyncEngine.runMenu(source: source, paths: ["배송 > 조회"], token: "t",
                                                                  known: history.files["Demo"], transport: figma.transport)
        else { Issue.record("받아 둔 메뉴는 다시 받지 않아야 한다"); return }
        #expect(figma.count == again + 1)

        guard case .captured(let all) = try await DesignSyncEngine.run(source: source, token: "t", known: history.files["Demo"],
                                                                      transport: figma.transport)
        else { Issue.record("프로젝트는 다시 받아야 한다"); return }
        let rest = history.record(all, at: Date(timeIntervalSince1970: 1_790_200_000))
        // 배송은 이미 남겼으니 주문 변경만 새로 나오고, 배송 이력 줄이 두 번 나오지 않는다
        #expect(rest.map(\.screenID) == ["SC-ORD-001"])
    }

    @Test func unknownMenuFallsBackToTheWholeProject() async throws {
        let figma = FakeFigma()
        figma.pages = pages()
        guard case .captured(let capture) = try await DesignSyncEngine.runMenu(source: DesignSource(fileKey: "Demo"), paths: ["배송"], token: "t",
                                                                              known: nil, transport: figma.transport)
        else { Issue.record("처음에는 받아야 한다"); return }
        #expect(!capture.partial)
        #expect(capture.coveredPages == ["1:1", "1:2"])
    }
}
