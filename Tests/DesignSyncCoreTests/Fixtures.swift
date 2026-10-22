import Foundation
@testable import DesignSyncCore

/// 회사 화면설계서와 같은 틀(헤더 표, Description 패널, 번호 표식)로 만든 가짜 화면. 실제 내용은 넣지 않는다.
enum Spec {
    static func text(_ id: String, _ characters: String, visible: Bool = true) -> FigmaNode {
        FigmaNode(id: id, name: String(characters.prefix(20)), type: "TEXT", visible: visible, characters: characters)
    }

    static func frame(_ id: String, _ name: String = "Frame", height: Double = 40, visible: Bool = true,
                      _ children: [FigmaNode]) -> FigmaNode {
        FigmaNode(id: id, name: name, type: "FRAME", visible: visible, width: 400, height: height, children: children)
    }

    static func instance(_ id: String, _ name: String, component: String) -> FigmaNode {
        FigmaNode(id: id, name: name, type: "INSTANCE", componentId: component, width: 80, height: 32)
    }

    /// 헤더 행: 라벨 칸과 값 칸이 번갈아 온다.
    static func header(_ id: String, screenID: String, title: String, path: String, author: String = "작성자A",
                       requirement: String = "-") -> FigmaNode {
        let pairs = [("시스템", "Demo"), ("요구사항 ID", requirement), ("화면 ID", screenID), ("작성자", author),
                     ("화면명", title), ("화면 경로", path)]
        let cells = pairs.enumerated().map { index, pair in
            frame("\(id):c\(index)", "Cell", [text("\(id):l\(index)", pair.0), text("\(id):v\(index)", pair.1)])
        }
        return frame(id, "Row", height: 104, [frame("\(id):f", "Frame 9", height: 104, cells)])
    }

    /// Description 패널. 숨긴 자리표시 행을 하나 섞는다(실제 템플릿처럼).
    static func panel(_ id: String, notes: String? = nil, items: [(String, String)], name: String = "Description") -> FigmaNode {
        var children: [FigmaNode] = []
        if let notes { children += [text("\(id):nh", "참고"), text("\(id):nb", notes)] }
        children.append(text("\(id):dh", "Description"))
        for (index, item) in items.enumerated() {
            children.append(frame("\(id):i\(index)", "Frame 17", [
                frame("\(id):n\(index)", "Frame 3", [text("\(id):nn\(index)", item.0)]),
                frame("\(id):t\(index)", "Frame 4", [text("\(id):tt\(index)", item.1)]),
            ]))
        }
        children.append(frame("\(id):hidden", "Frame 17", visible: false, [
            text("\(id):hn", "\(items.count + 1)"), text("\(id):ht", "화면 기능 설명"),
        ]))
        return frame(id, name, height: 1498, [frame("\(id):in", "Frame 11", height: 1498, children)])
    }

    static func mockup(_ id: String, texts: [(String, String)], components: [(String, String, String)] = [],
                       markers: Int = 2) -> FigmaNode {
        var children = texts.map { text($0.0, $0.1) }
        children += components.map { instance($0.0, $0.1, component: $0.2) }
        children += (0..<markers).map { frame("\(id):num\($0)", "num", [text("\(id):numt\($0)", "\($0 + 1)")]) }
        return frame(id, "page", height: 980, children)
    }

    static func screen(_ id: String, screenID: String = "SC-DEMO-001", title: String = "목록", path: String = "설정 > 목록",
                       items: [(String, String)] = [("1", "검색 버튼 클릭 시 목록 조회")], notes: String? = nil,
                       texts: [(String, String)] = [("m:1", "등록")], components: [(String, String, String)] = [],
                       frameName: String? = nil, panelName: String = "Description", visible: Bool = true) -> FigmaNode {
        FigmaNode(id: id, name: frameName ?? screenID, type: "FRAME", visible: visible, width: 2400, height: 1350, children: [
            header("\(id):row", screenID: screenID, title: title, path: path),
            text("\(id):copy", "© 2025 Demo Co., Ltd.\u{200B}"),
            panel("\(id):desc", notes: notes, items: items, name: panelName),
            mockup("\(id):page", texts: texts, components: components),
        ])
    }

    static func section(_ id: String, _ name: String, _ children: [FigmaNode]) -> FigmaNode {
        FigmaNode(id: id, name: name, type: "SECTION", width: 20000, height: 1700, children: children)
    }

    static func page(_ id: String, _ name: String, _ children: [FigmaNode]) -> FigmaNode {
        FigmaNode(id: id, name: name, type: "CANVAS", children: children)
    }

    /// 제·개정 이력 표: 칸 순서가 번호, 버전, 날짜, 내용.
    static func changelog(_ id: String, rows: [(String, String, String)]) -> FigmaNode {
        var children = [text("\(id):h", "제・개정 이력")]
        for (index, row) in rows.enumerated() {
            children += [text("\(id):k\(index)", "Change type"), text("\(id):no\(index)", "\(index + 1)"),
                         text("\(id):ver\(index)", row.0), text("\(id):d\(index)", row.1), text("\(id):b\(index)", row.2)]
        }
        return frame(id, "제개정 이력", height: 1080, children)
    }

    static let page1 = SpecExtractor.Page(id: "1:1", name: "설정 (10/19 수정)")
}
