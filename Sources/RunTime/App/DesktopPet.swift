import AppKit
import Combine
import UsageCore

/// 화면 위로 꺼낸 펫. 늘 위에 뜬 투명한 창에서 화면 네 모서리(바닥·오른쪽 벽·천장·왼쪽 벽)를 따라 걷는다.
/// 메뉴바 러너와 같은 상태(Claude 사용량)로 걷고 달리며, 메뉴바가 하는 동작을 함께 한다. 혼자 둘 때는 가끔 돌아서거나 쉬고,
/// 벽이나 천장에서 뛰어내리기도 한다. 누르면 쓰다듬고 키를 받아 ←→(벽에서는 ↑↓)로 걷고 스페이스로 뛰거나 뛰어내린다.
/// 끌어 옮기면 놓은 자리에 머문다 (다른 모니터로도). 오른쪽 클릭 '움직임'에서 다시 돌아다니게 한다. 펫 몸 위가 아니면 클릭이 뒤 창으로 지나간다. 메인 스레드에서만 쓴다.
final class DesktopPet {
    static let shared = DesktopPet()

    enum Edge: String { case bottom, right, top, left }

    /// 혼자 둘 때 어떻게 움직이는지.
    enum Mode: String, CaseIterable {
        /// 화면 네 가장자리를 따라 돌아다닌다.
        case roam
        /// 화면 아래에서만 오간다.
        case floor
        /// 끌어 놓은 자리에 머물며 그 자리에서 뛰고 걷는 시늉만 한다 (다음에 켜도 그 자리).
        case pinned

        var title: String {
            switch self {
            case .roam: "화면 가장자리를 돌아다니기"
            case .floor: "화면 아래에서만 걷기"
            case .pinned: "한 자리에 머물기"
            }
        }

        /// 예전에 저장한 '제자리에서 뛰기'는 '한 자리에 머물기'로 잇는다.
        init?(saved raw: String) {
            if raw == "stay" { self = .pinned } else if let mode = Mode(rawValue: raw) { self = mode } else { return nil }
        }
    }

    /// 지금 상태 (메뉴바와 같은 값).
    var displayProvider: () -> SpriteDisplay = { .normal(.walking) }
    var characterProvider: () -> RunnerCharacter = { Runner.cat.character }
    var themeProvider: () -> SpriteTheme = { .natural }
    var companionProvider: () -> RunnerCharacter? = { nil }
    /// 크기 배율 (1이 보통, 펫 키 약 70pt).
    var sizeProvider: () -> CGFloat = { 1 }
    var modeProvider: () -> Mode = { .roam }
    /// '놓은 자리에 두기'에서 둔 발 자리 (화면 좌표). 다음에 켜도 그 자리에서 나온다.
    var pinnedProvider: () -> CGPoint? = { nil }
    /// 쓰다듬기·뛰기를 메뉴바 러너에 보낸다. 메뉴바가 하면 `SpriteAnimator.performed`로 돌아와 이 펫도 한다.
    var perform: (Trick) -> Void = { _ in }
    /// 꺼냈는지 바뀔 때 (설정에 저장).
    var onChange: (Bool) -> Void = { _ in }
    /// 오른쪽 클릭 메뉴에서 크기·돌아다니기를 바꿀 때.
    var onSize: (CGFloat) -> Void = { _ in }
    var onMode: (Mode) -> Void = { _ in }
    var onPin: (CGPoint) -> Void = { _ in }
    /// 오른쪽 클릭 메뉴에서 앱 창의 화면을 바로 연다.
    var openPage: (MainPage) -> Void = { _ in }

    private var panel: PetPanel?
    private var view: PetView?
    private var timer: Timer?
    private var tricks: AnyCancellable?

    /// 화면 테두리를 반시계 방향으로 한 바퀴 잰 자리 (바닥 왼쪽 끝이 0). 모서리 위에 있을 때 쓴다.
    private var along: CGFloat = 0
    /// 떨어지거나 들려 있을 때의 발 자리 (화면 좌표, 위로 +). nil이면 모서리 위.
    private var free: CGPoint?
    private var fallSpeed: CGFloat = 0
    /// 바닥에서 뛴 높이.
    private var lift: CGFloat = 0
    private var liftSpeed: CGFloat = 0
    /// 걷는 쪽 (테두리 반시계 방향이 +1). 바닥에서는 오른쪽, 오른쪽 벽에서는 위가 +1이다.
    private var heading: CGFloat = 1
    /// 지금 그리는 기울기. 모서리를 돌 때 목표 기울기로 부드럽게 따라간다.
    private var angle: CGFloat = 0
    private var gait: CGFloat = 0
    private var buddyGait: CGFloat = 0
    private var trick: (kind: Trick, start: Date)?
    /// 누르고 있는 키 (화면 방향).
    private var held: (left: Bool, right: Bool, up: Bool, down: Bool) = (false, false, false, false)
    private var lastControl = Date.distantPast
    private var lastTick: Date?
    private var drag: (grab: CGSize, point: CGPoint)?
    /// 마우스를 누르고 있는지. 누른 채 끌기 시작하기 전에 펫이 걸어서 마우스 밑을 벗어나면 끌기를 놓쳐서,
    /// 누르는 동안은 멈추고 클릭을 계속 받는다.
    private var pressing = false
    /// 커서가 펫 가까이 있는지. 걷는 펫을 커서로 맞추기 어려워, 가까이 오면 멈춰 잡기 쉽게 한다.
    private var hovering = false
    private var hoverEnded = Date.distantPast
    /// 커서가 이만큼(pt) 가까이 오면 멈추고 클릭을 받는다.
    private static let reach: CGFloat = 20
    private var dropHeight: CGFloat = 0
    private var bodyOnScreen = CGRect.zero
    /// 혼자 둘 때 다음에 무엇을 할지 정할 때와, 그때까지 쉬는지.
    private var nextWhim = Date()
    private var resting = false

