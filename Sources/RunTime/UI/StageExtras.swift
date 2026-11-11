import AppKit
import GameCore

/// 팝오버 무대에서 러너가 달리는 동안 생기는 일들. 길 위 코인을 줍고, 빠를 때는 작은 장애물을 뛰어넘고,
/// 발을 디딜 때마다 고른 발먼지가 일고 등 뒤로 고른 꼬리가 끌린다. 하늘에는 시간대에 맞는 새나 별똥별이 지나간다.
/// 자리는 모두 땅 좌표(scroll 기준)로 두어 배경과 같은 속도로 흘러간다.
final class StageExtras {
    private enum Kind { case hurdle(GameSprite) }

    private struct Prop {
        let kind: Kind
        /// 땅 좌표 x (화면 x = worldX - scroll).
        let worldX: CGFloat
        /// 땅에서 위로 띄운 높이.
        let height: CGFloat
        /// 뛰어넘지 않고 부딪힐 장애물. 부딪힘 꾸미기를 달면 게임 밖에서도 그 효과를 보게 가끔 섞는다.
        var bumps = false
    }

    /// 러너가 장애물에 부딪혔다. 무대가 비틀거리는 동작을 붙인다.
    var onBump: () -> Void = {}

    private struct Puff {
        let spray: GameFX.Spray
        let worldX: CGFloat
        let y: CGFloat
        let at: Double
        let zoom: CGFloat
    }

    private struct Flyer {
        enum Kind { case birds, slime, shootingStar }
        let kind: Kind
        let at: Double
        let y: CGFloat
        let seed: CGFloat
    }

    private var props: [Prop] = []
    private var puffs: [Puff] = []
    private var flyers: [Flyer] = []
    private var trail: [(worldX: CGFloat, y: CGFloat)] = []
    /// 쓰다듬은 때. 하트가 머리 위로 살랑이며 피어오른다.
    private var pats: [Double] = []
    private var nextHurdle: Double?
    private var nextFlyer: Double?
    private var lastStep = 0
    private var wasAirborne = false
    private var lastHop: CGFloat = 0
    /// 직전 장면의 러너 몸 (화면 좌표). 뛰어넘을 높이와 코인 줍는 자리를 정한다.
    private(set) var body: CGRect = .zero

    func reset() {
        props.removeAll()
        puffs.removeAll()
        trail.removeAll()
        nextHurdle = nil
    }

    // MARK: 갱신

    /// 이번 프레임에 러너가 뛰어오를 높이(pt)를 돌려준다.
    func update(time: Double, scroll: CGFloat, speed: CGFloat, size: CGSize, active: Bool) -> CGFloat {
        let right = scroll + size.width + 24
        if nextHurdle == nil { nextHurdle = time + 0.3 }
        if nextFlyer == nil { nextFlyer = time + 2.5 }

        // 장애물은 빨리 달릴 때만. 느리면 한 번 뛰는 데 너무 오래 떠 있다
        if active, speed > 70, let due = nextHurdle, time >= due {
            let sprite: GameSprite = [.mushroom, .cactus, .spikes].randomElement() ?? .mushroom
            let x = right + 10
            props.append(Prop(kind: .hurdle(sprite), worldX: x, height: 0,
                              bumps: GameDecor.shared.equipped(.crash) != nil && Double.random(in: 0...1) < 0.4))
            nextHurdle = time + .random(in: 4.5...9)
        } else if speed <= 70, let due = nextHurdle, due < time {
            nextHurdle = time + .random(in: 1...3)
        }

        props.removeAll { prop in
            prop.worldX - scroll < -40
        }
        // 부딪힐 장애물에 몸 앞이 닿으면 고른 부딪힘이 터지고 장애물은 사라진다
        if body.width > 0, let index = props.firstIndex(where: { $0.bumps && $0.worldX - scroll <= body.maxX - body.width * 0.15 }) {
            let prop = props.remove(at: index)
            let height: CGFloat = if case .hurdle(let sprite) = prop.kind { sprite.size.height } else { 10 }
            for part in GameFX.crash(GameDecor.shared.equipped(.crash)) {
                puffs.append(Puff(spray: part.spray, worldX: prop.worldX + part.offset.x, y: body.maxY - height / 2 - part.offset.y,
                                  at: time, zoom: 1))
            }
            onBump()
        }
        puffs.removeAll { time - $0.at > Double($0.spray.life) + 0.1 }

        if let due = nextFlyer, time >= due {
            let night = Sky.isNight(Sky.hourOverride ?? Calendar.current.component(.hour, from: Date()))
            // 낮에는 새가 날거나 가끔 슬라임이 땅을 지나가고, 밤에는 별똥별이 떨어진다
            let kind: Flyer.Kind = night ? .shootingStar : (Double.random(in: 0...1) < 0.3 ? .slime : .birds)
            flyers.append(Flyer(kind: kind, at: time, y: .random(in: 16...44), seed: .random(in: 0...1)))
            nextFlyer = time + (night ? .random(in: 5...11) : .random(in: 10...20))
        }
        flyers.removeAll { time - $0.at > ($0.kind == .shootingStar ? 1.2 : 16) }

        // 머리가 무대 위로 넘치지 않을 만큼만 뛴다 (직전 몸 자리는 직전 높이만큼 떠 있었다)
        let room = max(0, body.minY + lastHop - 8)
        lastHop = min(hop(scroll: scroll), room)
        return lastHop
    }

