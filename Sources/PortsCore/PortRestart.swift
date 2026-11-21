import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 개발 서버를 다른 포트로 다시 띄울 때 쓰는 계산.
public enum PortRestart {
    public struct Plan: Equatable, Sendable {
        public enum Method: Equatable, Sendable {
            /// 같은 포트로 같은 명령을 다시 실행한다.
            case same
            /// 명령 안의 `--port`·`-p` 값을 바꿨다.
            case rewrote
            /// 포트 옵션을 받는 도구(vite, next 등)에 `--port`를 붙였다.
            case appended
            /// 환경변수 PORT로만 넘겼다. 이것을 읽지 않는 서버는 원래 포트로 뜬다.
            case environment
        }

        /// 실행할 인자. 셸을 거치지 않고 그대로 넘긴다.
        public let arguments: [String]
        /// 이 명령을 실행하던 프로세스. 그 작업 폴더에서 다시 실행한다.
        public let pid: Int
        public let method: Method

        public var command: String { arguments.joined(separator: " ") }
    }

    public struct Refusal: Error, Equatable, Sendable {
        public let message: String
    }

    /// `chain`은 포트를 연 프로세스부터 가장 바깥 실행까지. `processes`는 지금 프로세스 목록 전체다.
    /// 가까운 쪽부터 포트를 바꿀 수 있는 명령을 찾되, 그 명령만 다시 띄우면 함께 돌던 프로세스가 사라지는 경우는 막는다.
    public static func plan(chain: [PortProcess], from old: Int, to new: Int, processes: [PortProcess] = []) -> Result<Plan, Refusal> {
        // `sh -c`·`bash -c`로 감싼 바깥 셸은 다시 실행할 수 없어(Claude Code·편집기가 쓰는 일회용 셸) 그 안쪽을 쓴다
        guard let topIndex = chain.lastIndex(where: { !PortScan.isShellWrapper($0.tokens) }) else {
            return .failure(Refusal(message: "셸 명령으로 띄운 서버라 다시 실행할 명령을 알 수 없습니다"))
        }
        let inner = Array(chain[...topIndex])
        let top = inner[topIndex]
        // 끌 때는 감싼 셸까지 끈다. 그 셸이 `npm run dev & node api.js`처럼 다른 것도 띄웠다면 다시 살릴 수 없다
        if let root = chain.last, root.pid != top.pid {
            let kept = Set(PortScan.descendants(of: top.pid, in: processes) + chain.map(\.pid))
            if PortScan.descendants(of: root.pid, in: processes).contains(where: { !kept.contains($0) }) {
                return .failure(Refusal(message: "셸 명령 하나로 여러 프로세스를 함께 띄워 다시 시작할 수 없습니다. 터미널에서 다시 실행하세요"))
            }
        }
        if old == new { return .success(Plan(arguments: top.tokens, pid: top.pid, method: .same)) }

        var found: Plan?
        for process in inner {
            if let arguments = rewrite(process.tokens, from: old, to: new) { found = Plan(arguments: arguments, pid: process.pid, method: .rewrote); break }
        }
        if found == nil, let process = inner.first(where: { acceptsPortFlag($0.tokens) }) {
            found = Plan(arguments: process.tokens + ["--port", String(new)], pid: process.pid, method: .appended)
        }
        if let plan = found, plan.pid != top.pid {
            // `concurrently`·`turbo`처럼 바깥 실행이 다른 프로세스도 띄웠다면, 안쪽 하나만 다시 띄우면 나머지가 사라진다
            let kept = Set(PortScan.descendants(of: plan.pid, in: processes) + inner.map(\.pid))
            if PortScan.descendants(of: top.pid, in: processes).contains(where: { !kept.contains($0) }) {
                return .failure(Refusal(message: "\(PortScan.displayCommand(tokens: top.tokens, limit: 40))가 다른 프로세스도 함께 띄워, 포트만 바꿔 다시 시작할 수 없습니다. 같은 포트로 ‘다시 시작’하거나 터미널에서 포트를 바꿔 실행하세요"))
            }
            return .success(plan)
        }
        if let plan = found { return .success(plan) }
        // `npm run dev`는 `--` 뒤의 인자를 스크립트에 넘긴다. yarn·pnpm·bun은 바로 넘긴다
        var tokens = top.tokens
        if tokens.count > 1, ["node", "bun"].contains(PortScan.toolName(tokens[0])), PortScan.toolName(tokens[1]) != "bun" { tokens.removeFirst() }
        if tokens.count >= 2 {
            let manager = PortScan.toolName(tokens[0])
            if ["npm", "npm-cli"].contains(manager), ["run", "run-script", "start", "dev"].contains(tokens[1]) {
                return .success(Plan(arguments: top.tokens + ["--", "--port", String(new)], pid: top.pid, method: .appended))
            }
            if ["yarn", "pnpm", "bun"].contains(manager), !["exec", "dlx", "x"].contains(tokens[1]) {
                return .success(Plan(arguments: top.tokens + ["--port", String(new)], pid: top.pid, method: .appended))
            }
        }
        return .success(Plan(arguments: top.tokens, pid: top.pid, method: .environment))
    }

