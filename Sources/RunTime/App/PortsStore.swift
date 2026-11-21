import AppKit
import Darwin
import PortsCore

/// 지금 열려 있는 포트를 실행 단위로 묶어 보여 주고, 끄거나 다른 포트로 다시 시작한다.
/// 화면이 보이는 동안만 3초마다 다시 읽는다. 메뉴바 메뉴는 열 때 한 번 읽는다.
@MainActor
final class PortsStore: ObservableObject {
    static let shared = PortsStore()

    struct Server: Identifiable, Equatable {
        let group: PortServer
        let kind: PortKind
        /// 바깥 실행의 작업 폴더. 어느 프로젝트의 서버인지 보여 줄 때 쓴다.
        let cwd: String?
        let uid: Int
        /// 포트를 연 프로세스의 실행 파일.
        let path: String?
        /// 바깥 실행의 시작 시각. 끄기 직전에 같은 프로세스인지 이것으로 확인한다 (제목을 바꾸는 도구도 있어 명령은 믿지 않는다).
        let rootStarted: UInt64?
        /// 이 앱이 다시 시작한 서버라면 출력이 쌓이는 로그 파일.
        var log: URL?

        var id: Int { group.id }
        var primaryPort: Int { group.primaryPort }
        var ports: [Int] { group.portNumbers }
        var mine: Bool { uid == Int(getuid()) }
        var canTerminate: Bool { mine && kind.canTerminate }
        var isWeb: Bool { kind == .devServer }
        var isLocalOnly: Bool { group.isLocalOnly }
        /// 포트를 연 프로세스 이름. lsof는 이름을 31자에서 잘라 실행 파일 이름을 먼저 쓴다.
        var listenerName: String {
            path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? group.listener?.command ?? group.root.command
        }

        /// 줄 제목. 개발 서버는 프로젝트 폴더, 앱은 앱 이름, 나머지는 프로세스 이름.
        var title: String {
            switch kind {
            case .app(let name, _): return name
            case .database:
                return PortScan.homebrewFormula(path: path) ?? listenerName
            case .devServer:
                if let cwd, cwd != "/", cwd != NSHomeDirectory() { return URL(fileURLWithPath: cwd).lastPathComponent }
                return PortScan.displayCommand(tokens: group.root.tokens, limit: 32)
            case .docker:
                if let path, let range = path.range(of: ".app/") {
                    return URL(fileURLWithPath: String(path[..<range.lowerBound])).lastPathComponent
                }
                return listenerName
            case .system, .other: return listenerName
            }
        }

        /// 제목 아래 한 줄. 무엇으로 띄웠는지와 어디서 띄웠는지.
        var detail: String {
            switch kind {
            case .database:
                return brewService != nil ? "Homebrew 서비스 · " + PortScan.displayCommand(tokens: group.root.tokens)
                    : PortScan.displayCommand(tokens: group.root.tokens)
            case .devServer:
                let command = PortScan.displayCommand(tokens: group.root.tokens)
                guard let cwd, cwd != "/" else { return command }
                return command + " · " + (cwd as NSString).abbreviatingWithTildeInPath
            case .app(let name, _):
                return listenerName == name ? "PID \(group.root.pid)" : "\(listenerName) · PID \(group.root.pid)"
            case .docker: return "컨테이너 포트를 대신 여는 프로세스 (\(listenerName))"
            case .system: return "macOS 시스템 프로세스"
            case .other: return "PID \(group.root.pid)"
            }
        }

        /// 포트가 막혔을 때 자주 헷갈리는 경우를 짚어 준다.
        var note: String? {
            if kind == .system, listenerName == "ControlCenter" {
                return "AirPlay 수신 모드가 \(ports.map(String.init).joined(separator: "·"))번을 씁니다"
            }
            if kind == .docker { return "끄려면 컨테이너 도구에서 해당 컨테이너를 멈추세요" }
            if brewService != nil { return "종료해도 Homebrew가 다시 켭니다" }
            return nil
        }

