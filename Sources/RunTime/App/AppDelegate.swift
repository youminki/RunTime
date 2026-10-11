import AppKit
import SwiftUI
import Combine
import UsageCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let animator = SpriteAnimator()
    /// 러너 레이어를 담는 뷰. AppKit이 버튼 레이어를 다시 만들어도 러너가 사라지지 않게 따로 둔다.
    private let spriteView = PassthroughLayerView()
    /// 러너 바로 옆 사용률 글자. 버튼 제목은 양옆 여백이 커서 직접 둔다.
    private let percentLabel: PassthroughLabel = {
        let label = PassthroughLabel(labelWithString: "")
        label.setAccessibilityElement(false)
        return label
    }()
    private var currentLabel: StatusLabel?
    private let engine = UsageEngine()
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var dailyDetailWindow: NSWindow?
    private var leaderboardWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private let settingsTab = SettingsTabState(.general)
    /// 메뉴바 항목이 « 안에 숨었을 때 팝오버를 붙이는 보이지 않는 창.
    private var anchorWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        animator.canvas = MenuBarCanvas(barHeight: NSStatusBar.system.thickness, zoom: engine.settings.runnerSize.zoom,
                                        backing: NSScreen.main?.backingScaleFactor ?? 2)
        statusItem = NSStatusBar.system.statusItem(withLength: animator.canvas.size.width + 4)
        // 이름이 있어야 사용자가 ⌘로 끌어 옮긴 자리를 macOS가 기억한다. 없으면 켤 때마다 맨 왼쪽에 놓여
        // 메뉴가 긴 앱이 앞에 오면 가장 먼저 «로 접힌다.
        statusItem.autosaveName = "RunTime"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            // 오른쪽 클릭(또는 control 클릭)은 빠른 메뉴, 왼쪽 클릭은 사용량 창
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        if let button = statusItem.button {
            // 버튼 크기·글자 배치는 투명한 자리 표시 이미지로 잡고, 러너는 그 위 레이어에서 재생한다.
            button.image = placeholder(for: animator.canvas)
            spriteView.layer = animator.layer
            spriteView.wantsLayer = true
            button.addSubview(spriteView)
            layoutSprite()
        }
        animator.appearanceProvider = { [weak self] in
            self?.statusItem.button?.effectiveAppearance
        }
        animator.characterProvider = { [weak self] in
            self?.engine.settings.character ?? Runner.cat.character
        }
        animator.themeProvider = { [weak self] in
            self?.engine.settings.spriteTheme ?? .auto
        }
        animator.smoothnessProvider = { [weak self] in
            self?.engine.settings.smoothness ?? .smooth
        }
        animator.tricksEnabledProvider = { [weak self] in
            self?.engine.settings.tricksEnabled ?? true
        }
        animator.set(display: .normal(.sleeping))
        LeaderboardFeed.shared.start()
        AppUpdater.shared.isInUse = { [weak self] in self?.popover?.isShown ?? false }
        AppUpdater.shared.start()
        // 메뉴바가 있는 화면이 바뀌면(레티나↔일반, 메뉴바 높이) 레이어 배율과 칸 크기를 맞춘다
        NotificationCenter.default.publisher(for: NSWindow.didChangeBackingPropertiesNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification),
                   NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification,
                                                        object: statusItem.button?.window))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutSprite() }
            .store(in: &cancellables)
        statusItem.button?.setAccessibilityLabel("RunTime 사용량")

        Publishers.CombineLatest(engine.$sessionGauge, engine.$weeklyGauge)
            .map { Self.tooltip(session: $0, weekly: $1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.statusItem.button?.toolTip = text }
            .store(in: &cancellables)

        Publishers.CombineLatest3(engine.$sessionGauge, engine.$weeklyGauge, engine.settings.$menuBarLabel)
            .map { Self.statusLabel($2, session: $0, weekly: $1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] label in self?.applyStatusLabel(label) }
            .store(in: &cancellables)

        // 잠자기 동안 공식 값이 유예 시간을 넘겼을 수 있다. 네트워크가 붙을 틈을 두고 다시 읽는다.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.engine.refreshNow(forceOfficial: true) }
            .store(in: &cancellables)

        // 러너·색상·부드러움 변경 → 프레임 다시 그리기 (@Published는 값이 바뀌기 전에 알리므로 한 박자 뒤에)
        engine.settings.$spriteTheme.dropFirst().map { _ in }
            .merge(with: engine.settings.$runner.dropFirst().map { _ in },
                   engine.settings.$smoothness.dropFirst().map { _ in },
                   engine.settings.$customRunnerID.dropFirst().map { _ in },
                   engine.settings.$runnerSize.dropFirst().map { _ in },
                   CustomRunnerStore.shared.$runners.dropFirst().map { _ in },
                   PetdexStore.shared.$pets.dropFirst().map { _ in })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.animator.reloadFrames() }
            .store(in: &cancellables)
        engine.settings.$runnerSize.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutSprite() }
            .store(in: &cancellables)

        // 한도 오버라이드(§F2): 80% 이상 지침, 95% 이상 경고. 속도 상태보다 우선
        Publishers.CombineLatest(engine.$catState, engine.$alertLevel)
            .map { SpriteDisplay(state: $0, level: $1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] display in self?.animator.set(display: display) }
            .store(in: &cancellables)

        // Claude가 일을 마치면 메뉴바 러너가 축하 동작으로 알린다 (다른 창을 보고 있어도 눈에 띄게).
        // 오래 걸린 작업이고 사용량 창이 닫혀 있으면 알림도 보낸다. 짧은 대답마다 보내면 대화하는 동안 계속 울린다.
        engine.turnEnded
            .sink { [weak self] turn in
                guard let self else { return }
                _ = self.animator.perform(.celebrate)
                guard self.engine.settings.claudeDoneAlertEnabled, turn.duration >= Self.claudeDoneMinimum,
                      self.popover?.isShown != true else { return }
                let minutes = Int((turn.duration / 60).rounded())
                Notifier.shared.send(title: "Claude 작업이 끝났어요",
                                     body: [turn.project, "\(minutes)분 걸림"].compactMap { $0 }.joined(separator: " · "))
            }
            .store(in: &cancellables)

        // 같은 단계 안에서도 많이 쓸수록 빨리 달리고, 사용량 흐름의 순간마다 동작으로 반응한다
        engine.$tempo
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.animator.setTempo($0) }
            .store(in: &cancellables)
        engine.reacted
            .sink { [weak self] reaction in
                guard let self, self.engine.settings.tricksEnabled else { return }
                self.animator.perform(SpriteAnimator.trick(for: reaction))
            }
            .store(in: &cancellables)

        GlobalHotKey.shared.action = { [weak self] in
            // 다른 앱이 앞에 있을 때 누르므로, 열 때는 앱을 앞으로 가져와야 키 입력과 바깥 클릭 닫기가 된다
            if self?.popover?.isShown != true { NSApp.activate(ignoringOtherApps: true) }
            self?.togglePopover()
        }
        engine.settings.$globalHotKeyEnabled
            .removeDuplicates()
            .sink { GlobalHotKey.shared.setEnabled($0) }
            .store(in: &cancellables)

        // 알림을 누르면 그 내용을 볼 수 있는 화면을 연다
        Notifier.shared.onOpen = { [weak self] destination in
            guard let self else { return }
            switch destination {
            case .usage:
                NSApp.activate(ignoringOtherApps: true)
                if self.popover?.isShown != true { self.togglePopover() }
            case .daily:
                self.openDailyDetail()
            }
        }
        // 설정 창을 열어 둔 채 시스템 설정에서 자동 시작을 바꾸고 돌아와도 맞게 보이게
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.engine.settings.reloadLaunchAtLogin() }
            .store(in: &cancellables)
        Notifier.shared.requestAuthorization()
        engine.start()
        // 처음 설치한 사람에게만 한 번. 러너가 메뉴바에 자리 잡은 뒤에 띄운다
        if LegacyMigration.isFreshInstall && LaunchAtLogin.available {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openWelcome() }
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    /// 메뉴바 앱에서 흔히 기대하는 오른쪽 클릭 메뉴. 사용량 창을 열지 않고 자주 쓰는 곳으로 바로 간다.
    private func showQuickMenu() {
        popover?.performClose(nil)
        let menu = NSMenu()
        func add(_ title: String, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(action)
            menu.addItem(item)
        }
        let line = Self.tooltip(session: engine.sessionGauge, weekly: engine.weeklyGauge)
        menu.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        add(engine.settings.globalHotKeyEnabled && GlobalHotKey.shared.isRegistered
            ? "사용량 보기 (\(GlobalHotKey.displayName))" : "사용량 보기") { [weak self] in self?.togglePopover() }
        add("일별 사용량") { [weak self] in self?.openDailyDetail() }
        add("토큰 러너 순위") { [weak self] in self?.openLeaderboard() }
        add("새로고침") { [weak self] in self?.engine.refreshNow(forceOfficial: true) }
        menu.addItem(.separator())
        add("설정…") { [weak self] in self?.openSettings() }
        add("업데이트 확인") { [weak self] in
            AppUpdater.shared.check()
            self?.openSettings()
        }
        menu.addItem(.separator())
        add("RunTime 종료") { NSApp.terminate(nil) }
        // 메뉴를 잠깐 붙여 눌린 자리에 띄우고 바로 떼어, 왼쪽 클릭은 계속 사용량 창을 연다
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private final class MenuAction {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)   // RunCat 스타일 다크 팝오버
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(engine: engine, settings: engine.settings,
                                  openSettings: { [weak self] in self?.openSettings() },
                                  importRunner: { [weak self] in self?.importRunner() },
                                  openDailyDetail: { [weak self] in self?.openDailyDetail() },
                                  openLeaderboard: { [weak self] in self?.openLeaderboard() },
                                  performTrick: { [weak self] trick in self?.animator.perform(trick) }))
        engine.refreshNow()   // 여는 순간 JSONL 재스캔 + 공식 재조회(30초 스로틀)
        if let button = statusItem.button, let window = button.window, window.isVisible,
           NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let anchor = hiddenItemAnchor() {
            // 단축키로 열었는데 러너가 « 안에 숨어 있으면 화면 오른쪽 위, 메뉴바 바로 아래에 띄운다
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            return
        }
        Self.makeOpaque(popover)
        self.popover = popover
    }

    /// 팝오버는 뒤 창이 비치는 반투명이라 흰 창 위에서 열면 바탕이 밝아져 흰 글자·차트가 묻힌다.
    /// 내용은 SwiftUI에서 불투명하게 칠하고, 화살표를 그리는 효과 뷰도 뒤를 비추지 않게 바꾼다.
    private static func makeOpaque(_ popover: NSPopover) {
        guard let frameView = popover.contentViewController?.view.window?.contentView?.superview else { return }
        func visit(_ view: NSView) {
            if let effect = view as? NSVisualEffectView {
                effect.blendingMode = .withinWindow
                effect.material = .windowBackground
                effect.state = .active
            }
            view.subviews.forEach(visit)
        }
        visit(frameView)
    }

    private func hiddenItemAnchor() -> NSView? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return nil }
        let window = anchorWindow ?? {
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .statusBar
            window.ignoresMouseEvents = true
            return window
        }()
        window.setFrame(NSRect(x: screen.visibleFrame.maxX - 220, y: screen.visibleFrame.maxY - 1, width: 1, height: 1),
                        display: false)
        window.orderFrontRegardless()
        anchorWindow = window
        return window.contentView
    }

    /// 닫힌 팝오버의 화면을 놓아 준다. 무대 애니메이션이 보이지 않는 채로 돌지 않게.
    func popoverDidClose(_ notification: Notification) {
        // 닫히는 애니메이션 중에 다시 열었으면 새 팝오버는 건드리지 않는다
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        closed.contentViewController = nil
        popover = nil
        anchorWindow?.orderOut(nil)
        AppUpdater.shared.popoverClosed()
    }

    private func openSettings(tab: SettingsView.Tab? = nil) {
        if let tab { settingsTab.selection = tab }
        engine.settings.reloadLaunchAtLogin()
        settingsWindow = showWindow(settingsWindow, title: "RunTime 설정",
                                    style: [.titled, .closable, .resizable]) {   // 세로 드래그로 크기 조절
            SettingsView(settings: engine.settings, engine: engine, tab: settingsTab)
        }
    }

    /// 팝오버에서 누른 그림 불러오기. 팝오버를 닫은 뒤 파일 창을 띄우고, 결과는 알림 창으로 알린다.
    private func importRunner() {
        popover?.performClose(nil)
        DispatchQueue.main.async { [engine] in
            NSApp.activate(ignoringOtherApps: true)
            RunnerImport.choose(settings: engine.settings) { message, isError in
                guard isError else { return }
                let alert = NSAlert()
                alert.messageText = "러너를 만들지 못했습니다"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }

    private func openDailyDetail() {
        dailyDetailWindow = showWindow(dailyDetailWindow, title: "일별 사용량", style: [.titled, .closable]) {
            DailyDetailView(engine: engine)
        }
    }

    private func openWelcome() {
        welcomeWindow = showWindow(welcomeWindow, title: "RunTime", style: [.titled, .closable]) {
            WelcomeView(settings: engine.settings,
                        openSettings: { [weak self] in self?.openSettings() },
                        close: { [weak self] in self?.welcomeWindow?.performClose(nil) })
        }
        // 한 번만 보는 창이라 닫으면 놓아 준다 (러너 애니메이션이 남아 돌지 않게)
        if let welcomeWindow {
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: welcomeWindow)
                .first()
                .sink { [weak self] _ in self?.welcomeWindow = nil }
                .store(in: &cancellables)
        }
    }

    private func openLeaderboard() {
        leaderboardWindow = showWindow(leaderboardWindow, title: "토큰 러너 순위", style: [.titled, .closable]) {
            LeaderboardView()
        }
    }

    /// 창은 한 번만 만들고 다시 열 때는 앞으로 가져온다.
    private func showWindow<Content: View>(_ existing: NSWindow?, title: String, style: NSWindow.StyleMask,
                                           content: () -> Content) -> NSWindow {
        popover?.performClose(nil)
        let window = existing ?? {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = style
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        window.makeKeyAndOrderFront(nil)
        // 처음 열 때 글 칸(순위표 닉네임)에 커서가 가서 글자가 통째로 선택되지 않게 한다. SwiftUI가 초점을 잡은 뒤에 푼다
        if existing == nil { DispatchQueue.main.async { window.makeFirstResponder(nil) } }
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private struct StatusLabel: Equatable {
        let text: String
        let level: UsageAlertLevel
    }

    /// 고양이 옆 사용률. 공식 값이 없으면 "--%". 색은 표시 중인 %의 단계로 정한다.
    private static func statusLabel(_ label: MenuBarLabel, session: GaugeReading?, weekly: GaugeReading?) -> StatusLabel? {
        let gauge: GaugeReading?
        switch label {
        case .off: return nil
        case .session: gauge = session
        case .weekly: gauge = weekly
        case .higher: gauge = [session, weekly].compactMap { $0 }.max { $0.percent < $1.percent }
        }
        guard let gauge else { return StatusLabel(text: "--%", level: .normal) }
        return StatusLabel(text: "\(gauge.displayPercent)%", level: UsageAlertLevel.level(percent: gauge.percent))
    }

    /// 이보다 오래 걸린 작업만 알림을 보낸다.
    private static let claudeDoneMinimum: TimeInterval = 60

    private static let statusLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    /// 러너와 숫자 사이 간격. 러너 칸 오른쪽 끝이 이미 코끝이라 1pt만 둔다.
    private static let labelGap: CGFloat = 1

    private func applyStatusLabel(_ label: StatusLabel?) {
        currentLabel = label
        if let label {
            percentLabel.stringValue = label.text
            percentLabel.font = Self.statusLabelFont
            // 평소엔 메뉴바 글자색(라이트·다크 자동), 80% 주황, 95% 빨강
            percentLabel.textColor = switch label.level {
            case .normal: .labelColor
            case .tired: .systemOrange
            case .critical: .systemRed
            }
        }
        percentLabel.isHidden = label == nil
        // 화면 읽기 프로그램은 글자 뷰 대신 메뉴바 항목의 값으로 사용률을 읽는다
        statusItem.button?.setAccessibilityValue(label?.text)
        resizeStatusItem()
    }

    private var textWidth: CGFloat {
        guard let currentLabel else { return 0 }
        return ceil((currentLabel.text as NSString).size(withAttributes: [.font: Self.statusLabelFont]).width)
    }

    private var labelWidth: CGFloat { currentLabel == nil ? 0 : Self.labelGap + textWidth }

    /// NSTextField 글자 칸은 좌우에 2pt씩 안쪽 여백이 있어, 프레임을 그만큼 넓히고 왼쪽으로 당긴다.
    private static let cellInset: CGFloat = 2

    /// 항목 폭 = 러너 칸 + (켜져 있으면) 1pt + 숫자 폭. 버튼 제목을 쓰지 않아 여백이 생기지 않는다.
    private func resizeStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = placeholder(for: animator.canvas)
        statusItem.length = animator.canvas.size.width + labelWidth + 4
        DispatchQueue.main.async { self.layoutSprite() }   // 길이가 바뀐 뒤 버튼 배치가 끝나면
    }

    /// 버튼 크기·글자 배치를 잡는 투명한 이미지. 높이는 버튼(22pt)에 맞추고 러너 레이어만 위아래로 넘친다.
    private func placeholder(for canvas: MenuBarCanvas) -> NSImage {
        NSImage(size: NSSize(width: canvas.size.width + labelWidth, height: Stage.size.height))
    }

    /// 자리 표시 이미지가 놓인 자리에 러너 레이어를 맞춘다. 레이어는 버튼 위아래로 넘쳐 메뉴바 창 높이를 채운다.
    private func layoutSprite() {
        guard let button = statusItem.button, let cell = button.cell else { return }
        let canvas = MenuBarCanvas(barHeight: button.window?.frame.height ?? NSStatusBar.system.thickness,
                                   zoom: engine.settings.runnerSize.zoom,
                                   backing: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        if canvas != animator.canvas {
            animator.canvas = canvas
            resizeStatusItem()
            return
        }
        button.layoutSubtreeIfNeeded()
        let imageRect = cell.imageRect(forBounds: button.bounds)
        let rect = NSRect(x: imageRect.minX, y: (button.bounds.height - canvas.size.height) / 2,
                          width: canvas.size.width, height: canvas.size.height)
        // 버튼(22pt)과 macOS가 그 위에 둔 22pt 뷰가 자식을 잘라, 메뉴바 창 높이를 다 쓰는 콘텐츠 뷰에 얹는다.
        // 레이어 뷰는 클릭을 그대로 아래 버튼에 넘긴다.
        let host = button.window?.contentView ?? button
        if spriteView.superview !== host {
            spriteView.removeFromSuperview()
            host.addSubview(spriteView)
            percentLabel.removeFromSuperview()
            host.addSubview(percentLabel)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 픽셀 경계에 맞춰야 프레임이 반 픽셀씩 번지지 않는다
        spriteView.frame = host.backingAlignedRect(button.convert(rect, to: host),
                                                   options: [.alignMinXNearest, .alignMinYNearest,
                                                             .alignWidthNearest, .alignHeightNearest])
        animator.layer.frame = spriteView.bounds
        animator.layer.contentsScale = canvas.backing
        CATransaction.commit()
        let height = percentLabel.fittingSize.height
        percentLabel.frame = host.backingAlignedRect(
            NSRect(x: spriteView.frame.maxX + Self.labelGap - Self.cellInset, y: spriteView.frame.midY - height / 2,
                   width: textWidth + Self.cellInset * 2, height: height),
            options: .alignAllEdgesNearest)
    }

    /// 메뉴바 아이콘에 마우스를 올리면 현재 사용률을 보여준다.
    private static func tooltip(session: GaugeReading?, weekly: GaugeReading?) -> String {
        func line(_ name: String, _ gauge: GaugeReading?) -> String {
            "\(name) \(gauge.map { "\($0.displayPercent)" } ?? "--")%"
        }
        return "RunTime · \(line("세션", session)) · \(line("주간", weekly))"
    }
}

/// 클릭은 아래 상태바 버튼으로 넘기는 글자.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 클릭은 아래 상태바 버튼으로 넘기는 레이어 전용 뷰.
final class PassthroughLayerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
