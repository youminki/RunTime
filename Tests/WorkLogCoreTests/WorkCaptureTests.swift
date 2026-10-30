import Foundation
import Testing
@testable import WorkLogCore

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Suite struct WorkCaptureTests {
    @Test func readsGitLabMergedMRs() throws {
        let json = """
        [{"iid":14,"title":"데스티네이션 관리 API 연동","description":"[작업 내용]\\n- 목록 API","source_branch":"feat/destination-api",
          "merged_at":"2026-10-20T06:59:51.644Z","web_url":"https://git.example.com/velox/velox-web-portal/-/merge_requests/14",
          "references":{"full":"velox/velox-web-portal!14"}},
         {"iid":3,"title":"열린 MR","source_branch":"x","merged_at":null,"references":{"full":"a/b!3"}}]
        """
        let mrs = try WorkCapture.parseMRs(Data(json.utf8))
        #expect(mrs.count == 1)
        #expect(mrs[0].path == "velox/velox-web-portal")
        #expect(mrs[0].description == "[작업 내용]\n- 목록 API")
        let pages = #"[{"iid":1,"title":"a","source_branch":"x","merged_at":"2026-10-20T00:00:00Z","references":{"full":"a/b!1"}}]"#
            + "\n" + #"[{"iid":2,"title":"b","source_branch":"y","merged_at":"2026-10-20T00:00:00Z","references":{"full":"a/b!2"}}]"#
        #expect(try WorkCapture.parseMRs(Data(pages.utf8)).map(\.iid) == [1, 2])
    }

    @Test func readsPagedGitLabResponsesWithoutTouchingText() throws {
        let mr = { (iid: Int) in
            #"{"iid":\#(iid),"title":"[FE][게시판] 목록 ][ 정리","description":"[작업 내용] [연동 API]","source_branch":"x","merged_at":"2026-10-20T00:00:00Z","references":{"full":"a/b!\#(iid)"}}"#
        }
        // 빈 마지막 쪽과 앞에 붙은 안내 문구도 견딘다
        let pages = "glab notice\n[" + mr(1) + "]\n[" + mr(2) + "][]"
        let mrs = try WorkCapture.parseMRs(Data(pages.utf8))
        #expect(mrs.map(\.iid) == [1, 2])
        #expect(mrs[0].title == "[FE][게시판] 목록 ][ 정리")
        #expect(try WorkCapture.parseMRs(Data("[]".utf8)).isEmpty)
    }

    @Test func explainsNonListGitLabResponses() {
        #expect(throws: WorkCapture.GitLabResponseError(message: "401 Unauthorized")) {
            try WorkCapture.parseMRs(Data(#"{"message":"401 Unauthorized"}"#.utf8))
        }
        #expect(throws: WorkCapture.GitLabResponseError(message: "빈 응답이 왔습니다")) {
            try WorkCapture.parseMRs(Data())
        }
        #expect(throws: WorkCapture.GitLabResponseError.self) {
            try WorkCapture.parseMRs(Data("\n<!DOCTYPE html><script>var a = []</script>".utf8))
        }
        #expect(WorkCapture.hostName(" https://Git.Example.com/group/ ") == "git.example.com")
        #expect(WorkCapture.hostName("git.example.com") == "git.example.com")
    }

    @Test func findsProjectAcrossRemotesAndSkipsMergedBranches() {
        let remotes = "remote.origin.url https://github.com/me/x.git\nremote.upstream.url git@Git.Example.com:team/x.git"
        #expect(WorkCapture.projectPath(remotes: remotes, host: "git.example.com", mrPaths: []) == "team/x")
        let fork = "remote.origin.url git@git.example.com:me/x.git\nremote.upstream.url git@git.example.com:team/x.git"
        #expect(WorkCapture.projectPath(remotes: fork, host: "git.example.com", mrPaths: ["team/x"]) == "team/x")
        #expect(WorkCapture.namespacePath(remote: "https://git.example.com.evil.io/a/b.git", host: "git.example.com") == nil)
        #expect(WorkCapture.branchName("refs/stash") == nil)
        let mr = WorkCapture.MergedMR(path: "team/x", iid: 1, title: "t", description: "", sourceBranch: "feat/a",
                                      mergedAt: Date(), targetBranch: "epic/login")
        let refs = ["refs/remotes/origin/epic/login", "refs/heads/feat/a", "refs/remotes/origin/feat/b", "refs/heads/main"]
        #expect(WorkCapture.mergedRefs([mr], path: "team/x", refs: refs) == ["refs/remotes/origin/epic/login", "refs/heads/feat/a"])
        #expect(WorkCapture.mergedRefs([mr], path: "other/y", refs: refs).isEmpty)
    }

    @Test func readsGitLogAndRemotes() {
        let text = "refs/remotes/origin/feat/x\u{1F}feat(dest): 연결 테스트\u{1F}2026-10-20T10:00:00+09:00\nrefs/tags/v1\u{1F}t\u{1F}2026-10-20T10:00:00+09:00"
        let commits = WorkCapture.parseCommits(text, path: "velox/portal")
        #expect(commits.map(\.branch) == ["feat/x"])
        #expect(WorkCapture.namespacePath(remote: "https://git.example.com/velox/velox-web-portal.git", host: "git.example.com") == "velox/velox-web-portal")
        #expect(WorkCapture.namespacePath(remote: "git@git.example.com:cdh/cdh-web-admin.git", host: "git.example.com") == "cdh/cdh-web-admin")
        #expect(WorkCapture.namespacePath(remote: "https://github.com/a/b.git", host: "git.example.com") == nil)
    }

    @Test func cleansTitlesAndFindsIssues() {
        #expect(WorkCapture.cleanTitle("feat(destination): 수정 화면 연결") == "수정 화면 연결")
        #expect(WorkCapture.cleanTitle("Draft: Resolve \"QA 반영\"") == "QA 반영")
        #expect(WorkCapture.cleanTitle("fix : 위젯 수정 화면 UI 정리") == "위젯 수정 화면 UI 정리")
        #expect(WorkCapture.cleanTitle("feat(portal) : 마이페이지") == "마이페이지")
        #expect(WorkCapture.issueNumber(in: ["QA 반영 #4512"]) == 4512)
        #expect(WorkCapture.issueNumber(in: ["x"], branch: "feature/45123-pipeline") == 45123)
        #expect(WorkCapture.issueNumber(in: ["x"], branch: "feat/destination-api") == nil)
        #expect(WorkCapture.issueNumber(in: ["x"], branch: "fix/qa-1020-dataset-agent") == nil)
        #expect(WorkCapture.issueNumber(in: ["x"], branch: "fix/#1020") == 1020)
        #expect(WorkCapture.isHousekeeping("chore: update Swagger API"))
        #expect(!WorkCapture.isHousekeeping("feat: 목록 연동"))
        #expect(WorkCapture.sharedBranches(["refs/remotes/origin/dev", "refs/remotes/origin/feat/x", "refs/remotes/origin/release/1.2", "refs/heads/main"])
                == ["refs/remotes/origin/dev", "refs/remotes/origin/release/1.2"])
    }

    @Test func commitsBecomeProgressThenMRMarksDone() {
        var log = WorkLog(projects: ["VeloX"])
        let commits = [
            WorkCapture.Commit(path: "velox/portal", branch: "feat/dest", subject: "feat: 목록 연동", date: at("2026-10-20T01:00:00Z")),
            WorkCapture.Commit(path: "velox/portal", branch: "feat/dest", subject: "fix: 상세 연동", date: at("2026-10-20T02:00:00Z")),
        ]
        #expect(WorkCapture.apply(mrs: [], commits: commits, to: &log) == 1)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].project == "VeloX")   // velox 묶음이 대소문자만 다른 기존 프로젝트로 간다
        #expect(log.entries[0].status == .inProgress)
        #expect(log.entries[0].note == "[작업 내용]\n- 목록 연동\n- 상세 연동")
        #expect(WorkCapture.apply(mrs: [], commits: commits, to: &log) == 0)   // 다시 가져와도 그대로

        log.entries[0].issue = 4512   // 사용자가 일감을 골라 둠
        let mr = WorkCapture.MergedMR(path: "velox/portal", iid: 14, title: "데스티네이션 API 연동",
                                      description: "[작업 내용]\n- 목록·상세 API", sourceBranch: "feat/dest",
                                      mergedAt: at("2026-10-20T05:00:00Z"))
        #expect(WorkCapture.apply(mrs: [mr], commits: commits, to: &log) == 1)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].status == .done)
        #expect(log.entries[0].title == "데스티네이션 API 연동")
        #expect(log.entries[0].issue == 4512)
        #expect(log.entries[0].note == "[작업 내용]\n- 목록·상세 API\n\n[비고]\n- MR !14")   // 레드마인 댓글 꼴로
    }

    @Test func rereadsMRDescriptionEditedAfterImport() {
        // velox !15: 번호 없이 가져온 뒤 MR 설명 맨 위에 [일감]을 달았다 (2026-10-21)
        var log = WorkLog(projects: ["velox"])
        let before = WorkCapture.MergedMR(path: "velox/velox-web-portal", iid: 15, title: "수집 작업 관리 API 연동과 시안 차이 보정",
                                          description: "[작업 내용]\n- 수집 작업 관리 목록, 상세, 등록 화면을 API에 연동",
                                          sourceBranch: "feature/collection-job-api", mergedAt: at("2026-10-21T07:24:53Z"))
        WorkCapture.apply(mrs: [before], commits: [], to: &log)
        #expect(log.entries.map(\.issue) == [nil])
        #expect(WorkCapture.apply(mrs: [before], commits: [], to: &log) == 0)   // 그대로면 건드리지 않는다

        let after = WorkCapture.MergedMR(path: before.path, iid: 15, title: before.title,
                                         description: "[일감]\n- #36397 [FN-ING-07] 데이터 수집 작업 제어 > API 연동\n- #36415 [FN-ING-13] 데이터 수집 로그 조회 > API 연동\n\n"
                                            + before.description,
                                         sourceBranch: before.sourceBranch, mergedAt: before.mergedAt)
        #expect(WorkCapture.apply(mrs: [after], commits: [], to: &log) == 1)
        #expect(log.entries.map(\.issue) == [36397, 36415])
        #expect(!log.entries[0].note.contains("[일감]"))
        #expect(WorkCapture.apply(mrs: [after], commits: [], to: &log) == 0)

        log.entries[0].postedAt = Date()
        // 보낸 줄은 설명이 바뀌어도 댓글을 그대로 둔다
        let edited = WorkCapture.MergedMR(path: before.path, iid: 15, title: before.title, description: after.description + "\n- 로그 조회 검색어 덧붙임",
                                          sourceBranch: before.sourceBranch, mergedAt: before.mergedAt)
        WorkCapture.apply(mrs: [edited], commits: [], to: &log)
        #expect(!log.entries[0].note.contains("덧붙임"))
        #expect(log.entries[1].note.contains("덧붙임"))
    }

    @Test func addsNewlyListedIssuesEvenAfterTheMRLineWasSent() {
        // velox !15 실제 경우: #36406을 골라 레드마인에 보낸 뒤 MR 설명에 [일감] 넷을 달았다
        var log = WorkLog(projects: ["velox"])
        let body = "[작업 내용]\n- 수집 작업 관리 목록, 상세, 등록 화면을 API에 연동"
        log.entries = [WorkEntry(day: "2026-10-21", project: "velox", title: "수집 작업 관리 API 연동", issue: 36406, note: body,
                                 postedAt: Date(), source: "mr:velox/velox-web-portal!15", mrBody: body)]
        let sentNote = log.entries[0].note
        let mr = WorkCapture.MergedMR(path: "velox/velox-web-portal", iid: 15, title: "수집 작업 관리 API 연동",
                                      description: "[일감]\n- #36397 작업 제어 > API 연동\n- #36415 로그 조회 > API 연동\n- #36406 동기화 이력 > API 연동\n\n" + body,
                                      sourceBranch: "feature/collection-job-api", mergedAt: at("2026-10-21T07:24:53Z"))
        WorkCapture.apply(mrs: [mr], commits: [], to: &log)
        #expect(log.entries.map(\.issue) == [36406, 36397, 36415])
        #expect(log.entries[0].note == sentNote)
        #expect(log.entries[1].title == "작업 제어 > API 연동")
        #expect(log.entries[1].postedAt == nil && log.entries[1].note.hasPrefix("[작업 내용]"))
        #expect(WorkCapture.apply(mrs: [mr], commits: [], to: &log) == 0)
    }

    @Test func keepsUserEditsAndRemembersDeletes() {
        var log = WorkLog()
        let commit = WorkCapture.Commit(path: "cdh/admin", branch: "fix/a", subject: "fix: 아이콘", date: at("2026-10-20T01:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [commit], to: &log)
        log.entries[0].note = "직접 쓴 댓글"
        let later = WorkCapture.Commit(path: "cdh/admin", branch: "fix/a", subject: "fix: 크기", date: at("2026-10-20T02:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [commit, later], to: &log)
        #expect(log.entries[0].note == "직접 쓴 댓글")

        log.remove(log.entries[0].id)
        #expect(WorkCapture.apply(mrs: [], commits: [commit, later], to: &log) == 0)
        #expect(log.entries.isEmpty)
    }

    @Test func buildsRedmineRequests() throws {
        let base = try #require(RedmineAPI.baseURL("https://its.example.com/"))
        let request = try RedmineAPI.updateRequest(base: base, key: "k", issue: 12, doneRatio: 80, note: "[작업 내용]\n- a")
        #expect(request.url?.absoluteString == "https://its.example.com/issues/12.json")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "X-Redmine-API-Key") == "k")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: [String: Any]]
        #expect(body?["issue"]?["done_ratio"] as? Int == 80)
        #expect(body?["issue"]?["status_id"] == nil)
        let issues = try RedmineAPI.parseIssues(Data(#"{"issues":[{"id":12,"subject":"API","project":{"name":"VeloX"},"status":{"name":"진행"},"done_ratio":40}]}"#.utf8))
        #expect(issues == [RedmineAPI.Issue(id: 12, subject: "API", project: "VeloX", status: "진행", doneRatio: 40)])
        let config = #"{"projects":{"/x":{"mcpServers":{"redmine":{"env":{"REDMINE_URL":"https://its.example.com","REDMINE_API_KEY":"abc"}}}}}}"#
        #expect(RedmineAPI.mcpCredentials(in: Data(config.utf8))?.key == "abc")
    }

    @Test func carriedBranchLineStillTurnsDoneAndPostedLineSendsOnlyNewCommits() {
        var log = WorkLog()
        let monday = WorkCapture.Commit(path: "v/p", branch: "feat/a", subject: "feat: 목록", date: at("2026-10-19T01:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [monday], to: &log)
        log.carryOver(from: "2026-10-19", to: "2026-10-20")
        let tuesday = WorkCapture.Commit(path: "v/p", branch: "feat/a", subject: "feat: 상세", date: at("2026-10-20T01:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [tuesday], to: &log)
        #expect(log.entries(on: "2026-10-20").count == 1)   // 이어 쓴 줄에 붙고 새 줄이 생기지 않는다

        let index = log.entries.firstIndex { $0.day == "2026-10-20" }!
        log.entries[index].issue = 7
        // 보낸 기록 없이 "보낸 것으로 표시"만 한 줄: 표시한 뒤의 커밋만 새것이다
        log.entries[index].postedAt = at("2026-10-20T02:00:00Z")
        log.entries[index].updatedAt = at("2026-10-20T01:30:00Z")
        let later = WorkCapture.Commit(path: "v/p", branch: "feat/a", subject: "feat: 삭제", date: at("2026-10-20T03:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [tuesday, later], to: &log, now: at("2026-10-20T04:00:00Z"))
        // 보낸 커밋(상세)은 다시 올리지 않고, 보낸 뒤 한 커밋만 다시 보낼 목록에 오른다
        #expect(log.entries[index].needsRedmine)
        #expect(log.entries[index].note == "[작업 내용]\n- 삭제")
        // 다시 가져와도 표시 전 커밋(상세)을 되살리지 않는다
        #expect(WorkCapture.apply(mrs: [], commits: [tuesday, later], to: &log, now: at("2026-10-20T04:10:00Z")) == 0)
        #expect(log.entries[index].note == "[작업 내용]\n- 삭제")

        let mr = WorkCapture.MergedMR(path: "v/p", iid: 1, title: "A 연동", description: "", sourceBranch: "feat/a",
                                      mergedAt: at("2026-10-20T05:00:00Z"))
        WorkCapture.apply(mrs: [mr], commits: [], to: &log)
        #expect(log.entries[index].status == .done)
    }

    /// 보낸 뒤 같은 날 더 한 커밋은 새 커밋만 다시 보낼 목록에 오른다. 다시 가져와도 보낸 커밋은 되살아나지 않는다.
    @Test func commitsAfterSendingBecomeANewNote() {
        var log = WorkLog(projects: ["VeloX"])
        let first = WorkCapture.Commit(path: "velox/portal", branch: "feat/dest", subject: "feat: 목록 연동", date: at("2026-10-20T01:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [first], to: &log)
        let id = log.entries[0].id
        log.entries[0].issue = 4512
        let sentAt = log.entries[0].updatedAt.addingTimeInterval(60)
        log.entries[0].postedAt = sentAt
        log.sent = [RedmineSent(issue: 4512, sentAt: sentAt, entryIDs: [id], note: "<p>[작업 내용]<br />\n- 목록 연동</p>",
                                before: .init(), after: .init())]
        let later = WorkCapture.Commit(path: "velox/portal", branch: "feat/dest", subject: "fix: 상세 연동", date: at("2026-10-20T06:00:00Z"))
        let now = sentAt.addingTimeInterval(60)
        #expect(WorkCapture.apply(mrs: [], commits: [first, later], to: &log, now: now) == 1)
        #expect(log.entries[0].note == "[작업 내용]\n- 상세 연동")
        #expect(log.entries[0].needsRedmine)
        #expect(WorkCapture.apply(mrs: [], commits: [first, later], to: &log, now: now) == 0)
    }

    /// 이어 쓴 브랜치 줄은 어제 커밋 목록을 옮기지 않고, 오늘 커밋으로 새로 채운다.
    @Test func carriedBranchLineTakesTodaysCommits() {
        var log = WorkLog(projects: ["VeloX"])
        let yesterday = WorkCapture.Commit(path: "velox/portal", branch: "feat/dest", subject: "feat: 목록 연동", date: at("2026-10-20T01:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [yesterday], to: &log)
        let day = log.entries[0].day
        let next = WorkDay.adding(1, to: day)
        #expect(log.carryOver(from: day, to: next) == 1)
        #expect(log.entries[1].note.isEmpty)
        let today = WorkCapture.Commit(path: "velox/portal", branch: "feat/dest", subject: "fix: 상세 연동", date: at("2026-10-21T01:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [yesterday, today], to: &log)
        #expect(log.entries.count == 2)
        #expect(log.entries[1].note == "[작업 내용]\n- 상세 연동")
    }

    /// 예전 판이 stash 커밋으로 만든 줄은 다음 가져오기 때 지운다. 보냈거나 일감을 단 줄은 둔다.
    @Test func dropsStashLinesFromOlderVersions() {
        var log = WorkLog(projects: ["p"])
        log.entries = [
            WorkEntry(day: "2026-10-26", project: "p", title: "index on master: a047254b Merge", status: .inProgress,
                      note: "x", source: "branch:cdh/admin:refs/stash", autoNote: "x"),
            WorkEntry(day: "2026-10-26", project: "p", title: "index on dev", status: .inProgress, issue: 3,
                      note: "x", source: "branch:cdh/admin:refs/stash", autoNote: "x"),
            WorkEntry(day: "2026-10-26", project: "p", title: "feat", status: .inProgress, note: "x", source: "branch:cdh/admin:feat/a", autoNote: "x"),
        ]
        WorkCapture.apply(mrs: [], commits: [], to: &log)
        #expect(log.entries.map(\.title) == ["index on dev", "feat"])
    }
}
