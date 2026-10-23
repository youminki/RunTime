import Foundation

/// 화면설계서 Description의 번호 항목 하나.
public struct SpecItem: Codable, Equatable, Sendable {
    public var number: String
    public var text: String

    public init(number: String, text: String) {
        self.number = number
        self.text = text
    }

    public var label: String { "\(number). \(DesignText.headline(text))" }
}

/// 목업 안 컴포넌트 인스턴스나 이미지. 교체되면 `componentID`가 바뀐다.
public struct SpecComponent: Codable, Equatable, Sendable {
    /// 이미지는 컴포넌트 ID 대신 이미지 해시를 이 머리와 함께 둔다.
    public static let imagePrefix = "image:"

    public var name: String
    public var componentID: String

    public var isImage: Bool { componentID.hasPrefix(Self.imagePrefix) }

    public init(name: String, componentID: String) {
        self.name = name
        self.componentID = componentID
    }
}

/// 목업 요소가 화면 안 어디에 있는지. 마크업할 때 바뀐 곳을 찾기 쉽게 레이어 경로와 자리를 둔다.
public struct SpecPlace: Codable, Equatable, Hashable, Sendable {
    /// 화면 프레임 아래 레이어 이름들 (`Frame 12` 같은 자동 이름은 뺀다). 마지막은 요소 자신.
    public var path: [String]
    /// 화면 프레임 크기에 대한 비율 (0~1). 화면 이미지 위에 표시한다.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(path: [String], x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.path = path
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 자리를 모르는 요소 (캔버스 위치가 없을 때)는 넓이가 0이다.
    public var hasBox: Bool { width > 0 && height > 0 }
}

/// 화면설계서 화면 하나를 비교용으로 줄인 것. 피그마 원본은 크기가 커서 저장하지 않는다.
public struct ScreenSnapshot: Codable, Equatable, Sendable {
    public var frameID: String
    /// 이 화면을 받아 온 후보 프레임. 화면 여러 개를 감싼 프레임에서 나왔으면 그 프레임이다.
    public var candidateID: String
    public var frameName: String
    /// 헤더의 화면 ID. 없거나 `-`면 프레임 이름.
    public var screenID: String
    public var title: String
    /// 헤더의 화면 경로. 없으면 섹션, 그것도 없으면 페이지 이름.
    public var menuPath: String
    public var requirementID: String
    public var author: String
    /// 페이지 이름은 `(10/19 수정)`처럼 자주 바뀌어서 페이지는 ID로 가린다.
    public var pageID: String
    public var pageName: String
    /// 바로 위 섹션 이름. `[수정중] → [완료]` 같은 진행 상태가 여기 붙는다.
    public var sectionName: String
    /// Description 위의 참고 글.
    public var notes: String
    public var items: [SpecItem]
    /// 목업 글자. 노드 ID → 내용.
    public var texts: [String: String]
    public var components: [String: SpecComponent]
    /// 목업 글자·컴포넌트의 노드 ID → 자리. 이 칸이 생기기 전 기록은 nil이다.
    public var places: [String: SpecPlace]?

    public init(frameID: String, candidateID: String? = nil, frameName: String = "", screenID: String, title: String = "",
                menuPath: String = "", requirementID: String = "", author: String = "", pageID: String = "",
                pageName: String = "", sectionName: String = "", notes: String = "", items: [SpecItem] = [],
                texts: [String: String] = [:], components: [String: SpecComponent] = [:], places: [String: SpecPlace]? = nil) {
        self.frameID = frameID
        self.candidateID = candidateID ?? frameID
        self.frameName = frameName
        self.screenID = screenID
        self.title = title
        self.menuPath = menuPath
        self.requirementID = requirementID
        self.author = author
        self.pageID = pageID
        self.pageName = pageName
        self.sectionName = sectionName
        self.notes = notes
        self.items = items
        self.texts = texts
        self.components = components
        self.places = places
    }
}

/// 제·개정 이력 표의 한 줄.
public struct ChangelogEntry: Codable, Equatable, Hashable, Sendable {
    /// 페이지 이름은 `(10/19 수정)`처럼 자주 바뀌어서 같은 줄인지는 페이지 ID로 가린다.
    public var pageID: String
    public var pageName: String
    public var version: String?
    /// `yyyy-MM-dd`
    public var date: String
    /// 같은 페이지에서 버전·날짜가 같은 줄 가운데 몇 번째인지. 버전 칸을 비워 둔 줄이 겹치지 않게 한다.
    public var order: Int
    public var text: String
    /// 이력 표 프레임. 피그마에서 바로 열 때 쓴다 (이 칸이 생기기 전 기록은 nil).
    public var frameID: String?

    public init(pageID: String = "", pageName: String, version: String?, date: String, order: Int = 0, text: String,
                frameID: String? = nil) {
        self.frameID = frameID
        self.pageID = pageID
        self.pageName = pageName
        self.version = version
        self.date = date
        self.order = order
        self.text = text
    }

