import Cocoa
import Carbon.HIToolbox

/// 다른 프로세스의 창 하나에 명령을 차례로 해 보고 창이 바라던 자리에 갔는지 본다 (`RunTime --window-check`).
/// 자기 창을 손쉬운 사용 API로 옮기면 메인 스레드가 스스로를 기다려 멈추므로 대상 창은 따로 띄운다.
public enum WindowCheck {
    public struct Line {
        public let name: String
        public let ok: Bool
        public let detail: String
    }

    public static func run(pid: pid_t) -> [Line] {
        guard AXIsProcessTrusted() else {
            return [Line(name: "손쉬운 사용 권한", ok: false, detail: "이 프로세스(또는 띄운 터미널)에 권한이 없습니다")]
        }
        guard let window = waitForWindow(pid: pid, title: mainTitle) else {
            return [Line(name: "대상 창", ok: false, detail: "5초 안에 창을 찾지 못했습니다")]
        }
        let id = window.getWindowId()
        let original = window.frame
        guard let screen = ScreenDetection().detectScreens(using: window)?.currentScreen else {
            return [Line(name: "화면", ok: false, detail: "창이 있는 화면을 찾지 못했습니다")]
        }
        let visible = screen.adjustedVisibleFrame()
        let manager = WindowManager()
        var lines: [Line] = []

        func run(_ action: WindowAction) -> CGRect {
            manager.execute(ExecutionParameters(action, windowElement: window, windowId: id, source: .keyboardShortcut))
            pump(0.15)
            return window.frame.screenFlipped
        }
        func expect(_ name: String, _ action: WindowAction, _ want: (CGRect) -> Bool, _ wantText: String) {
            let got = run(action)
            lines.append(Line(name: name, ok: want(got), detail: "기대 \(wantText), 실제 \(text(got))"))
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 2 }
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
        }
        func first(_ action: WindowAction) -> CGRect {
            let params = RectCalculationParameters(window: Window(id: id, rect: window.frame.screenFlipped),
                                                   visibleFrameOfScreen: visible, action: action, lastAction: nil)
            return WindowCalculationFactory.calculationsByAction[action]?.calculateRect(params).rect ?? .null
        }

        let savedMode = Defaults.subsequentExecutionMode.value
        let savedGap = Defaults.gapSize.value
        Defaults.subsequentExecutionMode.value = .resize
        Defaults.gapSize.value = 0
        defer {
            Defaults.subsequentExecutionMode.value = savedMode
            Defaults.gapSize.value = savedGap
        }

        for action in [WindowAction.leftHalf, .rightHalf, .topHalf, .topLeft, .bottomRight, .firstThird, .lastTwoThirds, .maximize, .almostMaximize] {
            let want = first(action)
            expect(action.name, action, { same($0, want) }, text(want))
        }
        _ = run(.leftHalf)
        expect("leftHalf 거듭 → 2/3", .leftHalf, { near($0.width, visible.width * 2 / 3) && near($0.minX, visible.minX) }, "너비 \(Int(visible.width * 2 / 3))")
        expect("leftHalf 거듭 → 1/3", .leftHalf, { near($0.width, visible.width / 3) }, "너비 \(Int(visible.width / 3))")

        let size = run(.firstThird).size
        expect("center", .center, { near($0.midX, visible.midX) && near($0.width, size.width) }, "가운데, 너비 \(Int(size.width))")
        // 화면 너비를 다 쓴 창은 높이로만 커지니 넓이로 본다
        expect("larger", .larger, { $0.width * $0.height > size.width * size.height }, "\(Int(size.width))×\(Int(size.height))보다 크게")
        expect("restore", .restore, { same($0.screenFlipped, original) }, text(original.screenFlipped))

        Defaults.gapSize.value = 10
        expect("여백 10pt + leftHalf", .leftHalf, {
            near($0.minX, visible.minX + 10) && near($0.width, visible.width / 2 - 15)
        }, "x \(Int(visible.minX + 10)), 너비 \(Int(visible.width / 2 - 15))")

