import AppKit
import UsageCore
import WorkLogCore

LegacyMigration.run()

// 업무 일지: Claude가 일지 JSON을 통째로 읽지 않고 보고서·레드마인 글만 받거나 한 줄씩 넣게 한다.
// 예: RunTime --worklog day, RunTime --worklog add VeloX "삭제 API 연동" 70% #1234
if let index = CommandLine.arguments.firstIndex(of: "--worklog") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    // 앱 창을 열지 않고 GitLab MR과 로컬 커밋을 지금 가져온다
    // 나에게 배정된 열린 일감을 받아 장부에 넣고 보고서 이름과 함께 짧게 보인다 (MCP 없이 일감 목록 보기)
    if args.first == "issues" {
        WorkLogSync.shared.loadMyIssues {
            WorkLogStore.shared.saveNow()
            let sync = WorkLogSync.shared
            if let error = sync.issuesError { print("받지 못함: \(error)"); exit(1) }
            let log = WorkLogStore.shared.log
            for project in Array(Set(sync.myIssues.map(\.project))).sorted() {
                let issues = sync.myIssues.filter { $0.project == project }
                print("\(project) → 보고서: \(log.reportProject(for: issues[0])) (\(issues.count)개)")
                for info in issues {
                    let due = info.dueDate.map { " 기한 \($0)" } ?? ""
                    print("  #\(info.id) \(info.doneRatio)% \(info.status)\(due)\(info.isQA ? " [QA]" : "")  \(info.reportTitle)")
                }
            }
            exit(0)
        }
        RunLoop.main.run()
    }
    // 팀즈 채팅 웹훅 시험: RUNTIME_TEAMS_WEBHOOK(없으면 앱에 저장한 주소)으로 카드를 보낸다. 둘째 값이 report면 오늘 일일보고를 보낸다
    if args.first == "teams-test" {
        let log = WorkLogStore.shared.log
        let today = WorkDay.today()
        let report = args.dropFirst().first == "report"
            ? WorkReport.daily(log.entries(on: today), in: log, doneFirst: true, byIssue: true)
            : "[시험] RunTime 업무 일지\n1. 연결 확인\n- 이 카드가 보이면 팀즈 채팅과 연결됐습니다 (완료)"
        let title = args.dropFirst().first == "report" ? "일일보고 · \(WorkReport.shortDate(today))" : "RunTime 연결 시험"
        // 셋째 값이 me면 나와의 채팅으로
        let target: TeamsTarget? = args.contains("me") ? .me : nil
        let started = Date()
        WorkLogSync.shared.postTeams(report.isEmpty ? "오늘 기록 없음" : report, title: title, to: target) { message, failed in
            print(message, String(format: "(%.1f초)", Date().timeIntervalSince(started)))
            // 보낸 뒤 쓰던 앱으로 돌아가는 일이 끝나게 잠깐 두고 끝낸다
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(failed ? 1 : 0) }
        }
        RunLoop.main.run()
    }
    // 숨은 팀즈 웹이 뜨는지, 로그인돼 있는지 본다 (보내지 않음)
    if args.first == "teams-web" {
        _ = NSApplication.shared
        let started = Date()
        TeamsWeb.shared.prepare { ready in
            print(ready ? "팀즈 웹 로그인됨" : "팀즈 웹: \(TeamsWeb.shared.state)", String(format: "(%.1f초)", Date().timeIntervalSince(started)))
            exit(ready ? 0 : 1)
        }
        RunLoop.main.run()
    }
    if args.first == "capture" {
        WorkLogSync.shared.capture {
            WorkLogStore.shared.saveNow()
            let sync = WorkLogSync.shared
            print(sync.captureError.map { "가져오지 못함: \($0)" } ?? "\(sync.lastAdded)줄 넣거나 고침")
            exit(sync.captureError == nil ? 0 : 1)
        }
        RunLoop.main.run()
    }
    do {
        var log = try WorkLogFile.load()
        let result = WorkLogCommand.run(args, log: &log) {
            String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        if result.changed { try WorkLogFile.save(log) }
        print(result.output)
        exit(result.failed ? 1 : 0)
    } catch {
        print("일지 파일을 읽거나 쓰지 못했습니다: \(error)")
        exit(1)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--account-check") {
    AccountCheck.run(Array(CommandLine.arguments.dropFirst(index + 1)))
}

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

// 난이도 점검: 실제 장애물로 여러 판을 화면 없이 돌려 목표 점수까지 가는지 보고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--game-sim") {
    let args = CommandLine.arguments.dropFirst(index + 1).compactMap { Int($0) }
    MainActor.assumeIsolated { GameSim.run(runs: args.first ?? 40, target: args.dropFirst().first ?? 5000) }
    exit(0)
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

// 효과 점검: 상태·반응마다 무대와 메뉴바 장면을 PNG로 저장하고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--stage-shots") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    // 기본 러너 id나 Petdex·내 그림 러너 id (메뉴바 점검과 같은 목록)
    let id = args.dropFirst().first ?? ""
    let character = MenuBarAudit.entries().first { $0.id == id }?.character ?? Runner.cat.character
    Task { @MainActor in
        do {
            let wearing = (args.dropFirst(2).first ?? "").split(separator: ",").compactMap { Cosmetic(rawValue: String($0)) }
            try StageShots.run(to: URL(fileURLWithPath: args.first ?? "stage-shots"), character: character, wearing: wearing)
            exit(0)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

// 앱 아이콘: 무대 그림으로 1024px PNG를 그리고 종료 (scripts/make-icon.sh가 .icns로 만든다).
if let index = CommandLine.arguments.firstIndex(of: "--app-icon") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "AppIcon.png"
    do {
        try MainActor.assumeIsolated { try AppIcon.write(to: URL(fileURLWithPath: path)) }
        print("saved: \(path)")
        exit(0)
    } catch {
        print("failed: \(error)")
        exit(1)
    }
}

// README 그림: 예시 값으로 사용량 창, 상점, 창고, 퀘스트를 찍어 PNG로 저장하고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--readme-shots") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "readme-shots"
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        ReadmeShots.useDemoDefaults()
        ReadmeShots.run(to: URL(fileURLWithPath: path))
    }
    app.run()
}

