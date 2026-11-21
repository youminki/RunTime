import Foundation
import Testing
@testable import PortsCore

@Suite struct PortScanTests {
    @Test func mergesIPv4AndIPv6OfSameProcess() {
        let output = "p100\ncnode\nu501\nn*:3000\nn[::1]:3000\np200\ncPython\nu501\nn127.0.0.1:8000\n"
        let ports = PortScan.parse(lsof: output)
        #expect(ports.map(\.port) == [3000, 8000])
        #expect(ports[0].addresses == ["*", "::1"])
        #expect(ports[0].isLocalOnly == false)
        #expect(ports[1].isLocalOnly)
        #expect(ports[1].pid == 200)
    }

    @Test func unescapesCommandNames() {
        let ports = PortScan.parse(lsof: "p9\ncControl\\x20Center\nu501\nn*:7000\n")
        #expect(ports.first?.command == "Control Center")
    }

    @Test func ignoresBrokenLines() {
        #expect(PortScan.parse(lsof: "n*:3000\nx\n\n").isEmpty)
        #expect(PortScan.split(name: "localhost:abc") == nil)
    }

    @Test func readsWorkingDirectories() {
        #expect(PortScan.parse(cwd: "p100\nn/Users/me/app\np200\nn/tmp/a\\x20b\n") == [100: "/Users/me/app", 200: "/tmp/a b"])
    }

    @Test func findsDescendantsChildrenFirst() {
        let processes = PortScan.parse(ps: """
            10 1 npm run dev
            11 10 node vite --port 5173
            12 11 esbuild --service
            20 1 other
            """)
        #expect(PortScan.descendants(of: 10, in: processes) == [12, 11])
        #expect(PortScan.descendants(of: 20, in: processes).isEmpty)
    }

    @Test func rewritesPortFlags() {
        func rewrite(_ text: String, _ old: Int, _ new: Int) -> String? {
            PortRestart.rewrite(text.split(separator: " ").map(String.init), from: old, to: new)?.joined(separator: " ")
        }
        #expect(rewrite("node vite --port 5173", 5173, 5174) == "node vite --port 5174")
        #expect(rewrite("next dev -p 3000", 3000, 3001) == "next dev -p 3001")
        #expect(rewrite("next dev -p3000", 3000, 3001) == "next dev -p3001")
        #expect(rewrite("serve --port=8080", 8080, 8081) == "serve --port=8081")
        #expect(rewrite("node server.js", 3000, 3001) == nil)
        #expect(rewrite("x --port 9999", 3000, 3001) == nil)
    }

    @Test func keepsArgumentBoundaries() {
        let spaced = PortProcess(pid: 1, ppid: 0, command: "node /Users/me/My Projects/app/server.js", argv: ["node", "/Users/me/My Projects/app/server.js"])
        #expect(spaced.tokens == ["node", "/Users/me/My Projects/app/server.js"])
        // npm이 바꾼 프로세스 제목은 한 덩어리로 남는다
        let titled = PortProcess(pid: 2, ppid: 0, command: "npm run dev", argv: ["npm run dev", "", "", ""])
        #expect(titled.tokens == ["npm", "run", "dev"])
        #expect(PortProcess(pid: 3, ppid: 0, command: "a b").tokens == ["a", "b"])
    }

    @Test func freePortStopsAtTheLastPort() {
        #expect(PortRestart.freePort(from: 65536) == nil)
        #expect(PortRestart.freePort(from: 0) == nil)
        #expect(!PortRestart.isFree(70000))
    }

    @Test func freePortSkipsTaken() {
        let free = PortRestart.freePort(from: 40000, avoiding: [40000])
        #expect(free != nil && free! > 40000)
    }

    /// `::1`이나 127.0.0.1로만 듣는 서버도 쓰는 중으로 본다.
    // 케이스가 동시에 돌아 같은 포트를 고르지 않게 시작 번호를 나눈다
    @Test(arguments: [("::1", AF_INET6, 41000), ("127.0.0.1", AF_INET, 41300), ("0.0.0.0", AF_INET, 41600)])
    func seesLoopbackOnlyListeners(address: String, family: Int32, start: Int) throws {
        let port = try #require(PortRestart.freePort(from: start))
        let fd = socket(family, SOCK_STREAM, 0)
        defer { close(fd) }
        var ok = false
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            inet_pton(AF_INET, address, &addr.sin_addr)
            ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(port).bigEndian
            inet_pton(AF_INET6, address, &addr.sin6_addr)
            ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 } }
        }
        try #require(ok && listen(fd, 1) == 0)
        #expect(!PortRestart.isFree(port))
    }
}
