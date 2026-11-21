import Foundation
import Testing
@testable import PortsCore

// 이 맥에서 실제로 본 프로세스 모양을 줄였다
private let table = PortScan.parse(ps: """
    3075 3072 -/bin/zsh -l
    3755 3075 npm run dev
    3774 3755 node /Users/me/web/node_modules/.bin/vite
    4100 4000 claude
    4101 4100 npm exec @playwright/mcp@latest
    4102 4101 node /Users/me/.npm/_npx/1/node_modules/.bin/playwright-mcp
    5000 1 /Applications/Visual Studio Code.app/Contents/MacOS/Code
    5001 5000 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper --type=utility
    6000 3075 next-server (v14.2.3)
    7000 1 /usr/bin/python3 -m http.server 8000
    7100 99 node server.js
    """)

private func port(_ number: Int, _ pid: Int, _ name: String = "node", _ address: String = "127.0.0.1") -> ListeningPort {
    ListeningPort(port: number, addresses: [address], pid: pid, command: name, uid: 501)
}

@Suite struct PortServerTests {
    @Test func groupsChildUnderPackageScript() {
        let servers = PortScan.servers([port(6002, 3774, "node", "::1"), port(24678, 3774)], processes: table, own: 1)
        #expect(servers.count == 1)
        #expect(servers[0].root.command == "npm run dev")
        #expect(servers[0].chain.map(\.pid) == [3774, 3755])
        #expect(servers[0].portNumbers == [6002, 24678])
        #expect(servers[0].primaryPort == 6002)
    }

    @Test func stopsAtShellsEditorsAndClaude() {
        let servers = PortScan.servers([port(9000, 4102), port(49171, 5001, "Code Helper"), port(3000, 6000, "next-server")],
                                       processes: table, own: 1)
        let roots = Dictionary(uniqueKeysWithValues: servers.map { ($0.primaryPort, $0.root.pid) })
        #expect(roots[9000] == 4101)
        #expect(roots[49171] == 5001)
        #expect(roots[3000] == 6000)
    }

    @Test func stopsAtOwnApp() {
        let servers = PortScan.servers([port(3000, 7100)], processes: table, own: 99)
        #expect(servers[0].root.pid == 7100)
    }

