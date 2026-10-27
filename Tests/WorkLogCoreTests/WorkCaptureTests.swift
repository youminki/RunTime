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

    @Test func carriedBranchLineStillTurnsDoneAndPostedLineIsNotResent() {
        var log = WorkLog()
        let monday = WorkCapture.Commit(path: "v/p", branch: "feat/a", subject: "feat: 목록", date: at("2026-10-19T01:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [monday], to: &log)
        log.carryOver(from: "2026-10-19", to: "2026-10-20")
        let tuesday = WorkCapture.Commit(path: "v/p", branch: "feat/a", subject: "feat: 상세", date: at("2026-10-20T01:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [tuesday], to: &log)
        #expect(log.entries(on: "2026-10-20").count == 1)   // 이어 쓴 줄에 붙고 새 줄이 생기지 않는다

        let index = log.entries.firstIndex { $0.day == "2026-10-20" }!
        log.entries[index].issue = 7
        log.entries[index].postedAt = Date()
        let later = WorkCapture.Commit(path: "v/p", branch: "feat/a", subject: "feat: 삭제", date: at("2026-10-20T03:00:00Z"))
        WorkCapture.apply(mrs: [], commits: [tuesday, later], to: &log)
        #expect(!log.entries[index].needsRedmine)

        let mr = WorkCapture.MergedMR(path: "v/p", iid: 1, title: "A 연동", description: "", sourceBranch: "feat/a",
                                      mergedAt: at("2026-10-20T05:00:00Z"))
        WorkCapture.apply(mrs: [mr], commits: [], to: &log)
        #expect(log.entries[index].status == .done)
    }
}