        /// `brew services`로 켠 서비스의 이름. launchd가 다시 띄우므로 종료만으로는 꺼지지 않는다.
        var brewService: String? {
            guard group.root.ppid == 1 else { return nil }
            return PortScan.homebrewFormula(path: path)
        }

        /// 종료를 막은 이유. 끌 수 있으면 nil.
        var lockedReason: String? {
            if kind == .system { return "macOS가 쓰는 프로세스라 여기서 끄지 않습니다" }
            if kind == .docker { return "끄면 모든 컨테이너 포트가 끊기므로 컨테이너 도구에서 멈추세요" }
            if !mine { return "다른 계정의 프로세스라 끌 수 없습니다" }
            return nil
        }
    }

    /// 사용법 영상·화면 점검용. `RUNTIME_PORTS_DEMO=1`이면 이 Mac의 실제 프로세스 대신 예시 서버를 보이고, 끄거나 다시 시작하지 않는다.
    static let demo = ProcessInfo.processInfo.environment["RUNTIME_PORTS_DEMO"] == "1"

    @Published private(set) var servers: [Server] = []
    @Published private(set) var loaded = false
    @Published private(set) var problem: String?
    /// 끄거나 다시 시작하는 중인 서버와 그 상태 글.
    @Published private(set) var busy: [Int: String] = [:]
    /// 다시 시작한 서버의 로그. 열쇠는 새로 띄운 프로세스 pid.
    private var logs: [Int: URL] = [:]
    private var timer: Timer?
    private var scanning = false
    /// 늦게 끝난 옛 스캔이 새 결과를 덮지 않게 매긴 번호.
    private var scanSequence = 0
    private var appliedSequence = 0

    private init() {}

    /// 웹 개발 서버를 먼저, 데이터베이스를 그 뒤에.
    var devServers: [Server] {
        servers.filter { $0.kind.isDevelopment }.sorted { ($0.isWeb ? 0 : 1, $0.primaryPort) < ($1.isWeb ? 0 : 1, $1.primaryPort) }
    }
    var otherServers: [Server] { servers.filter { !$0.kind.isDevelopment } }

