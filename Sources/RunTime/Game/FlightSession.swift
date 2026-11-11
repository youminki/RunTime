import AppKit
import GameCore
import UsageCore
import SwiftUI

/// 난이도별 최고 점수와 고른 난이도. 이 Mac에만 저장한다.
enum FlightRecords {
    private static let difficultyKey = "flightDifficulty"

    static var difficulty: FlightDifficulty {
        get { UserDefaults.standard.string(forKey: difficultyKey).flatMap(FlightDifficulty.init(rawValue:)) ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: difficultyKey) }
    }

    static func best(_ difficulty: FlightDifficulty) -> Int {
        UserDefaults.standard.integer(forKey: "flightBest.\(difficulty.rawValue)")
    }

    static func finish(_ difficulty: FlightDifficulty, score: Int) {
        UserDefaults.standard.set(max(best(difficulty), score), forKey: "flightBest.\(difficulty.rawValue)")
    }
}

/// 무대 위의 비행 한 판. 규칙(FlightGame)과 화면·입력·소리를 잇는다. 메인 스레드에서만 쓴다.
final class FlightSession {
    let game: FlightGame
    private(set) var character: RunnerCharacter
    let live: Bool
    var window: () -> NSWindow? = { nil }
    var onExit: () -> Void = {}
    private var keyMonitor: Any?
    private var resignObserver: Any?
    private var lastDate: Date?
    private var banner: (text: String, life: CGFloat)?
    private var notice: (text: String, life: CGFloat)?
    private var crash: (at: CGPoint, age: CGFloat)?
    private var puffs: [(at: CGPoint, age: CGFloat, name: String)] = []
    private var trail: [CGPoint] = []
    private var shake: CGFloat = 0
    private var scaleCache: [String: CGFloat] = [:]
    private var clock = 0.0

    /// 러너 왼쪽 끝의 화면 x. 앞을 멀리 보게 왼쪽에 둔다.
    static let runnerX: CGFloat = 46
    private static let tile: CGFloat = 16
    /// 구역마다 바꾸는 블록 그림. 배경은 고른 것만 쓴다.
    private static let themes = ["spring", "beach", "autumn", "snow"]

