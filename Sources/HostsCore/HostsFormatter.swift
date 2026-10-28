import Foundation

/// 정리: 머리말은 그대로 두고 나머지를 묶음별로 한 이름에 한 줄씩 다시 쓴다.
/// 같은 줄은 하나만 남긴다. 같은 이름에 주소가 다른 줄은 맥이 어느 쪽을 쓸지 장담할 수 없어 그대로 둔다.
/// 묶음 설명 주석과 읽을 수 없는 줄은 원문 그대로 남겨, 정리해도 이름이 풀리는 곳과 적어 둔 말이 바뀌지 않는다.
public enum HostsFormatter {
    struct Group {
        var title: String
        /// 묶음 머리 바로 아래 설명 주석 (원문).
        var notes: [String] = []
        var items: [HostsFile.Item] = []
        /// 읽을 수 없던 줄 (원문). 지우지도 주석으로 바꾸지도 않는다.
        var leftovers: [String] = []
    }

    public static func organized(_ file: HostsFile) -> HostsFile {
        var groups: [Group] = []
        func index(_ title: String) -> Int {
            if let found = groups.firstIndex(where: { $0.title.lowercased() == title.lowercased() }) { return found }
            groups.append(Group(title: title))
            return groups.count - 1
        }
        for place in file.places {
            let line = file.lines[place.line]
            let raw = line.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch place.role {
            case .note: groups[index(place.title ?? "기타")].notes.append(raw)
            case .invalid: groups[index(place.title ?? "기타")].leftovers.append(raw)
            case .entry:
                guard let record = line.record else { continue }
                for (slot, name) in record.names.enumerated() {
                    let item = HostsFile.Item(line: place.line, slot: slot, ip: record.ip, name: name, enabled: record.enabled, note: record.note)
                    groups[index(place.title ?? suffix(name))].items.append(item)
                }
            case .blank, .title, .marker: continue
            }
        }

        // 같은 줄: 하나라도 켜져 있었으면 켠 채로, 메모는 먼저 있던 것
        var seen: [String: (group: Int, item: Int)] = [:]
        var output = groups.map { Group(title: $0.title, notes: $0.notes, leftovers: $0.leftovers) }
        for (groupIndex, group) in groups.enumerated() {
            for item in group.items {
                let key = item.ip + " " + item.name.lowercased()
                if let at = seen[key] {
                    let kept = output[at.group].items[at.item]
                    output[at.group].items[at.item] = HostsFile.Item(line: kept.line, slot: kept.slot, ip: kept.ip, name: kept.name,
                                                                     enabled: kept.enabled || item.enabled, note: kept.note ?? item.note)
                    continue
                }
                seen[key] = (groupIndex, output[groupIndex].items.count)
                output[groupIndex].items.append(item)
            }
        }
        for groupIndex in output.indices {
            output[groupIndex].items.sort { (ipKey($0.ip), $0.name.lowercased()) < (ipKey($1.ip), $1.name.lowercased()) }
        }

        // 머리말은 원문 그대로 두되 줄 끝 \r만 뗀다 (한 파일에 줄 끝이 섞이지 않게)
        var lines = file.lines[0..<file.headerEnd].map { $0.raw.hasSuffix("\r") ? String($0.raw.dropLast()) : $0.raw }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        for group in output where !group.items.isEmpty || !group.leftovers.isEmpty || !group.notes.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("## " + group.title)
            lines.append(contentsOf: group.notes)
            let width = group.items.map { $0.ip.count + ($0.enabled ? 0 : 1) }.max() ?? 0
            for item in group.items {
                let address = (item.enabled ? "" : "#") + item.ip
                lines.append(address.padding(toLength: width + 1, withPad: " ", startingAt: 0) + item.name + HostsFile.Record.memo(item.note))
            }
            lines.append(contentsOf: group.leftovers)
        }
        return HostsFile(lines.joined(separator: "\n") + "\n")
    }

    /// 이름과 주소 종류마다 켜 둔 주소들 (머리말 포함). 정리 앞뒤로 같아야 한다.
    static func enabledAddresses(_ file: HostsFile) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for line in file.lines {
            guard let record = line.record, record.enabled else { continue }
            for name in record.names { result[name.lowercased(), default: []].insert(record.ip) }
        }
        return result
    }

    /// 머리 없는 줄의 묶음 이름: 이름의 끝 두 마디 (`dev-bdl-nifi.seowoninfo.com` → `seowoninfo.com`).
    static func suffix(_ name: String) -> String {
        let labels = name.lowercased().split(separator: ".")
        return labels.count >= 2 ? labels.suffix(2).joined(separator: ".") : "기타"
    }

    /// IPv4는 숫자 차례로, IPv6는 그 뒤에.
    private static func ipKey(_ ip: String) -> String {
        guard HostsFile.isIPv4(ip) else { return "1" + ip }
        return "0" + ip.split(separator: ".").map { String(repeating: "0", count: 3 - $0.count) + $0 }.joined(separator: ".")
    }
}

/// 두 글의 줄 차이 (미리 보기용). 파일이 수백 줄이라 LCS 표로 충분하다.
public enum LineDiff {
    public enum Kind: Equatable { case same, added, removed }

    public struct Change: Equatable, Identifiable {
        public let id: Int
        public let kind: Kind
        public let text: String
    }

    /// 앞뒤 같은 줄을 먼저 덜어 내고 가운데만 LCS로 맞춘다. 수만 줄 hosts에서 한 줄 고쳐도 표가 커지지 않게.
    /// 가운데가 너무 크면(통째로 바뀐 판) 뺀 줄을 다 보이고 더한 줄을 다 보인다.
    public static func changes(from old: String, to new: String) -> [Change] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var head = 0
        while head < oldLines.count, head < newLines.count, oldLines[head] == newLines[head] { head += 1 }
        var tail = 0
        while tail < oldLines.count - head, tail < newLines.count - head,
              oldLines[oldLines.count - 1 - tail] == newLines[newLines.count - 1 - tail] { tail += 1 }
        let a = Array(oldLines[head..<(oldLines.count - tail)])
        let b = Array(newLines[head..<(newLines.count - tail)])
        var result: [Change] = []
        func add(_ kind: Kind, _ text: String) { result.append(Change(id: result.count, kind: kind, text: text)) }
        for line in oldLines[0..<head] { add(.same, line) }
        if a.count * b.count > 4_000_000 {
            for line in a { add(.removed, line) }
            for line in b { add(.added, line) }
        } else {
            for change in lcs(a, b) { add(change.kind, change.text) }
        }
        for line in oldLines[(oldLines.count - tail)...] { add(.same, line) }
        return result
    }

    private static func lcs(_ a: [String], _ b: [String]) -> [Change] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Change] = []
        var i = 0, j = 0
        func add(_ kind: Kind, _ text: String) { result.append(Change(id: result.count, kind: kind, text: text)) }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                add(.same, a[i]); i += 1; j += 1
            } else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] {
                add(.removed, a[i]); i += 1
            } else {
                add(.added, b[j]); j += 1
            }
        }
        return result
    }
}
