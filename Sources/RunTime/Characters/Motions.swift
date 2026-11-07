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
    /// 정지 말풍선 하나 (Assets/FX/emote): 이름과 진행도.
    case emote(String, CGFloat)
}

/// 한 번 재생하고 끝나는 동작. 시간 함수라 메뉴바는 fps만큼 잘라 쓰고 팝오버는 매 프레임 계산한다.
enum Trick: String, CaseIterable {
    // 깨어 있을 때
    case hop, flip, spin, lookAround, love, sing, dance, stretch, blink, shake, sneeze, sparkle, doze, dizzy, zoom, wiggle
    /// 손을 흔들며 반긴다 (Claude가 일을 마쳤을 때, 쓰다듬을 때).
    case greet
    // 상태가 바뀔 때
    case wakeUp, fallAsleep, celebrate
    // 잘 때
    case rollOver, snore, dream
    // 세션 사용률이 25·50·75%를 넘을 때
    case milestone25, milestone50, milestone75

    /// 혼자 하는 장난. 몸을 돌리거나 찌그러뜨리는 큰 동작은 빼고, 펫 그림의 줄(생각·손 흔들기)과 말풍선으로 보이는 것만 둔다.
    /// 나머지 동작은 '동작' 메뉴에서 직접 고를 수 있다.
    static let awake: [Trick] = [.lookAround, .sing, .doze, .greet, .love, .blink]
    static let asleep: [Trick] = [.rollOver, .snore, .dream]
    /// 팝오버에서 러너를 눌렀을 때. 같은 것을 연달아 하지 않게 고른다.
    static let petting: [Trick] = [.greet, .hop, .sing]

    var duration: TimeInterval {
        switch self {
        case .blink: return 0.6
        case .greet: return 1.6
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
        case .greet: return "인사"
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
            if t > 0.18 && t < 0.74 {
                f.pose = CharacterPose(activity: .run, phase: 0.62, speed: 1)
                f.pose.jump = (t - 0.18) / 0.56
            }

        case .flip, .celebrate:
            f.transform = Self.jump(t, height: 5, start: 0.16, end: 0.8)
            let spinT = smoothstep((t - 0.2) / 0.55)
            f.transform.rotation = -tau * spinT
            f.transform.pivotAtCenter = true
            if t > 0.16 && t < 0.8 {
                f.pose = CharacterPose(activity: .run, phase: 0.62, speed: 1)
                f.pose.jump = (t - 0.16) / 0.64
            }
            f.pose.eyes = t > 0.75 ? .happy : .open
            // 착지하는 순간 터진다
            if self == .celebrate { f.effects = [.burst((t - 0.72) / 0.28)] }

        case .spin:
            let k = smoothstep(t)
            f.transform.scaleX = cos(tau * 2 * k)
            f.transform.offset.y = -1.8 * sin(.pi * t)
            f.pose.eyes = .happy

        case .lookAround:
            // 그림 러너는 턱을 괴고 생각하는 줄로, 벡터 러너는 좌우를 둘러본다
            stand.review = seconds / 1.0
            f.pose = stand
            f.transform.scaleX = Self.turn(t, at: 0.12, back: 0.62)
            f.effects = [.question(Self.window(t, 0.25, 0.75))]

        case .love:
            stand.eyes = .happy
            stand.wave = seconds / Self.waveCycle
            f.pose = stand
            f.effects = [.hearts(t)]

        case .greet:
            stand.eyes = .happy
            stand.wave = seconds / Self.waveCycle
            f.pose = stand
            f.effects = [.emote("stars", t)]

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
        let nose = CGPoint(bounds.maxX - 0.5, bounds.minY + min(4, bounds.height * 0.35))
        switch self {
        case .hearts(let t):
            Emote.animate("balloonHeart", in: cg, around: bounds, progress: min(1, t / 0.45),
                          alpha: 1 - smoothstep((t - 0.85) / 0.15))
        case .notes(let t):
            Emote.draw("music", in: cg, around: bounds, pop: t / 0.15, alpha: 1 - smoothstep((t - 0.85) / 0.15),
                       bob: sin(t * tau * 2) * 0.4)
        case .question(let alpha):
            Emote.animate("balloonQuestion", in: cg, around: bounds, progress: alpha, alpha: alpha)
        case .exclaim(let alpha):
            Emote.animate("balloonExclaim", in: cg, around: bounds, progress: alpha, alpha: alpha)
        case .burst(let t):
            GameFX.drawSprite("starburst", at: CGPoint(bounds.midX, bounds.midY - bounds.height * 0.1),
                              height: max(bounds.width, bounds.height) * 1.2, progress: t, time: 0, cg)
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
            Emote.draw("swirl", in: cg, around: bounds, pop: 1, bob: sin(t * tau) * 0.4)
        case .dots(let t):
            Emote.animate("balloonDots", in: cg, around: bounds, progress: t)
        case .puff(let t):
            GameFX.drawSprite("puff", at: nose + CGPoint(2 + t * 2, -0.5), height: 4, progress: t, time: 0, cg)
        case .splash(let t):
            Emote.draw("drops", in: cg, around: bounds, pop: t / 0.2, alpha: 1 - smoothstep((t - 0.8) / 0.2))
        case .bubble(let t):
            // 코풍선: 부풀다가 0.85에서 터진다
            let swell = 1.5 + 4 * smoothstep(min(t, 0.85) / 0.85)
            GameFX.drawSprite("plasmaBubble", at: nose + CGPoint(swell * 0.4, -swell * 0.1), height: swell,
                              progress: t < 0.85 ? 0.45 : 0.6 + (t - 0.85) / 0.15 * 0.4, time: 0, cg)
        case .dream(let t):
            Emote.draw("hearts", in: cg, around: bounds, pop: t / 0.2, alpha: 1 - smoothstep((t - 0.85) / 0.15))
        case .speedLines(let t):
            GameFX.drawSprite("puff", at: CGPoint(bounds.minX - 2, bounds.maxY - 2), height: 5, progress: t - floor(t), time: 0, cg)
        case .emote(let name, let t):
            Emote.draw(name, in: cg, around: bounds, pop: t / 0.15, alpha: 1 - smoothstep((t - 0.85) / 0.15))
        case .zzz(let t):
            Emote.draw(t.truncatingRemainder(dividingBy: 1) < 0.5 ? "sleep" : "sleeps", in: cg, around: bounds, pop: 1,
                       bob: sin(t * tau) * 0.3)
        }
    }
}
