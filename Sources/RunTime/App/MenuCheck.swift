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

            navigator.go(.calendar)
            await settle()
            let day = page.day
            page.calendarDay = WorkDay.adding(-3, to: day)
            await settle()
            check("캘린더에서 날을 골라도 일지의 날은 그대로다", page.day == day)
            capture(main, "calendar-pick", into: folder)

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
