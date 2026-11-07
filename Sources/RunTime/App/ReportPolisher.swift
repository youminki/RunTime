import Foundation
import WorkLogCore

/// 보고서를 사내 보고 꼴로 다듬는다. 이 Mac의 Claude Code(`claude -p`)를 내 로그인으로 부른다.
/// 결과는 고쳐 쓸 수 있는 초안으로만 쓰고 어디에도 올리지 않는다.
enum ReportPolisher {
    enum Failure: LocalizedError {
        case noClaude, timedOut, failed(String), malformed

        var errorDescription: String? {
            switch self {
            case .noClaude: return "Claude Code(claude)를 찾지 못했습니다. 터미널에서 claude가 실행되는지 확인하세요"
            case .timedOut: return "Claude가 제한 시간 안에 답하지 않았습니다"
            case .failed(let message): return "Claude가 다듬지 못했습니다: \(message)"
            case .malformed: return "Claude가 보고서 꼴이 아닌 글을 돌려줘 쓰지 않았습니다"
            }
        }
    }

    /// 메뉴 경로·건수·상태는 일지와 레드마인에서 온 값이라 바꾸지 않게 한다.
    static let instructions = """
    너는 사내 일일보고를 다듬는 도구다. 받은 보고서를 같은 꼴로 더 짧게 고쳐 그 글만 출력한다. 설명, 인사, 코드 블록은 쓰지 않는다.

    꼴:
    1. 프로젝트 이름
    - 항목 (상태)

    규칙:
    - 프로젝트 줄(`1. 이름`)과 그 순서, 이름은 그대로 둔다.
    - 항목은 20자 안팎의 명사형으로 쓴다. 예: `데이터 마트 API 연동`, `배포 설정 수정`, `캐시 문제 설정 확인`.
    - 같은 주제의 항목은 한 줄로 묶어 한 단계 위의 말로 쓴다. 예: 게이트웨이 주소·환경변수 여러 줄 → `배포 환경 설정 변경`.
    - `A > B 일`처럼 메뉴 경로가 있는 줄, `QA 수정사항 N건 반영`, `안정화 이슈 N건 처리` 줄은 글자 하나 바꾸지 않는다.
    - 메뉴 이름, 기능 이름을 새로 지어내지 않는다.
    - 상태 괄호는 원래 값을 쓴다. 묶은 줄은 가장 덜 된 상태를 쓴다. 없는 상태를 만들지 않는다.
    - 문장형(`~던 것 수정`, `~한다`)은 명사형(`~ 겹침 수정`)으로 바꾼다.
    - 보고서에 없는 일을 더하거나 숫자를 바꾸지 않는다.
    """

    private static let queue = DispatchQueue(label: "dev.runtime.report-polisher")

    /// `done`은 메인 스레드에서 부른다.
    static func polish(_ report: String, done: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result = Result { try run(report) }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// 셸을 읽는 데 1~2초 걸려 한 번 찾은 값을 둔다. `queue`에서만 읽고 쓴다.
    private static var cachedEnvironment: (path: String, claude: String?)?

    private static func run(_ report: String) throws -> String {
        // 도구·MCP·설정 파일(훅)을 끄고 이 지시만으로 한 번 답하게 한다. 줄을 묶고 줄이는 일이라 가벼운 모델로 충분하고
        // (같은 보고서로 견줘 결과가 같았다) 사용량은 sonnet의 15분의 1쯤이다
        // 프로젝트 폴더에서 돌면 그 CLAUDE.md를 읽어 꼴이 흔들린다. 빈 폴더에서 돌린다
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RunTimeReportPolish")
        let text = try ask(report, system: instructions, model: "haiku", folder: folder)
        guard WorkReport.keepsShape(original: report, polished: text) else { throw Failure.malformed }
        return text
    }

    /// `queue`에서 다른 일을 하지 않고 한 번 묻는다. `done`은 메인 스레드에서 부른다.
    static func request(_ input: String, system: String, model: String, tools: [String] = [], folder: URL,
                        timeout: TimeInterval = 90, done: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result = Result { try ask(input, system: system, model: model, tools: tools, folder: folder, timeout: timeout) }
            DispatchQueue.main.async { done(result) }
        }
    }

