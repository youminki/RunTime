import Foundation
import Testing
@testable import UsageCore

struct UsageStoreTests {

    private func event(minutesAgo: Double, tokens: Int, id: String, now: Date) -> UsageEvent {
        UsageEvent(timestamp: now.addingTimeInterval(-minutesAgo * 60),
                   model: "claude-sonnet-5",
                   requestId: "req_\(id)", messageId: "msg_\(id)",
                   inputTokens: tokens, outputTokens: 0,
                   cacheCreationTokens: 0, cacheReadTokens: 0)
    }

    @Test func deduplicatesByMessageIdAndRequestId() {
        let store = UsageStore()
        let now = Date()
        let e = event(minutesAgo: 1, tokens: 500, id: "dup", now: now)
        // 실물 JSONL은 같은 응답을 최대 6줄로 중복 기록한다
        #expect(store.add([e, e, e, e, e, e]) == 1)
        #expect(store.snapshot(now: now).todayTokens == 500)
    }

    @Test func tokensLast60s() {
        let store = UsageStore()
        let now = Date()
        store.add([
            event(minutesAgo: 0.5, tokens: 100, id: "a", now: now),
            event(minutesAgo: 0.9, tokens: 200, id: "b", now: now),
            event(minutesAgo: 2.0, tokens: 999, id: "c", now: now),
        ])
        #expect(store.snapshot(now: now).tokensLast60s == 300)
    }

