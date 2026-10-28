import Foundation

/// /etc/hosts를 줄 단위로 읽은 것. 손대지 않은 줄은 읽은 글자 그대로 다시 쓴다.
public struct HostsFile: Equatable {
    public struct Record: Equatable {
        public var ip: String
        public var names: [String]
        /// `#`으로 꺼 둔 줄이면 false.
        public var enabled: Bool
        public var note: String?

        public init(ip: String, names: [String], enabled: Bool = true, note: String? = nil) {
            self.ip = ip
            self.names = names
            self.enabled = enabled
            self.note = note
        }

        public var text: String {
            (enabled ? "" : "#") + ip + "\t" + names.joined(separator: " ") + Self.memo(note)
        }

        /// 줄 끝에 붙일 ` # 메모`. 메모에 줄바꿈이 섞이면 hosts에 줄이 끼어들어 한 줄로 편다.
        static func memo(_ note: String?) -> String {
            let text = note?.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces) ?? ""
            return text.isEmpty ? "" : " # " + text
        }
    }

    public enum Kind: Equatable {
        case blank
        case comment(String)
        case entry(Record)
        /// 주소로 읽을 수 없는 줄 (`- End ##`, `192.168.1.300 a`).
        case invalid
    }

    public struct Line: Equatable {
        public var raw: String
        public var kind: Kind

        public init(_ raw: String) {
            self.raw = raw
            kind = HostsFile.parse(raw)
        }

        init(record: Record) {
            raw = record.text
            kind = .entry(record)
        }

        public var record: Record? {
            if case .entry(let record) = kind { return record }
            return nil
        }
    }

    public var lines: [Line]
    /// 마지막 줄 끝에 줄바꿈이 있었는지. 읽은 그대로 쓰려고 기억한다.
    public var endsWithNewline: Bool

    public init(_ text: String) {
        endsWithNewline = text.hasSuffix("\n") || text.isEmpty
        var parts = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { parts.removeLast() }
        lines = text.isEmpty ? [] : parts.map(Line.init)
    }

    public var text: String {
        let body = lines.map(\.raw).joined(separator: "\n")
        return endsWithNewline && !lines.isEmpty ? body + "\n" : body
    }

    // MARK: 읽기

    static func parse(_ raw: String) -> Kind {
        // 윈도우에서 고친 파일은 줄 끝에 \r이 붙는다
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .blank }
        if trimmed.hasPrefix("#") {
            let body = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            // 주석으로 꺼 둔 줄. 설명 글(`# 10.0.0.1 is the gateway`)을 줄로 잘못 읽지 않게, 이름이 여럿이면 점이 있어야 한다
            if let record = record(body, enabled: false),
               record.names.count == 1 || record.names.contains(where: { $0.contains(".") || $0 == "localhost" }) {
                return .entry(record)
            }
            return .comment(body)
        }
        return record(trimmed, enabled: true).map(Kind.entry) ?? .invalid
    }

    private static func record(_ text: String, enabled: Bool) -> Record? {
        var body = text
        var note: String?
        if let hash = body.firstIndex(of: "#") {
            let rest = body[body.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            note = rest.isEmpty ? nil : rest
            body = String(body[..<hash])
        }
        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2, isIP(tokens[0]), tokens.dropFirst().allSatisfy(isHostname) else { return nil }
        return Record(ip: tokens[0], names: Array(tokens.dropFirst()), enabled: enabled, note: note)
    }

    public static func isIP(_ text: String) -> Bool { isIPv4(text) || isIPv6(text) }

    public static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && Int(part)! <= 255
        }
    }

    public static func isIPv6(_ text: String) -> Bool {
        guard text.contains(":") else { return false }
        var address = in6_addr()
        // `fe80::1%lo0`처럼 영역을 붙인 주소도 hosts에 쓴다
        let bare = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        return inet_pton(AF_INET6, bare, &address) == 1
    }

    /// 끝에 점을 붙인 완전한 이름(`a.example.com.`)도 받는다.
    public static func isHostname(_ text: String) -> Bool {
        let name = text.hasSuffix(".") ? String(text.dropLast()) : text
        guard !name.isEmpty, name.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    // MARK: 머리말과 묶음

    /// 맨 위 시스템 머리말(설명 주석, localhost, broadcasthost)이 끝나는 줄 번호. 이 줄들은 보이지도 고치지도 않는다.
    public var headerEnd: Int {
        var end = 0
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .blank, .comment: continue
            case .entry(let record) where record.names.allSatisfy(Self.systemNames.contains): end = index + 1
            default: return end
            }
        }
        return end
    }

    static let systemNames: Set<String> = ["localhost", "broadcasthost"]

    /// 머리말 뒤 줄마다 어느 묶음에 들고 무슨 구실인지.
    enum Role: Equatable { case blank, title, note, marker, entry, invalid }

    struct Place {
        let line: Int
        let role: Role
        /// 이 줄이 든 묶음 제목. nil이면 머리 없이 있는 줄.
        let title: String?
        /// 이 줄이 든 묶음이 시작한 줄.
        let start: Int
    }

    /// 주석 머리 바로 다음 `#` 주석은 그 묶음의 설명으로 본다(`## Dev` 다음 `# VPN 필요`). `##` 주석은 늘 새 묶음 머리다
    /// (항목을 다 지운 묶음 머리 바로 아래 다음 묶음 머리가 와도 합쳐지지 않게).
    /// 항목이 나온 뒤의 주석은 새 묶음 머리다. 끝 표시(`- End ##`)는 묶음을 닫는다.
    var places: [Place] {
        var result: [Place] = []
        var title: String?
        var start = headerEnd
        var titled = false
        var hasItems = false
        for index in headerEnd..<lines.count {
            let line = lines[index]
            var role = Role.blank
            switch line.kind {
            case .blank: role = .blank
            case .comment(let text):
                if Self.isEndMarker(text) {
                    role = .marker
                } else if titled && !hasItems && !line.raw.trimmingCharacters(in: .whitespaces).hasPrefix("##") {
                    role = .note
                } else {
                    role = .title
                    title = Self.title(text)
                    start = index
                    titled = true
                    hasItems = false
                }
            case .invalid: role = Self.isEndMarker(line.raw) ? .marker : .invalid
            case .entry:
                role = .entry
                hasItems = true
            }
            if role == .marker {
                title = nil
                start = index
                titled = false
                hasItems = false
            }
            result.append(Place(line: index, role: role, title: title, start: start))
        }
        return result
    }

    /// 이름 하나가 한 항목이다. 한 줄에 이름이 여럿이면 이름마다 따로 켜고 끈다.
    public struct Item: Identifiable, Equatable {
        public var id: String { "\(line)-\(slot)" }
        public let line: Int
        public let slot: Int
        public let ip: String
        public let name: String
        public let enabled: Bool
        public let note: String?
    }

    public struct Section: Identifiable, Equatable {
        public var id: String { "\(start)-\(title ?? "")" }
        /// 묶음 머리 주석. nil이면 머리 없이 있는 줄들.
        public let title: String?
        /// 머리 줄(없으면 그 앞 끝 표시나 머리말 끝) 번호.
        public let start: Int
        public var items: [Item]
    }

    /// 항목이 없는 묶음은 뺀다.
    public var sections: [Section] {
        var result: [Section] = []
        for place in places where place.role == .entry {
            guard let record = lines[place.line].record else { continue }
            if result.last?.start != place.start || result.last?.title != place.title {
                result.append(Section(title: place.title, start: place.start, items: []))
            }
            for (slot, name) in record.names.enumerated() {
                result[result.count - 1].items.append(Item(line: place.line, slot: slot, ip: record.ip, name: name,
                                                           enabled: record.enabled, note: record.note))
            }
        }
        return result
    }

    public var items: [Item] { sections.flatMap(\.items) }

    /// `## Local - Start ##` → `Local`.
    static func title(_ comment: String) -> String {
        var text = comment.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\r"))
        if let range = text.range(of: #"\s+-\s*start$"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return text.isEmpty ? comment : text
    }

    /// 묶음을 닫는 줄: `## Local - End ##`, `- End ##`, `# End`. `Back-end`, `Front end` 같은 제목은 아니다.
    static func isEndMarker(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\r"))
        return body.range(of: #"^((.*\s)?-\s*)?end$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: 고치기

    /// 항목이 아직 그 자리에 있는지 보고, 줄이 밀렸으면 같은 주소·이름을 다시 찾는다.
    /// 고치기 창을 연 동안 다른 곳에서 파일이 바뀌어도 엉뚱한 줄을 고치지 않게.
    public func locate(_ item: Item) -> Item? {
        if item.line < lines.count, let record = lines[item.line].record, record.ip == item.ip,
           let slot = record.names.firstIndex(of: item.name) {
            return Item(line: item.line, slot: slot, ip: record.ip, name: item.name, enabled: record.enabled, note: record.note)
        }
        return items.first { $0.ip == item.ip && $0.name == item.name }
    }

    /// 한 항목을 켜거나 끈다. 이름이 여럿인 줄이면 그 이름만 바로 아래 줄로 떼어 낸다.
    public mutating func setEnabled(_ item: Item, _ enabled: Bool) {
        guard let item = locate(item), var record = lines[item.line].record, record.enabled != enabled else { return }
        if record.names.count == 1 { return setLine(item.line, enabled) }
        record.names.remove(at: item.slot)
        lines[item.line] = Line(record: record)
        lines.insert(Line(record: Record(ip: item.ip, names: [item.name], enabled: enabled, note: item.note)), at: item.line + 1)
    }

    /// 여러 항목을 한 번에. 한 줄의 이름이 다 들었으면 그 줄을 통째로 바꾸고, 줄 번호가 밀리지 않게 아래 줄부터 고친다.
    public mutating func setEnabled(_ items: [Item], _ enabled: Bool) {
        let located = items.compactMap(locate)
        let byLine = Dictionary(grouping: located, by: \.line)
        for line in byLine.keys.sorted(by: >) {
            guard let record = lines[line].record else { continue }
            let names = Set(byLine[line]!.map(\.name))
            if record.names.allSatisfy(names.contains) {
                if record.enabled != enabled { setLine(line, enabled) }
            } else {
                for item in byLine[line]!.sorted(by: { $0.slot > $1.slot }) {
                    if let current = locate(item) { setEnabled(current, enabled) }
                }
            }
        }
    }

    /// 앞에 `#`을 붙이거나 떼기만 해 손으로 맞춘 칸 맞춤을 살린다.
    private mutating func setLine(_ index: Int, _ enabled: Bool) {
        guard var record = lines[index].record, record.enabled != enabled else { return }
        record.enabled = enabled
        let raw = lines[index].raw
        lines[index].raw = enabled ? String(raw.drop { $0 == "#" || $0 == " " || $0 == "\t" }) : "#" + raw
        lines[index].kind = .entry(record)
    }

    public mutating func remove(_ item: Item) {
        guard let item = locate(item), var record = lines[item.line].record else { return }
        record.names.remove(at: item.slot)
        if record.names.isEmpty { lines.remove(at: item.line) } else { lines[item.line] = Line(record: record) }
    }

    /// 주소·이름·메모를 바꾼다. 이름이 여럿인 줄이면 그 이름만 떼어 바꾼다.
    public mutating func update(_ item: Item, ip: String, name: String, note: String?) {
        guard let item = locate(item), var record = lines[item.line].record else { return }
        let changed = Record(ip: ip, names: [name], enabled: item.enabled, note: note)
        if record.names.count == 1 {
            lines[item.line] = Line(record: changed)
        } else {
            record.names.remove(at: item.slot)
            lines[item.line] = Line(record: record)
            lines.insert(Line(record: changed), at: item.line + 1)
        }
    }

    /// 그 이름의 묶음 끝에 넣는다. 묶음이 없으면 파일 끝에 머리를 달아 새로 만든다.
    public mutating func add(_ records: [Record], to group: String?) {
        guard !records.isEmpty else { return }
        let added = records.map(Line.init(record:))
        let name = group?.trimmingCharacters(in: .whitespaces) ?? ""
        if let section = sections.last(where: { name.isEmpty ? $0.title == nil : $0.title == name }),
           let last = section.items.map(\.line).max() {
            lines.insert(contentsOf: added, at: last + 1)
            return
        }
        while lines.last?.kind == .blank { lines.removeLast() }
        if !lines.isEmpty { lines.append(Line("")) }
        if !name.isEmpty { lines.append(Line("## " + name)) }
        lines.append(contentsOf: added)
        endsWithNewline = true
    }

    /// 붙여 넣은 글에서 줄을 읽는다. 주소로 시작하지 않는 줄은 `skipped`로 돌려준다.
    public static func records(fromPasted text: String) -> (records: [Record], skipped: [String]) {
        var records: [Record] = []
        var skipped: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            switch parse(raw) {
            case .blank, .comment: continue
            case .entry(let record): records.append(record)
            case .invalid:
                // 메신저로 받은 `api.example.com 10.0.0.1`처럼 이름을 먼저 쓴 줄도 받는다
                if let record = reversedRecord(raw) { records.append(record) } else { skipped.append(raw.trimmingCharacters(in: .whitespaces)) }
            }
        }
        return (records, skipped)
    }

    private static func reversedRecord(_ raw: String) -> Record? {
        let body = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let tokens = body[0].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2, let ip = tokens.last, isIP(ip) else { return nil }
        let reordered = ([ip] + tokens.dropLast()).joined(separator: " ") + (body.count > 1 ? " #" + body[1] : "")
        return record(reordered, enabled: true)
    }
}
