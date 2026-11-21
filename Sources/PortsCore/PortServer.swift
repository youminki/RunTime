import Foundation

/// 포트를 연 프로그램의 종류. 끌 수 있는지와 화면에서 어디에 둘지를 정한다.
public enum PortKind: Equatable, Sendable {
    case devServer
    case database
    /// Docker가 컨테이너 포트를 대신 연다. 끄면 Docker 전체가 꺼진다.
    case docker
    /// 앱 번들 안의 프로세스. 이름은 바깥 앱 이름이다 (`Code Helper` → `Visual Studio Code`).
    case app(name: String, bundle: String)
    /// macOS가 띄운 프로세스. 내 계정이어도 끄면 안 된다.
    case system
    case other

    public var isDevelopment: Bool { self == .devServer || self == .database }
    public var canTerminate: Bool { self != .system && self != .docker }
}

/// 같은 실행에서 뜬 포트 묶음. `npm run dev`가 띄운 vite처럼 부모까지 거슬러 올라간 프로세스를 하나로 본다.
public struct PortServer: Identifiable, Equatable, Sendable {
    /// 끄고 다시 띄울 때 기준이 되는 가장 바깥 실행 (`npm run dev`).
    public let root: PortProcess
    /// 포트를 연 프로세스에서 `root`까지. 첫 번째가 포트를 연 프로세스다.
    public let chain: [PortProcess]
    public var ports: [ListeningPort]
    public var id: Int { root.pid }

    public init(root: PortProcess, chain: [PortProcess], ports: [ListeningPort]) {
        self.root = root
        self.chain = chain
        self.ports = ports
    }

    public var portNumbers: [Int] { Array(Set(ports.map(\.port))).sorted() }

    /// 브라우저로 열 포트. 임시 포트(49152 이상)는 내부 통신용인 경우가 많아 뒤로 미룬다.
    public var primaryPort: Int {
        let numbers = portNumbers
        return numbers.first { $0 < 49152 } ?? numbers.first ?? 0
    }

    public var isLocalOnly: Bool { ports.allSatisfy(\.isLocalOnly) }
    public var listener: ListeningPort? { ports.first }
}

extension PortScan {
    /// 프로세스 목록에서 포트를 연 프로세스마다 바깥 실행을 찾아 묶는다. 포트 순으로 정렬한다.
    /// `own`은 이 앱의 pid. 여기서 띄운 서버가 이 앱까지 묶이지 않게 거기서 멈춘다.
    public static func servers(_ ports: [ListeningPort], processes: [PortProcess], own: Int) -> [PortServer] {
        let table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [Int: PortServer] = [:]
        for port in ports {
            let start = table[port.pid] ?? PortProcess(pid: port.pid, ppid: 0, command: port.command)
            var chain = [start]
            var current = start
            while let parent = table[current.ppid], parent.pid > 1, parent.pid != own, isLauncher(parent.tokens),
                  !chain.contains(where: { $0.pid == parent.pid }) {
                chain.append(parent)
                current = parent
            }
            if var group = groups[current.pid] {
                group.ports.append(port)
                groups[current.pid] = group
            } else {
                groups[current.pid] = PortServer(root: current, chain: chain, ports: [port])
            }
        }
        return groups.values
            .map { group in
                var group = group
                group.ports.sort { ($0.port, $0.pid) < ($1.port, $1.pid) }
                return group
            }
            .sorted { ($0.primaryPort, $0.id) < ($1.primaryPort, $1.id) }
    }

    /// 개발 서버를 띄우는 실행으로 보이는지. 맞으면 그 부모까지 한 서버로 묶는다.
    /// 셸(`-zsh`)이나 편집기, Claude Code 같은 것은 넣지 않는다. 묶이면 서버를 끌 때 같이 꺼진다.
    static func isLauncher(_ tokens: [String]) -> Bool {
        guard let first = tokens.first.map(toolName) else { return false }
        if launchers.contains(first) { return true }
        // npm은 스크립트를 `sh -c`로, Homebrew mariadb는 `sh mariadbd-safe`로 띄운다
        if ["sh", "bash"].contains(first), tokens.count > 1 { return tokens[1] == "-c" || launchers.contains(toolName(tokens[1])) }
        if ["node", "bun", "deno"].contains(first), tokens.count > 1 { return launchers.contains(toolName(tokens[1])) }
        return false
    }