    private static func ask(_ report: String, system: String, model: String, tools: [String] = [], folder: URL,
                            timeout: TimeInterval = 90) throws -> String {
        // claude가 stdin을 읽기 전에 끝나면 닫힌 파이프에 쓰다 SIGPIPE로 앱이 죽는다. 오류로만 받게 한다
        signal(SIGPIPE, SIG_IGN)
        let found = cachedEnvironment?.claude.map { FileManager.default.isExecutableFile(atPath: $0) } == true
            ? cachedEnvironment : loginEnvironment()
        guard let shell = found, let claude = shell.claude else { throw Failure.noClaude }
        cachedEnvironment = shell
        let deadline = Date().addingTimeInterval(timeout)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        let list = tools.joined(separator: ",")
        process.arguments = ["-p", "--model", model, "--tools", list] + (tools.isEmpty ? [] : ["--allowedTools", list])
            + ["--strict-mcp-config", "--setting-sources", "", "--no-session-persistence", "--output-format", "text",
               "--system-prompt", system]
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = shell.path
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try? input.fileHandleForWriting.write(contentsOf: Data(report.utf8))
        try? input.fileHandleForWriting.close()
        // 출력을 끝까지 읽어야 파이프가 차서 멈추지 않는다
        var outData = Data(), errData = Data()
        let reading = DispatchGroup()
        for (pipe, isOut) in [(output, true), (errors, false)] {
            reading.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = data } else { errData = data }
                reading.leave()
            }
        }
        if reading.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut {
            process.terminate()
            // 자식(node)이 파이프를 쥐고 있어도 읽던 스레드가 풀리게 닫는다
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            throw Failure.timedOut
        }
        // 출력을 닫고도 끝나지 않으면 직렬 큐가 막혀 다음 다듬기가 모두 멈춘다
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            throw Failure.timedOut
        }
        let text = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(String((message.isEmpty ? text : message).prefix(200)))
        }
        return text
    }

    /// 로그인 셸의 PATH와 그 안의 claude. 메뉴바 앱은 터미널의 PATH를 물려받지 않고,
    /// nvm으로 깐 claude는 `.zshrc`에서 PATH에 들어가며 node를 PATH에서 찾아 대화형 로그인 셸(-i -l)로 읽는다.
    /// 셸 설정이 다른 글을 찍어도 섞이지 않게 표시를 붙여 찍고, 셸이 멈추면 15초 뒤 흔한 설치 자리를 본다.
    /// 작업 제어(+m)를 끈다. 켜 두면 터미널에서 `--worklog polish`로 부를 때 셸이 터미널을 가져가 이 프로세스의 출력이 막힌다.
    /// 로그인 셸의 PATH (메뉴바 앱은 터미널 PATH를 물려받지 않는다). 펫 만들기가 codex를 찾을 때도 쓴다.
    /// 로그인 셸에서 찾은 claude. 펫 그림 스크립트가 옆모습을 고를 때 쓴다.
    static func claudePath() -> String? { loginEnvironment()?.claude }

    static func loginPath() -> String {
        loginEnvironment()?.path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    }

    private static func loginEnvironment() -> (path: String, claude: String?)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-i", "-l", "+m", "-c", "printf 'RUNTIME_PATH=%s\\n' \"$PATH\"; printf 'RUNTIME_CLAUDE=%s\\n' \"$(command -v claude)\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var lines: [String] = []
        if (try? process.run()) != nil {
            var data = Data()
            let reading = DispatchGroup()
            reading.enter()
            DispatchQueue.global().async {
                data = output.fileHandleForReading.readDataToEndOfFile()
                reading.leave()
            }
            // 시간을 넘기면 읽던 값을 건드리지 않고(읽기 스레드가 아직 쓸 수 있다) 흔한 설치 자리로 간다
            if reading.wait(timeout: .now() + 15) == .timedOut {
                process.terminate()
                try? output.fileHandleForReading.close()
            } else {
                process.waitUntilExit()
                lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            }
        }
        func value(_ key: String) -> String? {
            lines.last { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let claude = ([value("RUNTIME_CLAUDE=")].compactMap { $0 } + fallback).first { FileManager.default.isExecutableFile(atPath: $0) }
        let path = value("RUNTIME_PATH=") ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        // claude가 있는 폴더(nvm이면 node도 거기 있다)를 PATH 앞에 둔다
        let folder = claude.map { ($0 as NSString).deletingLastPathComponent }
        return (folder.map { "\($0):\(path)" } ?? path, claude)
    }
}