    func setWatching(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        if Self.demo {
            if !loaded { apply(.success(Self.demoServers()), sequence: scanSequence + 1) }
            return
        }
        guard !scanning else { return }
        scanning = true
        scanSequence += 1
        let sequence = scanSequence
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.apply(result, sequence: sequence)
            }
        }
    }

    /// 메뉴바 메뉴처럼 바로 그려야 할 때. 보통 0.1초 안에 끝나지만, 응답 없는 네트워크 드라이브 때문에
    /// lsof가 늦으면 메뉴가 멈추지 않게 `timeout`까지만 기다리고 지난 목록을 쓴다.
    func refreshNow(timeout: TimeInterval = 0.8) {
        if Self.demo { return refresh() }
        scanSequence += 1
        let sequence = scanSequence
        let box = ScanBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.result = Self.scan()
            finished.signal()
            DispatchQueue.main.async { [weak self] in if let result = box.result { self?.apply(result, sequence: sequence) } }
        }
        if finished.wait(timeout: .now() + timeout) == .success, let result = box.result { apply(result, sequence: sequence) }
    }

    private final class ScanBox: @unchecked Sendable { var result: Result<[Server], ScanError>? }

    private func apply(_ result: Result<[Server], ScanError>, sequence: Int) {
        guard sequence > appliedSequence else { return }
        appliedSequence = sequence
        loaded = true
        switch result {
        case .success(var list):
            problem = nil
            // 끝난 서버의 로그는 버린다. 나중에 같은 pid를 받은 다른 프로그램에 붙지 않게
            logs = logs.filter { entry in list.contains { $0.id == entry.key } }
            for index in list.indices { list[index].log = logs[list[index].id] }
            if list != servers { servers = list }
        case .failure(let error):
            problem = error.message
        }
    }

    struct ScanError: Error, Sendable { let message: String }

    private nonisolated static func scan() -> Result<[Server], ScanError> {
        // +c0: 프로세스 이름을 9자에서 자르지 않는다 (`next-server`, `GitHub Desktop Helper`)
        // -b -w: 응답 없는 네트워크 드라이브에서 멈추지 않고, 그 경고도 찍지 않는다
        guard let out = run("/usr/sbin/lsof", ["-b", "-w", "-nP", "+c0", "-iTCP", "-sTCP:LISTEN", "-F", "pcnu"]) else {
            return .failure(ScanError(message: "lsof를 실행하지 못해 포트를 읽지 못했습니다"))
        }
        let ports = PortScan.parse(lsof: out)
        guard !ports.isEmpty else { return .success([]) }
        let processes = PortScan.parse(ps: run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="]) ?? "")
        let groups = PortScan.servers(ports, processes: processes, own: Int(getpid())).map { group in
            // 다시 실행할 때 인자 경계를 지키려고 실제 argv를 붙여 둔다
            let withArgv = { (process: PortProcess) -> PortProcess in
                var process = process
                process.argv = arguments(process.pid)
                return process
            }
            return PortServer(root: withArgv(group.root), chain: group.chain.map(withArgv), ports: group.ports)
        }
        let pids = Set(groups.flatMap { [$0.root.pid] + $0.ports.map(\.pid) }).sorted().map(String.init).joined(separator: ",")
        let cwds = PortScan.parse(cwd: run("/usr/sbin/lsof", ["-b", "-w", "-nP", "-a", "-d", "cwd", "-F", "pn", "-p", pids]) ?? "")
        let servers = groups.map { group -> Server in
            let listener = group.listener
            let path = listener.flatMap { executable($0.pid) }
            return Server(group: group, kind: PortScan.kind(name: listener?.command ?? "", path: path),
                          cwd: cwds[group.root.pid] ?? listener.flatMap { cwds[$0.pid] }, uid: listener?.uid ?? -1, path: path,
                          rootStarted: started(group.root.pid))
        }
        return .success(servers)
    }

    nonisolated static func executable(_ pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// 커널에 남은 실행 인자 (KERN_PROCARGS2). ps와 달리 `My Projects`처럼 공백이 든 인자도 하나로 남는다.
    nonisolated static func arguments(_ pid: Int) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        // 앞에 인자 수, 실행 파일 경로와 빈 바이트가 오고 그 뒤에 인자가 NUL로 이어진다
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < count, index < size {
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            result.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return result.count == count ? result : nil
    }

    /// 프로세스 시작 시각(마이크로초). pid가 재사용됐는지 가릴 때 쓴다.
    nonisolated static func started(_ pid: Int) -> UInt64? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size > 0 else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // 읽지 않는 파이프에 경고가 쌓이면 lsof가 멈춘다
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: 시연

    /// 사용법 영상용 예시 서버. pid는 실제 프로세스와 겹치지 않을 큰 값이고, 신호를 보내는 경로는 막혀 있다.
    private static func demoServers() -> [Server] {
        func make(_ pid: Int, _ command: [String], _ cwd: String, _ port: Int, outside: Bool = false) -> Server {
            let root = PortProcess(pid: pid, ppid: 1, command: command.joined(separator: " "), argv: command)
            let listener = ListeningPort(port: port, addresses: [outside ? "*" : "127.0.0.1"], pid: pid + 1, command: "node", uid: Int(getuid()))
            let group = PortServer(root: root, chain: [PortProcess(pid: pid + 1, ppid: pid, command: "node", argv: ["node"]), root], ports: [listener])
            return Server(group: group, kind: .devServer, cwd: cwd, uid: Int(getuid()), path: "/usr/local/bin/node", rootStarted: nil)
        }
        return [
            make(900_100, ["npm", "run", "dev"], "/Users/me/work/shop-web", 5173),
            make(900_200, ["npm", "run", "dev"], "/Users/me/work/admin-web", 3000),
            make(900_300, ["node", "server.js", "--host"], "/Users/me/work/mock-api", 3001, outside: true),
        ]
    }

    /// 시연 장면에서 예시 목록을 바꿔 서버가 꺼지거나 포트가 옮겨 간 모습을 보인다.
    func rehearse(_ change: (inout [Server]) -> Void) {
        guard Self.demo else { return }
        var list = servers
        change(&list)
        servers = list
    }

    /// 예시 서버 하나의 포트를 바꾼다.
    func rehearseMove(from old: Int, to new: Int) {
        rehearse { list in
            guard let index = list.firstIndex(where: { $0.primaryPort == old }) else { return }
            let server = list[index]
            let listener = ListeningPort(port: new, addresses: server.group.ports[0].addresses, pid: server.group.ports[0].pid,
                                         command: "node", uid: server.uid)
            let group = PortServer(root: server.group.root, chain: server.group.chain, ports: [listener])
            list[index] = Server(group: group, kind: server.kind, cwd: server.cwd, uid: server.uid, path: server.path, rootStarted: nil)
        }
    }

    // MARK: 종료

    /// 바깥 실행과 그 아래 프로세스를 모두 끝낸다. 자식만 끄면 `npm run dev`가 남거나 nodemon이 다시 띄운다.
    /// 일반 종료(SIGTERM)는 서버가 정리할 틈을 주고, 강제 종료(SIGKILL)는 바로 끊는다.
    func terminate(_ server: Server, force: Bool, done: @escaping (_ stopped: Bool, _ message: String) -> Void) {
        if let reason = server.lockedReason { return done(false, reason) }
        guard !Self.demo else { return done(false, "시연 모드에서는 끄지 않습니다") }
        guard busy[server.id] == nil else { return }
        busy[server.id] = "종료 중"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (stopped, message) = Self.stop(server, force: force)
            DispatchQueue.main.async {
                self?.busy[server.id] = nil
                self?.refresh()
                done(stopped, message)
            }
        }
    }

    private nonisolated static func stop(_ server: Server, force: Bool) -> (Bool, String) {
        let root = server.group.root
        let processes = PortScan.parse(ps: run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="]) ?? "")
        // 목록을 읽은 뒤 그 pid가 끝나고 다른 프로그램이 같은 번호를 받았을 수 있다
        guard let current = processes.first(where: { $0.pid == root.pid }) else {
            return (true, "\(server.primaryPort)번 포트 서버는 이미 종료됐습니다")
        }
        let same = server.rootStarted.map { $0 == started(root.pid) } ?? (current.command == root.command)
        guard same else {
            return (false, "그사이 프로세스가 바뀌어 종료하지 않았습니다. 목록을 다시 확인하세요")
        }
        let targets = PortScan.descendants(of: root.pid, in: processes) + [root.pid]
        for pid in targets { kill(pid_t(pid), force ? SIGKILL : SIGTERM) }
        let listeners = Set(server.group.ports.map(\.pid))
        // 개발 서버는 끝낼 때 파일 감시·하위 프로세스를 정리하느라 1~2초 걸리기도 한다
        for _ in 0..<40 {
            let alive = listeners.union([root.pid]).contains { kill(pid_t($0), 0) == 0 && !isZombie($0) }
            if !alive || server.ports.allSatisfy(PortRestart.isFree) {
                return (true, "\(server.primaryPort)번 포트 서버를 \(force ? "강제 " : "")종료했습니다")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return (false, force ? "\(server.primaryPort)번 포트 서버가 종료되지 않았습니다"
                : "\(server.primaryPort)번 포트 서버가 4초 안에 종료되지 않았습니다. ‘강제 종료’를 써 보세요")
    }

    /// 끝났지만 부모가 거두지 않은 프로세스. kill(pid, 0)은 이것도 살아 있다고 답한다.
    private nonisolated static func isZombie(_ pid: Int) -> Bool {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 && info.pbi_status == UInt32(SZOMB)
    }

    /// `brew services stop`으로 서비스를 멈춘다. 종료와 달리 launchd가 다시 띄우지 않는다.
    func stopBrewService(_ server: Server, done: @escaping (_ ok: Bool, _ message: String) -> Void) {
        guard !Self.demo else { return done(false, "시연 모드에서는 멈추지 않습니다") }
        guard let name = server.brewService, busy[server.id] == nil else { return }
        busy[server.id] = "멈추는 중"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "brew services stop \"$1\"", "runtime-brew", name]
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            let started = (try? process.run()) != nil
            let message = started ? String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" : ""
            if started { process.waitUntilExit() }
            let ok = started && process.terminationStatus == 0
            DispatchQueue.main.async {
                self?.busy[server.id] = nil
                self?.refresh()
                done(ok, ok ? "\(name) 서비스를 멈췄습니다. 다시 켜려면 터미널에서 brew services start \(name)"
                     : "\(name) 서비스를 멈추지 못했습니다\(message.isEmpty ? "" : ": " + message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    // MARK: 다시 시작

    /// 서버를 끝내고 같은 폴더에서 `port`로 다시 띄운다. 같은 포트를 주면 그대로 다시 시작한다.
    func restart(_ server: Server, to port: Int, done: @escaping (_ ok: Bool, _ message: String, _ log: URL?) -> Void) {
        if let reason = server.lockedReason { return done(false, reason, nil) }
        guard !Self.demo else { return done(false, "시연 모드에서는 다시 시작하지 않습니다", nil) }
        guard busy[server.id] == nil else { return }
        busy[server.id] = "재시작 중"
        let log = Self.logURL(port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let finish: (Bool, String, URL?) -> Void = { ok, message, url in
                DispatchQueue.main.async {
                    self?.busy[server.id] = nil
                    self?.refresh()
                    done(ok, message, url)
                }
            }
            // 화면의 목록은 최대 3초 묵어 있어, 함께 도는 프로세스는 지금 다시 읽어 본다
            let processes = PortScan.parse(ps: Self.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="]) ?? "")
            let plan: PortRestart.Plan
            switch PortRestart.plan(chain: server.group.chain, from: server.primaryPort, to: port, processes: processes) {
            case .success(let found): plan = found
            case .failure(let refusal): return finish(false, refusal.message, nil)
            }
            // 서버를 끄면 폴더와 실행 파일 위치를 더는 알 수 없어 먼저 읽어 둔다
            let cwd = PortScan.parse(cwd: Self.run("/usr/sbin/lsof", ["-b", "-w", "-nP", "-a", "-d", "cwd", "-F", "pn", "-p", String(plan.pid)]) ?? "")[plan.pid]
                ?? server.cwd
            let paths = server.group.chain.compactMap { Self.executable($0.pid) }.map { ($0 as NSString).deletingLastPathComponent }
            guard let cwd, cwd != "/" else { return finish(false, "실행하던 폴더를 알 수 없어 다시 시작하지 못했습니다", nil) }
            // 프로세스 제목만 바꾼 서버(`process.title = "my-api"`)는 원래 명령을 알 수 없다
            if plan.arguments.count == 1, let path = Self.executable(plan.pid),
               PortScan.toolName(plan.arguments[0]) != URL(fileURLWithPath: path).lastPathComponent {
                return finish(false, "이 서버는 프로세스 이름을 바꿔 원래 실행 명령을 알 수 없습니다. 터미널에서 다시 실행하세요", nil)
            }
            let (stopped, message) = Self.stop(server, force: false)
            guard stopped else { return finish(false, message, nil) }
            switch Self.launch(plan.arguments, cwd: cwd, port: port, paths: paths, log: log) {
            case .failure(let error):
                finish(false, error.message, log)
            case .success(let pid):
                DispatchQueue.main.async { self?.logs[pid] = log }
                // 개발 서버는 뜨는 데 몇 초 걸린다. 15초까지 새로 띄운 프로세스가 그 포트를 여는지 본다
                for _ in 0..<60 {
                    if Self.listens(port, under: pid) {
                        return finish(true, port == server.primaryPort ? "\(port)번 포트 서버를 다시 시작했습니다" : "\(port)번 포트로 옮겨 다시 시작했습니다", log)
                    }
                    if kill(pid_t(pid), 0) != 0 || Self.isZombie(pid) { return finish(false, "서버가 시작하자마자 종료됐습니다. 로그를 확인하세요", log) }
                    if !PortRestart.isFree(port), !Self.listens(port, under: pid) {
                        // 그사이 다른 프로그램이 이 포트를 잡았다. vite라면 다음 포트로 옮겨 뜬다
                        Thread.sleep(forTimeInterval: 0.5)
                        if !Self.listens(port, under: pid) {
                            // pm2·redis처럼 스스로 백그라운드로 옮겨 가는 서버일 수도 있어 단정하지 않는다
                            return finish(true, "\(port)번 포트가 열렸습니다. 다시 띄운 서버가 맞는지 목록에서 확인하세요", log)
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                finish(false, plan.method == .environment
                       ? "서버는 실행 중이지만 \(port)번 포트가 열리지 않았습니다. 이 서버는 PORT 환경변수를 읽지 않을 수 있어 목록에서 실제 포트를 확인하세요"
                       : "서버는 실행 중이지만 15초 안에 \(port)번 포트가 열리지 않았습니다. 로그를 확인하세요", log)
            }
        }
    }

    /// `pid`나 그 아래 프로세스가 `port`를 듣는지.
    private nonisolated static func listens(_ port: Int, under pid: Int) -> Bool {
        let owners = Set((run("/usr/sbin/lsof", ["-b", "-w", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]) ?? "")
            .split(separator: "\n").compactMap { Int($0) })
        guard !owners.isEmpty else { return false }
        let tree = Set(PortScan.descendants(of: pid, in: PortScan.parse(ps: run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="]) ?? "")) + [pid])
        return !owners.isDisjoint(with: tree)
    }

    private nonisolated static func logURL(_ port: Int) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunTime/ports-logs/port-\(port).log")
    }

    /// 로그인 셸로 띄워 터미널과 같은 환경을 잡고, 원래 실행 파일이 있던 폴더(nvm의 node 등)를 PATH 앞에 둔다.
    /// 폴더·포트·명령은 셸 인자로 넘겨 따옴표가 섞여도 셸 문장이 깨지지 않게 한다.
    private nonisolated static func launch(_ arguments: [String], cwd: String, port: Int, paths: [String], log: URL) -> Result<Int, ScanError> {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return .failure(ScanError(message: "로그 파일을 만들지 못했습니다")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 명령은 셸이 다시 쪼개지 않게 인자 하나씩 넘긴다. 앞에 붙일 경로가 없으면 PATH 맨 앞에 빈 칸(현재 폴더)이 들어가지 않게 한다
        let prefix = Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
        process.arguments = ["-lc", "cd \"$1\" && export PORT=\"$2\" && { [ -n \"$3\" ] && export PATH=\"$3:$PATH\"; true; } && exec \"${@[4,-1]}\"",
                             "runtime-restart", cwd, String(port), prefix] + arguments
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failure(ScanError(message: "다시 시작하지 못했습니다: \(error.localizedDescription)"))
        }
        return .success(Int(process.processIdentifier))
    }

    nonisolated static func suggestedPort(after port: Int, avoiding taken: Set<Int>) -> Int {
        PortRestart.freePort(from: port + 1, avoiding: taken) ?? port + 1
    }

    // MARK: 같은 와이파이의 휴대폰에서 열기

    /// 이 맥의 사설망 IPv4 주소 (와이파이·유선). 없으면 nil.
    nonisolated static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard text.hasPrefix("192.168.") || text.hasPrefix("10.") || text.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil
            else { continue }
            candidates.append((String(cString: entry.ifa_name), text))
        }
        // VPN(utun)보다 와이파이·유선(en*)을 먼저
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }
}
