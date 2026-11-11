import AppKit

/// 꾸미기 그림. 게임과 꾸미기 미리보기가 같은 함수로 그려 고를 때 본 모습이 게임에서도 그대로 나온다.
/// 좌표는 위가 0인 무대 좌표다. 꾸미기·동작 효과는 같은 결의 도트 그림(`PixelFX`)으로 그리고,
/// 말풍선·새·슬라임은 OpenGameArt의 CC0 도트 그림이다 (Assets/FX/CREDITS.txt).
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

    static func loops(_ name: String) -> Bool {
        let name = name.split(separator: "|").first.map(String.init) ?? name
        if PixelFX.sprite(name) != nil { return PixelFX.loops(name) }
        return sheets[name]?.loop == true
    }

    /// 효과 그림 한 장면. 한 번 재생하는 그림은 `progress`(0~1), 도는 그림은 `time`으로 프레임을 고른다.
    static func drawSprite(_ name: String, at center: CGPoint, height: CGFloat, progress: CGFloat, time: Double,
                           alpha: CGFloat = 1, rotation: CGFloat = 0, flip: Bool = false, _ cg: CGContext) {
        guard alpha > 0.01, height > 0.5 else { return }
        // 도트 효과는 `nominal` 줄이 요청한 키라, 그림마다 줄 수가 달라도 점 크기가 같다
        if let pixel = PixelFX.frame(name, progress: progress, time: time) {
            // 줄 수가 적은 도트 그림은 같은 키면 예전 그림보다 작게 읽혀, 배경의 점 굵기에 맞춰 조금 키운다
            let unit = height / CGFloat(pixel.nominal) * PixelFX.boost
            draw(pixel.image, at: center, height: unit * CGFloat(pixel.rows), pixel: true, alpha: alpha, rotation: 0, flip: flip, cg)
            return
        }
        guard let sheet = sheets[name] else { return }
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
        guard alpha > 0.01, height > 0.5 else { return }
        // 사탕도 도트 사탕으로 그린다. 도트 그림은 돌리면 점이 깨져 기울기는 버린다
        drawSprite(PixelFX.candyName(name), at: center, height: height, progress: 0, time: 0, alpha: alpha, cg)
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
            // "별|반짝이"처럼 여러 그림을 섞으면 입자마다 하나를 고른다
            let names = name.split(separator: "|")
            let chosen = names.count > 1 ? String(names[Int(seed * CGFloat(names.count)) % names.count]) : name
            drawSprite(chosen, at: center, height: r * 5, progress: progress, time: time + Double(seed) * 3, alpha: alpha, cg)
        case .candy(let name):
            drawCandy(name, at: center, height: r * 5, alpha: alpha,
                      rotation: (seed - 0.5) * 2 + progress * (seed - 0.5) * 5, cg)
        }
    }

    // MARK: 꼬리

    /// `points`는 오래된 자리부터 러너 쪽 순서 (무대 좌표). 꽃잎·눈·사탕은 팔랑이며 떨어지고, 구름·방울은 떠오르고,
    /// 하트·별은 둥실거리며, 뒤로 갈수록 작고 옅어진다.
    static func drawTrail(_ item: Cosmetic, points: [CGPoint], time: Double, _ cg: CGContext) {
        guard points.count > 1, let shape = item.fx else { return }
        let count = CGFloat(points.count)
        // 도트 입자는 크고 또렷해 촘촘히 두면 한 줄로 번져 보여 더 띄운다
        let gap = drift(shape) == nil ? 3 : 5
        for (i, point) in points.enumerated() where i % gap == 1 {
            let t = CGFloat(i) / count          // 러너 쪽이 1
            let age = 1 - t
            let phase = time * 3 + Double(i) * 0.8
            var p = point
            switch drift(shape) {
            case .fall?:
                p.y += age * 10
                p.x += CGFloat(sin(phase)) * 4 * age
            case .rise?:
                p.y -= age * 6
                p.x += CGFloat(sin(phase)) * 1.5 * age
            case .bob?, nil:
                p.y += CGFloat(sin(phase)) * 2
            }
            drawParticle(shape, at: p, size: 1.5 + 1.8 * t, alpha: 0.25 + 0.75 * t, progress: age,
                         seed: CGFloat(i % 7) / 7, time: time, cg)
        }
    }

    // MARK: 동료

    /// 동료 (Petdex 펫) 한 장면. `feet`는 발이 닿는 자리, `height`는 서 있을 때 키(pt).
    /// `jump`(0~1)를 주면 뛰는 중이라 그림 러너는 점프 줄로 그린다. `gesture`를 주면 서 있거나 걷는 대신 그 자세를 한다
    /// (펫을 따라 손 흔들기·앉기·잠).
    static func drawCompanion(_ character: RunnerCharacter, feet: CGPoint, height: CGFloat, phase: CGFloat, moving: Bool,
                              jump: CGFloat? = nil, facing: CGFloat = 1, theme: SpriteTheme = .auto,
                              gesture: CharacterPose? = nil, _ cg: CGContext) {
        var pose = gesture ?? CharacterPose(activity: moving ? .run : .stand, phase: phase)
        pose.jump = jump ?? pose.jump
        var transform = CharacterTransform()
        transform.scaleX = facing < 0 ? -1 : 1
        let scene = CharacterScene(rig: character.rig, pose: pose, transform: transform)
        let scale = height / FittedRig.targetHeight
        cg.saveGState()
        cg.translateBy(x: feet.x - FittedRig.targetCenterX * scale, y: feet.y - Stage.ground * scale)
        cg.scaleBy(x: scale, y: scale)
        let rich = character.theme(theme)
        scene.draw(in: cg, look: CharacterLook(rich: true, palette: rich.richPalette(character.rig.palette, phase: 0),
                                               tint: .white, outline: max(0.32, 1.1 / scale)))
        cg.restoreGState()
    }

    // MARK: 주변 효과

    /// 몸 둘레의 효과 (무대 좌표, 위가 0). `front`가 false면 몸 뒤, true면 몸 앞에 그릴 것만 그려 몸을 감싼다.
    /// 정신없지 않게 몇 개만, 조금 투명하게 둔다. `size`는 입자 키.
    static func drawAura(_ item: Cosmetic, around body: CGRect, time: Double, front: Bool, size: CGFloat, _ cg: CGContext) {
        guard case .sprite(let name)? = item.fx, !body.isEmpty else { return }
        let names = name.split(separator: "|").map(String.init)
        func hash(_ i: Int, _ salt: Int) -> CGFloat { RunnerStageHash.value(i, salt) }
        switch names[0] {
        case "butterfly":
            // 두 마리가 8자로 날며 몸 앞뒤를 오간다
            for i in 0..<2 {
                let angle = time * 0.9 + Double(i) * .pi
                let depth = CGFloat(sin(angle))
                guard (depth >= 0) == front else { continue }
                let x = body.midX + CGFloat(cos(angle)) * body.width * 0.85
                let y = body.minY + body.height * 0.32 + CGFloat(sin(angle * 2)) * body.height * 0.12
                drawSprite("butterfly", at: CGPoint(x: x, y: y), height: size * (0.85 + 0.15 * depth), progress: 0,
                           time: time + Double(i) * 0.3, alpha: 0.8 + 0.2 * depth, flip: cos(angle + .pi / 2) < 0, cg)
            }
        case "glitter":
            // 몸 둘레 몇 곳에서 반짝였다 사라지고, 다음에는 다른 곳에서 반짝인다
            for i in 0..<3 {
                let local = time / 1.8 + Double(i) / 3
                let round = Int(floor(local)) * 3 + i
                guard (hash(round, 17) > 0.5) == front else { continue }
                let x = body.minX - body.width * 0.2 + body.width * 1.4 * hash(round, 5)
                let y = body.minY + body.height * 0.9 * hash(round, 9)
                drawSprite("glitter", at: CGPoint(x: x, y: y), height: size * 0.9, progress: CGFloat(local - floor(local)),
                           time: time, alpha: 0.9, cg)
            }
        case "tinyHeart":
            // 이따금 머리 옆에서 하트 하나가 피어올라 사라진다
            guard front else { return }
            let t = CGFloat((time / 2.6).truncatingRemainder(dividingBy: 1))
            guard t < 0.65 else { return }
            let k = t / 0.65
            drawSprite("tinyHeart", at: CGPoint(x: body.midX + body.width * 0.3 + CGFloat(sin(Double(k) * 6)) * size * 0.25,
                                                y: body.minY + body.height * 0.1 - k * body.height * 0.4),
                       height: size * (0.6 + 0.3 * min(1, k * 4)), progress: 0, time: time, alpha: sin(k * .pi), cg)
        default:
            switch drift(.sprite(name)) {
            case .bob?, nil:
                // 허리 높이로 돌아 앞으로 지나갈 때 얼굴을 가리지 않는다
                let count = 3
                for i in 0..<count {
                    let angle = time * 1.1 + Double(i) * 2 * .pi / Double(count)
                    let depth = CGFloat(sin(angle))
                    guard (depth >= 0) == front else { continue }
                    let x = body.midX + CGFloat(cos(angle)) * body.width * 0.78
                    let y = body.minY + body.height * 0.66 + depth * body.height * 0.12
                    drawSprite(names[i % names.count], at: CGPoint(x: x, y: y), height: size * (0.75 + 0.2 * depth), progress: 0,
                               time: time + Double(i) * 0.4, alpha: 0.6 + 0.3 * depth, cg)
                }
            case .some(let drift):
                for i in 0..<4 where (i % 2 == 0) == front {
                    let seed = hash(i, 11)
                    let cycle = 2.6 + Double(seed) * 1.4
                    let t = CGFloat(((time + Double(i) * 0.9) / cycle).truncatingRemainder(dividingBy: 1))
                    let x = body.minX - body.width * 0.2 + body.width * 1.4 * seed + CGFloat(sin(Double(t) * 5 + Double(seed) * 6)) * size * 0.7
                    let y = drift == .rise ? body.maxY - t * body.height * 1.2 : body.minY - body.height * 0.3 + t * body.height * 1.3
                    drawSprite(names[i % names.count], at: CGPoint(x: x, y: y), height: size * 0.85, progress: t,
                               time: time + Double(seed) * 3, alpha: sin(t * .pi) * 0.85, cg)
                }
            }
        }
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

    /// 도트 입자의 움직임 (섞은 그림은 첫 그림을 따른다). 도트 그림이 아니면 nil.
    static func drift(_ shape: Shape) -> PixelFX.Drift? {
        guard case .sprite(let name) = shape else { return .fall }
        return PixelFX.drift(name.split(separator: "|").first.map(String.init) ?? name)
    }

    /// 발을 디딜 때 일어나는 먼지. 고른 발먼지로만 인다 (고르지 않았으면 부르는 쪽이 그리지 않는다).
    static func dust(_ item: Cosmetic, landing: Bool) -> Spray {
        let shape = item.fx ?? .sprite("dust")
        // 구름·먼지·방울은 떠오르고, 하트·별·꽃잎은 튀었다 떨어진다
        let floats = drift(shape).map { $0 == .rise } ?? { if case .sprite(let name) = shape { !loops(name) } else { false } }()
        return Spray(count: landing ? 3 : 2, shape: shape, speed: landing ? 30 : 40, life: floats ? 0.5 : 0.6,
                     size: 1.1...1.6, gravity: floats ? -20 : 80, drift: 1)
    }

    /// 부딪힌 순간 터지는 것들. 여러 겹이면 여러 개를 돌려준다. 가운데 터짐과 흩어지는 입자 모두 도트 그림이다.
    static func crash(_ item: Cosmetic?) -> [(offset: CGPoint, spray: Spray)] {
        func scatter(_ name: String, _ count: Int, speed: CGFloat = 140, life: CGFloat = 1.0, gravity: CGFloat = 220)
            -> (CGPoint, Spray) {
            (.zero, Spray(count: count, shape: .sprite(name), speed: speed, life: life, size: 1.2...1.8, spread: 2,
                          gravity: gravity, drift: 0.2))
        }
        switch item {
        case .starburstCrash:
            return [(.zero, blast("burst", size: 9, life: 0.6)), scatter("star", 8, speed: 130, life: 0.8)]
        case .heartCrash:
            return [(.zero, blast("popPink", size: 8)), scatter("heart", 9, speed: 130)]
        case .petalCrash:
            return [(.zero, blast("popPink", size: 7)), scatter("petal", 12, speed: 120, life: 1.2, gravity: 90)]
        case .coinCrash:
            return [scatter("coin", 14, speed: 170, life: 1.1)]
        case .fireCrash:
            return [(.zero, blast("fireBurst", size: 9)), scatter("flame", 8, speed: 90, life: 0.8, gravity: -160)]
        case .magicCrash:
            return [(.zero, blast("magic", size: 9, life: 0.7)), scatter("sparkle", 12, speed: 130, life: 0.8, gravity: 60)]
        case .snowCrash:
            return [(.zero, blast("snowPop", size: 8, life: 0.7)), scatter("snow", 10, speed: 110, life: 1.2, gravity: 70)]
        case .boomCrash:
            return [(.zero, blast("smoke", size: 9, life: 0.8)), scatter("dust", 5, speed: 60, life: 0.8, gravity: -60)]
        case .candyCrash:
            return [(.zero, blast("popPink", size: 8)), scatter("candyPink|candyBlue|candyYellow|candyTeal", 10, speed: 150, life: 1.1)]
        default:
            return [(.zero, blast("burst", size: 6))]
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
