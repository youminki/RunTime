import Foundation

/// 업무 일지를 보고서 글로 바꾸고, 붙여 넣은 보고서를 다시 읽는다.
public enum WorkReport {

    // MARK: 일일·주간 보고

    /// 사내 일일보고 꼴.
    /// ```
    /// 1. uxhub
    /// - QA 수정사항 7건 반영 (완료)
    /// ```
    /// `doneFirst`면 프로젝트마다 상시 → 완료 → 진행 중 순서로 놓는다 (회의·보고를 먼저 적는 관례).
    /// `byIssue`면 레드마인 일감 이름으로 적고 QA 건은 `QA 수정사항 N건 반영` 한 줄로 모은다.
    /// `grouped`면 같은 메뉴 경로(`데이터 수집 > 공유 파일 관리 > …`) 줄을 경로 한 줄 아래로 묶는다 (`grouping` 참고).
    /// `compact`면 사내 보고처럼 짧게 줄인다 (`compacted` 참고). 이때는 `grouped`를 쓰지 않는다.
    /// `ratios`는 일감별 레드마인 진척률 (`reportRatios`). `byIssue`일 때만 쓴다.
    public static func daily(_ entries: [WorkEntry], in log: WorkLog, doneFirst: Bool = false, byIssue: Bool = false,
                             grouped: Bool = false, compact: Bool = false, ratios: [Int: Int] = [:]) -> String {
        let lines = shaped(entries, in: log, byIssue: byIssue, compact: compact, ratios: ratios)
        return numbered(doneFirst ? ordered(lines) : lines, in: log, grouped: grouped && !compact)
    }

    /// 되돌리기는 날짜와 순서가 살아 있는 원래 줄에서 먼저 지운다. 같은 제목을 한 줄로 합친(`merged`) 뒤에는
    /// 같은 날 되돌렸다 다시 적용한 일을 가를 수 없다.
    private static func shaped(_ entries: [WorkEntry], in log: WorkLog, byIssue: Bool, compact: Bool,
                               merge: Bool = false, ratios: [Int: Int] = [:]) -> [WorkEntry] {
        var rows = compact ? withoutReverts(entries) : entries
        if merge { rows = merged(rows) }
        rows = byIssue ? issueLines(rows, in: log, ratios: ratios) : rows
        return compact ? shortened(rows) : rows
    }

    /// 일일보고 머리줄. 오늘이면 `[10/27 금일 진행 사항]`, 출근 때 올리는 계획은 `[10/27 금일 진행 예정 사항]`.
    /// 지난날을 보고 있으면 `금일` 없이 `[10/24 진행 사항]`.
    public static func dayHeader(_ day: String, plan: Bool = false, today: String = WorkDay.today()) -> String {
        let parts = day.split(separator: "-")
        let date = parts.count == 3 ? "\(parts[1])/\(parts[2])" : day
        return "[\(date) \(day == today ? "금일 " : "")진행\(plan ? " 예정" : "") 사항]"
    }

    /// 진행 예정 사항에 프로젝트마다 적는 한 줄 (사내 관례로 늘 같은 말을 쓴다).
    public static let planLine = "마크업 및 API 연동"
    /// 앞선 날 QA를 고친 프로젝트는 이어서 QA를 고치므로 이렇게 적는다.
    public static let qaPlanLine = "QA 수정사항 반영"
    /// 나에게 배정돼 아직 남은 안정화 일감이 있는 프로젝트.
    public static let stabilizationPlanLine = "안정화 이슈 처리"

