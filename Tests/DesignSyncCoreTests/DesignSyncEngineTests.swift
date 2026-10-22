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
