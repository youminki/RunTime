import AppKit
import UsageCore

/// 메뉴바에 표시할 스프라이트 종류. 움직임은 토큰 속도(5단계)가, 한도 경고는 사용률이 정한다 (§F2).
/// 토큰을 쓰는 중이면 한도에 가까워도 속도대로 달리고 경고만 얹는다. 쉬는 중일 때만 앉거나 멈춰 선다.
enum SpriteDisplay: Equatable {
    case normal(CatState)
    case tired      // 사용률 80%+ 이고 쉬는 중: 앉아서 헐떡인다
    case alert      // 사용률 95%+ 이고 쉬는 중: 빨갛게 멈춰 선다
    /// 한도에 가까운 채로 달린다. 80%는 달리며 헐떡이고, 95%는 빨갛게 달린다.
    case straining(CatState, critical: Bool)

    init(state: CatState, level: UsageAlertLevel) {
        switch (level, state) {
        case (.normal, _): self = .normal(state)
        case (.tired, .sleeping): self = .tired
        case (.critical, .sleeping): self = .alert
        case (.tired, _): self = .straining(state, critical: false)
        case (.critical, _): self = .straining(state, critical: true)
        }
    }

    /// 움직임을 정하는 토큰 속도 단계. 쉬면서 경고 중이면 nil.
    var pace: CatState? {
        switch self {
        case .normal(let state), .straining(let state, _): return state
        case .tired, .alert: return nil
        }
    }

    /// 한도 경고 중인지. 경고 중에는 장난을 치지 않아 경고 모습이 가려지지 않게 한다.
    var isLimited: Bool { if case .normal = self { return false } else { return true } }

    /// 제자리에 있는 모습인지 (잠, 쉬며 지침·경고). 누운 잠 자세는 달리는 모습보다 옆으로 길다.
    var isResting: Bool { pace == nil || pace == .sleeping }

    /// 빨간 경고(95%+)인지.
    var isCritical: Bool {
        switch self {
        case .alert, .straining(_, critical: true): return true
        default: return false
        }
    }

    /// 한 동작 주기(초). 프레임 수는 이 길이를 fps로 나눠 정한다.
    var cycle: TimeInterval {
        switch self {
        case .normal(.sleeping): return 2.6
        case .normal(.walking): return 1.25
        case .normal(.running): return 0.72
        case .normal(.dashing): return 0.54
        case .normal(.rainbow): return 0.44
        case .tired: return 1.1
        case .alert: return 1.6
        case .straining(let state, _): return SpriteDisplay.normal(state).cycle
        }
    }

    /// 프레임 캐시 키.
    var key: String {
        switch self {
        case .normal(let state): return state.rawValue
        case .tired: return "tired"
        case .alert: return "alert"
        case .straining(let state, let critical): return "\(state.rawValue)-\(critical ? "critical" : "tired")"
        }
    }

    var isAsleep: Bool { self == .normal(.sleeping) }

    /// 숨쉬기처럼 느린 동작은 프레임을 늘려도 차이가 없어 상한을 둔다 (잠자는 동안 CPU 절약).
    var maxFPS: Double {
        switch self {
        case .normal(.sleeping): return 20
        case .tired: return 30
        case .straining(let state, _): return SpriteDisplay.normal(state).maxFPS
        default: return 60
        }
    }

