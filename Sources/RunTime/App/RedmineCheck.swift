import Foundation
import WorkLogCore

/// `--redmine-check <일감>`: 실제 레드마인에 앱 코드 그대로 시험 댓글을 보내고 되돌린다.
@MainActor
enum RedmineCheck {
    static func run(issue: Int) {
        let settings = WorkLogSettings.shared
        let sync = WorkLogSync.shared
        let store = WorkLogStore.shared
        guard settings.redmineReady else { finish("레드마인 주소와 키가 없습니다 (RUNTIME_REDMINE_KEY)", ok: false) }
        // 시험 댓글만 보낸다: 상태·날짜 맞추기는 이번 실행에서만 끈다
        let fields = settings.syncIssueFields
        settings.syncIssueFields = false
        let note = "[작업 내용]\n- RunTime 업무 일지 연동 시험 (줄바꿈 확인)\n- 곧 지웁니다\n\n[비고]\n- 앱이 보낸 댓글을 앱이 되돌리는지 확인"
        // 진행중은 진척률이 없어 댓글만 나간다
        let entry = WorkEntry(day: WorkDay.today(), project: "점검", title: "연동 시험", status: .inProgress, issue: issue, note: note)
        guard let update = WorkReport.redmineUpdates([entry]).first, update.doneRatio == nil else { finish("시험 줄을 만들지 못했습니다", ok: false) }
        print("보내는 HTML:\n" + RedmineNote.html(note))
        sync.send([update]) { sent, failures in
            print("보냄 \(sent)건 \(failures)")
            guard let record = store.log.sent.first(where: { $0.issue == issue && $0.undoneAt == nil }) else {
                restore(); finish("보낸 기록이 없습니다", ok: false)
            }
            journals(issue) { list in
                let match = record.matchJournal(list)
                print("레드마인에 실린 댓글 #\(match?.id ?? 0):\n\(match?.notes ?? "(못 찾음)")")
                sync.undo(record) { problems, manual in
                    print("되돌리기 문제: \(problems) 직접 지울 댓글: \(manual.map(String.init) ?? "없음")")
                    journals(issue) { after in
                        let left = after.contains { $0.id == match?.id && !$0.notes.isEmpty }
                        restore()
                        finish(left ? "댓글이 남아 있습니다" : "댓글이 지워졌습니다", ok: match != nil && !left && problems.isEmpty)
                    }
                }
            }
        }

        func restore() {
            settings.syncIssueFields = fields
        }
    }

    /// `--redmine-check dupes`: 보낼 목록의 일감마다 비슷한 댓글이 이미 있는지만 읽어 본다 (쓰지 않는다).
    static func dupes() {
        let store = WorkLogStore.shared
        let sync = WorkLogSync.shared
        // 일감 제목을 먼저 받아야 MR 댓글이 일감마다 나뉜다
        sync.loadMyIssues { check(store: store, sync: sync) }
    }

    private static func check(store: WorkLogStore, sync: WorkLogSync) {
        let updates = WorkReport.redmineUpdates(store.log.entries.filter(\.needsRedmine), log: store.log)
        print("보낼 일감 \(updates.count)건")
        for update in updates { print("#\(update.issue)\n\(update.note)\n") }
        sync.checkPosted(updates)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            for update in updates {
                let hit = sync.postedHints[update.issue]
                print("#\(update.issue): " + (hit.map { "이미 있음 (댓글 \($0.id), \(WorkLogFormat.when($0.createdOn)))" } ?? "없음"))
            }
            exit(0)
        }
    }

    /// `--redmine-check screens <일감>`: 그 일감 줄이 온 MR의 수정 전·후 화면을 받아 레드마인에 올려만 보고
    /// (일감에 붙이지 않은 업로드는 어디에도 보이지 않는다), 보낼 댓글과 함께 바꿀 상태를 찍는다. 일감은 고치지 않는다.
    static func screens(issue: Int) {
        let settings = WorkLogSettings.shared
        let store = WorkLogStore.shared
        let sync = WorkLogSync.shared
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else {
            finish("레드마인 주소와 키가 없습니다", ok: false)
        }
        let entries = store.log.entries.filter { $0.issue == issue }
        guard let update = WorkReport.redmineUpdates(entries, log: store.log).first(where: { $0.issue == issue }) ?? nil else {
            finish("#\(issue) 줄이 일지에 없습니다", ok: false)
        }
        let origins = MRScreenStore.origins(entries.map(\.source))
        let fields = sync.fields(for: update)
        print("진척률: \(update.doneRatio.map { "\($0)%" } ?? "그대로"), 상태: \(store.log.issue(issue)?.status ?? "?") → \(fields.status?.name ?? "그대로")")
        let html = settings.redmineHTML
        let host = settings.gitlabHost
        DispatchQueue.global().async {
            let refs = origins.compactMap { MRScreenStore.shared.refForSending($0, host: host) }
            print("MR: " + (refs.isEmpty ? "없음 (\(origins))" : refs.map { "\($0.path)!\($0.iid)" }.joined(separator: ", ")))
            let result = WorkLogSync.attachScreens(refs, base: base, key: key, host: host, html: html)
            DispatchQueue.main.async {
                print("올린 첨부 \(result.uploads.count)개: " + result.uploads.map(\.filename).joined(separator: ", "))
                if !result.failures.isEmpty { print("문제: \(result.failures)") }
                print("보낼 댓글:\n" + (html ? RedmineNote.html(update.note) : update.note) + "\n" + result.section)
                finish(result.uploads.isEmpty ? "붙일 화면 없음" : "통과", ok: true)
            }
        }
    }

    private static func journals(_ issue: Int, _ done: @escaping ([RedmineAPI.Journal]) -> Void) {
        let settings = WorkLogSettings.shared
        guard let base = RedmineAPI.baseURL(settings.effectiveRedmineURL), let key = settings.redmineKey else { return done([]) }
        URLSession.shared.dataTask(with: RedmineAPI.issueWithJournalsRequest(base: base, key: key, issue: issue)) { data, _, _ in
            let list = (try? RedmineAPI.parseJournals(data ?? Data())) ?? []
            DispatchQueue.main.async { done(list) }
        }.resume()
    }

    private static func finish(_ message: String, ok: Bool) -> Never {
        print(message)
        WorkLogStore.shared.saveNow()
        exit(ok ? 0 : 1)
    }
}
