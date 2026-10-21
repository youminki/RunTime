import Foundation

/// GitLab에서 머지된 내 MR과 로컬 커밋을 업무 일지 줄로 바꾼다.
/// 머지된 MR은 완료, 아직 MR이 머지되지 않은 브랜치의 커밋은 진행중으로 적는다.
/// MR 설명이 이미 레드마인 댓글 꼴([작업 내용] …)이라 그대로 댓글로 쓴다.
public enum WorkCapture {

    public struct MergedMR: Equatable {
        /// `velox/velox-web-portal`
        public let path: String
        public let iid: Int
        public let title: String
        public let description: String
        public let sourceBranch: String
        public let mergedAt: Date
        public let webURL: String

        public init(path: String, iid: Int, title: String, description: String, sourceBranch: String,
                    mergedAt: Date, webURL: String = "") {
            self.path = path
            self.iid = iid
            self.title = title
            self.description = description
            self.sourceBranch = sourceBranch
            self.mergedAt = mergedAt
            self.webURL = webURL
        }

        var source: String { "mr:\(path)!\(iid)" }
    }

    public struct Commit: Equatable {
        public let path: String
        public let branch: String
        public let subject: String
        public let date: Date

        public init(path: String, branch: String, subject: String, date: Date) {
            self.path = path
            self.branch = branch
            self.subject = subject
            self.date = date
        }
    }

    // MARK: 읽기

    /// `glab api merge_requests?...` 응답.
    public static func parseMRs(_ data: Data) throws -> [MergedMR] {
        struct Raw: Decodable {
            struct References: Decodable { let full: String? }
            let iid: Int
            let title: String
            let description: String?
            let source_branch: String
            let merged_at: String?
            let web_url: String?
            let references: References?
        }
        let raws: [Raw]
        do {
            raws = try JSONDecoder().decode([Raw].self, from: data)
        } catch {
            // glab api --paginate는 쪽마다 배열을 이어 붙여 낸다 (`[...][...]`)
            let joined = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: #"\]\s*\["#, with: ",", options: .regularExpression)
            raws = try JSONDecoder().decode([Raw].self, from: Data(joined.utf8))
        }
        return raws.compactMap { raw in
            guard let merged = raw.merged_at.flatMap(parseDate),
                  let full = raw.references?.full, let bang = full.lastIndex(of: "!") else { return nil }
            return MergedMR(path: String(full[..<bang]), iid: raw.iid, title: raw.title,
                            description: raw.description ?? "", sourceBranch: raw.source_branch,
                            mergedAt: merged, webURL: raw.web_url ?? "")
        }
    }

    /// git log 꼴. 줄마다 `ref \u{1F} 제목 \u{1F} 날짜(ISO)`.
    /// `--since`가 커미터 날짜로 거르므로 날짜도 커미터 날짜를 쓴다 (리베이스한 커밋이 지난날로 가지 않게).
    public static let gitLogFormat = "%S%x1f%s%x1f%cI"