    /// 앞에 있는 장애물을 넘는 높이. 몸 앞이 장애물에 닿기 조금 전에 떠서 몸 뒤가 지나면 내려온다.
    private func hop(scroll: CGFloat) -> CGFloat {
        guard body.width > 0 else { return 0 }
        for prop in props where !prop.bumps {
            guard case .hurdle(let sprite) = prop.kind else { continue }
            let x = prop.worldX - scroll
            let half = sprite.size.width / 2
            let start = body.maxX + 18 + half
            let end = body.minX + body.width * 0.25 - half
            guard x < start, x > end else { continue }
            let p = (start - x) / (start - end)
            return sin(p * .pi) * (sprite.size.height + 12)
        }
        return 0
    }

    /// 발이 땅에 닿을 때마다(한 주기에 두 번) 먼지를 일으키고, 뛰었다 내려오면 크게 일으킨다.
    func step(gait: CGFloat, time: Double, scroll: CGFloat, feet: CGPoint, airborne: Bool, speed: CGFloat) {
        let step = Int(floor(gait * 2))
        defer {
            lastStep = step
            wasAirborne = airborne
        }
        // 발먼지를 고르지 않았으면 먼지를 일으키지 않는다
        guard let dust = GameDecor.shared.equipped(.dust) else { return }
        if wasAirborne && !airborne {
            puffs.append(Puff(spray: GameFX.dust(dust, landing: true), worldX: scroll + feet.x, y: feet.y, at: time,
                              zoom: 1.6))
            return
        }
        guard !airborne, speed > 12, step != lastStep else { return }
        puffs.append(Puff(spray: GameFX.dust(dust, landing: false), worldX: scroll + feet.x, y: feet.y, at: time,
                          zoom: 1.3))
    }

    /// 이번 장면의 러너 몸 (화면 좌표). 꼬리를 달았으면 등 자리를 땅 좌표로 남긴다.
    func record(back: CGPoint, scroll: CGFloat, speed: CGFloat, body: CGRect) {
        self.body = body
        guard GameDecor.shared.equipped(.trail) != nil, speed > 12 else {
            if !trail.isEmpty { trail.removeFirst() }
            return
        }
        trail.append((scroll + back.x, back.y))
        // 땅 좌표 기준으로 몸 길이 두 배쯤만 남긴다
        trail.removeAll { scroll + back.x - $0.worldX > 150 }
        if trail.count > 40 { trail.removeFirst(trail.count - 40) }
    }

    // MARK: 그리기

    /// 하늘: 새 떼, 별똥별. 배경 바로 위, 땅보다 먼저.
    func drawSky(_ cg: CGContext, size: CGSize, sky: Sky, time: Double) {
        for flyer in flyers {
            let age = time - flyer.at
            switch flyer.kind {
            case .birds: drawBirds(cg, size: size, sky: sky, age: age, y: flyer.y, seed: flyer.seed)
            case .shootingStar: drawShootingStar(cg, size: size, age: age, y: flyer.y, seed: flyer.seed)
            case .slime: drawSlime(cg, size: size, age: age, seed: flyer.seed)
            }
        }
    }

