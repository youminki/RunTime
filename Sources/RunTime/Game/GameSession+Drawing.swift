import AppKit
import GameCore
import SwiftUI

/// 장애물, 코인, 러너, 고스트를 그린다.
extension GameSession {
    // MARK: 그리기

    func screenX(_ worldX: Double) -> CGFloat { Self.runnerX + CGFloat(worldX - game.distance) }

    /// 지금 러너 왼쪽 끝의 화면 x (←→로 움직인 만큼).
    var runnerLeft: CGFloat { Self.runnerX + CGFloat(game.runnerOffset) }

    /// 무대가 열린 뒤 게임 화면으로 넘어가는 정도 (0~1). 러너가 작아지며 왼쪽으로 간다.
    var entrance: CGFloat {
        let t = min(1, CGFloat(clock) / 0.45)
        return t * t * (3 - 2 * t)
    }

    /// 화면 흔들림. 부딪힌 순간에만.
    var shakeOffset: CGPoint {
        guard shake > 0 else { return .zero }
        let a = shake * shake * 4
        return CGPoint(CGFloat.random(in: -a...a), CGFloat.random(in: -a...a))
    }

    /// 장애물, 코인, 러너, 파티클. 배경은 무대가 먼저 그린다.
    func drawWorld(_ cg: CGContext, size: CGSize, groundY: CGFloat, stageAnchorX: CGFloat, stageScale: CGFloat,
                   theme: SpriteTheme, time: Double) {
        let ground = { (height: Double) in groundY - CGFloat(height) }
        self.groundY = groundY

        // 코인
        for coin in game.coins where !coin.taken {
            let x = screenX(coin.x)
            guard x > -20, x < size.width + 20, let image = GameSprite.coin.frame(at: time + coin.x * 0.01) else { continue }
            let bob = CGFloat(sin(time * 5 + coin.x * 0.05)) * 1.5
            let s = GameSprite.pixelScale
            let rect = CGRect(x: x - 9 * s, y: ground(coin.y) - 9 * s + bob, width: 18 * s, height: 18 * s)
            GameAssets.draw(image, in: rect, cg)
        }

        // 장애물
        for obstacle in game.obstacles {
            guard let sprite = GameSprite(rawValue: obstacle.kind.id) else { continue }
            let left = screenX(obstacle.x)
            guard left < size.width + 40, left + CGFloat(obstacle.width) > -40 else { continue }
            let content = sprite.content
            let s = sprite.scale
            let frames = sprite.frames
            let phase = time + Double(obstacle.id) * 0.13
            for k in 0..<obstacle.count {
                // 내리찍는 상자는 떠 있는 동안 다리를 접은 모습
                let airborne = obstacle.kind.dropFrom != nil && obstacle.y > 0
                guard let image = airborne ? GameAssets.image("crusher_fall") : frames.isEmpty ? nil : sprite.frame(at: phase)
                else { continue }
                // 판정 상자(그림 영역)에 맞춰 타일 전체를 놓는다
                let boxLeft = left + CGFloat(k) * CGFloat(obstacle.kind.width)
                let boxBottom = ground(obstacle.y)
                let rect = CGRect(x: boxLeft - content.minX * s,
                                  y: boxBottom - content.maxY * s,
                                  width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
                if sprite == .spikeball {
                    // 다가오는 만큼 굴러간다 (반지름으로 나눈 이동 거리)
                    let roll = -CGFloat(game.distance - obstacle.x) / (CGFloat(obstacle.kind.width) / 2)
                    cg.saveGState()
                    cg.translateBy(x: rect.midX, y: rect.midY)
                    cg.rotate(by: roll)
                    cg.translateBy(x: -rect.midX, y: -rect.midY)
                    GameAssets.draw(image, in: rect, cg)
                    cg.restoreGState()
                } else {
                    GameAssets.draw(image, in: rect, cg)
                }
            }
            if obstacle.id == game.crashedInto {
                cg.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.8).cgColor)
                cg.setLineWidth(1.5)
                cg.stroke(CGRect(x: left - 2, y: ground(obstacle.y) - CGFloat(obstacle.height) - 2,
                                 width: CGFloat(obstacle.width) + 4, height: CGFloat(obstacle.height) + 4))
            }
        }

