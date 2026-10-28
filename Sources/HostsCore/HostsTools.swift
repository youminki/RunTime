import Foundation

extension HostsFile.Item {
    /// 메모의 `~2026-11-30`: 이날까지만 켜 둔다.
    public var expiry: String? {
        guard let note, let range = note.range(of: #"~[0-9]{4}-[0-9]{2}-[0-9]{2}"#, options: .regularExpression) else { return nil }
        let day = String(note[range].dropFirst())
        return HostsFile.isDay(day) ? day : nil
    }
}

extension HostsFile {
    /// 있는 날짜인지 (`2026-13-45`는 아니다).
    public static func isDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), parts[2] >= 1 else { return false }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        guard let date = Calendar(identifier: .gregorian).date(from: components),
              let days = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: date) else { return false }
        return days.contains(parts[2])
    }

    /// 메모에서 기한(`~yyyy-MM-dd`)을 바꾸거나 넣는다. `day`가 nil이면 뺀다.
    public static func note(_ note: String?, until day: String?) -> String? {
        var parts = (note ?? "").components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.range(of: #"^~[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) == nil }
        if let day { parts.append("~" + day) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 다른 판에서 같은 묶음을 찾는다. 줄 번호가 밀렸어도 제목과 이름들이 같으면 같은 묶음이다.
    /// 창을 연 뒤 파일이 바뀌어 다른 묶음의 같은 이름을 고치는 일을 막는다.
    public func section(matching old: Section) -> Section? {
        let names = old.items.map { $0.name.lowercased() }.sorted()
        func same(_ section: Section) -> Bool {
            section.title == old.title && section.items.map { $0.name.lowercased() }.sorted() == names
        }
        return sections.first { $0.id == old.id && same($0) } ?? sections.first(where: same)
    }

    /// 기한이 `day`(yyyy-MM-dd)보다 앞인데 아직 켜져 있는 항목.
    public func expired(on day: String) -> [Item] {
        items.filter { $0.enabled && ($0.expiry.map { $0 < day } ?? false) }
    }

    /// 묶음 안에서 `old` 주소를 쓰는 항목을 모두 `new`로 바꾼다 (개발 ↔ 스테이징 같은 환경 전환).
    /// 한 줄의 이름이 다 들었으면 그 줄의 주소 글자만 바꿔 칸 맞춤을 살린다.
    public mutating func replaceIP(in items: [Item], from old: String, to new: String) {
        let located = items.compactMap(locate).filter { $0.ip == old }
        let byLine = Dictionary(grouping: located, by: \.line)
        for line in byLine.keys.sorted(by: >) {
            guard var record = lines[line].record else { continue }
            let names = Set(byLine[line]!.map(\.name))
            if record.names.allSatisfy(names.contains), let range = lines[line].raw.range(of: old) {
                record.ip = new
                lines[line].raw.replaceSubrange(range, with: new)
                lines[line].kind = .entry(record)
            } else {
                for item in byLine[line]!.sorted(by: { $0.slot > $1.slot }) {
                    if let current = locate(item) { update(current, ip: new, name: current.name, note: current.note) }
                }
            }
        }
    }

    /// 추가하기 전에 이름마다 지금 파일과 견준 결과.
    public struct AddPlan {
        public enum Status: Equatable {
            case new
            /// 같은 주소·이름이 이미 켜져 있어 넣지 않는다.
            case exists
            /// 같은 주소·이름이 꺼진 채 있어 그 줄을 켠다.
            case reenable
            /// 같은 이름을 다른 주소로 켜 둔 줄이 있다.
            case conflict(String)
        }

        public struct Entry: Identifiable {
            public let id: Int
            public let ip: String
            public let name: String
            public let enabled: Bool
            public let status: Status
        }

        public var entries: [Entry] = []
        /// 새로 쓸 줄. 이미 있는 이름은 뺐다.
        public var records: [Record] = []
        public var reenable: [Item] = []
        /// 같은 이름을 다른 주소로 켜 둔 항목. 끄지 않으면 어느 쪽으로 풀릴지 모른다.
        public var conflicting: [Item] = []

        /// 파일이 바뀌는 이름 수.
        public var count: Int { entries.filter { $0.status != .exists }.count }
    }

    public func additionPlan(_ records: [Record]) -> AddPlan {
        let existing = items
        var plan = AddPlan()
        var seen = Set<String>()
        for record in records {
            var names: [String] = []
            for name in record.names {
                let key = name.lowercased()
                let same = existing.filter { $0.name.lowercased() == key && $0.ip == record.ip }
                // hosts는 IPv4와 IPv6를 따로 푸니 같은 종류끼리만 견준다
                let others = record.enabled ? existing.filter {
                    $0.enabled && $0.name.lowercased() == key && $0.ip != record.ip && $0.ip.contains(":") == record.ip.contains(":")
                } : []
                let status: AddPlan.Status
                if !seen.insert(record.ip + " " + key).inserted || same.contains(where: \.enabled) || (!same.isEmpty && !record.enabled) {
                    status = .exists
                } else if let off = same.first {
                    status = .reenable
                    plan.reenable.append(off)
                } else {
                    status = others.first.map { .conflict($0.ip) } ?? .new
                    names.append(name)
                }
                if status != .exists {
                    plan.conflicting += others.filter { item in !plan.conflicting.contains { $0.id == item.id } }
                }
                plan.entries.append(.init(id: plan.entries.count, ip: record.ip, name: name, enabled: record.enabled, status: status))
            }
            if !names.isEmpty { plan.records.append(Record(ip: record.ip, names: names, enabled: record.enabled, note: record.note)) }
        }
        return plan
    }

    /// `item` 말고 같은 이름을 다른 주소로 켜 둔 항목.
    public func conflicts(name: String, ip: String, except item: Item? = nil) -> [Item] {
        items.filter {
            $0.enabled && $0.id != item?.id && $0.name.lowercased() == name.lowercased() && $0.ip != ip
                && $0.ip.contains(":") == ip.contains(":")
        }
    }

    /// 팀원에게 보낼 글: 묶음 머리와 켜 둔 항목만, 주소 칸을 맞춰서. 받은 사람은 추가에 그대로 붙여 넣는다.
    public static func exportText(title: String?, items: [Item]) -> String {
        let shown = items.filter(\.enabled)
        let width = shown.map(\.ip.count).max() ?? 0
        let lines = shown.map { $0.ip.padding(toLength: width + 1, withPad: " ", startingAt: 0) + $0.name }
        return ((title.map { ["## " + $0] } ?? []) + lines).joined(separator: "\n") + "\n"
    }
}
