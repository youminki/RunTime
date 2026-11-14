import Foundation
import WorkLogCore

/// `--worklog-flow`: 일지를 레드마인으로 보내는 길을 가짜 응답으로 돌려 나가는 요청과 보냄 표시를 살핀다.
/// 내용이 빠지거나 겹치면 동료가 보는 일감에 남아 고칠 수 없어, 실패 때 줄이 남는지까지 본다. 서버에는 보내지 않는다.
@MainActor
enum WorkLogFlowCheck {
    /// 일지와 설정을 읽기 전에 불러 시험용 파일을 가리킨다.
    static func prepare() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-worklog-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("RUNTIME_WORKLOG", folder.appendingPathComponent("worklog.json").path, 1)
        setenv("RUNTIME_REDMINE_URL", "https://example.com", 1)
        setenv("RUNTIME_REDMINE_KEY", "flow", 1)
        setenv("RUNTIME_NO_KEYCHAIN", "1", 1)
        return folder
    }

    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool) {
        print((ok ? "통과  " : "실패  ") + name)
        if !ok { failures += 1 }
    }

    private static func issue(_ id: Int, status: Int = 1, ratio: Int = 0) -> Data {
        Data(#"{"issue":{"id":\#(id),"subject":"일감","project":{"id":1,"name":"시험"},"tracker":{"id":1,"name":"작업"},"status":{"id":\#(status),"name":"할일"},"priority":{"id":2,"name":"보통"},"done_ratio":\#(ratio),"journals":[]}}"#.utf8)
    }

    /// 나간 PUT의 본문.
    private static var puts: [[String: Any]] = []

    /// 지금 값을 읽으면 `read`로, 고치면 `write`로 답한다.
    private static func answer(read: Int = 200, write: @escaping ([String: Any]) -> Int = { _ in 204 }, id: Int) {
        puts = []
        WorkLogSync.stub = { request in
            guard request.httpMethod == "PUT" else { return (read, read == 200 ? issue(id) : nil) }
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let fields = body?["issue"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { puts.append(fields) }
            return (write(fields), Data())
        }
    }

    /// 되돌릴 때 나간 PUT 주소.
    private static var paths: [String] = []

    /// 한 줄을 보낸 뒤 레드마인에 그 댓글이 있는 것처럼 답하고 되돌린다.
    private static func undo(issue id: Int, clear: Int, then check: ([String], UUID?) -> Void) async {
        let row = line(id)
        answer(id: id)
        _ = await send(id)
        await Task.yield()
        guard let record = WorkLogStore.shared.log.sent.last(where: { $0.issue == id }) else { return check(["보낸 기록 없음"], row) }
        let notes = try? JSONSerialization.data(withJSONObject: [record.note])
        let quoted = notes.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let now = ISO8601DateFormatter().string(from: Date())
        let body = #"{"issue":{"id":\#(id),"subject":"일감","project":{"id":1,"name":"시험"},"tracker":{"id":1,"name":"작업"},"status":{"id":1,"name":"할일"},"priority":{"id":2,"name":"보통"},"done_ratio":60,"journals":[{"id":5,"user":{"id":7,"name":"나"},"notes":\#(quoted),"created_on":"\#(now)"}]}}"#
        paths = []
        WorkLogSync.stub = { request in
            guard request.httpMethod == "PUT" else { return (200, Data(body.utf8)) }
            let path = request.url?.path ?? ""
            DispatchQueue.main.async { paths.append(path) }
            return (path.contains("journals") ? clear : 204, Data())
        }
        let problems: [String] = await withCheckedContinuation { continuation in
            WorkLogSync.shared.undo(record) { problems, _ in continuation.resume(returning: problems) }
        }
        await Task.yield()
        check(problems, row)
    }

    private static func send(_ issue: Int, edits: [Int: WorkReport.IssueEdit] = [:], withoutNotes: Set<Int> = []) async -> (sent: Int, failures: [String]) {
        let store = WorkLogStore.shared
        let updates = WorkReport.redmineUpdates(store.log.entries.filter { $0.issue == issue && $0.needsRedmine }, log: store.log)
        return await withCheckedContinuation { continuation in
            WorkLogSync.shared.send(updates, edits: edits, withoutNotes: withoutNotes) { sent, failures in
                continuation.resume(returning: (sent, failures))
            }
        }
    }

    private static func line(_ issue: Int, _ title: String = "한 일") -> UUID? {
        let store = WorkLogStore.shared
        guard let entry = store.add(day: WorkDay.today(), project: "시험", title: title, status: .percent(60)) else { return nil }
        store.update(entry.id) { $0.issue = issue }
        return entry.id
    }

    private static func waiting(_ id: UUID?) -> Bool { id.flatMap(WorkLogStore.shared.entry)?.needsRedmine == true }

    static func run(folder: URL) {
        Task {
            await flow()
            WorkLogSync.stub = nil
            print(failures == 0 ? "일지 보내기 흐름 모두 통과" : "일지 보내기 흐름 실패 \(failures)건")
            try? FileManager.default.removeItem(at: folder)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func flow() async {
        let sync = WorkLogSync.shared, settings = WorkLogSettings.shared
        settings.syncIssueFields = false
        settings.attachScreens = false
        sync.statuses = [RedmineAPI.Status(id: 1, name: "할일", isClosed: false), RedmineAPI.Status(id: 2, name: "완료", isClosed: true)]

        let edits = ["2026-11-02": ["고친 글", "일지 글"], "2026-11-03": ["늦은 글", "일지 글"]]
        check("저장한 적 없으면 가장 늦은 날짜별 계획을 쓴다", WorkLogPage.restoredPlanTemplate(saved: nil, edits: edits)?.text == "늦은 글")
        check("저장한 계획을 그대로 읽는다", WorkLogPage.restoredPlanTemplate(saved: ["2026-11-04", "저장 글"], edits: edits)?.day == "2026-11-04")
        check("지운 계획은 날짜별 글에서 되살리지 않는다", WorkLogPage.restoredPlanTemplate(saved: [], edits: edits) == nil)

        func listed(ratio: Int) -> Data {
            Data(#"{"issues":[{"id":20,"subject":"일감","project":{"id":1,"name":"시험"},"tracker":{"id":1,"name":"작업"},"status":{"id":1,"name":"할일"},"priority":{"id":2,"name":"보통"},"done_ratio":\#(ratio)}],"total_count":1,"offset":0,"limit":100}"#.utf8)
        }
        let before = listed(ratio: 10), after = listed(ratio: 70)
        WorkLogSync.stub = { _ in (200, before) }
        sync.loadInfo([20])
        try? await Task.sleep(nanoseconds: 300_000_000)
        WorkLogSync.stub = { _ in (200, after) }
        sync.refreshInfo([20])
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("레드마인 화면에서 고친 일감을 장부에 다시 받는다", WorkLogStore.shared.log.issue(20)?.doneRatio == 70)

        var row = line(1)
        answer(id: 1)
        var result = await send(1)
        await Task.yield()
        check("댓글과 진척률이 한 번 나가고 줄이 보냄이 된다",
              result.sent == 1 && puts.count == 1 && puts[0]["notes"] != nil && puts[0]["done_ratio"] as? Int == 60 && !waiting(row))

        row = line(2)
        answer(write: { _ in 500 }, id: 2)
        result = await send(2)
        check("보내기가 실패하면 줄이 남고 까닭을 알린다", result.sent == 0 && !result.failures.isEmpty && waiting(row))

        // 시간 초과로 끊겼지만 레드마인에는 댓글이 저장된 경우: 다시 보내면 같은 댓글을 또 올리지 않는다
        let ledger = WorkLogStore.shared.log
        if let pending = WorkReport.redmineUpdates(ledger.entries.filter { $0.issue == 2 && $0.needsRedmine }, log: ledger).first {
            let stored = settings.redmineHTML ? RedmineNote.html(pending.note) : pending.note
            let quoted = (try? JSONSerialization.data(withJSONObject: [stored])).flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) } ?? "\"\""
            let now = ISO8601DateFormatter().string(from: Date())
            let body = #"{"issue":{"id":2,"subject":"일감","project":{"id":1,"name":"시험"},"tracker":{"id":1,"name":"작업"},"status":{"id":1,"name":"할일"},"priority":{"id":2,"name":"보통"},"done_ratio":0,"journals":[{"id":9,"user":{"id":7,"name":"나"},"notes":\#(quoted),"created_on":"\#(now)"}]}}"#
            puts = []
            WorkLogSync.stub = { request in
                guard request.httpMethod == "PUT" else { return (200, Data(body.utf8)) }
                let fields = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["issue"] as? [String: Any] ?? [:]
                DispatchQueue.main.async { puts.append(fields) }
                return (204, Data())
            }
            result = await send(2)
            await Task.yield()
            check("끊긴 뒤 다시 보내면 이미 올라간 댓글은 빼고 진척률만 보낸다",
                  puts.count == 1 && (puts[0]["notes"] as? String ?? "").isEmpty && puts[0]["done_ratio"] as? Int == 60 && !waiting(row))
        } else {
            check("끊긴 뒤 다시 보낼 줄이 남아 있다", false)
        }

        row = line(3)
        answer(read: 500, id: 3)
        result = await send(3, edits: [3: WorkReport.IssueEdit(statusID: 2)])
        check("지금 값을 못 읽으면 고른 상태를 버리고 보내지 않는다", puts.isEmpty && result.sent == 0 && !result.failures.isEmpty && waiting(row))

        row = line(4)
        answer(write: { $0["status_id"] != nil ? 422 : 204 }, id: 4)
        result = await send(4, edits: [4: WorkReport.IssueEdit(statusID: 2)])
        await Task.yield()
        check("상태가 막히면 댓글은 잃지 않고 칸만 빼고 다시 보낸다",
              puts.count == 2 && puts[1]["status_id"] == nil && puts[1]["notes"] != nil && !result.failures.isEmpty)

        row = line(5)
        answer(id: 5)
        result = await send(5, withoutNotes: [5])
        await Task.yield()
        check("댓글을 뺀 일감은 진척률만 나간다", puts.count == 1 && (puts[0]["notes"] as? String)?.isEmpty != false && puts[0]["done_ratio"] as? Int == 60)

        row = line(6)
        answer(read: 500, id: 6)
        result = await send(6, withoutNotes: [6])
        check("댓글을 빼고 지금 값도 못 읽으면 표시하지 않는다", puts.isEmpty && waiting(row))

        row = line(7)
        answer(id: 7)
        let store = WorkLogStore.shared
        let updates = WorkReport.redmineUpdates(store.log.entries.filter { $0.issue == 7 }, log: store.log)
        var second: [String]?
        let first: Void = await withCheckedContinuation { continuation in
            sync.send(updates) { _, _ in continuation.resume() }
            sync.send(updates) { _, failures in second = failures }
        }
        _ = first
        await Task.yield()
        check("보내는 중에 또 눌러도 한 번만 나간다", puts.count == 1 && second?.isEmpty == false)

        await undo(issue: 8, clear: 204) { problems, row in
            check("되돌리면 칸과 댓글을 되돌리고 줄이 다시 보낼 목록에 온다",
                  problems.isEmpty && waiting(row) && paths.contains("/issues/8.json") && paths.contains("/journals/5.json"))
        }
        await undo(issue: 9, clear: 500) { problems, row in
            check("댓글을 못 지우면 줄을 돌리지 않아 두 번 올라가지 않는다", !problems.isEmpty && !waiting(row))
        }
    }
}
