import AppKit

/// 한 순간의 모습: 자세 + 전체 변형 + 주변 효과.
struct MotionFrame {
    var pose: CharacterPose
    var transform = CharacterTransform()
    var effects: [MotionEffect] = []
}

/// 러너에 덧붙는 효과. 진행도(0~1)를 함께 받아 스스로 움직인다.
enum MotionEffect {
    case hearts(CGFloat)
    case notes(CGFloat)
    case question(CGFloat)        // 투명도
    case exclaim(CGFloat)         // 투명도
    case burst(CGFloat)
    /// 사용률 고리: 진행도, 채우기 시작과 끝 (0~1).
    case ring(CGFloat, from: CGFloat, to: CGFloat)
    case dizzyStars(CGFloat)
    case dots(CGFloat)
    case puff(CGFloat)
    case splash(CGFloat)
    case bubble(CGFloat)          // 코풍선: 0~0.85 부풀고 그 뒤 터진다
    case dream(CGFloat)
    case speedLines(CGFloat)
    case zzz(CGFloat)
}

/// 한 번 재생하고 끝나는 동작. 시간 함수라 메뉴바는 fps만큼 잘라 쓰고 팝오버는 매 프레임 계산한다.
enum Trick: String, CaseIterable {
    // 깨어 있을 때
    case hop, flip, spin, lookAround, love, sing, dance, stretch, blink, shake, sneeze, sparkle, doze, dizzy, zoom, wiggle
    // 상태가 바뀔 때
    case wakeUp, fallAsleep, celebrate
    // 잘 때
    case rollOver, snore, dream
    // 세션 사용률이 25·50·75%를 넘을 때
    case milestone25, milestone50, milestone75

    static let awake: [Trick] = [.hop, .flip, .spin, .lookAround, .love, .sing, .dance, .stretch, .blink, .blink,
                                 .shake, .sneeze, .sparkle, .doze, .dizzy, .zoom, .wiggle]
    static let asleep: [Trick] = [.rollOver, .snore, .dream]
    /// 팝오버에서 러너를 눌렀을 때.
    static let petting: [Trick] = [.hop, .flip, .spin, .love, .dance, .sparkle, .shake, .wiggle]

    var duration: TimeInterval {
        switch self {
        case .blink: return 0.6
        case .hop: return 0.9
        case .shake: return 1.0
        case .spin: return 1.0
        case .flip, .celebrate: return 1.15
        case .sneeze, .zoom, .wiggle: return 1.3
        case .stretch, .sparkle: return 1.5
        case .love: return 1.7
        case .lookAround, .sing, .dizzy: return 1.9
        case .dance: return 2.1
        case .doze, .rollOver: return 2.3
        case .wakeUp: return 1.7
        case .fallAsleep: return 1.9
        case .snore, .dream: return 2.8
        case .milestone25, .milestone50, .milestone75: return 1.9
        }
    }

    var label: String {
        switch self {
        case .hop: return "깡충"
        case .flip: return "공중제비"
        case .spin: return "빙글"
        case .lookAround: return "두리번"
        case .love: return "하트"
        case .sing: return "노래"
        case .dance: return "춤"
        case .stretch: return "기지개"
        case .blink: return "깜빡"
        case .shake: return "부르르"
        case .sneeze: return "에취"
        case .sparkle: return "팡"
        case .doze: return "꾸벅"
        case .dizzy: return "어질어질"
        case .zoom: return "슝"
        case .wiggle: return "실룩실룩"
        case .wakeUp: return "기상"
        case .fallAsleep: return "하품"
        case .celebrate: return "신남"
        case .rollOver: return "뒤척"
        case .snore: return "코풍선"
        case .dream: return "꿈"
        case .milestone25: return "세션 25%"
        case .milestone50: return "세션 50%"
        case .milestone75: return "세션 75%"
        }
    }

    /// 손 흔들기 줄 한 바퀴(초).
    private static let waveCycle: CGFloat = 0.9