    @Test func classifiesByPathFirst() {
        #expect(PortScan.kind(name: "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter") == .system)
        #expect(PortScan.kind(name: "rapportd", path: "/usr/libexec/rapportd") == .system)
        #expect(PortScan.kind(name: "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
            == .app(name: "Visual Studio Code", bundle: "/Applications/Visual Studio Code.app"))
        #expect(PortScan.kind(name: "com.docker.backend", path: nil) == .docker)
        #expect(PortScan.kind(name: "node", path: "/Users/me/.nvm/versions/node/v24/bin/node") == .devServer)
        #expect(PortScan.kind(name: "Python", path: "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python")
            == .devServer)
        #expect(PortScan.kind(name: "python3.12", path: "/usr/local/bin/python3.12") == .devServer)
        #expect(PortScan.kind(name: "next-server (v14.2.3)", path: "/usr/local/bin/node") == .devServer)
        #expect(PortScan.kind(name: "mariadbd", path: "/opt/homebrew/opt/mariadb/bin/mariadbd") == .database)
        #expect(PortScan.kind(name: "Spotify", path: "/opt/spotify") == .other)
    }

    @Test func groupsHomebrewSafeScript() {
        let processes = PortScan.parse(ps: """
            2037 1 /bin/sh /opt/homebrew/opt/mariadb/bin/mariadbd-safe --datadir=/opt/homebrew/var/mysql
            3186 2037 /opt/homebrew/opt/mariadb/bin/mariadbd --basedir=/opt/homebrew/opt/mariadb
            """)
        let servers = PortScan.servers([port(3306, 3186, "mariadbd", "*")], processes: processes, own: 99)
        #expect(servers[0].root.pid == 2037)
        #expect(PortScan.homebrewFormula(path: "/opt/homebrew/opt/mariadb/bin/mariadbd") == "mariadb")
        #expect(PortScan.homebrewFormula(path: "/usr/local/Cellar/redis/7.2/bin/redis-server") == "redis")
        #expect(PortScan.homebrewFormula(path: "/usr/bin/python3") == nil)
    }

    @Test func shortensCommands() {
        #expect(PortScan.displayCommand("node /Users/me/web/node_modules/.bin/vite --port 5173") == "vite --port 5173")
        #expect(PortScan.displayCommand("npm run dev") == "npm run dev")
        #expect(PortScan.displayCommand("/opt/homebrew/bin/mariadbd --basedir=/opt/x", limit: 20) == "mariadbd --basedir=…")
    }

    @Test func classifiesBundledRuntimesAsApps() {
        #expect(PortScan.kind(name: "java", path: "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java")
            == .app(name: "Android Studio", bundle: "/Applications/Android Studio.app"))
        #expect(PortScan.kind(name: "OrbStack Helper", path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper") == .docker)
        #expect(PortScan.kind(name: "limactl", path: "/opt/homebrew/bin/limactl") == .docker)
    }

    private func process(_ pid: Int, _ ppid: Int, _ argv: [String]) -> PortProcess {
        PortProcess(pid: pid, ppid: ppid, command: argv.joined(separator: " "), argv: argv)
    }

    @Test func restartPlansFromClosestProcess() throws {
        let vite = [process(2, 1, ["node", "/w/node_modules/.bin/vite"]), process(1, 0, ["npm run dev", "", ""])]
        #expect(try PortRestart.plan(chain: vite, from: 6002, to: 6003).get() == .init(arguments: ["node", "/w/node_modules/.bin/vite", "--port", "6003"], pid: 2, method: .appended))
        #expect(try PortRestart.plan(chain: vite, from: 6002, to: 6002).get() == .init(arguments: ["npm", "run", "dev"], pid: 1, method: .same))

        let flagged = [process(2, 1, ["node", "/w/.bin/vite", "--port", "5173"]), process(1, 0, ["npm run dev"])]
        #expect(try PortRestart.plan(chain: flagged, from: 5173, to: 5174).get().command == "node /w/.bin/vite --port 5174")

        let cra = [process(2, 1, ["node", "/w/react-scripts/scripts/start.js"]), process(1, 0, ["npm start"])]
        #expect(try PortRestart.plan(chain: cra, from: 3000, to: 3001).get() == .init(arguments: ["npm", "start", "--", "--port", "3001"], pid: 1, method: .appended))

        let plain = [process(3, 1, ["node", "server.js"])]
        #expect(try PortRestart.plan(chain: plain, from: 3000, to: 3001).get() == .init(arguments: ["node", "server.js"], pid: 3, method: .environment))
    }

    @Test func handlesPnpmShims() throws {
        // pnpm은 root가 `node …/pnpm.cjs dev`, 리스너가 `node …/vite/bin/vite.js`로 보인다
        let viteJS = [process(2, 1, ["node", "/w/node_modules/vite/bin/vite.js"]), process(1, 0, ["node", "/opt/homebrew/lib/pnpm.cjs", "dev"])]
        let processes = viteJS
        #expect(try PortRestart.plan(chain: viteJS, from: 5173, to: 5174, processes: processes).get().command
            == "node /w/node_modules/vite/bin/vite.js --port 5174")
        let next = [process(2, 1, ["next-server (v14)"]), process(1, 0, ["node", "/opt/homebrew/bin/pnpm", "dev"])]
        #expect(try PortRestart.plan(chain: next, from: 3000, to: 3001).get().command == "node /opt/homebrew/bin/pnpm dev --port 3001")
        let shim = [process(20, 10, ["node", "/w/node_modules/vite/bin/vite.js"]), process(10, 1, ["node", "/opt/homebrew/lib/pnpm.cjs", "dev"])]
        #expect(PortScan.servers([port(5173, 20)], processes: shim, own: 99)[0].root.pid == 10)
    }

    @Test func refusesToDropSiblingProcesses() {
        // concurrently가 vite와 api를 같이 띄웠으면 vite만 다시 띄울 수 없다
        let all = [process(1, 0, ["npm run dev"]), process(2, 1, ["node", "/w/.bin/concurrently", "vite", "node api.js"]),
                   process(3, 2, ["node", "/w/.bin/vite"]), process(4, 2, ["node", "api.js"])]
        let chain = [all[2], all[1], all[0]]
        guard case .failure = PortRestart.plan(chain: chain, from: 5173, to: 5174, processes: all) else {
            Issue.record("함께 도는 api가 있는데 vite만 다시 띄우려 함")
            return
        }
        // 같은 포트로 다시 시작은 바깥 실행 전체를 다시 띄우니 된다
        #expect((try? PortRestart.plan(chain: chain, from: 5173, to: 5173, processes: all).get())?.pid == 1)
    }

    @Test func skipsShellWrappers() throws {
        // bash를 쓰는 사용자의 Claude Code·편집기는 `bash -c -l … npm run dev`로 띄운다
        let chain = [process(3, 2, ["node", "/w/server.js"]), process(2, 1, ["npm run dev"]),
                     process(1, 0, ["/bin/bash", "-c", "-l", "source snapshot.sh && eval 'npm run dev'"])]
        #expect(try PortRestart.plan(chain: chain, from: 3000, to: 3000).get().pid == 2)
        // 감싼 셸이 다른 프로세스도 띄웠으면 다시 시작하지 않는다
        let wrapped = [process(13, 12, ["npm run dev"]), process(12, 11, ["bash", "-c", "npm run dev & node api.js"])]
        let all = wrapped + [process(14, 12, ["node", "api.js"])]
        guard case .failure = PortRestart.plan(chain: wrapped, from: 3000, to: 3000, processes: all) else { Issue.record("api.js를 잃음"); return }
        #expect(PortScan.toolName("/w/.yarn/releases/yarn-4.5.0.cjs") == "yarn")
        let only = [process(5, 4, ["sh", "-c", "python3 -m http.server"])]
        guard case .failure = PortRestart.plan(chain: only, from: 8000, to: 8000) else { Issue.record("셸만 남은 실행을 다시 띄우려 함"); return }
    }
}