    init(difficulty: FlightDifficulty, character: RunnerCharacter, live: Bool = true) {
        game = FlightGame(difficulty: difficulty, best: live ? FlightRecords.best(difficulty) : 0)
        self.character = character
        self.live = live
        if live { installKeys() }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func use(_ character: RunnerCharacter) { self.character = character }

    var isPlaying: Bool { game.phase == .playing }
    private var theme: String { Self.themes[(game.zoneNumber - 1) % Self.themes.count] }

    func press() {
        let wasOver = game.phase == .over
        game.press()
        if wasOver, game.phase == .playing { trail.removeAll() }
    }

    func release() { game.release() }

    func announce(_ text: String) { notice = (text, 3.5) }

    private func installKeys() {
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, window === self.window() else { return }
            self.release()
            self.game.setBoost(false)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .rightMouseDown, .rightMouseUp]) { [weak self] event in
            guard let self, event.window != nil, event.window === self.window() else { return event }
            if event.type == .rightMouseDown || event.type == .rightMouseUp {
                self.game.setBoost(event.type == .rightMouseDown && self.isPlaying)
                return nil
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad, .capsLock]).isEmpty else { return event }
            if self.window()?.firstResponder is NSTextView { return event }
            let down = event.type == .keyDown
            switch event.keyCode {
            case 49, 126, 13:   // 스페이스, ↑, W
                if down, !event.isARepeat { self.press() }
                if !down { self.release() }
                return nil
            case 124, 2:        // →, D 가속
                self.game.setBoost(down && self.isPlaying)
                return nil
            case 53:            // esc
                if down { self.onExit() }
                return nil
            default:
                return event
            }
        }
    }

    // MARK: 한 프레임

    func update(date: Date) {
        advance(seconds: min(max(date.timeIntervalSince(lastDate ?? date), 0), 0.1))
        lastDate = date
    }

    /// 화면 점검 도구도 이 길로 시간을 보낸다.
    func advance(seconds dt: Double) {
        clock += dt
        game.advance(by: dt)
        for event in game.drainEvents() { handle(event) }
        let k = CGFloat(dt)
        shake = max(0, shake - k * 5)
        if let current = banner { banner = current.life > k ? (current.text, current.life - k) : nil }
        if let current = notice { notice = current.life > k ? (current.text, current.life - k) : nil }
        if let current = crash { crash = current.age < 0.9 ? (current.at, current.age + k) : nil }
        for i in puffs.indices { puffs[i].age += k }
        puffs.removeAll { $0.age > 0.5 }
        if isPlaying {
            let shift = CGFloat(game.currentSpeed) * k
            trail = trail.map { CGPoint($0.x - shift, $0.y) }.filter { $0.x > -10 }
            trail.append(CGPoint(Self.runnerX + 4, CGFloat(game.y + FlightGame.runnerHeight / 2)))
            if trail.count > 36 { trail.removeFirst() }
        }
    }

    private var here: CGPoint {
        CGPoint(Self.runnerX + CGFloat(FlightGame.runnerWidth / 2), CGFloat(game.y + FlightGame.runnerHeight / 2))
    }

    private func handle(_ event: FlightGame.Event) {
        switch event {
        case .started:
            banner = ("누르는 동안 올라가요", 2)
        case .candy:
            play(.coin)
            puffs.append((here, 0, "plasmaSparkle"))
        case .shieldPicked:
            play(.shield)
            banner = ("보호막!", 1.2)
        case .shieldBroke:
            play(.shield)
            shake = 0.5
            puffs.append((here, 0, "pumpingHeart"))
        case .stuck:
            play(.hit)
            banner = ("슬라임이 붙어서 무거워요!", 1.4)
        case .nearMiss:
            play(.nearmiss)
            banner = ("아슬!", 0.6)
        case .zone(let number):
            play(.milestone)
            banner = ("구역 \(number) · 더 빨라져요", 1.8)
        case .newBest:
            play(.record)
            banner = ("신기록!", 1.6)
        case .crashed:
            play(.hit)
            shake = 1
            crash = (here, 0)
            if live { FlightRecords.finish(game.difficulty, score: game.score) }
            let new = game.isNewBest
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.game.phase == .over else { return }
                self.play(new ? .fanfare : .gameover)
            }
        }
    }

    private func play(_ effect: GameSound.Effect) {
        if live { GameSound.shared.play(effect) }
    }

    // MARK: 그리기

    func draw(_ cg: CGContext, size: CGSize, groundY: CGFloat, theme palette: SpriteTheme, time: Double) {
        let at = game.x
        let world = { (wx: Double) in Self.runnerX + CGFloat(wx - at) }
        let screenY = { (y: CGFloat) in groundY - y }
        cg.saveGState()
        if shake > 0 {
            let a = shake * shake * 4
            cg.translateBy(x: CGFloat.random(in: -a...a), y: CGFloat.random(in: -a...a))
        }
        drawSpeedLines(cg, size: size, groundY: groundY, time: time)
        drawRails(cg, size: size, groundY: groundY)
        for pickup in game.pickups {
            let x = world(pickup.x)
            guard x > -20, x < size.width + 20 else { continue }
            let point = CGPoint(x, screenY(CGFloat(pickup.y)) + CGFloat(sin(time * 5 + pickup.x * 0.03)) * 1.5)
            switch pickup.kind {
            case .candy:
                GameFX.drawCandy(GameFX.candy(for: pickup.x / 40), at: point, height: 15, cg)
            case .shield:
                GameFX.drawSprite("plasmaBubble", at: point, height: 26, progress: 0.4, time: time, cg)
            }
        }
        for hazard in game.hazards {
            let p = hazard.position(at: at)
            let x = world(p.x)
            guard x < size.width + 40, x + CGFloat(hazard.width) > -40 else {
                // 화면 밖에서 마주 오는 드릴은 미리 알린다
                if hazard.kind == .drill, x < size.width + 180 {
                    GameFX.drawSprite("balloonExclaim", at: CGPoint(size.width - 12, screenY(CGFloat(p.y + hazard.height / 2))),
                                      height: 16, progress: 0.5, time: time, cg)
                }
                continue
            }
            let rect = CGRect(x: x, y: screenY(CGFloat(p.y + hazard.height)), width: CGFloat(hazard.width), height: CGFloat(hazard.height))
            draw(hazard, rect: rect, time: time, cg)
        }
        if let item = GameDecor.shared.equipped(.trail), trail.count > 1 {
            GameFX.drawTrail(item, points: trail.map { CGPoint($0.x, screenY($0.y)) }, time: time, cg)
        }
        for puff in puffs {
            GameFX.drawSprite(puff.name, at: CGPoint(puff.at.x, screenY(puff.at.y)), height: 22, progress: puff.age / 0.5, time: time,
                              alpha: 1 - puff.age / 0.5, cg)
        }
        if game.phase != .over || (crash?.age ?? 1) > 0.45 {
            drawRunner(cg, groundY: groundY, palette: palette, time: time)
        }
        if let crash {
            for part in GameFX.crash(GameDecor.shared.equipped(.crash)) {
                GameFX.drawSpray(part.spray, from: CGPoint(crash.at.x + part.offset.x, screenY(crash.at.y) - part.offset.y),
                                 age: crash.age, time: time, cg)
            }
        }
        cg.restoreGState()
        drawHUD(cg, size: size)
    }

    /// 빠르기가 눈에 보이게 바람 줄을 흘린다. 가속 중에는 더 많고 길다.
    private func drawSpeedLines(_ cg: CGContext, size: CGSize, groundY: CGFloat, time: Double) {
        let v = game.currentSpeed
        guard game.phase == .playing else { return }
        let count = 4 + Int(v / 90) + (game.isBoosting ? 6 : 0)
        cg.setFillColor(NSColor.white.withAlphaComponent(game.isBoosting ? 0.5 : 0.28).cgColor)
        for k in 0..<count {
            let seed = StageModel.hash(k, 41)
            let x = size.width - CGFloat(game.x * (0.9 + Double(seed) * 0.6) + Double(k) * 97).truncatingRemainder(dividingBy: size.width + 60)
            let y = 34 + seed * (groundY - 44)
            cg.fill(CGRect(x: x, y: y, width: CGFloat(v / 22) * (game.isBoosting ? 1.6 : 1), height: 1))
        }
    }

    private var tiles: (top: CGImage?, fill: CGImage?) {
        (GameFX.image("tile_\(theme)_top", folder: "Game"), GameFX.image("tile_\(theme)_fill", folder: "Game"))
    }

    private func drawRails(_ cg: CGContext, size: CGSize, groundY: CGFloat) {
        guard let top = tiles.top else { return }
        let tile = Self.tile
        let offset = CGFloat(game.x).truncatingRemainder(dividingBy: tile)
        let ceiling = groundY - CGFloat(FlightGame.ceiling)
        var x = -offset
        while x < size.width {
            GameAssets.draw(top, in: CGRect(x: x, y: groundY, width: tile, height: tile), cg)
            drawFlipped(top, in: CGRect(x: x, y: ceiling - tile, width: tile, height: tile), cg)
            if let fill = tiles.fill { GameAssets.draw(fill, in: CGRect(x: x, y: ceiling - tile * 2, width: tile, height: tile), cg) }
            x += tile
        }
    }

    private func drawFlipped(_ image: CGImage, in rect: CGRect, _ cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        GameAssets.draw(image, in: CGRect(origin: .zero, size: rect.size), cg)
        cg.restoreGState()
    }

    private func draw(_ hazard: FlightHazard, rect: CGRect, time: Double, _ cg: CGContext) {
        switch hazard.kind {
        case .pillar:
            drawBlocks(cg, rect: rect, hanging: hazard.y > 0 && hazard.y + hazard.height >= FlightGame.ceiling - 1)
        case .rock:
            drawBlocks(cg, rect: rect, hanging: false)
        case .bat:
            sprite(.bat, rect: rect, time: time, cg)
        case .crusher:
            sprite(.crusher, rect: rect, time: time, cg)
        case .drill:
            sprite(.drill, rect: rect, time: time, cg, flip: true)
        case .spikeball:
            cg.saveGState()
            cg.translateBy(x: rect.midX, y: rect.midY)
            cg.rotate(by: CGFloat(time * 5))
            cg.translateBy(x: -rect.midX, y: -rect.midY)
            sprite(.spikeball, rect: rect, time: time, cg)
            cg.restoreGState()
        case .slime:
            GameFX.drawSprite("slime", at: CGPoint(rect.midX, rect.midY), height: rect.height + 4, progress: 0, time: time, cg)
        }
    }

    private func sprite(_ sprite: GameSprite, rect: CGRect, time: Double, _ cg: CGContext, flip: Bool = false) {
        guard let image = sprite.frame(at: time) else { return }
        let content = sprite.content
        let sx = rect.width / max(content.width, 1), sy = rect.height / max(content.height, 1)
        let box = CGRect(x: rect.minX - (flip ? CGFloat(image.width) - content.maxX : content.minX) * sx,
                         y: rect.minY - content.minY * sy, width: CGFloat(image.width) * sx, height: CGFloat(image.height) * sy)
        GameAssets.draw(image, in: box, cg, flipX: flip)
    }

    private func drawBlocks(_ cg: CGContext, rect: CGRect, hanging: Bool) {
        let images = tiles
        cg.saveGState()
        cg.clip(to: rect)
        let tile = Self.tile
        var column = rect.minX
        while column < rect.maxX {
            var row = hanging ? rect.maxY - tile : rect.minY
            var first = true
            while hanging ? row + tile > rect.minY : row < rect.maxY {
                let box = CGRect(x: column, y: row, width: tile, height: tile)
                if first, let top = images.top {
                    hanging ? drawFlipped(top, in: box, cg) : GameAssets.draw(top, in: box, cg)
                } else if let fill = images.fill {
                    GameAssets.draw(fill, in: box, cg)
                }
                first = false
                row += hanging ? -tile : tile
            }
            column += tile
        }
        cg.restoreGState()
    }

    private func drawRunner(_ cg: CGContext, groundY: CGFloat, palette: SpriteTheme, time: Double) {
        let scale = runnerScale(character)
        var pose: CharacterPose
        switch game.phase {
        case .ready:
            pose = CharacterPose(activity: .stand, phase: CGFloat(time / 2.4))
        case .over:
            pose = CharacterPose(activity: .sit, phase: CGFloat(time / 1.1), mouthOpen: true)
        case .playing:
            pose = CharacterPose(activity: .run, phase: 0.62, speed: 1.2)
            // 오를 때 도약, 내려올 때 착지 준비 (그림 펫은 점프 줄을 쓴다)
            pose.jump = game.velocityY > 0 ? 0.3 : 0.7
        }
        let scene = CharacterScene(rig: character.rig, pose: pose)
        let center = Self.runnerX + CGFloat(FlightGame.runnerWidth) / 2
        let bottom = groundY - CGFloat(game.y)
        // 판정 상자 가운데에 그림 가운데를 맞춘다
        let bounds = scene.bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : scene.bounds
        let originY = bottom - CGFloat(FlightGame.runnerHeight) / 2 - bounds.midY * scale
        cg.saveGState()
        cg.translateBy(x: center - bounds.midX * scale, y: originY)
        cg.scaleBy(x: scale, y: scale)
        let look = CharacterLook(rich: true, palette: palette.richPalette(character.rig.palette, phase: CGFloat(time / 6)),
                                 tint: .white, outline: 0.36)
        scene.draw(in: cg, look: look)
        cg.restoreGState()
        if game.hasShield {
            GameFX.drawSprite("plasmaBubble", at: CGPoint(center, bottom - CGFloat(FlightGame.runnerHeight) / 2), height: 40,
                              progress: 0.4, time: time, alpha: 0.7, cg)
        }
        if game.heavy > 0 {
            GameFX.drawSprite("slime", at: CGPoint(center, bottom + 3), height: 13, progress: 0, time: time, cg)
        }
    }

    private func runnerScale(_ character: RunnerCharacter) -> CGFloat {
        if let cached = scaleCache[character.key] { return cached }
        let bounds = CharacterScene(rig: character.rig, pose: CharacterPose(activity: .stand)).bounds
        let scale = bounds.isNull ? 30 / FittedRig.targetHeight : min(30 / max(bounds.height, 1), 30 / max(bounds.width, 1))
        scaleCache[character.key] = scale
        return scale
    }

    /// 맨 위 띠를 어둡게 깔아 점수를 읽기 쉽게 한다. 왼쪽 점수, 오른쪽 빠르기 막대.
    private func drawHUD(_ cg: CGContext, size: CGSize) {
        cg.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 20))
        let bar = CGRect(x: size.width - 92, y: 8, width: 80, height: 5)
        cg.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        cg.fillPath()
        let d = game.difficulty
        let ratio = min(1, max(0.05, (game.currentSpeed - d.startSpeed * 0.9) / (d.maxSpeed * FlightGame.boostFactor - d.startSpeed * 0.9)))
        var filled = bar
        filled.size.width = bar.width * CGFloat(ratio)
        cg.setFillColor(NSColor(hex: game.isBoosting ? 0xFF7A5C : 0xFFD45E).cgColor)
        cg.addPath(CGPath(roundedRect: filled, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        cg.fillPath()
    }

    // MARK: 글자

    func overlay(size: CGSize) -> (panels: [GameSession.Panel], labels: [GameSession.Label]) {
        var labels: [GameSession.Label] = []
        var panels: [GameSession.Panel] = []
        let caption = Font.system(size: 10.5, weight: .semibold).monospacedDigit()
        let gold = Color(nsColor: NSColor(hex: 0xFFD45E))
        let box = CGRect(x: size.width - 222, y: size.height / 2 - 36, width: 210, height: 76)
        let mid = box.midX
        switch game.phase {
        case .ready:
            panels.append(.init(rect: box))
            labels.append(.init(text: Text("비행").font(GameFont.pixel(20)).foregroundColor(.white), position: CGPoint(mid, box.minY + 18)))
            labels.append(.init(text: Text("\(game.difficulty.title) · 최고 \(game.best)점").font(caption).foregroundColor(gold),
                                position: CGPoint(mid, box.minY + 37)))
            labels.append(.init(text: Text("누르는 동안 올라가요 · → 가속").font(caption).foregroundColor(.white.opacity(0.8)),
                                position: CGPoint(mid, box.minY + 51)))
            labels.append(.init(text: Text("스페이스 또는 클릭으로 시작").font(caption).foregroundColor(.white.opacity(0.6)),
                                position: CGPoint(mid, box.minY + 65)))
        case .over:
            panels.append(.init(rect: box))
            labels.append(.init(text: Text(verbatim: "\(game.score)").font(GameFont.pixel(24)).foregroundColor(.white), position: CGPoint(mid, box.minY + 19)))
            labels.append(.init(text: Text(game.isNewBest ? "신기록!" : "최고 \(game.best)점").font(caption).foregroundColor(gold),
                                position: CGPoint(mid, box.minY + 38)))
            labels.append(.init(text: Text("구역 \(game.zoneNumber) · 사탕 \(game.candies) · 아슬 \(game.nearMisses)").font(caption).foregroundColor(.white.opacity(0.8)),
                                position: CGPoint(mid, box.minY + 52)))
            labels.append(.init(text: Text("스페이스 다시 · esc 나가기").font(caption).foregroundColor(.white.opacity(0.6)),
                                position: CGPoint(mid, box.minY + 66)))
        case .playing:
            break
        }
        labels.append(.init(text: Text(verbatim: "\(game.score)").font(GameFont.pixel(13)).foregroundColor(.white),
                            position: CGPoint(10, 2), anchor: .topLeading))
        labels.append(.init(text: Text(verbatim: "BEST \(max(game.best, game.score))").font(caption).foregroundColor(.white.opacity(0.7)),
                            position: CGPoint(70, 5), anchor: .topLeading))
        if let banner {
            labels.append(.init(text: Text(banner.text).font(.system(size: 12, weight: .bold)).foregroundColor(.white),
                                position: CGPoint(size.width / 2, 40), opacity: Double(min(1, banner.life * 2))))
        }
        if let notice {
            labels.append(.init(text: Text(notice.text).font(caption).foregroundColor(gold),
                                position: CGPoint(size.width / 2, size.height - 8), opacity: Double(min(1, notice.life * 2))))
        }
        return (panels, labels)
    }
}

