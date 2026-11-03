import Darwin
import Foundation
import ReportCore

/// 앱이 죽으면 다음에 켤 때 macOS가 남긴 충돌 보고서(`.ips`)를 읽어 만든 사람에게 알린다.
/// `fatalError`와 ObjC 예외의 까닭은 충돌 보고서에 없고 stderr에만 찍혀서, 켤 때마다 stderr를 기록 폴더의 파일로 돌려 둔다.
enum CrashReports {
    static let seenKey = "crashReportSeen"
    /// 보낸 충돌 보고서의 사건 ID와 보낸 때. 파일이 다시 저장돼 수정 시각이 바뀌어도 두 번 보내지 않는다.
    static let sentKey = "crashReportsSent"
    /// 서버가 모양이 틀렸다고 거절한 날. 그날은 그 종류를 다시 보내지 않는다. 뒤에 종류 이름이 붙는다.
    static let rejectedKey = "reportRejectedDay."
    static let reportsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/DiagnosticReports")
    /// `<pid>-<켠 시각>.log`. 충돌 보고서의 pid와 시각으로 그 실행의 출력을 찾는다.
    static let outputDirectory = Diagnostics.directory.appendingPathComponent("output")
    private static let outputLimit: off_t = 2 * 1024 * 1024
    private static let keepDays: TimeInterval = 7 * 86_400
    private static var trimTimer: Timer?
    /// 비운 뒤에도 커밋을 알 수 있게 다시 쓰는 머리줄.
    private static var header = ""

    private static var isInstalled: Bool { Bundle.main.infoDictionary?["RunTimeCommitSHA"] != nil }

