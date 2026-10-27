import Foundation

/// 업무 일지 파일. 앱과 `--worklog` 명령, Claude가 같은 파일을 읽고 쓴다.
public enum WorkLogFile {
    /// `RUNTIME_WORKLOG`로 다른 파일을 쓰게 할 수 있다 (점검할 때 내 일지를 건드리지 않게).
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["RUNTIME_WORKLOG"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunTime/worklog.json")
    }

    /// 파일이 없으면 빈 일지. 깨진 파일은 덮어쓰지 않게 오류를 낸다.
    public static func load(_ url: URL = defaultURL) throws -> WorkLog {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkLog() }
        return try decode(Data(contentsOf: url))
    }

    public static func save(_ log: WorkLog, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(log).write(to: url, options: .atomic)
    }

    public static func decode(_ data: Data) throws -> WorkLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = fractional.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        return try decoder.decode(WorkLog.self, from: data)
    }

    // 올린 때와 고친 때를 같은 초 안에서도 가리려고 밀리초까지 쓴다
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    public static func encode(_ log: WorkLog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.string(from: date))
        }
        // 사람이 열어 보고 git diff처럼 비교하기 쉽게 줄을 나누고 키 순서를 고정한다
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(log)
    }
}

/// `RunTime --worklog …` 명령. Claude가 JSON을 통째로 읽지 않고 필요한 글만 받게 한다.
public enum WorkLogCommand {
    public struct Result: Equatable {
        public let output: String
        public let changed: Bool
        public let failed: Bool
    }

    public static let usage = """
    RunTime --worklog <명령>
      day [날짜] [--raw]              그날 일일보고 (날짜는 yyyy-MM-dd, 없으면 오늘). --raw면 일감 이름으로 바꾸지 않음
      week [날짜] [--raw]             그 주 주간 보고
      redmine [날짜|week [날짜]]       레드마인에 아직 올리지 않은 진척률과 댓글
      add <프로젝트> <내용> [상태] [#일감] [--day 날짜] [--note 댓글]
                                      상태: 완료, 상시, 60% (없으면 완료)
      import [날짜]                    표준 입력의 보고서 글을 읽어 넣기
      posted <일감번호>... [날짜|week [날짜]]
                                      레드마인에 올린 것으로 표시 (redmine과 같은 범위)
      capture                         GitLab MR과 로컬 커밋을 지금 가져오기
      issues                          나에게 배정된 레드마인 일감과 보고서 이름
      teams-test [report] [me]        팀즈 웹훅으로 시험 카드(report면 오늘 일일보고, me면 나에게) 보내기
      path                            일지 파일 위치
    """