    /// 크기 배율 1에서 설계 1pt를 몇 pt로 그릴지.
    private static let baseScale: CGFloat = 4
    private var scale: CGFloat { Self.baseScale * min(max(sizeProvider(), 0.5), 2.5) }
    /// 회전해도 잘리지 않게 정사각형 창을 쓴다. 펫과 뒤따르는 동료가 들어가는 폭.
    private var side: CGFloat { (Stage.size.width * scale + 130).rounded() }

    var isShown: Bool { panel != nil }
    /// 점검 도구가 읽는 자리. `lift`는 바닥 위 높이.
    var position: (x: CGFloat, lift: CGFloat, facing: CGFloat) {
        let feet = feetOnScreen
        return (feet.x, max(0, feet.y - area.minY), edge == .bottom ? heading : 1)
    }
    var groundY: CGFloat { area.minY }
    var panelFrame: NSRect { panel?.frame ?? .zero }
    var bodyCenter: CGPoint { CGPoint(bodyOnScreen.midX, bodyOnScreen.midY) }
    var takesClicks: Bool { panel?.ignoresMouseEvents == false }
    /// 점검 도구가 커서를 움직이지 않고 '커서가 여기 있다'고 알릴 때.
    var pointerForCheck: CGPoint?
    var panelWindow: NSWindow? { panel }
    var edgeName: String { free == nil ? edge.rawValue : "free" }

    /// 점검 도구가 지금 모습을 PNG로 남긴다.
    func snapshot(to file: URL) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    /// 점검 도구가 모서리 근처에서 시작해 보려고 자리를 옮긴다.
    func place(along value: CGFloat, heading: CGFloat) {
        free = nil
        along = value
        self.heading = heading
        lastControl = .distantPast
        nextWhim = Date().addingTimeInterval(60)
        resting = false
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard panel == nil, NSScreen.main != nil else { return }
        let panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = PetView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.pet = self
        panel.contentView = view
        self.panel = panel
        self.view = view
        // 놓아 둔 자리가 있으면 그 자리에, 아니면 오른쪽 위에서 톡 떨어지며 나온다
        let screen = area
        if modeProvider() == .pinned, let spot = pinnedProvider(), NSScreen.screens.contains(where: { $0.frame.contains(spot) }) {
            free = spot
        } else {
            free = CGPoint(screen.maxX - 220, screen.minY + 160)
        }
        fallSpeed = 0
        dropHeight = 160
        angle = 0
        // 나오자마자 쉬거나 돌아서면 멈춰 있는 것처럼 보여, 처음 몇 초는 걷기만 한다
        nextWhim = Date().addingTimeInterval(8)
        resting = false
        lastTick = nil
        place()
        panel.orderFrontRegardless()
        tricks = SpriteAnimator.performed.sink { [weak self] trick in self?.play(trick) }
        schedule(fps: 60)
        onChange(true)
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        tricks = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
        held = (false, false, false, false)
        drag = nil
        pressing = false
        onChange(false)
    }

    /// 크기를 바꾸면 창을 새 크기로 다시 잡는다.
    func resize() {
        guard let panel, let view else { return }
        let size = NSSize(width: side, height: side)
        panel.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        place()
    }