    /// 진행도 phase(0~1)의 모습.
    func motion(at phase: CGFloat) -> MotionFrame {
        switch self {
        case .normal(.sleeping):
            return MotionFrame(pose: CharacterPose(activity: .sleep, phase: phase, eyes: .closed))
        case .normal(.walking):
            return MotionFrame(pose: CharacterPose(activity: .walk, phase: phase))
        case .normal(.running):
            return MotionFrame(pose: CharacterPose(activity: .run, phase: phase, speed: 1))
        case .normal(.dashing):
            return MotionFrame(pose: CharacterPose(activity: .run, phase: phase, speed: 1.2))
        case .normal(.rainbow):
            return MotionFrame(pose: CharacterPose(activity: .run, phase: phase, speed: 1.35))
        case .tired:
            return MotionFrame(pose: CharacterPose(activity: .sit, phase: phase, mouthOpen: true))
        case .alert:
            // 멈춰 서서 무겁게 숨 쉰다. 떨게 하면 메뉴바에서 계속 눈에 걸려 일을 방해한다
            var frame = MotionFrame(pose: CharacterPose(activity: .stand, phase: phase))
            frame.transform.squash = 1 - 0.035 * sin(tau * phase)
            return frame
        case .straining(let state, _):
            // 지쳐도 달리는 모습은 그대로 두고 입만 벌린다
            var frame = SpriteDisplay.normal(state).motion(at: phase)
            frame.pose.mouthOpen = true
            return frame
        }
    }

    /// 상태마다 늘 붙는 효과 (빛 꼬리, 공기 줄, 흙먼지, z, 입김, 경고 점).
    /// `leftEdge`는 빛 꼬리가 끝나는 x (팝오버 무대는 화면 왼쪽 끝까지 끈다).
    /// `compact`면 메뉴바에서 러너 바로 오른쪽에 사용률 숫자가 붙어 있다. 몸 오른쪽으로 나가는 효과는 숫자를 가리므로
    /// 빼거나 왼쪽으로 돌린다. 경고는 숫자 색(주황·빨강)이 대신 알린다.
    func drawLoopEffects(in cg: CGContext, scene: CharacterScene, phase: CGFloat, tint: NSColor, front: Bool,
                         leftEdge: CGFloat = -1, compact: Bool = false) {
        let bounds = scene.placedBounds
        let body = (bounds.minY + bounds.height * 0.2)...(bounds.maxY - bounds.height * 0.25)
        let mouth = scene.headAnchor.map {
            CGPoint(min($0.eye.x + $0.width * 0.32, bounds.maxX), $0.eye.y + $0.width * 0.3)
        } ?? CGPoint(bounds.maxX - 0.3, bounds.minY + min(4, bounds.height * 0.35))
        if case .straining(let state, let critical) = self {
            // 속도 효과는 그대로, 위에 한도 표시만 얹는다
            SpriteDisplay.normal(state).drawLoopEffects(in: cg, scene: scene, phase: phase, tint: tint, front: front,
                                                        leftEdge: leftEdge, compact: compact)
            guard front, !compact else { return }
            if critical {
                // 달리는 한 주기가 짧아 퍼지는 원은 너무 잦다. 점만 둔다
                let c = CGPoint(min(bounds.maxX + 1.4, 33), max(bounds.minY + 0.5, 4.8))
                cg.setFillColor(NSColor.systemRed.cgColor)
                cg.fillEllipse(in: CGRect(x: c.x - 1.1, y: c.y - 1.1, width: 2.2, height: 2.2))
            } else {
                SpriteEffects.breath(cg, at: mouth, phase: phase, color: tint)
            }
            return
        }
        switch (self, front) {
        case (.normal(.rainbow), false):
            SpriteEffects.lightTrail(cg, from: leftEdge, to: bounds.minX + 4, centerY: bounds.midY - 0.3, width: 2.6,
                                     phase: phase, color: tint)
            SpriteEffects.airStreaks(cg, phase: phase * 2, maxX: bounds.minX + 1, band: body, color: tint, count: 4,
                                     length: 8)
        case (.normal(.dashing), false):
            SpriteEffects.airStreaks(cg, phase: phase, maxX: bounds.minX + 2, band: body, color: tint)
        case (.normal(.running), false):
            SpriteEffects.footDust(cg, at: CGPoint(bounds.minX + 4, Stage.ground - 0.7), phase: phase, color: tint)
        case (.normal(.sleeping), true):
            SpriteEffects.zzz(cg, from: CGPoint(bounds.maxX - 2.5, bounds.minY + 0.5), phase: phase, color: tint,
                              leftward: compact)
        case (.tired, true) where !compact:
            SpriteEffects.breath(cg, at: mouth, phase: phase, color: tint)
        case (.alert, true) where !compact:
            // 퍼지는 원(반지름 2.4)이 메뉴바 칸 위·오른쪽에서 잘리지 않는 자리
            SpriteEffects.ping(cg, at: CGPoint(min(bounds.maxX + 1.4, 33), max(bounds.minY + 0.5, 4.8)),
                               phase: phase, color: .systemRed)
        default:
            break
        }
    }
}