    /// 글에 적힌 화면 ID들 (`SC-SET-001`처럼 대문자 머리에 하이픈 마디가 둘 이상).
    public var screenIDs: [String] {
        let pattern = try! NSRegularExpression(pattern: "\\b[A-Z]{2,5}(?:-[A-Z0-9]+){2,}\\b")
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return pattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .filter { seen.insert($0).inserted }
    }

    var key: String { "\(pageID)|\(version ?? "")|\(date)|\(order)" }
}

/// 화면설계서 템플릿(헤더 표, Description 패널)을 읽는다.
/// 레이어 이름은 디자이너마다 달라서 템플릿에 찍힌 글자 라벨로만 찾는다.
public enum SpecExtractor {
    static let screenIDLabel = "화면 ID"
    static let headerLabels = ["시스템", "요구사항 ID", screenIDLabel, "작성자", "화면명", "화면 경로"]
    static let descriptionLabel = "Description"
    static let noteLabels: Set<String> = ["참고", "참고사항"]
    /// 숨기지 않고 남겨 둔 템플릿 자리표시 글.
    static let placeholders: Set<String> = ["화면 기능 설명", "Text"]
    /// 목업 위 번호 표식. 위치만 바뀌어도 잡히니 비교하지 않는다.
    static let markerNames: Set<String> = ["num"]
    /// 화면 프레임은 헤더 행(높이 100 안팎)보다 훨씬 크다.
    static let minimumScreenHeight = 900.0

    private static let itemNumber = try! NSRegularExpression(pattern: "^\\d+(\\.\\d+)*$")

    /// `root` 아래의 화면을 모두 찾는다. `root`는 페이지, 섹션, 화면 프레임 어느 것이든 된다.
    public static func screens(in root: FigmaNode, page: Page, sectionName: String = "") -> [ScreenSnapshot] {
        var found: [ScreenSnapshot] = []
        collect(root, page: page, section: sectionName, into: &found)
        for index in found.indices { found[index].candidateID = root.id }
        return found
    }

    /// 화면이 놓인 페이지.
    public struct Page: Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    private static func collect(_ node: FigmaNode, page: Page, section: String, into found: inout [ScreenSnapshot]) {
        guard node.visible else { return }
        if isScreen(node) {
            found.append(snapshot(of: node, page: page, sectionName: section))
            return
        }
        let inner = node.type == "SECTION" ? node.name : section
        for child in node.children { collect(child, page: page, section: inner, into: &found) }
    }

    /// 헤더를 품은 가장 안쪽의 큰 프레임이 화면이다. 화면 여러 개를 감싼 프레임은 화면이 아니다.
    static func isScreen(_ node: FigmaNode) -> Bool {
        guard ["FRAME", "COMPONENT", "INSTANCE"].contains(node.type), isLarge(node), node.shows(screenIDLabel) else { return false }
        return !node.children.contains { $0.visible && isLarge($0) && $0.shows(screenIDLabel) }
    }

    private static func isLarge(_ node: FigmaNode) -> Bool {
        (node.height ?? minimumScreenHeight) >= minimumScreenHeight
    }

