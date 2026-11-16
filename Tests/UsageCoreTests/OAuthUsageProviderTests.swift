import Foundation
import Testing
@testable import UsageCore

struct OAuthUsageProviderTests {

    // docs/usage-endpoint.md의 실측 응답을 축약한 픽스처
    static let realResponse = """
    {
      "five_hour": { "utilization": 61.0, "resets_at": "2026-07-14T11:50:00.300459+00:00",
                     "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
      "seven_day": { "utilization": 42.0, "resets_at": "2026-07-19T11:00:00.300485+00:00",
                     "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
      "seven_day_opus": null,
      "limits": [
        { "kind": "session", "group": "session", "percent": 61, "severity": "normal",
          "resets_at": "2026-07-14T11:50:00.300459+00:00", "scope": null, "is_active": true },
        { "kind": "weekly_all", "group": "weekly", "percent": 42, "severity": "normal",
          "resets_at": "2026-07-19T11:00:00.300485+00:00", "scope": null, "is_active": false }
      ],
      "extra_usage": { "is_enabled": false },
      "member_dashboard_available": false
    }
    """

    @Test func parsesRealResponse() throws {
        let usage = try #require(OAuthUsageProvider.parse(
            data: Data(Self.realResponse.utf8), fetchedAt: Date()))
        #expect(usage.sessionPercent == 61.0)
        #expect(usage.weeklyPercent == 42.0)

        let iso = ISO8601DateFormatter()
        let sessionReset = try #require(usage.sessionResetsAt)
        let weeklyReset = try #require(usage.weeklyResetsAt)
        #expect(abs((sessionReset.timeIntervalSince(iso.date(from: "2026-07-14T11:50:00Z")!)) - (0.3)) <= 0.01)
        #expect(abs((weeklyReset.timeIntervalSince(iso.date(from: "2026-07-19T11:00:00Z")!)) - (0.3)) <= 0.01)
    }

    @Test func fallsBackToLimitsArray() throws {
        // five_hour/seven_day가 사라져도 limits[]에서 복원 (스키마 변경 대비)
        let json = """
        { "limits": [
            { "kind": "session", "percent": 30, "resets_at": "2026-07-14T11:50:00Z" },
            { "kind": "weekly_all", "percent": 55, "resets_at": "2026-07-19T11:00:00Z" }
        ] }
        """
        let usage = try #require(OAuthUsageProvider.parse(data: Data(json.utf8), fetchedAt: Date()))
        #expect(usage.sessionPercent == 30)
        #expect(usage.weeklyPercent == 55)
        #expect(usage.sessionResetsAt != nil)
    }

    @Test func rejectsResponseWithoutAnyPercent() {
        #expect(OAuthUsageProvider.parse(data: Data("{}".utf8), fetchedAt: Date()) == nil)
        #expect(OAuthUsageProvider.parse(data: Data("not json".utf8), fetchedAt: Date()) == nil)
    }

    // MARK: 자격증명 파싱 (토큰 값은 픽스처 — 실제 토큰 아님)

    @Test func parseCredentialsWithExpiry() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok_fixture","expiresAt":1789400000000}}"#
        let parsed = try #require(OAuthUsageProvider.parseCredentials(Data(json.utf8)))
        #expect(parsed.token == "tok_fixture")
        #expect(parsed.expiresAt == Date(timeIntervalSince1970: 1_789_400_000))
    }

    @Test func parseCredentialsWithoutExpiryAssumesOneHour() throws {
        let now = Date()
        let json = #"{"claudeAiOauth":{"accessToken":"tok_fixture"}}"#
        let parsed = try #require(OAuthUsageProvider.parseCredentials(Data(json.utf8), now: now))
        #expect(parsed.expiresAt == now.addingTimeInterval(OAuthUsageProvider.defaultTokenLifetime))
    }

    @Test func parseCredentialsRejectsMissingToken() {
        #expect(OAuthUsageProvider.parseCredentials(Data("{}".utf8)) == nil)
        #expect(OAuthUsageProvider.parseCredentials(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
        #expect(OAuthUsageProvider.parseCredentials(Data("garbage".utf8)) == nil)
    }

    @Test func userAgentUsesClientVersion() {
        #expect(OAuthUsageProvider.userAgent(clientVersion: "2.1.285") == "claude-code/2.1.285")
        let fallback = "claude-code/\(OAuthUsageProvider.fallbackClientVersion)"
        #expect(OAuthUsageProvider.userAgent(clientVersion: nil) == fallback)
        // 로그에서 온 값이라 숫자와 점이 아니면 헤더에 넣지 않는다
        #expect(OAuthUsageProvider.userAgent(clientVersion: "2.1\r\nX-Evil: 1") == fallback)
        #expect(OAuthUsageProvider.userAgent(clientVersion: "") == fallback)
    }

    @Test func parsesWeeklyBreakdown() throws {
        let json = """
        {
          "five_hour": { "utilization": 10, "resets_at": "2026-10-06T17:10:00.474399+00:00" },
          "seven_day": { "utilization": 25, "resets_at": "2026-10-13T02:00:00.474424+00:00" },
          "seven_day_breakdown": { "rows": [
            { "display_name": "Claude Code", "key": "claude_code", "percent": 92 },
            { "display_name": "채팅", "key": "chat", "percent": 8 },
            { "key": "other", "percent": 0 }
          ] }
        }
        """
        let usage = try #require(OAuthUsageProvider.parse(data: Data(json.utf8), fetchedAt: Date()))
        #expect(usage.sessionPercent == 10)
        #expect(usage.weeklyBreakdown == [UsageShare(name: "Claude Code", percent: 92),
                                          UsageShare(name: "채팅", percent: 8),
                                          UsageShare(name: "other", percent: 0)])
        let bare = try #require(OAuthUsageProvider.parse(data: Data(Self.realResponse.utf8), fetchedAt: Date()))
        #expect(bare.weeklyBreakdown.isEmpty)
    }

    @Test func 실측_응답에는_이상한_값이_없다() throws {
        let usage = try #require(OAuthUsageProvider.parse(data: Data(Self.realResponse.utf8), fetchedAt: Date()))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-14T09:00:00Z"))
        #expect(usage.oddities(now: now).isEmpty)
    }

    @Test func 범위_밖_사용률과_리셋_시각을_잡는다() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let odd = OfficialUsage(sessionPercent: 250, sessionResetsAt: now.addingTimeInterval(-2 * 3600),
                                weeklyPercent: 4200, weeklyResetsAt: now.addingTimeInterval(30 * 24 * 3600), fetchedAt: now)
        #expect(odd.oddities(now: now) == ["세션 사용률이 범위 밖", "주간 사용률이 범위 밖", "세션 리셋 시각이 범위 밖", "주간 리셋 시각이 범위 밖"])
        // 한도를 넘긴 100% 남짓과 방금 지난 리셋은 정상이다
        let edge = OfficialUsage(sessionPercent: 104, sessionResetsAt: now.addingTimeInterval(-60),
                                 weeklyPercent: nil, weeklyResetsAt: now.addingTimeInterval(7 * 24 * 3600), fetchedAt: now)
        #expect(edge.oddities(now: now).isEmpty)
        // 쓰지 않아 0%인 창은 지난 리셋 시각이 와도 정상이다
        let idle = OfficialUsage(sessionPercent: 0, sessionResetsAt: now.addingTimeInterval(-6 * 3600),
                                 weeklyPercent: 12, weeklyResetsAt: now.addingTimeInterval(3 * 24 * 3600), fetchedAt: now)
        #expect(idle.oddities(now: now).isEmpty)
    }
}
