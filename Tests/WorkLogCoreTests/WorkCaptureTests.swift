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
