import Foundation

/// 피그마 REST API 노드에서 변경 기록에 쓰는 필드만 받는다. 나머지 필드는 버린다.
public struct FigmaNode: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var visible: Bool
    /// 글자 노드의 내용. 레이어 이름은 디자이너가 바꿀 수 있어 내용은 이 값으로만 읽는다.
    public var characters: String?
    public var componentId: String?
    /// 이미지 채우기의 해시. 목업에 붙인 화면 캡처를 바꾸면 달라진다.
    public var imageRef: String?
    /// 캔버스 기준 위치. 화면 안 어디가 바뀌었는지 표시할 때 화면 프레임 위치를 빼서 쓴다.
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var children: [FigmaNode]

    public init(id: String, name: String = "", type: String = "FRAME", visible: Bool = true, characters: String? = nil,
                componentId: String? = nil, imageRef: String? = nil, x: Double? = nil, y: Double? = nil,
                width: Double? = nil, height: Double? = nil, children: [FigmaNode] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.visible = visible
        self.characters = characters
        self.componentId = componentId
        self.imageRef = imageRef
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, visible, characters, componentId, fills, absoluteBoundingBox, children
    }

    private struct Box: Decodable {
        let x: Double?
        let y: Double?
        let width: Double
        let height: Double
    }

    private struct Paint: Decodable {
        let visible: Bool?
        let imageRef: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        characters = try container.decodeIfPresent(String.self, forKey: .characters)
        componentId = try container.decodeIfPresent(String.self, forKey: .componentId)
        // fills는 여러 형태가 섞여 와서 읽지 못하면 이미지 없음으로 둔다
        let fills = try? container.decodeIfPresent([Paint].self, forKey: .fills)
        imageRef = fills?.first { $0.visible != false && $0.imageRef != nil }?.imageRef
        let box = try container.decodeIfPresent(Box.self, forKey: .absoluteBoundingBox)
        x = box?.x
        y = box?.y
        width = box?.width
        height = box?.height
        children = try container.decodeIfPresent([FigmaNode].self, forKey: .children) ?? []
    }

    /// 글자 노드면 내용, 아니면 nil.
    public var text: String? {
        guard type == "TEXT" else { return nil }
        return DesignText.normalize(characters ?? name)
    }

    /// 숨긴 레이어(조상이 숨겨진 것 포함)를 뺀 글자 노드를 레이어 순서대로.
    public func visibleTexts() -> [FigmaNode] {
        guard visible else { return [] }
        if type == "TEXT" { return [self] }
        return children.flatMap { $0.visibleTexts() }
    }

    /// 보이는 글자 가운데 `text`와 같은 것이 있는지.
    public func shows(_ text: String) -> Bool {
        guard visible else { return false }
        if self.text == text { return true }
        return children.contains { $0.shows(text) }
    }
}

/// 화면설계서 글자를 비교하기 좋게 다듬는다.
public enum DesignText {
    /// 줄 안의 공백을 하나로 줄이고 빈 줄을 지운다. 피그마가 넣는 nbsp·zero-width space도 지운다.
    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 첫 줄을 `limit`자까지.
    public static func headline(_ text: String, limit: Int = 40) -> String {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        return first.count > limit ? String(first.prefix(limit)) + "…" : first
    }
}

/// 피그마 주소에서 파일 키를 꺼낸다. 주소를 통째로 붙여넣어도, 키만 넣어도 된다.
public enum FigmaFileURL {
    public static func fileKey(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKey(text) { return text }
        // 주소창에서 `www.figma.com/design/…`만 복사해 오기도 한다
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host, host == "figma.com" || host.hasSuffix(".figma.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        // 프로토타입(proto) 주소도 같은 파일을 가리킨다
        guard parts.count >= 2, ["design", "file", "proto"].contains(parts[0]) else { return nil }
        // 브랜치 주소는 브랜치 키가 파일 키다
        if parts.count >= 4, parts[2] == "branch", isKey(parts[3]) { return parts[3] }
        return isKey(parts[1]) ? parts[1] : nil
    }

    /// 주소의 `node-id`(`12-345`)를 API가 쓰는 `12:345`로. 없으면 nil.
    public static func nodeID(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard fileKey(from: text) != nil, let components = URLComponents(string: text),
              let value = components.queryItems?.first(where: { $0.name == "node-id" })?.value, !value.isEmpty else { return nil }
        let id = value.replacingOccurrences(of: "-", with: ":")
        return id.contains(":") ? id : nil
    }

    /// 프레임으로 바로 가는 주소. 노드 ID의 `:`는 주소에서 `-`로 쓴다.
    public static func link(fileKey: String, nodeID: String) -> URL? {
        var components = URLComponents(string: "https://www.figma.com/design/\(fileKey)")
        components?.queryItems = [URLQueryItem(name: "node-id", value: nodeID.replacingOccurrences(of: ":", with: "-"))]
        return components?.url
    }

    private static func isKey(_ text: String) -> Bool {
        (22...128).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
