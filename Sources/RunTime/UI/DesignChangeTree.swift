import SwiftUI
import DesignSyncCore

/// 목업 문구·컴포넌트 변경을 화면의 레이어 구조대로 묶는다. 마크업할 때 바뀐 곳을 영역별로 찾아가게 한다.
/// 번호는 위에서 아래로 매겨, 화면 비교 이미지에 찍는 번호와 같다.
enum DesignChangeTree {
    struct Item: Identifiable {
        let number: Int
        let change: SpecChange
        var id: Int { number }
    }

    struct Node: Identifiable {
        var id: String
        var name: String
        var children: [Node] = []
        var items: [Item] = []
        var count: Int { items.count + children.reduce(0) { $0 + $1.count } }
    }

    struct Row: Identifiable {
        enum Kind { case group(Node), item(Item) }
        let kind: Kind
        let depth: Int
        var id: String {
            switch kind {
            case .group(let node): return "g:" + node.id
            case .item(let item): return "i:\(item.number)"
            }
        }
    }

    static let unknownGroup = "위치를 모르는 변경"

    /// 트리로 묶을 변경. 자리가 하나도 없으면(이 기능 전 기록) nil이라 예전처럼 종류별로 보인다.
    static func mockupChanges(_ event: DesignEvent) -> [SpecChange]? {
        let changes = event.changes.filter { ($0.layer == .text || $0.layer == .component) && $0.op != .renumbered }
        return changes.contains { $0.place != nil } ? changes : nil
    }

    /// 뿌리 노드. 번호는 펼친 순서(위 → 아래)로 매긴다.
    static func build(_ changes: [SpecChange]) -> Node {
        var root = Node(id: "", name: "")
        var unknown: [SpecChange] = []
        for change in changes {
            guard let place = change.place else { unknown.append(change); continue }
            insert(change, containers: Array(place.path.dropLast()), into: &root, prefix: "")
        }
        root = sorted(compact(root))
        if !unknown.isEmpty {
            var group = Node(id: "?", name: unknownGroup)
            group.items = unknown.map { Item(number: 0, change: $0) }
            root.children.append(group)
        }
        var next = 1
        number(&root, next: &next)
        return root
    }

    private static func insert(_ change: SpecChange, containers: [String], into node: inout Node, prefix: String) {
        guard let head = containers.first else {
            node.items.append(Item(number: 0, change: change))
            return
        }
        let id = prefix + "/" + head
        if let index = node.children.firstIndex(where: { $0.id == id }) {
            insert(change, containers: Array(containers.dropFirst()), into: &node.children[index], prefix: id)
        } else {
            var child = Node(id: id, name: head)
            insert(change, containers: Array(containers.dropFirst()), into: &child, prefix: id)
            node.children.append(child)
        }
    }

    /// 변경이 없고 자식이 하나뿐인 층은 `검색 영역 › 버튼 묶음`처럼 한 줄로 합친다.
    private static func compact(_ node: Node) -> Node {
        var node = node
        node.children = node.children.map(compact)
        for index in node.children.indices {
            var child = node.children[index]
            while child.items.isEmpty, child.children.count == 1 {
                let only = child.children[0]
                child = Node(id: only.id, name: child.name + " › " + only.name, children: only.children, items: only.items)
            }
            node.children[index] = child
        }
        return node
    }

    /// 화면에서 위에 있는 것부터, 같은 줄이면 왼쪽부터.
    private static func sorted(_ node: Node) -> Node {
        var node = node
        node.items.sort { order($0.change.place) < order($1.change.place) }
        node.children = node.children.map(sorted).sorted { top($0) < top($1) }
        return node
    }

    private static func order(_ place: SpecPlace?) -> Spot {
        guard let place, place.hasBox else { return Spot(row: 100, x: 2) }
        // 몇 픽셀 차이로 같은 줄이 갈리지 않게 줄을 조금 굵게 본다
        return Spot(row: (place.y * 50).rounded(), x: place.x)
    }

    private static func top(_ node: Node) -> Spot {
        (node.items.map { order($0.change.place) } + node.children.map(top)).min() ?? Spot(row: 100, x: 2)
    }