    /// 업무 일지 작업 시간 어림에 쓰는 폴더별 활동 분: 기록이 있는 5분 칸 수 × 5.
    @Test func countsActiveMinutesPerProjectFolder() {
        let store = UsageStore()
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)   // 오늘 10:00
        func at(_ minutesAgo: Double, _ id: String, _ project: String) -> UsageEvent {
            UsageEvent(timestamp: now.addingTimeInterval(-minutesAgo * 60), model: "claude-sonnet-5",
                       requestId: "req_\(id)", messageId: "msg_\(id)", inputTokens: 10, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0, project: project)
        }
        store.add([at(1, "a", "velox-web-portal"), at(2, "b", "velox-web-portal"),   // 같은 5분 칸
                   at(12, "c", "velox-web-portal"), at(30, "d", "cdh-web-admin")])
        let today = store.snapshot(now: now).dailyTotals.first
        #expect(today?.projectActiveMinutes == ["velox-web-portal": 10, "cdh-web-admin": 5])
    }

    @Test func todayTokensExcludesYesterday() {
        let store = UsageStore()
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(3600) // 오늘 01:00
        store.add([
            event(minutesAgo: 30, tokens: 100, id: "today", now: now),
            event(minutesAgo: 120, tokens: 999, id: "yesterday", now: now), // 전날 23:00
        ])
        #expect(store.snapshot(now: now).todayTokens == 100)
    }

    @Test func weeklyTokensAndModelShares() {
        let store = UsageStore()
        let now = Date()
        var opus = event(minutesAgo: 60, tokens: 300, id: "o", now: now)
        opus = UsageEvent(timestamp: opus.timestamp, model: "claude-opus-4-8",
                          requestId: opus.requestId, messageId: opus.messageId,
                          inputTokens: 300, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        store.add([
            opus,
            event(minutesAgo: 120, tokens: 700, id: "s", now: now),
            event(minutesAgo: 8 * 24 * 60, tokens: 999, id: "old", now: now), // 8일 전 → 롤링 7일 밖
        ])
        let snap = store.snapshot(now: now)
        #expect(snap.weeklyTokens == 1000)
        #expect(snap.weeklyModelTokens["claude-opus-4-8"] == 300)
        #expect(snap.weeklyModelTokens["claude-sonnet-5"] == 700)
    }

    @Test func weeklyWindowWithCustomStart() {
        let store = UsageStore()
        let now = Date()
        store.add([
            event(minutesAgo: 30, tokens: 100, id: "in", now: now),
            event(minutesAgo: 90, tokens: 200, id: "out", now: now),
        ])
        let snap = store.snapshot(now: now, weeklySince: now.addingTimeInterval(-3600))
        #expect(snap.weeklyTokens == 100)
    }

    @Test func sparklineBuckets() {
        let store = UsageStore()
        let now = Date()
        store.add([
            event(minutesAgo: 0.5, tokens: 10, id: "a", now: now),   // 마지막 버킷
            event(minutesAgo: 5.5, tokens: 20, id: "b", now: now),   // 5분 전 버킷
            event(minutesAgo: 29.5, tokens: 30, id: "c", now: now),  // 첫 버킷
            event(minutesAgo: 31, tokens: 99, id: "d", now: now),    // 창 밖
        ])
        let spark = store.snapshot(now: now).sparkline
        #expect(spark.count == 30)
        #expect(spark[29] == 10)
        #expect(spark[24] == 20)
        #expect(spark[0] == 30)
        #expect(spark.reduce(0, +) == 60)
    }

    @Test func dailyTotalsAndProgrammaticSplit() {
        let store = UsageStore()
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(2 * 3600) // 오늘 02:00
        let sdkEvent = UsageEvent(timestamp: now.addingTimeInterval(-1800), model: "claude-sonnet-5",
                                  requestId: "r_sdk", messageId: "m_sdk",
                                  inputTokens: 400, outputTokens: 0,
                                  cacheCreationTokens: 0, cacheReadTokens: 0,
                                  entrypoint: "sdk-py")
        store.add([
            event(minutesAgo: 60, tokens: 100, id: "t1", now: now),      // 오늘 01:00
            sdkEvent,                                                     // 오늘 01:30 (SDK)
            event(minutesAgo: 5 * 60, tokens: 200, id: "y1", now: now),  // 전날 21:00
        ])
        let snap = store.snapshot(now: now)
        #expect(snap.todayTokens == 500)
        #expect(snap.todayProgrammaticTokens == 400)
        #expect(snap.dailyTotals.count == 2)
        #expect(snap.dailyTotals[0].tokens == 500)   // 최신(오늘)부터
        #expect(snap.dailyTotals[1].tokens == 200)
        #expect(snap.dailyTotals[0].costUSD > 0)
    }

    @Test func costUsesPricingTable() {
        let store = UsageStore()
        let now = Date()
        // sonnet 5: input $2/MTok → 1M input = $2
        let e = UsageEvent(timestamp: now.addingTimeInterval(-60), model: "claude-sonnet-5",
                           requestId: "r", messageId: "m",
                           inputTokens: 1_000_000, outputTokens: 0,
                           cacheCreationTokens: 0, cacheReadTokens: 0)
        store.add([e])
        #expect(abs((store.snapshot(now: now).todayCostUSD) - (2.0)) <= 0.001)
    }

    @Test func opus55PricingIsNotZero() {
        let e = UsageEvent(timestamp: Date(), model: "claude-opus-5-5",
                           requestId: "r", messageId: "m",
                           inputTokens: 1_000_000, outputTokens: 0,
                           cacheCreationTokens: 0, cacheReadTokens: 1_000_000)
        #expect(abs((PricingTable.cost(of: e)) - (4.2)) <= 0.001)
    }

    @Test func prunesEventsOlderThanRetention() {
        let store = UsageStore(retention: 24 * 60 * 60)
        let now = Date()
        store.add([
            event(minutesAgo: 60, tokens: 100, id: "keep", now: now),
            event(minutesAgo: 2 * 24 * 60, tokens: 999, id: "drop", now: now),
        ])
        let snap = store.snapshot(now: now)
        #expect(snap.totalEventCount == 1)
        #expect(snap.dailyTotals.map(\.tokens).reduce(0, +) == 100)
    }

    @Test func dailyTotalsSkipPartialOldestDay() {
        let store = UsageStore()
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let today = calendar.startOfDay(for: now)
        // 8×24시간 보관이라 8일 전 날은 오후 기록만 남는다. 일별 합계에는 오늘부터 7일 전까지만 넣는다
        store.add([
            event(minutesAgo: now.timeIntervalSince(today.addingTimeInterval(-7 * 86_400 + 3600)) / 60,
                  tokens: 100, id: "first", now: now),
            event(minutesAgo: 8 * 24 * 60 - 60, tokens: 999, id: "partial", now: now),
        ])
        let days = store.snapshot(now: now).dailyTotals
        #expect(days.count == 1)
        #expect(days.first?.tokens == 100)
    }

    @Test func dailyTotalsSplitByProject() {
        let store = UsageStore()
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        func at(_ minutes: Double, _ tokens: Int, _ id: String, _ project: String?) -> UsageEvent {
            UsageEvent(timestamp: now.addingTimeInterval(-minutes * 60), model: "claude-sonnet-5",
                       requestId: "req_\(id)", messageId: "msg_\(id)", inputTokens: tokens, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0, project: project)
        }
        store.add([at(1, 300, "a", "RunTime"), at(2, 200, "b", "RunTime"), at(3, 500, "c", "cafeteria"), at(4, 50, "d", nil)])
        let today = store.snapshot(now: now).dailyTotals[0]
        #expect(today.projectTokens == ["RunTime": 500, "cafeteria": 500, "": 50])
        #expect(abs(today.projectCostUSD.values.reduce(0, +) - today.costUSD) < 1e-9)
    }

    @Test func dailyTotalsSplitByModel() {
        let store = UsageStore()
        // 자정 직후에 돌면 2분 전이 어제가 되므로 한낮으로 고정한다
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        store.add([
            event(minutesAgo: 1, tokens: 300, id: "s", now: now),
            UsageEvent(timestamp: now.addingTimeInterval(-120), model: "claude-opus-5-5",
                       requestId: "req_o", messageId: "msg_o", inputTokens: 700, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let today = store.snapshot(now: now).dailyTotals[0]
        #expect(today.modelTokens == ["claude-sonnet-5": 300, "claude-opus-5-5": 700])
        #expect(today.tokens == 1000)
    }

    @Test func latestClientVersionComesFromNewestEvent() {
        let store = UsageStore()
        let now = Date()
        func versioned(_ minutesAgo: Double, _ id: String, _ version: String?) -> UsageEvent {
            UsageEvent(timestamp: now.addingTimeInterval(-minutesAgo * 60), model: "claude-sonnet-5",
                       requestId: "req_\(id)", messageId: "msg_\(id)", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0, clientVersion: version)
        }
        // 늦게 읽힌 옛 기록이 최신 버전을 덮지 않아야 한다
        store.add([versioned(1, "new", "2.1.285"), versioned(2, "nil", nil), versioned(30, "old", "2.1.200")])
        #expect(store.snapshot(now: now).latestClientVersion == "2.1.285")
    }
}

struct PricingTableTests {
    @Test func generatedRatesWinOverFamilyFallback() throws {
        // LiteLLM 데이터 기준: haiku-5-5는 haiku 계열 기본값보다 10배 싸다
        let haiku = try #require(PricingTable.rates(forModel: "claude-haiku-5-5"))
        #expect(haiku.input == 0.1)
        let dated = try #require(PricingTable.rates(forModel: "claude-sonnet-5-5-20260901"))
        #expect(dated.cacheRead == 0.1)
        // 표에 없는 새 모델과 옛 모델은 계열 값으로
        #expect(PricingTable.rates(forModel: "claude-opus-6")?.input == 5)
        #expect(PricingTable.rates(forModel: "claude-opus-4-1-20250805")?.input == 15)
        #expect(PricingTable.rates(forModel: "gpt-5") == nil)
    }
}

struct PeriodSummaryTests {
    private func event(_ at: Date, _ tokens: Int, _ id: String, project: String?) -> UsageEvent {
        UsageEvent(timestamp: at, model: "claude-sonnet-5", requestId: "req_\(id)", messageId: "msg_\(id)",
                   inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, project: project)
    }

    @Test func summarizesTokensBusiestDayAndTopProject() throws {
        let calendar = Calendar.current
        let end = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: Date())!
        let start = end.addingTimeInterval(-WeeklyWindow.duration)
        let tuesday = start.addingTimeInterval(36 * 3600)
        let store = UsageStore()
        store.add([
            event(start.addingTimeInterval(3600), 100, "a", project: "cafeteria"),
            event(tuesday, 500, "b", project: "RunTime"),
            event(tuesday.addingTimeInterval(60), 300, "c", project: "RunTime"),
            event(end.addingTimeInterval(60), 9_999, "d", project: "next-week"),   // 기간 밖
        ])
        let summary = store.summary(from: start, to: end, calendar: calendar)
        #expect(summary.tokens == 900)
        #expect(summary.busiestDay == calendar.startOfDay(for: tuesday))
        #expect(summary.busiestDayTokens == 800)
        #expect(summary.topProject == "RunTime")
        #expect(abs(summary.topProjectShare - 800.0 / 900.0) < 1e-9)
    }

    @Test func weekStartsAtOfficialResetOrMonday() throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(WeeklyWindow.currentStart(nextReset: reset) == reset.addingTimeInterval(-WeeklyWindow.duration))
        let start = WeeklyWindow.currentStart(nextReset: nil)
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        #expect(calendar.component(.weekday, from: start) == 2)   // 월요일
        #expect(start <= Date())
        #expect(Date().timeIntervalSince(start) < WeeklyWindow.duration)
    }
}
