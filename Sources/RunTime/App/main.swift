import AppKit
import UsageCore

LegacyMigration.run()

// 디버그/수용기준 검증용: GUI 없이 1회 풀스캔 집계를 출력하고 종료.
// ccusage blocks 결과와 대조하는 데 사용 (§7 오차 2% 기준).
if CommandLine.arguments.contains("--report") {
    let watcher = JSONLWatcher()
    let store = UsageStore()
    let start = Date()
    store.add(watcher.scan())
    let snap = store.snapshot()
    print("scan: \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000))ms, events(dedup): \(snap.totalEventCount)")
    print("today: \(snap.todayTokens) tokens, $\(String(format: "%.2f", snap.todayCostUSD)) (추정)")
    if let block = snap.currentBlock {
        let iso = ISO8601DateFormatter()
        print("current block: \(iso.string(from: block.start)) ~ \(iso.string(from: block.end))")
        print("current block tokens: \(block.totalTokens) (entries: \(block.eventCount))")
    } else {
        print("current block: none")
    }
    print("last 60s: \(snap.tokensLast60s) tokens")
    print("weekly(rolling 7d): \(snap.weeklyTokens) tokens, models: \(snap.weeklyModelTokens)")

    // 공식 % 1회 조회 (§7: /usage 표시값과 일치 검증용)
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let usage = try await OAuthUsageProvider().fetch(clientVersion: snap.latestClientVersion)
            print("official: session \(usage.sessionPercent.map { "\($0)%" } ?? "-")"
                + " (resets \(usage.sessionResetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-"))"
                + ", weekly \(usage.weeklyPercent.map { "\($0)%" } ?? "-")")
        } catch {
            print("official: FAILED (\(error)) → 게이지 비움")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// 메뉴바 점검: 모든 러너의 잘림·크기·대비를 메뉴바와 같은 칸으로 재고 종료.
// 예: --menubar-audit out 1 30 1.1 (화면 배율, 메뉴바 높이, 크기 배율)
if let index = CommandLine.arguments.firstIndex(of: "--menubar-audit") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    let number = { (i: Int, fallback: CGFloat) in args.count > i ? CGFloat(Double(args[i]) ?? Double(fallback)) : fallback }
    let canvas = MenuBarCanvas(barHeight: number(2, 30), zoom: number(3, RunnerSize.large.zoom), backing: number(1, 2))
    do {
        try MenuBarAudit.run(to: URL(fileURLWithPath: args.first ?? "menubar-audit"), canvas: canvas)
        print("saved: \(args.first ?? "menubar-audit") (\(canvas.pixelWidth)×\(canvas.pixelHeight)px)")
        exit(0)
    } catch {
        print("failed: \(error)")
        exit(1)
    }
}

// 게임 화면 점검: 자동 플레이로 시작·진행·부딪힘 장면을 PNG로 저장하고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--game-shots") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    let id = args.dropFirst().first
    let character = Runner(rawValue: id ?? "")?.character ?? Runner.cat.character
    // 무대 그리기는 메인 액터에서만 된다
    Task { @MainActor in
        do {
            try GameShots.run(to: URL(fileURLWithPath: args.first ?? "game-shots"), character: character)
            exit(0)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

// README용: 고스트와 겨루는 게임 장면을 이어 찍어 PNG로 저장하고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--game-frames") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "game-frames"
    Task { @MainActor in
        do {
            try GameFrames.run(to: URL(fileURLWithPath: path), character: Runner.cat.character)
            exit(0)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

// 모자·안경 점검: 모든 러너에 꾸미기를 씌워 한 장으로 저장하고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--accessory-sheet") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "accessory-sheet.png"
    Task { @MainActor in
        do {
            try AccessorySheet.run(to: URL(fileURLWithPath: path), set: CommandLine.arguments.dropFirst(index + 2).first)
            print("saved: \(path)")
            exit(0)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

// 성능 점검: 무대와 게임 한 장면을 그리는 데 드는 시간을 재고 종료.
if CommandLine.arguments.contains("--game-bench") {
    Task { @MainActor in
        GameBench.run(character: Runner.cat.character)
        exit(0)
    }
    dispatchMain()
}

// 디자인 점검용: 모든 러너의 대표 장면을 PNG로 저장하고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--sprite-sheet") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    let path = args.first ?? "sprite-sheet"
    let filter = args.dropFirst().first
    let runners = filter.map { $0.split(separator: ",").compactMap { Runner(rawValue: String($0)) } }
    do {
        try SpriteSheet.write(to: URL(fileURLWithPath: path), runners: runners ?? Runner.allCases)
        print("saved: \(path)")
        exit(0)
    } catch {
        print("failed: \(error)")
        exit(1)
    }
}

// README GIF 생성: 러너 몇 마리가 차례로 달리는 애니메이션.
if let index = CommandLine.arguments.firstIndex(of: "--hero-gif") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "runtime-run.gif"
    try? SpriteSheet.writeHeroGIF(to: URL(fileURLWithPath: path))
    print("saved: \(path)")
    exit(0)
}

// 화면 점검: 주요 창을 실제 데이터로 찍어 PNG로 저장하고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--ui-shots") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "ui-shots"
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let engine = UsageEngine()
    engine.start()
    MainActor.assumeIsolated { UIShots.run(to: URL(fileURLWithPath: path), engine: engine) }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock 아이콘 없이 메뉴바 전용
app.run()