/// 러너 색상. 코드로 그린 러너에만 적용되고, 커스텀 PNG 에셋은 원본 색 그대로.
enum SpriteTheme: String, CaseIterable {
    case auto      // labelColor — 다크/라이트 메뉴바 자동
    case natural   // 캐릭터 고유색 + 외곽선
    case orange
    case sky
    case pink
    case green
    case purple
    case yellow
    case rainbow   // 프레임마다 색이 돈다
    // 상점 색: 미니게임 코인으로 산다
    case gold, ruby, mint, aurora

    var displayName: String {
        switch self {
        case .auto: return "자동"
        case .natural: return "본래 색"
        case .orange: return "주황"
        case .sky: return "하늘"
        case .pink: return "분홍"
        case .green: return "초록"
        case .purple: return "보라"
        case .yellow: return "노랑"
        case .rainbow: return "무지개"
        case .gold: return "황금"
        case .ruby: return "루비"
        case .mint: return "민트"
        case .aurora: return "오로라"
        }
    }

    /// 단색일 때의 색. 무지개는 진행도에 따라 색상환을 돈다.
    func tint(at phase: CGFloat) -> NSColor {
        switch self {
        case .auto, .natural: return .labelColor
        case .orange: return .systemOrange
        case .sky: return .systemTeal
        case .pink: return .systemPink
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .yellow: return .systemYellow
        case .rainbow:
            return NSColor(hue: phase - floor(phase), saturation: 0.72, brightness: 0.98, alpha: 1)
        case .gold: return NSColor(hex: 0xF5B800)
        case .ruby: return NSColor(hex: 0xE0245E)
        case .mint: return NSColor(hex: 0x3DDBB4)
        case .aurora:
            // 청록과 보라 사이를 천천히 오간다
            let wave = 0.5 + 0.5 * sin(phase * 2 * .pi)
            return NSColor(hue: 0.45 + 0.33 * wave, saturation: 0.62, brightness: 0.98, alpha: 1)
        }
    }

    /// 메뉴바용 그리는 방식.
    func look(palette: CharacterPalette, phase: CGFloat, alarm: Bool) -> CharacterLook {
        if self == .natural {
            var look = CharacterLook(rich: true, palette: palette, tint: .labelColor, outline: 0.42)
            look.alarm = alarm
            return look
        }
        return .mono(alarm ? .systemRed : tint(at: phase))
    }

    /// 팝오버 무대·설정 타일용. 단색 테마는 몸 색만 바꾸고 나머지는 캐릭터 고유색을 쓴다.
    func richPalette(_ base: CharacterPalette, phase: CGFloat) -> CharacterPalette {
        guard self != .auto && self != .natural else { return base }
        var palette = base
        let color = tint(at: phase).usingColorSpace(.sRGB) ?? .systemOrange
        palette.body = color.tinted(by: 0.12)
        palette.belly = color.tinted(by: 0.6)
        palette.imageTint = color
        return palette
    }
}

/// 메뉴바 애니메이션 부드러움 (fps 상한). 높을수록 매끄럽고 CPU를 더 쓴다.
enum SpriteSmoothness: String, CaseIterable {
    case saver, smooth, max

    var displayName: String {
        switch self {
        case .saver: return "절약"
        case .smooth: return "부드럽게"
        case .max: return "최고"
        }
    }

    var fps: Double {
        switch self {
        case .saver: return 12
        case .smooth: return 30
        case .max: return 60
        }
    }
}

/// 한 동작을 잘게 나눈 프레임 묶음.
struct SpriteClip {
    let frames: [NSImage]
    let interval: TimeInterval
}

