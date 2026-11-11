import AppKit

/// Claude Code가 일하던 앱(터미널, 편집기, Orca)을 찾는다. 작업 끝 알림의 '열기'가 그 앱을 앞으로 가져온다.
/// 그 폴더에서 도는 claude 프로세스에서 부모를 따라 올라가 앱을 찾는다. 앱의 도우미 프로세스(Orca Helper,
/// Code Helper)는 앱 목록에 없어서, 실행 파일 경로에서 가장 바깥 .app으로 앱을 고른다.
enum ClaudeHost {
    private struct Process {
        let pid: pid_t
        let parent: pid_t
        let command: String
    }

    /// Claude가 일하던 앱과 작업 폴더 (전체 경로).
    struct Target {
        let app: NSRunningApplication
        let folder: String
    }

    /// `project`는 작업 폴더 이름. 못 찾으면 nil. 프로세스 목록을 읽으니 메인 스레드 밖에서 부른다.
    static func find(project: String) -> Target? {
        let table = processes()
        let claudes = table.values.filter { isClaude($0.command) }.map(\.pid)
        guard !claudes.isEmpty else { return nil }
        let folders = workingDirectories(of: claudes)
        // 같은 폴더에 세션이 여럿이면 나중에 띄운 쪽을 먼저 본다
        let matching = claudes.filter { folders[$0].map { URL(fileURLWithPath: $0).lastPathComponent == project } ?? false }
        for pid in matching.sorted(by: >) {
            if let app = host(of: pid, in: table), let folder = folders[pid] { return Target(app: app, folder: folder) }
        }
        return nil
    }

    /// 앱을 앞으로 가져온다. Orca면 그 폴더에서 Claude가 돌던 터미널 탭으로 먼저 바꾼다. 메인 스레드 밖에서 부른다.
    static func open(_ target: Target) {
        if let (cli, terminal) = orcaTerminal(for: target) { _ = run(cli, ["terminal", "switch", "--terminal", terminal.handle]) }
        DispatchQueue.main.async {
            target.app.unhide()
            target.app.activate(options: [.activateAllWindows])
        }
    }

    private static let orcaID = "com.stablyai.orca"

    private struct OrcaList: Decodable {
        struct Result: Decodable { let terminals: [Terminal] }
        struct Terminal: Decodable {
            let handle: String
            let title: String?
            let worktreePath: String?
            let agentIdentity: String?
            let lastOutputAt: Double?
        }
        let result: Result?
    }

    /// 점검 도구가 고를 Orca 터미널 탭 이름을 읽는다 (바꾸지는 않는다).
    static func orcaTabTitle(for target: Target) -> String? {
        orcaTerminal(for: target).map { $0.1.title ?? $0.1.handle }
    }

    /// Orca면 그 폴더(또는 상위 worktree)의 Claude 터미널 가운데 방금까지 출력한 탭과 CLI 경로.
    private static func orcaTerminal(for target: Target) -> (String, OrcaList.Terminal)? {
        let folder = target.folder
        guard target.app.bundleIdentifier == orcaID,
              let cli = target.app.bundleURL?.appendingPathComponent("Contents/Resources/bin/orca").path,
              FileManager.default.isExecutableFile(atPath: cli),
              let list = try? JSONDecoder().decode(OrcaList.self, from: Data(run(cli, ["terminal", "list", "--json"]).utf8))
        else { return nil }
        let candidates = (list.result?.terminals ?? []).filter { terminal in
            guard let path = terminal.worktreePath else { return false }
            return folder == path || folder.hasPrefix(path + "/")
        }
        let claude = candidates.filter { $0.agentIdentity == "claude" }
        return (claude.isEmpty ? candidates : claude).max(by: { ($0.lastOutputAt ?? 0) < ($1.lastOutputAt ?? 0) })
            .map { (cli, $0) }
    }

    /// 백그라운드 도우미("claude bg-pty-host")는 뺀다.
    private static func isClaude(_ command: String) -> Bool {
        let name = (command as NSString).lastPathComponent
        return name == "claude" || name == "claude.exe"
    }

    private static func host(of start: pid_t, in table: [pid_t: Process]) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        let me = Foundation.ProcessInfo.processInfo.processIdentifier
        var pid = start
        for _ in 0..<40 {
            guard pid > 1, pid != me, let process = table[pid] else { return nil }
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            if let bundle = outermostApp(in: process.command),
               let app = running.first(where: { $0.bundleURL?.standardizedFileURL.path == bundle }) {
                return app
            }
            pid = process.parent
        }
        return nil
    }

    /// "/Applications/Orca.app/Contents/Frameworks/Orca Helper.app/..." → "/Applications/Orca.app"
    private static func outermostApp(in path: String) -> String? {
        guard path.hasPrefix("/"), let range = path.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app").standardizedFileURL.path
    }

    private static func processes() -> [pid_t: Process] {
        var table: [pid_t: Process] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,ppid=,comm="]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let parent = pid_t(parts[1]) else { continue }
            table[pid] = Process(pid: pid, parent: parent, command: String(parts[2]))
        }
        return table
    }

    private static func workingDirectories(of pids: [pid_t]) -> [pid_t: String] {
        let list = pids.map(String.init).joined(separator: ",")
        var folders: [pid_t: String] = [:]
        var current: pid_t?
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
            if line.hasPrefix("n"), let pid = current { folders[pid] = String(line.dropFirst()) }
        }
        return folders
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