        // 다음 목표 깃발
        if let x = flagX(), x > -10, x < size.width + 10 {
            cg.setStrokeColor(NSColor(white: 0.92, alpha: 0.9).cgColor)
            cg.setLineWidth(1.5)
            cg.move(to: CGPoint(x, groundY))
            cg.addLine(to: CGPoint(x, groundY - 46))
            cg.strokePath()
            let wave = CGFloat(sin(time * 8)) * 1.5
            cg.setFillColor(NSColor(hex: 0xFF6B5E).cgColor)
            cg.move(to: CGPoint(x, groundY - 46))
            cg.addLine(to: CGPoint(x + 15, groundY - 41 + wave))
            cg.addLine(to: CGPoint(x, groundY - 36))
            cg.closePath()
            cg.fillPath()
        }

        if let ghost = ghost?.game {
            let left = Self.runnerX + CGFloat(ghost.distance + ghost.runnerOffset - game.distance)
            if left > -60, left < size.width + 20 {
                cg.saveGState()
                cg.setAlpha(0.38)
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
                drawRunner(cg, ghost, character: ghostCharacter, left: left, groundY: groundY, stageAnchorX: stageAnchorX,
                           stageScale: stageScale, theme: ghostCharacter.theme(.natural), time: time)
                cg.endTransparencyLayer()
                cg.restoreGState()
            }
        }
        drawTrail(cg, groundY: groundY, time: time)
        drawBuddy(cg, groundY: groundY, time: time)
        // 보호막이 깨진 뒤 지나가는 동안은 깜빡인다
        let blink = game.invulnerable > 0 && Int(time * 18) % 2 == 0
        cg.saveGState()
        if blink { cg.setAlpha(0.35) }
        drawRunner(cg, game, character: character, left: runnerLeft, groundY: groundY, stageAnchorX: stageAnchorX, stageScale: stageScale,
                   theme: theme, time: time)
        cg.restoreGState()
        drawAbilities(cg, groundY: groundY, time: time)

        // 파티클
        for p in particles {
            let alpha = max(0, min(1, p.life / p.total))
            GameFX.drawParticle(p.shape, color: p.color, at: CGPoint(p.position.x, ground(Double(p.position.y))), size: p.size,
                                alpha: alpha, progress: 1 - alpha, seed: p.seed, time: time, cg)
        }