    private func schedule(fps: Double) {
        if let timer, abs(timer.timeInterval - 1 / fps) < 0.001 { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2 / fps
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: 화면 테두리

    /// 걷는 화면 (메뉴바와 Dock을 뺀 자리).
    private var area: NSRect {
        let point = free ?? lastFeet
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    private var lastFeet = CGPoint.zero
    private var perimeter: CGFloat { 2 * (area.width + area.height) }

    private var edge: Edge { edge(of: along) }

    private func edge(of p: CGFloat) -> Edge {
        let a = area
        if p < a.width { return .bottom }
        if p < a.width + a.height { return .right }
        if p < 2 * a.width + a.height { return .top }
        return .left
    }

    /// 테두리 위 자리의 화면 좌표.
    private func point(along p: CGFloat) -> CGPoint {
        let a = area
        switch edge(of: p) {
        case .bottom: return CGPoint(a.minX + p, a.minY)
        case .right: return CGPoint(a.maxX, a.minY + (p - a.width))
        case .top: return CGPoint(a.maxX - (p - a.width - a.height), a.maxY)
        case .left: return CGPoint(a.minX, a.maxY - (p - 2 * a.width - a.height))
        }
    }

    /// 모서리마다 펫의 위쪽이 화면 안쪽을 보게 돌리는 각도 (그리는 좌표, 시계 방향 +).
    private static func angle(for edge: Edge) -> CGFloat {
        switch edge {
        case .bottom: 0
        case .right: -.pi / 2
        case .top: .pi
        case .left: .pi / 2
        }
    }

    private var feetOnScreen: CGPoint {
        if var free {
            if modeProvider() == .pinned, drag == nil { free.y += lift }
            return free
        }
        var feet = point(along: along)
        feet.y += edge == .bottom ? lift : 0
        return feet
    }

    // MARK: 동작

    private func play(_ kind: Trick) {
        guard lift == 0, drag == nil, free == nil else { return }
        // 이 펫이 메뉴바에 보낸 동작이 돌아올 때 이미 하는 중이면 처음부터 다시 하지 않는다
        if let trick, trick.kind == kind, Date().timeIntervalSince(trick.start) < 0.4 { return }
        trick = (kind, Date())
    }

    /// 점검 도구가 펫을 누른 것처럼 키 입력을 받게 한다.
    func takeKeyboardForCheck() {
        panel?.makeKey()
        lastControl = Date()
    }
    var hasKeyboard: Bool { panel?.isKeyWindow == true }

    fileprivate func clicked() {
        lastControl = Date()
        perform(Trick.petting.randomElement() ?? .greet)
    }

    /// 방향키 말고 다른 키가 오면 키 입력을 바로 돌려준다. 앱을 앞으로 가져오지 않는 창이라
    /// 쥐고 있으면 다른 앱에서 치는 글자가 이 창으로 와 경고음과 함께 사라진다.
    fileprivate func releaseKeyboard() {
        held = (false, false, false, false)
        panel?.resignKey()
    }

    func key(_ code: UInt16, down: Bool, repeated: Bool) -> Bool {
        switch code {
        case 123: held.left = down
        case 124: held.right = down
        case 125: held.down = down
        case 126:
            held.up = down
            if down, !repeated, edge == .bottom, free == nil { jump() }
        case 49:
            if down, !repeated {
                if modeProvider() == .pinned || (edge == .bottom && free == nil) {
                    jump()
                } else {
                    dropOff()
                }
            }
        case 53:
            if down { panel?.resignKey() }
        default: return false
        }
        lastControl = Date()
        resting = false
        if down { trick = nil }
        return true
    }

    private func jump() {
        guard lift == 0, drag == nil, free == nil || modeProvider() == .pinned else { return }
        liftSpeed = 320
        lift = 0.01
        trick = nil
        perform(.hop)
    }

    /// 벽이나 천장에서 손을 놓고 바닥으로 떨어진다.
    private func dropOff() {
        guard free == nil, edge != .bottom else { return }
        let feet = feetOnScreen
        // 벽에서는 안쪽으로 조금 떨어져야 벽에 붙은 채 미끄러져 보이지 않는다
        let inset: CGFloat = edge == .right ? -24 : (edge == .left ? 24 : 0)
        free = CGPoint(feet.x + inset, edge == .top ? feet.y - 20 : feet.y)
        fallSpeed = 0
        dropHeight = feet.y - area.minY
        trick = nil
    }

    fileprivate func press(_ down: Bool) {
        pressing = down
        if down { trick = nil }
    }

    func beginDrag(at point: CGPoint) {
        let feet = feetOnScreen
        drag = (CGSize(width: point.x - feet.x, height: point.y - feet.y), point)
        free = feet
        lift = 0
        trick = nil
        perform(.wiggle)
    }

    func dragged(to point: CGPoint) {
        guard let current = drag else { return }
        drag = (current.grab, point)
    }

    func endDrag() {
        guard drag != nil, let free else { return }
        drag = nil
        pressing = false
        fallSpeed = 0
        lastControl = Date()
        // 끌어 놓은 자리에 둔다. 돌아다니던 중이었으면 '놓은 자리에 두기'로 바꾼다
        if modeProvider() != .pinned { onMode(.pinned) }
        onPin(free)
    }

    /// 오른쪽 클릭 메뉴: 앱의 화면으로 바로 가기, 펫 크기, 움직이는 방식, 넣기.
    fileprivate func menu() -> NSMenu {
        let menu = NSMenu()
        let pages: [(String, MainPage)] = [("사용량 보기", .usage), ("펫 바꾸기·꾸미기", .runners), ("업무 일지", .workLog),
                                          ("레드마인", .redmine), ("디자인 변경", .design), ("설정", .settings)]
        for (title, page) in pages {
            let item = NSMenuItem(title: title, action: #selector(PetView.menuPage(_:)), keyEquivalent: "")
            item.target = view
            item.representedObject = page.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sizes = NSMenu()
        for (title, value) in [("작게", 0.7), ("보통", 1.0), ("크게", 1.4), ("아주 크게", 2.0)] as [(String, CGFloat)] {
            let item = NSMenuItem(title: title, action: #selector(PetView.menuSize(_:)), keyEquivalent: "")
            item.target = view
            item.representedObject = value
            item.state = abs(sizeProvider() - value) < 0.05 ? .on : .off
            sizes.addItem(item)
        }
        let size = NSMenuItem(title: "펫 크기", action: nil, keyEquivalent: "")
        size.submenu = sizes
        menu.addItem(size)
        let modes = NSMenu()
        for mode in Mode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(PetView.menuMode(_:)), keyEquivalent: "")
            item.target = view
            item.representedObject = mode.rawValue
            item.state = modeProvider() == mode ? .on : .off
            modes.addItem(item)
        }
        let move = NSMenuItem(title: "움직이는 방식", action: nil, keyEquivalent: "")
        move.submenu = modes
        menu.addItem(move)
        menu.addItem(.separator())
        let put = NSMenuItem(title: "펫 넣기 (화면에서 치우기)", action: #selector(PetView.putBack), keyEquivalent: "")
        put.target = view
        menu.addItem(put)
        return menu
    }

    fileprivate func chooseSize(_ value: CGFloat) {
        onSize(value)
        resize()
    }

    /// 설정 화면에서 움직임을 바꿀 때. 꺼내 두지 않았으면 저장만 한다.
    func setMode(_ mode: Mode) {
        guard isShown else { return }
        choose(mode)
    }

    fileprivate func choose(_ mode: Mode) {
        onMode(mode)
        switch mode {
        case .pinned:
            // 지금 자리에 둔다 (모서리 위면 그 자리, 기울기는 바로 선다)
            let feet = feetOnScreen
            free = feet
            lift = 0
            onPin(feet)
        case .floor:
            if free == nil, edge != .bottom { dropOff() }
        case .roam:
            break
        }
        // 놓아 둔 자리에서 다른 방식으로 바꾸면 거기서 떨어진다
        if mode != .pinned, let free, drag == nil {
            fallSpeed = 0
            dropHeight = free.y - area.minY
        }
    }

    // MARK: 한 프레임

    private func tick() {
        let now = Date()
        let dt = CGFloat(min(max(now.timeIntervalSince(lastTick ?? now), 0), 0.1))
        lastTick = now
        let display = displayProvider()
        let a = area
        var velocity: CGFloat = 0   // 테두리를 따라 (반시계 +)
        if let drag {
            let target = CGPoint(drag.point.x - drag.grab.width, drag.point.y - drag.grab.height)
            let current = free ?? target
            velocity = (target.x - current.x) / max(dt, 0.001)
            free = CGPoint(current.x + (target.x - current.x) * min(1, dt * 20),
                           max(a.minY, current.y + (target.y - current.y) * min(1, dt * 20)))
        } else if var spot = free, modeProvider() == .pinned {
            // 머무는 자리: 방향키로 조금씩 옮기고, 스페이스로 그 자리에서 뛴다
            let x: CGFloat = (held.right ? 1 : 0) - (held.left ? 1 : 0)
            let y: CGFloat = (held.up ? 1 : 0) - (held.down ? 1 : 0)
            if x != 0 || y != 0 {
                spot.x = min(max(spot.x + x * 150 * dt, a.minX + 20), a.maxX - 20)
                spot.y = min(max(spot.y + y * 150 * dt, a.minY), a.maxY - 20)
                free = spot
                onPin(spot)
                velocity = x * 150
                if x != 0 { heading = x }
            }
            if lift > 0 || liftSpeed > 0 {
                liftSpeed -= 1500 * dt
                lift += liftSpeed * dt
                if lift <= 0 { lift = 0; liftSpeed = 0 }
            }
        } else if var falling = free {
            // 떨어지는 중: 바닥에 닿으면 바닥 위로 돌아가고, 높이서 떨어졌으면 한 번 통 튄다
            fallSpeed -= 1500 * dt
            falling.y += fallSpeed * dt
            falling.x = min(max(falling.x, a.minX + 20), a.maxX - 20)
            if falling.y <= a.minY {
                free = nil
                along = falling.x - a.minX
                lastFeet = CGPoint(falling.x, a.minY)
                if dropHeight > 30 {
                    liftSpeed = min(dropHeight * 2.2, 420)
                    lift = 0.01
                }
                if dropHeight > 150 { perform(.dizzy) }
                dropHeight = 0
            } else {
                free = falling
            }
        } else {
            let mode = modeProvider()
            // 누르고 있거나 커서가 가까이 있으면 멈춘다. 커서가 떠나도 잠깐은 기다려 다시 잡으려는 손을 피하지 않는다
            let waiting = pressing || hovering || now.timeIntervalSince(hoverEnded) < 0.8
            velocity = pressing ? 0 : control(edge: edge) * 150
            if velocity == 0, !waiting, trick == nil, !resting, now.timeIntervalSince(lastControl) > 2 {
                // 직접 움직이지 않으면 상태 빠르기대로 테두리를 따라 걷는다
                velocity = heading * Self.walkSpeed(display)
            }
            if velocity != 0 { heading = velocity > 0 ? 1 : -1 }
            wander(now: now, display: display)
            var next = along + velocity * dt
            if mode == .roam {
                next = next.truncatingRemainder(dividingBy: perimeter)
                if next < 0 { next += perimeter }
            } else if next < 30 || next > a.width - 30 {
                // 바닥에서만 걸을 때는 양끝에서 돌아선다
                next = min(max(next, 30), a.width - 30)
                heading = -heading
            }
            along = next
            if lift > 0 || liftSpeed > 0 {
                liftSpeed -= 1500 * dt
                lift += liftSpeed * dt
                if lift <= 0 {
                    lift = 0
                    liftSpeed = 0
                }
            }
            lastFeet = point(along: along)
        }
        if let trick, now.timeIntervalSince(trick.start) >= trick.kind.duration { self.trick = nil }
        // 모서리를 돌 때 기울기를 짧은 쪽으로 부드럽게 맞춘다. 떨어지는 동안은 바로 선다
        let target = free == nil ? Self.angle(for: edge) : 0
        var diff = (target - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if diff > .pi { diff -= 2 * .pi }
        if diff < -.pi { diff += 2 * .pi }
        angle += diff * min(1, dt * 12)
        let moving = abs(velocity) > 8 && drag == nil && free == nil
        gait += moving ? dt * abs(velocity) / 110 : dt / CGFloat(display.cycle)
        buddyGait += dt * (moving ? abs(velocity) : 20) / 60
        place()
        view?.needsDisplay = true
        // 방향키를 4초 넘게 쓰지 않으면 키 입력을 돌려준다
        if panel?.isKeyWindow == true, now.timeIntervalSince(lastControl) > 4, drag == nil { releaseKeyboard() }
        // 펫 몸 위에서만 클릭을 받고, 나머지는 뒤 창으로 지나가게 한다
        updateHover(now: now)
        panel?.ignoresMouseEvents = drag == nil && !pressing && !hovering
        let busy = drag != nil || free != nil || lift > 0 || hovering || held.left || held.right || held.up || held.down || trick != nil
            || moving || abs(diff) > 0.01
        schedule(fps: busy ? 60 : AppSettings.shared.smoothness.fps)
    }

    /// 누른 키를 지금 모서리의 걷는 방향(반시계 +)으로 바꾼다.
    private func control(edge: Edge) -> CGFloat {
        let x: CGFloat = (held.right ? 1 : 0) - (held.left ? 1 : 0)
        let y: CGFloat = (held.up ? 1 : 0) - (held.down ? 1 : 0)
        switch edge {
        case .bottom: return x
        case .top: return -x
        case .right: return y
        case .left: return -y
        }
    }

    /// 혼자 둘 때의 변덕: 가끔 쉬고, 돌아서고, 벽이나 천장에서는 뛰어내린다.
    private func wander(now: Date, display: SpriteDisplay) {
        guard now >= nextWhim, now.timeIntervalSince(lastControl) > 2, trick == nil else { return }
        nextWhim = now.addingTimeInterval(.random(in: 6...16))
        if resting {
            resting = false
            return
        }
        switch Double.random(in: 0...1) {
        case ..<0.18: resting = true
        case ..<0.4: heading = -heading
        case ..<0.55 where edge != .bottom && modeProvider() == .roam: dropOff()
        default: break
        }
    }

    /// 커서가 펫 둘레 `reach` 안에 들어왔는지 보고 커서 모양을 바꾼다. 펫 밖에서는 클릭이 뒤 창으로 지나간다.
    private func updateHover(now: Date) {
        let near = bodyOnScreen.insetBy(dx: -Self.reach, dy: -Self.reach).contains(pointerForCheck ?? NSEvent.mouseLocation)
        if near != hovering {
            hovering = near
            if !near { hoverEnded = now }
        }
        if drag != nil {
            NSCursor.closedHand.set()
        } else if hovering {
            NSCursor.openHand.set()
        }
    }

    fileprivate func pointerLeft() {
        guard drag == nil, !pressing else { return }
        NSCursor.arrow.set()
    }

    /// 걷는 빠르기 (pt/초). 잘 때와 지칠 때는 서 있다.
    static func walkSpeed(_ display: SpriteDisplay) -> CGFloat {
        switch display {
        case .normal(.sleeping), .tired, .alert: 0
        case .straining(let state, _): walkSpeed(.normal(state))
        case .normal(.walking): 22
        case .normal(.running): 55
        case .normal(.dashing): 95
        case .normal(.rainbow): 140
        }
    }

    /// 발이 화면의 그 자리에 오게 창을 놓는다. 그릴 때 창 가운데를 기준으로 돌리므로, 돌린 발 자리만큼 창을 옮긴다.
    private func place() {
        guard let panel else { return }
        let feet = feetOnScreen
        let offset = feetOffset
        panel.setFrameOrigin(NSPoint(x: (feet.x - offset.x - side / 2).rounded(), y: (feet.y + offset.y - side / 2).rounded()))
    }

    /// 창 가운데에서 발까지 (그리는 좌표, y 아래로 +). 발은 돌리기 전 가운데에서 `drop`만큼 아래.
    private var feetOffset: CGPoint {
        let drop = Stage.size.height * scale / 2
        return CGPoint(-drop * sin(angle), drop * cos(angle))
    }

    /// 창 안에 펫과 동료를 그린다 (y 아래로). 창 가운데를 돌려 모서리마다 위쪽이 화면 안쪽을 보게 한다.
    fileprivate func draw(_ cg: CGContext, size: CGSize) {
        let display = displayProvider()
        let character = characterProvider()
        let theme = character.theme(themeProvider())
        let now = Date()
        var frame: MotionFrame
        if let trick {
            frame = trick.kind.frame(at: CGFloat(now.timeIntervalSince(trick.start) / trick.kind.duration))
        } else if held.left || held.right || held.up || held.down {
            frame = MotionFrame(pose: CharacterPose(activity: .run, phase: gait - floor(gait)))
        } else if resting, display.cycle > 0, Self.walkSpeed(display) > 0 {
            frame = MotionFrame(pose: CharacterPose(activity: .stand, phase: gait - floor(gait)))
        } else {
            frame = display.motion(at: gait)
        }
        let pinned = free != nil && drag == nil && modeProvider() == .pinned
        let airborne = lift > 1 || (free != nil && !pinned)
        if airborne { frame.pose.jump = drag != nil ? 0.45 : (fallSpeed > 0 || liftSpeed > 0 ? 0.3 : 0.7) }
        frame.transform.scaleX = abs(frame.transform.scaleX) * (free == nil || pinned ? heading : 1)
        let scale = scale
        let center = CGPoint(size.width / 2, size.height / 2)
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: angle)
        // 돌린 좌표에서 발은 가운데 아래
        let feet = CGPoint(0, Stage.size.height * scale / 2)
        let origin = CGPoint(feet.x - Stage.size.width / 2 * scale, feet.y - Stage.ground * scale)
        // 데려간 동료는 뒤에서 따라 걷는다
        if let companion = companionProvider() {
            let facing = free == nil ? heading : 1
            GameFX.drawCompanion(companion, feet: CGPoint(feet.x - facing * (Stage.size.width / 2 * scale + 14), feet.y),
                                 height: 10 * scale, phase: buddyGait, moving: Self.walkSpeed(display) > 0 && !resting,
                                 facing: facing, theme: themeProvider(), cg)
        }
        let scene = CharacterScene(rig: character.rig, pose: frame.pose, transform: frame.transform)
        cg.saveGState()
        cg.translateBy(x: origin.x, y: origin.y)
        cg.scaleBy(x: scale, y: scale)
        let look = CharacterLook(rich: true, palette: theme.richPalette(character.rig.palette,
                                                                       phase: CGFloat(now.timeIntervalSinceReferenceDate / 6)),
                                 tint: .white, outline: 0.36)
        display.drawLoopEffects(in: cg, scene: scene, phase: gait - floor(gait), tint: .white, front: false)
        scene.draw(in: cg, look: look)
        display.drawLoopEffects(in: cg, scene: scene, phase: gait - floor(gait), tint: .white, front: true)
        for effect in frame.effects { effect.draw(in: cg, around: scene.placedBounds, tint: .white) }
        cg.restoreGState()
        cg.restoreGState()
        // 누른 뒤 방향키를 받는 동안에는 위에 조작법을 띄운다
        if panel?.isKeyWindow == true {
            let text = NSAttributedString(string: "방향키로 움직이기 · 스페이스로 점프", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let box = CGRect(x: (size.width - text.size().width) / 2 - 8, y: 4, width: text.size().width + 16, height: 20)
            NSGraphicsContext.saveGraphicsState()
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            text.draw(at: CGPoint(box.minX + 8, box.minY + 3))
            NSGraphicsContext.restoreGraphicsState()
        }
        // 몸 자리를 화면 좌표로 남겨 클릭을 가린다 (돌린 사각형을 감싸는 사각형)
        let body = scene.placedBounds
        let local = CGRect(x: origin.x + body.minX * scale, y: origin.y + body.minY * scale,
                           width: body.width * scale, height: body.height * scale)
        let inView = local.applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
        if let panel {
            bodyOnScreen = CGRect(x: panel.frame.minX + inView.minX, y: panel.frame.maxY - inView.maxY,
                                  width: inView.width, height: inView.height)
        }
    }
}

/// 키를 받을 수 있는 테두리 없는 창. 앱을 앞으로 가져오지 않는다.
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// 펫이 가장자리에 붙으면 정사각형 창의 일부가 화면이나 메뉴바 밖으로 나간다. 시스템이 창을 안쪽으로 밀어 넣으면
    /// 펫이 천장·벽에서 떨어져 떠 보여서 놓은 자리 그대로 둔다.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class PetView: NSView {
    weak var pet: DesktopPet?
    private var down: NSPoint?
    private var moved = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// 다른 앱이 앞에 있어도 첫 클릭부터 받는다. 아니면 첫 클릭은 창을 앞으로 가져오는 데만 쓰여 끌기가 되지 않는다.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // 앱이 앞에 없어도 커서가 펫 위에 오가는 것을 받아 커서 모양을 바꾼다
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                               .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { pet?.pointerLeft() }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        pet?.draw(cg, size: bounds.size)
    }

    /// 이벤트가 일어난 화면 좌표. 창이 펫을 따라 움직이므로 창 안 좌표가 아니라 화면 좌표로 끈다.
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        down = screenPoint(event)
        moved = false
        pet?.press(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let point = screenPoint(event)
        if !moved, hypot(point.x - down.x, point.y - down.y) > 4 {
            moved = true
            pet?.beginDrag(at: down)
        }
        if moved { pet?.dragged(to: point) }
    }

    override func mouseUp(with event: NSEvent) {
        pet?.press(false)
        if moved { pet?.endDrag() } else { pet?.clicked() }
        down = nil
        moved = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = pet?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // 받지 않는 키는 경고음을 내지 않고 키 입력을 돌려준다
    override func keyDown(with event: NSEvent) {
        if pet?.key(event.keyCode, down: true, repeated: event.isARepeat) != true { pet?.releaseKeyboard() }
    }

    override func keyUp(with event: NSEvent) {
        _ = pet?.key(event.keyCode, down: false, repeated: false)
    }

    @objc func putBack() { pet?.hide() }
    @objc func menuPage(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let page = MainPage(rawValue: raw) { pet?.openPage(page) }
    }

    @objc func menuMode(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let mode = DesktopPet.Mode(rawValue: raw) { pet?.choose(mode) }
    }
    @objc func menuSize(_ item: NSMenuItem) {
        if let value = item.representedObject as? CGFloat { pet?.chooseSize(value) }
    }
}

/// 꺼낸 펫 점검 (`--desktop-pet-check`): 실제 창을 띄워 떨어져 내리고, 상태대로 걷고, 키로 움직이고,
/// 모서리를 따라 벽을 타고, 끌어 올렸다 떨어뜨린다. 마지막 모습을 PNG로 남긴다.
enum DesktopPetCheck {
    static func run(to file: URL, done: @escaping (Bool) -> Void) {
        let pet = DesktopPet.shared
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if !ok { failures += 1 }
        }
        var display = SpriteDisplay.normal(.running)
        var mode = DesktopPet.Mode.roam
        var grabbed = CGPoint.zero, destination = CGPoint.zero
        pet.displayProvider = { display }
        pet.modeProvider = { mode }
        pet.onMode = { mode = $0 }
        // RUNTIME_PET_SHOTS 폴더를 주면 벽·천장을 걷는 모습을 화면째 찍어 펫이 가장자리에 붙어 걷는지 본다
        func capture(_ name: String) {
            guard let folder = ProcessInfo.processInfo.environment["RUNTIME_PET_SHOTS"],
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: pet.panelFrame.midX, y: pet.panelFrame.midY)) }) else { return }
            let frame = pet.panelFrame.insetBy(dx: -40, dy: -40).intersection(screen.frame)
            // screencapture는 주 화면 왼쪽 위가 원점이다
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", "\(folder)/\(name).png"]
            try? task.run()
            task.waitUntilExit()
        }
        // 진짜 마우스 이벤트를 창에 보낸다 (커서는 움직이지 않는다)
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
            guard let window = pet.panelWindow,
                  let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            pet.pointerForCheck = point
            // AppKit은 만든 끌기 이벤트를 창에 넘기지 않아, 펫 뷰의 마우스 처리를 바로 부른다
            guard let view = window.contentView else { return }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        pet.companionProvider = { Runner.dog.character }
        pet.show()
        var start = pet.position
        let steps: [(Double, () -> Void)] = [
            (1.5, {
                check("떨어져 내려와 바닥에 선다", pet.position.lift == 0 && pet.edgeName == "bottom")
                start = pet.position
            }),
            (1.0, { check("달리는 상태면 테두리를 따라 걷는다 (\(Int(abs(pet.position.x - start.x)))pt)", abs(pet.position.x - start.x) > 20) }),
            (0.1, {
                // 걷는 펫 옆으로 커서를 가져가면 멈춰서 잡기 쉬워야 한다
                let body = pet.bodyCenter
                pet.pointerForCheck = CGPoint(body.x + 30, body.y)
            }),
            (0.3, { start = pet.position }),
            (0.8, {
                check("커서가 가까이 오면 멈추고 첫 클릭부터 받는다 (\(Int(abs(pet.position.x - start.x)))pt)",
                      abs(pet.position.x - start.x) < 1 && pet.takesClicks
                        && pet.panelWindow?.contentView?.acceptsFirstMouse(for: nil) == true)
                pet.pointerForCheck = nil
                start = pet.position
            }),
            (2.0, { check("커서가 떠나면 다시 걷는다 (\(Int(abs(pet.position.x - start.x)))pt)", abs(pet.position.x - start.x) > 20) }),
            (0.1, {
                display = .normal(.sleeping)
                _ = pet.key(123, down: true, repeated: false)
            }),
            (0.8, {
                _ = pet.key(123, down: false, repeated: false)
                check("←를 누르면 왼쪽으로 걷는다", pet.position.facing < 0)
                _ = pet.key(49, down: true, repeated: false)
            }),
            (0.15, { check("스페이스로 뛴다 (높이 \(Int(pet.position.lift)))", pet.position.lift > 10) }),
            (1.0, {
                check("뛰고 나면 내린다", pet.position.lift == 0)
                // 바닥 오른쪽 끝 바로 앞에서 오른쪽으로 걸으면 오른쪽 벽을 탄다
                display = .normal(.dashing)
                let area = NSScreen.main?.visibleFrame ?? .zero
                pet.place(along: area.width - 40, heading: 1)
            }),
            (1.5, {
                check("바닥 끝에서 오른쪽 벽으로 올라간다 (\(pet.edgeName))", pet.edgeName == "right")
                capture("wall")
                // 천장 바로 앞으로 옮겨 천장을 걷는 모습도 찍는다
                let area = NSScreen.main?.visibleFrame ?? .zero
                pet.place(along: area.width + area.height - 30, heading: 1)
            }),
            (1.2, {
                check("벽 끝에서 천장으로 넘어간다 (\(pet.edgeName))", pet.edgeName == "top")
                capture("top")
                _ = pet.key(49, down: true, repeated: false)
            }),
            // 천장에서 떨어지면 바닥까지 멀어 튀고 멈출 때까지 넉넉히 기다린다
            (3.0, { check("천장에서 스페이스를 누르면 바닥으로 떨어진다 (\(pet.edgeName))", pet.edgeName == "bottom" && pet.position.lift == 0) }),
            (0.1, {
                // 달리는 펫을 눌러 끈다. 누른 동안 펫이 걸어서 마우스 밑을 벗어나도 클릭을 놓지 않아야 한다
                display = .normal(.dashing)
                pet.place(along: 300, heading: 1)
            }),
            (0.5, {
                grabbed = pet.bodyCenter
                pet.pointerForCheck = grabbed
            }),
            (0.2, {
                mouse(.leftMouseDown, at: grabbed)
                start = pet.position
            }),
            (0.6, {
                // 몸 상자는 달리는 자세마다 바뀌어 발 자리로 본다
                check("누르고 있으면 펫이 멈추고 클릭을 계속 받는다 (\(Int(abs(pet.position.x - start.x)))pt)",
                      pet.takesClicks && abs(pet.position.x - start.x) < 1)
                // 다른 모니터가 있으면 그 화면 가운데로, 없으면 같은 화면 위쪽으로 끈다
                let target = NSScreen.screens.first { $0 != NSScreen.main } ?? NSScreen.main
                let frame = target?.visibleFrame ?? .zero
                destination = CGPoint(frame.midX, frame.midY)
                for k in 1...10 {
                    let t = CGFloat(k) / 10
                    mouse(.leftMouseDragged, at: CGPoint(grabbed.x + (destination.x - grabbed.x) * t, grabbed.y + (destination.y - grabbed.y) * t))
                }
            }),
            (0.6, {
                check("끌면 따라와 들린다 (높이 \(Int(pet.position.lift)))", pet.position.lift > 100)
                mouse(.leftMouseUp, at: destination)
            }),
            (2.5, {
                let screen = NSScreen.screens.first { $0.frame.contains(destination) }?.frame ?? .zero
                check("끌어 놓으면 그 모니터의 놓은 자리에 머문다 (\(NSScreen.screens.count)개 화면, 높이 \(Int(pet.position.lift)))",
                      screen.contains(CGPoint(pet.position.x, screen.midY)) && pet.position.lift > 100 && pet.edgeName == "free"
                        && mode == .pinned)
                // 놓은 자리에 두기: 끌어 놓으면 떨어지지 않고 머문다
                mode = .pinned
                grabbed = pet.bodyCenter
                pet.pointerForCheck = grabbed
            }),
            (0.2, {
                mouse(.leftMouseDown, at: grabbed)
                for k in 1...6 { mouse(.leftMouseDragged, at: CGPoint(grabbed.x - CGFloat(k) * 20, grabbed.y + CGFloat(k) * 40)) }
            }),
            (0.5, {
                mouse(.leftMouseUp, at: CGPoint(grabbed.x - 120, grabbed.y + 240))
            }),
            (1.5, {
                pet.pointerForCheck = nil
                check("한 자리에 머물기면 놓은 자리에 머문다 (높이 \(Int(pet.position.lift)))", pet.position.lift > 150 && pet.edgeName == "free")
                start = pet.position
            }),
            (1.5, {
                check("달리는 상태여도 머무는 자리를 옮기지 않는다 (\(Int(abs(pet.position.x - start.x)))pt)", abs(pet.position.x - start.x) < 2)
                mode = .roam
                pet.takeKeyboardForCheck()
                check("누르면 방향키를 받는다", pet.hasKeyboard)
            }),
            (4.6, {
                check("4초 동안 방향키를 쓰지 않으면 키 입력을 돌려준다", !pet.hasKeyboard)
                pet.snapshot(to: file)
                pet.hide()
                check("넣으면 창이 사라진다", !pet.isShown)
            }),
        ]
        var delay = 0.0
        for (wait, step) in steps {
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.2) { done(failures == 0) }
    }
}