    /// 땅: 장애물, 코인, 꼬리, 발먼지. 러너보다 먼저.
    func drawGround(_ cg: CGContext, groundY: CGFloat, scroll: CGFloat, time: Double) {
        for prop in props {
            let x = prop.worldX - scroll
            switch prop.kind {
            case .hurdle(let sprite):
                guard let image = sprite.frame(at: time) else { continue }
                let scale = sprite.scale
                let content = sprite.content
                let rect = CGRect(x: x - CGFloat(image.width) * scale / 2, y: groundY - content.maxY * scale + 1,
                                  width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                cg.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
                cg.fillEllipse(in: CGRect(x: x - sprite.size.width * 0.45, y: groundY - 2, width: sprite.size.width * 0.9, height: 4))
                GameAssets.draw(image, in: rect, cg)
            }
        }
        if let item = GameDecor.shared.equipped(.trail), trail.count > 1 {
            GameFX.drawTrail(item, points: trail.map { CGPoint($0.worldX - scroll, $0.y) }, time: time, cg)
        }
        for puff in puffs {
            let origin = CGPoint(puff.worldX - scroll, puff.y)
            cg.saveGState()
            cg.translateBy(x: origin.x, y: origin.y)
            cg.scaleBy(x: puff.zoom, y: puff.zoom)
            cg.translateBy(x: -origin.x, y: -origin.y)
            GameFX.drawSpray(puff.spray, from: origin, age: CGFloat(time - puff.at), time: time, cg)
            cg.restoreGState()
        }
    }

    func pat(at time: Double) {
        pats.append(time)
    }

    /// 앞: 쓰다듬을 때 피는 하트. 러너 위에 그린다.
    func drawFront(_ cg: CGContext, groundY: CGFloat, scroll: CGFloat, time: Double) {
        pats.removeAll { time - $0 > 1.6 }
        for (n, at) in pats.enumerated() where !body.isEmpty {
            let top = CGPoint(body.midX + body.width * 0.1, body.minY + body.height * 0.12)
            for k in 0..<3 {
                let age = CGFloat(time - at) - CGFloat(k) * 0.14
                guard age > 0, age < 1.2 else { continue }
                let k1 = age / 1.2
                let seed = CGFloat((n * 3 + k) % 5) - 2
                let x = top.x + seed * 7 + sin(age * 7 + CGFloat(k)) * 4
                let y = top.y - 8 - k1 * 46
                let pop = min(1, age / 0.18)
                GameFX.drawSprite("pumpingHeart", at: CGPoint(x, y), height: (9 + CGFloat(k) * 2) * pop, progress: 0,
                                  time: time + Double(k) * 0.2, alpha: 1 - k1 * k1, cg)
            }
        }
    }

    /// 새 떼: 화면 오른쪽에서 왼쪽으로 날갯짓하며 지나간다 (Mantis 새 그림, CC0). 떼마다 색이 다르다.
    private func drawBirds(_ cg: CGContext, size: CGSize, sky: Sky, age: Double, y: CGFloat, seed: CGFloat) {
        let speed: CGFloat = 34 + seed * 14
        let leadX = size.width + 20 - CGFloat(age) * speed
        let kinds = ["birdYellow", "birdRed", "birdPurple", "birdMaroon"]
        let name = kinds[Int(seed * 100) % kinds.count]
        let offsets: [(dx: CGFloat, dy: CGFloat, s: CGFloat)] = [(0, 0, 1), (16, -7, 0.8), (18, 8, 0.85)]
        for (i, o) in offsets.enumerated() {
            let c = CGPoint(leadX + o.dx, y + o.dy + CGFloat(sin(age * 1.3 + Double(i))) * 2)
            GameFX.drawSprite(name, at: c, height: 12 * o.s, progress: 0, time: age * 1.4 + Double(i) * 0.3, flip: true, cg)
        }
    }

    /// 슬라임: 땅 위를 통통 튀며 오른쪽에서 왼쪽으로 지나간다 (Graveheartart, CC0).
    private func drawSlime(_ cg: CGContext, size: CGSize, age: Double, seed: CGFloat) {
        let x = size.width + 20 - CGFloat(age) * (22 + seed * 8)
        let hop = abs(sin(age * 3.2)) * 5
        GameFX.drawSprite("slime", at: CGPoint(x, size.height - 15 - 7 - hop), height: 15, progress: 0, time: age * 0.8,
                          flip: true, cg)
    }

    /// 별똥별: 오른쪽 위에서 왼쪽 아래로 빛줄기가 짧게 지나가고 사라진다 (Cethiel 빛 그림, CC0).
    private func drawShootingStar(_ cg: CGContext, size: CGSize, age: Double, y: CGFloat, seed: CGFloat) {
        let life = 0.9
        guard age < life else { return }
        let t = CGFloat(age / life)
        let start = CGPoint(size.width * (0.55 + seed * 0.4), y - 6)
        let head = CGPoint(start.x - 0.92 * 120 * t, start.y + 0.38 * 120 * t)
        GameFX.drawSprite("pure", at: head, height: 16, progress: min(t * 1.4, 0.99), time: age,
                          alpha: t < 0.7 ? 1 : (1 - t) / 0.3, rotation: -0.39, flip: true, cg)
    }

}

extension Sky {
    static func isNight(_ hour: Int) -> Bool { hour >= 20 || hour < 5 }
}