    /// 출근 때 올리는 오늘 할 일. 프로젝트마다 `planLine` 한 줄.
    /// 기간을 정한 프로젝트는 그 기간 동안 늘 들어가고, 기간이 없는 프로젝트는 오늘 적은 일이나 앞선 날 끝나지 않은 일이 있을 때 들어간다.
    /// ```
    /// 1. UxHub
    /// - 마크업 및 API 연동
    /// 2. VeloX
    /// - 마크업 및 API 연동
    /// ```
    /// 상시(회의 등)만 있는 프로젝트는 뺀다. 앞선 날 QA를 고친 프로젝트는 `qaPlanLine`을, 남은 안정화 일감이 있으면
    /// `stabilizationPlanLine`을 적고, 둘 다 없을 때만 `planLine`을 적는다 (사람이 쓰는 예정 사항도 그렇게 쓴다).
    /// `closed`는 레드마인에서 닫힘으로 표시된 상태 ID (`IssueInfo.isOpen`).
    public static func plan(day: String, in log: WorkLog, closed: Set<Int> = []) -> String {
        let carried = log.previousDay(before: day).map { log.carryCandidates(from: $0, to: day) } ?? []
        let rows = (log.entries(on: day) + carried).filter {
            $0.status != .ongoing && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let fixed = log.projectsInPeriod(on: day)
        let stabilizing = stabilizationProjects(in: log, closed: closed)
        // 기간이 끝난 프로젝트도 그날 적은 일이 있으면 넣는다 (기간을 늦게 고친 경우)
        var names = fixed + log.orderedProjects(of: rows).filter { !fixed.contains($0) }
        names += stabilizing.filter { !names.contains($0) && !log.hiddenProjects.contains($0) }.sorted()
        let order = log.allProjects.filter(names.contains) + names.filter { !log.allProjects.contains($0) }
        let before = log.previousDay(before: day).map { log.entries(on: $0) } ?? []
        let qaProjects = Set(before.filter { isQA($0, in: log) }.map(\.project))
        return order.enumerated().map { index, project in
            var lines = [qaProjects.contains(project) ? qaPlanLine : nil, stabilizing.contains(project) ? stabilizationPlanLine : nil]
                .compactMap { $0 }
            if lines.isEmpty { lines = [planLine] }
            return (["\(index + 1). \(project)"] + lines.map { "- \($0)" }).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// 나에게 배정돼 아직 남은 안정화 일감이 있는 보고서 프로젝트.
    public static func stabilizationProjects(in log: WorkLog, closed: Set<Int> = []) -> Set<String> {
        Set(log.issues.values.filter { $0.assigned && $0.isStabilization && $0.isOpen(closed: closed) }.map { log.reportProject(for: $0) })
    }

    /// QA 일감 줄이거나, 직접 `QA 수정사항 …`처럼 적은 줄.
    static func isQA(_ entry: WorkEntry, in log: WorkLog) -> Bool {
        if let issue = entry.issue, let info = log.issue(issue) { return info.isQA }
        // `QAT 환경`처럼 QA로 시작하는 다른 말은 빼고 `QA 수정사항`·`QA수정`·`[QA]`만
        return entry.title.trimmingCharacters(in: .whitespaces)
            .range(of: #"^\[?QA(\]|\s|:|$|수정|이슈)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 레드마인 일감 기준 보고 줄. 같은 일감은 한 줄(가장 많이 한 상태), QA·안정화 건은 프로젝트마다 한 줄로 앞에 둔다.
    /// 장부에 없는 일감과 일감 없는 줄(회의 등)은 그대로 둔다.
    /// `ratios`(일감 → 진척률)가 있으면 그 일감의 상태를 레드마인 진척률로 적는다 (`reportRatios` 참고).
    public static func issueLines(_ entries: [WorkEntry], in log: WorkLog, ratios: [Int: Int] = [:]) -> [WorkEntry] {
        var result: [WorkEntry] = []
        for project in log.orderedProjects(of: entries) {
            // 막 지운 빈 줄은 일감 이름으로 바뀌어 보고서에 나오지 않게 먼저 뺀다
            let rows = entries.filter { $0.project == project && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            var qa: [Int: WorkStatus] = [:]
            var stabilization: [Int: WorkStatus] = [:]
            var issueIndex: [Int: Int] = [:]
            var lines: [WorkEntry] = []
            for entry in rows {
                guard let issue = entry.issue, let info = log.issue(issue) else {
                    lines.append(entry)
                    continue
                }
                if info.isQA {
                    qa[issue] = best(qa[issue], entry.status)
                    continue
                }
                if info.isStabilization {
                    stabilization[issue] = best(stabilization[issue], entry.status)
                    continue
                }
                if let index = issueIndex[issue] {
                    lines[index].status = best(lines[index].status, entry.status)
                    continue
                }
                var line = entry
                line.title = info.reportTitle
                issueIndex[issue] = lines.count
                lines.append(line)
            }
            for (issue, index) in issueIndex {
                if let ratio = ratios[issue] { lines[index].status = status(ratio, over: lines[index].status) }
                // 화면 기능 일감은 끝나면 (100%)로 적는다 (보고 관례: 기능 연동은 %, QA·기획 반영은 완료)
                if lines[index].status == .done, let info = log.issue(issue), IssueInfo.isWorkName(IssueInfo.cleanSubject(info.subject)) {
                    lines[index].status = .percent(100)
                }
            }
            if let first = rows.first {
                var head: [WorkEntry] = []
                for (title, group) in [("QA 수정사항 %d건 반영", qa), ("안정화 이슈 %d건 처리", stabilization)] where !group.isEmpty {
                    let statuses = group.map { status(ratios[$0.key], over: $0.value) }
                    head.append(WorkEntry(day: first.day, project: project, title: String(format: title, group.count),
                                          status: countStatus(statuses), updatedAt: first.updatedAt))
                }
                lines.insert(contentsOf: head, at: 0)
            }
            result += lines
        }
        return result
    }

    /// 레드마인 진척률을 보고서 상태로. 100은 완료, 0은 진행 중으로 적는다. 진척률이 없거나 상시 줄이면 일지 상태 그대로.
    static func status(_ ratio: Int?, over status: WorkStatus) -> WorkStatus {
        guard let ratio, status != .ongoing else { return status }
        return ratio >= 100 ? .done : ratio <= 0 ? .inProgress : .percent(ratio)
    }

    /// 여러 건을 한 줄로 셀 때의 상태. 끝난 비율을 10% 단위로 반올림하되, 다 끝나지 않았으면 100%로 올리지 않는다.
    static func countStatus(_ statuses: [WorkStatus]) -> WorkStatus {
        let finished = statuses.filter(\.isFinished).count
        let ratio = min(90, Int((Double(finished) / Double(statuses.count) * 10).rounded()) * 10)
        return finished == statuses.count ? .done : finished == 0 ? .inProgress : .percent(max(10, ratio))
    }

    /// 보고서에 적을 일감별 레드마인 진척률. 보고서는 늘 "레드마인에 보낸 뒤의 모습"을 적는다.
    /// - 아직 보내지 않았으면(`pending`) 보낼 값. 레드마인 탭에서 직접 고른 진척률도 여기 들어온다
    /// - 레드마인 탭에서 빼 둔 일감(`skipped`)은 보낼 값을 쓰지 않는다. 이미 보낸 값이 있으면 그것이 레드마인의 값이다
    /// - 보냈으면 마지막으로 보낸 값. 되돌린 건은 빼고, 가장 늦은 날 줄을 보낸 뒤 고쳤으면 보낼 값이 앞선다
    /// 보낸 기록이 어느 줄을 실었는지 적혀 있지 않은 옛 기록은 일감 번호와 보낸 때로 맞춘다.
    public static func reportRatios(_ entries: [WorkEntry], in log: WorkLog, pending: [Int: Int],
                                    skipped: Set<Int> = []) -> [Int: Int] {
        ratioSources(entries, in: log, pending: pending, skipped: skipped).ratios
    }

    /// `reportRatios`와 같고, 보낼 값을 쓴 일감도 함께 돌려준다 (보고서 아래 안내에 센다).
    public static func ratioSources(_ entries: [WorkEntry], in log: WorkLog, pending: [Int: Int],
                                    skipped: Set<Int> = []) -> (ratios: [Int: Int], fromPending: Set<Int>) {
        var ratios: [Int: Int] = [:]
        var fromPending: Set<Int> = []
        for issue in Set(entries.compactMap(\.issue)) {
            let rows = entries.filter { $0.issue == issue }
            // 보낼 값은 그 일감의 가장 늦은 날 줄이 아직 보내지 않은 줄일 때만 앞선다. 주간 보고에서 월요일 줄을 고쳐
            // 다시 보낼 목록에 올라도, 수요일에 이미 100%로 보냈으면 레드마인은 100%다
            let lastDay = rows.map(\.day).max()
            let latestWaiting = rows.contains { $0.day == lastDay && $0.needsRedmine }
            let waiting = skipped.contains(issue) ? nil : pending[issue]
            if latestWaiting, let ratio = waiting {
                ratios[issue] = ratio
                fromPending.insert(issue)
                continue
            }
            let ids = Set(rows.map(\.id))
            let sent = log.sent
                .filter { $0.issue == issue && $0.undoneAt == nil && $0.after.doneRatio != nil }
                .filter { record in
                    // 어느 줄을 실었는지 적힌 기록은 그 줄로, 옛 기록은 보낸 뒤에 고치지 않은 줄이 있으면 맞춘다
                    record.entryIDs.isEmpty ? rows.contains { $0.updatedAt <= record.sentAt } : !ids.isDisjoint(with: record.entryIDs)
                }
                .max { $0.sentAt < $1.sentAt }
            if let ratio = sent?.after.doneRatio {
                ratios[issue] = ratio
            } else if let ratio = waiting {
                ratios[issue] = ratio
                fromPending.insert(issue)
            }
        }
        return (ratios, fromPending)
    }

    /// 레드마인에 아직 반영되지 않은 것. 보고서 아래에 알려, 올리기 전에 레드마인부터 보낼 수 있게 한다.
    /// `unsent`는 보낼 일감(빼 둔 것 제외), `skipped`는 레드마인 탭에서 빼 둔 일감, `unlinked`는 일감 없는 줄 수 (상시 제외).
    public struct Unreflected: Equatable {
        public var unsent: [Int]
        public var skipped: [Int]
        public var unlinked: Int
        public var isEmpty: Bool { unsent.isEmpty && skipped.isEmpty && unlinked == 0 }
    }

    public static func unreflected(_ entries: [WorkEntry], skipped: Set<Int> = []) -> Unreflected {
        let live = entries.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        let waiting = Set(live.filter(\.needsRedmine).compactMap(\.issue))
        return Unreflected(unsent: waiting.subtracting(skipped).sorted(), skipped: waiting.intersection(skipped).sorted(),
                           unlinked: live.filter { $0.issue == nil && $0.status != .ongoing }.count)
    }

    /// CLI·자동 보내기처럼 레드마인 탭을 거치지 않을 때의 보낼 값: 일지 줄 상태로 정한 진척률.
    public static func pendingRatios(_ entries: [WorkEntry], log: WorkLog) -> [Int: Int] {
        var ratios: [Int: Int] = [:]
        for update in redmineUpdates(entries.filter(\.needsRedmine), log: log) where update.needsNote {
            if let ratio = update.doneRatio { ratios[update.issue] = ratio }
        }
        return ratios
    }

    /// 둘 가운데 더 나아간 상태. 상시는 상시끼리만 남는다.
    private static func best(_ a: WorkStatus?, _ b: WorkStatus) -> WorkStatus {
        guard let a else { return b }
        func value(_ s: WorkStatus) -> Int {
            switch s {
            case .done: return 101
            case .percent(let v): return v
            case .inProgress: return 1
            case .ongoing: return 0
            }
        }
        if a == .done || b == .done { return .done }
        return value(a) >= value(b) ? a : b
    }

    /// 다듬은 글이 보고서 꼴인지. 프로젝트마다 견준다.
    /// - 프로젝트 줄이 같은 이름·순서로 있고, 나머지는 `- 항목 (상태)` 줄뿐이다
    /// - 줄 수는 늘지 않고, 상태는 그 프로젝트 원래 줄에 있던 상태 가운데 하나다 (없는 상태·일을 만들지 않았다)
    /// - 메뉴 경로·QA·안정화 줄은 그 프로젝트 안에 글자 그대로 한 번씩 있다
    public static func keepsShape(original: String, polished: String) -> Bool {
        func blocks(_ text: String) -> [(project: String, lines: [String])]? {
            var result: [(project: String, lines: [String])] = []
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                    result.append((line, []))
                } else if line.hasPrefix("- "), !result.isEmpty {
                    result[result.count - 1].lines.append(line)
                } else {
                    return nil
                }
            }
            return result
        }
        func status(_ line: String) -> String? {
            line.range(of: #"\(([^()]+)\)$"#, options: .regularExpression).map { String(line[$0]) }
        }
        func fixed(_ line: String) -> Bool {
            line.contains(" > ") || line.hasPrefix("- QA 수정사항 ") || line.hasPrefix("- 안정화 이슈 ")
        }
        guard let before = blocks(original), let after = blocks(polished), !after.isEmpty,
              before.map(\.project) == after.map(\.project) else { return false }
        for (old, new) in zip(before, after) {
            let statuses = Set(old.lines.compactMap(status))
            // 고정 줄은 양쪽에서 같은 줄이 같은 개수만큼 있어야 한다 (지우지도, 새로 짓지도 않았다)
            let oldFixed = old.lines.filter(fixed), newFixed = new.lines.filter(fixed)
            guard !new.lines.isEmpty, new.lines.count <= old.lines.count,
                  new.lines.allSatisfy({ status($0).map(statuses.contains) ?? false }),
                  Dictionary(oldFixed.map { ($0, 1) }, uniquingKeysWith: +) == Dictionary(newFixed.map { ($0, 1) }, uniquingKeysWith: +)
            else { return false }
        }
        return true
    }

    // MARK: 간결하게

    /// 사내 일일보고처럼 짧게 줄인다. 프로젝트마다 차례로
    /// 1. MR·커밋에서 가져온 `X 되돌리기`와 그것이 되돌린 `X`를 뺀다 (한 일이 남지 않은 시행착오다)
    /// 2. `데이터 탐색 > SQL 편집기 > 끝 이름 API 연동`을 `데이터 탐색 > SQL 편집기 API 연동` 한 줄로 모은다
    /// 3. 일감 없이 MR·커밋에서 가져온 줄 가운데 주제 낱말이 셋 이상, 양쪽 절반 이상 겹치는 줄은 가장 짧은 줄 하나로 모은다
    /// 4. 진행 중인 브랜치 줄은 같은 프로젝트의 끝난 줄과 같은 일이면 뺀다
    /// 1·3·4번은 직접 적은 줄을 건드리지 않는다. 2번은 메뉴 이름만 줄이므로 직접 적은 줄에도 쓴다.
    /// 어느 규칙도 다른 일을 한 줄을 지우지 않게, 겹친다고 볼 때만 줄인다.
    public static func compacted(_ entries: [WorkEntry]) -> [WorkEntry] {
        shortened(withoutReverts(entries))
    }

    /// 2~4번 규칙.
    private static func shortened(_ entries: [WorkEntry]) -> [WorkEntry] {
        var projects: [String] = []
        for entry in entries where !projects.contains(entry.project) { projects.append(entry.project) }
        return projects.flatMap { project in
            withoutSideBranches(similarMerged(menuMerged(entries.filter { $0.project == project })))
        }
    }

    /// 1번 규칙. 프로젝트마다 날짜 순서로 견주고, 남은 줄은 원래 순서를 지킨다.
    private static func withoutReverts(_ entries: [WorkEntry]) -> [WorkEntry] {
        var kept: Set<UUID> = []
        for project in Set(entries.map(\.project)) {
            let rows = entries.filter { $0.project == project }
            let byDay = rows.enumerated().sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }.map(\.element)
            kept.formUnion(withoutReverted(byDay).map(\.id))
        }
        return entries.filter { kept.contains($0.id) }
    }

    /// `X 되돌리기`·`X 되돌림`·`X 원복`·`Revert "X"`의 X.
    static func revertedTitle(_ title: String) -> String? {
        let text = title.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("revert ") {
            return String(text.dropFirst("revert ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        for word in ["되돌리기", "되돌림", "원복"] where text.hasSuffix(" " + word) {
            return String(text.dropLast(word.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 되돌린 대상을 찾았을 때만 줄인다. 대상이 되돌린 뒤 날짜에 있으면(다시 적용) 되돌리기 줄만 뺀다.
    /// 대상이 없으면(보고 범위 밖의 날 것) 되돌린 일 자체가 한 일이라 둔다. 직접 적은 줄은 되돌리기도 대상도 되지 않는다.
    private static func withoutReverted(_ rows: [WorkEntry]) -> [WorkEntry] {
        var kept = rows
        for revert in rows {
            let auto = { (row: WorkEntry) in row.issue == nil && row.source != nil }
            guard kept.contains(where: { $0.id == revert.id }), auto(revert), let target = revertedTitle(revert.title),
                  let index = kept.lastIndex(where: { $0.id != revert.id && auto($0) && normalized($0.title) == normalized(target) })
            else { continue }
            if kept[index].day <= revert.day { kept.remove(at: index) }
            kept.removeAll { $0.id == revert.id }
        }
        return kept
    }

    /// 화면 기능 일감 이름 끝에 붙는 일 종류. 긴 것부터 맞춰 본다.
    private static let workKinds = ["API 연동", "화면 개발", "기능 개발", "퍼블리싱", "마크업", "연동", "개발", "설계", "디자인"]

    /// `A > B > 끝 이름 API 연동` → `A > B API 연동`. 경로가 셋보다 짧거나 끝에 일 종류가 없으면 nil.
    static func menuTitle(_ title: String) -> String? {
        let parts = title.components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let last = parts.last,
              let kind = workKinds.first(where: { last == $0 || last.hasSuffix(" " + $0) }) else { return nil }
        return parts.prefix(2).joined(separator: " > ") + " " + kind
    }

    private static func menuMerged(_ rows: [WorkEntry]) -> [WorkEntry] {
        var result: [WorkEntry] = []
        var index: [String: Int] = [:]
        for row in rows {
            // 상시 줄은 묶으면 그 묶음이 상시가 되어 맨 위로 가므로 그대로 둔다
            guard row.status != .ongoing, let title = menuTitle(row.title) else {
                result.append(row)
                continue
            }
            if let at = index[normalized(title)] {
                result[at].status = least(result[at].status, row.status)
                continue
            }
            var line = row
            line.title = title
            index[normalized(title)] = result.count
            result.append(line)
        }
        return result
    }

    /// 묶은 줄의 상태는 가장 덜 된 것. 하나라도 진행 중이면 그 묶음은 아직 끝나지 않았다.
    private static func least(_ a: WorkStatus, _ b: WorkStatus) -> WorkStatus {
        func value(_ s: WorkStatus) -> Int {
            switch s {
            case .done: return 101
            case .percent(let v): return v
            case .inProgress: return 1
            case .ongoing: return 0
            }
        }
        return value(b) < value(a) ? b : a
    }

    /// 비슷한지 견줄 때 빼는 말. 어떻게 했는지(적용·수정), 일 종류(API 연동·마크업), 흔한 화면 말(목록·상세)은
    /// 주제를 가르지 못해 `로그인 API 연동`과 `회원가입 API 연동`을 같은 일로 보게 만든다.
    private static let commonWords: Set<String> = [
        "적용", "수정", "추가", "변경", "처리", "반영", "정리", "교체", "개선", "제거", "구현", "작성", "삭제", "생성", "조회",
        "api", "연동", "마크업", "퍼블리싱", "개발", "설계", "디자인", "화면", "목록", "상세", "버그", "오류", "결함", "배포", "테스트",
        "및", "과", "와", "의", "을", "를", "것", "기능", "작업", "fix", "feat", "chore", "refactor",
    ]

    /// 주제 낱말. 메뉴 경로(`A > B >`)는 같은 화면 묶음이면 늘 겹쳐 떼고 끝 이름만 본다.
    static func words(_ title: String) -> Set<String> {
        let leaf = title.components(separatedBy: " > ").last ?? title
        // 점은 남겨 `v1.2`와 `v1.3`이 둘 다 `v1`이 되지 않게 하고, 숫자는 한 자리여도 남겨 `Step 1`과 `Step 2`를 가른다
        return Set(leaf.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { ($0.count >= 2 || $0.contains(where: \.isNumber)) && !commonWords.contains($0) })
    }

    /// 주제 낱말이 셋 이상 겹치고 양쪽 모두 절반 이상이 겹치면 같은 일로 본다. 짧은 쪽만 견주면
    /// 다른 일까지 적은 긴 제목이 짧은 제목에 묻혀 사라진다. 숫자(버전·번호)가 서로 다르면 다른 일이다.
    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let numbers = { (set: Set<String>) in set.filter { $0.contains(where: \.isNumber) } }
        let (na, nb) = (numbers(a), numbers(b))
        if !na.isEmpty, !nb.isEmpty, na != nb { return false }
        let shared = a.intersection(b).count
        return shared >= 3 && Double(shared) >= Double(max(a.count, b.count)) * 0.5
    }

    private static func similarMerged(_ rows: [WorkEntry]) -> [WorkEntry] {
        // 자동으로 가져온, 일감 없는, 상시가 아닌 줄만 모은다. 진행 중 브랜치는 4번 규칙에서 따로 본다
        let mergeable = { (row: WorkEntry) in
            row.issue == nil && row.source != nil && row.status != .ongoing && !isSideBranch(row)
        }
        var clusters: [[WorkEntry]] = []
        for row in rows where mergeable(row) {
            let mine = words(row.title)
            // 무리의 첫 줄하고만 견준다. 아무 줄과 견주면 A~B, B~C로 이어져 상관없는 A와 C가 한 줄이 된다
            if let at = clusters.firstIndex(where: { $0.first.map { similar(words($0.title), mine) } ?? false }) {
                clusters[at].append(row)
            } else {
                clusters.append([row])
            }
        }
        var result: [WorkEntry] = []
        for row in rows {
            guard mergeable(row) else {
                result.append(row)
                continue
            }
            // 무리의 첫 줄 자리에 가장 짧은 제목과 가장 덜 된 상태로 한 줄만 둔다 (하나라도 남았으면 끝난 일이 아니다)
            guard let cluster = clusters.first(where: { $0.first?.id == row.id }) else { continue }
            var line = row
            line.title = cluster.map(\.title).min { $0.count < $1.count } ?? row.title
            line.status = cluster.dropFirst().reduce(row.status) { least($0, $1.status) }
            result.append(line)
        }
        return result
    }

    /// 진행 중 브랜치가 같은 프로젝트의 끝난 줄과 같은 일이면 뺀다. 상관없는 진행 중 작업은 그날 한 일이라 둔다.
    private static func isSideBranch(_ row: WorkEntry) -> Bool {
        row.issue == nil && row.source?.hasPrefix("branch:") == true && !row.status.isFinished
    }

    private static func withoutSideBranches(_ rows: [WorkEntry]) -> [WorkEntry] {
        let finished = rows.filter { !isSideBranch($0) && $0.status.isFinished }.map { words($0.title) }
        return rows.filter { row in !(isSideBranch(row) && finished.contains { similar($0, words(row.title)) }) }
    }


    /// 상시 → 완료 → 진행 중(많이 한 것 먼저). 같은 무리 안에서는 원래 순서.
    public static func ordered(_ entries: [WorkEntry]) -> [WorkEntry] {
        func rank(_ status: WorkStatus) -> (Int, Int) {
            switch status {
            case .ongoing: return (0, 0)
            case .done, .percent(100): return (1, 0)
            case .percent(let value): return (2, -value)
            case .inProgress: return (3, 0)
            }
        }
        return entries.enumerated().sorted { a, b in
            let ra = rank(a.element.status), rb = rank(b.element.status)
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        .map(\.element)
    }

    /// 한 주 동안 같은 일은 한 줄로 모으고 마지막 상태를 적는다. 화요일 60%, 목요일 완료면 완료 한 줄만 남는다.
    /// `nextWeekPlan`이면 끝나지 않은 일을 `[차주 계획]`으로 한 번 더 적는다.
    public static func weekly(_ entries: [WorkEntry], in log: WorkLog, week: ClosedRange<String>,
                              doneFirst: Bool = false, nextWeekPlan: Bool = false, byIssue: Bool = false,
                              grouped: Bool = false, compact: Bool = false, ratios: [Int: Int] = [:]) -> String {
        let body = period(entries, in: log, doneFirst: doneFirst, byIssue: byIssue, grouped: grouped, compact: compact, ratios: ratios,
                          header: "[주간 진행 사항] \(shortDate(week.lowerBound)) ~ \(shortDate(week.upperBound))")
        guard nextWeekPlan, !body.isEmpty else { return body }
        let lines = shaped(entries, in: log, byIssue: byIssue, compact: compact, merge: true, ratios: ratios)
        let open = lines.filter { !$0.status.isFinished && $0.status != .ongoing }
        guard !open.isEmpty else { return body }
        return body + "\n\n[차주 계획]\n" + numbered(open, in: log, grouped: grouped && !compact)
    }

    /// 한 달치를 주간 보고와 같은 규칙으로 모은다. 머리는 `[월간 진행 사항] 2026년 10월`.
    public static func monthly(_ entries: [WorkEntry], in log: WorkLog, month: ClosedRange<String>, byIssue: Bool = false,
                               grouped: Bool = false, compact: Bool = false, ratios: [Int: Int] = [:]) -> String {
        let parts = month.lowerBound.split(separator: "-")
        let title = parts.count == 3 ? "\(parts[0])년 \(Int(parts[1]) ?? 0)월" : month.lowerBound
        return period(entries, in: log, doneFirst: false, byIssue: byIssue, grouped: grouped, compact: compact, ratios: ratios,
                      header: "[월간 진행 사항] \(title)")
    }

    private static func period(_ entries: [WorkEntry], in log: WorkLog, doneFirst: Bool, byIssue: Bool, grouped: Bool,
                               compact: Bool, ratios: [Int: Int] = [:], header: String) -> String {
        let lines = shaped(entries, in: log, byIssue: byIssue, compact: compact, merge: true, ratios: ratios)
        let body = numbered(doneFirst ? ordered(lines) : lines, in: log, grouped: grouped && !compact)
        return body.isEmpty ? "" : header + "\n" + body
    }

    /// 같은 프로젝트의 같은 제목을 하나로 모은다. 순서는 처음 나온 날을 따르고 상태와 일감 번호는 마지막 날 것을 쓴다.
    public static func merged(_ entries: [WorkEntry]) -> [WorkEntry] {
        var order: [String] = []
        var latest: [String: WorkEntry] = [:]
        for entry in entries.sorted(by: { $0.day < $1.day }) {
            let key = entry.project + "\u{1F}" + normalized(entry.title)
            if latest[key] == nil { order.append(key) }
            var merged = entry
            if merged.issue == nil { merged.issue = latest[key]?.issue }
            latest[key] = merged
        }
        return order.compactMap { latest[$0] }
    }

    /// 한 일감이 이 주 며칠에 걸쳐 어떻게 나아갔는지. 예: `60% → 완료`.
    public static func progression(of entry: WorkEntry, in entries: [WorkEntry]) -> [WorkStatus] {
        let key = normalized(entry.title)
        var steps: [WorkStatus] = []
        for item in entries.sorted(by: { $0.day < $1.day })
        where item.project == entry.project && normalized(item.title) == key && steps.last != item.status {
            steps.append(item.status)
        }
        return steps
    }

    private static func numbered(_ entries: [WorkEntry], in log: WorkLog, grouped: Bool = false) -> String {
        // 막 지운 빈 줄은 보고서에 넣지 않는다
        let entries = entries.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        return log.orderedProjects(of: entries).enumerated().map { index, project in
            let rows = entries.filter { $0.project == project }
            let lines = grouped ? groupedLines(rows) : rows.map { "- \(line($0))" }
            return (["\(index + 1). \(project)"] + lines).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// 경로 앞부분이 같은 줄이 둘 이상이면 경로를 한 번만 적고 끝 이름을 그 아래 `  · `로 늘어놓는다.
    /// ```
    /// - 데이터 수집 > 수집 파이프라인 관리
    ///   · 작업 제어 API 연동 (100%)
    ///   · 로그 조회 API 연동 (100%)
    /// ```
    /// 묶음은 첫 줄이 있던 자리에 두어 상시 → 완료 → 진행 순서를 되도록 지킨다.
    static func groupedLines(_ rows: [WorkEntry]) -> [String] {
        let groups = grouping(rows)
        var printed: Set<String> = []
        var lines: [String] = []
        for row in rows {
            guard let (path, _) = split(row.title), let members = groups[path], members.count > 1 else {
                lines.append("- \(line(row))")
                continue
            }
            guard printed.insert(path).inserted else { continue }
            lines.append("- \(path)")
            for member in members {
                let leaf = split(member.title)?.leaf ?? member.title
                lines.append("  · \(leaf) (\(member.status.label))")
            }
        }
        return lines
    }

    /// 경로 앞부분마다 그 경로를 쓰는 줄 (원래 순서).
    private static func grouping(_ rows: [WorkEntry]) -> [String: [WorkEntry]] {
        var groups: [String: [WorkEntry]] = [:]
        for row in rows {
            if let (path, _) = split(row.title) { groups[path, default: []].append(row) }
        }
        return groups
    }

    /// `A > B > 끝 이름` → (`A > B`, `끝 이름`). 경로가 없으면 nil.
    private static func split(_ title: String) -> (path: String, leaf: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: " > ", options: .backwards) else { return nil }
        let path = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let leaf = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty || leaf.isEmpty ? nil : (path, leaf)
    }

    public static func line(_ entry: WorkEntry) -> String {
        "\(entry.title.trimmingCharacters(in: .whitespaces)) (\(entry.status.label))"
    }

    private static func normalized(_ title: String) -> String {
        title.lowercased().filter { !$0.isWhitespace }
    }

    /// `2026-10-20` → `10.20`
    public static func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return key }
        return "\(month).\(day)"
    }

    // MARK: 레드마인

    /// 레드마인 일감 하나에 올릴 것.
    public struct RedmineUpdate: Equatable {
        public let issue: Int
        public var doneRatio: Int?
        public let note: String
        public let entryIDs: [UUID]
        /// 댓글·진척률을 보내야 하는지. 시간만 남기면 될 때는 false라 댓글을 또 올리지 않는다.
        public var needsNote = true
        /// 아직 남기지 않은 작업 시간. 레드마인 소요 시간은 날짜마다 따로라 날마다 한 건씩 남긴다.
        public var timeEntries: [TimeEntry] = []
        /// 이 일감 줄이 적힌 날들.
        public var days: [String] = []
        /// 마지막 날 줄이 몇 %인지 정하지 않은 진행중이다. 설정의 진행중 진척률을 얹을 수 있다 (상시 업무는 아니다).
        public var inProgress = false

        /// 진행중 일감에 설정한 기본 진척률을 얹는다. 직접 고른 진척률은 이 뒤에 얹는다.
        public func withInProgressRatio(_ ratio: Int?) -> RedmineUpdate {
            guard inProgress, doneRatio == nil, let ratio else { return self }
            var copy = self
            copy.doneRatio = ratio
            return copy
        }

        public var hours: Double? {
            let total = timeEntries.map(\.hours).reduce(0, +)
            return total > 0 ? total : nil
        }
    }

    public struct TimeEntry: Equatable {
        public let day: String
        public let hours: Double
        public let entryIDs: [UUID]
    }

    /// 일감 번호별로 모은다. 같은 일감에 여러 줄이 있으면 [작업 내용]에 모두 적고 진척률은 가장 늦은 줄을 쓴다.
    /// `log`를 주면 MR에서 온 댓글을 레드마인 꼴로 다듬는다 (리뷰어용 섹션·일감 번호를 빼고, 따로 줄이 있는 일감 줄은 그쪽으로).
    public static func redmineUpdates(_ entries: [WorkEntry], log: WorkLog? = nil) -> [RedmineUpdate] {
        var order: [Int] = []
        var grouped: [Int: [WorkEntry]] = [:]
        let entries = log.map { log in entries.map { tidied($0, in: log) } } ?? entries
        for entry in entries.sorted(by: { $0.day < $1.day }) {
            // 제목을 비운 줄은 보고서처럼 빈 항목이 되지 않게 뺀다
            guard let issue = entry.issue, !entry.title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if grouped[issue] == nil { order.append(issue) }
            grouped[issue, default: []].append(entry)
        }
        return order.map { issue in
            let items = grouped[issue] ?? []
            let lastDay = items.last?.day
            let ratio = items.filter { $0.day == lastDay }.compactMap(\.status.doneRatio).max()
            let timed = items.filter(\.needsTime)
            let timeEntries = Dictionary(grouping: timed, by: \.day).sorted { $0.key < $1.key }.map { day, rows in
                TimeEntry(day: day, hours: rows.compactMap(\.hours).reduce(0, +), entryIDs: rows.map(\.id))
            }
            // 댓글은 보내야 할 줄만으로 만든다 (시간만 남은 줄의 내용을 또 올리지 않게)
            let noteItems = items.filter(\.needsRedmine)
            let inProgress = ratio == nil && items.contains { $0.day == lastDay && $0.status == .inProgress }
            return RedmineUpdate(issue: issue, doneRatio: ratio, note: comment(noteItems.isEmpty ? items : noteItems),
                                 entryIDs: items.map(\.id), needsNote: !noteItems.isEmpty, timeEntries: timeEntries,
                                 days: Array(Set(items.map(\.day))).sorted(), inProgress: inProgress)
        }
    }

    /// 진척률과 함께 바꿀 일감 칸. 비어 있으면 댓글과 진척률만 보낸다.
    /// 날짜는 `yyyy-MM-dd`, 빈 글자면 그 칸을 비운다.
    public struct IssueFields: Equatable {
        public var status: RedmineAPI.Status?
        public var startDate: String?
        public var dueDate: String?
        public var assignee: RedmineAPI.Member?

        public init(status: RedmineAPI.Status? = nil, startDate: String? = nil, dueDate: String? = nil,
                    assignee: RedmineAPI.Member? = nil) {
            self.status = status
            self.startDate = startDate
            self.dueDate = dueDate
            self.assignee = assignee
        }

        public var isEmpty: Bool { status == nil && startDate == nil && dueDate == nil && assignee == nil }

        /// 자동으로 정한 칸 위에 직접 고른 칸을 얹고, 지금 값과 같은 칸은 뺀다 (바뀌지 않는 칸을 보내지 않게).
        public static func merged(auto: IssueFields, edit: IssueEdit?, current: IssueInfo?,
                                  statuses: [RedmineAPI.Status]) -> IssueFields {
            var fields = auto
            if let edit {
                if let id = edit.statusID { fields.status = statuses.first { $0.id == id } }
                if let start = edit.startDate { fields.startDate = start }
                if let due = edit.dueDate { fields.dueDate = due }
                if let assignee = edit.assignee { fields.assignee = assignee }
            }
            if fields.status?.id == current?.statusID { fields.status = nil }
            if fields.startDate == (current?.startDate ?? "") { fields.startDate = nil }
            if fields.dueDate == (current?.dueDate ?? "") { fields.dueDate = nil }
            if fields.assignee?.id == current?.assignee?.id { fields.assignee = nil }
            return fields
        }

        /// 보낸 뒤의 시작일이 기한보다 늦으면 레드마인이 422로 거절한다. 미리 알린다.
        public func problem(current: IssueInfo?) -> String? {
            let start = startDate ?? current?.startDate ?? ""
            let due = dueDate ?? current?.dueDate ?? ""
            guard !start.isEmpty, !due.isEmpty, start > due else { return nil }
            return "시작일이 완료 기한보다 늦습니다"
        }
    }

    /// 직접 고른 칸. nil은 고르지 않음(자동), 날짜의 빈 글자는 비우기.
    public struct IssueEdit: Codable, Equatable {
        public var statusID: Int?
        public var startDate: String?
        public var dueDate: String?
        public var assignee: RedmineAPI.Member?
        /// 직접 고른 진척률. 일지 줄의 상태(완료·60% 등)로 정한 값보다 앞선다.
        public var doneRatio: Int?

        public init(statusID: Int? = nil, startDate: String? = nil, dueDate: String? = nil, assignee: RedmineAPI.Member? = nil,
                    doneRatio: Int? = nil) {
            self.statusID = statusID
            self.startDate = startDate
            self.dueDate = dueDate
            self.assignee = assignee
            self.doneRatio = doneRatio
        }

        public var isEmpty: Bool { statusID == nil && startDate == nil && dueDate == nil && assignee == nil && doneRatio == nil }

        /// 직접 고른 진척률을 얹은 보낼 것. 진척률로 정하는 상태(100%면 완료)도 이 값을 따른다.
        public func applied(to update: RedmineUpdate) -> RedmineUpdate {
            guard let doneRatio else { return update }
            var copy = update
            copy.doneRatio = doneRatio
            return copy
        }
    }

    /// 일지를 보고 일감 상태·시작일·완료 기한을 맞춘다.
    /// 상태는 처음 상태(할일·신규) → 진행 → 완료 순으로 앞으로만 옮긴다. 레드마인의 상태 목록 순서는 일의 흐름과 다를 수 있어
    /// (할일, 처리중, 코드리뷰, 테스트, 완료, … 해결) 순서 대신 이 세 칸만 본다. 테스트·반려처럼 그 밖의 상태면 건드리지 않는다.
    /// 날짜는 비어 있을 때만 채운다. 지금 값을 모르는 일감(옛 장부)은 아무것도 바꾸지 않는다. 빈 칸으로 알고 덮어쓰면 안 되니까.
    public static func issueFields(for update: RedmineUpdate, current: IssueInfo?, statuses: [RedmineAPI.Status],
                                   progressID: Int?, doneID: Int?) -> IssueFields {
        guard let current, let currentID = current.statusID, update.needsNote else { return IssueFields() }
        let finished = update.doneRatio == 100
        var fields = IssueFields()
        func rank(_ id: Int) -> Int? {
            if id == doneID { return 2 }
            if id == progressID { return 1 }
            if let status = statuses.first(where: { $0.id == id }), isInitial(status, in: statuses) { return 0 }
            return nil
        }
        if let targetID = finished ? doneID : progressID,
           let target = statuses.first(where: { $0.id == targetID }),
           let from = rank(currentID), let to = rank(targetID), to > from {
            fields.status = target
        }
        let due = current.dueDate ?? (finished ? update.days.last : nil)
        if current.startDate == nil, let first = update.days.first, due.map({ first <= $0 }) ?? true {
            fields.startDate = first
        }
        if finished, current.dueDate == nil, let last = update.days.last,
           (current.startDate ?? fields.startDate).map({ $0 <= last }) ?? true {
            fields.dueDate = last
        }
        return fields
    }

    /// 새 일감이 처음 받는 상태 (목록 맨 앞이거나 할일·신규).
    static func isInitial(_ status: RedmineAPI.Status, in statuses: [RedmineAPI.Status]) -> Bool {
        let name = status.name.lowercased()
        return status.id == statuses.first?.id || ["할일", "신규", "new", "todo", "to do"].contains(name)
    }

    /// 상태 이름으로 진행·완료 상태를 어림한다 (설정에서 고르지 않았을 때). 완료는 `완료`를 `해결`보다 먼저 본다.
    public static func defaultStatuses(_ statuses: [RedmineAPI.Status]) -> (progress: Int?, done: Int?) {
        func find(_ words: [String], closed: Bool? = nil) -> Int? {
            for word in words {
                if let hit = statuses.first(where: { (closed == nil || $0.isClosed == closed) && $0.name.lowercased().contains(word) }) {
                    return hit.id
                }
            }
            return nil
        }
        return (find(["처리중", "진행", "in progress", "progress", "doing"], closed: false),
                find(["완료", "done"]) ?? find(["해결", "resolved", "closed"]))
    }

    /// MR에서 온 댓글을 보내기 전에 한 번 더 다듬는다. 원문에서 만든 댓글은 이미 다듬어져 있고,
    /// 사용자가 고친 댓글도 리뷰어용 섹션과 일감 번호만은 뗀다.
    static func tidied(_ entry: WorkEntry, in log: WorkLog) -> WorkEntry {
        guard let source = entry.source, source.hasPrefix("mr:"), !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.note != entry.autoNote else { return entry }
        let base = String(source.split(separator: "#").first ?? Substring(source))
        let siblings = Set(log.entries.filter { ($0.source == base || $0.source?.hasPrefix(base + "#") == true) && $0.day == entry.day }.compactMap(\.issue))
        var copy = entry
        copy.note = RedmineComment.fromMR(entry.note, mr: WorkCapture.mrNumber(source), issue: entry.issue,
                                          subjects: WorkCapture.subjects(for: Array(siblings), in: log), siblings: siblings)
        return copy
    }

    /// 직접 쓴 댓글이 있으면 그대로 쓰고, 없으면 제목으로 [작업 내용]을 만든다.
    public static func comment(_ entries: [WorkEntry]) -> String {
        // 이어 쓴 줄은 보내지 않은 댓글을 그대로 옮겨, 주간으로 보내면 같은 댓글이 둘 모인다
        var noted = Set<String>()
        let written = entries.map { $0.note.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && noted.insert(normalized($0)).inserted }
        let untitled = entries.filter { $0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var parts = written
        if !untitled.isEmpty {
            var seen = Set<String>()
            let lines = untitled.map(\.title).filter { seen.insert(normalized($0)).inserted }.map { "- \($0)" }
            parts.insert((["[작업 내용]"] + lines).joined(separator: "\n"), at: 0)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Claude에게 그대로 붙여 넣는 글. git을 다시 훑지 않고 이 글만 보고 올리게 해 토큰을 아낀다.
    /// `html`이면 댓글을 레드마인에 실릴 HTML 그대로 넣어, Claude가 꼴을 바꾸다 줄바꿈을 잃지 않게 한다.
    public static func redmineRequest(_ updates: [RedmineUpdate], fields: [Int: IssueFields] = [:], html: Bool = false,
                                      withoutNotes: Set<Int> = []) -> String {
        guard !updates.isEmpty else { return "" }
        let head = html
            ? "레드마인 일감에 아래 진척률과 댓글을 반영해 줘. 적힌 칸 말고는 바꾸지 말고, 댓글은 HTML이니 고치지 말고 notes에 그대로 넣어 (줄바꿈을 지우지 마)."
            : "레드마인 일감에 아래 진척률과 댓글을 반영해 줘. 적힌 칸 말고는 바꾸지 말고, 댓글은 고치지 말고 그대로 올려."
        let blocks = updates.map { update in
            var parts = [update.doneRatio.map { "진척률 \($0)%" } ?? "진척률 그대로"]
            let extra = fields[update.issue] ?? IssueFields()
            if let status = extra.status { parts.append("상태 \(status.name)") }
            if let start = extra.startDate { parts.append(start.isEmpty ? "시작일 비우기" : "시작일 \(start)") }
            if let due = extra.dueDate { parts.append(due.isEmpty ? "완료 기한 비우기" : "완료 기한 \(due)") }
            if let assignee = extra.assignee { parts.append("담당자 \(assignee.name)(id \(assignee.id))") }
            // 카드에서 댓글을 뺀 일감은 여기서도 빼야 Claude가 같은 댓글을 또 올리지 않는다
            if withoutNotes.contains(update.issue) { return "#\(update.issue) \(parts.joined(separator: " · ")) (댓글 없음)" }
            return "#\(update.issue) \(parts.joined(separator: " · "))\n\(html ? RedmineNote.html(update.note) : update.note)"
        }
        return ([head] + blocks).joined(separator: "\n\n---\n")
    }

    // MARK: 붙여 넣기

    /// 이미 써 둔 보고서를 읽는다. `1.uxhub`, `2. VeloX` 같은 번호 줄이 프로젝트, `- 내용 (완료)`가 일이다.
    /// 줄 안의 `#12345`는 일감 번호로 떼어 낸다. `[금일 진행 사항]` 같은 머리줄은 건너뛴다.
    /// 묶어 쓴 보고서(`- 경로` 아래 들여 쓴 `· 끝 이름 (상태)`)는 경로를 다시 붙여 한 줄씩 읽는다.
    public static func parse(_ text: String, day: String, now: Date = Date()) -> [WorkEntry] {
        var project: String?
        var entries: [WorkEntry] = []
        let rawLines = text.components(separatedBy: .newlines)
        var group: String?
        for (index, raw) in rawLines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("[") else { continue }
            if let name = projectName(line) {
                project = name
                group = nil
                continue
            }
            guard let first = line.first, "-•·*".contains(first), let project else { continue }
            let indented = raw.first?.isWhitespace == true
            if !indented {
                group = nil
                // 묶어 쓴 꼴(`- 경로` 다음 줄이 들여 쓴 `· `)일 때만 경로 머리로 읽는다.
                // 상태나 일감 번호가 붙은 줄 아래의 `  - 세부` 같은 하위 글머리는 그대로 따로 읽는다
                let head = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let next = rawLines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let next, next.first?.isWhitespace == true,
                   next.trimmingCharacters(in: .whitespaces).hasPrefix("·"),
                   !head.hasSuffix(")"), splitIssue(head).issue == nil {
                    group = head
                    continue
                }
            }
            var body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if indented, let group { body = group + " > " + body }
            var status = WorkStatus.done
            if body.hasSuffix(")"), let open = body.lastIndex(of: "(") {
                let inside = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
                if let parsed = WorkStatus(label: inside) {
                    status = parsed
                    body = String(body[..<open]).trimmingCharacters(in: .whitespaces)
                }
            }
            let (title, issue) = splitIssue(body)
            guard !title.isEmpty else { continue }
            entries.append(WorkEntry(day: day, project: project, title: title, status: status, issue: issue, updatedAt: now))
        }
        return entries
    }

    /// `1.uxhub`, `2) VeloX` → 프로젝트 이름.
    private static func projectName(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        // 프로젝트 번호는 한두 자리. `2026.10.20 보고` 같은 날짜 줄은 프로젝트로 읽지 않는다
        guard (1...2).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, ".)".contains(mark), rest.dropFirst().first?.isNumber != true else { return nil }
        let name = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 제목에서 `#12345`를 떼어 낸다.
    public static func splitIssue(_ text: String) -> (title: String, issue: Int?) {
        guard let range = text.range(of: #"#(\d{2,7})"#, options: .regularExpression) else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        let issue = Int(text[range].dropFirst())
        var title = text
        title.removeSubrange(range)
        title = title.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return (title, issue)
    }
}