    /// 포트 옵션 값만 바꾼 인자. 바꿀 것이 없으면 nil.
    static func rewrite(_ tokens: [String], from old: Int, to new: Int) -> [String]? {
        var tokens = tokens
        var rewrote = false
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if flags.contains(token), index + 1 < tokens.count, Int(tokens[index + 1]) == old {
                tokens[index + 1] = String(new)
                rewrote = true
                index += 2
                continue
            }
            if let equals = token.firstIndex(of: "="), flags.contains(String(token[..<equals])), Int(token[token.index(after: equals)...]) == old {
                tokens[index] = String(token[...equals]) + String(new)
                rewrote = true
            } else if token.hasPrefix("-p"), Int(token.dropFirst(2)) == old {
                tokens[index] = "-p\(new)"
                rewrote = true
            }
            index += 1
        }
        return rewrote ? tokens : nil
    }

    private static let flags: Set<String> = ["--port", "-p"]

    /// `--port`를 받는 개발 서버 도구. CRA(react-scripts)는 받지 않아 넣지 않는다.
    private static let portTools: Set<String> = [
        "vite", "next", "nuxt", "nuxi", "astro", "ng", "webpack", "webpack-dev-server", "storybook", "vue-cli-service",
        "parcel", "http-server", "remix", "react-router",
    ]

    static func acceptsPortFlag(_ tokens: [String]) -> Bool {
        var tokens = tokens
        if tokens.count > 1, ["node", "bun", "deno"].contains(PortScan.toolName(tokens[0])) { tokens.removeFirst() }
        return tokens.first.map { portTools.contains(PortScan.toolName($0)) } ?? false
    }

    /// `start` 이후 처음 비어 있는 포트.
    public static func freePort(from start: Int, avoiding taken: Set<Int> = []) -> Int? {
        guard (1...65535).contains(start) else { return nil }
        for port in start...min(start + 200, 65535) where !taken.contains(port) && isFree(port) { return port }
        return nil
    }

    /// 이 포트에 새 서버가 뜰 수 있는지. 개발 서버가 흔히 쓰는 네 주소에 모두 묶어 본다.
    /// 모든 주소(0.0.0.0)에만 묶어 보면 `::1`이나 127.0.0.1로만 듣는 vite 같은 서버를 놓친다.
    /// SO_REUSEADDR를 켜야 방금 끈 서버의 TIME_WAIT 연결 때문에 쓰는 중으로 보이지 않는다.
    public static func isFree(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fixed: [(String, Int32)] = [("127.0.0.1", AF_INET), ("0.0.0.0", AF_INET), ("::1", AF_INET6), ("::", AF_INET6)]
        // `--host 192.168.0.5`처럼 이 맥의 특정 주소로만 듣는 서버도 본다
        guard fixed.allSatisfy({ canBind(port, address: $0.0, family: $0.1) }) else { return false }
        // 방금 내려간 인터페이스 주소는 묶을 수 없어도(EADDRNOTAVAIL) 쓰는 중이라는 뜻은 아니다
        return interfaceAddresses().allSatisfy { canBind(port, address: $0, family: AF_INET, missingIsFree: true) }
    }

    /// 루프백을 뺀 이 맥의 IPv4 주소들.
    static func interfaceAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(String(cString: host))
        }
        return Array(Set(result))
    }

    static func canBind(_ port: Int, address: String, family: Int32, missingIsFree: Bool = false) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        // IPv6를 끈 맥에서는 그 주소로 뜰 서버도 없다
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            inet_pton(AF_INET, address, &addr.sin_addr)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
            return bound || (missingIsFree && errno == EADDRNOTAVAIL)
        }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(port).bigEndian
        inet_pton(AF_INET6, address, &addr.sin6_addr)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
        }
    }
}
