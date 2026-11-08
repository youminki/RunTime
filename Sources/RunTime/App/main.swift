import UniformTypeIdentifiers
import Combine
import AppKit
import HostsCore
import ReportCore
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
            ? WorkReport.daily(log.entries(on: today), in: log, doneFirst: true, byIssue: true, compact: WorkLogSettings.shared.reportCompact,
                               ratios: WorkReport.reportRatios(log.entries(on: today), in: log,
                                                               pending: WorkReport.pendingRatios(log.entries(on: today), log: log)))
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
    // 그날 진행 사항을 앱과 같은 규칙으로 만들고 Claude Code로 다듬어 찍는다 (올리지 않음)
    if args.first == "polish" {
        let log = WorkLogStore.shared.log
        let day = args.dropFirst().first ?? WorkDay.today()
        guard WorkDay.isValid(day) else { print("날짜는 yyyy-MM-dd로 적습니다"); exit(1) }
        let entries = log.entries(on: day)
        let ratios = WorkReport.reportRatios(entries, in: log, pending: WorkReport.pendingRatios(entries, log: log))
        let report = WorkReport.daily(entries, in: log, doneFirst: true, byIssue: true, compact: true, ratios: ratios)
        guard !report.isEmpty else { print("\(day) 기록 없음"); exit(1) }
        let started = Date()
        ReportPolisher.polish(report) { result in
            switch result {
            case .success(let text): print(text, String(format: "\n(%.1f초)", Date().timeIntervalSince(started)))
            case .failure(let error): print(error.localizedDescription)
            }
            exit((try? result.get()) == nil ? 1 : 0)
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
        let base = try WorkLogFile.load()
        var log = base
        let result = WorkLogCommand.run(args, log: &log) {
            String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        if result.changed {
            // 입력을 기다리는 사이 앱이 파일을 저장했으면 그 내용을 덮지 않게 앱 저장처럼 합친다
            let disk = try WorkLogFile.load()
            try WorkLogFile.save(disk == base ? log : WorkLog.merge(mine: log, base: base, disk: disk))
        }
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
if CommandLine.arguments.contains("--stage-check") {
    Task { @MainActor in exit(StageCheck.run(character: Runner.cat.character) ? 0 : 1) }
    dispatchMain()
}

// README 비행 GIF용 장면 (`--flight-frames <폴더>`)
if let index = CommandLine.arguments.firstIndex(of: "--flight-frames") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "flight-frames"
    Task { @MainActor in
        do {
            ReadmeShots.useDemoDefaults()
            try FlightShots.frames(to: URL(fileURLWithPath: path), character: AppSettings.shared.character)
            exit(0)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

if let index = CommandLine.arguments.firstIndex(of: "--flight-shots") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "flight-shots"
    Task { @MainActor in
        do {
            try FlightShots.run(to: URL(fileURLWithPath: path), character: Runner.cat.character)
            exit(0)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

if let index = CommandLine.arguments.firstIndex(of: "--game-frames") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? "game-frames"
    Task { @MainActor in
        do {
            // README 예시 러너(짱구). 받아 두지 않았으면 기본 펫 고양이
            let lead = PetdexStore.shared.pets.first { $0.slug == "crayon-shin-chan" }.flatMap(PetdexStore.shared.character(for:))
            try GameFrames.run(to: URL(fileURLWithPath: path), character: lead ?? Runner.cat.character)
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

// Petdex 시트 자르기 점검: 받은 시트 PNG를 폴더에 러너 프레임으로 잘라 두고 종료.
// 펫 만들기 점검: 설명 한 줄로 실제로 만들어 고른다. --pet-watch는 몇 초 동안 폴더를 지켜본다
if let index = CommandLine.arguments.firstIndex(of: "--pet-make") {
    let factory = PetFactory.shared
    var revised = false
    let watch = factory.$state.sink { state in
        print("상태: \(state)")
        if case .done = state {
            print("고른 펫: \(AppSettings.shared.customRunnerID ?? "-")")
            // RUNTIME_PET_REVISE=고칠 점: 다 만든 뒤 한 번 고쳐 본다
            if let ask = ProcessInfo.processInfo.environment["RUNTIME_PET_REVISE"], !revised {
                revised = true
                DispatchQueue.main.async { factory.revise(ask, settings: AppSettings.shared) }
                return
            }
            exit(0)
        }
        if case .failed = state { exit(1) }
    }
    // --pet-make --reference <그림> <설명>
    var words = Array(CommandLine.arguments.dropFirst(index + 1))
    var references: [URL] = []
    while let at = words.firstIndex(of: "--reference"), at + 1 < words.count {
        references.append(URL(fileURLWithPath: words[at + 1]))
        words.removeSubrange(at...(at + 1))
    }
    // RUNTIME_PET_CANCEL_AFTER=초: 그만큼 뒤에 멈추기를 눌러 그리던 프로세스가 끝나는지 본다
    if let after = ProcessInfo.processInfo.environment["RUNTIME_PET_CANCEL_AFTER"].flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            factory.cancel()
            print("멈춤: 상태 \(factory.state)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let pipe = Pipe()
                let check = Process()
                check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                check.arguments = ["-f", "petmaker.py"]
                check.standardOutput = pipe
                try? check.run()
                check.waitUntilExit()
                print("남은 그림 프로세스: \(check.terminationStatus == 0 ? "있음" : "없음")")
                exit(0)
            }
        }
    }
    factory.make(words.joined(separator: " "), references: references, settings: AppSettings.shared)
    withExtendedLifetime(watch) { RunLoop.main.run(until: Date().addingTimeInterval(3600)) }
    exit(1)
}
// 참고 그림 받기 점검: 파일 끌어다 놓기, 그림 붙여 넣기(데이터), 그림이 아닌 파일, 네 장째를 차례로 넣어 본다
if let index = CommandLine.arguments.firstIndex(of: "--pet-drop-check") {
    let paths = CommandLine.arguments.dropFirst(index + 1).map { URL(fileURLWithPath: $0) }
    let maker = PetMakerText()
    var providers = paths.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() }
    if let first = paths.first, let data = try? Data(contentsOf: first) {
        providers.insert(NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier), at: 0)
    }
    maker.take(Array(providers.prefix(2)))
    maker.take(Array(providers.dropFirst(2)))
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        print("받은 그림 \(maker.references.count)장: \(maker.references.map(\.lastPathComponent))")
        exit(maker.references.count <= 3 ? 0 : 1)
    }
    dispatchMain()
}

// Petdex 이름 다듬기 점검 (`--petdex-names [묶음 수]`): 목록을 받고 그만큼 Claude에 물어 바뀐 이름을 보인다
if let index = CommandLine.arguments.firstIndex(of: "--petdex-names") {
    let batches = CommandLine.arguments.dropFirst(index + 1).first.flatMap { Int($0) } ?? 1
    let store = PetdexStore.shared
    store.loadCatalog()
    var seen = 0
    var before: [String: String] = [:]
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        guard !store.entries.isEmpty else { return }
        if before.isEmpty { before = store.koreanNames }
        if !store.isRefiningNames { seen += 1 }
        let changed = store.entries.filter { before[$0.slug] != store.koreanNames[$0.slug] }
        if seen > batches * 2 || changed.count >= batches * 100 {
            print("바뀐 이름 \(changed.count)개")
            for entry in changed.prefix(40) { print("  \(entry.displayName) : \(before[entry.slug] ?? "") → \(store.koreanNames[entry.slug] ?? "")") }
            exit(0)
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(600))
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--pet-watch") {
    let seconds = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 10
    PetWatcher.shared.start(settings: AppSettings.shared)
    let watch = PetFactory.shared.$state.sink { print("상태: \($0)") }
    withExtendedLifetime(watch) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    print("펫: \(PetdexStore.shared.pets.map(\.name)), 고른 펫: \(AppSettings.shared.customRunnerID ?? "-")")
    exit(0)
}

// 직접 만든 펫 찾기·가져오기 점검: 찾은 펫을 적고, 경로를 주면 가져온다
if let index = CommandLine.arguments.firstIndex(of: "--pet-import") {
    for pet in PetdexStore.shared.scanLocalPets() { print("found: \(pet.name) \(pet.slug) \(pet.sheet.lastPathComponent)") }
    guard let path = CommandLine.arguments.dropFirst(index + 1).first else { exit(0) }
    PetdexStore.shared.importLocal(from: URL(fileURLWithPath: path)) { result in
        switch result {
        case .success(let pet):
            print("imported: \(pet.name) \(pet.slug) picture=\(PetdexStore.shared.character(for: pet) != nil)")
            exit(0)
        case .failure(let error):
            print("failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

if let index = CommandLine.arguments.firstIndex(of: "--petdex-extract") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    guard args.count == 2, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil) else {
        print("usage: --petdex-extract <sheet.png> <folder>")
        exit(1)
    }
    do {
        try PetdexAtlas.extract(from: source, to: URL(fileURLWithPath: args[1]))
        print("saved: \(args[1])")
        exit(0)
    } catch {
        print("failed: \(error)")
        exit(1)
    }
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
    // 받아 둔 짱구와 부리부리 대마왕이 있으면 먼저 달린다
    let lead = ["crayon-shin-chan", "futuduozaemon"].compactMap { slug in
        PetdexStore.shared.pets.first { $0.slug == slug }.flatMap { PetdexStore.shared.character(for: $0)?.rig }
    }
    try? SpriteSheet.writeHeroGIF(to: URL(fileURLWithPath: path), lead: lead)
    print("saved: \(path)")
    exit(0)
}

// 효과 점검: 상태·반응마다 무대와 메뉴바 장면을 PNG로 저장하고 종료.
if let index = CommandLine.arguments.firstIndex(of: "--stage-shots") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    // 기본 러너 id나 Petdex·내 그림 러너 id (메뉴바 점검과 같은 목록)
    let id = args.dropFirst().first ?? ""
    // "sheet:<폴더>"면 --petdex-extract로 자른 폴더를 바로 러너로 쓴다
    let sheet = id.hasPrefix("sheet:") ? SheetRig(folder: URL(fileURLWithPath: String(id.dropFirst(6)))) : nil
    let character = sheet.map {
        RunnerCharacter(key: id, name: "시트", sound: "시트", rig: FittedRig($0), fixedTheme: .natural)
    } ?? MenuBarAudit.entries().first { $0.id == id }?.character ?? Runner.cat.character
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
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    let path = args.first ?? "AppIcon.png"
    let folders = args.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
    do {
        try MainActor.assumeIsolated {
            try AppIcon.write(to: URL(fileURLWithPath: path), runner: folders.first, companion: folders.dropFirst().first)
        }
        print("saved: \(path)")
        exit(0)
    } catch {
        print("failed: \(error)")
        exit(1)
    }
}

// README 그림: 예시 값으로 사용량 창과 꾸미기를 찍어 PNG로 저장하고 종료.
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
// 문제 보고 미리 보기: 만든 사람에게 보낼 때의 본문을 보내지 않고 찍는다. `--report-preview screen`은 화면 오류 본문,
// `--report-preview crash [충돌 보고서.ips]`는 그 충돌(없으면 아직 알리지 않은 가장 최근 충돌)의 본문,
// `--report-preview hang`은 메인 스레드를 1.5초 붙잡고 뜬 호출 순서로 만든 멈춤 본문
if let index = CommandLine.arguments.firstIndex(of: "--report-preview"),
   CommandLine.arguments.dropFirst(index + 1).first == "hang" {
    guard let hang = HangWatch.preview() else { print("호출 순서를 뜨지 못했습니다"); exit(1) }
    let body = ProblemReporter.payload(.hang, hang.summary, detail: hang.detail(), app: hang.app, commit: hang.commit, log: "")
    if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--report-preview"),
   CommandLine.arguments.dropFirst(index + 1).first == "crash" {
    let report = CommandLine.arguments.dropFirst(index + 2).first.map { path in
        (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)).flatMap { CrashReport(ips: $0) }
    } ?? CrashReports.newestUnseen()?.report
    guard let report else { print("충돌 보고서가 없거나 읽지 못했습니다"); exit(1) }
    let draft = CrashReports.draft(report, others: 0)
    let body = ProblemReporter.payload(.crash, draft.message, detail: draft.detail, app: draft.app, commit: draft.commit, log: draft.log)
    if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--report-preview") {
    let body = CommandLine.arguments.dropFirst(index + 1).first == "screen"
        ? ProblemReporter.payload(.screen, "레드마인 PUT 실패 (HTTP 422)", screen: "업무 일지",
                                  source: ProblemReporter.source(#filePath, #line, "preview()"), detail: "요청: PUT /issues/1.json")
        : ProblemReporter.payload(.failed, "업데이트에 실패했습니다: 미리 보기")
    if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}
// 업데이트 판정: 그 커밋으로 만든 빌드라 치고 GitHub와 견줘 받을지만 찍는다 (설치하지 않음)
// 일지를 레드마인으로 보내는 길을 가짜 응답으로 돌려 본다. 서버에는 보내지 않는다.
if CommandLine.arguments.contains("--worklog-flow") {
    MainActor.assumeIsolated { WorkLogFlowCheck.run(folder: WorkLogFlowCheck.prepare()) }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--redmine-activity") {
    MainActor.assumeIsolated { RedmineFlowCheck.activityCount() }
    RunLoop.main.run()
}

// 레드마인 화면의 일을 가짜 응답으로 끝까지 돌려 나가는 요청을 살핀다. 서버에는 보내지 않는다.
if CommandLine.arguments.contains("--redmine-flow") {
    MainActor.assumeIsolated { RedmineFlowCheck.run(folder: RedmineFlowCheck.prepare()) }
    RunLoop.main.run()
}

if let index = CommandLine.arguments.firstIndex(of: "--update-check") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    _ = NSApplication.shared
    UpdaterCheck.run(args)
    RunLoop.main.run()
}
// 디자인 화면 시나리오 시험: 기록 사본(RUNTIME_DESIGN_HISTORY)으로 화면을 띄워 단추를 손쉬운 사용 길로 눌러 본다
if let index = CommandLine.arguments.firstIndex(of: "--design-qa") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    _ = NSApplication.shared
    MainActor.assumeIsolated { DesignQA.run(args) }
    RunLoop.main.run()
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
if CommandLine.arguments.contains("--hosts-check") {
    MainActor.assumeIsolated {
        var seen = Set<String>()
        let targets = HostsStore.shared.sections.flatMap(\.items)
            .filter { $0.enabled && seen.insert(HostsPage.probeKey($0.name, $0.ip)).inserted }.map { (name: $0.name, ip: $0.ip) }
        Task {
            var results: [HostProbe] = []
            await HostsProber.probeAll(targets) { result in await MainActor.run { results.append(result) } }
            for result in results.sorted(by: { $0.name < $1.name }) {
                let verdict = result.verdict()
                print("\(verdict.level)\t\(result.name)\t\(result.ip)\t\(verdict.label)")
            }
            if let overview = HostProbe.overview(results) { print(overview) }
            exit(0)
        }
    }
    RunLoop.main.run()
}

// 업데이트 말풍선 점검: 커밋 제목 몇 줄(표준 입력)로 메뉴바 아래 말풍선을 띄우고 PNG로 남긴 뒤 종료.
if let index = CommandLine.arguments.firstIndex(of: "--update-bubble-check") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let file = URL(fileURLWithPath: CommandLine.arguments.dropFirst(index + 1).first ?? "update-bubble.png")
    let lines = (readLine(strippingNewline: true).map { [$0] } ?? []) + Array(sequence(first: "", next: { _ in readLine() }).dropFirst())
    do {
        let items = UpdateDigest.make(lines.filter { !$0.isEmpty })
        print(items.map { "· \($0)" }.joined(separator: "\n"))
        let screen = NSScreen.main?.frame ?? .zero
        MenuBarBubble.shared.show(.init(title: "새 버전이 있어요", items: items, actionTitle: "지금 업데이트", action: {}),
                                  below: NSRect(x: screen.maxX - 300, y: screen.maxY - 30, width: 40, height: 30))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MenuBarBubble.shared.snapshot(to: file)
            MenuBarBubble.shared.hide()
            exit(items.isEmpty ? 1 : 0)
        }
    }
    app.run()
}

// 꺼낸 펫 점검: 실제 창을 띄워 걷기·키·끌기를 보고 마지막 모습을 PNG로 남긴 뒤 종료.
if let index = CommandLine.arguments.firstIndex(of: "--desktop-pet-check") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let file = URL(fileURLWithPath: CommandLine.arguments.dropFirst(index + 1).first ?? "desktop-pet.png")
    DesktopPetCheck.run(to: file) { ok in
        print(ok ? "모두 통과" : "실패")
        exit(ok ? 0 : 1)
    }
    app.run()
}

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

CrashReports.captureOutput()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock 아이콘 없이 메뉴바 전용
app.run()