    /// 메뉴바 앱으로 켤 때만 부른다. 터미널에서 켰으면 출력이 그대로 보이게 둔다.
    static func captureOutput() {
        guard isInstalled, isatty(STDERR_FILENO) == 0 else { return }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        removeOld()
        let url = outputDirectory.appendingPathComponent("\(getpid())-\(Int(Date().timeIntervalSince1970)).log")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
        let info = Bundle.main.infoDictionary ?? [:]
        header = "RunTime pid=\(getpid()) commit=\(info["RunTimeCommitSHA"] as? String ?? "") version=\(info["CFBundleShortVersionString"] as? String ?? "") build=\(info["CFBundleVersion"] as? String ?? "")\n"
        fputs(header, stderr)
        // 오래 켜 두는 앱이라 시스템 경고가 쌓여도 기록 폴더를 채우지 않게 가끔 비운다
        trimTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            guard lseek(STDERR_FILENO, 0, SEEK_END) > outputLimit else { return }
            ftruncate(STDERR_FILENO, 0)
            fputs(header, stderr)
        }
    }

    private static func removeOld() {
        let files = (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where (modified(file) ?? .distantPast) < Date(timeIntervalSinceNow: -keepDays) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// 지난번에 알린 뒤 생긴 이 앱의 가장 최근 충돌과, 그보다 먼저 죽은 횟수. 처음에는 최근 일주일만 본다.
    /// 보고서가 수백 KB라 맞는 것 하나를 찾을 때까지만 읽는다.
    static func newestUnseen() -> (url: URL, date: Date, report: CrashReport, others: Int)? {
        let seen = UserDefaults.standard.object(forKey: seenKey) as? Date ?? Date(timeIntervalSinceNow: -keepDays)
        let sent = UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Date] ?? [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix("RunTime-") && $0.pathExtension == "ips" }
            .compactMap { url in modified(url).map { (url, $0) } }
            .filter { $0.1 > seen }
            .sorted { $0.1 > $1.1 }
        for (index, (url, date)) in candidates.enumerated() {
            // swift run(.build 아래 실행 파일)으로 켠 것이 죽은 것은 빼고 .app으로 켠 것만
            guard let text = try? String(contentsOf: url, encoding: .utf8), let report = CrashReport(ips: text),
                  report.appName == "RunTime", report.procPath.hasSuffix(".app/Contents/MacOS/RunTime"),
                  report.incident.isEmpty || sent[report.incident] == nil else { continue }
            return (url, date, report, candidates.count - index - 1)
        }
        return nil
    }

    /// 죽은 실행이 stderr에 남긴 출력. pid는 일주일이면 다시 쓰여서, 켠 시각까지 맞는 파일만 쓴다.
    /// 터미널에서 켜 출력을 남기지 않은 실행이 다른 실행의 출력과 커밋을 달고 나가지 않게 한다.
    static func output(pid: Int?, launched: Date?) -> String {
        guard let pid, let launched else { return "" }
        let files = (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
        let file = files.first { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 2, Int(parts[0]) == pid, let time = Int(parts[1]) else { return false }
            return abs(Double(time) - launched.timeIntervalSince1970) < 10
        }
        return file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// 보낼 본문의 칸들. 커밋은 그 실행이 남긴 머리줄에서 읽고, 없으면 지금 빌드와 버전·빌드 번호가 같을 때만 지금 커밋을 쓴다.
    static func draft(_ report: CrashReport, others: Int)
        -> (message: String, detail: String, app: String, commit: String, log: String) {
        let printed = output(pid: report.pid, launched: CrashReport.date(report.procLaunch))
        let fatal = CrashReport.fatalLines(printed)
        let info = Bundle.main.infoDictionary ?? [:]
        let header = printed.components(separatedBy: "\n").first ?? ""
        let commit = header.range(of: #"commit=[0-9a-f]{40}"#, options: .regularExpression)
            .map { String(header[$0].dropFirst("commit=".count)) }
            ?? (report.appVersion == info["CFBundleShortVersionString"] as? String && report.buildVersion == info["CFBundleVersion"] as? String
                ? info["RunTimeCommitSHA"] as? String ?? "" : "")
        let more = others > 0 ? "지난번에 알린 뒤 이 충돌 말고도 \(others)번 더 죽음\n" : ""
        let detail = more + report.detail(fatal: fatal, limit: 1900)
        let events = CrashReport.events((try? String(contentsOf: Diagnostics.logURL, encoding: .utf8)) ?? "", before: report.captureTime)
        return (report.summary(fatal: fatal), detail, report.appVersion, commit, (["[죽기 전 기록]"] + events).joined(separator: "\n"))
    }

    private static func markSent(_ incident: String, date: Date) {
        UserDefaults.standard.set(date, forKey: seenKey)
        guard !incident.isEmpty else { return }
        var sent = (UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Date] ?? [:])
            .filter { $0.value > Date(timeIntervalSinceNow: -2 * keepDays) }
        sent[incident] = Date()
        UserDefaults.standard.set(sent, forKey: sentKey)
    }

    private static var today: String { CrashReport.day(Date()) }
    static func rejectedToday(_ kind: ProblemReporter.Kind) -> Bool {
        UserDefaults.standard.string(forKey: rejectedKey + kind.rawValue) == today
    }
    static func markRejected(_ kind: ProblemReporter.Kind) { UserDefaults.standard.set(today, forKey: rejectedKey + kind.rawValue) }

    /// 켜자마자 다시 죽는 경우도 알리게 잠깐만 기다린 뒤, 가장 최근 충돌 하나만 보낸다. 서버가 1분에 두 건까지만 받아서다.
    /// 서버가 받았을 때만 본 것으로 적어, 망이 없거나 서버가 아직 이 종류를 모를 때 죽은 것은 다음에 켤 때 다시 보낸다.
    static func sendNew(after delay: TimeInterval = 5) {
        guard isInstalled, ProblemReporter.isOn, !rejectedToday(.crash) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            guard let newest = newestUnseen() else { return }
            let body = draft(newest.report, others: newest.others)
            DispatchQueue.main.async {
                Diagnostics.record("문제 보고", "지난 실행이 죽음: \(body.message)")
                ProblemReporter.send(.crash, body.message, detail: body.detail, app: body.app, commit: body.commit, log: body.log) { status in
                    if status == 200 { markSent(newest.report.incident, date: newest.date) }
                    if status == 400 { markRejected(.crash) }
                }
            }
        }
    }
}