    private struct Spot: Comparable {
        let row: Double
        let x: Double
        static func < (a: Spot, b: Spot) -> Bool { (a.row, a.x) < (b.row, b.x) }
    }

    private static func number(_ node: inout Node, next: inout Int) {
        node.items = node.items.map { item in
            defer { next += 1 }
            return Item(number: next, change: item.change)
        }
        for index in node.children.indices { number(&node.children[index], next: &next) }
    }

    static func items(_ node: Node) -> [Item] {
        node.items + node.children.flatMap(items)
    }

    static func rows(_ node: Node, depth: Int = 0, folded: Set<String>) -> [Row] {
        var rows = node.items.map { Row(kind: .item($0), depth: depth) }
        for child in node.children {
            rows.append(Row(kind: .group(child), depth: depth))
            if !folded.contains(child.id) { rows += self.rows(child, depth: depth + 1, folded: folded) }
        }
        return rows
    }

    static func color(_ op: SpecChange.Op) -> Color {
        switch op {
        case .added: return WL.done
        case .removed: return WL.waiting
        case .modified, .renumbered: return WL.accent
        }
    }

    /// 이 쪽(이전·이후) 이미지에 표시할 변경. 지운 것은 이전에만, 더한 것은 이후에만 있다.
    static func shows(_ change: SpecChange, before: Bool) -> Bool {
        switch change.op {
        case .removed: return before
        case .added: return !before
        case .modified, .renumbered: return true
        }
    }
}