    /// 진행도 t(0~1)의 모습.
    func frame(at t: CGFloat) -> MotionFrame {
        let seconds = t * CGFloat(duration)
        var stand = CharacterPose(activity: .stand, phase: seconds / 2.4)
        let sleep = CharacterPose(activity: .sleep, phase: seconds / 2.6, eyes: .closed)
        var f = MotionFrame(pose: stand)

        switch self {
        case .hop:
            f.transform = Self.jump(t, height: 3.6, start: 0.18, end: 0.74)
            if t > 0.18 && t < 0.74 { f.pose = CharacterPose(activity: .run, phase: 0.62, speed: 1) }

        case .flip, .celebrate:
            f.transform = Self.jump(t, height: 5, start: 0.16, end: 0.8)
            let spinT = smoothstep((t - 0.2) / 0.55)
            f.transform.rotation = -tau * spinT
            f.transform.pivotAtCenter = true
            if t > 0.16 && t < 0.8 { f.pose = CharacterPose(activity: .run, phase: 0.62, speed: 1) }
            f.pose.eyes = t > 0.75 ? .happy : .open
            // 착지하는 순간 터진다
            if self == .celebrate { f.effects = [.burst((t - 0.72) / 0.28)] }

        case .spin:
            let k = smoothstep(t)
            f.transform.scaleX = cos(tau * 2 * k)
            f.transform.offset.y = -1.8 * sin(.pi * t)
            f.pose.eyes = .happy

        case .lookAround:
            f.transform.scaleX = Self.turn(t, at: 0.12, back: 0.62)
            f.effects = [.question(Self.window(t, 0.25, 0.75))]
            f.transform.rotation = 0.06 * sin(tau * t * 2)

        case .love:
            stand.eyes = .happy
            stand.wave = seconds / Self.waveCycle
            f.pose = stand
            f.transform.squash = 1 + 0.05 * sin(tau * t * 3)
            f.effects = [.hearts(t)]

        case .sing:
            stand.eyes = .happy
            stand.mouthOpen = sin(tau * t * 5) > 0
            stand.wave = seconds / Self.waveCycle
            f.pose = stand
            f.transform.rotation = 0.1 * sin(tau * t * 2)
            f.effects = [.notes(t)]

        case .dance:
            stand.eyes = .happy
            stand.wave = seconds / Self.waveCycle
            f.pose = stand
            f.transform.offset.y = -2.2 * abs(sin(.pi * t * 6))
            f.transform.scaleX = tanh(5 * cos(tau * t * 1.5))
            f.transform.rotation = 0.12 * sin(.pi * t * 6)
            f.transform.squash = 1 - 0.08 * abs(cos(.pi * t * 6))
            f.effects = [.notes(t)]

        case .stretch:
            let k = sin(.pi * smoothstep(t))
            f.transform.squash = 1 - 0.26 * k
            stand.eyes = k > 0.4 ? .closed : .open
            stand.mouthOpen = k > 0.55
            f.pose = stand

        case .blink:
            let closed = (t > 0.1 && t < 0.3) || (t > 0.55 && t < 0.75)
            stand.eyes = closed ? .closed : .open
            f.pose = stand

        case .shake:
            let fade = 1 - smoothstep((t - 0.6) / 0.4)
            f.transform.rotation = 0.2 * sin(tau * t * 8) * fade
            f.transform.offset.x = 0.5 * sin(tau * t * 8 + 1) * fade
            stand.eyes = t < 0.7 ? .closed : .open
            f.pose = stand
            f.effects = [.splash(t)]

        case .sneeze:
            if t < 0.55 {
                let k = smoothstep(t / 0.55)
                f.transform.rotation = -0.14 * k
                f.transform.squash = 1 + 0.1 * k
                stand.eyes = .closed
            } else {
                let k = (t - 0.55) / 0.45
                let jolt = exp(-k * 6) * cos(k * 18)
                f.transform.rotation = 0.22 * jolt
                f.transform.squash = 1 - 0.14 * jolt
                f.transform.offset.x = 1.2 * jolt
                stand.eyes = k < 0.4 ? .closed : .open
                stand.mouthOpen = k < 0.3
                f.effects = [.puff(k)]
            }
            f.pose = stand

        case .sparkle:
            stand.eyes = .happy
            f.pose = stand
            f.transform = Self.jump(t, height: 2.4, start: 0.14, end: 0.5)
            f.effects = [.burst((t - 0.26) / 0.7)]

        case .doze:
            if t < 0.72 {
                let k = smoothstep(t / 0.72)
                f.transform.rotation = 0.16 * k
                f.transform.offset.y = 0.8 * k
                stand.eyes = .closed
                f.effects = [.dots(t / 0.72)]
            } else {
                let k = (t - 0.72) / 0.28
                f.transform.rotation = 0.16 * exp(-k * 8) * cos(k * 20)
                f.effects = [.exclaim(1 - k)]
            }
            f.pose = stand

        case .dizzy:
            f.transform.rotation = 0.16 * sin(tau * t * 3)
            f.transform.offset.x = 0.8 * sin(tau * t * 1.5)
            stand.eyes = .closed
            f.pose = stand
            f.effects = [.dizzyStars(t)]

        case .wiggle:
            // 뒤돌아 엉덩이를 좌우로 흔든다
            stand.eyes = .happy
            f.pose = stand
            f.transform.scaleX = Self.turn(t, at: 0.05, back: 0.85)
            let beat = sin(tau * t * 5) * Self.window(t, 0.12, 0.85)
            f.transform.rotation = 0.16 * beat
            f.transform.offset.x = 0.9 * beat
            f.transform.squash = 1 - 0.05 * abs(beat)
            f.effects = [.notes(t)]

        case .zoom:
            f.pose = CharacterPose(activity: .run, phase: seconds / 0.4, speed: 1.4)
            if t < 0.45 {
                f.transform.offset.x = 34 * pow(t / 0.45, 2)
            } else if t < 0.55 {
                f.transform.offset.x = 60   // 화면 밖
            } else {
                let k = (t - 0.55) / 0.45
                f.transform.offset.x = -34 * pow(1 - k, 2)
            }
            f.effects = [.speedLines(t * 3)]

        case .wakeUp:
            if t < 0.3 {
                f.pose = sleep
                f.pose.eyes = t < 0.12 ? .closed : .open
                f.effects = [.exclaim(Self.window(t, 0.1, 0.3))]
            } else if t < 0.68 {
                let k = sin(.pi * (t - 0.3) / 0.38)
                stand.eyes = .closed
                stand.mouthOpen = k > 0.5
                f.pose = stand
                f.transform.squash = 1 - 0.24 * k
            } else {
                stand.eyes = t < 0.8 ? .happy : .open
                f.pose = stand
                f.transform.offset.y = -1.4 * sin(.pi * (t - 0.68) / 0.32)
            }

        case .fallAsleep:
            if t < 0.55 {
                var sit = CharacterPose(activity: .sit, phase: seconds / 1.6, eyes: .closed)
                sit.mouthOpen = t > 0.12 && t < 0.42
                f.pose = sit
                f.transform.squash = 1 + 0.06 * sin(.pi * t / 0.55)
            } else if t < 0.75 {
                f.pose = CharacterPose(activity: .sit, phase: 0, eyes: .closed)
                f.transform.rotation = 0.12 * sin(.pi * (t - 0.55) / 0.2)
            } else {
                f.pose = sleep
                f.effects = [.zzz((t - 0.75) / 0.25 * 0.5)]
            }

        case .rollOver:
            f.pose = sleep
            f.transform.scaleX = Self.turn(t, at: 0.15, back: 0.7, speed: 0.18)
            f.transform.offset.y = -0.8 * (Self.window(t, 0.15, 0.33) + Self.window(t, 0.7, 0.88))

        case .snore:
            f.pose = sleep
            f.effects = [.bubble(t)]

        case .dream:
            f.pose = sleep
            f.effects = [.dream(t)]

        case .milestone25, .milestone50, .milestone75:
            // 고리가 다 차는 순간 살짝 뛰어오른다
            let goal: CGFloat = self == .milestone25 ? 0.25 : self == .milestone50 ? 0.5 : 0.75
            stand.eyes = t > 0.5 && t < 0.85 ? .happy : .open
            f.pose = stand
            f.transform.squash = 1 - 0.1 * Self.window(t, 0.42, 0.52)
            f.transform.offset.y = -1.6 * Self.window(t, 0.5, 0.72)
            f.effects = [.ring(t, from: goal - 0.25, to: goal)]
        }
        return f
    }

