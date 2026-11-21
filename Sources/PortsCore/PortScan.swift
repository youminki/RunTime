import Foundation

/// 이 맥에서 연결을 기다리는(LISTEN) TCP 포트 하나. 같은 프로세스가 IPv4·IPv6로 같은 포트를 열면 하나로 합친다.
public struct ListeningPort: Identifiable, Equatable, Sendable {
    public let port: Int
    /// 듣는 주소들. `*`은 모든 주소(같은 와이파이의 다른 기기도 접속 가능)다.
    public var addresses: [String]
    public let pid: Int
    public let command: String
    public let uid: Int
    public var id: String { "\(pid)-\(port)" }

    public init(port: Int, addresses: [String], pid: Int, command: String, uid: Int) {
        self.port = port
        self.addresses = addresses
        self.pid = pid
        self.command = command
        self.uid = uid
    }

    /// 이 맥 안에서만 접속되는지. 하나라도 바깥에 열려 있으면 false.
    public var isLocalOnly: Bool {
        addresses.allSatisfy { ["127.0.0.1", "::1", "localhost"].contains($0) }
    }
}

/// 프로세스 하나의 부가 정보 (ps, lsof 결과).
public struct PortProcess: Equatable, Sendable {
    public let pid: Int
    public let ppid: Int
    /// ps가 보여 주는 명령. 인자를 공백으로 이어 붙여 원래 경계는 알 수 없다.
    public let command: String
    /// 커널에서 읽은 실제 인자. 있으면 다시 실행할 때 이것을 쓴다.
    public var argv: [String]?

    public init(pid: Int, ppid: Int, command: String, argv: [String]? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.command = command
        self.argv = argv
    }

    /// 다시 실행할 인자. `~/My Projects/app`처럼 공백이 든 경로도 한 인자로 남는다.
    /// npm은 프로세스 제목을 `npm run dev`로 바꿔 인자 자리에 한 덩어리로 남기므로 그때만 공백으로 나눈다.
    public var tokens: [String] {
        if var list = argv {
            while list.last == "" { list.removeLast() }
            if list.count > 1 || (list.count == 1 && !list[0].contains(" ")) { return list }
        }
        return command.split(separator: " ").map(String.init)
    }
}

public enum PortScan {
    /// `lsof -nP -iTCP -sTCP:LISTEN -F pcnu` 출력을 읽는다. 포트 → pid 순으로 정렬한다.
    public static func parse(lsof output: String) -> [ListeningPort] {
        var result: [String: ListeningPort] = [:]
        var pid = 0, uid = 0
        var command = ""
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p": pid = Int(value) ?? 0; command = ""; uid = 0
            case "c": command = unescape(value)
            case "u": uid = Int(value) ?? 0
            case "n":
                guard pid > 0, let (address, port) = split(name: value) else { continue }
                let key = "\(pid)-\(port)"
                if var existing = result[key] {
                    if !existing.addresses.contains(address) { existing.addresses.append(address) }
                    result[key] = existing
                } else {
                    result[key] = ListeningPort(port: port, addresses: [address], pid: pid, command: command, uid: uid)
                }
            default: continue
            }
        }
        return result.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// `*:3000`, `127.0.0.1:5173`, `[::1]:8080`을 주소와 포트로 나눈다.
    static func split(name: String) -> (String, Int)? {
        guard let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) else { return nil }
        var address = String(name[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        return (address, port)
    }

    /// lsof는 공백 같은 글자를 `\x20`으로 적는다.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\x") else { return text }
        var bytes: [UInt8] = []
        let chars = Array(text.utf8)
        var index = 0
        while index < chars.count {
            if chars[index] == UInt8(ascii: "\\"), index + 3 < chars.count, chars[index + 1] == UInt8(ascii: "x"),
               let byte = UInt8(String(decoding: chars[(index + 2)...(index + 3)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                index += 4
            } else {
                bytes.append(chars[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `lsof -a -d cwd -Fpn` 출력에서 pid → 작업 폴더.
    public static func parse(cwd output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var pid = 0
        for raw in output.split(separator: "\n") {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            if tag == "p" { pid = Int(value) ?? 0 } else if tag == "n", pid > 0 { result[pid] = unescape(value) }
        }
        return result
    }

    /// `ps -axo pid=,ppid=,command=` 출력.
    public static func parse(ps output: String) -> [PortProcess] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { return nil }
            return PortProcess(pid: pid, ppid: ppid, command: parts[2].trimmingCharacters(in: .whitespaces))
        }
    }

    /// `root`와 그 아래로 뻗은 모든 자식 프로세스. 자식부터 먼저 오게 깊은 것이 앞이다.
    /// `npm run dev`는 vite·next 같은 자식을 띄우므로 같이 끝내야 포트가 풀린다.
    public static func descendants(of root: Int, in processes: [PortProcess]) -> [Int] {
        var children: [Int: [Int]] = [:]
        for process in processes { children[process.ppid, default: []].append(process.pid) }
        var order: [Int] = []
        var seen: Set<Int> = [root]
        func walk(_ pid: Int) {
            for child in children[pid] ?? [] where seen.insert(child).inserted {
                walk(child)
                order.append(child)
            }
        }
        walk(root)
        return order
    }
}
