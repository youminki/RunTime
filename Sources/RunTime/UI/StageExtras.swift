import AppKit
import GameCore

/// 팝오버 무대에서 러너가 달리는 동안 생기는 일들. 길 위 코인을 줍고, 빠를 때는 작은 장애물을 뛰어넘고,
/// 발을 디딜 때마다 상점 발먼지가 일고 등 뒤로 상점 꼬리가 끌린다. 하늘에는 시간대에 맞는 새나 별똥별이 지나간다.
/// 자리는 모두 땅 좌표(scroll 기준)로 두어 배경과 같은 속도로 흘러간다.
final class StageExtras {
    private enum Kind { case coin, hurdle(GameSprite) }

    private struct Prop {
        let kind: Kind
        /// 땅 좌표 x (화면 x = worldX - scroll).
        let worldX: CGFloat
        /// 땅에서 위로 띄운 높이.
        let height: CGFloat
        var takenAt: Double?
    }

    private struct Puff {
        let spray: GameFX.Spray
        let worldX: CGFloat
        let y: CGFloat
        let at: Double
        let zoom: CGFloat
    }

    private struct Flyer {
        enum Kind { case birds, shootingStar }
        let kind: Kind
        let at: Double
        let y: CGFloat
        let seed: CGFloat
    }

    private var props: [Prop] = []
    private var puffs: [Puff] = []
    private var flyers: [Flyer] = []
    private var trail: [(worldX: CGFloat, y: CGFloat)] = []
    private var nextCoins: Double?
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
        nextCoins = nil
        nextHurdle = nil
    }

    // MARK: 갱신

    /// 이번 프레임에 러너가 뛰어오를 높이(pt)를 돌려준다.
    func update(time: Double, scroll: CGFloat, speed: CGFloat, size: CGSize, active: Bool) -> CGFloat {
        let right = scroll + size.width + 24
        if nextCoins == nil { nextCoins = time + 2 }
        if nextHurdle == nil { nextHurdle = time + 0.3 }
        if nextFlyer == nil { nextFlyer = time + 2.5 }

        // 장애물 위 코인과 겹치지 않게 가까이 장애물이 있으면 다음으로 미룬다
        let hurdleNear = props.contains { if case .hurdle = $0.kind { return $0.worldX > right - 200 } else { return false } }
        if active, speed > 12, !hurdleNear, let due = nextCoins, time >= due {
            // 3~5개를 한 줄이나 낮은 무지개 모양으로 늘어놓는다
            let count = Int.random(in: 3...5)
            let arch = Bool.random()
            for i in 0..<count {
                let k = CGFloat(i) / CGFloat(max(count - 1, 1))
                let lift = arch ? 30 + sin(k * .pi) * 22 : 34
                props.append(Prop(kind: .coin, worldX: right + CGFloat(i) * 22, height: lift))
            }
            nextCoins = time + .random(in: 3.5...7)
        }
        // 장애물은 빨리 달릴 때만. 느리면 한 번 뛰는 데 너무 오래 떠 있다
        if active, speed > 70, let due = nextHurdle, time >= due {
            let sprite: GameSprite = [.mushroom, .cactus, .spikes].randomElement() ?? .mushroom
            let x = right + 10
            props.append(Prop(kind: .hurdle(sprite), worldX: x, height: 0))
            // 뛰어오른 꼭대기에서 먹게 장애물 위에 코인 셋
            for i in -1...1 {
                props.append(Prop(kind: .coin, worldX: x + CGFloat(i) * 22, height: 64 - abs(CGFloat(i)) * 8))
            }
            nextHurdle = time + .random(in: 4.5...9)
            nextCoins = max(nextCoins ?? time, time + 2.5)
        } else if speed <= 70, let due = nextHurdle, due < time {
            nextHurdle = time + .random(in: 1...3)
        }

        // 몸에 닿은 코인은 줍는다
        for i in props.indices where props[i].takenAt == nil {
            guard case .coin = props[i].kind else { continue }
            let x = props[i].worldX - scroll
            if x < body.maxX - body.width * 0.25 && x > body.minX { props[i].takenAt = time }
        }
        props.removeAll { prop in
            if let taken = prop.takenAt { return time - taken > 0.5 }
            return prop.worldX - scroll < -40
        }
        puffs.removeAll { time - $0.at > Double($0.spray.life) + 0.1 }

        if let due = nextFlyer, time >= due {
            let night = Sky.isNight(Sky.hourOverride ?? Calendar.current.component(.hour, from: Date()))
            flyers.append(Flyer(kind: night ? .shootingStar : .birds, at: time, y: .random(in: 16...44),
                                seed: .random(in: 0...1)))
            nextFlyer = time + (night ? .random(in: 5...11) : .random(in: 10...20))
        }
        flyers.removeAll { time - $0.at > ($0.kind == .birds ? 14 : 1.2) }

        // 머리가 무대 위로 넘치지 않을 만큼만 뛴다 (직전 몸 자리는 직전 높이만큼 떠 있었다)
        let room = max(0, body.minY + lastHop - 8)
        lastHop = min(hop(scroll: scroll), room)
        return lastHop
    }

    /// 앞에 있는 장애물을 넘는 높이. 몸 앞이 장애물에 닿기 조금 전에 떠서 몸 뒤가 지나면 내려온다.
    private func hop(scroll: CGFloat) -> CGFloat {
        guard body.width > 0 else { return 0 }
        for prop in props {
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
        let dust = GameWallet.shared.equipped(.dust)
        if wasAirborne && !airborne {
            puffs.append(Puff(spray: GameFX.dust(dust, landing: true), worldX: scroll + feet.x, y: feet.y, at: time,
                              zoom: dust?.art == nil ? 2.4 : 1.6))
            return
        }
        guard !airborne, speed > 12, step != lastStep else { return }
        puffs.append(Puff(spray: GameFX.dust(dust, landing: false), worldX: scroll + feet.x, y: feet.y, at: time,
                          zoom: dust?.art == nil ? 1.8 : 1.3))
    }

    /// 꼬리를 달았으면 등 자리를 땅 좌표로 남긴다.
    func record(back: CGPoint, scroll: CGFloat, speed: CGFloat, body: CGRect) {
        self.body = body
        guard GameWallet.shared.equipped(.trail) != nil, speed > 12 else {
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
            case .coin:
                guard prop.takenAt == nil, let image = GameSprite.coin.frame(at: time + Double(prop.worldX) * 0.01) else { continue }
                // 제자리에서 살짝 떠오르내린다
                let bob = sin(time * 4 + Double(prop.worldX) * 0.05) * 1.5
                let y = groundY - prop.height + CGFloat(bob)
                GameAssets.draw(image, in: CGRect(x: x - 8, y: y - 8, width: 16, height: 16), cg)
            }
        }
        if let item = GameWallet.shared.equipped(.trail), trail.count > 1 {
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

    /// 앞: 주운 코인이 위로 튀며 사라지고 반짝인다. 러너 위에 그린다.
    func drawFront(_ cg: CGContext, groundY: CGFloat, scroll: CGFloat, time: Double) {
        for prop in props {
            guard case .coin = prop.kind, let taken = prop.takenAt else { continue }
            let age = CGFloat(time - taken)
            let x = prop.worldX - scroll
            let y = groundY - prop.height - age * 70 + age * age * 60
            let alpha = max(0, 1 - age / 0.5)
            if let image = GameSprite.coin.frame(at: time * 3) {
                cg.saveGState()
                cg.setAlpha(alpha)
                let s = 16 * (1 - age * 0.6)
                GameAssets.draw(image, in: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s), cg)
                cg.restoreGState()
            }
            // 줍는 순간 네 갈래 반짝임이 한 번 커졌다 줄어든다
            let flash = sin(min(1, age / 0.3) * .pi)
            SpriteEffects.sparkle(cg, at: CGPoint(x + 7, groundY - prop.height - 6), radius: 6 * flash,
                                  color: NSColor(hex: 0xFFF3B0).withAlphaComponent(0.95))
        }
    }

    /// 새 떼: 화면 오른쪽에서 왼쪽으로 날아가며 날갯짓한다. 하늘색보다 짙은 실루엣.
    private func drawBirds(_ cg: CGContext, size: CGSize, sky: Sky, age: Double, y: CGFloat, seed: CGFloat) {
        let speed: CGFloat = 34 + seed * 14
        let leadX = size.width + 20 - CGFloat(age) * speed
        let color = (sky.top.blended(withFraction: 0.65, of: NSColor(hex: 0x1A1F33)) ?? .black).withAlphaComponent(0.75)
        cg.saveGState()
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(1.3)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        let offsets: [(dx: CGFloat, dy: CGFloat, s: CGFloat)] = [(0, 0, 1), (13, -6, 0.8), (15, 7, 0.85)]
        for (i, o) in offsets.enumerated() {
            let c = CGPoint(leadX + o.dx, y + o.dy + CGFloat(sin(age * 1.3 + Double(i))) * 2)
            let flap = CGFloat(sin(age * 9 + Double(i) * 1.7))
            let w = 5.5 * o.s
            let tip = c.y - flap * 3.2 * o.s
            cg.move(to: CGPoint(c.x - w, tip))
            cg.addQuadCurve(to: c, control: CGPoint(c.x - w * 0.45, c.y - 2.4 * o.s))
            cg.addQuadCurve(to: CGPoint(c.x + w, tip), control: CGPoint(c.x + w * 0.45, c.y - 2.4 * o.s))
        }
        cg.strokePath()
        cg.restoreGState()
    }

    /// 별똥별: 오른쪽 위에서 왼쪽 아래로 짧게 긋고 사라진다.
    private func drawShootingStar(_ cg: CGContext, size: CGSize, age: Double, y: CGFloat, seed: CGFloat) {
        let life = 0.9
        guard age < life else { return }
        let t = CGFloat(age / life)
        let start = CGPoint(size.width * (0.55 + seed * 0.4), y - 6)
        let direction = CGPoint(-0.92, 0.38)
        let travel = 120 * t
        let head = CGPoint(start.x + direction.x * travel, start.y + direction.y * travel)
        let length = 34 * min(1, t * 3)
        let tail = CGPoint(head.x - direction.x * length, head.y - direction.y * length)
        let alpha = t < 0.7 ? 1 : (1 - t) / 0.3
        cg.saveGState()
        let path = CGMutablePath()
        path.move(to: tail)
        path.addLine(to: head)
        cg.addPath(path)
        cg.setLineWidth(1.4)
        cg.setLineCap(.round)
        cg.replacePathWithStrokedPath()
        cg.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [NSColor.white.withAlphaComponent(0).cgColor,
                                              NSColor.white.withAlphaComponent(0.95 * alpha).cgColor] as CFArray,
                                     locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: tail, end: head, options: [])
        }
        cg.restoreGState()
        cg.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        cg.fillEllipse(in: CGRect(x: head.x - 1.3, y: head.y - 1.3, width: 2.6, height: 2.6))
    }
}

extension Sky {
    static func isNight(_ hour: Int) -> Bool { hour >= 20 || hour < 5 }
}