        // 먹은 코인이 왼쪽 위 코인 수로 날아간다
        let target = CGPoint(30, 49)
        for flyer in coinFlyers {
            let t = min(1, flyer.t)
            let e = t * t
            let x = flyer.from.x + (target.x - flyer.from.x) * e
            let y = flyer.from.y + (target.y - flyer.from.y) * e - sin(t * .pi) * 18
            let size = 12 - 5 * t
            if let image = GameSprite.coin.frame(at: time) {
                GameAssets.draw(image, in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size), cg)
            }
        }

        // 빠를수록 바람이 보인다
        if game.phase == .playing, game.speed > 400 {
            let strength = CGFloat((game.speed - 400) / (game.tuning.maxSpeed - 400))
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.18 + 0.2 * strength).cgColor)
            cg.setLineWidth(1)
            cg.setLineCap(.round)
            for i in 0..<5 {
                let span = size.width + 80
                let raw = Double(i) * 97.3 - game.distance * 1.6
                let x = CGFloat(raw - floor(raw / Double(span)) * Double(span)) - 40
                let y = 18 + CGFloat(i) * (groundY - 40) / 5
                cg.move(to: CGPoint(x, y))
                cg.addLine(to: CGPoint(x + 18 + 20 * strength, y))
            }
            cg.strokePath()
        }

        if flash > 0 {
            cg.setFillColor(NSColor.white.withAlphaComponent(flash * 0.35).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 러너 하나 (내 러너 또는 고스트). 무대에서 게임으로 넘어가는 움직임은 내 러너에만 준다.
    func drawRunner(_ cg: CGContext, _ game: RunnerGame, character: RunnerCharacter, left: CGFloat, groundY: CGFloat,
                            stageAnchorX: CGFloat, stageScale: CGFloat, theme: SpriteTheme, time: Double) {
        let rig = character.rig
        var frame: MotionFrame
        switch game.phase {
        case .ready:
            frame = MotionFrame(pose: CharacterPose(activity: .stand, phase: CGFloat(time / 2.4)))
        case .playing where !game.isOnGround:
            frame = MotionFrame(pose: CharacterPose(activity: .run, phase: 0.62, speed: 1.2))
            // 오를 때 살짝 들고, 내려올 때 숙인다
            frame.transform.rotation = CGFloat(-game.velocityY / game.tuning.jumpVelocity) * 0.12
        case .playing:
            // 보폭 70pt마다 한 걸음 주기. 앞으로 움직이면 발이 빨라지고 몸을 앞으로 기울인다
            frame = MotionFrame(pose: CharacterPose(activity: .run, phase: CGFloat((game.distance + game.runnerOffset) / 70),
                                                    speed: 1.25))
            if game.isDucking { frame.transform.squash = 0.6 }
            if game === self.game, landBounce > 0 { frame.transform.squash = min(frame.transform.squash, 1 - 0.22 * landBounce) }
            frame.transform.rotation = CGFloat(game.moveDirection) * 0.08
        case .over:
            frame = MotionFrame(pose: CharacterPose(activity: .sit, phase: CGFloat(time / 1.1), mouthOpen: true))
            frame.effects = [.dizzyStars(CGFloat(time.truncatingRemainder(dividingBy: 1)))]
        }

        let gameScale = scale(for: character)
        let e = game === self.game ? entrance : 1
        let scale = stageScale + (gameScale - stageScale) * e
        let center = stageAnchorX + (left + CGFloat(Self.runnerWidth) / 2 - stageAnchorX) * e
        let feet = groundY - CGFloat(game.runnerY)

        var scene = CharacterScene(rig: rig, pose: frame.pose, transform: frame.transform)
        // 무대 높이 안으로 (뛰는 동안 머리가 잘리지 않게)
        let origin = CGPoint(center - FittedRig.targetCenterX * scale, feet - Stage.ground * scale)
        scene.fit(verticallyIn: (-origin.y / scale + 0.4)...((groundY + 15 - origin.y) / scale))

        // 그림자
        let lift = CGFloat(game.runnerY)
        let shadowW = CGFloat(Self.runnerWidth) * 1.3 * (1 - min(lift / 120, 0.6))
        cg.setFillColor(NSColor.black.withAlphaComponent(0.25 * (1 - min(lift / 90, 0.8))).cgColor)
        cg.fillEllipse(in: CGRect(x: center - shadowW / 2, y: groundY - 2.5, width: shadowW, height: 5))

        cg.saveGState()
        cg.translateBy(x: origin.x, y: origin.y)
        cg.scaleBy(x: scale, y: scale)
        let look = CharacterLook(rich: true, palette: theme.richPalette(rig.palette, phase: CGFloat(time / 6)),
                                 tint: .white, outline: 0.36)
        // 모자·안경·등 꾸미기는 내 러너에만 (고스트는 그 판의 모습만 남긴다)
        let mine = game === self.game
        let back = mine ? GameWallet.shared.equipped(.back) : nil
        GameFX.drawBack(back, on: scene, time: time, front: false, cg)
        scene.draw(in: cg, look: look)
        if mine {
            GameFX.drawAccessories(hat: GameWallet.shared.equipped(.hat), face: GameWallet.shared.equipped(.face), on: scene,
                                   time: time, cg)
        }
        GameFX.drawBack(back, on: scene, time: time, front: true, cg)
        for effect in frame.effects { effect.draw(in: cg, around: scene.placedBounds, tint: .white) }
        cg.restoreGState()
    }

    /// 서 있는 모습이 characterHeight × characterWidth 안에 들어가는 배율. 고양이·고래처럼 옆으로 긴 러너가
    /// 판정 상자보다 훨씬 크게 그려져 닿지 않았는데 부딪힌 것처럼 보이지 않게 한다.
    func scale(for character: RunnerCharacter) -> CGFloat {
        if let cached = scaleCache[character.key] { return cached }
        let bounds = CharacterScene(rig: character.rig, pose: CharacterPose(activity: .stand)).bounds
        let scale = bounds.isNull ? Self.characterHeight / FittedRig.targetHeight
            : min(Self.characterHeight / max(bounds.height, 1), Self.characterWidth / max(bounds.width, 1))
        scaleCache[character.key] = scale
        return scale
    }

    /// 패널 폭에 맞게 긴 닉네임은 자른다.
    static func shortName(_ name: String?) -> String {
        guard let name else { return "고스트" }
        return name.count > 6 ? name.prefix(6) + "…" : name
    }
}