/// 비행 화면 점검 (`--flight-shots <폴더>`): 앞을 보는 플레이어로 난이도마다 날며 찍는다.
enum FlightShots {
    @MainActor
    static func run(to directory: URL, character: RunnerCharacter) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for difficulty in FlightDifficulty.allCases {
            let session = FlightSession(difficulty: difficulty, character: character, live: false)
            let pilot = FlightPilot(game: session.game)
            try write(session, to: directory.appendingPathComponent("\(difficulty.rawValue)-ready.png"))
            session.game.press()
            session.game.release()
            var shot = 0
            var ticks = 0
            while session.game.phase == .playing, shot < 12 {
                pilot.step()
                session.advance(seconds: FlightGame.step)
                ticks += 1
                if ticks % 240 == 0 {
                    try write(session, to: directory.appendingPathComponent("\(difficulty.rawValue)-\(shot).png"))
                    shot += 1
                }
            }
            print("\(difficulty.title): 조각 \(session.game.chunks.map(\.rawValue).joined(separator: ", "))")
        }
    }

    /// README GIF용: 앞을 보는 플레이어로 보통 난이도를 날며 1초 20장으로 찍는다.
    @MainActor
    static func frames(to directory: URL, character: RunnerCharacter) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = FlightSession(difficulty: .normal, character: character, live: false)
        let pilot = FlightPilot(game: session.game)
        session.game.press()
        session.game.release()
        // 앞의 빈 하늘을 지나 장애물이 나오는 곳부터 찍는다
        for _ in 0..<(120 * 3) {
            pilot.step()
            session.advance(seconds: FlightGame.step)
        }
        var index = 0
        for tick in 0..<(120 * 6) where session.game.phase == .playing {
            pilot.step()
            session.advance(seconds: FlightGame.step)
            if tick % 6 == 0 {
                index += 1
                try write(session, to: directory.appendingPathComponent(String(format: "%04d.png", index)), scale: 2)
            }
        }
        print("frames \(index)")
    }

    @MainActor
    private static func write(_ session: FlightSession, to url: URL, scale: CGFloat = 3) throws {
        let size = CGSize(width: 348, height: 150)
        let view = Canvas { context, _ in
            context.withCGContext { cg in
                let sky = Sky.at(hour: 12, space: false)
                Backdrop.draw(cg, size: size, sky: sky, time: 0, groundY: 135, scroll: CGFloat(session.game.x), speed: 0,
                              track: GameDecor.shared.equipped(.track))
                session.draw(cg, size: size, groundY: 135, theme: .auto, time: session.game.x / 200)
            }
            RunnerStage.drawOverlay(session.overlay(size: size), in: &context)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
}

/// 무대와 키 입력 점검 (`--stage-check`): 진짜 창에 진짜 키 이벤트를 보내 게임을 조작해 본다.
enum StageCheck {
    @MainActor
    static func run(character: RunnerCharacter) -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✓" : "✗") \(name)")
            if !ok { failures += 1 }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.orderBack(nil)
        func key(_ code: UInt16, down: Bool) {
            guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: " ",
                                               charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code) else { return }
            app.sendEvent(event)
        }
        let size = CGSize(width: 348, height: 150)
        guard let cg = CGContext(data: nil, width: 348, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        cg.translateBy(x: 0, y: 150)
        cg.scaleBy(x: 1, y: -1)
        let model = StageModel()
        model.window = window
        var now = Date()
        func frames(_ count: Int) {
            for _ in 0..<count {
                now = now.addingTimeInterval(1.0 / 60)
                model.draw(cg, size: size, date: now, display: .normal(.walking), character: character, theme: .auto)
            }
        }

        // 게임 밖: ←→로 걷고 스페이스로 뛰고, 들어 옮겨 놓으면 땅으로 돌아온다. 동료는 뒤를 따라온다
        model.installRoamKeys { _ in }
        model.companionOverride = Runner.dog.character
        frames(60)
        let home = model.roamOffset
        let buddyHome = model.buddyPosition ?? 0
        check("동료가 러너 뒤에 선다", buddyHome < model.bodyRect.midX - 20)
        key(124, down: true)
        frames(40)
        key(124, down: false)
        check("→로 걷는다 (\(Int(model.roamOffset - home))pt)", model.roamOffset > home + 40)
        frames(30)
        check("동료가 따라 걷는다 (\(Int((model.buddyPosition ?? 0) - buddyHome))pt)", (model.buddyPosition ?? 0) > buddyHome + 30)
        key(49, down: true)
        key(49, down: false)
        frames(8)
        check("스페이스로 뛴다 (높이 \(Int(model.liftHeight)))", model.liftHeight > 5)
        frames(90)
        check("뛰고 나면 땅에 내린다", model.liftHeight == 0)
        let body = model.bodyRect
        model.drag(from: CGPoint(body.midX, body.midY), to: CGPoint(body.midX + 10, body.midY - 30))
        frames(20)
        check("러너를 잡고 끌면 들린다 (높이 \(Int(model.liftHeight)))", model.liftHeight > 10)
        _ = model.release(at: CGPoint(body.midX + 10, body.midY - 30), tapped: false)
        frames(120)
        check("놓으면 땅으로 떨어진다", model.liftHeight == 0)
        check("러너 몸이 무대 위로 나가지 않는다", model.bodyRect.minY >= 0)
        model.companionOverride = nil

        // 비행: 키로 시작하고, 눌러서 오르고, →로 빨라지고, 끝나면 다시 시작하고, esc로 나간다
        model.startFlight(character: character, rehearsal: false)
        check("비행을 켜면 게임 중이 된다", model.isPlaying && model.flight != nil)
        frames(1)
        key(49, down: true)
        frames(10)
        check("스페이스로 시작한다", model.flight?.isPlaying == true)
        let low = model.flight?.game.y ?? 0
        frames(10)
        check("누르는 동안 올라간다", (model.flight?.game.y ?? 0) > low)
        key(49, down: false)
        let plain = model.flight?.game.currentSpeed ?? 0
        key(124, down: true)
        check("→로 빨라진다", (model.flight?.game.currentSpeed ?? 0) > plain)
        key(124, down: false)
        frames(1200)
        check("손을 놓으면 언젠가 부딪혀 끝난다", model.flight?.game.phase == .over)
        let first = model.flight?.game.score ?? 0
        frames(40)
        key(49, down: true)
        key(49, down: false)
        frames(5)
        check("다시 시작하면 새 판이다 (\(first)점 → \(model.flight?.game.score ?? 0)점)",
              model.flight?.isPlaying == true && (model.flight?.game.score ?? 0) < max(first, 1))
        key(53, down: true)
        check("esc로 비행을 나간다", model.flight == nil && !model.isPlaying)

        // 비행을 앞을 보는 플레이어로 20초 날아 진짜 그리기를 거친다
        model.startFlight(character: character, rehearsal: true)
        if let session = model.flight {
            let pilot = FlightPilot(game: session.game)
            frames(1)
            session.press()
            session.release()
            for _ in 0..<1200 {
                pilot.step()
                pilot.step()
                frames(1)
            }
            check("그리기를 거쳐 20초 난다 (\(Int(session.game.x))pt, \(Set(session.game.chunks).count)종 조각)", session.game.x > 3000)
        }
        model.endGame()

        // 달리기: 길게 눌러 가장 높이 뛰어도 무대 안에 있고 그림이 뒤집히지 않는다
        model.startGame(character: character)
        guard let session = model.game else { return false }
        key(49, down: true)
        key(49, down: false)
        // 첫 장애물이 오기 전에 시험한다
        frames(35)
        var top = 0.0
        key(49, down: true)
        for _ in 0..<40 {
            frames(1)
            top = max(top, session.game.runnerY)
        }
        key(49, down: false)
        check("점프가 무대 안에서 멈춘다 (발 높이 \(Int(top)))", top > 30 && top <= session.game.tuning.maxRise && top <= 135)
        let fit = CharacterScene.fitTransform(for: CGRect(x: 0, y: -30, width: 20, height: 20), in: 40...60)
        check("맞춤 배율이 음수가 되지 않는다", fit.a > 0 && fit.d > 0)
        key(53, down: true)
        check("esc로 달리기를 나간다", model.game == nil)
        print(failures == 0 ? "모두 통과" : "실패 \(failures)건")
        return failures == 0
    }
}