/// 상태별 스프라이트 프레임 로더.
///
/// 에셋 교체: `Sources/RunTime/Assets/`에 `<러너>_<상태>_<번호>.png`를 넣고 다시 빌드하면
/// 코드로 그린 러너 대신 자동 사용된다 (Assets/README.md 참조). 예: cat_run_0.png ... cat_run_7.png
enum SpriteFrames {

    static let spriteSize = Stage.size

    /// 주기를 fps로 나눈 프레임 수와 간격.
    static func timing(cycle: TimeInterval, fps: Double) -> (count: Int, interval: TimeInterval) {
        let count = max(4, Int((cycle * fps).rounded()))
        return (count, cycle / Double(count))
    }

    /// `visibleY`를 주면 그 높이 범위(메뉴바 칸)를 벗어나는 장면을 줄여 넣는다.
    static func clip(for display: SpriteDisplay, character: RunnerCharacter, theme chosen: SpriteTheme,
                     fps: Double, visibleY: ClosedRange<CGFloat>? = nil, compact: Bool = false) -> SpriteClip {
        if let prefix = character.assetPrefix, let assets = assetClip(for: display, prefix: prefix) { return assets }
        let theme = character.menuBarTheme(chosen)
        let overlay = character.imageTint(chosen)
        let (count, interval) = timing(cycle: display.cycle, fps: min(fps, display.maxFPS))
        let rig = character.rig
        let fit = visibleY.map { SceneFit.fixed(loopFit(display, rig: rig, range: $0, count: count)) } ?? .none
        let frames = (0..<count).map { i -> NSImage in
            let phase = CGFloat(i) / CGFloat(count)
            return image { cg in
                render(cg, rig: rig, frame: display.motion(at: phase), theme: theme, themePhase: phase,
                       alarm: display.isCritical, fit: fit, overlay: overlay) { cg, scene, tint, front in
                    display.drawLoopEffects(in: cg, scene: scene, phase: phase, tint: tint, front: front, compact: compact)
                }
            }
        }
        return SpriteClip(frames: frames, interval: interval)
    }

    /// 한 번 재생하는 동작. Assets 폴더 PNG로 바꾼 러너는 동작 프레임이 없어 nil.
    static func clip(for trick: Trick, character: RunnerCharacter, theme chosen: SpriteTheme, fps: Double,
                     visibleY: ClosedRange<CGFloat>? = nil, compact: Bool = false) -> SpriteClip? {
        if let prefix = character.assetPrefix, loadAssets(named: "\(prefix)_run", count: 8) != nil { return nil }
        let theme = character.menuBarTheme(chosen)
        let overlay = character.imageTint(chosen)
        let (count, interval) = timing(cycle: trick.duration, fps: fps)
        let rig = character.rig
        let frames = (0...count).map { i -> NSImage in
            let t = CGFloat(i) / CGFloat(count)
            var frame = trick.frame(at: t)
            // 사용률 고리는 러너 오른쪽에 떠서 붙어 있는 숫자를 가린다. 숫자가 이미 사용률을 보여 준다
            if compact { frame.effects.removeAll { if case .ring = $0 { true } else { false } } }
            return image { cg in
                render(cg, rig: rig, frame: frame, theme: theme, themePhase: t, alarm: false,
                       fit: visibleY.map(SceneFit.each) ?? .none, overlay: overlay) { _, _, _, _ in }
            }
        }
        return SpriteClip(frames: frames, interval: interval)
    }

    /// 높이가 정해진 칸(메뉴바)에 장면을 맞추는 방법.
    enum SceneFit {
        case none
        /// 프레임마다 따로 맞춘다. 장난은 움직임이 이어지니 크기도 이어서 바뀐다.
        case each(ClosedRange<CGFloat>)
        /// 미리 구한 변환을 모든 프레임에 건다. 반복 동작이 프레임마다 커졌다 작아지지 않게 한다.
        case fixed(CGAffineTransform)
    }