    /// `sh -c …`처럼 셸이 명령 한 줄을 감싼 것. 다시 실행할 때는 그 안쪽 프로세스를 쓴다.
    static func isShellWrapper(_ tokens: [String]) -> Bool {
        guard let first = tokens.first.map(toolName), ["sh", "bash", "zsh", "dash"].contains(first) else { return false }
        return tokens.dropFirst().contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }
    }

    /// 도구 이름. 경로와 `.js` 같은 꼬리를 뗀다 (pnpm은 `…/vite/bin/vite.js`, `…/pnpm.cjs`로 실행한다).
    public static func toolName(_ token: String) -> String {
        var name = basename(token)
        for suffix in [".js", ".cjs", ".mjs"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        // yarn 2 이상은 `.yarn/releases/yarn-4.5.0.cjs`로 실행된다
        if name.hasPrefix("yarn-"), name.dropFirst(5).first?.isNumber == true { return "yarn" }
        return name
    }

    private static let launchers: Set<String> = [
        "npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx", "turbo", "nx", "nodemon", "concurrently",
        "npm-cli", "npx-cli",
        "vite", "next", "nuxt", "nuxi", "astro", "ng", "react-scripts", "craco", "webpack", "webpack-dev-server",
        "storybook", "vue-cli-service", "parcel", "ts-node", "tsx", "remix", "react-router",
        "mysqld_safe", "mariadbd-safe",
    ]

    static func basename(_ token: String) -> String {
        var name = token.split(separator: "/").last.map(String.init) ?? token
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    private static let devNames: Set<String> = [
        "node", "bun", "deno", "python", "ruby", "php", "java", "go", "dotnet", "esbuild", "next", "vite", "uvicorn", "gunicorn",
        "rails", "puma", "hugo", "caddy", "nginx", "httpd", "air",
    ]
    private static let databaseNames: Set<String> = [
        "mysqld", "mariadbd", "postgres", "redis", "mongod", "memcached", "elasticsearch", "clickhouse",
    ]

    /// `name`은 lsof의 프로세스 이름, `path`는 실행 파일 경로.
    public static func kind(name: String, path: String?) -> PortKind {
        let path = path ?? ""
        if containerNames.contains(where: name.hasPrefix) || containerApps.contains(where: path.contains) { return .docker }
        if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains(where: path.hasPrefix) { return .system }
        // `next-server (v14.2.3)`, `python3.12`처럼 붙은 꼬리를 떼고 본다
        let word = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init) ?? ""
        let stem = String(word.prefix { !$0.isNumber && $0 != "." })
        let development: PortKind? = devNames.contains(stem) ? .devServer
            : databaseNames.contains(stem) || stem.hasPrefix("redis") ? .database : nil
        // Homebrew 파이썬은 Python.framework 안의 Python.app에서 돈다. 다른 앱 번들 안의 java·node는
        // Android Studio의 Gradle 데몬처럼 앱의 일부라 앱으로 본다
        if let development, path.contains("/Python.framework/") { return development }
        if let range = path.range(of: ".app/") {
            let bundle = String(path[..<range.lowerBound]) + ".app"
            let app = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
            return .app(name: app, bundle: bundle)
        }
        return development ?? .other
    }

    /// 컨테이너 포트를 대신 여는 도구. 끄면 모든 컨테이너 포트가 끊긴다.
    private static let containerNames = ["com.docker", "OrbStack", "limactl", "colima", "gvproxy", "vpnkit", "rancher"]
    private static let containerApps = ["/Docker.app/", "/OrbStack.app/", "/Rancher Desktop.app/", "/Podman Desktop.app/"]

    /// Homebrew로 설치한 프로그램이면 그 이름 (`/opt/homebrew/opt/mariadb/bin/mariadbd` → `mariadb`).
    public static func homebrewFormula(path: String?) -> String? {
        guard let path, let match = path.range(of: #"^/(opt/homebrew|usr/local)/(opt|Cellar)/[^/]+"#, options: .regularExpression) else { return nil }
        return path[match].split(separator: "/").last.map(String.init)
    }

    /// 화면에 보일 짧은 명령. 경로는 파일 이름만 남긴다. `node …/node_modules/.bin/vite` → `vite`.
    public static func displayCommand(_ command: String, limit: Int = 60) -> String {
        displayCommand(tokens: command.split(separator: " ").map(String.init), limit: limit)
    }

    public static func displayCommand(tokens: [String], limit: Int = 60) -> String {
        var tokens = tokens
        if tokens.count > 1, ["node", "bun", "deno", "sh", "bash"].contains(basename(tokens[0])), tokens[1].contains("/") {
            tokens.removeFirst()
        }
        let text = tokens.map { $0.hasPrefix("-") || !$0.contains("/") ? $0 : basename($0) }.joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
