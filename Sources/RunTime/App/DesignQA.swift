import AppKit
import DesignSyncCore
import SwiftUI

/// `--design-qa <파일키> <메뉴 경로> <결과 폴더> [notoken]`: 디자인 화면 시나리오 시험.
/// RUNTIME_DESIGN_HISTORY로 기록 사본을 가리키고 RUNTIME_NO_KEYCHAIN·RUNTIME_FIGMA_TOKEN으로 토큰을 넘긴다.
/// 단추가 부르는 `DesignSync`·`DesignHistoryPage` 함수를 순서대로 부르고, 피그마 요청 수·사본 파일·화면 스냅숏으로 확인해
/// 케이스마다 `케이스\t결과\t근거` 한 줄을 찍는다. 화면 좌표 클릭은 하지 않는다.
@MainActor
enum DesignQA {
    private static var window: NSWindow!
    private static var folder: URL!

    static func run(_ args: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard args.count >= 3 else { print("쓰기: --design-qa <파일키> <메뉴 경로> <결과 폴더> [notoken]"); exit(2) }
        let (key, path) = (args[0], args[1])
        folder = URL(fileURLWithPath: args[2])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sync = DesignSync.shared
        // 디버그 빌드 설정에만 남는다. 시험 프로젝트 하나만 지켜보게 둔다
        DesignSyncSettings.shared.sources = [DesignSource(fileKey: key, name: sync.history.files[key]?.name ?? key)]
        let page = DesignHistoryPage.shared
        page.project = key
        let view = DesignHistoryView(sync: sync, settings: .shared, page: page, autoStart: false)
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1240, height: 760),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view.frame(width: 1240, height: 760))
        window.orderBack(nil)
        Task {
            if args.dropFirst(3).first == "notoken" {
                await noToken(key: key, path: path)
            } else if args.dropFirst(3).first == "verify" {
                await verify(key: key, path: path)
            } else if args.dropFirst(3).first == "hide" {
                await hide(key: key, path: path)
            } else {
                await scenario(key: key, path: path)
            }
            sync.flush()
            exit(0)
        }
    }

    private static func report(_ id: String, _ pass: Bool?, _ evidence: String) {
        print("\(id)\t\(pass.map { $0 ? "PASS" : "FAIL" } ?? "INFO")\t\(evidence)")
    }

    private static func onDisk() -> DesignHistory {
        DesignSync.shared.flush()
        return (try? DesignHistoryFile.load()) ?? DesignHistory()
    }

    private static func menu(_ path: String, in key: String) async -> Int {
        await withCheckedContinuation { done in DesignSync.shared.syncMenu(path, in: key) { done.resume(returning: $0) } }
    }

    private static func project(_ key: String) async -> Int {
        await withCheckedContinuation { done in DesignSync.shared.sync(only: key) { done.resume(returning: $0) } }
    }

    /// 화면을 그려 PNG로 남긴다. 상태가 화면에 반영될 틈을 준다.
    private static func shot(_ name: String) async -> String {
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "" }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = folder.appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return url.lastPathComponent
    }

    private static func sent() async -> Int { await FigmaClient.shared.sent }

    private static func scenario(key: String, path: String) async {
        let sync = DesignSync.shared
        let page = DesignHistoryPage.shared
        let targets = sync.screens(key, under: path)
        let before = sync.history.files[key]
        let menuPages = Set(targets.map(\.pageID))
        let otherChangelog = before?.changelog.filter { !menuPages.contains($0.pageID) }.count ?? 0
        report("준비", nil, "메뉴 화면 \(targets.count)개(페이지 \(menuPages.count)), 받은 버전 표시 없음 \(targets.filter { before?.fetchedVersion[$0.frameID] == nil }.count)개, 파일 lastModified \(before?.lastModified ?? "-")")

        // QA_FROM=C25면 앞 단계를 건너뛴다 (중간에 멈춘 단계를 다시 볼 때)
        let skip = ProcessInfo.processInfo.environment["QA_FROM"] == "C25"
        var mark = await sent()
        let token = DesignSyncSettings.shared.token ?? ""
        if !skip {
        // C1·C2·C31: 메뉴만 가져오기 (사본에서 받은 버전 표시를 지워 바뀐 것처럼 둔 상태)
        let started = Date()
        let found1 = await menu(path, in: key)
        let menuRequests = await sent() - mark
        let after = onDisk().files[key]
        let fetched = targets.filter { after?.fetchedVersion[$0.frameID] != nil }.count
        report("C1", menuRequests <= 4 && fetched == targets.count,
               "요청 \(menuRequests)번, 새 변경 \(found1)건, 받은 메뉴 화면 \(fetched)/\(targets.count), \(Int(Date().timeIntervalSince(started)))초, 오류 \(sync.errors[key] ?? "없음")")
        let same = after?.lastModified == before?.lastModified && after?.syncedAt == before?.syncedAt && after?.version == before?.version
        let checked = targets.filter { (after?.checkedAt[$0.frameID] ?? .distantPast) >= started }.count
        report("C2", same && checked == targets.count,
               "파일 lastModified 같음 \(after?.lastModified == before?.lastModified), syncedAt 같음 \(after?.syncedAt == before?.syncedAt), version 같음 \(after?.version == before?.version), checkedAt 갱신 \(checked)/\(targets.count)")
        let otherAfter = after?.changelog.filter { !menuPages.contains($0.pageID) }.count ?? 0
        report("C31", otherAfter == otherChangelog, "메뉴 페이지 밖 이력 줄 \(otherChangelog)→\(otherAfter)")
        let lastModified = after?.fetchedVersion[targets.first?.frameID ?? ""]

        // C3: 그대로면 파일 정보만, 확인 시각은 다시 당긴다
        mark = await sent()
        let again = Date()
        let found3 = await menu(path, in: key)
        let requests3 = await sent() - mark
        let rechecked = targets.filter { (onDisk().files[key]?.checkedAt[$0.frameID] ?? .distantPast) >= again }.count
        report("C3", requests3 == 1 && found3 == 0 && rechecked == targets.count, "요청 \(requests3)번, 새 변경 \(found3)건, checkedAt 다시 갱신 \(rechecked)/\(targets.count)")

        // C21: 메뉴만 받은 화면 이미지를 그 화면의 버전으로
        if let screen = targets.first, let version = sync.history.files[key]?.version(of: screen.frameID) {
            let images = DesignImages.shared
            images.load(fileKey: key, nodeID: screen.frameID, version: version)
            var state = images.state(fileKey: key, nodeID: screen.frameID, version: version)
            for _ in 0..<120 where state == nil || state == .loading {
                try? await Task.sleep(nanoseconds: 500_000_000)
                state = images.state(fileKey: key, nodeID: screen.frameID, version: version)
            }
            let ready: Bool = if case .ready = state { true } else { false }
            report("C21", ready, "화면 버전 \(version == sync.history.files[key]?.version ? "= 파일 버전" : "≠ 파일 버전(메뉴만 받은 버전)"), 이미지 \(String(describing: state))")
        }

        // C4·C5: 같은 프로젝트를 강제로 전체 받아 요청 수와 중복 변경을 본다 (결과는 앱 기록이 아니라 복사본 기록에만 남긴다)
        if var record = sync.history.files[key], let source = sync.source(key) {
            record.lastModified = nil
            mark = await sent()
            do {
                let outcome = try await DesignSyncEngine.run(source: source, token: token, known: record,
                                                             transport: { try await FigmaClient.shared.send($0) })
                let fullRequests = await sent() - mark
                report("C4", fullRequests > menuRequests, "프로젝트 요청 \(fullRequests)번 vs 메뉴 \(menuRequests)번")
                if case .captured(var capture) = outcome {
                    capture.rules = sync.rules(for: key)
                    var history = sync.history
                    let events = history.record(capture, at: Date())
                    let inMenu = events.filter { $0.concerns(path) }
                    report("C5", lastModified != capture.lastModified || inMenu.isEmpty,
                           "피그마 lastModified 메뉴 받을 때 \(lastModified ?? "-") / 프로젝트 받을 때 \(capture.lastModified), 새 변경 \(events.count)건, 그중 메뉴 \(inMenu.count)건 \(events.prefix(4).map { $0.screenID + " " + $0.summary })")
                }
            } catch {
                report("C4", false, "프로젝트 받기 실패: \(error)")
            }

            // C23·C24: 사본 기록을 고쳐 지운 화면·옮긴 화면처럼 두고 메뉴 경로로 받아 기록 (복사본 기록에만)
            if let victim = targets.first {
                var gone = record
                gone.lastModified = before?.lastModified
                for screen in targets { gone.fetchedVersion[screen.frameID] = nil }
                gone.screens[victim.frameID]?.candidateID = "999:999"
                var moved = gone
                moved.screens[victim.frameID]?.candidateID = victim.candidateID
                let otherPage = sync.history.files[key]?.screens.values.first { $0.pageID != victim.pageID }?.pageID ?? victim.pageID
                moved.screens[victim.frameID]?.pageID = otherPage
                for (id, known) in [("C23", gone), ("C24", moved)] {
                    do {
                        let outcome = try await DesignSyncEngine.runMenu(source: source, paths: [path], token: token, known: known,
                                                                         transport: { try await FigmaClient.shared.send($0) })
                        guard case .captured(var capture) = outcome else { report(id, false, "받지 않음(unchanged)"); continue }
                        capture.rules = sync.rules(for: key)
                        var history = sync.history
                        history.files[key] = known
                        let events = history.record(capture, at: Date())
                        let removed = events.filter { [.removed, .added].contains($0.kind) }
                        let kept = history.files[key]?.screens[victim.frameID]
                        report(id, removed.isEmpty && kept != nil,
                               "partial \(capture.partial), 삭제·추가 변경 \(removed.count)건, 화면 남음 \(kept != nil), pageID \(kept?.pageID == victim.pageID ? "실제 페이지" : "그대로 다른 페이지")")
                    } catch {
                        report(id, false, "오류 \(error)")
                    }
                }
            }

        }
        }
        print("C25 시작"); fflush(stdout)
        if let record = sync.history.files[key], let source = sync.source(key) {
            // C25: 링크 범위 소스는 메뉴 경로를 타지 않는다
            if let victim = targets.first {
                var scoped = source
                scoped.scope = [DesignScope(nodeID: victim.frameID, name: victim.title, pageID: victim.pageID, frames: [victim.frameID])]
                var known = record
                known.lastModified = nil
                do {
                    let outcome = try await DesignSyncEngine.runMenu(source: scoped, paths: [path], token: token, known: known,
                                                                     transport: { try await FigmaClient.shared.send($0) })
                    if case .captured(let capture) = outcome {
                        report("C25", !capture.partial && capture.scoped, "partial \(capture.partial), 링크 범위로 받음 \(capture.scoped), 화면 \(capture.screens.count)개")
                    } else { report("C25", nil, "바뀌지 않아 받지 않음") }
                } catch { report("C25", false, "오류 \(error)") }
            }
        }

        // C6·C28: 받는 중에 다른 메뉴·같은 메뉴·프로젝트 요청
        let other = Set(sync.history.files[key]?.screens.values.map(\.menuPath) ?? []).sorted().first { !DesignStatus.covers(path, $0) } ?? path
        var order = [String]()
        var calls = [String]()
        let watcher = Task { @MainActor in
            var last = ""
            while !Task.isCancelled {
                let now = sync.fetchingMenu.map { "메뉴:" + $0.paths.joined() } ?? sync.fetching.map { _ in "프로젝트" } ?? ""
                if !now.isEmpty && now != last { order.append(now); last = now }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in "메뉴A \(await menu(path, in: key))" }
            try? await Task.sleep(nanoseconds: 200_000_000)
            group.addTask { @MainActor in "메뉴B \(await menu(other, in: key))" }
            group.addTask { @MainActor in "메뉴A다시 \(await menu(path, in: key))" }
            let queuedSame = sync.queuedMenus.filter { $0.paths == [path] }.count
            group.addTask { @MainActor in "프로젝트 \(await project(key))" }
            for await call in group { calls.append(call) }
            report("C28", queuedSame <= 1, "같은 메뉴 대기열 \(queuedSame)개")
        }
        watcher.cancel()
        report("C6", calls.count == 4 && !sync.syncing && sync.fetchingMenu == nil && sync.queuedMenus.isEmpty && sync.queued.isEmpty,
               "완료 \(calls.sorted()), 받은 순서 \(order), syncing \(sync.syncing), 대기 메뉴 \(sync.queuedMenus.count)")

        // C8: 반영 체크 → 반영 완료 → 풀기, 구현 체크
        if let event = sync.history.events.last(where: { $0.fileKey == key && !$0.changes.isEmpty && !sync.history.isApplied($0) && $0.kind != .changelog }),
           let change = event.changes.first(where: { $0.op != .renumbered }) {
            sync.toggleChecked(change, in: event.id)
            let checkedOK = onDisk().checked[event.id.uuidString]?.contains(change.key) == true
            sync.setApplied(event.id, true)
            let appliedOK = onDisk().applied.contains(event.id)
            sync.setApplied(event.id, false)
            let unappliedOK = !onDisk().applied.contains(event.id)
            sync.toggleChecked(change, in: event.id)
            report("C8", checkedOK && appliedOK && unappliedOK && onDisk().checked[event.id.uuidString] == nil,
                   "\(event.screenID): 반영 체크 저장 \(checkedOK), 반영 완료 저장 \(appliedOK), 풀기 \(unappliedOK), 체크 풀기 후 빈칸 \(onDisk().checked[event.id.uuidString] == nil)")
        }
        if let screen = targets.first(where: { !$0.items.isEmpty }), let item = screen.items.first {
            sync.toggleBuilt(item, of: screen, in: key)
            let built = onDisk().built(screen, in: key).contains(item.text)
            sync.toggleBuilt(item, of: screen, in: key)
            report("C8b", built && onDisk().built(screen, in: key).isEmpty, "구현 체크 저장 \(built), 풀기 후 비어 있음 \(onDisk().built(screen, in: key).isEmpty)")
        }

        // C9: 실제 기록으로 만든 Claude 문구
        let changePrompt = sync.claudePrompt(menu: path, in: key)
        let buildPrompt = sync.claudeBuildPrompt(menu: path, in: key)
        try? changePrompt.write(to: folder.appendingPathComponent("prompt-menu.txt"), atomically: true, encoding: .utf8)
        try? buildPrompt.write(to: folder.appendingPathComponent("prompt-build.txt"), atomically: true, encoding: .utf8)
        let banned = ["[지금 기능 명세]", "- 프로젝트:", "작성자", "[목업 문구]"]
        let leaked = banned.filter { changePrompt.contains($0) || buildPrompt.contains($0) }
        report("C9", leaked.isEmpty && changePrompt.contains("피그마: ") && buildPrompt.contains("피그마: "),
               "변경 문구 \(changePrompt.count)자, 마크업 문구 \(buildPrompt.count)자, 들어가면 안 되는 것 \(leaked)")

        // C11·C12·C17: 메뉴 작업대 스냅숏, 끝난 화면 숨기기, 찾기 0건
        page.scope = .group(fileKey: key, head: path)
        page.menuTab = .screens
        report("C11", nil, await shot("C11-menu"))
        if let screen = targets.first(where: { !$0.items.isEmpty && sync.pendingEvents(for: $0, in: key).isEmpty }) {
            for item in screen.items where !sync.history.built(screen, in: key).contains(item.text) { sync.toggleBuilt(item, of: screen, in: key) }
            page.hidesBuiltScreens = true
            let hidden = await shot("C12-hidden")
            page.hidesBuiltScreens = false
            for item in screen.items { sync.toggleBuilt(item, of: screen, in: key) }
            report("C12", nil, "모두 구현 체크한 \(screen.screenID) \(screen.title) 숨김 → \(hidden)")
        } else {
            report("C12", nil, "반영할 변경이 없고 명세가 있는 화면이 이 메뉴에 없음 (반영할 변경 \(targets.map { sync.pendingEvents(for: $0, in: key).count }))")
        }
        page.search = "없는말zzz"
        report("C17", nil, await shot("C17-search"))
        page.search = ""

        // C13: 다른 메뉴의 변경을 고른 채 메뉴를 옮기면 상세가 비워진다
        if let foreign = sync.history.events.last(where: { $0.fileKey == key && !$0.concerns(path) && $0.kind != .changelog }) {
            page.scope = .important
            page.selected = foreign.id
            page.scope = .group(fileKey: key, head: path)
            let cleared = page.selected == nil
            let own = sync.history.events.last { $0.fileKey == key && $0.concerns(path) && $0.kind != .changelog }
            page.scope = .important
            page.selected = own?.id
            page.scope = .group(fileKey: key, head: path)
            report("C13", cleared && (own == nil || page.selected == own?.id),
                   "다른 메뉴 변경 비움 \(cleared), 같은 메뉴 변경 남음 \(own == nil ? "해당 없음" : String(page.selected == own?.id))")
        }

        // C14·C20·C32·C33·C15: 날짜 비교
        let compare = DesignCompareModel.shared
        compare.open(fileKey: key, path: path)
        page.scope = .compare
        compare.source = .record
        compare.preset = 3
        let three = compare.recorded().count
        report("C14", nil, "3일 기록 \(three)건 → \(await shot("C14-compare-3d"))")
        compare.preset = 7
        let week = compare.recorded().count
        report("C14b", week >= three, "1주 \(week)건 ≥ 3일 \(three)건")
        compare.preset = 0
        let (from, to) = (compare.from, compare.to)
        compare.from = to
        compare.to = from
        report("C20", compare.recorded().count == week, "날짜를 거꾸로 넣어도 \(compare.recorded().count)건 (1주 \(week)건)")
        compare.preset = 7
        if let screen = targets.first {
            compare.open(fileKey: key, path: screen.menuPath, screen: DesignCompareModel.Target(screen))
            let one = compare.recorded()
            compare.open(fileKey: key, path: nil)
            let all = compare.recorded().count
            let foreignInOne = one.filter { $0.kind != .changelog && $0.frameID != screen.frameID && $0.beforeFrameID != screen.frameID }
            report("C32", one.count <= week && week <= all && foreignInOne.isEmpty,
                   "화면 \(one.count) ≤ 메뉴 \(week) ≤ 프로젝트 \(all), 화면 결과에 다른 화면 \(foreignInOne.count)건")
        }
        let quiet = Set(sync.history.files[key]?.screens.values.map(\.menuPath) ?? []).sorted().first { menu in
            !sync.history.events.contains { $0.fileKey == key && $0.concerns(menu) }
        }
        if let quiet {
            compare.open(fileKey: key, path: quiet)
            compare.preset = 1
            report("C33", compare.recorded().isEmpty, "변경 없는 메뉴 \(quiet) 1일 \(compare.recorded().count)건 → \(await shot("C33-empty"))")
        }
        compare.open(fileKey: key, path: path)
        compare.preset = 3
        compare.source = .figma
        try? await Task.sleep(nanoseconds: 300_000_000)
        if !compare.running && compare.currentResult == nil { compare.run() }
        for _ in 0..<400 where compare.running { try? await Task.sleep(nanoseconds: 500_000_000) }
        report("C15", !compare.running && (compare.currentResult != nil || compare.error != nil),
               "결과 \(compare.currentResult.map { "변경 \($0.events.count)건, \(DesignFormat.stamp($0.from.createdAt))→\(DesignFormat.stamp($0.to.createdAt))" } ?? "없음"), 오류 \(compare.error ?? "없음") → \(await shot("C15-figma"))")
        compare.source = .record

        // C29: 메뉴 받는 중 프로젝트를 숨기고 전체 가져오기를 대기열에 넣는다
        let fileKeys = Set(sync.history.files.keys)
        mark = await sent()
        async let hiddenMenu = menu(path, in: key)
        try? await Task.sleep(nanoseconds: 100_000_000)
        sync.setProjectHidden(key, hidden: true)
        let all: Int = await withCheckedContinuation { done in sync.sync { done.resume(returning: $0) } }
        let menuResult = await hiddenMenu
        report("C29", !sync.syncing, "메뉴 \(menuResult)건, 전체 \(all)건, 요청 \(await sent() - mark)번 (메뉴만이면 1번), syncing \(sync.syncing)")
        sync.setProjectHidden(key, hidden: false)

        // C27: 메뉴 받는 중 프로젝트를 지운다 (디버그 설정과 사본 기록에서만, 끝나면 되돌림)
        let saved = DesignSyncSettings.shared.sources
        async let removedMenu = menu(path, in: key)
        try? await Task.sleep(nanoseconds: 100_000_000)
        sync.removeSource(key)
        let removedResult = await removedMenu
        report("C27", !sync.syncing && sync.history.files[key] == nil,
               "콜백 \(removedResult)건, syncing \(sync.syncing), 기록에 다시 생김 \(sync.history.files[key] != nil), 다른 파일 그대로 \(fileKeys.subtracting([key]) == Set(sync.history.files.keys))")
        DesignSyncSettings.shared.sources = saved
    }

    /// C7·C30: 토큰이 없거나 틀렸을 때 메뉴 두 개를 잇달아 요청한다. 기록은 그대로여야 한다
    private static func noToken(key: String, path: String) async {
        let sync = DesignSync.shared
        let before = try? DesignHistoryFile.encode(sync.history)
        var calls: [String] = []
        await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in "첫 요청 콜백 \(await menu(path, in: key))건" }
            group.addTask { @MainActor in "둘째 요청 콜백 \(await menu(path, in: key))건" }
            for await call in group { calls.append(call) }
        }
        let unchanged = (try? DesignHistoryFile.encode(sync.history)) == before
        report("C7/C30", calls.count == 2 && !sync.syncing && sync.fetchingMenu == nil && unchanged,
               "\(calls.sorted()), 공통 오류 \(sync.errors["*"] ?? "없음"), 파일 오류 \(sync.errors[key] ?? "없음"), syncing \(sync.syncing), 기록 그대로 \(unchanged)")
    }

    /// 결함을 고친 뒤 다시 보는 케이스: 작업대 건수와 문구(C38), 숨기기 요약(C37), 날짜 비교 상세(C35)·가져온 시각(C36)·같은 ID 표시(C34), 다음 화면 넘기기·복사 알림
    private static func verify(key: String, path: String) async {
        let sync = DesignSync.shared
        let page = DesignHistoryPage.shared
        let screens = sync.screens(key, under: path)
        let pendingScreens = screens.filter { !sync.pendingEvents(for: $0, in: key).isEmpty }
        let prompt = sync.claudePrompt(menu: path, in: key)
        let inPrompt = prompt.components(separatedBy: "[화면] ").count - 1
        report("C38", pendingScreens.count == inPrompt, "반영할 변경이 있는 화면 \(pendingScreens.map(\.screenID)) / 문구의 화면 \(inPrompt)개, 알림 '\(DesignFormat.copied(prompt))'")

        page.scope = .group(fileKey: key, head: path)
        page.menuTab = .screens
        report("C38b", nil, await shot("V-menu"))
        // 다음 화면 넘기기: 첫 화면을 연 뒤 다음으로 넘겨 달라고 한다
        if screens.count > 1 {
            page.screen = screens[0].frameID
            try? await Task.sleep(nanoseconds: 300_000_000)
            page.stepRequest += 1
            try? await Task.sleep(nanoseconds: 500_000_000)
            let order = DesignTimeline.grouped(screens).flatMap { $0.screens.map(\.frameID) }
            report("S3", page.screen == order[1], "첫 화면 \(order[0]) → 넘긴 뒤 \(page.screen ?? "nil") (다음 \(order[1]))")
            page.screen = nil
        }

        // C37: 끝난 화면을 숨겨도 요약은 메뉴 전체
        let other = "대시보드 > SQL 위젯 관리"
        if let done = sync.screens(key, under: other).first(where: { !$0.items.isEmpty && sync.pendingEvents(for: $0, in: key).isEmpty }) {
            for item in done.items where !sync.history.built(done, in: key).contains(item.text) { sync.toggleBuilt(item, of: done, in: key) }
            page.scope = .menu(fileKey: key, path: other)
            page.hidesBuiltScreens = true
            report("C37", nil, "\(done.screenID) 구현 \(done.items.count)개 체크 후 숨김 → \(await shot("V-hide"))")
            page.hidesBuiltScreens = false
            for item in done.items { sync.toggleBuilt(item, of: done, in: key) }
        }

        // C35: 결과 밖 변경을 고른 채 날짜 비교 범위를 바꾼다
        let compare = DesignCompareModel.shared
        if let own = sync.history.events.last(where: { $0.fileKey == key && $0.concerns(path) && $0.kind != .changelog }) {
            page.scope = .compare
            compare.open(fileKey: key, path: path)
            compare.source = .record
            compare.preset = 7
            page.selected = own.id
            compare.open(fileKey: key, path: other)
            compare.preset = 1
            report("C35", !compare.shownEvents.contains { $0.id == own.id }, "고른 변경이 결과에 없음, 상세 → \(await shot("V-compare-empty"))")
        }

        // C34: 같은 화면 ID 프레임 표시
        compare.open(fileKey: key, path: nil)
        compare.preset = 3
        page.selected = nil
        report("C34", nil, await shot("V-compare-dup"))

        // C36: 방금 메뉴를 가져온 뒤 오늘까지 피그마 버전 비교
        _ = await menu(path, in: key)
        compare.open(fileKey: key, path: path)
        compare.source = .figma
        try? await Task.sleep(nanoseconds: 300_000_000)
        if !compare.running && compare.currentResult == nil { compare.run() }
        for _ in 0..<400 where compare.running { try? await Task.sleep(nanoseconds: 500_000_000) }
        if let result = compare.currentResult {
            let age = result.checkedAt.map { Date().timeIntervalSince($0) } ?? -1
            report("C36", result.toIsRecord && age >= 0 && age < DesignCompareModel.staleRecord,
                   "지금 상태 확인 \(result.checkedAt.map(DesignFormat.stamp) ?? "-"), 파일 고친 때 \(DesignFormat.stamp(result.to.createdAt)), \(Int(age))초 전 → \(await shot("V-compare-figma"))")
        } else {
            report("C36", false, "결과 없음, 오류 \(compare.error ?? "-")")
        }
    }

    /// C12·C13 다시: 반영할 변경이 남은 화면은 숨기지 않고, 끄면 돌아오며, 화면을 고른 채 프로젝트를 바꾸면 비운다
    private static func hide(key: String, path: String) async {
        let sync = DesignSync.shared
        let page = DesignHistoryPage.shared
        page.scope = .group(fileKey: key, head: path)
        page.menuTab = .screens
        guard let busy = sync.screens(key, under: path).first(where: { !$0.items.isEmpty && !sync.pendingEvents(for: $0, in: key).isEmpty }) else {
            report("C12", nil, "반영할 변경이 남은 화면이 없음"); return
        }
        for item in busy.items where !sync.history.built(busy, in: key).contains(item.text) { sync.toggleBuilt(item, of: busy, in: key) }
        page.hidesBuiltScreens = true
        let on = await shot("C12-busy-on")
        page.hidesBuiltScreens = false
        let off = await shot("C12-busy-off")
        for item in busy.items { sync.toggleBuilt(item, of: busy, in: key) }
        report("C12", nil, "명세를 모두 체크했지만 반영할 변경이 남은 \(busy.screenID): 숨기기 켬 \(on), 끔 \(off)")
        page.screen = busy.frameID
        let selected = page.screen != nil
        page.project = "다른프로젝트"
        report("C13b", selected && page.screen == nil, "화면 고름 \(selected) → 프로젝트 바꾼 뒤 screen \(page.screen ?? "nil")")
    }
}