    public static func parseCommits(_ text: String, path: String) -> [Commit] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let date = parseDate(fields[2]), let branch = branchName(fields[0]),
                  !isHousekeeping(fields[1]) else { return nil }
            return Commit(path: path, branch: branch, subject: fields[1], date: date)
        }
    }

    /// 보고할 일이 아닌 커밋 (chore·docs·ci·style·test·build·revert, Merge).
    static func isHousekeeping(_ subject: String) -> Bool {
        subject.hasPrefix("Merge ")
            || subject.range(of: #"^(chore|docs|ci|style|test|build|revert)(\([^)]*\))?!?:"#, options: .regularExpression) != nil
    }

    /// 이미 머지된 커밋을 빼려고 쓰는 공용 브랜치. `refs/remotes/origin/dev` 꼴 목록에서 고른다.
    public static func sharedBranches(_ refs: [String]) -> [String] {
        let names: Set<String> = ["main", "master", "dev", "develop", "development", "release", "staging", "stage", "prod", "production"]
        return refs.filter { ref in
            guard ref.hasPrefix("refs/remotes/"), let name = branchName(ref) else { return false }
            return names.contains(name) || name.hasPrefix("release/")
        }
    }

    /// `refs/remotes/origin/feat/x` → `feat/x`. 태그는 건너뛴다.
    static func branchName(_ ref: String) -> String? {
        if ref.hasPrefix("refs/tags/") { return nil }
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        if ref.hasPrefix("refs/remotes/") {
            let rest = ref.dropFirst("refs/remotes/".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let name = String(rest[rest.index(after: slash)...])
            return name == "HEAD" ? nil : name
        }
        return ref.isEmpty || ref == "HEAD" ? nil : ref
    }

    /// `https://git.example.com/velox/velox-web-portal.git`, `git@git.example.com:velox/x.git` → `velox/velox-web-portal`.
    public static func namespacePath(remote: String, host: String) -> String? {
        guard let range = remote.range(of: host) else { return nil }
        var path = String(remote[range.upperBound...])
        while let first = path.first, first == ":" || first == "/" { path.removeFirst() }
        if path.hasPrefix("~") { return nil }
        // 포트가 붙은 주소(host:8443/...)
        if let first = path.split(separator: "/").first, Int(first) != nil { path = path.split(separator: "/").dropFirst().joined(separator: "/") }
        if path.hasSuffix(".git") { path.removeLast(4) }
        if path.hasSuffix("/") { path.removeLast() }
        return path.contains("/") ? path : nil
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: 다듬기

    /// `feat(destination): 수정 화면 연결` → `수정 화면 연결`, `Resolve "QA 반영"` → `QA 반영`.
    public static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["Draft:", "WIP:", "[Draft]"] where title.hasPrefix(prefix) {
            title = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        if title.hasPrefix("Resolve \""), title.hasSuffix("\"") {
            title = String(title.dropFirst("Resolve \"".count).dropLast())
        }
        if let range = title.range(of: #"^[A-Za-z]+(\([^)]*\))?!?:\s*"#, options: .regularExpression) {
            title.removeSubrange(range)
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// 제목·설명의 `#1234`, 브랜치의 `feature/12345-x`, `fix/#1234`.
    /// 브랜치의 맨숫자는 QA 시트 번호(`qa-1020`)와 헷갈려 다섯 자리 이상만 일감으로 본다.
    public static func issueNumber(in texts: [String], branch: String? = nil) -> Int? {
        for text in texts {
            if let range = text.range(of: #"#\d{3,7}"#, options: .regularExpression) {
                return Int(text[range].dropFirst())
            }
        }
        guard let branch,
              let range = branch.range(of: #"#\d{3,7}|(^|[/_-])\d{5,7}([/_-]|$)"#, options: .regularExpression) else { return nil }
        return Int(branch[range].filter(\.isNumber))
    }

    /// GitLab 묶음 이름으로 보고서 프로젝트를 정한다. 이름을 바꿔 둔 게 있으면 그것을, 대소문자만 다른 프로젝트가 있으면 그것을 쓴다.
    public static func projectName(for path: String, in log: inout WorkLog) -> String {
        let group = String(path.split(separator: "/").first ?? Substring(path))
        if let alias = log.aliases[group] { return alias }
        if let match = log.projects.first(where: { $0.lowercased() == group.lowercased() }) {
            log.aliases[group] = match
            return match
        }
        // 처음 보는 묶음도 적어 두어, 나중에 프로젝트 이름을 바꾸면 따라가게 한다
        log.aliases[group] = group
        return group
    }

    // MARK: 일지에 넣기

    /// 넣거나 고친 줄 수. 사용자가 고친 제목·댓글은 덮어쓰지 않는다.
    @discardableResult
    public static func apply(mrs: [MergedMR], commits: [Commit], to log: inout WorkLog, now: Date = Date()) -> Int {
        var changed = 0
        let known = Set(log.entries.compactMap(\.source))

        for mr in mrs.sorted(by: { $0.mergedAt < $1.mergedAt }) {
            if known.contains(mr.source) {
                changed += refresh(mr, in: &log, now: now)
                continue
            }
            let day = WorkDay.key(mr.mergedAt)
            guard !log.dismissed.contains(day + "|" + mr.source) else { continue }
            let branchSource = "branch:\(mr.path):\(mr.sourceBranch)"
            let title = cleanTitle(mr.title)
            // 같은 브랜치로 앞서 적힌 줄의 일감 번호를 이어받는다
            let earlierIssue = log.entries.last { $0.source == branchSource && $0.issue != nil }?.issue
            let issue = issueNumber(in: [mr.title, mr.description], branch: mr.sourceBranch) ?? earlierIssue
            // MR 설명은 리뷰어용 글이라 레드마인 댓글 꼴로 다듬는다 (tidyMRNotes). 일감이 여럿이면 일감마다 줄을 나눈다
            let raw = mr.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = log.entries.firstIndex(where: { $0.source == branchSource && $0.day == day }) {
                // 같은 날 진행중이던 브랜치 줄을 완료로 바꾼다
                var entry = log.entries[index]
                let untouched = entry.autoNote != nil && entry.note == entry.autoNote
                entry.source = mr.source
                entry.status = .done
                if untouched {
                    entry.title = title
                    entry.note = raw
                    entry.autoNote = nil
                }
                entry.mrBody = raw
                if entry.issue == nil { entry.issue = issue }
                entry.updatedAt = now
                log.entries[index] = entry
            } else {
                let project = projectName(for: mr.path, in: &log)
                log.register(project: project)
                log.entries.append(WorkEntry(day: day, project: project, title: title, status: .done, issue: issue,
                                             note: raw, updatedAt: now, source: mr.source, mrBody: raw))
            }
            changed += 1
        }

        // MR로 머지된 커밋은 MR 줄에 들어 있으니 뺀다
        let mergedAt = Dictionary(mrs.map { ("\($0.path):\($0.sourceBranch)", $0.mergedAt) }, uniquingKeysWith: max)
        let pending = commits.filter { commit in
            guard let merged = mergedAt["\(commit.path):\(commit.branch)"] else { return true }
            return commit.date > merged
        }
        var groups: [String: [Commit]] = [:]
        var order: [String] = []
        for commit in pending.sorted(by: { $0.date < $1.date }) {
            let key = WorkDay.key(commit.date) + "\u{1F}" + commit.path + "\u{1F}" + commit.branch
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(commit)
        }
        for key in order {
            guard let group = groups[key], let first = group.first else { continue }
            let day = WorkDay.key(first.date)
            let source = "branch:\(first.path):\(first.branch)"
            guard !log.dismissed.contains(day + "|" + source) else { continue }
            var subjects: [String] = []
            for subject in group.map({ cleanTitle($0.subject) }) where !subject.isEmpty && !subjects.contains(subject) {
                subjects.append(subject)
            }
            guard !subjects.isEmpty else { continue }
            if let index = log.entries.firstIndex(where: { $0.source == source && $0.day == day }) {
                var entry = log.entries[index]
                // 고친 댓글이나 이미 레드마인에 보낸 줄에는 덧붙이지 않는다 (보낸 내용을 또 올리지 않게)
                guard let auto = entry.autoNote, entry.note == auto, entry.postedAt == nil else { continue }
                let existing = auto.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
                let added = subjects.filter { !existing.contains($0) }
                guard !added.isEmpty else { continue }
                let note = commitNote(existing + added)
                entry.note = note
                entry.autoNote = note
                if entry.issue == nil { entry.issue = issueNumber(in: subjects, branch: first.branch) }
                entry.updatedAt = now
                log.entries[index] = entry
            } else {
                let project = projectName(for: first.path, in: &log)
                log.register(project: project)
                let note = commitNote(subjects)
                let earlierIssue = log.entries.last { $0.source == source && $0.issue != nil }?.issue
                log.entries.append(WorkEntry(day: day, project: project, title: subjects[0], status: .inProgress,
                                             issue: issueNumber(in: group.map(\.subject), branch: first.branch) ?? earlierIssue,
                                             note: note, updatedAt: now, source: source, autoNote: note))
            }
            changed += 1
        }
        tidyMRNotes(&log, now: now)
        return changed
    }

    /// 머지 뒤에 고친 MR 설명(나중에 단 `[일감]` 등)을 다시 읽는다.
    /// - 아직 보내지 않은 줄: 원문을 바꾸고, 일감 번호가 없던 줄은 새 설명에서 찾는다. 댓글은 고치지 않은 것만 tidyMRNotes가 다시 만든다.
    /// - 이미 보낸 줄: 댓글은 그대로 두고, 새로 적힌 다른 일감 줄만 더한다 (tidyMRNotes는 보낸 MR 줄을 나누지 않는다).
    static func refresh(_ mr: MergedMR, in log: inout WorkLog, now: Date) -> Int {
        let raw = mr.description.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = 0
        for index in log.entries.indices {
            let entry = log.entries[index]
            guard let source = entry.source, source == mr.source || source.hasPrefix(mr.source + "#"),
                  (entry.mrBody ?? entry.note) != raw else { continue }
            log.entries[index].mrBody = raw
            if entry.postedAt == nil {
                if entry.issue == nil { log.entries[index].issue = issueNumber(in: [mr.title, raw], branch: mr.sourceBranch) }
                log.entries[index].updatedAt = now
            } else if source == mr.source {
                let listed = listedTitles(raw)
                for other in RedmineComment.allIssueRefs([raw]) where other != entry.issue {
                    let siblingSource = source + "#\(other)"
                    guard !log.entries.contains(where: { $0.source == siblingSource }),
                          !log.dismissed.contains(entry.day + "|" + siblingSource) else { continue }
                    log.entries.append(WorkEntry(day: entry.day, project: entry.project,
                                                 title: log.issue(other)?.reportTitle ?? listed[other] ?? "#\(other)",
                                                 status: entry.status, issue: other, note: "", updatedAt: now,
                                                 source: siblingSource, mrBody: raw))
                }
            }
            changed += 1
        }
        return changed
    }

    /// 아직 보내지 않은 MR 줄을 레드마인 댓글 꼴로 다듬는다.
    /// - MR이 다룬 다른 일감마다 줄을 하나씩 더한다 (레드마인에 일감마다 따로 올리던 대로). 그날 그 일감 줄이 있으면 건너뛴다.
    /// - 사용자가 고치지 않은 댓글(note == autoNote)은 원문(mrBody)에서 다시 만든다. 일감 제목을 나중에 받으면 줄을 다시 나눈다.
    /// 고친 때(updatedAt)는 그대로 둔다. 몇 번을 돌려도 결과가 같다.
    @discardableResult
    public static func tidyMRNotes(_ log: inout WorkLog, now: Date = Date()) -> Int {
        var changed = 0
        // 예전에 가져온 줄은 원문을 따로 두지 않았다. 고치지 않은 댓글이 곧 원문이다
        for index in log.entries.indices where isMR(log.entries[index]) && log.entries[index].postedAt == nil
            && log.entries[index].mrBody == nil && log.entries[index].autoNote == nil {
            log.entries[index].mrBody = log.entries[index].note
        }
        for entry in log.entries where isMR(entry) && entry.postedAt == nil && entry.issue != nil && !(entry.source ?? "").contains("#") {
            guard let raw = entry.mrBody, let source = entry.source else { continue }
            let listed = listedTitles(raw)
            // 그날 같은 일감 줄이 이미 있어도 MR마다 줄을 둔다 (한 일감을 여러 MR로 하는 날). 보낼 때 일감별로 한 댓글로 모인다
            for other in RedmineComment.allIssueRefs([raw]) where other != entry.issue {
                let siblingSource = source + "#\(other)"
                guard !log.entries.contains(where: { $0.source == siblingSource }),
                      !log.dismissed.contains(entry.day + "|" + siblingSource) else { continue }
                log.entries.append(WorkEntry(day: entry.day, project: entry.project,
                                             title: log.issue(other)?.reportTitle ?? listed[other] ?? "#\(other)",
                                             status: entry.status, issue: other, note: "", updatedAt: now, source: siblingSource,
                                             mrBody: raw))
                changed += 1
            }
        }
        for index in log.entries.indices where isMR(log.entries[index]) && log.entries[index].postedAt == nil {
            let entry = log.entries[index]
            guard let raw = entry.mrBody, entry.autoNote == nil || entry.note == entry.autoNote || entry.note.isEmpty,
                  let source = entry.source else { continue }
            let base = String(source.split(separator: "#").first ?? Substring(source))
            let siblings = Set(log.entries.filter { $0.day == entry.day && ($0.source == base || $0.source?.hasPrefix(base + "#") == true) }.compactMap(\.issue))
            let refs = RedmineComment.allIssueRefs([raw])
            let listed = listedTitles(raw)
            // [일감]에 적은 이름이 장부의 잎 이름(`API 연동`)보다 화면 낱말이 많아 줄 주인을 더 잘 가른다
            let named = subjects(for: refs + Array(siblings), in: log).merging(listed) { _, mine in mine }
            let note = RedmineComment.fromMR(raw, mr: mrNumber(source), issue: entry.issue, subjects: named, siblings: siblings)
            // 따로 나눈 일감 줄의 제목: 일감 이름을 받았으면 그것, 아니면 [작업 내용] 첫 항목 ([비고]의 `MR !110`이 제목이 되지 않게)
            if source.contains("#") {
                let work = note.components(separatedBy: "\n\n").first { $0.hasPrefix("[작업 내용]") }
                let first = work?.components(separatedBy: "\n").first { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
                if let title = log.issue(entry.issue)?.reportTitle ?? entry.issue.flatMap({ listed[$0] }) ?? first, title != entry.title {
                    log.entries[index].title = title
                    changed += 1
                }
            }
            if note != entry.note || entry.autoNote != note {
                log.entries[index].note = note
                log.entries[index].autoNote = note
                changed += 1
            }
        }
        return changed
    }

    static func isMR(_ entry: WorkEntry) -> Bool { entry.source?.hasPrefix("mr:") == true }

    static func mrNumber(_ source: String) -> Int? {
        Int(source.split(separator: "!").last?.split(separator: "#").first ?? "")
    }

    static func subjects(for issues: [Int], in log: WorkLog) -> [Int: String] {
        Dictionary(issues.compactMap { id in log.issue(id).map { (id, IssueInfo.cleanSubject($0.subject)) } }, uniquingKeysWith: { a, _ in a })
    }

    /// `[일감]`에 이름까지 적은 일감 (번호 → 이름).
    static func listedTitles(_ raw: String) -> [Int: String] {
        Dictionary(RedmineComment.listedIssues(raw).filter { !$0.title.isEmpty }.map { ($0.id, $0.title) },
                   uniquingKeysWith: { a, _ in a })
    }

    static func commitNote(_ subjects: [String]) -> String {
        (["[작업 내용]"] + subjects.map { "- \($0)" }).joined(separator: "\n")
    }
}
