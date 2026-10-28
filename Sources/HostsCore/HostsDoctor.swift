import Foundation

/// hosts 파일에서 손볼 곳. `fixable`이면 정리하면 고쳐진다.
public struct HostsIssue: Identifiable, Equatable {
    public enum Kind: Equatable { case duplicate, conflict, invalid, brokenMarker, suspiciousIP, mdns }

    public var id: String { "\(line)-\(kind)-\(message)" }
    public let kind: Kind
    /// 0부터 센 줄 번호. 화면에는 1을 더해 보인다.
    public let line: Int
    public let message: String

    /// 정리하면 고쳐지는 것. 나머지는 사람이 골라야 한다.
    public var fixable: Bool { kind == .duplicate || kind == .brokenMarker }
    /// 이름 풀이를 늦출 뿐 틀리지는 않는 것.
    public var isNotice: Bool { kind == .mdns }
}

public enum HostsDoctor {
    public static func issues(in file: HostsFile) -> [HostsIssue] {
        var issues: [HostsIssue] = []
        var seenPairs: [String: Int] = [:]
        // 이름과 주소 종류(IPv4/IPv6)마다 처음 켠 줄
        var firstEnabled: [String: (line: Int, ip: String)] = [:]
        var mdnsWarned = Set<String>()
        for index in file.headerEnd..<file.lines.count {
            let line = file.lines[index]
            switch line.kind {
            case .invalid:
                if HostsFile.isEndMarker(line.raw) {
                    issues.append(.init(kind: .brokenMarker, line: index, message: "묶음 끝 표시가 주석(#)으로 시작하지 않습니다"))
                } else {
                    issues.append(.init(kind: .invalid, line: index, message: "주소로 읽을 수 없는 줄입니다: \(line.raw.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            case .entry(let record):
                if let hint = typoHint(record.ip) {
                    issues.append(.init(kind: .suspiciousIP, line: index, message: "\(record.ip)는 \(hint)의 오타일 수 있습니다"))
                }
                for name in record.names {
                    let pair = record.ip + " " + name.lowercased()
                    if let first = seenPairs[pair] {
                        issues.append(.init(kind: .duplicate, line: index, message: "\(name): \(first + 1)번째 줄과 같습니다"))
                    } else {
                        seenPairs[pair] = index
                    }
                    if record.enabled {
                        let key = name.lowercased() + (record.ip.contains(":") ? "/6" : "/4")
                        if let first = firstEnabled[key], first.ip != record.ip {
                            issues.append(.init(kind: .conflict, line: index,
                                                message: "\(name): \(first.line + 1)번째 줄(\(first.ip))과 주소가 다릅니다. 어느 쪽으로 풀릴지 장담할 수 없어 하나를 끄세요"))
                        } else if firstEnabled[key] == nil {
                            firstEnabled[key] = (index, record.ip)
                        }
                    }
                    if name.lowercased().hasSuffix(".local"), mdnsWarned.insert(name.lowercased()).inserted {
                        issues.append(.init(kind: .mdns, line: index,
                                            message: "\(name): .local은 맥이 mDNS로 먼저 찾아 5초쯤 늦어질 수 있습니다. .test나 .localhost를 권합니다"))
                    }
                }
            default: continue
            }
        }
        return issues.sorted { ($0.line, $0.kind.order) < ($1.line, $1.kind.order) }
    }

    /// 사설 대역을 잘못 친 것으로 보이는 주소. `191.168.10.40` → `192.168.10.40`.
    static func typoHint(_ ip: String) -> String? {
        guard HostsFile.isIPv4(ip) else { return nil }
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        if octets[1] == 168, octets[0] != 192, abs(octets[0] - 192) <= 10 || octets[0] == 129 {
            return "192.168.\(octets[2]).\(octets[3])"
        }
        if octets[0] == 192, octets[1] == 186 || octets[1] == 68 {
            return "192.168.\(octets[2]).\(octets[3])"
        }
        return nil
    }
}

private extension HostsIssue.Kind {
    var order: Int {
        switch self {
        case .invalid: return 0
        case .brokenMarker: return 1
        case .duplicate: return 2
        case .conflict: return 3
        case .suspiciousIP: return 4
        case .mdns: return 5
        }
    }
}