/// 목업 변경 트리. 줄을 누르면 화면 비교 이미지에서 그 자리를 강조하고, 동그라미로 반영했는지 체크한다.
struct DesignChangeTreeView: View {
    let root: DesignChangeTree.Node
    let fileKey: String
    @ObservedObject var page: DesignHistoryPage
    let checked: Set<String>
    let toggle: (SpecChange) -> Void
    /// 기록에 없는 변경(날짜 비교 결과)은 반영 체크를 두지 않는다.
    var checkable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionLabel("목업 변경 · 레이어별", trailing: "\(root.count)")
                let groups = allGroups(root)
                if !groups.isEmpty {
                    Button(page.foldedChangeGroups.isEmpty ? "모두 접기" : "모두 펼치기") {
                        page.foldedChangeGroups = page.foldedChangeGroups.isEmpty ? Set(groups) : []
                    }
                    .buttonStyle(TextLinkButtonStyle())
                    .font(WL.label)
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                let rows = DesignChangeTree.rows(root, folded: page.foldedChangeGroups)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { RowDivider(inset: 0) }
                    switch row.kind {
                    case .group(let node): groupRow(node, depth: row.depth)
                    case .item(let item): itemRow(item, depth: row.depth)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wlSurface()
            Text("번호는 화면 비교의 표시와 같습니다. 줄을 누르면 화면에서 그 자리를 강조하고, 동그라미로 반영한 것을 체크합니다.")
                .font(WL.caption).foregroundStyle(WL.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func allGroups(_ node: DesignChangeTree.Node) -> [String] {
        node.children.flatMap { [$0.id] + allGroups($0) }
    }

    private func groupRow(_ node: DesignChangeTree.Node, depth: Int) -> some View {
        let isFolded = page.foldedChangeGroups.contains(node.id)
        let done = DesignChangeTree.items(node).filter { checked.contains($0.change.key) }.count
        return Button {
            if isFolded { page.foldedChangeGroups.remove(node.id) } else { page.foldedChangeGroups.insert(node.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(isFolded ? 0 : 90)).foregroundStyle(WL.faint).frame(width: 12)
                Image(systemName: node.name == DesignChangeTree.unknownGroup ? "questionmark.square.dashed" : "square.on.square.dashed")
                    .font(.system(size: 11)).foregroundStyle(WL.muted)
                Text(node.name).font(WL.heading).foregroundStyle(WL.text).lineLimit(1).truncationMode(.middle)
                    .tip(node.name)
                Spacer(minLength: 6)
                Text(done > 0 ? "\(done)/\(node.count)" : "\(node.count)").font(WL.number)
                    .foregroundStyle(done == node.count ? WL.done : WL.faint)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func itemRow(_ item: DesignChangeTree.Item, depth: Int) -> some View {
        let change = item.change
        let isSelected = page.selectedChange == item.number
        let isHovered = page.hoveredChange == item.number
        let isChecked = checked.contains(change.key)
        return HStack(alignment: .top, spacing: 8) {
            if checkable { AppliedCheck(on: isChecked) { toggle(change) }.padding(.top, 12) }
            ChangeNumber(number: item.number, op: change.op, filled: isSelected, located: change.place?.hasBox == true)
                .padding(.top, 12.5)
            DesignChangeRow(change: change).opacity(isChecked ? 0.45 : 1)
            Spacer(minLength: 0)
            actions(change).padding(.top, 10).opacity(isHovered || isSelected ? 1 : 0)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
            .fill(isSelected ? WL.selected : isHovered ? WL.hover : .clear))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture { page.selectedChange = isSelected ? nil : item.number }
        .onHover { inside in
            if inside { page.hoveredChange = item.number } else if page.hoveredChange == item.number { page.hoveredChange = nil }
        }
    }

    private func actions(_ change: SpecChange) -> some View {
        HStack(spacing: 2) {
            // 지운 요소는 지금 파일에 없어 피그마에서 열 수 없다
            if change.op != .removed, let node = change.nodeID, let url = FigmaFileURL.link(fileKey: fileKey, nodeID: node) {
                Button { NSWorkspace.shared.open(url) } label: { FigmaMark(height: 11).frame(width: 22, height: 22) }
                    .buttonStyle(.plain)
                    .tip("피그마에서 이 요소 열기")
            }
            if change.layer == .text, let text = change.op == .removed ? change.before : change.after {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    page.flash(change.op == .removed ? "지운 문구를 복사했습니다" : "바뀐 문구를 복사했습니다")
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(WL.muted).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .tip(change.op == .removed ? "지운 문구 복사" : "마크업에 넣을 문구 복사")
            }
        }
    }
}

/// 변경 번호 동그라미. 화면 이미지의 표시와 트리 줄이 같은 모양을 쓴다.
struct ChangeNumber: View {
    let number: Int
    let op: SpecChange.Op
    var filled = false
    /// 화면 위 자리를 모르면 점선으로 그려 이미지에 표시가 없다는 것을 보인다.
    var located = true

    var body: some View {
        let color = DesignChangeTree.color(op)
        Text("\(number)")
            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .background(Capsule().fill(filled ? color : color.opacity(0.13)))
            .overlay(Capsule().strokeBorder(color.opacity(located ? 0 : 0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
    }
}

/// 화면 비교 이미지 위에 바뀐 자리와 번호를 그린다. 이미지에 딱 맞게 겹친다.
struct ChangeMarks: View {
    let items: [DesignChangeTree.Item]
    let before: Bool
    @Binding var selected: Int?

    var body: some View {
        GeometryReader { geo in
            let shown = items.filter { DesignChangeTree.shows($0.change, before: before) && $0.change.place?.hasBox == true }
            ZStack(alignment: .topLeading) {
                ForEach(shown) { item in
                    if let place = item.change.place {
                        mark(item, place: place, size: geo.size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func mark(_ item: DesignChangeTree.Item, place: SpecPlace, size: CGSize) -> some View {
        let color = DesignChangeTree.color(item.change.op)
        let isSelected = selected == item.number
        let dimmed = selected != nil && !isSelected
        let rect = CGRect(x: place.x * size.width, y: place.y * size.height,
                          width: max(place.width * size.width, 4), height: max(place.height * size.height, 4))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(isSelected ? 0.18 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(color, lineWidth: isSelected ? 2 : 1))
                .frame(width: rect.width, height: rect.height)
            ChangeNumber(number: item.number, op: item.change.op, filled: true)
                .offset(x: -6, y: -9)
                .scaleEffect(isSelected ? 1.25 : 1)
        }
        .opacity(dimmed ? 0.25 : 1)
        .offset(x: rect.minX, y: rect.minY)
        .onTapGesture { selected = isSelected ? nil : item.number }
        .tip("\(item.number). \(item.change.label)")
    }
}
