import Foundation

/// 화면 하나에서 바뀐 것 하나.
public struct SpecChange: Codable, Equatable, Hashable, Sendable {
    public enum Layer: String, Codable, Sendable, CaseIterable {
        /// 화면명, 화면 경로 같은 헤더 값과 섹션 상태
        case header
        /// Description 기능 명세
        case spec
        /// 목업 문구
        case text
        /// 목업 컴포넌트
        case component
    }

    public enum Op: String, Codable, Sendable {
        case added, removed, modified
        /// 내용은 같고 번호만 바뀐 명세 항목
        case renumbered
    }

    public var layer: Layer
    public var op: Op
    public var label: String
    public var before: String?
    public var after: String?

    public init(layer: Layer, op: Op, label: String, before: String? = nil, after: String? = nil) {
        self.layer = layer
        self.op = op
        self.label = label
        self.before = before
        self.after = after
    }
}

public enum SpecDiff {
    /// 같은 항목으로 볼 최소 유사도. 문장 절반이 바뀌어도 같은 항목의 수정으로 본다.
    static let sameItemSimilarity = 0.45

    public static func changes(from old: ScreenSnapshot, to new: ScreenSnapshot) -> [SpecChange] {
        header(old, new) + spec(old.items, new.items) + texts(old.texts, new.texts) + components(old.components, new.components)
    }

    // MARK: 헤더

    private static func header(_ old: ScreenSnapshot, _ new: ScreenSnapshot) -> [SpecChange] {
        let fields: [(String, KeyPath<ScreenSnapshot, String>)] = [
            ("화면 ID", \.screenID), ("화면명", \.title), ("화면 경로", \.menuPath), ("요구사항 ID", \.requirementID),
            ("작성자", \.author), ("섹션", \.sectionName), ("참고", \.notes),
        ]
        return fields.compactMap { label, path in
            old[keyPath: path] == new[keyPath: path] ? nil
                : SpecChange(layer: .header, op: .modified, label: label, before: old[keyPath: path], after: new[keyPath: path])
        }
    }

    // MARK: 기능 명세

    /// 항목을 내용으로 짝지은 뒤 번호를 본다. 앞에 항목 하나가 끼면 뒤 번호가 다 밀려서, 번호로 맞추면 전부 바뀐 것처럼 보인다.
    static func spec(_ old: [SpecItem], _ new: [SpecItem]) -> [SpecChange] {
        var oldLeft = Set(old.indices)
        var newLeft = Set(new.indices)
        var pairs: [(Int, Int)] = []
        func pair(_ o: Int, _ n: Int) {
            pairs.append((o, n))
            oldLeft.remove(o)
            newLeft.remove(n)
        }
        // 1. 내용이 같은 것
        for n in new.indices {
            if let o = old.indices.first(where: { oldLeft.contains($0) && old[$0].text == new[n].text }) { pair(o, n) }
        }
        // 2. 번호가 같고 내용이 비슷한 것
        for n in new.indices where newLeft.contains(n) {
            if let o = old.indices.first(where: { oldLeft.contains($0) && old[$0].number == new[n].number
                && matchScore(old[$0].text, new[n].text, containment: 1) >= sameItemSimilarity }) { pair(o, n) }
        }
        // 3. 번호와 상관없이 가장 비슷한 것부터. 번호가 다르면 `검색` ⊂ `검색 결과 없음 안내`처럼 짧은 말이 우연히 들어 있을 수 있어
        //    포함은 짧은 쪽이 여섯 글자 넘을 때만 친다
        let candidates = oldLeft.flatMap { o in newLeft.map { n in (o, n, matchScore(old[o].text, new[n].text, containment: 6)) } }
            .filter { $0.2 >= sameItemSimilarity }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : ($0.1, $0.0) < ($1.1, $1.0) }
        for (o, n, _) in candidates where oldLeft.contains(o) && newLeft.contains(n) { pair(o, n) }

