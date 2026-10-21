import AppKit

/// 다른 Mac에서 생긴 문제를 나중에 그 자리에서 볼 수 있게 남기는 기록.
/// 그 Mac의 `~/Library/Logs/RunTime/events.log`에만 쓰고 어디로도 보내지 않는다. 키·토큰·일지 내용은 넣지 않는다.
enum Diagnostics {
    /// 화면 점검은 `RUNTIME_LOG_DIR`로 다른 폴더를 써서 실제 기록을 건드리지 않는다.
    static let directory = ProcessInfo.processInfo.environment["RUNTIME_LOG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/RunTime")
    static let logURL = directory.appendingPathComponent("events.log")
    /// 이보다 커지면 뒤쪽 절반만 남긴다.
    private static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "dev.runtime.diagnostics")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// `2026-10-21 13:40:02 [업데이트] 미룸: …`
    static func record(_ area: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(area)] \(message.replacingOccurrences(of: "\n", with: " "))\n"
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                let size = handle.offsetInFile
                try? handle.close()
                if size > maxBytes, let text = try? String(contentsOf: logURL, encoding: .utf8) {
                    let lines = text.components(separatedBy: "\n")
                    try? lines.suffix(lines.count / 2).joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
                }
            } else {
                try? line.write(to: logURL, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: recorded, object: nil) }
        }
    }

    static let recorded = Notification.Name("RunTimeDiagnosticsRecorded")

    /// 최근 기록 (오래된 것부터).
    static func recent(_ count: Int) -> [String] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(count))
    }

    /// 붙여 넣어 물어볼 수 있는 진단 요약. 이 Mac의 빌드·화면 구성·상태와 최근 기록.
    static func report(updater: AppUpdater = .shared, usage: String? = nil) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = ["RunTime 진단 \(stamp.string(from: Date()))"]
        lines.append("빌드: \(info["RunTimeCommit"] as? String ?? "개발 실행") (\(info["RunTimeBranch"] as? String ?? "-"))"
                     + ((info["RunTimeCommitSubject"] as? String).map { " \($0)" } ?? ""))
        lines.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("업데이트: \(describe(updater.state))" + (updater.blocked.map { " · 미룸: \($0)" } ?? "")
                     + (updater.autoUpdate ? " · 자동" : ""))
        if let usage { lines.append("공식 사용량: \(usage)") }
        lines.append("화면:")
        for screen in NSScreen.screens {
            let f = screen.frame, v = screen.visibleFrame
            lines.append("  \(screen.localizedName) \(Int(f.width))x\(Int(f.height)) @(\(Int(f.minX)),\(Int(f.minY)))"
                         + " 메뉴바 \(Int(f.maxY - v.maxY))pt" + (screen == NSScreen.screens.first ? " · 주 화면" : ""))
        }
        let recent = recent(40)
        lines.append("최근 기록 (\(recent.count)):")
        lines.append(contentsOf: recent.isEmpty ? ["  없음"] : recent.map { "  " + $0 })
        if let failure = (try? String(contentsOf: AppUpdater.logURL, encoding: .utf8)).flatMap(AppUpdater.failureReason(inLog:)) {
            lines.append("마지막 설치 로그의 오류 줄: \(failure)")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ state: AppUpdater.State) -> String {
        switch state {
        case .unavailable(let reason): return "확인 안 함 (\(reason))"
        case .idle: return "대기"
        case .checking: return "확인 중"
        case .upToDate: return "최신"
        case .available(let count, let latest): return "새 커밋 \(count)개 (\(latest))"
        case .updating: return "설치 중"
        case .failed(let reason): return "실패: \(reason)"
        }
    }

    static func copyReport(usage: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(usage: usage), forType: .string)
    }
}
