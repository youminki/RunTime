import AppKit
import Carbon.HIToolbox
import Combine
import UsageCore

/// 화면 위로 꺼낸 펫. 늘 위에 뜬 투명한 창에서 화면 네 모서리(바닥·오른쪽 벽·천장·왼쪽 벽)를 따라 걷는다.
/// 메뉴바 러너와 같은 상태(Claude 사용량)로 걷고 달리며, 메뉴바가 하는 동작을 함께 한다. 혼자 둘 때는 가끔 돌아서거나 쉬고,
/// 벽이나 천장에서 뛰어내리기도 한다. 누르면 쓰다듬고 키를 받아 ←→(벽에서는 ↑↓)로 걷고 스페이스로 뛰거나 뛰어내린다.
/// 어느 앱을 쓰고 있든 ⌃⌥+방향키로 움직인다 (`PetKeys`). 사용자가 다른 모니터로 끌어 놓기 전에는 지금 화면을 벗어나지 않는다.
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

        /// 옵션 창 카드에 붙는 한 줄 설명과 그림.
        var detail: String {
            switch self {
            case .roam: "바닥·벽·천장을 따라 한 바퀴씩 돌아요"
            case .floor: "화면 아래를 오가며 걸어요"
            case .pinned: "놓은 자리에서 쉬고, 끌어서 옮겨요"
            }
        }

        var icon: String {
            switch self {
            case .roam: "arrow.triangle.2.circlepath"
            case .floor: "arrow.left.and.right"
            case .pinned: "pin.fill"
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
    var modeProvider: () -> Mode = { .pinned }
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
    /// 동료가 펫의 어느 쪽 뒤에 있는지 (-1…1, 펫이 보는 쪽의 반대가 1). 펫이 돌아서면 반대편으로 달려간다.
    private var buddySide: CGFloat = 1
    /// 동료가 바닥에서 뛴 높이. 펫보다 늦고 낮게 뛴다.
    private var buddyLift: CGFloat = 0
    /// 동료가 펫보다 뒤처진 거리 (펫 기준 가로, pt). 펫이 걸으면 늘고 멈추면 따라붙어 0으로 돌아온다.
    private var buddyLag: CGFloat = 0
    /// 조작 안내가 떠 있는 자리 (화면 좌표). 말풍선이 가리지 않게 피한다.
    private var hintOnScreen: CGRect?
    /// 동료가 반대편으로 달려가는 빠르기 (buddySide가 1초에 바뀌는 양). 0이 아니면 가는 쪽을 본다.
    private var buddyShift: CGFloat = 0
    private var trick: (kind: Trick, start: Date)?
    /// 누르고 있는 키 (화면 방향).
    private var held: (left: Bool, right: Bool, up: Bool, down: Bool) = (false, false, false, false)
    private var lastControl = Date.distantPast
    private var lastTick: Date?
    /// 화면 크기를 마지막으로 읽은 때. 프레임마다 화면 목록을 다시 만들지 않고 1초에 한 번과 화면이 바뀔 때만 읽는다.
    private var homeReadAt = Date.distantPast
    private var screenObserver: NSObjectProtocol?
    private var drag: (grab: CGSize, point: CGPoint)?
    /// 마우스를 누르고 있는지. 누른 채 끌기 시작하기 전에 펫이 걸어서 마우스 밑을 벗어나면 끌기를 놓쳐서,
    /// 누르는 동안은 멈추고 클릭을 계속 받는다.
    private var pressing = false
    /// 커서가 펫 가까이 있는지. 걷는 펫을 커서로 맞추기 어려워, 가까이 오면 멈춰 잡기 쉽게 한다.
    private var hovering = false
    private var hoverEnded = Date.distantPast
    /// 커서가 이만큼(pt) 가까이 오면 멈추고 클릭을 받는다.
    private static let reach: CGFloat = 28
    /// 커서가 떠난 뒤에도 이만큼은 기다린다. 오른쪽 클릭하려고 손을 옮기는 사이에 걸어가 버리지 않게 한다.
    private static let hoverLinger: TimeInterval = 1.5
    /// 오른쪽 클릭 메뉴가 떠 있는지. 메뉴를 고르는 동안 펫이 걸어가면 무엇을 고른 건지 헷갈려 멈춘다.
    private var menuOpen = false
    /// 발먼지 (화면 좌표의 발 자리, 난 때, 그 자리의 기울기, 크기). 무대처럼 고른 발먼지를 쓰고, 없으면 연기다.
    private var puffs: [(spray: GameFX.Spray, at: CGPoint, born: Double, angle: CGFloat, zoom: CGFloat)] = []
    private var lastStep = 0
    private var wasAirborne = false
    private var buddyWasUp = false
    private var buddyStep = 0
    private var decorWatch: AnyCancellable?
    /// 꾸미기를 바꾼 직후 꼬리를 보여 주는 때. 머무는 펫은 걷지 않아 꼬리가 생길 일이 없다.
    private var showcaseUntil = Date.distantPast
    /// 고른 꼬리가 끌린 자리 (화면 좌표). 걷는 동안만 남긴다.
    private var trail: [CGPoint] = []
    private var wearing: Set<Cosmetic> = []
    /// 쓰다듬은 때와 누구를 쓰다듬었는지. 머리 위로 하트가 피어오른다.
    private var pats: [(at: Double, buddy: Bool)] = []
    /// 동료를 눌러 뛰게 한 높이와 빠르기.
    private var buddyHop: CGFloat = 0
    private var buddyHopSpeed: CGFloat = 0
    /// 동료 몸과 발 자리 (화면 좌표). 몸을 누르면 동료가 반응한다.
    private var buddyOnScreen = CGRect.zero
    private var buddyGround: CGPoint?
    /// 이번 프레임 걷는 빠르기 (꼬리를 남길지 본다).
    private var speedNow: CGFloat = 0
    /// 발이 화면 양 끝에서 떨어져 있을 거리. 넓은 그림 펫은 앞으로 내민 머리·몸이 30pt보다 길어
    /// 끝에서 돌아설 때 화면 밖으로 잘렸다 (2026-11-12). 몸 폭의 반에 조금 더 둔다.
    private var edgeMargin: CGFloat { max(30, bodyOnScreen.width / 2 + 6) }
    /// 효과 그림은 무대 크기에 맞춰 그려져 있어 펫 크기만큼 키운다.
    private var effectZoom: CGFloat { scale / 3 }
    private var dropHeight: CGFloat = 0
    private var bodyOnScreen = CGRect.zero
    /// 혼자 둘 때 다음에 무엇을 할지 정할 때와, 그때까지 쉬는지.
    private var nextWhim = Date()
    private var resting = false

    /// 크기 배율 1에서 설계 1pt를 몇 pt로 그릴지.
    private static let baseScale: CGFloat = 4
    private var scale: CGFloat { Self.baseScale * min(max(sizeProvider(), 0.5), 2.5) }
    /// 회전해도 잘리지 않게 정사각형 창을 쓴다. 펫과 뒤따르는 동료가 들어가는 폭.
    /// 회전한 몸, 뒤따르는 동료, 등 뒤로 끌리는 꼬리(몸 뒤 150pt), 머리 위로 오르는 하트가 잘리지 않을 만큼.
    private var side: CGFloat { (Stage.size.width * scale * 2 + 160).rounded() }

    var isShown: Bool { panel != nil }
    /// 점검 도구가 읽는 자리. `lift`는 바닥 위 높이.
    var position: (x: CGFloat, lift: CGFloat, facing: CGFloat) {
        let feet = feetOnScreen
        return (feet.x, max(0, feet.y - area.minY), edge == .bottom ? heading : 1)
    }
    var groundY: CGFloat { area.minY }
    var panelFrame: NSRect { panel?.frame ?? .zero }
    var bodyCenter: CGPoint { CGPoint(bodyOnScreen.midX, bodyOnScreen.midY) }
    /// 화면에 나와 있으면 펫 몸 자리 (화면 좌표). 말풍선을 이 위에 띄운다.
    var bodyFrame: CGRect? { isShown && bodyOnScreen.width > 0 ? bodyOnScreen : nil }
    /// 말풍선이 피할 자리: 몸과, 떠 있으면 조작 안내까지.
    var bubbleTarget: CGRect? { bodyFrame.map { body in hintOnScreen.map(body.union) ?? body } }
    var takesClicks: Bool { panel?.ignoresMouseEvents == false }
    /// 점검 도구가 커서를 움직이지 않고 '커서가 여기 있다'고 알릴 때.
    var pointerForCheck: CGPoint?
    var panelWindow: NSWindow? { panel }
    var edgeName: String { free == nil ? edge.rawValue : "free" }
    /// 점검 도구가 읽는 동료 자리 (어느 쪽 뒤인지, 뛴 높이).
    var buddyForCheck: (side: CGFloat, lift: CGFloat, lag: CGFloat) { (buddySide, buddyLift, buddyLag) }
    /// 점검 도구가 읽는 발 자리(화면 좌표)와 지금 기울기.
    var feetForCheck: CGPoint { feetOnScreen }
    var tiltForCheck: CGFloat { angle }
    var playingForCheck: Bool { trick != nil }
    /// 점검 도구가 읽는 효과: 발먼지·하트 수, 동료가 뛰는지(높이나 오르는 빠르기), 동료 몸과 발 자리.
    var effectsForCheck: (puffs: Int, pats: Int, buddyHop: CGFloat, buddyBox: CGRect, buddyGround: CGPoint?, trail: Int) {
        (puffs.count, pats.count, max(buddyHop, buddyHopSpeed), buddyOnScreen, buddyGround, trail.count)
    }
    fileprivate func playForCheck(_ kind: Trick) { play(kind) }
    /// 점검 도구가 옵션 창의 움직임 카드를 누른 것처럼 고른다.
    fileprivate func optionsForCheck(_ mode: Mode) {
        PetOptions.shared.model?.mode = mode
        choose(mode)
    }

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
        // 놓아 둔 자리가 있으면 그 자리에, 아니면 지금 화면 오른쪽 위에서 톡 떨어지며 나온다
        if modeProvider() == .pinned, let spot = pinnedProvider(), NSScreen.screens.contains(where: { $0.frame.contains(spot) }) {
            moveHome(to: spot)
            free = spot
        } else {
            homeID = NSScreen.main.flatMap(Self.id(of:))
            refreshHome()
            free = CGPoint(homeArea.maxX - 220, homeArea.minY + 160)
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
        wearing = GameDecor.shared.equipped
        decorWatch = GameDecor.shared.$equipped.combineLatest(GameDecor.shared.$companionID)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] equipped, _ in self?.showcase(equipped) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.homeReadAt = .distantPast }
        PetKeys.shared.handler = { [weak self] code, down in _ = self?.key(code, down: down, repeated: false) }
        PetKeys.shared.register()
        schedule(fps: 60)
        onChange(true)
    }

    func hide() {
        PetOptions.shared.close()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        timer?.invalidate()
        timer = nil
        tricks = nil
        decorWatch = nil
        PetKeys.shared.unregister()
        panel?.orderOut(nil)
        panel = nil
        view = nil
        held = (false, false, false, false)
        drag = nil
        pressing = false
        menuOpen = false
        puffs = []
        pats = []
        trail = []
        NSCursor.arrow.set()
        onChange(false)
    }

    /// 크기를 바꾸면 창을 새 크기로 다시 잡는다.
    func resize() {
        place()
        view?.needsDisplay = true
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
    private var area: NSRect { homeArea }

    /// 펫이 사는 화면. 자리로 짐작하면 오른쪽 벽(maxX)이 옆 모니터의 시작점이라 프레임마다 화면이 뒤바뀌어,
    /// 사용자가 끌어 놓을 때만 바꾼다.
    private var homeID: CGDirectDisplayID?
    private(set) var homeFrame = NSRect.zero
    private(set) var homeArea = NSRect(x: 0, y: 0, width: 800, height: 600)
    /// 그릴 때 돌리는 가운데 (창 안, y 아래로). 창을 화면 안으로 자르면 창 가운데와 달라진다.
    private var drawCenter = CGPoint.zero

    private static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 살던 화면의 지금 크기를 읽는다. 모니터를 뺐으면 주 화면으로 옮긴다.
    private func refreshHome() {
        guard let screen = NSScreen.screens.first(where: { Self.id(of: $0) == homeID }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        homeID = Self.id(of: screen)
        homeFrame = screen.frame
        homeArea = screen.visibleFrame
    }

    /// 점이 든 화면(없으면 가장 가까운 화면)을 살 곳으로 삼는다.
    private func moveHome(to point: CGPoint) {
        func distance(_ rect: NSRect) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
        }
        if let screen = NSScreen.screens.min(by: { distance($0.frame) < distance($1.frame) }) { homeID = Self.id(of: screen) }
        refreshHome()
    }
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

    /// 모서리를 도는 둥근 길의 반지름. 꺾이는 자리에서 펫이 제자리에서 홱 돌거나 몸이 화면 밖으로 삐져나가지 않게
    /// 모서리 조금 앞에서부터 안쪽으로 둥글게 돈다.
    private var cornerRadius: CGFloat { min(Stage.size.height * scale * 0.4, area.width / 4, area.height / 4) }

    /// 테두리 위 모서리 (테두리를 잰 자리, 꼭짓점, 들어오는 쪽, 나가는 쪽, 들어올 때 기울기). 0과 한 바퀴 끝은 같은 모서리다.
    private var corners: [(along: CGFloat, point: CGPoint, into: CGVector, out: CGVector, angle: CGFloat)] {
        let a = area
        return [(0, CGPoint(a.minX, a.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0), .pi / 2),
                (a.width, CGPoint(a.maxX, a.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), 0),
                (a.width + a.height, CGPoint(a.maxX, a.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0), -.pi / 2),
                (2 * a.width + a.height, CGPoint(a.minX, a.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1), .pi),
                (perimeter, CGPoint(a.minX, a.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0), .pi / 2)]
    }

    /// 모서리를 도는 중이면 얼마나 돌았는지 (0…1).
    private func cornerTurn(along p: CGFloat) -> CGFloat? {
        guard modeProvider() == .roam else { return nil }
        let r = cornerRadius
        guard r > 1, let corner = corners.first(where: { abs(p - $0.along) < r }) else { return nil }
        return (p - corner.along + r) / (2 * r)
    }

    /// 테두리 위 자리의 화면 좌표와 그 자리의 기울기. 모서리 근처에서는 꼭짓점 안쪽 사분원을 따라가며 기울기도 고르게 바뀐다.
    private func path(along p: CGFloat) -> (point: CGPoint, angle: CGFloat) {
        let r = cornerRadius
        if modeProvider() == .roam, r > 1, let c = corners.first(where: { abs(p - $0.along) < r }) {
            let t = (p - c.along + r) / (2 * r)
            let phi = t * .pi / 2
            let center = CGPoint(c.point.x + (c.out.dx - c.into.dx) * r, c.point.y + (c.out.dy - c.into.dy) * r)
            let point = CGPoint(center.x + r * (c.into.dx * sin(phi) - c.out.dx * cos(phi)),
                                center.y + r * (c.into.dy * sin(phi) - c.out.dy * cos(phi)))
            return (point, c.angle - t * .pi / 2)
        }
        return (point(along: p), Self.angle(for: edge(of: p)))
    }

    private var feetOnScreen: CGPoint {
        if var free {
            if modeProvider() == .pinned, drag == nil { free.y += lift }
            return free
        }
        var feet = path(along: along).point
        feet.y += edge == .bottom ? lift : 0
        return feet
    }

    // MARK: 동작

    private func play(_ kind: Trick) {
        // 머무는 펫도 자리(free)를 갖고 있어, 그때는 떨어지는 중이 아니라 서 있는 것이다
        guard lift == 0, drag == nil, free == nil || modeProvider() == .pinned else { return }
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
    func releaseKeysForCheck() { releaseKeyboard() }

    /// 눌렀다 뗐다 (끌지 않음). 동료 몸을 눌렀으면 동료가 뛰고, 아니면 펫을 쓰다듬는다. 둘 다 머리 위로 하트가 핀다.
    fileprivate func clicked(at point: CGPoint? = nil) {
        lastControl = Date()
        // 쉬는 동안은 프레임을 드물게 그려, 누른 즉시 반응하게 바로 올린다
        schedule(fps: 60)
        let clock = Date().timeIntervalSinceReferenceDate
        // 기운 펫의 몸 상자는 돌린 몸을 감싸 커서 곁의 동료를 덮기도 한다. 동료 상자 안이고 동료 쪽이 더 가까우면 동료다
        func distance(_ rect: CGRect) -> CGFloat { point.map { hypot($0.x - rect.midX, $0.y - rect.midY) } ?? .infinity }
        if let point, buddyOnScreen.insetBy(dx: -6, dy: -6).contains(point),
           !bodyOnScreen.contains(point) || distance(buddyOnScreen) < distance(bodyOnScreen) {
            if buddyHop == 0 { buddyHopSpeed = 330 }
            pats.append((clock, true))
            return
        }
        pats.append((clock, false))
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
        moveHome(to: free)
        onPin(free)
    }

    /// 오른쪽 클릭 옵션 창. 떠 있는 동안 펫은 멈추고, 다시 오른쪽 클릭하면 닫는다.
    fileprivate func showOptions() {
        let options = PetOptions.shared
        if options.isShown { return options.close() }
        menu(open: true)
        options.show(near: bodyOnScreen, mode: modeProvider(), size: sizeProvider(), keys: PetKeys.shared.label,
                     actions: .init(mode: { [weak self] in self?.choose($0) },
                                    size: { [weak self] in self?.chooseSize($0) },
                                    page: { [weak self] in self?.openPage($0) },
                                    report: { DailyReportBubble.showOrExplain($0) },
                                    putBack: { [weak self] in self?.hide() },
                                    closed: { [weak self] in self?.menu(open: false) }))
    }

    /// 옵션 창이 뜨고 닫힐 때. 닫힌 뒤에도 잠깐 멈춰 고른 결과(크기, 움직임)를 보게 한다.
    fileprivate func menu(open: Bool) {
        menuOpen = open
        trick = nil
        lastControl = Date()
        if !open { hoverEnded = Date() }
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
        if now.timeIntervalSince(homeReadAt) >= 1 {
            homeReadAt = now
            refreshHome()
        }
        // 전역 단축키는 보조키를 먼저 떼면 놓임 알림이 안 올 수 있어 실제 키 상태로 한 번 더 본다
        if held.left || held.right || held.up || held.down, !panelHasKeys {
            held.left = held.left && PetKeys.isDown(123)
            held.right = held.right && PetKeys.isDown(124)
            held.down = held.down && PetKeys.isDown(125)
            held.up = held.up && PetKeys.isDown(126)
        }
        let display = displayProvider()
        let a = area
        var velocity: CGFloat = 0   // 테두리를 따라 (반시계 +)
        if let drag {
            let target = CGPoint(drag.point.x - drag.grab.width, drag.point.y - drag.grab.height)
            let current = free ?? target
            velocity = (target.x - current.x) / max(dt, 0.001)
            // 끄는 동안에는 손 밑 화면의 Dock 아래로만 내려가지 않게 한다
            let floor = NSScreen.screens.first { $0.frame.contains(target) }?.visibleFrame.minY ?? -.greatestFiniteMagnitude
            free = CGPoint(current.x + (target.x - current.x) * min(1, dt * 20),
                           max(floor, current.y + (target.y - current.y) * min(1, dt * 20)))
        } else if var spot = free, modeProvider() == .pinned {
            // 머무는 자리: 방향키로 조금씩 옮기고, 스페이스로 그 자리에서 뛴다
            let x: CGFloat = (held.right ? 1 : 0) - (held.left ? 1 : 0)
            let y: CGFloat = (held.up ? 1 : 0) - (held.down ? 1 : 0)
            if x != 0 || y != 0 {
                spot.x = min(max(spot.x + x * 150 * dt, a.minX + edgeMargin), a.maxX - edgeMargin)
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
            falling.x = min(max(falling.x, a.minX + edgeMargin), a.maxX - edgeMargin)
            if falling.y <= a.minY {
                free = nil
                along = falling.x - a.minX
                if dropHeight > 30 {
                    liftSpeed = min(dropHeight * 2.2, 420)
                    lift = 0.01
                }
                if dropHeight > 150 {
                    perform(.dizzy)
                    // 높이서 쿵 내려앉으면 고른 부딪힘이 터진다. 게임 밖에서 그 효과를 보는 자리다
                    burst(at: CGPoint(falling.x, a.minY))
                }
                dropHeight = 0
            } else {
                free = falling
            }
        } else {
            let mode = modeProvider()
            // 누르고 있거나 커서가 가까이 있으면 멈춘다. 커서가 떠나도 잠깐은 기다려 다시 잡으려는 손을 피하지 않는다
            let waiting = pressing || hovering || menuOpen || now.timeIntervalSince(hoverEnded) < Self.hoverLinger
            velocity = pressing || menuOpen ? 0 : control(edge: edge) * 150
            if velocity == 0, !waiting, trick == nil, !resting, now.timeIntervalSince(lastControl) > 2 {
                // 직접 움직이지 않으면 상태 빠르기대로 테두리를 따라 걷는다
                velocity = heading * Self.walkSpeed(display)
            }
            if velocity != 0 { heading = velocity > 0 ? 1 : -1 }
            if !waiting { wander(now: now, display: display) }
            // 모서리 가운데서는 조금 늦춰 발을 디디며 도는 것처럼 보이게 한다
            if let turn = cornerTurn(along: along) { velocity *= 1 - 0.4 * sin(turn * .pi) }
            var next = along + velocity * dt
            if mode == .roam {
                next = next.truncatingRemainder(dividingBy: perimeter)
                if next < 0 { next += perimeter }
            } else if next < edgeMargin || next > a.width - edgeMargin {
                // 바닥에서만 걸을 때는 양끝에서 돌아선다
                next = min(max(next, edgeMargin), a.width - edgeMargin)
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
        }
        if let trick, now.timeIntervalSince(trick.start) >= trick.kind.duration { self.trick = nil }
        // 기울기를 짧은 쪽으로 부드럽게 맞춘다. 모서리에서는 둥근 길의 기울기를 따라가고, 떨어지는 동안은 바로 선다
        let target = free == nil ? path(along: along).angle : 0
        var diff = (target - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if diff > .pi { diff -= 2 * .pi }
        if diff < -.pi { diff += 2 * .pi }
        angle += diff * min(1, dt * 12)
        let moving = abs(velocity) > 8 && drag == nil && free == nil
        gait += moving ? dt * abs(velocity) / 110 : dt / CGFloat(display.cycle)
        speedNow = moving ? abs(velocity) : 0
        emitDust(moving: moving, buddyMoving: abs(buddyLag * 4) > 8 || buddyShift != 0 || moving,
                 clock: now.timeIntervalSinceReferenceDate)
        if buddyHop > 0 || buddyHopSpeed > 0 {
            buddyHopSpeed -= 1500 * dt
            buddyHop += buddyHopSpeed * dt
            if buddyHop <= 0 { buddyHop = 0; buddyHopSpeed = 0 }
        }
        // 동료는 펫이 보는 쪽 뒤에 선다. 펫이 돌아서면 순간이동하지 않고 반대편으로 달려가고,
        // 펫이 뛰면 조금 늦게 낮게 뛴다 (같이 붙어 떠오르면 매달린 것처럼 보인다). 끌거나 떨어질 때는 붙어 다닌다
        let follows = free == nil || (drag == nil && modeProvider() == .pinned)
        let side = follows ? heading : 1
        // 반대편까지(2) 약 0.3초에 고르게 달려간다
        let gap = side - buddySide
        buddyShift = gap == 0 ? 0 : (gap > 0 ? 6 : -6)
        buddySide += gap > 0 ? min(gap, 6 * dt) : max(gap, -6 * dt)
        buddyLift = follows ? buddyLift + (lift * 0.6 - buddyLift) * min(1, dt * 10) : lift
        // 펫이 걸으면 동료는 제자리에 남았다가 뒤따라 달려온다. 1초에 남은 거리의 4배씩 줄여 걸을 때 약 0.25초 늦게 따라온다
        if follows, drag == nil { buddyLag -= velocity * dt }
        buddyLag -= buddyLag * min(1, dt * 4)
        let room = 12 * scale
        buddyLag = min(max(buddyLag, -room), room)
        let catching = abs(buddyLag * 4) > 8
        buddyGait += dt * (moving || catching || buddyShift != 0 ? max(abs(velocity), 90) : 20) / 60
        place()
        view?.needsDisplay = true
        // 방향키를 4초 넘게 쓰지 않으면 키 입력을 돌려준다
        let holding = held.left || held.right || held.up || held.down
        if panelHasKeys, !holding, now.timeIntervalSince(lastControl) > 4, drag == nil { releaseKeyboard() }
        // 펫 몸 위에서만 클릭을 받고, 나머지는 뒤 창으로 지나가게 한다
        updateHover(now: now)
        panel?.ignoresMouseEvents = drag == nil && !pressing && !hovering && !menuOpen
        // 머무는 펫은 늘 자리(free)를 갖고 있어, 떨어지거나 끄는 중일 때만 바쁘게 그린다
        let floating = free != nil && !(drag == nil && modeProvider() == .pinned)
        let busy = drag != nil || floating || lift > 0 || hovering || held.left || held.right || held.up || held.down || trick != nil
            || moving || abs(diff) > 0.01 || !puffs.isEmpty || !pats.isEmpty || !trail.isEmpty || buddyHop > 0
            || now < showcaseUntil
        schedule(fps: busy ? 60 : AppSettings.shared.smoothness.fps)
    }

    /// 무대처럼 발을 디딜 때마다(한 주기에 두 번) 발먼지가 일고, 뛰거나 떨어졌다 내려오면 크게 인다. 동료가 내려와도 인다.
    private func emitDust(moving: Bool, buddyMoving: Bool, clock: Double) {
        let pinned = drag == nil && modeProvider() == .pinned
        let airborne = lift > 1 || (free != nil && !pinned)
        let step = Int(floor(gait * 2))
        defer {
            lastStep = step
            wasAirborne = airborne
            buddyWasUp = buddyHop > 1
        }
        // 발먼지를 고르지 않았으면 먼지를 일으키지 않는다. 걸음·착지 셈은 위 defer가 이어 간다
        guard let dust = GameDecor.shared.equipped(.dust) else {
            puffs.removeAll { clock - $0.born > Double($0.spray.life) + 0.1 }
            return
        }
        if drag == nil, free == nil || pinned {
            let ground = free ?? path(along: along).point
            let tilt = free == nil ? angle : 0
            if wasAirborne && !airborne {
                puffs.append((GameFX.dust(dust, landing: true), ground, clock, tilt, 1.6))
            } else if !airborne, moving, step != lastStep {
                puffs.append((GameFX.dust(dust, landing: false), ground, clock, tilt, 1.2))
            }
        }
        if let ground = buddyGround {
            // 동료도 같은 발먼지를 일으킨다. 몸이 작아 조금 작게
            let step = Int(floor(buddyGait * 2))
            if buddyWasUp, buddyHop <= 1 {
                puffs.append((GameFX.dust(dust, landing: true), ground, clock, free == nil ? angle : 0, 1.2))
            } else if buddyMoving, buddyHop <= 1, drag == nil, step != buddyStep {
                puffs.append((GameFX.dust(dust, landing: false), ground, clock, free == nil ? angle : 0, 0.9))
            }
            buddyStep = step
        }
        puffs.removeAll { clock - $0.born > Double($0.spray.life) + 0.1 }
        pats.removeAll { clock - $0.at > 1.6 }
    }

    /// 동료가 펫을 따라 할 자세. 펫이 손을 흔들면 조금 늦게 따라 흔들고, 지쳐 앉거나 시무룩하거나 자면 곁에서 같이 한다.
    /// 따라잡느라 달리는 중이면 달리기를 먼저 한다.
    static func gesture(following pet: CharacterPose, moving: Bool, phase: CGFloat) -> CharacterPose? {
        guard !moving else { return nil }
        if let wave = pet.wave {
            var pose = CharacterPose(activity: .stand, phase: phase)
            pose.wave = max(0, wave - 0.25)
            return pose
        }
        switch pet.activity {
        case .sit:
            var pose = CharacterPose(activity: .sit, phase: pet.phase, eyes: pet.eyes)
            pose.sad = pet.sad
            return pose
        case .sleep:
            return CharacterPose(activity: .sleep, phase: pet.phase, eyes: .closed)
        default:
            return pet.review.map { review in
                var pose = CharacterPose(activity: .stand, phase: phase)
                pose.review = review
                return pose
            }
        }
    }

    /// 꾸미기를 바꾸면 바로 보여 준다. 발먼지는 폴짝 뛰어 일으키고, 부딪힘은 그 자리에서 터지고,
    /// 주변 효과는 늘 보이니 손을 흔들어 알린다. 동료를 바꾸면 펫이 반긴다.
    private func showcase(_ equipped: Set<Cosmetic>) {
        let added = equipped.subtracting(wearing)
        wearing = equipped
        lastControl = Date()
        schedule(fps: 60)
        if added.isEmpty {
            perform(.greet)
            return
        }
        for item in added {
            switch item.slot {
            case .trail: showcaseUntil = Date().addingTimeInterval(1.4)
            case .aura: perform(.greet)
            case .dust:
                if lift == 0, drag == nil, free == nil || modeProvider() == .pinned { jump() }
            case .crash: burst(at: free ?? path(along: along).point, lifted: bodyOnScreen.height / 2)
            case .track: break
            }
        }
    }

    /// 고른 부딪힘을 화면의 그 자리에서 터뜨린다. 고르지 않았으면 아무것도 하지 않는다.
    private func burst(at ground: CGPoint, lifted: CGFloat = 0) {
        guard let item = GameDecor.shared.equipped(.crash) else { return }
        let clock = Date().timeIntervalSinceReferenceDate
        let inward = CGVector(dx: sin(free == nil ? angle : 0), dy: cos(free == nil ? angle : 0))
        let at = CGPoint(ground.x + inward.dx * lifted, ground.y + inward.dy * lifted)
        for part in GameFX.crash(item) {
            puffs.append((part.spray, CGPoint(at.x + part.offset.x, at.y - part.offset.y), clock, free == nil ? angle : 0, 1))
        }
    }

    /// 화면 좌표를 창 안 좌표(y 아래로)로.
    private func inPanel(_ point: CGPoint) -> CGPoint {
        guard let panel else { return point }
        return CGPoint(point.x - panel.frame.minX, panel.frame.maxY - point.y)
    }

    /// 머리 위로 피어오르는 하트 세 개 (무대와 같은 그림). `up`은 창 안 좌표의 위쪽.
    private func drawHearts(from top: CGPoint, up: CGVector, age: CGFloat, seed: Int, clock: Double, _ cg: CGContext) {
        let zoom = effectZoom
        let side = CGVector(dx: -up.dy, dy: up.dx)
        for k in 0..<3 {
            let life = age - CGFloat(k) * 0.14
            guard life > 0, life < 1.2 else { continue }
            let rise = life / 1.2
            let sway = (CGFloat((seed * 3 + k) % 5) - 2) * 7 + sin(life * 7 + CGFloat(k)) * 4
            let distance = (8 + rise * 46) * zoom
            let at = CGPoint(top.x + up.dx * distance + side.dx * sway * zoom, top.y + up.dy * distance + side.dy * sway * zoom)
            GameFX.drawSprite("pumpingHeart", at: at, height: (9 + CGFloat(k) * 2) * min(1, life / 0.18) * zoom, progress: 0,
                              time: clock + Double(k) * 0.2, alpha: 1 - rise * rise, cg)
        }
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
        let pointer = pointerForCheck ?? NSEvent.mouseLocation
        // 동료도 누를 수 있어 동료 둘레에서도 멈추고 클릭을 받는다
        let near = bodyOnScreen.insetBy(dx: -Self.reach, dy: -Self.reach).contains(pointer)
            || (!buddyOnScreen.isEmpty && buddyOnScreen.insetBy(dx: -8, dy: -8).contains(pointer))
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
    /// 끄는 중이 아니면 창을 사는 화면 안으로 잘라 옆 모니터에 걸치지 않게 한다. 걸치면 펫이 양쪽에 나뉘어 보인다.
    private func place() {
        guard let panel else { return }
        let feet = feetOnScreen
        let offset = feetOffset
        let ideal = NSRect(x: (feet.x - offset.x - side / 2).rounded(), y: (feet.y + offset.y - side / 2).rounded(),
                           width: side, height: side)
        var frame = ideal
        if drag == nil {
            let inside = ideal.intersection(homeFrame)
            if !inside.isNull, inside.width >= 1, inside.height >= 1 { frame = inside }
        }
        drawCenter = CGPoint(ideal.midX - frame.minX, frame.maxY - ideal.midY)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    private var panelHasKeys: Bool { panel?.isKeyWindow == true }

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
        let center = drawCenter
        let clock = now.timeIntervalSinceReferenceDate
        let zoom = effectZoom
        // 돌린 좌표에서 발은 가운데 아래
        let feet = CGPoint(0, Stage.size.height * scale / 2)
        let origin = CGPoint(feet.x - Stage.size.width / 2 * scale, feet.y - Stage.ground * scale)
        let scene = CharacterScene(rig: character.rig, pose: frame.pose, transform: frame.transform)
        let body = scene.placedBounds
        /// 돌린 좌표의 점을 창 안 좌표로.
        let toView = { (p: CGPoint) in p.applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: self.angle)) }

        // 꼬리: 등 자리를 화면 좌표로 남겨 두고, 걸어온 길을 따라 끌리게 그린다
        let facing: CGFloat = frame.transform.scaleX < 0 ? -1 : 1
        let backLocal = CGPoint(origin.x + (facing > 0 ? body.minX + body.width * 0.18 : body.maxX - body.width * 0.18) * scale,
                                origin.y + (body.midY + body.height * 0.08) * scale)
        let showing = now < showcaseUntil
        if let item = GameDecor.shared.equipped(.trail), let panel {
            if speedNow > 12 || showing {
                // 막 단 꼬리는 걷지 않아도 몸 둘레를 한 바퀴 휘감아 보인다
                let view: CGPoint
                if showing {
                    let middle = toView(CGPoint(origin.x + body.midX * scale, origin.y + body.midY * scale))
                    let radius = max(body.width, body.height) * scale * 0.65, turn = CGFloat(clock * 7)
                    view = CGPoint(middle.x + cos(turn) * radius, middle.y + sin(turn) * radius)
                } else {
                    view = toView(backLocal)
                }
                let back = CGPoint(panel.frame.minX + view.x, panel.frame.maxY - view.y)
                trail.append(back)
                trail.removeAll { hypot($0.x - back.x, $0.y - back.y) > 150 * zoom }
                if trail.count > 40 { trail.removeFirst(trail.count - 40) }
            } else if !trail.isEmpty {
                trail.removeFirst()
            }
            // 멈춘 뒤에도 남은 꼬리는 줄어드는 동안 그린다. 다 줄어들면 서 있는 동안 등 뒤에서 살랑이는 꼬리를 그려,
            // 걷지 않는 머무는 펫에서도 고른 꼬리가 늘 보인다 (꾸미기 칸 미리보기와 같은 모양)
            let points: [CGPoint]
            if trail.isEmpty, !showing, drag == nil {
                points = (0..<18).map { i -> CGPoint in
                    let back = CGFloat(17 - i)
                    let local = CGPoint(backLocal.x - facing * back * 3.4 * zoom,
                                        backLocal.y + CGFloat(sin(clock * 3 - Double(i) * 0.35)) * back * 0.35 * zoom)
                    return toView(local)
                }
            } else {
                points = trail.map(inPanel)
            }
            cg.saveGState()
            cg.scaleBy(x: zoom, y: zoom)
            GameFX.drawTrail(item, points: points.map { CGPoint($0.x / zoom, $0.y / zoom) }, time: clock, cg)
            cg.restoreGState()
        } else if !trail.isEmpty {
            trail.removeAll()
        }
        // 발먼지: 난 자리의 기울기대로 돌려 벽·천장에서도 바닥 쪽에서 일어 화면 안쪽으로 퍼진다
        for puff in puffs {
            let at = inPanel(puff.at)
            cg.saveGState()
            cg.translateBy(x: at.x, y: at.y)
            cg.rotate(by: puff.angle)
            cg.scaleBy(x: puff.zoom * zoom, y: puff.zoom * zoom)
            GameFX.drawSpray(puff.spray, from: .zero, age: CGFloat(clock - puff.born), time: clock, cg)
            cg.restoreGState()
        }

        // 발밑 그림자: 무대처럼 땅에 붙어 있게 보이고, 뛰면 작고 옅어진다. 떨어지거나 들려 있을 때는 그리지 않는다
        if free == nil || (drag == nil && modeProvider() == .pinned) {
            let ground = inPanel(free ?? path(along: along).point)
            let shrink = max(0.4, 1 - lift / 120)
            let width = body.width * scale * 0.7 * shrink
            cg.saveGState()
            cg.translateBy(x: ground.x, y: ground.y)
            cg.rotate(by: free == nil ? angle : 0)
            cg.setFillColor(NSColor.black.withAlphaComponent(0.22 * shrink).cgColor)
            cg.fillEllipse(in: CGRect(x: -width / 2, y: -2 * zoom, width: width, height: 4 * zoom))
            cg.restoreGState()
        }
        // 데려간 동료는 몸 바로 뒤에서 따라 걷는다. 무대 폭이 아니라 몸 폭으로 재야 캐릭터와 붙어 보인다
        let companion = companionProvider()
        let buddyHeight = 10 * scale
        let buddyOffset = origin.x + (body.midX - buddySide * (body.width / 2 + 5)) * scale + buddyLag
        // 반대편으로 달려가는 동안은 가는 쪽을, 아니면 펫과 같은 쪽을 본다
        let buddyFacing: CGFloat = buddyShift != 0 ? (buddyShift > 0 ? -1 : 1) : (buddySide >= 0 ? 1 : -1)
        let buddyMoving = buddyShift != 0 || abs(buddyLag * 4) > 8 || (Self.walkSpeed(display) > 0 && !resting) || held.left || held.right
        let rise = buddyLift + buddyHop
        let buddyJump: CGFloat? = rise > 2 ? (buddyHopSpeed > 0 || lift * 0.6 > buddyLift ? 0.3 : 0.7) : nil
        // 펫은 장난하는 동안 멈춰 있어, 동료가 따라잡는 중이거나 펫이 실제로 움직일 때만 따라 하지 않는다
        let busyBuddy = buddyShift != 0 || abs(buddyLag * 4) > 8 || speedNow > 0 || held.left || held.right
        let buddyGesture = buddyJump == nil ? Self.gesture(following: frame.pose, moving: busyBuddy, phase: buddyGait) : nil
        var buddyInFrame = false
        if let companion, free == nil {
            // 테두리 위에서는 동료도 둥근 길을 따라 선다. 펫 몸 축으로 곧게 두면 모서리에서 화면 밖으로 떠 보인다
            var p = along + buddyOffset
            if modeProvider() == .roam {
                p = p.truncatingRemainder(dividingBy: perimeter)
                if p < 0 { p += perimeter }
            } else {
                p = min(max(p, 0), area.width)
            }
            let spot = path(along: p)
            // 화면 안쪽 (화면 좌표, 위로 +)
            let inward = CGVector(dx: sin(spot.angle), dy: cos(spot.angle))
            let ground = spot.point
            let feetOnScreen = CGPoint(ground.x + inward.dx * rise, ground.y + inward.dy * rise)
            let at = inPanel(feetOnScreen)
            cg.saveGState()
            cg.translateBy(x: at.x, y: at.y)
            cg.rotate(by: spot.angle)
            GameFX.drawCompanion(companion, feet: .zero, height: buddyHeight, phase: buddyGait, moving: buddyMoving,
                                 jump: buddyJump, facing: buddyFacing, theme: themeProvider(), gesture: buddyGesture, cg)
            cg.restoreGState()
            buddyGround = ground
            let middle = CGPoint(feetOnScreen.x + inward.dx * buddyHeight / 2, feetOnScreen.y + inward.dy * buddyHeight / 2)
            buddyOnScreen = CGRect(x: middle.x - buddyHeight / 2, y: middle.y - buddyHeight / 2, width: buddyHeight, height: buddyHeight)
        } else if companion != nil {
            buddyInFrame = true
        } else {
            buddyOnScreen = .zero
            buddyGround = nil
        }

        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: angle)
        // 들려 있거나 머무는 펫은 바로 서 있어, 동료도 펫 좌표에서 곁에 붙여 그린다
        if buddyInFrame, let companion, let panel {
            let height = max(lift - buddyLift, 0) - buddyHop
            let local = CGPoint(buddyOffset, feet.y + height)
            GameFX.drawCompanion(companion, feet: local, height: buddyHeight, phase: buddyGait, moving: buddyMoving,
                                 jump: buddyJump, facing: buddyFacing, theme: themeProvider(), gesture: buddyGesture, cg)
            let view = toView(local)
            let onScreen = CGPoint(panel.frame.minX + view.x, panel.frame.maxY - view.y)
            buddyGround = drag == nil ? CGPoint(onScreen.x, onScreen.y - buddyHop) : nil
            buddyOnScreen = CGRect(x: onScreen.x - buddyHeight / 2, y: onScreen.y, width: buddyHeight, height: buddyHeight)
        }
        // 주변 효과는 펫 좌표에서 그려 벽·천장에서도 몸을 따라 돈다. 뒤로 지나가는 것은 몸 뒤, 앞으로 오는 것은 몸 앞에
        let aura = GameDecor.shared.equipped(.aura)
        let auraBody = CGRect(x: origin.x + body.minX * scale, y: origin.y + body.minY * scale,
                              width: body.width * scale, height: body.height * scale)
        if let aura { GameFX.drawAura(aura, around: auraBody, time: clock, front: false, size: auraBody.height * 0.2, cg) }
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
        if let aura { GameFX.drawAura(aura, around: auraBody, time: clock, front: true, size: auraBody.height * 0.2, cg) }
        cg.restoreGState()
        // 몸 자리를 화면 좌표로 남겨 클릭을 가린다 (돌린 사각형을 감싸는 사각형)
        let local = CGRect(x: origin.x + body.minX * scale, y: origin.y + body.minY * scale,
                           width: body.width * scale, height: body.height * scale)
        let inView = local.applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
        if let panel {
            bodyOnScreen = CGRect(x: panel.frame.minX + inView.minX, y: panel.frame.maxY - inView.maxY,
                                  width: inView.width, height: inView.height)
        }
        // 쓰다듬은 하트는 머리 쪽(화면 안쪽)으로 피어오른다
        let up = CGVector(dx: sin(angle), dy: -cos(angle))
        for (n, pat) in pats.enumerated() {
            let age = CGFloat(clock - pat.at)
            if pat.buddy {
                let top = inPanel(CGPoint(buddyOnScreen.midX, buddyOnScreen.midY))
                drawHearts(from: CGPoint(top.x + up.dx * buddyHeight / 2, top.y + up.dy * buddyHeight / 2), up: up, age: age, seed: n,
                           clock: clock, cg)
            } else {
                let middle = CGPoint(inView.midX, inView.midY), half = body.height * scale / 2
                drawHearts(from: CGPoint(middle.x + up.dx * half, middle.y + up.dy * half), up: up, age: age, seed: n, clock: clock, cg)
            }
        }
        hintOnScreen = nil
        // 누른 뒤 방향키를 받는 동안에는 머리 바로 위에 조작법을 띄운다. 창은 펫보다 훨씬 커서 창 위쪽에 두면 펫과 떨어져 보인다.
        // 위에 자리가 없으면(천장, 화면 위 끝) 발 아래에 둔다
        if panel?.isKeyWindow == true {
            let text = NSAttributedString(string: "방향키로 움직이기 · 스페이스로 뛰기", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let width = text.size().width + 16, height: CGFloat = 20
            let x = min(max(inView.midX - width / 2, 2), size.width - width - 2)
            let y = inView.minY - height - 6 >= 2 ? inView.minY - height - 6 : min(inView.maxY + 6, size.height - height - 2)
            let box = CGRect(x: x, y: y, width: width, height: height)
            if let panel {
                hintOnScreen = CGRect(x: panel.frame.minX + box.minX, y: panel.frame.maxY - box.maxY, width: width, height: height)
            }
            NSGraphicsContext.saveGraphicsState()
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            text.draw(at: CGPoint(box.minX + 8, box.minY + 3))
            NSGraphicsContext.restoreGraphicsState()
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
        if moved { pet?.endDrag() } else { pet?.clicked(at: screenPoint(event)) }
        down = nil
        moved = false
    }

    override func rightMouseDown(with event: NSEvent) { pet?.showOptions() }

    // 받지 않는 키는 경고음을 내지 않고 키 입력을 돌려준다
    override func keyDown(with event: NSEvent) {
        if pet?.key(event.keyCode, down: true, repeated: event.isARepeat) != true { pet?.releaseKeyboard() }
    }

    override func keyUp(with event: NSEvent) {
        _ = pet?.key(event.keyCode, down: false, repeated: false)
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
        var worn: Set<Cosmetic> = []
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
        // 합성 키로는 Carbon 단축키가 발동하지 않아, 처리기에 눌림·놓임 이벤트를 직접 넣는다
        func hotKey(down: Bool) {
            var event: EventRef?
            CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(down ? kEventHotKeyPressed : kEventHotKeyReleased), 0, 0, &event)
            guard let event else { return }
            var id = EventHotKeyID(signature: PetKeys.checkSignature, id: 123)
            SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              MemoryLayout<EventHotKeyID>.size, &id)
            SendEventToEventTarget(event, GetApplicationEventTarget())
            ReleaseEvent(event)
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
        // RUNTIME_PET_SHEET에 --petdex-extract로 자른 폴더를 주면 그 그림 펫으로 본다 (왼쪽 달리기 줄 점검)
        if let folder = ProcessInfo.processInfo.environment["RUNTIME_PET_SHEET"], let rig = SheetRig(folder: URL(fileURLWithPath: folder)) {
            let character = RunnerCharacter(key: "sheet:" + folder, name: "시트", sound: "시트", rig: FittedRig(rig), fixedTheme: .natural)
            pet.characterProvider = { character }
        }
        pet.show()
        PetKeys.assumesDown = true
        var start = pet.position
        let steps: [(Double, () -> Void)] = [
            (1.5, {
                check("떨어져 내려와 바닥에 선다", pet.position.lift == 0 && pet.edgeName == "bottom")
                start = pet.position
            }),
            (1.0, {
                check("달리는 상태면 테두리를 따라 걷는다 (\(Int(abs(pet.position.x - start.x)))pt)", abs(pet.position.x - start.x) > 20)
                // 발먼지는 고른 것만 인다. 고르지 않았으면 먼지가 없어야 한다
                let chosen = GameDecor.shared.equipped(.dust) != nil
                check("걸으면 고른 발먼지만 인다 (\(chosen ? "고름" : "고르지 않음"), \(pet.effectsForCheck.puffs)개)",
                      chosen ? pet.effectsForCheck.puffs > 0 : pet.effectsForCheck.puffs == 0)
            }),
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
            (2.5, { check("커서가 떠나면 다시 걷는다 (\(Int(abs(pet.position.x - start.x)))pt)", abs(pet.position.x - start.x) > 20) }),
            (0.1, {
                display = .normal(.sleeping)
                pet.takeKeyboardForCheck()
                _ = pet.key(123, down: true, repeated: false)
            }),
            (0.8, {
                pet.snapshot(to: file.deletingPathExtension().appendingPathExtension("walk-left.png"))
                _ = pet.key(123, down: false, repeated: false)
                check("←를 누르면 왼쪽으로 걷는다", pet.position.facing < 0)
                check("동료도 돌아서 펫 뒤(오른쪽)로 간다 (\(String(format: "%.2f", pet.buddyForCheck.side)))", pet.buddyForCheck.side == -1)
                check("걷는 동안 동료가 조금 늦게 따라온다 (\(Int(pet.buddyForCheck.lag))pt 뒤)", pet.buddyForCheck.lag > 5)
                _ = pet.key(49, down: true, repeated: false)
            }),
            (0.15, {
                check("스페이스로 뛴다 (높이 \(Int(pet.position.lift)))", pet.position.lift > 10)
                check("동료는 펫보다 낮게 뛴다 (\(Int(pet.buddyForCheck.lift))pt)", pet.buddyForCheck.lift < pet.position.lift)
                pet.snapshot(to: file.deletingPathExtension().appendingPathExtension("jump.png"))
            }),
            (1.0, {
                // 펫 창이 키를 쥐지 않은 채 시스템에 ⌃⌥←를 보낸다. 어느 앱이 앞에 있든 펫이 움직여야 한다
                pet.releaseKeysForCheck()
                check("전역 단축키를 잡는다 (\(PetKeys.shared.label ?? "없음"))", PetKeys.shared.label != nil && !pet.hasKeyboard)
                start = pet.position
                hotKey(down: true)
            }),
            (0.6, {
                check("단축키 눌림이 오면 펫 창 없이도 걷는다 (\(Int(start.x - pet.position.x))pt)", start.x - pet.position.x > 30)
                hotKey(down: false)
            }),
            (0.3, { start = pet.position }),
            (0.5, { check("단축키를 놓으면 멈춘다", abs(pet.position.x - start.x) < 1) }),
            (1.0, {
                check("뛰고 나면 내린다", pet.position.lift == 0)
                // 바닥 오른쪽 끝 바로 앞에서 오른쪽으로 걸으면 오른쪽 벽을 탄다
                display = .normal(.dashing)
                pet.place(along: pet.homeArea.width - 40, heading: 1)
            }),
            (1.5, {
                check("바닥 끝에서 오른쪽 벽으로 올라간다 (\(pet.edgeName))", pet.edgeName == "right")
                check("벽을 걸어도 창이 옆 모니터로 넘어가지 않는다", pet.homeFrame.contains(pet.panelFrame))
                capture("wall")
                // 천장 바로 앞으로 옮겨 천장을 걷는 모습도 찍는다
                pet.place(along: pet.homeArea.width + pet.homeArea.height - 30, heading: 1)
            }),
            (1.2, {
                check("벽 끝에서 천장으로 넘어간다 (\(pet.edgeName))", pet.edgeName == "top")
                capture("top")
                display = .normal(.sleeping)
                _ = pet.key(49, down: true, repeated: false)
            }),
            // 천장에서 떨어지면 바닥까지 멀어 튀고 멈출 때까지 넉넉히 기다린다
            (3.0, { check("천장에서 스페이스를 누르면 바닥으로 떨어진다 (\(pet.edgeName), 높이 \(Int(pet.position.lift)))", pet.edgeName == "bottom" && pet.position.lift == 0) }),
            (0.1, {
                // 모서리 한가운데에 세워 둥근 길을 따라 비스듬히 서는지 본다
                display = .normal(.sleeping)
                pet.place(along: pet.homeArea.width, heading: 1)
            }),
            (0.6, {
                let feet = pet.feetForCheck, area = pet.homeArea
                check("모서리는 안쪽으로 둥글게 돌며 비스듬히 선다 (기울기 \(Int((pet.tiltForCheck * 180 / .pi).rounded()))도)",
                      feet.x < area.maxX - 5 && feet.y > area.minY + 5 && abs(pet.tiltForCheck + .pi / 4) < 0.1)
                capture("corner")
                let ground = pet.effectsForCheck.buddyGround ?? CGPoint(-1, -1)
                check("모서리에서도 동료가 화면 안 길 위에 선다 (발 \(Int(ground.x - area.maxX)), \(Int(ground.y - area.minY)))",
                      ground.x <= area.maxX + 1 && ground.y >= area.minY - 1 && ground.x >= area.minX)
                // 동료를 누르면 뛰고 하트가 핀다
                let buddy = pet.effectsForCheck.buddyBox
                let tap = CGPoint(buddy.midX, buddy.midY)
                pet.pointerForCheck = tap
                mouse(.leftMouseDown, at: tap)
                mouse(.leftMouseUp, at: tap)
            }),
            (0.12, {
                check("동료를 누르면 뛰고 하트가 핀다 (\(Int(pet.effectsForCheck.buddyHop)), 하트 \(pet.effectsForCheck.pats))",
                      pet.effectsForCheck.buddyHop > 5 && pet.effectsForCheck.pats == 1)
                let body = pet.bodyCenter
                pet.pointerForCheck = body
                mouse(.leftMouseDown, at: body)
                mouse(.leftMouseUp, at: body)
                check("펫을 누르면 쓰다듬고 하트가 핀다 (하트 \(pet.effectsForCheck.pats))", pet.effectsForCheck.pats == 2)
                // 동료는 펫을 따라 손 흔들고, 지쳐 앉고, 시무룩하고, 잔다. 따라잡느라 달리는 중이면 달리기를 먼저 한다
                var waving = CharacterPose(activity: .stand, phase: 0)
                waving.wave = 1.5
                var down = CharacterPose(activity: .sit, phase: 0, eyes: .closed)
                down.sad = true
                let follows = DesktopPet.gesture(following: waving, moving: false, phase: 0)?.wave != nil
                    && DesktopPet.gesture(following: down, moving: false, phase: 0).map { $0.activity == .sit && $0.sad } == true
                    && DesktopPet.gesture(following: CharacterPose(activity: .sleep, phase: 0), moving: false, phase: 0)?.activity == .sleep
                    && DesktopPet.gesture(following: waving, moving: true, phase: 0) == nil
                check("동료가 펫의 손 흔들기·앉기·시무룩·잠을 따라 한다", follows)
            }),
            (0.3, {
                pet.snapshot(to: file.deletingPathExtension().appendingPathExtension("hearts.png"))
                pet.pointerForCheck = nil
                pet.menu(open: true)
                display = .normal(.dashing)
                pet.place(along: 300, heading: 1)
                start = pet.position
            }),
            (0.6, {
                check("오른쪽 클릭 메뉴가 떠 있는 동안은 걷지 않는다 (\(Int(abs(pet.position.x - start.x)))pt)",
                      abs(pet.position.x - start.x) < 1 && pet.takesClicks)
                pet.menu(open: false)
                // 오른쪽 클릭: 펫 옆에 옵션 창이 뜨고, 떠 있는 동안 멈추고, 움직임을 고르면 닫히지 않고 바로 바뀐다
                display = .normal(.dashing)
                pet.showOptions()
                start = pet.position
            }),
            (0.6, {
                let options = PetOptions.shared.frame ?? .zero, body = pet.bodyFrame ?? .zero
                check("오른쪽 클릭하면 펫 옆에 옵션 창이 뜬다 (\(Int(options.width))×\(Int(options.height)), 몸과 \(Int(min(abs(options.minX - body.maxX), abs(body.minX - options.maxX))))pt)",
                      PetOptions.shared.isShown && min(abs(options.minX - body.maxX), abs(body.minX - options.maxX)) < 20
                        && options.minY <= body.midY && options.maxY >= body.midY)
                check("옵션 창이 떠 있는 동안 펫은 걷지 않는다 (\(Int(abs(pet.position.x - start.x)))pt)", abs(pet.position.x - start.x) < 1)
                pet.optionsForCheck(.floor)
                check("옵션 창에서 움직임을 고르면 바로 바뀌고 창은 남는다", mode == .floor && PetOptions.shared.isShown
                      && PetOptions.shared.model?.mode == .floor)
                capture("options")
                PetOptions.shared.snapshot(to: file.deletingPathExtension().appendingPathExtension("options.png"))
                pet.showOptions()
                check("다시 오른쪽 클릭하면 옵션 창이 닫힌다", !PetOptions.shared.isShown)
                mode = .roam
                // 열어 볼 곳이 없는 안내는 때가 되면 저절로 닫히고, 할 일이 남은 소식은 남는다
                MenuBarBubble.shared.show(.init(title: "호스트", items: ["‘개발’ 묶음을 켰습니다"], keeps: false, closesAfter: 0.5),
                                          at: { pet.bubbleTarget.map { ($0, true) } })
                MenuBarBubble.shared.show(.init(title: "세션 사용량 95%", items: ["곧 한도에 닿습니다"]),
                                          at: { pet.bubbleTarget.map { ($0, true) } })
            }),
            (1.2, {
                check("안내 말풍선은 저절로 닫히고 남은 소식이 보인다 (\(MenuBarBubble.shared.pending)건, \(MenuBarBubble.shared.currentTitle ?? "없음"))",
                      MenuBarBubble.shared.pending == 1 && MenuBarBubble.shared.currentTitle == "세션 사용량 95%")
                MenuBarBubble.shared.hide()
            }),
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
                let target = NSScreen.screens.first { $0.frame != pet.homeFrame } ?? NSScreen.main
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
                _ = pet.key(124, down: true, repeated: false)
            }),
            (0.6, {
                _ = pet.key(124, down: false, repeated: false)
                check("한 자리에 머물 때 →로 돌면 동료도 왼쪽 뒤로 간다 (\(String(format: "%.2f", pet.buddyForCheck.side)))",
                      pet.buddyForCheck.side == 1)
                _ = pet.key(123, down: true, repeated: false)
            }),
            (0.6, {
                _ = pet.key(123, down: false, repeated: false)
                check("한 자리에 머물 때 ←로 돌면 동료도 오른쪽 뒤로 간다 (\(String(format: "%.2f", pet.buddyForCheck.side)))",
                      pet.buddyForCheck.side == -1)
                pet.snapshot(to: file.deletingPathExtension().appendingPathExtension("pinned-left.png"))
                pet.playForCheck(.greet)
                check("한 자리에 머무는 펫도 누르거나 소식이 오면 반응한다", pet.playingForCheck)
                // 머무는 펫은 걷지 않아 꼬리·발먼지가 생기지 않는다. 꾸미기를 바꾸면 바로 보여 줘야 한다
                worn = GameDecor.shared.equipped
                GameDecor.shared.choose(.heartTrail)
                if GameDecor.shared.equipped(.dust) == nil { GameDecor.shared.choose(.heartDust) }
                GameDecor.shared.choose(.starburstCrash)
                GameDecor.shared.choose(.butterflyAura)
            }),
            (0.4, {
                let effects = pet.effectsForCheck
                check("꾸미기를 바꾸면 머무는 펫에도 바로 보인다 (꼬리 \(effects.trail), 효과 \(effects.puffs))",
                      effects.trail > 3 && effects.puffs > 0)
                pet.snapshot(to: file.deletingPathExtension().appendingPathExtension("showcase.png"))
                let body = pet.bodyFrame ?? .zero, panel = pet.panelFrame
                check("펫 창이 꼬리·하트·동료가 들어가게 넉넉하다 (창 \(Int(panel.width)), 몸 \(Int(body.width)))",
                      panel.width >= body.width * 3 || panel.height >= body.height * 3)
            }),
            (1.6, {
                // 보여 주기가 끝난 뒤에도 서 있는 펫 등 뒤에 꼬리가, 몸 둘레에 주변 효과가 남는다
                pet.snapshot(to: file.deletingPathExtension().appendingPathExtension("idle-decor.png"))
                check("꼬리·주변 효과는 머무는 펫에 늘 남는다", GameDecor.shared.equipped(.trail) == .heartTrail
                      && GameDecor.shared.equipped(.aura) == .butterflyAura && pet.isShown)
                GameDecor.shared.equipped.subtracting(worn).forEach { GameDecor.shared.choose($0) }
                worn.subtracting(GameDecor.shared.equipped).forEach { GameDecor.shared.choose($0) }
            }),
            (0.2, {
                mode = .roam
                pet.takeKeyboardForCheck()
                check("누르면 방향키를 받는다", pet.hasKeyboard)
            }),
            (0.3, {
                // 조작 안내가 머리 바로 위에 붙는지 눈으로 본다
                pet.snapshot(to: file.deletingPathExtension().appendingPathExtension("keys.png"))
                MenuBarBubble.shared.show(.init(title: "호스트", items: ["‘개발’ 묶음을 켰습니다"]),
                                          at: { pet.bubbleTarget.map { ($0, true) } })
            }),
            (0.2, {
                let bubble = MenuBarBubble.shared.frame ?? .zero, body = pet.bodyFrame ?? .zero, target = pet.bubbleTarget ?? .zero
                check("조작 안내가 떠 있으면 말풍선이 안내 위로 비켜 뜬다 (몸에서 \(Int(bubble.minY - body.maxY))pt)",
                      target.maxY > body.maxY + 10 && bubble.minY >= target.maxY)
                capture("bubble-over-hint")
                MenuBarBubble.shared.hide()
            }),
            (3.8, {
                check("4초 동안 방향키를 쓰지 않으면 키 입력을 돌려준다", !pet.hasKeyboard)
                mode = .pinned
                let anchor = { pet.bubbleTarget.map { ($0, true) } }
                MenuBarBubble.shared.show(.init(title: "레드마인 새 일감 2건", items: ["#101 로그인 화면 수정", "#102 목록 정렬"],
                                                actionTitle: "열기", action: {}), at: anchor)
                MenuBarBubble.shared.show(.init(title: "호스트", items: ["‘개발’ 묶음을 켰습니다"]), at: anchor)
                MenuBarBubble.shared.show(.init(title: "호스트", items: ["‘개발’ 묶음을 켰습니다"]), at: anchor)
                check("같은 소식은 겹쳐 쌓지 않고 줄을 세운다 (\(MenuBarBubble.shared.pending)건)", MenuBarBubble.shared.pending == 2)
                MenuBarBubble.shared.turn(1)
                let second = MenuBarBubble.shared.currentTitle
                MenuBarBubble.shared.turn(1)
                check("앞뒤로 넘겨 보고 끝에서 처음으로 돈다", second == "호스트" && MenuBarBubble.shared.currentTitle == "레드마인 새 일감 2건")
            }),
            (16.0, {
                let bubble = MenuBarBubble.shared.frame ?? .zero, body = pet.bodyFrame ?? .zero
                check("말풍선이 펫 바로 위에 뜬다 (틈 \(Int(bubble.minY - body.maxY))pt)",
                      bubble.minY >= body.maxY && bubble.minY - body.maxY < 20 && bubble.minX < body.midX && bubble.maxX > body.midX)
                check("말풍선은 16초가 지나도 저절로 닫히지 않는다", MenuBarBubble.shared.frame != nil)
                MenuBarBubble.shared.snapshot(to: file.deletingPathExtension().appendingPathExtension("bubble.png"))
                capture("bubble-on-pet")
                MenuBarBubble.shared.hide()
                check("모두 닫으면 사라지고 남긴 소식도 지운다", MenuBarBubble.shared.frame == nil && MenuBarBubble.shared.pending == 0
                      && UserDefaults.standard.data(forKey: "menuBarBubbleQueue") == nil)
                // 화면 오른쪽 위 끝: 위에 자리가 없어 아래로 뒤집히고, 밀려도 꼬리는 대상을 가리킨다
                let screen = NSScreen.main?.visibleFrame ?? .zero
                let corner = NSRect(x: screen.maxX - 40, y: screen.maxY - 60, width: 30, height: 50)
                MenuBarBubble.shared.show(.init(title: "호스트", items: ["‘개발’ 묶음을 켰습니다"]), at: { (corner, true) })
                let flipped = MenuBarBubble.shared.frame ?? .zero
                check("위에 자리가 없으면 아래로 뒤집혀 뜬다", !MenuBarBubble.shared.isAbove && flipped.maxY <= corner.minY
                      && flipped.maxX <= screen.maxX)
                MenuBarBubble.shared.snapshot(to: file.deletingPathExtension().appendingPathExtension("edge.png"))
                MenuBarBubble.shared.hide()
                // 끄기 전에 닫지 않은 소식: 다시 켜면 단추까지 살아난다
                let saved = ##"[{"title":"레드마인 새 일감 1건","items":["#101 로그인 화면 수정"],"actionTitle":"레드마인 열기","link":"page:redmine"}]"##
                UserDefaults.standard.set(Data(saved.utf8), forKey: "menuBarBubbleQueue")
                MenuBarBubble.resolve = { $0 == "page:redmine" ? {} : nil }
                MenuBarBubble.shared.restore(at: { pet.bodyFrame.map { ($0, true) } })
                check("다시 켜면 닫지 않은 소식을 되살린다 (\(MenuBarBubble.shared.pending)건)",
                      MenuBarBubble.shared.pending == 1 && MenuBarBubble.shared.isAbove)
                MenuBarBubble.shared.snapshot(to: file.deletingPathExtension().appendingPathExtension("restored.png"))
                MenuBarBubble.shared.hide()
                // 일일보고 말풍선: 글을 그대로 보이고 복사·보내기 단추를 둔다
                let report = "[11/11 금일 진행 사항]\n1. UxHub\n- 로그인 화면 마크업 (100%)\n- 목록 API 연동 (50%)"
                let copy = MenuBarBubble.Choice(title: "복사", icon: "doc.on.doc") { $0("복사했습니다", false) }
                let send = MenuBarBubble.Choice(title: "팀즈 나에게 보내기", icon: "paperplane.fill", primary: true) { $0("보냈습니다", true) }
                MenuBarBubble.shared.show(.init(title: "오늘 진행 사항", items: [], actionTitle: "업무 일지에서 고치기", action: {},
                                                keeps: false, report: report, buttons: [copy, send]),
                                          at: { pet.bodyFrame.map { ($0, true) } })
                let reportFrame = MenuBarBubble.shared.frame ?? .zero
                check("일일보고 말풍선은 글과 단추가 들어가게 넓게 뜬다 (\(Int(reportFrame.width))×\(Int(reportFrame.height)))",
                      reportFrame.width >= 320 && reportFrame.height > 150)
                MenuBarBubble.shared.snapshot(to: file.deletingPathExtension().appendingPathExtension("report.png"))
                MenuBarBubble.shared.hide()
                check("일일보고 말풍선은 다시 켜도 낡은 글을 되살리지 않는다", UserDefaults.standard.data(forKey: "menuBarBubbleQueue") == nil)
                pet.snapshot(to: file)
                pet.hide()
                check("넣으면 창이 사라진다", !pet.isShown)
                // 앱 창 머리줄의 펫 단추에 붙는 러너 얼굴
                let icon = MainToolbar.runnerIcon(pet.characterProvider(), size: 64)
                if let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: file.deletingPathExtension().appendingPathExtension("toolbar-icon.png"))
                    let filled = (0..<rep.pixelsWide).contains { x in (0..<rep.pixelsHigh).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 } }
                    check("머리줄 펫 단추에 러너 얼굴이 그려진다", filled)
                } else {
                    check("머리줄 펫 단추에 러너 얼굴이 그려진다", false)
                }
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

/// 어느 앱이 앞에 있든 펫을 움직이는 전역 단축키. 그냥 방향키는 앞에 있는 앱의 것이라 펫 창이 키를 쥔 동안에만 받는다.
/// Carbon 단축키는 권한 없이 동작하고 누름과 놓임을 모두 알려 준다. 기본은 ⌃⌥이고, 다른 앱이 먼저 잡았으면 ⌃⌥⇧으로 물러난다.
final class PetKeys {
    static let shared = PetKeys()
    /// 키 번호(NSEvent.keyCode와 같다), 누름 여부.
    var handler: (UInt16, Bool) -> Void = { _, _ in }
    /// 등록한 보조키 이름. 등록하지 못했으면 nil.
    private(set) var label: String?
    private var refs: [EventHotKeyRef] = []
    private var installed: EventHandlerRef?
    private static let signature = OSType(0x5254_5054)   // 'RTPT'
    static var checkSignature: OSType { signature }
    /// 점검 도구는 키를 실제로 누르지 않아 눌린 것으로 친다.
    static var assumesDown = false
    private static let codes: [UInt16] = [123, 124, 125, 126, 49]

    /// 지금 그 키가 실제로 눌려 있는지. 수를 세거나 내용을 읽지 않아 권한이 필요 없다.
    static func isDown(_ code: UInt16) -> Bool {
        assumesDown || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
    }

    func register() {
        guard refs.isEmpty else { return }
        install()
        let choices: [(UInt32, String)] = [(UInt32(controlKey | optionKey), "⌃⌥"), (UInt32(controlKey | optionKey | shiftKey), "⌃⌥⇧")]
        for (modifiers, name) in choices {
            if take(modifiers) {
                label = name
                return
            }
            unregister()
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        label = nil
    }

    /// 다섯 키를 모두 잡으면 true. 하나라도 다른 앱이 쥐고 있으면 false.
    private func take(_ modifiers: UInt32) -> Bool {
        for code in Self.codes {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(code))
            guard RegisterEventHotKey(UInt32(code), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
            refs.append(ref)
        }
        return true
    }

    private func install() {
        guard installed == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.signature == PetKeys.signature else { return OSStatus(eventNotHandledErr) }
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let code = UInt16(pressed.id)
            DispatchQueue.main.async { PetKeys.shared.handler(code, down) }
            return noErr
        }, specs.count, &specs, nil, &installed)
    }
}
