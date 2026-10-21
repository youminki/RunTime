import AppKit
import Combine
import WorkLogCore

/// 업무 일지를 들고 있고 고칠 때마다 조금 뒤에 파일로 쓴다.
/// `--worklog` 명령이나 Claude가 파일을 고치면 다시 읽어 창에 바로 보인다.
final class WorkLogStore: ObservableObject {
    static let shared = WorkLogStore()

    @Published private(set) var log = WorkLog()
    /// 파일을 읽지 못했을 때의 이유. 이때는 덮어쓰지 않는다.
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?

    private let url: URL
    private var pendingSave: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var lastWritten: Date?
    /// 마지막으로 파일과 맞춘 내용. 저장할 때 이것과 비교해 이 창에서 고친 줄만 골라낸다.
    private var base = WorkLog()

    init(url: URL = WorkLogFile.defaultURL) {
        self.url = url
        reload()
        watch()
        // 고치고 0.4초 안에 앱을 끄면 마지막 글자가 남지 않는다
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            if self?.pendingSave != nil { self?.saveNow() }
        }
    }

    deinit { watcher?.cancel() }

    // MARK: 읽고 쓰기

    func reload() {
        do {
            log = try WorkLogFile.load(url)
            base = log
            loadError = nil
            tidyMRNotes()
        } catch {
            loadError = "\(url.lastPathComponent)을 읽지 못했습니다. 파일을 고치거나 옮기면 다시 읽습니다."
        }
        lastWritten = modificationDate()
    }

    /// 바로 쓰지 않고 잠깐 모아 쓴다. 제목을 한 글자씩 칠 때마다 파일을 쓰지 않게.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard loadError == nil else { return }
        // 저장을 기다리는 사이 명령이나 Claude가 파일을 고쳤으면, 그 내용 위에 이 창에서 고친 줄만 얹는다
        if modificationDate() != lastWritten {
            // 바깥에서 깨진 채로(또는 쓰는 도중에) 저장한 파일은 이 창의 옛 내용으로 덮어쓰지 않고, 고쳐질 때까지 다시 본다
            guard let disk = try? WorkLogFile.load(url) else {
                saveError = "\(url.lastPathComponent)이 깨져 있어 저장을 미뤘습니다. 파일이 고쳐지면 바로 저장합니다."
                let retry = DispatchWorkItem { [weak self] in self?.saveNow() }
                pendingSave = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: retry)
                return
            }
            log = WorkLog.merge(mine: log, base: base, disk: disk)
        }
        do {
            try WorkLogFile.save(log, to: url)
            saveError = nil
        } catch {
            saveError = "일지를 저장하지 못했습니다: \(error.localizedDescription)"
        }
        base = log
        lastWritten = modificationDate()
    }


    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 파일은 통째로 바꿔 써서(atomic) 파일 대신 폴더를 지켜본다.
    private func watch() {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.modificationDate() != self.lastWritten else { return }
            // 저장을 기다리던 중이면 바로 저장하며 합친다. 아니면 그냥 다시 읽는다
            if self.pendingSave != nil { self.saveNow() } else { self.reload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func change(_ body: (inout WorkLog) -> Void) {
        body(&log)
        scheduleSave()
    }

    // MARK: 고치기

    func entry(_ id: UUID) -> WorkEntry? {
        log.entries.first { $0.id == id }
    }

    @discardableResult
    func add(day: String, project: String, title: String, status: WorkStatus = .done) -> WorkEntry? {
        let split = WorkReport.splitIssue(title)
        guard !split.title.isEmpty else { return nil }
        let entry = WorkEntry(day: day, project: project, title: split.title, status: status, issue: split.issue)
        change {
            $0.register(project: project)
            $0.entries.append(entry)
        }
        return entry
    }

    func update(_ id: UUID, _ body: (inout WorkEntry) -> Void) {
        guard let index = log.entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = log.entries[index]
        body(&entry)
        guard entry != log.entries[index] else { return }
        entry.updatedAt = Date()
        change { $0.entries[index] = entry }
    }

    /// 제목 칸에서 Enter. 다 지웠으면 줄을 지우고, 끝에 붙인 `#1234`는 일감 번호로 뗀다.
    func commitTitle(_ id: UUID) {
        guard let entry = entry(id) else { return }
        let split = WorkReport.splitIssue(entry.title)
        if split.title.isEmpty {
            delete(id)
        } else if let issue = split.issue {
            update(id) {
                $0.title = split.title
                $0.issue = issue
            }
        }
    }

    func delete(_ id: UUID) {
        change { $0.remove(id) }
    }

    /// 같은 날 같은 프로젝트 안에서 한 칸 올리거나 내린다. 보고서 줄 순서가 이 순서다.
    func move(_ id: UUID, by offset: Int) {
        guard let entry = entry(id) else { return }
        let siblings = log.entries.indices.filter {
            log.entries[$0].day == entry.day && log.entries[$0].project == entry.project
        }
        guard let position = siblings.firstIndex(where: { log.entries[$0].id == id }),
              siblings.indices.contains(position + offset) else { return }
        change { $0.entries.swapAt(siblings[position], siblings[position + offset]) }
    }

    /// 끌어 놓은 줄을 대상 줄 자리로 옮긴다. 같은 날 같은 프로젝트 안에서만 (보고서 줄 순서가 이 순서다).
    func move(_ id: UUID, before target: UUID) {
        guard id != target, let moving = entry(id), let goal = entry(target),
              moving.day == goal.day, moving.project == goal.project else { return }
        change { log in
            guard let from = log.entries.firstIndex(where: { $0.id == id }) else { return }
            let item = log.entries.remove(at: from)
            guard let to = log.entries.firstIndex(where: { $0.id == target }) else { return }
            // 놓는 자리 표시(대상 줄 위의 선)와 같게 늘 대상 앞에 놓는다
            log.entries.insert(item, at: to)
        }
    }

    func addProject(_ name: String) {
        change { $0.register(project: name) }
    }

    /// 프로젝트 이름을 바꾸면 지난 기록도 함께 바꾼다.
    func renameProject(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        change { log in
            if let index = log.projects.firstIndex(of: old) {
                if log.projects.contains(name) { log.projects.remove(at: index) } else { log.projects[index] = name }
            }
            for index in log.entries.indices where log.entries[index].project == old {
                log.entries[index].project = name
            }
            // 다음에 GitLab에서 가져올 때도 새 이름으로 넣는다
            for (group, alias) in log.aliases where alias == old { log.aliases[group] = name }
            // 고정 업무가 옛 이름을 다시 만들지 않게
            for index in log.recurring.indices where log.recurring[index].project == old { log.recurring[index].project = name }
            if log.hiddenProjects.remove(old) != nil { log.hiddenProjects.insert(name) }
            // 레드마인 일감을 옛 이름 아래에 적어 옛 프로젝트를 되살리지 않게
            for (redmine, report) in log.redmineProjects where report == old { log.redmineProjects[redmine] = name }
        }
    }

    /// 프로젝트를 목록에서 숨기거나 다시 보인다. 기록은 그대로 둔다.
    func setHidden(_ name: String, _ hidden: Bool) {
        change { log in
            if hidden { log.hiddenProjects.insert(name) } else { log.hiddenProjects.remove(name) }
        }
    }

    func setRedmineHidden(_ name: String, _ hidden: Bool) {
        change { log in
            if hidden { log.hiddenRedmineProjects.insert(name) } else { log.hiddenRedmineProjects.remove(name) }
        }
    }

    /// 보고서 번호 순서를 바꾼다.
    func moveProject(_ name: String, by offset: Int) {
        guard let index = log.projects.firstIndex(of: name), log.projects.indices.contains(index + offset) else { return }
        change { $0.projects.swapAt(index, index + offset) }
    }

    /// 기록이 없는 프로젝트만 목록에서 뺀다.
    func removeProjectIfEmpty(_ name: String) {
        guard !log.entries.contains(where: { $0.project == name }) else { return }
        change { $0.projects.removeAll { $0 == name } }
    }

    func carryOver(to day: String) -> Int {
        guard let source = log.previousDay(before: day) else { return 0 }
        var copy = log
        let count = copy.carryOver(from: source, to: day)
        if count > 0 { change { $0 = copy } }
        return count
    }

    func importReport(_ text: String, day: String) -> Int {
        let entries = WorkReport.parse(text, day: day)
        guard !entries.isEmpty else { return 0 }
        change { log in
            for entry in entries { log.register(project: entry.project) }
            log.entries += entries
        }
        return entries.count
    }

    /// 가져온 MR·커밋을 넣는다. 넣거나 고친 줄 수.
    func applyCapture(mrs: [WorkCapture.MergedMR], commits: [WorkCapture.Commit]) -> Int {
        var copy = log
        let count = WorkCapture.apply(mrs: mrs, commits: commits, to: &copy)
        if copy != log { change { $0 = copy } }
        return count
    }

    /// 예전에 가져온 MR 댓글을 레드마인 꼴로 다듬고 일감마다 나눈다. 바뀐 게 없으면 파일을 쓰지 않는다.
    private func tidyMRNotes() {
        var copy = log
        if WorkCapture.tidyMRNotes(&copy) > 0 { change { $0 = copy } }
    }

    func setRecurring(_ items: [RecurringWork]) {
        change {
            $0.recurring = items
            $0.applyRecurring(on: WorkDay.today())
        }
    }

    /// 오늘 요일의 고정 업무를 넣는다 (창을 열 때와 가져올 때).
    func applyRecurringToday() {
        var copy = log
        if copy.applyRecurring(on: WorkDay.today()) > 0 { change { $0 = copy } }
    }

    /// 받은 일감을 장부에 넣는다. 배정 목록을 통째로 받았으면 거기 없는 일감은 내 일감에서 뺀다.
    func updateIssues(_ infos: [IssueInfo], assignedIDs: Set<Int>?) {
        change { log in
            if let assignedIDs {
                for (key, info) in log.issues where info.assigned && !assignedIDs.contains(info.id) {
                    log.issues[key]?.assigned = false
                }
            }
            for var info in infos {
                let key = String(info.id)
                if let old = log.issues[key] {
                    // 배정 목록을 받지 않은 조회는 내 일감 여부를 모르니 있던 값을 둔다
                    if assignedIDs == nil { info.assigned = old.assigned }
                    // 받기를 시작한 뒤에 보낸 진척률은 늦게 끝난 받기가 옛 값으로 덮지 않게 둔다
                    if old.fetchedAt > info.fetchedAt {
                        info.doneRatio = old.doneRatio
                        info.status = old.status
                        info.statusID = old.statusID ?? info.statusID
                        info.startDate = old.startDate ?? info.startDate
                        info.dueDate = old.dueDate ?? info.dueDate
                        info.assignee = old.assignee ?? info.assignee
                    }
                }
                log.issues[key] = info
            }
        }
        // 일감 제목을 받았으니 MR 댓글을 일감마다 다시 나눈다
        tidyMRNotes()
    }

    /// 보낸 진척률·상태·날짜를 장부에도 적어, 다시 받기 전에도 화면이 새 값을 보이게 한다.
    func setIssueState(_ id: Int, ratio: Int?, fields: WorkReport.IssueFields) {
        let key = String(id)
        guard log.issues[key] != nil, ratio != nil || !fields.isEmpty else { return }
        change { log in
            if let ratio { log.issues[key]?.doneRatio = ratio }
            if let status = fields.status {
                log.issues[key]?.status = status.name
                log.issues[key]?.statusID = status.id
            }
            if let start = fields.startDate { log.issues[key]?.startDate = start }
            if let due = fields.dueDate { log.issues[key]?.dueDate = due }
            if let assignee = fields.assignee { log.issues[key]?.assignee = assignee }
            log.issues[key]?.fetchedAt = Date()
        }
    }

    /// 레드마인 프로젝트를 보고서에서 부를 이름.
    func setReportProject(_ name: String, for redmineProject: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        change { log in
            log.redmineProjects[redmineProject] = trimmed.isEmpty ? nil : trimmed
            if !trimmed.isEmpty { log.register(project: trimmed) }
        }
    }

    /// 내 일감을 고른 날 일지에 넣는다. 이미 그날 그 일감 줄이 있으면 상태만 바꾼다.
    /// `again`이면 같은 일감 줄을 하나 더 넣는다 (한 일감에 따로 적을 일이 여럿인 날). 보낼 때 일감별로 한 댓글로 모인다.
    @discardableResult
    func addIssue(_ info: IssueInfo, day: String, status: WorkStatus, again: Bool = false) -> WorkEntry? {
        if !again, let index = log.entries.firstIndex(where: { $0.day == day && $0.issue == info.id }) {
            update(log.entries[index].id) { $0.status = status }
            return log.entries[index]
        }
        let project = log.reportProject(for: info)
        let entry = WorkEntry(day: day, project: project, title: info.reportTitle, status: status, issue: info.id)
        change {
            $0.register(project: project)
            $0.entries.append(entry)
        }
        return entry
    }

    /// 보낸 기록을 맨 앞에 쌓는다. 오래된 것은 100건까지만 둔다.
    func addSent(_ record: RedmineSent) {
        change { log in
            log.sent.insert(record, at: 0)
            if log.sent.count > 100 { log.sent.removeLast(log.sent.count - 100) }
        }
    }

    /// 되돌린 건: 그 줄들을 다시 보낼 목록으로 돌리고, 지운 작업 시간은 다시 남길 수 있게 한다.
    func markUndone(_ record: RedmineSent) {
        let ids = Set(record.entryIDs)
        change { log in
            if let index = log.sent.firstIndex(where: { $0.id == record.id }) { log.sent[index].undoneAt = Date() }
            for index in log.entries.indices where ids.contains(log.entries[index].id) {
                if !record.note.isEmpty { log.entries[index].postedAt = nil }
                if !record.timeEntryIDs.isEmpty { log.entries[index].timeLogged = false }
            }
        }
    }

    func markPosted(_ ids: [UUID]) {
        let now = Date()
        change { log in
            for index in log.entries.indices where ids.contains(log.entries[index].id) {
                // 고친 때보다 늦게 찍어야 다시 올릴 목록에서 빠진다
                log.entries[index].postedAt = max(now, log.entries[index].updatedAt)
            }
        }
    }
}
