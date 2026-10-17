import Foundation
import Testing
@testable import UsageCore

struct UsageAlertsTests {

    @Test func alertLevels() {
        #expect(UsageAlertLevel.level(percent: 0) == .normal)
        #expect(UsageAlertLevel.level(percent: 79.9) == .normal)
        #expect(UsageAlertLevel.level(percent: 80) == .tired)
        #expect(UsageAlertLevel.level(percent: 94.9) == .tired)
        #expect(UsageAlertLevel.level(percent: 95) == .critical)
    }

    @Test func eightyFiresExactlyOnce() {
        var tracker = LimitAlertTracker()
        #expect(tracker.alertsToFire(kind: .session, percent: 81, windowId: "w1") == [.eighty])
        #expect(tracker.alertsToFire(kind: .session, percent: 85, windowId: "w1") == [])
        #expect(tracker.alertsToFire(kind: .session, percent: 82, windowId: "w1") == [])
    }

    @Test func ninetyFiveAfterEighty() {
        var tracker = LimitAlertTracker()
        #expect(tracker.alertsToFire(kind: .session, percent: 81, windowId: "w1") == [.eighty])
        #expect(tracker.alertsToFire(kind: .session, percent: 96, windowId: "w1") == [.ninetyFive])
        #expect(tracker.alertsToFire(kind: .session, percent: 97, windowId: "w1") == [])
    }

    @Test func jumpStraightToNinetySixFiresOnlyNinetyFive() {
        var tracker = LimitAlertTracker()
        #expect(tracker.alertsToFire(kind: .session, percent: 96, windowId: "w1") == [.ninetyFive])
        // 건너뛴 80도 소진됨 — 이후 아무것도 재발송 없음
        #expect(tracker.alertsToFire(kind: .session, percent: 96, windowId: "w1") == [])
        #expect(tracker.alertsToFire(kind: .session, percent: 85, windowId: "w1") == [])
    }

    @Test func savedHistorySurvivesRestart() {
        var before = LimitAlertTracker()
        _ = before.alertsToFire(kind: .session, percent: 85, windowId: "w1")
        _ = before.alertsToFire(kind: .weekly, percent: 96, windowId: "k1")
        var after = LimitAlertTracker()
        after.saved = before.saved
        #expect(after.alertsToFire(kind: .session, percent: 85, windowId: "w1") == [])
        #expect(after.alertsToFire(kind: .weekly, percent: 97, windowId: "k1") == [])
        #expect(after.alertsToFire(kind: .session, percent: 96, windowId: "w1") == [.ninetyFive])
    }

    @Test func newWindowResets() {
        var tracker = LimitAlertTracker()
        #expect(tracker.alertsToFire(kind: .session, percent: 85, windowId: "w1") == [.eighty])
        #expect(tracker.alertsToFire(kind: .session, percent: 85, windowId: "w2") == [.eighty])
    }

    @Test func sessionAndWeeklyIndependent() {
        var tracker = LimitAlertTracker()
        #expect(tracker.alertsToFire(kind: .session, percent: 85, windowId: "s1") == [.eighty])
        #expect(tracker.alertsToFire(kind: .weekly, percent: 85, windowId: "k1") == [.eighty])
    }

    @Test func belowThresholdNeverFires() {
        var tracker = LimitAlertTracker()
        #expect(tracker.alertsToFire(kind: .weekly, percent: 79.9, windowId: "w") == [])
    }

    // 회귀: resets_at은 조회할 때마다 1초 안쪽으로 흔들린다 (실측 17:09:59.75 → 17:10:00.47).
    // 그대로 창 식별자로 쓰면 조회마다 새 창이 되어 80% 알림이 반복됐다.
    @Test func windowIdIgnoresSubSecondJitter() throws {
        let a = try #require(ISODate.parse("2026-10-06T17:09:59.747952+00:00"))
        let b = try #require(ISODate.parse("2026-10-06T17:10:00.474399+00:00"))
        #expect(LimitAlertTracker.windowId(resetsAt: a) == LimitAlertTracker.windowId(resetsAt: b))
        var tracker = LimitAlertTracker()
        #expect(tracker.alertsToFire(kind: .session, percent: 81, windowId: LimitAlertTracker.windowId(resetsAt: a))
                == [.eighty])
        #expect(tracker.alertsToFire(kind: .session, percent: 82, windowId: LimitAlertTracker.windowId(resetsAt: b))
                == [])
    }
}