    // MARK: 곡선 도우미

    /// 웅크렸다가 뛰어오르고 착지하며 찌그러진다.
    static func jump(_ t: CGFloat, height: CGFloat, start: CGFloat, end: CGFloat) -> CharacterTransform {
        var tr = CharacterTransform()
        if t < start {
            tr.squash = 1 - 0.22 * sin(.pi / 2 * t / start)
        } else if t < end {
            let k = (t - start) / (end - start)
            tr.offset.y = -height * sin(.pi * k)
            tr.squash = 1 + 0.14 * cos(.pi * k) * (k < 0.5 ? 1 : 0.4)
        } else {
            let k = (t - end) / (1 - end)
            tr.squash = 1 - 0.2 * exp(-k * 4) * cos(k * 9)
        }
        return tr
    }

    /// 뒤돌았다가 다시 앞을 본다 (scaleX 1 → -1 → 1).
    static func turn(_ t: CGFloat, at a: CGFloat, back b: CGFloat, speed: CGFloat = 0.1) -> CGFloat {
        if t < a { return 1 }
        if t < a + speed { return cos(.pi * (t - a) / speed) }
        if t < b { return -1 }
        if t < b + speed { return -cos(.pi * (t - b) / speed) }
        return 1
    }

    /// a~b 구간에서 0 → 1 → 0으로 부드럽게.
    static func window(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        guard t > a && t < b else { return 0 }
        return sin(.pi * (t - a) / (b - a))
    }
}

