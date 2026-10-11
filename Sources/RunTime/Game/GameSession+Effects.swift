import AppKit
import GameCore

/// 능력·꾸미기·파티클 같은 화면 효과.
extension GameSession {
    static func fillHeart(_ cg: CGContext, at c: CGPoint, size s: CGFloat, color: NSColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(c.x, c.y + s * 0.35))
        path.addCurve(to: CGPoint(c.x - s * 0.5, c.y - s * 0.1), control1: CGPoint(c.x - s * 0.1, c.y + s * 0.1),
                      control2: CGPoint(c.x - s * 0.5, c.y + s * 0.15))
        path.addArc(center: CGPoint(c.x - s * 0.25, c.y - s * 0.12), radius: s * 0.25, startAngle: .pi, endAngle: 0,
                    clockwise: false)
        path.addArc(center: CGPoint(c.x + s * 0.25, c.y - s * 0.12), radius: s * 0.25, startAngle: .pi, endAngle: 0,
                    clockwise: false)
        path.addCurve(to: CGPoint(c.x, c.y + s * 0.35), control1: CGPoint(c.x + s * 0.5, c.y + s * 0.15),
                      control2: CGPoint(c.x + s * 0.1, c.y + s * 0.1))
        cg.setFillColor(color.cgColor)
        cg.addPath(path)
        cg.fillPath()
    }

    // MARK: 능력

    /// 보호막 방울과 글라이드 날개. 내 러너에만.
    func drawAbilities(_ cg: CGContext, groundY: CGFloat, time: Double) {
        guard game.phase == .playing, entrance >= 1 else { return }
        let center = CGPoint(runnerLeft + CGFloat(Self.runnerWidth) / 2, groundY - CGFloat(game.runnerY + Self.runnerHeight / 2))
        cg.saveGState()
        if game.shieldsLeft > 0 {
            let pulse = 1 + 0.04 * CGFloat(sin(time * 5))
            for k in 0..<game.shieldsLeft {
                let r = (27 + CGFloat(k) * 4) * pulse
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                cg.setFillColor(NSColor(hex: 0x8FD3FF).withAlphaComponent(k == 0 ? 0.08 : 0).cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(NSColor(hex: 0x8FD3FF).withAlphaComponent(0.55 - CGFloat(k) * 0.15).cgColor)
                cg.setLineWidth(1.2)
                cg.strokeEllipse(in: rect)
            }
        }
        if game.isGliding {
            // 머리 위 낙하산
            let top = CGPoint(center.x - 2, center.y - 40)
            let canopy = CGMutablePath()
            canopy.addArc(center: CGPoint(top.x, top.y + 6), radius: 17, startAngle: .pi * 1.08, endAngle: .pi * 1.92,
                          clockwise: false)
            canopy.closeSubpath()
            cg.setFillColor(NSColor(hex: 0xFF8FB8).withAlphaComponent(0.9).cgColor)
            cg.addPath(canopy)
            cg.fillPath()
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            cg.setLineWidth(0.8)
            for dx in [-14.0, 0, 14] {
                cg.move(to: CGPoint(top.x + CGFloat(dx), top.y + 1))
                cg.addLine(to: CGPoint(center.x - 2, center.y - 14))
            }
            cg.strokePath()
        }
        cg.restoreGState()
    }

    // MARK: 꾸미기

    /// 발을 디딜 때 먼지. 상점 발먼지를 달면 그 색과 모양으로.
    func dust(at feet: CGPoint, landing: Bool) {
        spray(GameFX.dust(GameWallet.shared.equipped(.dust), landing: landing), at: feet)
    }

    /// 부딪힌 순간. 기본은 흰 점, 상점 효과를 달면 그 모양으로 터진다.
    func crashBurst(at center: CGPoint) {
        for part in GameFX.crash(GameWallet.shared.equipped(.crash)) {
            // offset의 y는 위로 + (입자 좌표처럼 바닥 위 높이)
            spray(part.spray, at: CGPoint(center.x + part.offset.x, center.y + part.offset.y))
        }
    }

    func spray(_ spray: GameFX.Spray, at point: CGPoint) {
        burst(at: point, count: spray.count, colors: spray.colors, shape: spray.shape, speed: spray.speed, life: spray.life,
              drift: spray.drift, spread: spray.spread, size: spray.size, gravity: -spray.gravity)
    }

    func updateTrail(_ k: CGFloat) {
        guard game.phase == .playing, GameWallet.shared.equipped(.trail) != nil else {
            if !trail.isEmpty { trail.removeFirst() }
            return
        }
        let shift = CGFloat(game.speed) * k
        for i in trail.indices { trail[i].x -= shift }
        let height = Self.runnerHeight * (game.isDucking ? 0.3 : 0.45)
        trail.append(CGPoint(runnerLeft + 2, CGFloat(game.runnerY + height)))
        if trail.count > 22 { trail.removeFirst(trail.count - 22) }
    }

    func drawTrail(_ cg: CGContext, groundY: CGFloat, time: Double) {
        guard let item = GameWallet.shared.equipped(.trail) else { return }
        GameFX.drawTrail(item, points: trail.map { CGPoint($0.x, groundY - $0.y) }, time: time, cg)
    }

    // MARK: 동료

    /// 데려간 Petdex 펫. 점검 도구는 저장하지 않고 바꿔 본다.
    var companion: RunnerCharacter? { companionOverride ?? GameWallet.shared.companion }

    /// 동료는 러너 뒤에서 조금 늦게 따라 뛴다. 러너 높이를 0.15초 늦춰 쓴다 (화면 주사율과 상관없이).
    func updateBuddy() {
        guard companion != nil else {
            buddyHeights.removeAll()
            return
        }
        buddyHeights.append((clock, game.phase == .playing ? game.runnerY : 0))
        while buddyHeights.count > 1, clock - buddyHeights[1].time >= Self.buddyDelay { buddyHeights.removeFirst() }
    }

    static let buddyDelay = 0.15

    func drawBuddy(_ cg: CGContext, groundY: CGFloat, time: Double) {
        guard let companion, entrance >= 1 else { return }
        let lift = CGFloat(buddyHeights.first?.height ?? 0)
        let x = runnerLeft - 20
        // 그림자
        let shadow = 16 * (1 - min(lift / 120, 0.6))
        cg.setFillColor(NSColor.black.withAlphaComponent(0.22 * (1 - min(lift / 90, 0.8))).cgColor)
        cg.fillEllipse(in: CGRect(x: x - shadow / 2, y: groundY - 2, width: shadow, height: 4))
        let running = game.phase == .playing
        // 보폭 50pt마다 한 걸음, 서 있으면 숨 쉬기
        let phase = running ? CGFloat(game.distance / 50) : CGFloat(time / 2.4)
        GameFX.drawCompanion(companion, feet: CGPoint(x, groundY - lift), height: 24, phase: phase, moving: running, cg)
    }

    // MARK: 화면 효과

    /// 바닥 위 높이(y 위로)로 잰 점 주변에 작은 점을 흩뿌린다.
    func burst(at point: CGPoint, count: Int, color: NSColor, speed: CGFloat, life: CGFloat, drift: CGFloat) {
        burst(at: point, count: count, colors: [color], speed: speed, life: life, drift: drift)
    }

    /// `spread`가 1이면 위쪽 반원, 2면 사방으로 흩어진다.
    func burst(at point: CGPoint, count: Int, colors: [NSColor], shape: GameFX.Shape = .dot, speed: CGFloat,
                       life: CGFloat, drift: CGFloat, spread: CGFloat = 1, size: ClosedRange<CGFloat> = 1.4...2.6,
                       gravity: CGFloat = -220) {
        for i in 0..<count {
            let angle = CGFloat(i) / CGFloat(count) * .pi * spread + .pi * 0.05 + CGFloat.random(in: -0.2...0.2)
            let v = speed * CGFloat.random(in: 0.6...1.1)
            particles.append(Particle(position: point, velocity: CGPoint(-cos(angle) * v, sin(angle) * v),
                                      gravity: gravity, life: life * CGFloat.random(in: 0.7...1), total: life,
                                      color: colors[i % colors.count], size: CGFloat.random(in: size), drift: drift,
                                      shape: shape))
        }
    }

    struct Particle {
        var position: CGPoint   // x는 화면, y는 바닥 위 높이
        var velocity: CGPoint
        var gravity: CGFloat
        var life: CGFloat
        let total: CGFloat
        let color: NSColor
        let size: CGFloat
        /// 땅을 따라 뒤로 흘러가는 정도 (먼지 1, 터지는 별 0).
        let drift: CGFloat
        var shape: GameFX.Shape = .dot
        /// 0~1 고정 값. 입자마다 다르게 돌린다.
        let seed = CGFloat.random(in: 0...1)
    }

    struct Popup {
        let text: String
        var position: CGPoint
        var life: CGFloat
    }
}
