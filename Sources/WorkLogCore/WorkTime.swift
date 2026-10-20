import Foundation

/// Claude Code를 쓴 시간으로 일감별 작업 시간을 어림한다.
/// 줄의 출처(`mr:velox/velox-web-portal!14`)에서 저장소 이름을 뽑아, 같은 이름 폴더에서 쓴 시간을 그날 그 저장소 일감들에 고르게 나눈다.
public enum WorkTime {
    /// `mr:velox/velox-web-portal!14`, `branch:velox/velox-web-portal:feat/x` → `velox-web-portal`
    public static func repository(of source: String?) -> String? {
        guard let source else { return nil }
        let body: Substring
        if source.hasPrefix("mr:") {
            body = source.dropFirst(3).split(separator: "!").first ?? ""
        } else if source.hasPrefix("branch:") {
            body = source.dropFirst(7).split(separator: ":").first ?? ""
        } else {
            return nil
        }
        return body.split(separator: "/").last.map(String.init)
    }

    /// 일감 번호 → 아직 남기지 않은 어림 시간. 그날 같은 일감에 이미 남긴 시간은 뺀다 (두 번 남기지 않게).
    public static func remaining(_ entries: [WorkEntry], minutesByFolder: [String: Int]) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for (issue, total) in suggest(entries, minutesByFolder: minutesByFolder) {
            let logged = entries.filter { $0.issue == issue && $0.timeLogged }.compactMap(\.hours).reduce(0, +)
            let left = ((total - logged) * 4).rounded(.down) / 4
            if left >= 0.25 { result[issue] = left }
        }
        return result
    }

    /// Claude Code 폴더 이름이 저장소 이름과 맞는지. worktree(`velox-web-portal-feat`)도 같은 저장소로 본다.
    static func minutes(for repo: String, in minutesByFolder: [String: Int]) -> Int {
        minutesByFolder.filter { folder, _ in
            folder == repo || folder.hasPrefix(repo + "-") || folder.hasPrefix(repo + "_") || folder.hasPrefix(repo + ".")
        }.values.reduce(0, +)
    }

    /// 일감 번호 → 어림한 시간(시간, 0.25 단위). 폴더별 분은 그날 Claude Code 기록에서 온다.
    public static func suggest(_ entries: [WorkEntry], minutesByFolder: [String: Int]) -> [Int: Double] {
        var issuesByRepo: [String: Set<Int>] = [:]
        for entry in entries {
            guard let issue = entry.issue, let repo = repository(of: entry.source) else { continue }
            issuesByRepo[repo, default: []].insert(issue)
        }
        var result: [Int: Double] = [:]
        for (repo, issues) in issuesByRepo {
            let minutes = minutes(for: repo, in: minutesByFolder)
            guard minutes > 0 else { continue }
            let share = Double(minutes) / 60 / Double(issues.count)
            let rounded = max(0.25, (share * 4).rounded() / 4)
            for issue in issues { result[issue, default: 0] += rounded }
        }
        return result
    }

    /// `1.5` → `1.5h`, `0.25` → `0.25h`
    public static func label(_ hours: Double) -> String {
        let text = hours == hours.rounded() ? String(Int(hours)) : String(format: "%g", hours)
        return text + "h"
    }
}