// 레드마인 점검: 앱의 보내기·되돌리기 길로 시험 댓글을 한 일감에 보내고, 줄바꿈이 살았는지 본 뒤 지운다.
// 진척률·상태·날짜·작업 시간은 건드리지 않는다. RUNTIME_WORKLOG로 다른 일지 파일을 가리키고 쓴다.
// 디자인 변경 기록: 저장한 피그마 토큰으로 화면설계서 하나를 앱 코드 그대로 받아 보고 개수만 찍는다 (기록은 저장하지 않음)
if let index = CommandLine.arguments.firstIndex(of: "--design-check"),
   let url = CommandLine.arguments.dropFirst(index + 1).first {
    MainActor.assumeIsolated { DesignCheck.run(url: url) }
    RunLoop.main.run()
}
// 날짜 비교: 두 날짜의 피그마 버전을 앱 코드 그대로 받아 견주고 개수와 걸린 시간만 찍는다 (같은 비교를 두 번 해 저장한 버전을 쓰는지도 본다)
if let index = CommandLine.arguments.firstIndex(of: "--design-compare") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    MainActor.assumeIsolated { DesignCheck.compare(args) }
    RunLoop.main.run()
}
// 문제 보고 미리 보기: 업데이트 문제를 만든 사람에게 보낼 때의 본문을 보내지 않고 찍는다
if CommandLine.arguments.contains("--report-preview") {
    let body = ProblemReporter.payload(.failed, "업데이트에 실패했습니다: 미리 보기")
    if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--redmine-check"),
   CommandLine.arguments.dropFirst(index + 1).first == "dupes" {
    MainActor.assumeIsolated { RedmineCheck.dupes() }
    RunLoop.main.run()
}
if let index = CommandLine.arguments.firstIndex(of: "--redmine-check"),
   CommandLine.arguments.dropFirst(index + 1).first == "screens",
   let issue = CommandLine.arguments.dropFirst(index + 2).first.flatMap({ Int($0) }) {
    MainActor.assumeIsolated { RedmineCheck.screens(issue: issue) }
    RunLoop.main.run()
}
if let index = CommandLine.arguments.firstIndex(of: "--redmine-check"),
   CommandLine.arguments.dropFirst(index + 1).first == "share",
   let issue = CommandLine.arguments.dropFirst(index + 2).first.flatMap({ Int($0) }) {
    MainActor.assumeIsolated { RedmineCheck.share(issue: issue) }
    RunLoop.main.run()
}
if let index = CommandLine.arguments.firstIndex(of: "--redmine-check"),
   let issue = CommandLine.arguments.dropFirst(index + 1).first.flatMap({ Int($0) }) {
    MainActor.assumeIsolated { RedmineCheck.run(issue: issue) }
    RunLoop.main.run()
}

// 화면 점검: 주요 창을 실제 데이터로 찍어 PNG로 저장하고 종료.
// 터미널이나 원격 접속으로 다른 Mac의 상태를 볼 때
if CommandLine.arguments.contains("--diagnose") {
    _ = NSApplication.shared
    print(Diagnostics.report())
    exit(0)
}

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