    /// 반복 동작 한 주기의 모든 장면을 감싸는 영역으로 맞춤을 한 번 구한다.
    static func loopFit(_ display: SpriteDisplay, rig: CharacterRig, range: ClosedRange<CGFloat>,
                        count: Int) -> CGAffineTransform {
        let union = (0..<count).reduce(CGRect.null) { rect, i in
            let frame = display.motion(at: CGFloat(i) / CGFloat(count))
            return rect.union(CharacterScene(rig: rig, pose: frame.pose, transform: frame.transform).placedBounds)
        }
        return union.isNull ? .identity : CharacterScene.fitTransform(for: union, in: range)
    }

    /// 러너 한 장면을 그린다. 효과는 `loopEffects`(뒤·앞 두 번 불림)와 동작 자체의 효과를 함께 얹는다.
    static func render(_ cg: CGContext, rig: CharacterRig, frame: MotionFrame, theme: SpriteTheme,
                       themePhase: CGFloat, alarm: Bool, fit: SceneFit = .none, overlay: SpriteTheme? = nil,
                       loopEffects: (CGContext, CharacterScene, NSColor, Bool) -> Void) {
        func place(_ frame: MotionFrame) -> CharacterScene {
            var scene = CharacterScene(rig: rig, pose: frame.pose, transform: frame.transform)
            switch fit {
            case .none: break
            case .each(let range): scene.fit(verticallyIn: range)
            case .fixed(let transform): scene.apply(fit: transform)
            }
            return scene
        }
        let scene = place(frame)
        var palette = rig.palette
        palette.imageTint = overlay?.tint(at: themePhase)
        let look = theme.look(palette: palette, phase: themePhase, alarm: alarm)
        let tint = theme == .natural ? NSColor.labelColor : look.tint
        loopEffects(cg, scene, tint, false)
        scene.draw(in: cg, look: look)
        loopEffects(cg, scene, tint, true)
        for effect in frame.effects {
            effect.draw(in: cg, around: scene.placedBounds, tint: tint)
        }
    }

    /// 설계 좌표(y 아래)로 그리는 이미지. 그리기는 래스터라이즈 시점에 일어난다.
    static func image(size: CGSize = Stage.size, scale: CGFloat = 1, _ draw: @escaping (CGContext) -> Void) -> NSImage {
        NSImage(size: NSSize(width: size.width * scale, height: size.height * scale), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.scaleBy(x: scale, y: scale)
            draw(cg)
            return true
        }
    }

    // MARK: - 파일 에셋

    private static func assetClip(for display: SpriteDisplay, prefix: String) -> SpriteClip? {
        let frames: [NSImage]?
        switch display {
        case .normal(.sleeping): frames = loadAssets(named: "\(prefix)_sleep", count: 2)
        case .normal(.rainbow):
            frames = loadAssets(named: "\(prefix)_rainbow", count: 8) ?? loadAssets(named: "\(prefix)_run", count: 8)
        case .normal: frames = loadAssets(named: "\(prefix)_run", count: 8)
        case .tired: frames = loadAssets(named: "\(prefix)_tired", count: 2)
        case .alert: frames = loadAssets(named: "\(prefix)_alert", count: 2)
        case .straining(let state, _): return assetClip(for: .normal(state), prefix: prefix)
        }
        guard let frames else { return nil }
        return SpriteClip(frames: frames, interval: display.cycle / Double(frames.count))
    }

    private static var assetCache: [String: [NSImage]?] = [:]

    private static func loadAssets(named prefix: String, count: Int) -> [NSImage]? {
        if let cached = assetCache[prefix] { return cached }
        var result: [NSImage]? = nil
        if let assetsDir = Bundle.module.resourceURL?.appendingPathComponent("Assets") {
            var frames: [NSImage] = []
            for i in 0..<count {
                let url = assetsDir.appendingPathComponent("\(prefix)_\(i).png")
                guard let image = NSImage(contentsOf: url) else { break }   // 하나라도 없으면 전체 폴백
                image.size = spriteSize
                frames.append(image)
            }
            if frames.count == count { result = frames }
        }
        assetCache[prefix] = result
        return result
    }
}