        if NSScreen.screens.count > 1 {
            let before = NSScreen.screens.first { $0.frame.contains(window.frame.screenFlipped.centerPoint) }
            let after = run(.nextDisplay)
            let moved = NSScreen.screens.first { $0.frame.contains(after.centerPoint) }
            lines.append(Line(name: "nextDisplay", ok: before != moved, detail: "다른 모니터로 옮겨졌는지"))
        }
        window.setFrame(original)
        return lines
    }

    /// 실제 입력 경로를 본다: 단축키 처리기, 화면 가장자리로 끌어 붙이기, 다시 끌어내면 원래 크기.
    /// 마우스 포인터를 잠깐 움직였다가 제자리로 돌려놓는다.
    public static func runInput(pid: pid_t) -> [Line] {
        guard AXIsProcessTrusted(), let window = waitForWindow(pid: pid, title: mainTitle),
              let screen = ScreenDetection().detectScreens(using: window)?.currentScreen else { return [] }
        let original = window.frame
        let visible = screen.adjustedVisibleFrame()
        var lines: [Line] = []
        let control = WindowControl.shared
        let savedSnapping = Defaults.windowSnapping.enabled
        Defaults.windowSnapping.enabled = true
        defer { Defaults.windowSnapping.enabled = savedSnapping }
        guard control.start() else { return [Line(name: "창 배치 시작", ok: false, detail: "")] }
        pump(0.3)

        let failed = control.failedSlots.sorted()
        let bound = MASShortcutBinder.shared()?.boundKeys.count ?? 0
        lines.append(Line(name: "단축키 등록", ok: failed.isEmpty && bound > 0,
                          detail: failed.isEmpty ? "\(bound)개" : "못 잡음: \(failed.joined(separator: ", "))"))

        // 합성 키로는 Carbon 단축키가 발동하지 않아 처리기에 단축키 이벤트를 직접 넣는다
        NSRunningApplication(processIdentifier: pid)?.activate()
        pump(0.3)
        let pressed = MASShortcutBinder.shared()?.simulatePress(defaultsKey: WindowAction.rightHalf.name) ?? false
        pump(0.4)
        let half = window.frame.screenFlipped
        lines.append(Line(name: "단축키 → rightHalf", ok: pressed && abs(half.minX - visible.midX) <= 2 && abs(half.width - visible.width / 2) <= 2,
                          detail: "실제 \(text(half))"))
        window.setFrame(original)
        pump(0.3)

        // 위쪽 끝은 가로·세로 화면 모두 최대화다 (세로 화면의 왼쪽·오른쪽 끝은 3분할). 위에 모니터가 붙어 있으면 왼쪽 끝을 쓴다
        let cg = screen.frame.screenFlipped
        let others = NSScreen.screens.filter { $0 != screen }.map { $0.frame.screenFlipped }
        let topFree = !others.contains { abs($0.maxY - cg.minY) < 1 && $0.minX < cg.maxX && $0.maxX > cg.minX }
        let (edge, action): (CGPoint, WindowAction) = topFree ? (CGPoint(x: cg.midX, y: cg.minY + 1), .maximize)
            : (CGPoint(x: cg.minX + 1, y: cg.midY), screen.frame.isLandscape ? .leftHalf : .centerThird)
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let grab = CGPoint(x: original.midX, y: original.minY + 12)
        drag(from: grab, to: edge)
        pump(0.6)
        let snapped = window.frame.screenFlipped
        let want = WindowCalculationFactory.calculationsByAction[action]?.calculateRect(
            RectCalculationParameters(window: Window(id: nil, rect: snapped), visibleFrameOfScreen: visible, action: action, lastAction: nil)).rect ?? .null
        let snappedOK = abs(snapped.minX - want.minX) <= 2 && abs(snapped.width - want.width) <= 2 && abs(snapped.height - want.height) <= 2
        lines.append(Line(name: "끌어다 붙이기 → \(action.name)", ok: snappedOK, detail: "기대 \(text(want)), 실제 \(text(snapped))"))

        // 붙인 창을 다시 끌어내면 붙이기 전 크기로
        let title = CGPoint(x: window.frame.midX, y: window.frame.minY + 12)
        drag(from: title, to: CGPoint(x: cg.midX, y: cg.midY))
        pump(0.6)
        let restored = window.frame
        lines.append(Line(name: "다시 끌어내면 원래 크기", ok: abs(restored.width - original.width) <= 2 && abs(restored.height - original.height) <= 2,
                          detail: "기대 \(Int(original.width))×\(Int(original.height)), 실제 \(Int(restored.width))×\(Int(restored.height))"))

        CGWarpMouseCursorPosition(cursor)
        window.setFrame(original)
        control.stop()
        return lines
    }

    /// 메뉴, 끄고 켜기, 여러 창 배열, 애니메이션, 배치 저장·불러오기, 새 창 자동 배치를 본다. 마우스는 쓰지 않는다.
    public static func runFeatures(pid: pid_t) -> [Line] {
        guard AXIsProcessTrusted(), let window = waitForWindow(pid: pid, title: mainTitle),
              let second = waitForWindow(pid: pid, title: mainTitle + " 2"),
              let screen = ScreenDetection().detectScreens(using: window)?.currentScreen else { return [] }
        let control = WindowControl.shared
        let binder = MASShortcutBinder.shared()!
        let original = window.frame, originalSecond = second.frame
        let visible = screen.adjustedVisibleFrame()
        var lines: [Line] = []
        func run(_ action: WindowAction, on target: AccessibilityElement = window, wait: TimeInterval = 0.3) -> CGRect {
            NotificationCenter.default.post(name: action.notificationName,
                                            object: ExecutionParameters(action, windowElement: target, windowId: target.getWindowId()))
            pump(wait)
            return target.frame.screenFlipped
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 2 }
        defer {
            window.setFrame(original)
            second.setFrame(originalSecond)
            control.stop()
        }

        guard control.start() else { return [Line(name: "창 배치 시작", ok: false, detail: "")] }
        pump(0.3)
        let menu = WindowMenu()
        menu.menuNeedsUpdate(menu.menu)
        let titles = menu.menu.items.map(\.title)
        lines.append(Line(name: "메뉴", ok: titles.contains("왼쪽 절반") && titles.contains("배치") && menu.menu.items.count < 40,
                          detail: "항목 \(menu.menu.items.count)개"))

        control.stop()
        let pausedKeys = binder.boundKeys.count
        let pausedMove = run(.leftHalf)
        control.start()
        pump(0.3)
        lines.append(Line(name: "끄면 쉬고 켜면 돌아옴", ok: pausedKeys == 0 && near(pausedMove.width, original.width) && binder.boundKeys.count > 0,
                          detail: "꺼졌을 때 단축키 \(pausedKeys)개, 다시 켠 뒤 \(binder.boundKeys.count)개"))

        // 같은 앱 창 둘을 나란히
        let tiled = run(.tileActiveApp, wait: 0.6)
        let other = second.frame.screenFlipped
        lines.append(Line(name: "이 앱 창 바둑판 배열", ok: !tiled.intersects(other.insetBy(dx: 2, dy: 2)) && tiled.width < visible.width,
                          detail: "\(text(tiled)) · \(text(other))"))

        let savedAnimations = Defaults.experimentalWindowAnimations.enabled
        Defaults.experimentalWindowAnimations.enabled = true
        Notification.Name.windowAnimationPreferencesChanged.post()
        let animated = run(.rightHalf, wait: 1.0)
        Defaults.experimentalWindowAnimations.enabled = savedAnimations
        Notification.Name.windowAnimationPreferencesChanged.post()
        lines.append(Line(name: "애니메이션으로 옮기기", ok: near(animated.minX, visible.midX) && near(animated.width, visible.width / 2),
                          detail: "실제 \(text(animated))"))

        window.setFrame(original)
        pump(0.2)
        let layouts = WindowLayouts.shared
        // 불러오기·되돌리기가 사용자가 쓰는 다른 앱 창을 옮기지 않게 점검 창만 옮긴다
        layouts.onlyApp = NSRunningApplication(processIdentifier: pid).flatMap(WindowLayouts.key(of:))
        defer { layouts.onlyApp = nil }
        let saved = layouts.save(named: "RunTime 점검")
        _ = run(.maximize)
        layouts.restore(saved)
        pump(0.4)
        let back = window.frame
        layouts.delete(saved)
        lines.append(Line(name: "배치 저장·불러오기", ok: near(back.minX, original.minX) && near(back.width, original.width) && near(back.height, original.height),
                          detail: "창 \(saved.windowCount)개 저장, 되돌린 자리 \(text(back.screenFlipped))"))

        // RunTime이 더한 명령: 포커스 옮기기. 사용자가 쓰는 다른 앱 창으로 가지 않게 후보를 점검 창으로 좁힌다
        window.setFrame(original)
        _ = run(.leftHalf)
        _ = run(.rightHalf, on: second)
        let focused = WindowExtraCommand.focusRight.perform(on: window, onlyPID: pid)
        pump(0.4)
        let front = AccessibilityElement(pid).windowElements?.first { $0.isMainWindow == true }?.title
        lines.append(Line(name: "오른쪽 창으로 포커스", ok: focused && front == mainTitle + " 2", detail: "그 앱의 앞 창: \(front ?? "없음")"))

        // 조금씩 옮기기 (점검 창에만)
        second.setFrame(originalSecond)
        window.setFrame(original)
        pump(0.2)
        let before = window.frame
        _ = WindowExtraCommand.nudgeRight.perform(on: window)
        pump(0.2)
        let nudged = window.frame
        lines.append(Line(name: "오른쪽으로 조금", ok: near(nudged.minX - before.minX, WindowExtraCommand.nudgeStep) && near(nudged.width, before.width),
                          detail: "\(Int(before.minX)) → \(Int(nudged.minX))"))

        // 누르고 있으면 되풀이: 창을 건드리지 않는 시험용 단축키로 센다
        var count = 0
        let testKey = "check.repeat"
        WindowDefaults.store.set(MASDictionaryTransformer().reverseTransformedValue(MASShortcut(keyCode: 105, modifierFlags: [.control, .option, .command])), forKey: testKey)
        binder.bindShortcut(withDefaultsKey: testKey) { count += 1 }
        binder.repeatingKeys.insert(testKey)
        _ = binder.simulatePress(defaultsKey: testKey)
        pump(0.8)
        _ = binder.simulatePress(defaultsKey: testKey, down: false)
        pump(0.1)
        let whileHeld = count
        pump(0.4)
        binder.breakBinding(withDefaultsKey: testKey)
        binder.repeatingKeys.remove(testKey)
        WindowDefaults.store.removeObject(forKey: testKey)
        lines.append(Line(name: "누르고 있으면 되풀이, 놓으면 멈춤", ok: whileHeld >= 5 && count == whileHeld,
                          detail: "0.8초 동안 \(whileHeld)번, 놓은 뒤 \(count - whileHeld)번"))

        // 최대화한 창을 다른 모니터로 보내도 최대화 (Rectangle #1080·#1264)
        if NSScreen.screens.count > 1 {
            _ = run(.maximize)
            let moved = run(.nextDisplay, wait: 0.6)
            // moved는 화면 아래쪽이 0인 좌표라 NSScreen.frame과 그대로 견준다
            let target = NSScreen.screens.first { $0.frame.contains(moved.centerPoint) }
            let full = target?.adjustedVisibleFrame() ?? .null
            lines.append(Line(name: "최대화한 창은 다른 모니터에서도 최대화", ok: near(moved.width, full.width) && near(moved.height, full.height),
                              detail: "실제 \(text(moved)), 그 모니터 \(text(full))"))
        }

        // 모니터 구성별 기억: 지금 자리를 찍고, 창을 옮긴 뒤 구성이 바뀐 것처럼 하면 찍은 자리로 돌아온다
        window.setFrame(original)
        second.setFrame(originalSecond)
        pump(0.3)
        layouts.quietUntil = .distantPast
        layouts.snapshot()
        // 이 창이 지금 자리로 찍힐 때까지 기다린다 (먼저 돌던 찍기가 다른 자리를 담았을 수 있다)
        for _ in 0..<60 where layouts.snapshots[WindowLayouts.screenSignature()]?.contains(where: { $0.title == mainTitle && $0.frame == original }) != true {
            layouts.snapshot()
            pump(0.1)
        }
        _ = run(.maximize)
        layouts.lastScreens = "점검"
        layouts.screensChanged()
        pump(2.6)
        let remembered = window.frame
        lines.append(Line(name: "모니터를 바꾸면 창 자리 되돌리기", ok: near(remembered.minX, original.minX) && near(remembered.width, original.width),
                          detail: "되돌린 자리 \(text(remembered.screenFlipped))"))

        // 새 창 자동 배치는 설정 화면에서 뺐지만, Rectangle 설정 파일의 newWindowAction으로는 여전히 켤 수 있다
        let savedRule = Defaults.newWindowAction.value
        Defaults.newWindowAction.value = WindowAction.rightHalf.name
        Notification.Name.configImported.post()
        // 앱마다 새 창 감시를 붙이는 데 시간이 걸린다
        pump(1.5)
        kill(pid, SIGUSR1)
        var placed: CGRect = .null
        for _ in 0..<50 {
            pump(0.1)
            if let fresh = AccessibilityElement(pid).windowElements?.first(where: { $0.title == "RunTime 새 창" }) {
                placed = fresh.frame.screenFlipped
                if near(placed.minX, visible.midX) { break }
            }
        }
        Defaults.newWindowAction.value = savedRule
        Notification.Name.configImported.post()
        lines.append(Line(name: "새 창 자동 배치", ok: near(placed.minX, visible.midX) && near(placed.width, visible.width / 2),
                          detail: "실제 \(text(placed))"))
        return lines
    }

    /// 늘 도는 일의 비용을 잰다: 30초마다 하는 창 자리 찍기, 설정 화면이 한 번 그릴 때 읽는 단축키 표.
    public static func measure(extra: [WindowShortcutSlot]) -> [Line] {
        func time(_ runs: Int, _ body: () -> Void) -> Double {
            let start = Date()
            for _ in 0..<runs { body() }
            return Date().timeIntervalSince(start) / Double(runs) * 1000
        }
        var windows = 0
        let capture = time(3) { windows = WindowLayouts.captureWindows().count }
        let table = time(20) { _ = WindowControl.shared.keyTable(extra: extra) }
        let menu = WindowMenu()
        WindowControl.shared.start()
        let menuTime = time(10) { menu.menuNeedsUpdate(menu.menu) }
        let items = menu.menu.items.count
        WindowControl.shared.stop()
        return [
            Line(name: "창 자리 찍기 (30초마다, 다른 스레드)", ok: capture < 500, detail: String(format: "창 %d개에 %.0fms", windows, capture)),
            Line(name: "설정 화면 단축키 표 (그릴 때 한 번)", ok: table < 30, detail: String(format: "%.1fms", table)),
            Line(name: "메뉴 열기", ok: menuTime < 100 && items > 20, detail: String(format: "항목 %d개, %.1fms", items, menuTime)),
        ]
    }

    private static let mainTitle = "RunTime 창 배치 점검"

    private static func drag(from start: CGPoint, to end: CGPoint) {
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, start)
        pump(0.1)
        post(.leftMouseDown, start)
        pump(0.2)
        let steps = 24
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            pump(0.02)
        }
        pump(0.3)
        post(.leftMouseUp, end)
    }

    /// 전역 이벤트 감시는 앱 이벤트 대기열을 돌려야 불린다.
    private static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: min(until, Date().addingTimeInterval(0.02)), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private static func waitForWindow(pid: pid_t, title: String) -> AccessibilityElement? {
        let app = AccessibilityElement(pid)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let window = app.windowElements?.first(where: { $0.title == title }) { return window }
            pump(0.1)
        }
        return nil
    }


    private static func text(_ rect: CGRect) -> String {
        guard !rect.isNull, !rect.isInfinite else { return "(없음)" }
        return "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width))×\(Int(rect.height)))"
    }

}
