import AppKit
import DesignSyncCore
import WorkLogCore

/// 앱 창의 메뉴를 차례로 열어 보는 점검 (`RUNTIME_MENU_CHECK=<사진 폴더>`). 키보드와 마우스를 쓰지 않아 쓰던 일을 방해하지 않는다.
/// 일지·디자인 기록·hosts는 환경 변수로 가리킨 사본을 쓴다.
@MainActor
enum MenuCheck {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool) {
        print((ok ? "통과  " : "실패  ") + name)
        // 출력을 파일로 받으면 끝날 때 한꺼번에 써져, 오래 걸리는 단계가 멈춘 것처럼 보인다
        fflush(stdout)
        if !ok { failures += 1 }
    }

    private static func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func memory() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return Int(info.resident_size / 1_048_576)
    }

    private static func capture(_ window: NSWindow, _ name: String, into folder: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), folder + "/" + name + ".png"]
        try? process.run()
        process.waitUntilExit()
    }

    /// 묶음 안 줄을 실제 글 칸으로 고친다. 초점을 주면 그 묶음에 고정되고, 글자를 넣으면 경로가 다시 붙고,
    /// 고치는 동안 묶음이 풀리지 않고, 고치는 중에 묶음을 접으면 고정이 풀리는지 본다.
    private static func editInsidePathGroup(_ window: NSWindow, page: WorkLogPage, store: WorkLogStore) async {
        let (today, path) = (WorkDay.today(), "점검 > 묶음")
        (page.search, page.mode, page.day) = ("", .day, today)
        let added = ["첫째 줄", "둘째 줄"].compactMap { store.add(day: today, project: "점검", title: path + " > " + $0) }
        await settle(0.8)
        let field = textField(showing: "첫째 줄", in: window.contentView)
        check("묶음 안 줄은 글 칸에 끝 이름만 보인다", added.count == 2 && field != nil)
        if let field, let id = added.first?.id {
            window.makeFirstResponder(field)
            await settle(0.4)
            check("글 칸에 초점을 주면 그 묶음에 고정된다", page.pinnedPaths[id] == path)
            if let editor = window.firstResponder as? NSTextView {
                editor.moveToEndOfDocument(nil)
                editor.insertText(" 고침", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            await settle(0.4)
            check("고친 이름 앞에 경로가 다시 붙는다", store.entry(id)?.title == path + " > 첫째 줄 고침")
            check("고치는 동안 초점이 글 칸에 남는다", (window.firstResponder as? NSTextView)?.delegate === field)
            let shown = WorkLogFormat.pathTree(store.log.entries(on: today).filter { $0.project == "점검" }, pinned: page.pinnedPaths)
            check("고치는 동안 묶음 머리가 그대로다", shown.contains { if case .heading(path, _, _, 2) = $0 { true } else { false } })
            let folds = PathFolds(page: page, scope: "day|점검")
            folds.toggle(path)
            await settle(0.6)
            check("고치는 중에 묶음을 접으면 고정이 풀린다", page.pinnedPaths[id] == nil)
            folds.toggle(path)
        }
        window.makeFirstResponder(nil)
        for entry in added { store.delete(entry.id) }
        await settle(0.4)
    }

    /// 화면에서 그 글을 보이는 고칠 수 있는 글 칸.
    private static func textField(showing text: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.stringValue == text { return field }
        return view.subviews.lazy.compactMap { textField(showing: text, in: $0) }.first
    }

    /// 다음 화면을 그릴 때까지 메인 스레드가 얼마나 막히는지 잰다.
    private static func timed(_ body: () -> Void) async -> Int {
        let started = Date()
        body()
        await Task.yield()
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: Int(Date().timeIntervalSince(started) * 1000)) }
        }
    }

    static func run(window: @escaping () -> NSWindow?, navigator: MainNavigator, page: WorkLogPage, folder: String) {
        Task {
            await settle(3)
            guard let main = window() else {
                check("앱 창이 뜬다", false)
                exit(1)
            }
            for target in MainPage.allCases {
                let cost = await timed { navigator.go(target) }
                await settle(target == .redmine ? 3 : 1.2)
                check("\(target.title) 화면을 연다 (\(cost)ms)", navigator.page == target && cost < 1500)
                capture(main, target.rawValue, into: folder)
            }

            navigator.go(.workLog)
            await settle()
            let store = WorkLogStore.shared
            let lines = store.log.entries.count
            let entry = store.add(day: WorkDay.today(), project: "점검", title: "메뉴 점검 줄")
            check("일지에 줄을 넣는다", store.log.entries.count == lines + 1)
            for mode in [WorkLogPage.Mode.week, .month, .day] {
                let cost = await timed { page.mode = mode }
                await settle(0.8)
                check("일지 \(mode.rawValue) 보기 (\(cost)ms)", page.mode == mode && cost < 1000)
                capture(main, "worklog-\(mode.rawValue)", into: folder)
            }
            if let entry { store.delete(entry.id) }
            check("넣은 줄을 지운다", store.log.entries.count == lines)

            await editInsidePathGroup(main, page: page, store: store)

            // 목록·달력 선택은 저장되어, 점검이 끝나면 쓰던 값으로 돌려 둔다
            let monthCalendar = page.monthCalendar
            page.mode = .month
            page.monthCalendar = true
            await settle(0.8)
            check("월간을 달력으로 본다", page.mode == .month && page.monthCalendar)
            capture(main, "worklog-month-calendar", into: folder)
            page.monthCalendar = monthCalendar
            page.mode = .day

            navigator.go(.hosts)
            await settle()
            let hosts = HostsStore.shared
            check("호스트를 읽는다", hosts.loaded && hosts.problem == nil && !hosts.sections.isEmpty)
            if let section = hosts.sections.first(where: { $0.title != nil }) ?? hosts.sections.first {
                let on = section.items.contains(where: \.enabled)
                let saved: String? = await withCheckedContinuation { continuation in
                    hosts.quickToggle(section, !on) { continuation.resume(returning: $0) }
                }
                await settle()
                check("호스트 묶음을 끄고 켠다", saved == nil && hosts.saved.text.contains("#"))
                _ = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    hosts.quickToggle(hosts.sections.first { $0.id == section.id } ?? section, on) { continuation.resume(returning: $0) }
                }
            }

            navigator.go(.runners)
            await settle()
            let decor = GameDecor.shared
            let before = decor.equipped
            if let item = Cosmetic.allCases.first(where: { !before.contains($0) }) {
                decor.choose(item)
                check("꾸미기를 고른다", decor.equipped.contains(item))
                await settle()
                capture(main, "runners-decor", into: folder)
                decor.choose(item)
                check("고른 꾸미기를 뗀다", !decor.equipped.contains(item))
            }

            navigator.go(.design)
            await settle()
            let design = DesignSync.shared
            let first = await timed { _ = design.menus }
            let again = await timed { _ = design.menus }
            check("디자인 메뉴 목록 (\(design.menus.count)개, 처음 \(first)ms, 다음 \(again)ms)", again <= max(first, 5))
            // 기록에는 레이어 자리를 두지 않고, 화면 상세를 열 때 자리 파일에서 채운다
            let stored = design.history.files.flatMap { key, file in file.screens.values.map { (key, $0) } }
            check("기록에는 화면 자리를 두지 않는다", stored.allSatisfy { $0.1.places == nil })
            if let (key, screen) = stored.first(where: { !$0.1.texts.isEmpty }) {
                check("화면 상세는 자리 파일에서 자리를 채운다", design.placed(screen, in: key).places?.isEmpty == false)
            }

            var started = Date()
            let loaded = try? DesignHistoryFile.load()
            let readCost = Int(Date().timeIntervalSince(started) * 1000)
            started = Date()
            let written = loaded.flatMap { try? DesignHistoryFile.encode($0) }
            print("디자인 기록 \((written?.count ?? 0) / 1_048_576)MB: 읽기 \(readCost)ms, 쓰기 \(Int(Date().timeIntervalSince(started) * 1000))ms")

            let start = memory()
            var worst = 0
            for _ in 0..<6 {
                for target in MainPage.allCases {
                    worst = max(worst, await timed { navigator.go(target) })
                    await settle(0.15)
                }
            }
            await settle(1)
            let end = memory()
            print("화면 48번 전환: 가장 오래 \(worst)ms, 메모리 \(start)MB → \(end)MB")
            check("전환을 되풀이해도 메모리가 크게 늘지 않는다", end - start < 80)
            check("전환이 1초 넘게 막히지 않는다", worst < 1000)
            print(failures == 0 ? "메뉴 점검 모두 통과" : "메뉴 점검 실패 \(failures)건")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