    public static func run(_ args: [String], log: inout WorkLog, today: String = WorkDay.today(), now: Date = Date(),
                           stdin: () -> String = { "" }) -> Result {
        guard let command = args.first else { return Result(output: usage, changed: false, failed: false) }
        // 보고서는 앱처럼 레드마인 일감 이름으로 쓰고 QA는 건수로 모은다. --raw면 적은 그대로
        let byIssue = !args.contains("--raw")
        let rest = Array(args.dropFirst()).filter { $0 != "--raw" }
        func dayArg(_ value: String?) -> String? {
            guard let value else { return today }
            return WorkDay.isValid(value) ? value : nil
        }
        func fail(_ message: String) -> Result { Result(output: message, changed: false, failed: true) }

        switch command {
        case "day":
            guard let day = dayArg(rest.first) else { return fail("날짜는 yyyy-MM-dd로 적습니다") }
            let text = WorkReport.daily(log.entries(on: day), in: log, doneFirst: true, byIssue: byIssue)
            return Result(output: text.isEmpty ? "\(day) 기록 없음" : text, changed: false, failed: false)

        case "week":
            guard let day = dayArg(rest.first) else { return fail("날짜는 yyyy-MM-dd로 적습니다") }
            let week = WorkDay.week(of: day)
            let text = WorkReport.weekly(log.entries(in: week), in: log, week: week, doneFirst: true, byIssue: byIssue)
            return Result(output: text.isEmpty ? "\(week.lowerBound) 주 기록 없음" : text, changed: false, failed: false)

        case "redmine":
            let entries: [WorkEntry]
            if rest.first == "week" {
                guard let day = dayArg(rest.dropFirst().first) else { return fail("날짜는 yyyy-MM-dd로 적습니다") }
                entries = log.entries(in: WorkDay.week(of: day))
            } else {
                guard let day = dayArg(rest.first) else { return fail("날짜는 yyyy-MM-dd로 적습니다") }
                entries = log.entries(on: day)
            }
            // 앱 설정의 댓글 꼴을 따른다 (기본 HTML: 평문 줄바꿈은 레드마인 웹 편집기에서 한 줄로 붙는다)
            let html = UserDefaults.standard.object(forKey: "workLog.redmineHTML") as? Bool ?? true
            let text = WorkReport.redmineRequest(WorkReport.redmineUpdates(entries.filter(\.needsRedmine), log: log), html: html)
            return Result(output: text.isEmpty ? "올릴 일감 없음" : text, changed: false, failed: false)

        case "add":
            return add(rest, log: &log, today: today, now: now)

        case "import":
            guard let day = dayArg(rest.first) else { return fail("날짜는 yyyy-MM-dd로 적습니다") }
            let entries = WorkReport.parse(stdin(), day: day, now: now)
            guard !entries.isEmpty else { return fail("읽은 줄이 없습니다. `1. 프로젝트` 아래 `- 내용 (완료)` 꼴인지 보세요") }
            for entry in entries { log.register(project: entry.project) }
            log.entries += entries
            return Result(output: "\(day)에 \(entries.count)줄 넣음", changed: true, failed: false)

        case "posted":
            // redmine에서 보여 준 범위의 줄만 표시해, 아직 안 올린 다른 날 줄이 빠지지 않게 한다
            var issues = Set<Int>(), scopeWords: [String] = []
            for arg in rest {
                if let number = Int(arg.hasPrefix("#") ? String(arg.dropFirst()) : arg) { issues.insert(number) }
                else { scopeWords.append(arg) }
            }
            guard !issues.isEmpty else { return fail("일감 번호를 적습니다") }
            let days: ClosedRange<String>
            if scopeWords.first == "week" {
                guard let day = dayArg(scopeWords.dropFirst().first) else { return fail("날짜는 yyyy-MM-dd로 적습니다") }
                days = WorkDay.week(of: day)
            } else {
                guard let day = dayArg(scopeWords.first) else { return fail("날짜는 yyyy-MM-dd로 적습니다") }
                days = day...day
            }
            var count = 0
            for index in log.entries.indices where days.contains(log.entries[index].day) {
                if let issue = log.entries[index].issue, issues.contains(issue), log.entries[index].needsRedmine {
                    log.entries[index].postedAt = now
                    count += 1
                }
            }
            return Result(output: "\(count)줄을 올림으로 표시", changed: count > 0, failed: false)

        case "path":
            return Result(output: WorkLogFile.defaultURL.path, changed: false, failed: false)

        default:
            return fail(usage)
        }
    }

    private static func add(_ args: [String], log: inout WorkLog, today: String, now: Date) -> Result {
        var day = today, note = "", plain: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if (arg == "--day" || arg == "--note"), index + 1 < args.count {
                if arg == "--day" { day = args[index + 1] } else { note = args[index + 1].replacingOccurrences(of: "\\n", with: "\n") }
                index += 2
                continue
            }
            plain.append(arg)
            index += 1
        }
        guard WorkDay.isValid(day) else { return Result(output: "날짜는 yyyy-MM-dd로 적습니다", changed: false, failed: true) }
        guard plain.count >= 2 else { return Result(output: usage, changed: false, failed: true) }
        var status = WorkStatus.done, issue: Int?, words = [plain[1]]
        for extra in plain.dropFirst(2) {
            if extra.hasPrefix("#"), let number = Int(extra.dropFirst()) { issue = number }
            else if let parsed = WorkStatus(label: extra) { status = parsed }
            else { words.append(extra) }   // 따옴표 없이 쓴 내용도 버리지 않는다
        }
        let split = WorkReport.splitIssue(words.joined(separator: " "))
        let entry = WorkEntry(day: day, project: plain[0], title: split.title, status: status,
                              issue: issue ?? split.issue, note: note, updatedAt: now)
        log.register(project: entry.project)
        log.entries.append(entry)
        return Result(output: "\(day) \(entry.project): \(WorkReport.line(entry))", changed: true, failed: false)
    }
}
