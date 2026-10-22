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

    public init(frameID: String, candidateID: String? = nil, frameName: String = "", screenID: String, title: String = "",
                menuPath: String = "", requirementID: String = "", author: String = "", pageID: String = "",
                pageName: String = "", sectionName: String = "", notes: String = "", items: [SpecItem] = [],
                texts: [String: String] = [:], components: [String: SpecComponent] = [:]) {
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
        for child in screen.children where child.visible && child.id != headerRow?.id && child.id != panel?.id {
            readMockup(child, texts: &mockTexts, components: &components)
        }

        let screenID = header[screenIDLabel].flatMap { $0.isEmpty ? nil : $0 } ?? screen.name
        let path = header["화면 경로"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (sectionName.isEmpty ? nil : stripStatus(sectionName))
            ?? stripNote(page.name)
        return ScreenSnapshot(frameID: screen.id, frameName: screen.name, screenID: screenID, title: header["화면명"] ?? "",
                              menuPath: path, requirementID: header["요구사항 ID"] ?? "", author: header["작성자"] ?? "",
                              pageID: page.id, pageName: page.name, sectionName: sectionName, notes: notes, items: items,
                              texts: mockTexts, components: components)
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

    private static func readMockup(_ node: FigmaNode, texts: inout [String: String], components: inout [String: SpecComponent]) {
        guard node.visible, !markerNames.contains(node.name) else { return }
        if let text = node.text {
            if !text.isEmpty, !text.hasPrefix("©"), !placeholders.contains(text) { texts[node.id] = text }
            return
        }
        if node.type == "INSTANCE", let component = node.componentId {
            components[node.id] = SpecComponent(name: node.name, componentID: component)
        } else if let image = node.imageRef {
            components[node.id] = SpecComponent(name: node.name, componentID: SpecComponent.imagePrefix + image)
        }
        for child in node.children { readMockup(child, texts: &texts, components: &components) }
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
