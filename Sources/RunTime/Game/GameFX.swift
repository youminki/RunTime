import AppKit

/// 꾸미기 그림. 게임과 꾸미기 미리보기가 같은 함수로 그려 고를 때 본 모습이 게임에서도 그대로 나온다.
/// 좌표는 위가 0인 무대 좌표다. 효과 그림은 모두 OpenGameArt의 CC0 도트 그림이다 (Assets/FX/CREDITS.txt).
enum GameFX {
    private static var images: [String: CGImage] = [:]

    static func image(_ name: String, folder: String = "Game") -> CGImage? {
        let key = folder + "/" + name
        if let cached = images[key] { return cached }
        guard let url = Bundle.assets.resourceURL?.appendingPathComponent("Assets/\(folder)/\(name).png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        images[key] = image
        return image
    }

    // MARK: 효과 그림

    /// Assets/FX/<이름>의 프레임 묶음. fx.json에 프레임 수와 반복 여부가 있다.
    struct Sheet: Decodable {
        let frames: Int
        let pixel: Bool
        /// 하트·별·코인처럼 계속 도는 그림. 아니면 수명 동안 한 번 재생한다.
        var loop: Bool?
    }

    private static let sheets: [String: Sheet] = {
        guard let url = Bundle.assets.resourceURL?.appendingPathComponent("Assets/FX/fx.json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Sheet].self, from: data)) ?? [:]
    }()

    static func loops(_ name: String) -> Bool { sheets[name]?.loop == true }

    /// 효과 그림 한 장면. 한 번 재생하는 그림은 `progress`(0~1), 도는 그림은 `time`으로 프레임을 고른다.
    static func drawSprite(_ name: String, at center: CGPoint, height: CGFloat, progress: CGFloat, time: Double,
                           alpha: CGFloat = 1, rotation: CGFloat = 0, flip: Bool = false, _ cg: CGContext) {
        guard alpha > 0.01, height > 0.5, let sheet = sheets[name] else { return }
        let index = sheet.loop == true ? Int(time * 10) % sheet.frames
            : min(max(Int(progress * CGFloat(sheet.frames)), 0), sheet.frames - 1)
        guard let image = image("\(index)", folder: "FX/\(name)") else { return }
        draw(image, at: center, height: height, pixel: sheet.pixel, alpha: alpha, rotation: rotation, flip: flip, cg)
    }

    /// 게임 코인으로 쓰는 사탕 그림. 자리마다 다르게 고른다.
    static let candies = ["lollipop_pink", "swirl_blue", "jelly_yellow", "star_yellow", "mm_teal", "heart_red",
                          "lollipop_teal", "swirl_pink", "jelly_pink", "candycane"]

    static func candy(for seed: Double) -> String {
        candies[Int(abs(seed).rounded()) % candies.count]
    }

    /// 사탕 그림 한 장 (Assets/FX/candy).
    static func drawCandy(_ name: String, at center: CGPoint, height: CGFloat, alpha: CGFloat = 1, rotation: CGFloat = 0,
                          _ cg: CGContext) {
        guard alpha > 0.01, height > 0.5, let image = image(name, folder: "FX/candy") else { return }
        draw(image, at: center, height: height, pixel: false, alpha: alpha, rotation: rotation, cg)
    }

    private static func draw(_ image: CGImage, at center: CGPoint, height: CGFloat, pixel: Bool, alpha: CGFloat,
                             rotation: CGFloat, flip: Bool = false, _ cg: CGContext) {
        let width = height * CGFloat(image.width) / CGFloat(max(image.height, 1))
        cg.saveGState()
        cg.setAlpha(alpha)
        // 도트 그림은 점이 번지지 않게 키운다
        cg.interpolationQuality = pixel ? .none : .high
        cg.translateBy(x: center.x, y: center.y)
        cg.scaleBy(x: flip ? -1 : 1, y: -1)   // 무대는 위가 0이라 그림을 바로 세운다
        if rotation != 0 { cg.rotate(by: -rotation) }
        cg.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        cg.restoreGState()
    }

    // MARK: 입자

    enum Shape: Equatable {
        case sprite(String)
        /// 사탕 그림. 떨어지며 빙글 돈다.
        case candy(String)
    }

    /// 입자 하나. `progress`는 0(막 생김)에서 1(사라짐), `size`의 다섯 배가 그림 키다.
    static func drawParticle(_ shape: Shape, at center: CGPoint, size r: CGFloat, alpha: CGFloat, progress: CGFloat,
                             seed: CGFloat, time: Double, _ cg: CGContext) {
        switch shape {
        case .sprite(let name):
            drawSprite(name, at: center, height: r * 5, progress: progress, time: time + Double(seed) * 3, alpha: alpha, cg)
        case .candy(let name):
            drawCandy(name, at: center, height: r * 5, alpha: alpha,
                      rotation: (seed - 0.5) * 2 + progress * (seed - 0.5) * 5, cg)
        }
    }

    // MARK: 꼬리

    /// `points`는 오래된 자리부터 러너 쪽 순서 (무대 좌표). 사탕은 팔랑이며 떨어지고,
    /// 도는 그림은 둥실거리고, 한 번 재생하는 그림(연기·불꽃·마법)은 뒤로 갈수록 끝까지 재생돼 흩어진다.
    static func drawTrail(_ item: Cosmetic, points: [CGPoint], time: Double, _ cg: CGContext) {
        guard points.count > 1, let shape = item.fx else { return }
        let count = CGFloat(points.count)
        for (i, point) in points.enumerated() where i % 3 == 1 {
            let t = CGFloat(i) / count          // 러너 쪽이 1
            let age = 1 - t
            let phase = time * 3 + Double(i) * 0.8
            var p = point
            switch shape {
            case .candy:
                p.y += age * 10
                p.x += CGFloat(sin(phase)) * 4 * age
            case .sprite(let name) where loops(name):
                p.y += CGFloat(sin(phase)) * 2
            case .sprite:
                p.y -= age * 6
            }
            drawParticle(shape, at: p, size: 1.5 + 1.8 * t, alpha: 0.25 + 0.75 * t, progress: age,
                         seed: CGFloat(i % 7) / 7, time: time, cg)
        }
    }

    // MARK: 동료

    /// 동료 (Petdex 펫) 한 장면. `feet`는 발이 닿는 자리, `height`는 서 있을 때 키(pt).
    /// `jump`(0~1)를 주면 뛰는 중이라 그림 러너는 점프 줄로 그린다.
    static func drawCompanion(_ character: RunnerCharacter, feet: CGPoint, height: CGFloat, phase: CGFloat, moving: Bool,
                              jump: CGFloat? = nil, theme: SpriteTheme = .auto, _ cg: CGContext) {
        var pose = CharacterPose(activity: moving ? .run : .stand, phase: phase)
        pose.jump = jump
        let scene = CharacterScene(rig: character.rig, pose: pose)
        let scale = height / FittedRig.targetHeight
        cg.saveGState()
        cg.translateBy(x: feet.x - FittedRig.targetCenterX * scale, y: feet.y - Stage.ground * scale)
        cg.scaleBy(x: scale, y: scale)
        let rich = character.theme(theme)
        scene.draw(in: cg, look: CharacterLook(rich: true, palette: rich.richPalette(character.rig.palette, phase: 0),
                                               tint: .white, outline: max(0.32, 1.1 / scale)))
        cg.restoreGState()
    }

    // MARK: 발먼지·부딪힘

    struct Spray {
        var count: Int
        var shape: Shape
        var speed: CGFloat
        var life: CGFloat
        var size: ClosedRange<CGFloat> = 1.4...2.6
        /// 1이면 위쪽 반원, 2면 사방.
        var spread: CGFloat = 1
        /// 아래로 끌어당기는 힘 (음수면 떠오른다).
        var gravity: CGFloat = 220
        var drift: CGFloat = 0
    }

    /// 한 번 터지는 큰 그림 하나 (부딪힘의 가운데).
    private static func blast(_ name: String, size: CGFloat, life: CGFloat = 0.6) -> Spray {
        Spray(count: 1, shape: .sprite(name), speed: 0, life: life, size: size...size, spread: 2, gravity: 0)
    }

    /// 발을 디딜 때 일어나는 먼지. 고르지 않았으면 흙먼지.
    static func dust(_ item: Cosmetic?, landing: Bool) -> Spray {
        let shape = item?.fx ?? .sprite("smokePoff")
        // 연기는 떠오르고, 하트·별·사탕은 튀었다 떨어진다
        let floats = if case .sprite(let name) = shape { !loops(name) } else { false }
        return Spray(count: landing ? 3 : 2, shape: shape, speed: landing ? 30 : 40, life: floats ? 0.5 : 0.6,
                     size: 1.1...1.6, gravity: floats ? -20 : 80, drift: 1)
    }

    /// 부딪힌 순간 터지는 것들. 여러 겹이면 여러 개를 돌려준다.
    static func crash(_ item: Cosmetic?) -> [(offset: CGPoint, spray: Spray)] {
        switch item {
        case .starburstCrash:
            return [(.zero, blast("starburst", size: 9, life: 0.7)),
                    (.zero, Spray(count: 8, shape: .sprite("rainbowStar"), speed: 130, life: 0.8, size: 1.2...1.8, spread: 2))]
        case .ringCrash:
            return [(.zero, blast("ringBoom", size: 8, life: 0.7))]
        case .boomCrash:
            return [(.zero, blast("boom", size: 8, life: 0.8)),
                    (.zero, Spray(count: 5, shape: .sprite("smokePoff"), speed: 60, life: 0.8, size: 1.6...2.4, gravity: -60))]
        case .fireCrash:
            return [(.zero, blast("fireBlast", size: 8)),
                    (.zero, Spray(count: 8, shape: .sprite("firePlume"), speed: 90, life: 0.8, size: 1.4...2.2, gravity: -160))]
        case .candyCrash:
            return [(.zero, blast("candyPop_pink", size: 8)),
                    (.zero, Spray(count: 4, shape: .candy("lollipop_pink"), speed: 150, life: 1.1, size: 1.2...1.6, spread: 2)),
                    (.zero, Spray(count: 4, shape: .candy("swirl_blue"), speed: 150, life: 1.1, size: 1.2...1.6, spread: 2)),
                    (.zero, Spray(count: 4, shape: .candy("jelly_yellow"), speed: 150, life: 1.1, size: 1.2...1.6, spread: 2))]
        case .heartCrash:
            return [(.zero, blast("candyPop_red", size: 7)),
                    (.zero, Spray(count: 10, shape: .sprite("pumpingHeart"), speed: 130, life: 1.0, size: 1.2...1.8, spread: 2))]
        case .gemCrash:
            return [(.zero, Spray(count: 8, shape: .sprite("gemHeart"), speed: 150, life: 1.1, size: 1.4...2.0, spread: 2,
                                  drift: 0.3))]
        case .coinCrash:
            return [(.zero, Spray(count: 14, shape: .sprite("coin"), speed: 170, life: 1.1, size: 1.2...1.8, spread: 2,
                                  drift: 0.3))]
        case .magicCrash:
            return [(.zero, blast("plasmaBubble", size: 8, life: 0.7)),
                    (.zero, Spray(count: 12, shape: .sprite("plasmaSparkle"), speed: 130, life: 0.8, size: 1.2...2.0,
                                  spread: 2, gravity: 60))]
        default:
            return [(.zero, blast("pixelBoom", size: 6))]
        }
    }

    /// 미리보기용: 터진 지 `age`초 지난 뿌림 하나를 계산해서 그린다 (난수 대신 순번으로 정해 깜빡이지 않게).
    static func drawSpray(_ spray: Spray, from origin: CGPoint, age: CGFloat, time: Double, _ cg: CGContext) {
        guard age >= 0, age < spray.life else { return }
        for i in 0..<spray.count {
            let jitter = RunnerStageHash.value(i, 7)
            let angle = CGFloat(i) / CGFloat(max(spray.count, 1)) * .pi * spray.spread + .pi * 0.05 + (jitter - 0.5) * 0.4
            let v = spray.speed * (0.6 + 0.5 * RunnerStageHash.value(i, 3))
            let life = spray.life * (0.7 + 0.3 * RunnerStageHash.value(i, 5))
            guard age < life else { continue }
            let x = origin.x - cos(angle) * v * age - spray.drift * 60 * age
            let y = origin.y - sin(angle) * v * age + 0.5 * spray.gravity * age * age
            let size = spray.size.lowerBound + (spray.size.upperBound - spray.size.lowerBound) * RunnerStageHash.value(i, 9)
            drawParticle(spray.shape, at: CGPoint(x: x, y: y), size: size, alpha: 1 - age / life, progress: age / life,
                         seed: jitter, time: time, cg)
        }
    }
}

/// 0~1 고정 난수. 무대 그림과 같은 식이다.
enum RunnerStageHash {
    static func value(_ i: Int, _ salt: Int) -> CGFloat { StageModel.hash(i, salt) }
}
