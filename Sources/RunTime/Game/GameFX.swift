import AppKit

/// 꾸미기 그림. 게임과 상점 미리보기가 같은 함수로 그려 상점에서 본 모습이 게임에서도 그대로 나온다.
/// 좌표는 위가 0인 무대 좌표다.
enum GameFX {
    /// 흰 입자 그림 (Kenney Particle Pack, CC0). 색을 입혀 쓴다.
    enum Texture: String {
        case smoke = "fx_smoke_04", star = "fx_star_06", spark = "fx_spark_05",
             flame = "fx_flame_03", glow = "fx_light_01", twirl = "fx_twirl_02", ring = "fx_circle_05"
    }

    private static var images: [String: CGImage] = [:]
    private struct TintKey: Hashable {
        let texture: Texture
        let rgb: UInt32
    }
    private static var tinted: [TintKey: CGImage] = [:]

    static func image(_ name: String, folder: String = "Game") -> CGImage? {
        let key = folder + "/" + name
        if let cached = images[key] { return cached }
        guard let url = Bundle.assets.resourceURL?.appendingPathComponent("Assets/\(folder)/\(name).png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        images[key] = image
        return image
    }

    /// Fluent Emoji 3D 그림 하나 (Assets/Fluent, MIT). 가운데에 맞춰 돌려 그린다.
    static func drawArt(_ name: String, at center: CGPoint, size: CGFloat, alpha: CGFloat = 1, rotation: CGFloat = 0,
                        flip: Bool = false, _ cg: CGContext) {
        guard alpha > 0.01, size > 0.5, let image = image(name, folder: "Fluent") else { return }
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.interpolationQuality = .high
        cg.translateBy(x: center.x, y: center.y)
        cg.scaleBy(x: flip ? -1 : 1, y: -1)
        if rotation != 0 { cg.rotate(by: -rotation) }
        cg.draw(image, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
        cg.restoreGState()
    }

    /// 흰 그림의 밝기는 두고 색만 바꾼 그림. 색마다 한 번만 만든다.
    static func image(_ texture: Texture, tint: NSColor) -> CGImage? {
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let key = TintKey(texture: texture, rgb: UInt32(rgb.redComponent * 255) << 16 | UInt32(rgb.greenComponent * 255) << 8
                            | UInt32(rgb.blueComponent * 255))
        if let cached = tinted[key] { return cached }
        guard let base = image(texture.rawValue),
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(rgb.withAlphaComponent(1).cgColor)
        context.fill(rect)
        let result = context.makeImage()
        tinted[key] = result
        return result
    }

    /// 입자 그림 하나를 가운데에 맞춰 돌려 그린다. 빛나는 그림은 더해 그려 바탕 위에서 밝게 보이게 한다.
    static func draw(_ texture: Texture, tint: NSColor, at center: CGPoint, size: CGFloat, alpha: CGFloat,
                     rotation: CGFloat = 0, glow: Bool = true, _ cg: CGContext) {
        guard alpha > 0.01, size > 0.2, let image = image(texture, tint: tint) else { return }
        cg.saveGState()
        cg.setAlpha(alpha)
        if glow { cg.setBlendMode(.plusLighter) }
        cg.interpolationQuality = .medium
        cg.translateBy(x: center.x, y: center.y)
        cg.scaleBy(x: 1, y: -1)   // 무대는 위가 0이라 그림을 바로 세운다
        if rotation != 0 { cg.rotate(by: rotation) }
        cg.draw(image, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
        cg.restoreGState()
    }

    // MARK: 입자

    enum Shape: Equatable {
        case dot, heart, coin, spark
        case texture(Texture)
        /// Fluent 그림. 떨어지며 빙글 돈다.
        case art(String)
    }

    /// 입자 하나. `progress`는 0(막 생김)에서 1(사라짐).
    static func drawParticle(_ shape: Shape, color: NSColor, at center: CGPoint, size r: CGFloat, alpha: CGFloat,
                             progress: CGFloat, seed: CGFloat, time: Double, _ cg: CGContext) {
        switch shape {
        case .dot:
            cg.setFillColor(color.withAlphaComponent(alpha).cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        case .heart:
            GameSession.fillHeart(cg, at: center, size: r * 2.2, color: color.withAlphaComponent(alpha))
        case .spark:
            SpriteEffects.sparkle(cg, at: center, radius: r * 1.6, color: color.withAlphaComponent(alpha))
        case .coin:
            if let image = GameSprite.coin.frame(at: time + Double(seed)) {
                cg.saveGState()
                cg.setAlpha(alpha)
                GameAssets.draw(image, in: CGRect(x: center.x - r * 2, y: center.y - r * 2, width: r * 4, height: r * 4), cg)
                cg.restoreGState()
            }
        case .art(let name):
            drawArt(name, at: center, size: r * 5, alpha: alpha, rotation: (seed - 0.5) * 2 + progress * (seed - 0.5) * 5, cg)
        case .texture(let texture):
            // 연기는 퍼지며 커지고, 고리는 크게 번진다
            let grow: CGFloat = switch texture {
            case .smoke: 1 + progress * 1.4
            case .ring, .twirl: 0.4 + progress * 2.6
            default: 1
            }
            // 불꽃은 늘 위로 서고, 나머지는 돌며 흩어진다
            let rotation = texture == .flame ? 0 : seed * 6 + progress * (texture == .twirl ? 4 : 1.5)
            draw(texture, tint: color, at: center, size: r * 5 * grow, alpha: alpha, rotation: rotation,
                 glow: texture != .smoke, cg)
        }
    }

    // MARK: 꼬리

    /// `points`는 오래된 자리부터 러너 쪽 순서 (무대 좌표).
    static func drawTrail(_ item: Cosmetic, points: [CGPoint], time: Double, _ cg: CGContext) {
        guard points.count > 1 else { return }
        cg.saveGState()
        cg.setLineCap(.round)
        let count = CGFloat(points.count)
        if let art = item.art {
            drawArtTrail(item, art: art, points: points, time: time, cg)
            cg.restoreGState()
            return
        }
        switch item {
        case .rainbowTrail:
            for (band, color) in SpriteEffects.rainbow.enumerated() {
                let dy = (CGFloat(band) - 2.5) * 2.2
                for i in 1..<points.count {
                    let t = CGFloat(i) / count
                    cg.setStrokeColor(color.withAlphaComponent(0.85 * t).cgColor)
                    cg.setLineWidth(2.4)
                    cg.move(to: CGPoint(x: points[i - 1].x, y: points[i - 1].y + dy))
                    cg.addLine(to: CGPoint(x: points[i].x, y: points[i].y + dy))
                    cg.strokePath()
                }
            }
        case .cometTrail:
            for i in 1..<points.count {
                let t = CGFloat(i) / count
                cg.setStrokeColor(item.color.withAlphaComponent(0.7 * t).cgColor)
                cg.setLineWidth(1 + 7 * t)
                cg.move(to: points[i - 1])
                cg.addLine(to: points[i])
                cg.strokePath()
            }
        case .fireTrail:
            // 꼬리 쪽으로 갈수록 노랗고 작아지며 흔들린다
            for (i, point) in points.enumerated() where i % 2 == 1 {
                let t = CGFloat(i) / count
                let flicker = CGFloat(sin(time * 23 + Double(i) * 1.7)) * 1.2
                let color = NSColor(hex: 0xFFE14D).blended(withFraction: t, of: NSColor(hex: 0xFF5A1F)) ?? item.color
                draw(.glow, tint: color, at: CGPoint(x: point.x, y: point.y + flicker), size: 6 + 14 * t, alpha: 0.3 * t, cg)
                draw(.flame, tint: color, at: CGPoint(x: point.x, y: point.y + flicker - 4 * t), size: 7 + 17 * t,
                     alpha: 0.35 + 0.65 * t, cg)
            }
        case .noteTrail, .heartTrail:
            for (i, point) in points.enumerated() where i % 5 == 1 {
                let t = CGFloat(i) / count
                let bob = CGFloat(sin(time * 6 + Double(i))) * 3
                let p = CGPoint(x: point.x, y: point.y - 6 + bob)
                let color = item.color.withAlphaComponent(0.3 + 0.7 * t)
                if item == .heartTrail {
                    GameSession.fillHeart(cg, at: p, size: 4 + 3 * t, color: color)
                } else {
                    let s = 0.8 + 0.5 * t
                    cg.setFillColor(color.cgColor)
                    cg.fillEllipse(in: CGRect(x: p.x - 2.4 * s, y: p.y + 1.5 * s, width: 3.6 * s, height: 2.6 * s))
                    cg.setStrokeColor(color.cgColor)
                    cg.setLineWidth(1.1 * s)
                    cg.move(to: CGPoint(x: p.x + 1.1 * s, y: p.y + 2.6 * s))
                    cg.addLine(to: CGPoint(x: p.x + 1.1 * s, y: p.y - 4 * s))
                    cg.addLine(to: CGPoint(x: p.x + 3.2 * s, y: p.y - 2.6 * s))
                    cg.strokePath()
                }
            }
        case .magicTrail:
            // 보라·분홍 별이 돌며 뒤로 흩어진다
            for (i, point) in points.enumerated() where i % 2 == 0 {
                let t = CGFloat(i) / count
                let wobble = CGFloat(sin(time * 7 + Double(i) * 0.9)) * 4 * (1 - t)
                let color = i % 4 == 0 ? NSColor(hex: 0xC68CFF) : NSColor(hex: 0xFF9AE0)
                draw(.glow, tint: color, at: CGPoint(x: point.x, y: point.y + wobble), size: 10 + 14 * t, alpha: 0.5 * t, cg)
                draw(.star, tint: color, at: CGPoint(x: point.x, y: point.y + wobble), size: 9 + 13 * t, alpha: 0.4 + 0.6 * t,
                     rotation: CGFloat(time * 3) + CGFloat(i), cg)
            }
        case .smokeTrail:
            // 오래된 김일수록 크고 옅다
            for (i, point) in points.enumerated() where i % 2 == 0 {
                let t = CGFloat(i) / count
                let rise = (1 - t) * 8
                draw(.smoke, tint: item.color, at: CGPoint(x: point.x, y: point.y - rise), size: 8 + 16 * (1 - t),
                     alpha: 0.12 + 0.4 * t, rotation: CGFloat(i) * 0.7, glow: false, cg)
            }
        case .sparkTrail:
            // 틱마다 모양이 바뀌는 지그재그 번개
            let tick = Int(time * 20)
            for pass in 0..<2 {
                let path = CGMutablePath()
                for (i, point) in points.enumerated() {
                    let jitter = (RunnerStageHash.value(i, tick + pass * 31) - 0.5) * 8 * (1 - CGFloat(i) / count)
                    let p = CGPoint(x: point.x, y: point.y + jitter)
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                cg.addPath(path)
                cg.setStrokeColor(item.color.withAlphaComponent(pass == 0 ? 0.35 : 0.9).cgColor)
                cg.setLineWidth(pass == 0 ? 4 : 1.3)
                cg.setLineJoin(.round)
                cg.strokePath()
            }
            if let head = points.last {
                draw(.spark, tint: item.color, at: head, size: 18, alpha: 0.7, rotation: CGFloat(tick % 4) * .pi / 2, cg)
            }
        default:
            for (i, point) in points.enumerated() where i % 3 == 0 {
                let t = CGFloat(i) / count
                let twinkle = 0.7 + 0.3 * CGFloat(sin(time * 9 + Double(i)))
                draw(.star, tint: item.color, at: point, size: (5 + 10 * t) * twinkle, alpha: t, cg)
            }
        }
        cg.restoreGState()
    }

    /// 그림 꼬리. 꽃잎·잎·눈은 팔랑이며 떨어지고, 비눗방울은 떠오르며 커지고, 사탕은 돈다.
    private static func drawArtTrail(_ item: Cosmetic, art: String, points: [CGPoint], time: Double, _ cg: CGContext) {
        let count = CGFloat(points.count)
        for (i, point) in points.enumerated() where i % 3 == 1 {
            let t = CGFloat(i) / count          // 러너 쪽이 1
            let age = 1 - t
            let phase = time * 3 + Double(i) * 0.8
            var p = point
            var rotation: CGFloat = 0
            var size = 7 + 6 * t
            switch item {
            case .bubbleTrail:
                p.y -= age * 14 + CGFloat(sin(phase)) * 2
                p.x += CGFloat(sin(phase * 0.7)) * 3
                size = 6 + 9 * age
            case .candyTrail:
                rotation = CGFloat(phase)
            default:
                // 팔랑이며 아래로 떨어진다
                p.y += age * 10
                p.x += CGFloat(sin(phase)) * 4 * age
                rotation = CGFloat(sin(phase * 0.9)) * 0.9
            }
            drawArt(art, at: p, size: size, alpha: 0.25 + 0.75 * t, rotation: rotation, cg)
        }
    }

    // MARK: 동료

    /// 동료 (Petdex 펫) 한 장면. `feet`는 발이 닿는 자리, `height`는 서 있을 때 키(pt).
    static func drawCompanion(_ character: RunnerCharacter, feet: CGPoint, height: CGFloat, phase: CGFloat, moving: Bool,
                              theme: SpriteTheme = .auto, _ cg: CGContext) {
        let scene = CharacterScene(rig: character.rig, pose: CharacterPose(activity: moving ? .run : .stand, phase: phase))
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
        var colors: [NSColor]
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

    /// 발을 디딜 때 일어나는 먼지.
    static func dust(_ item: Cosmetic?, landing: Bool) -> Spray {
        let count = landing ? 4 : 5
        let speed: CGFloat = landing ? 30 : 40
        if let item, let art = item.art {
            return Spray(count: landing ? 2 : 1, colors: [item.color], shape: .art(art), speed: speed * 0.8, life: 0.6,
                         size: 1.2...1.8, gravity: 80, drift: 1)
        }
        switch item {
        case .cloudDust:
            return Spray(count: 3, colors: [item!.color], shape: .texture(.smoke), speed: speed * 0.7, life: 0.55,
                         size: 1.4...2.2, gravity: -20, drift: 1)
        case .starDust:
            return Spray(count: count, colors: [item!.color, .white], shape: .texture(.star), speed: speed, life: 0.45,
                         size: 1.0...1.6, drift: 1)
        case .rainbowDust:
            return Spray(count: count + 1, colors: SpriteEffects.rainbow, shape: .dot, speed: speed, life: 0.4, drift: 1)
        case let item?:
            return Spray(count: count, colors: [item.color], shape: .dot, speed: speed, life: 0.35, drift: 1)
        case nil:
            return Spray(count: count, colors: [NSColor(white: 0.85, alpha: 1)], shape: .dot, speed: speed, life: 0.35, drift: 1)
        }
    }

    /// 부딪힌 순간 터지는 것들. 여러 겹이면 여러 개를 돌려준다.
    static func crash(_ item: Cosmetic?) -> [(offset: CGPoint, spray: Spray)] {
        switch item {
        case .fireworksCrash:
            return [-18.0, 0, 20].enumerated().map { k, dx in
                (CGPoint(x: dx, y: 18 + Double(k % 2) * 10),
                 Spray(count: 14, colors: SpriteEffects.rainbow.shuffled(), shape: .spark, speed: 110, life: 0.9, spread: 2))
            }
        case .heartCrash:
            return [(.zero, Spray(count: 12, colors: [NSColor(hex: 0xFF8FB8), NSColor(hex: 0xFF5C8A)], shape: .heart,
                                  speed: 120, life: 0.9, size: 2.2...3.4, spread: 2))]
        case .coinCrash:
            return [(.zero, Spray(count: 16, colors: [.white], shape: .coin, speed: 170, life: 1.1, size: 1.6...2.4,
                                  spread: 2, drift: 0.3))]
        case .magicCrash:
            return [(.zero, Spray(count: 1, colors: [NSColor(hex: 0xC68CFF)], shape: .texture(.ring), speed: 0, life: 0.7,
                                  size: 5...5, spread: 2, gravity: 0)),
                    (.zero, Spray(count: 1, colors: [NSColor(hex: 0xFF9AE0)], shape: .texture(.twirl), speed: 0, life: 0.8,
                                  size: 4...4, spread: 2, gravity: 0)),
                    (.zero, Spray(count: 12, colors: [NSColor(hex: 0xC68CFF), NSColor(hex: 0xFF9AE0), .white],
                                  shape: .texture(.star), speed: 130, life: 0.8, size: 1.2...2.0, spread: 2, gravity: 60))]
        case .boomCrash:
            return [(.zero, Spray(count: 1, colors: [.white], shape: .art("collision"), speed: 0, life: 0.5, size: 6...6,
                                  spread: 2, gravity: 0)),
                    (.zero, Spray(count: 10, colors: [NSColor(hex: 0xFFE14D), NSColor(hex: 0xFF8A3D)], shape: .texture(.star),
                                  speed: 150, life: 0.6, size: 1.0...1.6, spread: 2))]
        case .balloonCrash:
            return [(.zero, Spray(count: 5, colors: [.white], shape: .art("balloon"), speed: 40, life: 1.4, size: 1.6...2.2,
                                  gravity: -90))]
        case .sweetCrash:
            return ["donut", "candy", "lollipop"].map { art in
                (.zero, Spray(count: 4, colors: [.white], shape: .art(art), speed: 150, life: 1.1, size: 1.3...1.9, spread: 2))
            }
        case .confettiCrash:
            return [(CGPoint(x: 0, y: 6), Spray(count: 1, colors: [.white], shape: .art("confetti"), speed: 0, life: 0.9,
                                                size: 4.5...4.5, spread: 2, gravity: 0)),
                    (CGPoint(x: -14, y: 0), Spray(count: 2, colors: [.white], shape: .art("popper"), speed: 60, life: 0.9,
                                                  size: 2.2...2.6, gravity: 120)),
                    (.zero, Spray(count: 18, colors: SpriteEffects.rainbow, shape: .texture(.star), speed: 170, life: 1.0,
                                  size: 0.9...1.5, spread: 2, gravity: 120))]
        case .flameCrash:
            return [(.zero, Spray(count: 14, colors: [NSColor(hex: 0xFFE14D), NSColor(hex: 0xFF8A3D), NSColor(hex: 0xFF4A1F)],
                                  shape: .texture(.flame), speed: 90, life: 0.75, size: 1.6...2.6, gravity: -160)),
                    (.zero, Spray(count: 6, colors: [NSColor(white: 0.6, alpha: 1)], shape: .texture(.smoke), speed: 50,
                                  life: 1.0, size: 2...3, gravity: -60))]
        default:
            return [(.zero, Spray(count: 12, colors: [.white], shape: .dot, speed: 120, life: 0.55))]
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
            drawParticle(spray.shape, color: spray.colors[i % spray.colors.count], at: CGPoint(x: x, y: y), size: size,
                         alpha: 1 - age / life, progress: age / life, seed: jitter, time: time, cg)
        }
    }
}

/// 0~1 고정 난수. 무대 그림과 같은 식이다.
enum RunnerStageHash {
    static func value(_ i: Int, _ salt: Int) -> CGFloat { StageModel.hash(i, salt) }
}
