import AppKit
import UsageCore

/// 표시 상태의 반복 동작을 재생하고, 가끔 한 번짜리 동작(Trick)을 끼워 넣는다.
/// 프레임은 현재 appearance로 1회 래스터라이즈해 캐시하고, Core Animation 키프레임으로 넘겨 재생한다.
/// 프레임마다 버튼 이미지를 바꾸면 버튼 전체를 다시 그려 30fps에서 CPU 18%를 썼다. 레이어 애니메이션은
/// 시스템 렌더 서버가 돌리므로 앱은 상태가 바뀔 때만 깨어난다.
final class SpriteAnimator {

    /// 메뉴바 버튼 위에 얹는 레이어.
    let layer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.contentsScale = 2
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }()
    /// 래스터라이즈에 사용할 appearance 공급자 (상태바 버튼의 effectiveAppearance).
    var appearanceProvider: () -> NSAppearance? = { nil }
    /// 러너 종류·색상·부드러움·장난 여부 공급자 (설정).
    var characterProvider: () -> RunnerCharacter = { Runner.cat.character }
    var themeProvider: () -> SpriteTheme = { .auto }
    var smoothnessProvider: () -> SpriteSmoothness = { .smooth }
    var tricksEnabledProvider: () -> Bool = { true }
    /// 메뉴바에 사용률 숫자가 러너 바로 옆에 붙어 있는지. 그러면 몸 오른쪽으로 나가는 효과를 뺀다.
    var compactProvider: () -> Bool = { false }
    /// 레이어 크기. 프레임을 이 픽셀 크기 그대로 그린다.
    var canvas = MenuBarCanvas(barHeight: NSStatusBar.system.thickness, zoom: 1, backing: 2) {
        didSet { if canvas != oldValue { reloadFrames() } }
    }

    private var idleTimer: Timer?
    private(set) var display: SpriteDisplay?
    /// 지금 건 애니메이션의 번호. 지난 동작의 완료 알림이 늦게 와도 새 동작을 끊지 않게 비교한다.
    private var showToken = 0
    private var playing: Trick?
    private var lastIdleTrick: Trick?
    private var rasterCache: [String: RasterClip] = [:]

    /// 래스터라이즈를 마친 프레임 묶음.
    struct RasterClip {
        let frames: [CGImage]
        let interval: TimeInterval
    }

    init() {
        // 다크/라이트 테마 전환 → 래스터 캐시 무효화 후 다시 그리기
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    func set(display newDisplay: SpriteDisplay) {
        guard newDisplay != display else { return }
        let previous = display
        display = newDisplay
        // 걷기·달리기가 3초마다 바뀌어도 장난 타이머는 이어 간다
        if idleTimer == nil { scheduleIdleTrick() }
        // 상태가 바뀌는 순간을 짧은 동작으로 잇는다. 한도 경고는 바로 보여 준다.
        if let previous, tricksEnabledProvider() {
            switch (previous.isAsleep, newDisplay) {
            case (true, .normal(let state)) where state != .sleeping:
                if perform(.wakeUp) { return }
            case (false, .normal(.sleeping)):
                if perform(.fallAsleep) { return }
            case (false, .normal(.rainbow)):
                if perform(.celebrate) { return }
            default:
                break
            }
        }
        playing = nil
        playLoop()
    }

    /// 한 번짜리 동작 재생. 지침·경고 중이거나 그릴 수 없으면 false.
    @discardableResult
    func perform(_ trick: Trick) -> Bool {
        guard let display, !display.isLimited,
              let clip = rasterized(trick: trick) else { return false }
        playing = trick
        show(clip, loop: false)
        return true
    }

    /// 같은 단계 안에서 빠르기를 바꾼다. 레이어 재생 속도만 바꿔 프레임을 다시 굽지 않고,
    /// 지금 재생 위치를 이어 받아 바꾸는 순간 동작이 튀지 않게 한다.
    func setTempo(_ tempo: Double) {
        let speed = Float(min(max(tempo, 0.5), 2))
        guard abs(layer.speed - speed) > 0.01 else { return }
        let now = CACurrentMediaTime()
        let local = layer.convertTime(now, from: nil)
        layer.speed = speed
        layer.timeOffset = local
        layer.beginTime = now
    }

    /// 사용량 반응에 맞는 동작.
    static func trick(for reaction: UsageReactions.Reaction) -> Trick {
        switch reaction {
        case .burst: .zoom
        case .resumed: .stretch
        case .sessionMilestone(let percent): percent >= 75 ? .milestone75 : percent >= 50 ? .milestone50 : .milestone25
        case .multitask: .dance
        case .newSession: .celebrate
        }
    }

    /// 깨어 있으면 깨어 있는 동작, 자고 있으면 잠버릇 중 하나.
    func performRandom() {
        guard let display else { return }
        let candidates = (display.isAsleep ? Trick.asleep : Trick.awake).filter { $0 != lastIdleTrick }
        guard let trick = candidates.randomElement() else { return }
        lastIdleTrick = trick
        perform(trick)
    }

    @objc private func themeChanged() {
        DispatchQueue.main.async { [self] in reloadFrames() }
    }

    /// 캐시를 비우고 현재 표시 상태의 프레임을 다시 만든다 (macOS 테마·러너·색상·부드러움 변경 시).
    func reloadFrames() {
        rasterCache.removeAll()
        bodyRightCache.removeAll()
        trickKeys.removeAll()
        guard display != nil else { return }
        playing = nil
        playLoop()
        scheduleIdleTrick()
    }

    private func playLoop() {
        guard let display else { return }
        show(rasterized(display: display), loop: true)
    }

    /// 프레임을 키프레임 애니메이션으로 레이어에 건다. 한 번짜리 동작이 끝나면 반복 동작으로 돌아간다.
    private func show(_ clip: RasterClip, loop: Bool) {
        showToken += 1
        let token = showToken
        layer.removeAnimation(forKey: "sprite")
        guard let first = clip.frames.first, clip.frames.count > 1 else {
            layer.contents = clip.frames.first
            if !loop {
                // 재생할 프레임이 없으면 바로 반복 동작으로 돌아간다
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.showToken == token else { return }
                    self.playing = nil
                    self.playLoop()
                }
            }
            return
        }
        layer.contents = loop ? first : clip.frames.last
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = clip.frames
        animation.calculationMode = .discrete
        animation.duration = clip.interval * Double(clip.frames.count)
        animation.repeatCount = loop ? .infinity : 1
        animation.isRemovedOnCompletion = !loop
        if !loop {
            animation.delegate = AnimationEnd { [weak self] finished in
                guard let self, finished, self.showToken == token else { return }
                self.playing = nil
                self.playLoop()
            }
        }
        layer.add(animation, forKey: "sprite")
    }

    // MARK: - 래스터 캐시

    private var cacheSuffix: String {
        let appearance = appearanceProvider()?.name.rawValue ?? "default"
        return "\(characterProvider().key)|\(themeProvider().rawValue)|\(smoothnessProvider().rawValue)|\(appearance)"
            + "|\(canvas.cacheKey)|\(compactProvider() ? "compact" : "wide")"
    }

    private func rasterized(display: SpriteDisplay) -> RasterClip {
        let key = "\(display.key)|\(cacheSuffix)"
        if let cached = rasterCache[key] { return cached }
        let clip = SpriteFrames.clip(for: display, character: characterProvider(), theme: themeProvider(),
                                     fps: smoothnessProvider().fps, visibleY: canvas.visibleY, compact: compactProvider())
        let result = rasterize(clip)
        rasterCache[key] = result
        return result
    }

    /// 동작 클립 캐시. 30fps 이하는 모든 동작을 다 둬도 십여 MB라 다 두고, 60fps는 한 동작이 100장을 넘어 최근 것만 둔다.
    private var trickKeys: [String] = []
    private var trickCacheLimit: Int { smoothnessProvider() == .max ? 6 : Trick.allCases.count }

    private func rasterized(trick: Trick) -> RasterClip? {
        let key = "trick.\(trick.rawValue)|\(cacheSuffix)"
        if let cached = rasterCache[key] { return cached }
        guard let clip = SpriteFrames.clip(for: trick, character: characterProvider(), theme: themeProvider(),
                                           fps: smoothnessProvider().fps, visibleY: canvas.visibleY,
                                           compact: compactProvider()) else { return nil }
        let result = rasterize(clip)
        rasterCache[key] = result
        trickKeys.append(key)
        if trickKeys.count > trickCacheLimit {
            rasterCache[trickKeys.removeFirst()] = nil
        }
        return result
    }

    private func rasterize(_ clip: SpriteClip) -> RasterClip {
        let appearance = appearanceProvider()
        let halo = Self.halo(theme: characterProvider().menuBarTheme(themeProvider()), appearance: appearance)
        let frames = clip.frames.compactMap {
            SpriteRasterizer.cgImage($0, canvas: canvas, appearance: appearance, halo: halo)
        }
        return RasterClip(frames: frames, interval: clip.interval)
    }

    /// 컬러로 그리는 러너의 테두리 색. 검은 머리·옷이 어두운 메뉴바에 묻히지 않게 메뉴바와 반대 밝기로 두른다.
    /// 단색 실루엣은 메뉴바 글자색이라 필요 없다.
    static func halo(theme: SpriteTheme, appearance: NSAppearance?) -> NSColor? {
        guard theme == .natural else { return nil }
        let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.35)
    }

    // MARK: - 몸 오른쪽 끝

    private var bodyRightCache: [String: CGFloat] = [:]

    /// 러너 몸이 닿는 오른쪽 끝 (칸 왼쪽에서 pt). 사용률 숫자를 몸 바로 옆에 붙이는 데 쓴다.
    /// 그림 러너는 그림 둘레가 투명해서 칸 끝보다 한참 안쪽에서 끝난다. 반복 동작 몇 장을 효과 없이 그려 실제 픽셀로 잰다.
    /// 누운 잠 자세가 달리는 자세보다 길어서 둘을 따로 잰다. 그래야 달리는 동안 숫자가 몸에 붙고,
    /// 항목 폭은 잠들고 깰 때만 바뀐다 (걷기·달리기가 바뀔 때마다 메뉴바를 다시 배치하지 않는다).
    func bodyRight(resting: Bool) -> CGFloat {
        let character = characterProvider()
        let key = "\(character.key)|\(themeProvider().rawValue)|\(canvas.cacheKey)|\(resting)"
        if let cached = bodyRightCache[key] { return cached }
        var right = 0
        let displays: [SpriteDisplay] = resting ? [.normal(.sleeping), .tired, .alert]
            : [.normal(.walking), .normal(.running), .normal(.dashing), .normal(.rainbow)]
        // 메뉴바와 같은 색 방식으로 그린다. 단색 실루엣은 그림 러너의 투명한 둘레까지 칠할 수 있다
        let theme = character.menuBarTheme(themeProvider())
        do {
            for display in displays {
                let count = 6
                let fit = SpriteFrames.loopFit(display, rig: character.rig, range: canvas.visibleY, count: count)
                for i in 0..<count {
                    let image = SpriteFrames.image { cg in
                        SpriteFrames.render(cg, rig: character.rig, frame: display.motion(at: CGFloat(i) / CGFloat(count)),
                                            theme: theme, themePhase: 0, alarm: false, fit: .fixed(fit)) { _, _, _, _ in }
                    }
                    if let raster = SpriteRasterizer.cgImage(image, canvas: canvas, appearance: nil) {
                        right = max(right, Self.opaqueRight(raster))
                    }
                }
            }
        }
        let points = right == 0 ? canvas.size.width : min(canvas.size.width, CGFloat(right) / canvas.backing)
        bodyRightCache[key] = points
        return points
    }

    /// 알파가 있는 가장 오른쪽 픽셀 열 + 1.
    private static func opaqueRight(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let cg = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return width }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for x in stride(from: width - 1, through: 0, by: -1) {
            for y in 0..<height where bytes[(y * width + x) * 4 + 3] > 24 { return x + 1 }
        }
        return 0
    }

    // MARK: - 장난 타이머

    /// 25~70초마다 아무 동작이나 한 번. 지침·경고 중에는 쉰다.
    private func scheduleIdleTrick() {
        idleTimer?.invalidate()
        let delay = TimeInterval.random(in: 25...70)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.tricksEnabledProvider(), self.playing == nil,
               let display = self.display, !display.isLimited {
                self.performRandom()
            }
            self.scheduleIdleTrick()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

}

/// 애니메이션이 끝났을 때 알림을 받는 대리자 (CAAnimation은 대리자를 강하게 붙든다).
private final class AnimationEnd: NSObject, CAAnimationDelegate {
    let completion: (Bool) -> Void

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        completion(flag)
    }
}