// MARK: - 효과 그리기

extension MotionEffect {
    /// 러너가 차지한 영역(`bounds`)을 기준으로 효과를 그린다. `tint`는 단색 효과(물음표·Z 등)의 색.
    func draw(in cg: CGContext, around bounds: CGRect, tint: NSColor) {
        let head = CGPoint(bounds.maxX - 3, bounds.minY)
        let nose = CGPoint(bounds.maxX - 0.5, bounds.minY + min(4, bounds.height * 0.35))
        let pink = NSColor(hex: 0xFF5C93)
        let gold = NSColor(hex: 0xFFD23F)
        let warm = NSColor(hex: 0xFFB547)
        switch self {
        case .hearts(let t):
            for k in 0..<3 {
                let local = (t * 1.25 - CGFloat(k) * 0.22)
                guard local > 0 && local < 1 else { continue }
                let c = head + CGPoint(-2 + CGFloat(k) * 2.2 + sin(local * 7 + CGFloat(k)) * 0.8, -local * 8)
                let size = 1.0 + 0.5 * sin(.pi * min(local * 2, 1))
                SpriteEffects.heart(cg, at: c, size: size, color: pink.withAlphaComponent(1 - local * local))
            }
        case .notes(let t):
            for k in 0..<3 {
                let local = (t * 1.4 - CGFloat(k) * 0.3).truncatingRemainder(dividingBy: 1.1)
                guard local > 0 && local < 1 else { continue }
                let c = head + CGPoint(-1 + CGFloat(k) * 1.8 + sin(local * 6) * 1.2, -local * 8 + 1)
                SpriteEffects.note(cg, at: c, size: 2.2, color: tint.withAlphaComponent(sin(.pi * local)))
            }
        case .question(let alpha):
            guard alpha > 0.01 else { return }
            drawGlyph(cg, "?", at: head + CGPoint(0.5, -1.5 - alpha), size: 5, color: tint.withAlphaComponent(alpha))
        case .exclaim(let alpha):
            guard alpha > 0.01 else { return }
            SpriteEffects.exclaim(cg, at: head + CGPoint(0.8, -1.5), height: 4.5 * (0.7 + 0.3 * alpha),
                                  color: NSColor.systemOrange.withAlphaComponent(alpha))
        case .burst(let t):
            SpriteEffects.burst(cg, at: CGPoint(bounds.midX, bounds.midY - bounds.height * 0.1),
                                radius: max(bounds.width, bounds.height) * 0.42, t: t, color: tint, accent: warm)
        case .ring(let t, let from, let to):
            let fill = smoothstep((t - 0.12) / 0.38)
            let alpha = smoothstep(t / 0.1) * (1 - smoothstep((t - 0.8) / 0.2))
            // 다 퍼진 고리(반지름 3.4)까지 메뉴바 칸 위·오른쪽 안에 들어가는 자리
            let c = CGPoint(min(bounds.maxX + 3.2, 31.8), max(bounds.minY + 1.2, 5.6))
            let grow = 1 + 0.1 * smoothstep((t - 0.8) / 0.2)
            SpriteEffects.progressRing(cg, at: c, radius: 2.2 * grow, from: from, to: to, fill: fill, alpha: alpha,
                                       color: tint)
            // 다 찬 순간 고리 바깥으로 한 번 퍼진다
            let pulse = (t - 0.5) / 0.3
            if pulse > 0 && pulse < 1 {
                let r = 2.2 + pulse * 1.2
                cg.saveGState()
                defer { cg.restoreGState() }
                cg.setStrokeColor(tint.withAlphaComponent(0.5 * (1 - pulse) * alpha).cgColor)
                cg.setLineWidth(0.4 * (1 - pulse) + 0.1)
                cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        case .dizzyStars(let t):
            for k in 0..<3 {
                let angle = t * tau * 2 + CGFloat(k) / 3 * tau
                let c = head + CGPoint(cos(angle) * 3.2, -1 + sin(angle) * 1.1)
                SpriteEffects.sparkle(cg, at: c, radius: sin(angle) > 0 ? 1.3 : 0.9, color: gold)
            }
        case .dots(let t):
            for k in 0..<3 where t > CGFloat(k) * 0.25 {
                let c = head + CGPoint(CGFloat(k) * 1.5, -2)
                cg.setFillColor(tint.cgColor)
                cg.fillEllipse(in: CGRect(x: c.x - 0.5, y: c.y - 0.5, width: 1, height: 1))
            }
        case .puff(let t):
            for k in 0..<4 {
                let angle = CGFloat(k) * 0.5 - 0.75
                let c = nose + CGPoint.polar(angle, 1 + t * 4)
                let r = 0.6 + t * 1.2
                cg.setFillColor(tint.withAlphaComponent(0.5 * (1 - t)).cgColor)
                cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        case .splash(let t):
            for k in 0..<6 {
                let angle = CGFloat(k) / 6 * tau + 0.3
                let local = (t * 2 + CGFloat(k) * 0.13).truncatingRemainder(dividingBy: 1)
                let c = CGPoint(bounds.midX, bounds.midY) + CGPoint.polar(angle, bounds.width * 0.35 + local * 4)
                SpriteEffects.drop(cg, at: c, size: 0.6, color: NSColor(hex: 0x5AC8FA).withAlphaComponent(1 - local))
            }
        case .bubble(let t):
            if t < 0.85 {
                let r = 0.4 + 2.6 * smoothstep(t / 0.85) * (1 + 0.06 * sin(t * 40))
                let c = nose + CGPoint(r * 0.7, -r * 0.2)
                cg.setFillColor(NSColor(hex: 0xBFE9FF).withAlphaComponent(0.55).cgColor)
                cg.setStrokeColor(NSColor(hex: 0x7FD0FF).cgColor)
                cg.setLineWidth(0.35)
                cg.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                cg.drawPath(using: .fillStroke)
                cg.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                cg.fillEllipse(in: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.6, width: r * 0.45, height: r * 0.35))
            } else {
                let k = (t - 0.85) / 0.15
                let c = nose + CGPoint(2, -0.5)
                for i in 0..<6 {
                    let p = c + CGPoint.polar(CGFloat(i) / 6 * tau, 1.5 + k * 2.5)
                    cg.setFillColor(NSColor(hex: 0x7FD0FF).withAlphaComponent(1 - k).cgColor)
                    cg.fillEllipse(in: CGRect(x: p.x - 0.35, y: p.y - 0.35, width: 0.7, height: 0.7))
                }
            }
        case .dream(let t):
            let base = head + CGPoint(0, -0.5)
            let sizes: [CGFloat] = [0.5, 0.8, 2.8]
            let offsets = [CGPoint(0, 0), CGPoint(1.3, -1.6), CGPoint(3.4, -4.6)]
            for k in 0..<3 {
                let appear = smoothstep((t - CGFloat(k) * 0.12) / 0.15) * (1 - smoothstep((t - 0.85) / 0.15))
                guard appear > 0 else { continue }
                let c = base + offsets[k]
                let r = sizes[k] * appear
                cg.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
                cg.setStrokeColor(tint.withAlphaComponent(0.6).cgColor)
                cg.setLineWidth(0.3)
                cg.addEllipse(in: CGRect(x: c.x - r * 1.2, y: c.y - r, width: r * 2.4, height: r * 2))
                cg.drawPath(using: .fillStroke)
                if k == 2 && appear > 0.6 {
                    SpriteEffects.heart(cg, at: c + CGPoint(0, 0.1), size: 1.0 * appear, color: pink)
                }
            }
        case .speedLines(let t):
            SpriteEffects.airStreaks(cg, phase: t - floor(t), maxX: bounds.minX,
                                     band: (bounds.minY + bounds.height * 0.2)...(bounds.maxY - bounds.height * 0.25),
                                     color: tint)
        case .zzz(let t):
            SpriteEffects.zzz(cg, from: CGPoint(bounds.maxX - 2.5, bounds.minY + 0.5), phase: t, color: tint)
        }
    }

    private func drawGlyph(_ cg: CGContext, _ text: String, at c: CGPoint, size: CGFloat, color: NSColor) {
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(string)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        cg.saveGState()
        // 텍스트는 y 위 좌표로 그려지므로 뒤집는다
        cg.translateBy(x: c.x - CGFloat(width) / 2, y: c.y + size * 0.35)
        cg.scaleBy(x: 1, y: -1)
        cg.textPosition = .zero
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}
