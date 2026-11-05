import Foundation

/// 일지 화면의 경로 트리: `데이터 탐색 > SQL 편집기 > 할 일`의 앞 경로를 마디마다 나눠 디자인 메뉴 트리처럼 묶는다.
/// 줄이 둘 이상 모인 마디만 묶음 머리가 되고, 혼자인 줄은 위 묶음 안에 둔다 (화면이 경로를 옅게 붙여 보인다).
/// 아래가 하나뿐인 마디는 `데이터 탐색 > SQL 편집기`처럼 한 머리로 합친다. 묶음과 줄은 처음 나온 자리를 지킨다.
public enum WorkPathTree {
    public enum Item {
        /// 묶음 머리. `path`는 전체 경로, `title`은 위 묶음을 뺀 이름, `count`는 아래 줄 수.
        case heading(path: String, title: String, depth: Int, count: Int)
        /// 줄. `path`는 줄이 든 가장 가까운 묶음의 전체 경로 (묶음 밖이면 nil).
        case row(WorkEntry, path: String?, depth: Int)
    }

    /// - Parameters:
    ///   - placement: 줄을 둘 경로 (`A > B`). nil이면 경로 없는 줄.
    ///   - keeps: 혼자 남아도 묶음을 지킬 줄. 고치는 동안 묶음이 풀려 글 칸이 바뀌지 않게 한다.
    ///   - isFolded: 접은 묶음의 전체 경로. 접은 묶음은 머리만 남긴다.
    public static func items(_ entries: [WorkEntry], placement: (WorkEntry) -> String?,
                             keeps: (WorkEntry) -> Bool = { _ in false },
                             isFolded: (String) -> Bool = { _ in false }) -> [Item] {
        let root = Node(name: "", path: "")
        for entry in entries {
            let kept = keeps(entry)
            var node = root
            for name in segments(placement(entry)) {
                node = node.child(name)
                node.count += 1
                if kept { node.kept = true }
            }
            node.children.append(.entry(entry))
        }
        var items: [Item] = []
        flatten(root, depth: 0, path: nil, isFolded: isFolded, into: &items)
        return items
    }

    private static func segments(_ path: String?) -> [String] {
        (path ?? "").components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func flatten(_ node: Node, depth: Int, path: String?, isFolded: (String) -> Bool, into items: inout [Item]) {
        for child in node.children {
            switch child {
            case .entry(let entry):
                items.append(.row(entry, path: path, depth: depth))
            case .node(let first):
                // 혼자인 줄은 묶음을 만들지 않고 이 묶음 안에 둔다
                guard first.count > 1 || first.kept else {
                    if let entry = first.firstEntry { items.append(.row(entry, path: path, depth: depth)) }
                    continue
                }
                var group = first
                var title = [group.name]
                while group.children.count == 1, case .node(let only) = group.children[0] {
                    group = only
                    title.append(only.name)
                }
                items.append(.heading(path: group.path, title: title.joined(separator: " > "), depth: depth, count: group.count))
                if !isFolded(group.path) {
                    flatten(group, depth: depth + 1, path: group.path, isFolded: isFolded, into: &items)
                }
            }
        }
    }

    private final class Node {
        enum Child {
            case entry(WorkEntry)
            case node(Node)
        }

        let name: String
        let path: String
        /// 줄과 아래 마디를 처음 나온 차례대로.
        var children: [Child] = []
        /// 이 마디 아래 줄 수.
        var count = 0
        /// 아래에 혼자여도 묶음을 지킬 줄이 있는지.
        var kept = false
        private var index: [String: Node] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func child(_ name: String) -> Node {
            if let found = index[name] { return found }
            let made = Node(name: name, path: path.isEmpty ? name : path + " > " + name)
            index[name] = made
            children.append(.node(made))
            return made
        }

        var firstEntry: WorkEntry? {
            for child in children {
                switch child {
                case .entry(let entry): return entry
                case .node(let node): if let entry = node.firstEntry { return entry }
                }
            }
            return nil
        }
    }
}