    static func snapshot(of screen: FigmaNode, page: Page, sectionName: String) -> ScreenSnapshot {
        let texts = screen.visibleTexts().compactMap(\.text)
        var header: [String: String] = [:]
        for (index, text) in texts.enumerated() where headerLabels.contains(text) && header[text] == nil {
            let value = index + 1 < texts.count ? texts[index + 1] : ""
            header[text] = headerLabels.contains(value) || value == "-" ? "" : value
        }
        let headerRow = screen.children.first { $0.visible && !isLarge($0) && $0.shows(screenIDLabel) }
        let panel = screen.children.first { $0.visible && $0.shows(descriptionLabel) && !$0.shows(screenIDLabel) }
        let (notes, items) = panel.map(readPanel) ?? ("", [])

        var mockTexts: [String: String] = [:]
        var components: [String: SpecComponent] = [:]
        var places: [String: SpecPlace] = [:]
        let frame = Frame(screen)
        for child in screen.children where child.visible && child.id != headerRow?.id && child.id != panel?.id {
            readMockup(child, path: [], frame: frame, texts: &mockTexts, components: &components, places: &places)
        }

        let screenID = header[screenIDLabel].flatMap { $0.isEmpty ? nil : $0 } ?? screen.name
        let path = header["화면 경로"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (sectionName.isEmpty ? nil : stripStatus(sectionName))
            ?? stripNote(page.name)
        return ScreenSnapshot(frameID: screen.id, frameName: screen.name, screenID: screenID, title: header["화면명"] ?? "",
                              menuPath: path, requirementID: header["요구사항 ID"] ?? "", author: header["작성자"] ?? "",
                              pageID: page.id, pageName: page.name, sectionName: sectionName, notes: notes, items: items,
                              texts: mockTexts, components: components, places: places)
    }

    /// Description 패널: 위쪽 참고 글, 아래쪽 `번호 → 설명` 항목들.
    private static func readPanel(_ panel: FigmaNode) -> (String, [SpecItem]) {
        let texts = panel.visibleTexts().compactMap(\.text).filter { !$0.isEmpty && !placeholders.contains($0) }
        guard let start = texts.firstIndex(of: descriptionLabel) else { return ("", []) }
        let notes = texts[..<start].filter { !noteLabels.contains($0) }.joined(separator: "\n")
        var items: [SpecItem] = []
        for text in texts[(start + 1)...] {
            if isItemNumber(text) {
                items.append(SpecItem(number: text, text: ""))
            } else if let last = items.indices.last {
                items[last].text += items[last].text.isEmpty ? text : "\n" + text
            }
        }
        return (notes, items.filter { !$0.text.isEmpty })
    }

    private static func readMockup(_ node: FigmaNode, path: [String], frame: Frame, texts: inout [String: String],
                                   components: inout [String: SpecComponent], places: inout [String: SpecPlace]) {
        guard node.visible, !markerNames.contains(node.name) else { return }
        if let text = node.text {
            if !text.isEmpty, !text.hasPrefix("©"), !placeholders.contains(text) {
                texts[node.id] = text
                places[node.id] = frame.place(of: node, path: path + [DesignText.headline(text, limit: 30)])
            }
            return
        }
        if node.type == "INSTANCE", let component = node.componentId {
            components[node.id] = SpecComponent(name: node.name, componentID: component)
            places[node.id] = frame.place(of: node, path: path + [node.name])
        } else if let image = node.imageRef {
            components[node.id] = SpecComponent(name: node.name, componentID: SpecComponent.imagePrefix + image)
            places[node.id] = frame.place(of: node, path: path + [node.name])
        }
        let inner = isGenericName(node.name) ? path : path + [node.name]
        for child in node.children {
            readMockup(child, path: inner, frame: frame, texts: &texts, components: &components, places: &places)
        }
    }

    /// 피그마가 붙이는 자동 이름. 경로에 넣어도 어디인지 알 수 없어 뺀다.
    static func isGenericName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        let generic = ["Frame", "Group", "Rectangle", "Vector", "Auto layout", "Container", "Ellipse", "Line", "Union", "Mask group"]
        return generic.contains { prefix in
            trimmed == prefix || (trimmed.hasPrefix(prefix + " ") && trimmed.dropFirst(prefix.count + 1).allSatisfy(\.isNumber))
        }
    }

    /// 화면 프레임의 캔버스 위치. 요소 자리를 화면 크기에 대한 비율로 바꾼다.
    struct Frame {
        let x, y, width, height: Double?

        init(_ node: FigmaNode) {
            x = node.x; y = node.y; width = node.width; height = node.height
        }

        func place(of node: FigmaNode, path: [String]) -> SpecPlace {
            guard let x, let y, let width, let height, width > 0, height > 0,
                  let nx = node.x, let ny = node.y, let nw = node.width, let nh = node.height
            else { return SpecPlace(path: path) }
            let clamp = { (value: Double) in min(max(value, 0), 1) }
            let left = clamp((nx - x) / width), top = clamp((ny - y) / height)
            let right = clamp((nx + nw - x) / width), bottom = clamp((ny + nh - y) / height)
            return SpecPlace(path: path, x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
        }
    }

    static func isItemNumber(_ text: String) -> Bool {
        itemNumber.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `[완료] 상품 > 목록` → `상품 > 목록`
    public static func stripStatus(_ name: String) -> String {
        name.replacingOccurrences(of: "\\[[^\\]]*\\]\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// `상품 관리 (10/19 수정)` → `상품 관리`
    public static func stripNote(_ name: String) -> String {
        name.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: 제·개정 이력

    /// 제·개정 이력 프레임인지. 디자이너마다 `제・개정`, `제/개정`, `제개정`으로 쓴다.
    public static func isChangelog(_ node: FigmaNode) -> Bool {
        let letters = node.name.filter { $0.isLetter }
        return letters.contains("제개정이력")
    }

    /// 표의 날짜 칸을 기준으로 줄을 나눈다. 날짜 앞 칸이 버전, 뒤 칸이 내용이다.
    public static func changelog(in node: FigmaNode, page: Page) -> [ChangelogEntry] {
        let pageName = stripNote(page.name)
        let texts = node.visibleTexts().compactMap(\.text).filter { $0 != "Change type" && !$0.hasPrefix("©") }
        var entries: [ChangelogEntry] = []
        for (index, text) in texts.enumerated() where isDate(text) {
            let before = texts[max(0, index - 2)..<index]
            let version = before.last { $0.range(of: "^\\d+(\\.\\d+)+$", options: .regularExpression) != nil }
            let next = index + 1 < texts.count ? texts[index + 1] : ""
            let body = isDate(next) || next.range(of: "^\\d+(\\.\\d+)*$", options: .regularExpression) != nil ? "" : next
            let order = entries.filter { $0.version == version && $0.date == text }.count
            entries.append(ChangelogEntry(pageID: page.id, pageName: pageName, version: version, date: text, order: order,
                                          text: body, frameID: node.id))
        }
        return entries
    }

    private static func isDate(_ text: String) -> Bool {
        text.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil
    }
}
