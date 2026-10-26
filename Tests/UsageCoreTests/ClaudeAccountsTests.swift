import Foundation
import Testing
@testable import UsageCore

struct ClaudeAccountsTests {

    private let config = Data("""
    {"numStartups": 3, "oauthAccount": {"accountUuid": "a-1", "emailAddress": "a@x.com", "organizationType": "claude_pro"},
     "projects": {"/tmp/p": {"allowedTools": []}}}
    """.utf8)

    @Test func readsAccountFromConfig() {
        let info = ClaudeLogin.account(inConfig: config)
        #expect(info?.uuid == "a-1")
        #expect(info?.email == "a@x.com")
        #expect(info?.organizationType == "claude_pro")
    }

    @Test func replacingAccountKeepsOtherKeys() throws {
        let other = Data(#"{"accountUuid": "b-2", "emailAddress": "b@x.com"}"#.utf8)
        let updated = try #require(ClaudeLogin.replacingAccount(inConfig: config, with: other))
        #expect(ClaudeLogin.account(inConfig: updated)?.uuid == "b-2")
        let root = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(root["numStartups"] as? Int == 3)
        #expect((root["projects"] as? [String: Any])?["/tmp/p"] != nil)
    }

    @Test func accountWithoutUuidIsIgnored() {
        #expect(ClaudeLogin.account(inConfig: Data(#"{"oauthAccount": {"emailAddress": "a@x.com"}}"#.utf8)) == nil)
    }

    @Test func autoSwitchPicksAccountWithMostRoom() {
        let now = Date()
        let usage: [String: ClaudeLogin.LastUsage] = [
            "a": .init(sessionPercent: 96, sessionResetsAt: now.addingTimeInterval(3600), weeklyPercent: 40, weeklyResetsAt: nil),
            "b": .init(sessionPercent: 50, sessionResetsAt: now.addingTimeInterval(3600), weeklyPercent: 10, weeklyResetsAt: nil),
            "c": .init(sessionPercent: 20, sessionResetsAt: now.addingTimeInterval(3600), weeklyPercent: 30, weeklyResetsAt: nil),
        ]
        #expect(ClaudeLogin.autoSwitchTarget(current: "a", usage: usage, candidates: ["a", "b", "c"], limit: 95, now: now) == "c")
    }

    @Test func autoSwitchStaysBelowLimit() {
        let now = Date()
        let usage: [String: ClaudeLogin.LastUsage] = [
            "a": .init(sessionPercent: 80, sessionResetsAt: nil, weeklyPercent: 40, weeklyResetsAt: nil),
            "b": .init(sessionPercent: 0, sessionResetsAt: nil, weeklyPercent: 0, weeklyResetsAt: nil),
        ]
        #expect(ClaudeLogin.autoSwitchTarget(current: "a", usage: usage, candidates: ["a", "b"], limit: 95, now: now) == nil)
    }

    @Test func autoSwitchCountsPassedResetAsEmpty() {
        let now = Date()
        let usage: [String: ClaudeLogin.LastUsage] = [
            "a": .init(sessionPercent: 99, sessionResetsAt: now.addingTimeInterval(600), weeklyPercent: 10, weeklyResetsAt: nil),
            "b": .init(sessionPercent: 100, sessionResetsAt: now.addingTimeInterval(-60), weeklyPercent: 20, weeklyResetsAt: nil),
        ]
        #expect(ClaudeLogin.autoSwitchTarget(current: "a", usage: usage, candidates: ["a", "b"], limit: 95, now: now) == "b")
    }

    @Test func autoSwitchSkipsOtherAccountsAtLimit() {
        let now = Date()
        let usage: [String: ClaudeLogin.LastUsage] = [
            "a": .init(sessionPercent: 99, sessionResetsAt: nil, weeklyPercent: 10, weeklyResetsAt: nil),
            "b": .init(sessionPercent: 10, sessionResetsAt: nil, weeklyPercent: 97, weeklyResetsAt: now.addingTimeInterval(86400)),
        ]
        #expect(ClaudeLogin.autoSwitchTarget(current: "a", usage: usage, candidates: ["a", "b"], limit: 95, now: now) == nil)
    }

    /// 실제 키체인에 시험용 항목을 만들었다가 지운다. Claude Code 항목은 건드리지 않는다.
    @Test func keychainWriteRoundTrips() throws {
        let service = "RunTime-test-\(UUID().uuidString)"
        defer {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["delete-generic-password", "-s", service, "-a", NSUserName()]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
        let first = Data(#"{"claudeAiOauth": {"accessToken": "a b \"c\"", "refreshToken": "r"}}"#.utf8)
        #expect(ClaudeLogin.writeKeychain(first, service: service))
        #expect(OAuthUsageProvider.keychainCredentials(service: service) == first)
        let second = Data(#"{"claudeAiOauth": {"accessToken": "next"}}"#.utf8)
        #expect(ClaudeLogin.writeKeychain(second, service: service))
        #expect(OAuthUsageProvider.keychainCredentials(service: service) == second)
        // security -i 한 줄에 담기지 않는 길이도 깨지지 않고 써진다
        for size in [1990, 2010, 5000] {
            let big = Data(repeating: 65, count: size)
            #expect(ClaudeLogin.writeKeychain(big, service: service))
            #expect(ClaudeLogin.readKeychain(service: service, account: NSUserName()) == big)
        }
    }

    @Test func parsesLimitHitLine() throws {
        let line = Data(#"{"type":"assistant","timestamp":"2026-10-12T04:36:58.918Z","apiError":"usage_limit_reached","quotaLimits":{"status":"rejected","resetsAt":1791354000,"rateLimitType":"five_hour"},"isApiErrorMessage":true,"apiErrorStatus":429,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit"}]}}"#.utf8)
        let hit = try #require(JSONLParser.parseLimitHit(line: line))
        #expect(hit.window == .session)
        #expect(hit.resetsAt == Date(timeIntervalSince1970: 1791354000))
        #expect(JSONLParser.parse(line: line) == nil)
    }

    @Test func weeklyLimitHitAndOtherErrors() {
        let weekly = Data(#"{"timestamp":"2026-10-12T04:36:58.918Z","apiError":"usage_limit_reached","quotaLimits":{"resetsAt":1791354000,"rateLimitType":"seven_day_opus"}}"#.utf8)
        #expect(JSONLParser.parseLimitHit(line: weekly)?.window == .weekly)
        let overloaded = Data(#"{"timestamp":"2026-10-12T04:36:58.918Z","apiError":"overloaded","error":"rate_limit"}"#.utf8)
        #expect(JSONLParser.parseLimitHit(line: overloaded) == nil)
    }

    @Test func oauthPartDropsOtherTokensAndMergeKeepsThem() throws {
        let live = Data(#"{"claudeAiOauth":{"accessToken":"b","refreshToken":"rb"},"mcpOAuth":{"srv":{"accessToken":"m"}}}"#.utf8)
        let stored = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"ra"},"mcpOAuth":{"srv":{"accessToken":"old"}}}"#.utf8)
        let part = try #require(ClaudeLogin.oauthPart(of: stored))
        let partRoot = try #require(JSONSerialization.jsonObject(with: part) as? [String: Any])
        #expect(partRoot["mcpOAuth"] == nil)
        let merged = try #require(ClaudeLogin.merging(oauthPart: part, into: live))
        let root = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        #expect((root["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "a")
        #expect(((root["mcpOAuth"] as? [String: Any])?["srv"] as? [String: Any])?["accessToken"] as? String == "m")
        #expect(ClaudeLogin.refreshToken(in: part) == "ra")
    }

    @Test func tokenResponseReplacesTokensAndKeepsPlan() throws {
        let part = Data(#"{"claudeAiOauth": {"accessToken": "old", "refreshToken": "r-old", "expiresAt": 1, "subscriptionType": "pro", "scopes": ["user:inference"]}}"#.utf8)
        let response = Data(#"{"access_token": "new", "refresh_token": "r-new", "expires_in": 28800, "refresh_token_expires_in": 2592000, "scope": "user:inference user:profile", "account": {"uuid": "a-1"}}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_000)
        let result = try #require(ClaudeLogin.applying(tokenResponse: response, to: part, now: now))
        #expect(result.owner == "a-1")
        let oauth = try #require((JSONSerialization.jsonObject(with: result.part) as? [String: Any])?["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new")
        #expect(oauth["refreshToken"] as? String == "r-new")
        #expect((oauth["expiresAt"] as? NSNumber)?.int64Value == Int64(29_800_000))
        #expect((oauth["refreshTokenExpiresAt"] as? NSNumber)?.int64Value == Int64(2_593_000_000))
        #expect(oauth["scopes"] as? [String] == ["user:inference", "user:profile"])
        #expect(oauth["subscriptionType"] as? String == "pro")
        #expect(!ClaudeLogin.needsRefresh(result.part, now: now, margin: 300))
        #expect(ClaudeLogin.needsRefresh(part, now: now, margin: 300))
    }

    @Test func tokenResponseWithoutNewRefreshTokenKeepsOld() throws {
        let part = Data(#"{"claudeAiOauth": {"accessToken": "old", "refreshToken": "r-old"}}"#.utf8)
        let response = Data(#"{"access_token": "new", "expires_in": 60}"#.utf8)
        let result = try #require(ClaudeLogin.applying(tokenResponse: response, to: part, now: Date()))
        #expect(ClaudeLogin.refreshToken(in: result.part) == "r-old")
        #expect(result.owner == nil)
        #expect(ClaudeLogin.applying(tokenResponse: Data(#"{"error": "x"}"#.utf8), to: part, now: Date()) == nil)
    }

    @Test func onlyInvalidGrantCountsAsRejected() {
        #expect(ClaudeLogin.refreshRejected(status: 400, body: Data(#"{"error": "invalid_grant"}"#.utf8)))
        #expect(ClaudeLogin.refreshRejected(status: 401, body: Data()))
        #expect(!ClaudeLogin.refreshRejected(status: 400, body: Data(#"{"error": "invalid_scope"}"#.utf8)))
        #expect(!ClaudeLogin.refreshRejected(status: 429, body: Data()))
        #expect(!ClaudeLogin.refreshRejected(status: 503, body: Data()))
    }
}
