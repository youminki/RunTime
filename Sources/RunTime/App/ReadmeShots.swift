import AppKit
import SwiftUI
import UsageCore

/// README 그림 (`--readme-shots <폴더>`): 내 사용량·지갑 대신 꾸민 예시 값으로 사용량 창, 상점, 창고, 퀘스트를 찍는다.
/// 예시 값은 저장하지 않는 임시 설정 영역에 두고, 실제 기록과 공식 사용량은 읽지 않는다.
/// Petdex 펫은 사용자가 올린 팬아트라 README에 싣지 않게 동료를 비운다.
@MainActor
enum ReadmeShots {
    /// GameWallet·AppSettings가 처음 읽히기 전에 불러야 한다.
    static func useDemoDefaults() {
        let pending = (try? JSONEncoder().encode([GameWallet.PendingReward]())) ?? Data()
        UserDefaults.standard.setVolatileDomain([
            "runner": "cat", "customRunner": "", "spriteTheme": "auto",
            "gameCompanion": "",
            "gameWalletCoins": 1280,
            "gameCosmeticsOwned": ["pineTrack", "cityTrack", "snowWeather", "rainbowTrail", "fireTrail", "starDust",
                                   "heartCrash"],
            "gameCosmeticsEquipped": ["pineTrack", "rainbowTrail", "starDust"],
            "gameAbilityLevels": ["airJump": 1, "shield": 2],
            "gamePendingRewards": pending,
        ], forName: UserDefaults.argumentDomain)
    }

    static func run(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
        let engine = UsageEngine()
        fill(engine)
        Sky.hourOverride = 12
        let screens: [(String, AnyView)] = [
            ("usage", AnyView(PopoverView(engine: engine, settings: engine.settings))),
            ("shop", AnyView(GameShopView(settings: engine.settings, tab: .track)
                .padding(14).frame(width: 376).background(Theme.background))),
            ("storage", AnyView(StorageView(settings: engine.settings)
                .padding(14).frame(width: 376).background(Theme.background))),
            ("quests", AnyView(QuestView().padding(14).frame(width: 376).background(Theme.background))),
        ]
        let windows = screens.map { _, view -> NSWindow in
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled]
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            return window
        }
        // 무대가 달리기 시작하고 상점 미리보기가 한 바퀴 돌 때까지 기다린다
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            for ((name, _), window) in zip(screens, windows) {
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = directory.appendingPathComponent("\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("saved: \(url.path)")
            }
            exit(0)
        }
    }

    /// 하루 몇 시간씩 일한 8일 치 예시 기록과, 세션 42%·주간 18%인 공식 사용량.
    private static func fill(_ engine: UsageEngine) {
        let now = Date()
        let calendar = Calendar.current
        let projects = ["my-app", "api-server", "blog", "dotfiles"]
        var events: [UsageEvent] = []
        var n = 0
        func add(_ date: Date, tokens: Int, project: String) {
            n += 1
            events.append(UsageEvent(timestamp: date, model: "claude-opus-4-5", requestId: "r\(n)", messageId: "m\(n)",
                                     inputTokens: tokens / 20, outputTokens: tokens / 10, cacheCreationTokens: tokens / 10,
                                     cacheReadTokens: tokens - tokens / 20 - tokens / 10 * 2, project: project))
        }
        // 지난 7일: 날마다 다른 양
        for day in 1...7 {
            guard let start = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now)) else { continue }
            let scale = [0.8, 1.3, 0.4, 1.0, 1.6, 0.2, 1.1][day - 1]
            for minute in stride(from: 10 * 60, to: 18 * 60, by: 7) {
                add(start.addingTimeInterval(Double(minute) * 60), tokens: Int(60_000 * scale),
                    project: projects[(minute / 7 + day) % (day == 6 ? 1 : projects.count)])
            }
        }
        // 오늘: 최근 30분이 오르내리게
        for second in stride(from: 3 * 3600, to: 0, by: -20) {
            let t = Double(second)
            let wave = 0.55 + 0.45 * sin(t / 300) + (second < 300 ? 0.8 : 0)
            add(now.addingTimeInterval(-t), tokens: Int(9_000 * wave), project: projects[(second / 600) % 2])
        }
        let store = UsageStore()
        _ = store.add(events)
        let snapshot = store.snapshot(now: now)
        engine.snapshot = snapshot
        engine.burnRate = Double(snapshot.tokensLast60s)
        engine.catState = .running
        let sessionReset = now.addingTimeInterval(2 * 3600 + 18 * 60)
        let weeklyReset = calendar.date(byAdding: .day, value: 3, to: now) ?? now
        engine.official = OfficialUsage(sessionPercent: 42, sessionResetsAt: sessionReset, weeklyPercent: 18,
                                        weeklyResetsAt: weeklyReset, fetchedAt: now.addingTimeInterval(-120),
                                        weeklyBreakdown: [UsageShare(name: "Claude Code", percent: 92)])
        engine.officialStatus = .live
        engine.sessionGauge = GaugeReading(percent: 42, source: .official)
        engine.weeklyGauge = GaugeReading(percent: 18, source: .official)
        engine.sessionResetsAt = sessionReset
        engine.nextWeeklyReset = weeklyReset
        engine.weeklyBreakdown = [UsageShare(name: "Claude Code", percent: 92)]
    }
}