        var changes: [SpecChange] = []
        let matched = Dictionary(pairs.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })
        for n in new.indices {
            if let o = matched[n] {
                if old[o].text != new[n].text {
                    changes.append(SpecChange(layer: .spec, op: .modified, label: new[n].label, before: old[o].text, after: new[n].text))
                } else if old[o].number != new[n].number {
                    changes.append(SpecChange(layer: .spec, op: .renumbered, label: new[n].label,
                                              before: old[o].number, after: new[n].number))
                }
            } else {
                changes.append(SpecChange(layer: .spec, op: .added, label: new[n].label, after: new[n].text))
            }
        }
        for o in old.indices where oldLeft.contains(o) {
            changes.append(SpecChange(layer: .spec, op: .removed, label: old[o].label, before: old[o].text))
        }
        return changes
    }

    /// 짧은 항목 뒤에 조건을 덧붙이는 수정(`검색` → `검색 (Enter 키 포함)`)은 유사도가 낮게 나와서, 한쪽이 다른 쪽을 품으면 같은 항목으로 본다.
    static func matchScore(_ a: String, _ b: String, containment minimum: Int) -> Double {
        let left = a.filter { !$0.isWhitespace }
        let right = b.filter { !$0.isWhitespace }
        let (short, long) = left.count <= right.count ? (left, right) : (right, left)
        if short.count >= max(2, minimum), long.contains(short) { return max(similarity(a, b), sameItemSimilarity + 0.1) }
        return similarity(a, b)
    }

    /// 글자 2-gram 다이스 계수. 띄어쓰기에 덜 흔들려서 한글 문장 비교에 맞다.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let left = bigrams(a)
        let right = bigrams(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for gram in left { counts[gram, default: 0] += 1 }
        var shared = 0
        for gram in right where counts[gram, default: 0] > 0 {
            counts[gram]! -= 1
            shared += 1
        }
        return Double(2 * shared) / Double(left.count + right.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let letters = Array(text.filter { !$0.isWhitespace })
        guard letters.count > 1 else { return letters.map(String.init) }
        return (0..<(letters.count - 1)).map { String(letters[$0...($0 + 1)]) }
    }

    // MARK: 목업

    /// 노드 ID로 맞춘다. 지우고 같은 글을 다시 만든 것(ID만 바뀐 것)은 바뀐 것으로 치지 않는다.
    static func texts(_ old: [String: String], _ new: [String: String]) -> [SpecChange] {
        var changes: [SpecChange] = []
        var removed: [String] = []
        var added: [String] = []
        for (id, text) in old.sorted(by: { $0.key < $1.key }) {
            if let now = new[id] {
                if now != text {
                    changes.append(SpecChange(layer: .text, op: .modified, label: DesignText.headline(now), before: text, after: now))
                }
            } else {
                removed.append(text)
            }
        }
        for (id, text) in new.sorted(by: { $0.key < $1.key }) where old[id] == nil { added.append(text) }
        var unmatched = removed
        for text in added {
            if let index = unmatched.firstIndex(of: text) {
                unmatched.remove(at: index)
            } else {
                changes.append(SpecChange(layer: .text, op: .added, label: DesignText.headline(text), after: text))
            }
        }
        var pending = added
        for text in removed {
            if let index = pending.firstIndex(of: text) {
                pending.remove(at: index)
            } else {
                changes.append(SpecChange(layer: .text, op: .removed, label: DesignText.headline(text), before: text))
            }
        }
        return changes
    }

    /// 교체는 하나씩, 추가·삭제는 표를 새로 짜면 수십 개가 한꺼번에 생겨서 이름별 개수로 묶는다.
    static func components(_ old: [String: SpecComponent], _ new: [String: SpecComponent]) -> [SpecChange] {
        var changes: [SpecChange] = []
        for (id, before) in old.sorted(by: { $0.key < $1.key }) {
            if let after = new[id], after.componentID != before.componentID {
                // 이름이 같으면 같은 컴포넌트의 다른 변형(상태·크기)으로 바꾼 것이다
                let label = after.isImage ? "이미지 교체" : after.name == before.name ? "\(after.name) 변형 교체" : "컴포넌트 교체"
                changes.append(SpecChange(layer: .component, op: .modified, label: label, before: before.name, after: after.name))
            }
        }
        let added = new.filter { old[$0.key] == nil }.map(\.value.name)
        let removed = old.filter { new[$0.key] == nil }.map(\.value.name)
        if let summary = tally(added, minus: removed) {
            changes.append(SpecChange(layer: .component, op: .added, label: "컴포넌트 추가", after: summary))
        }
        if let summary = tally(removed, minus: added) {
            changes.append(SpecChange(layer: .component, op: .removed, label: "컴포넌트 삭제", before: summary))
        }
        return changes
    }

    /// 다시 만든 같은 이름 인스턴스는 지우고 `button 3, input 1`처럼 센다.
    private static func tally(_ names: [String], minus other: [String]) -> String? {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        for name in other where counts[name, default: 0] > 0 { counts[name]! -= 1 }
        let parts = counts.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// 전·후 글을 낱말 단위로 맞대 바뀐 부분만 강조할 수 있게 나눈다.
public enum InlineDiff {
    public enum Kind: String, Sendable { case same, removed, added }

    public struct Segment: Equatable, Sendable {
        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public static func segments(before: String, after: String) -> [Segment] {
        let a = tokens(before)
        let b = tokens(after)
        // 아주 긴 글은 LCS 표가 커지니 통째로 바뀐 것으로 본다
        guard a.count * b.count <= 250_000 else {
            return [Segment(kind: .removed, text: before), Segment(kind: .added, text: after)]
        }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Segment] = []
        func push(_ kind: Kind, _ token: String) {
            if let last = result.indices.last, result[last].kind == kind {
                result[last].text += token
            } else {
                result.append(Segment(kind: kind, text: token))
            }
        }
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                push(.same, a[i]); i += 1; j += 1
            } else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] {
                // 같은 자리에서 빠진 말을 들어온 말보다 먼저 보여 준다
                push(.removed, a[i]); i += 1
            } else {
                push(.added, b[j]); j += 1
            }
        }
        return result
    }

    /// 낱말과 그 뒤 공백을 한 토큰으로. 이어 붙이면 원래 글이 된다.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            let space = character.isWhitespace
            if space != inSpace && !space && !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            current.append(character)
            inSpace = space
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
