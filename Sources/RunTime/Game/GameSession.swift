import AppKit
import GameCore
import SwiftUI

/// 난이도별 최고 점수, 판 수, 고른 난이도. 이 Mac에만 저장한다.
enum GameRecords {
    static let bestKey = "gameBest"
    static let playsKey = "gamePlays"
    private static let difficultyKey = "gameDifficulty"

    static var difficulty: RunDifficulty {
        get { UserDefaults.standard.string(forKey: difficultyKey).flatMap(RunDifficulty.init(rawValue:)) ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: difficultyKey) }
    }

    /// 보통은 난이도가 생기기 전 기록을 그대로 잇는다.
    private static func key(_ difficulty: RunDifficulty) -> String {
        difficulty == .normal ? bestKey : "\(bestKey).\(difficulty.rawValue)"
    }

    static var best: Int { best(difficulty) }
    static func best(_ difficulty: RunDifficulty) -> Int { UserDefaults.standard.integer(forKey: key(difficulty)) }
    static var plays: Int { UserDefaults.standard.integer(forKey: playsKey) }

    static func finish(_ difficulty: RunDifficulty, score: Int) {
        let defaults = UserDefaults.standard
        defaults.set(max(best(difficulty), score), forKey: key(difficulty))
        defaults.set(plays + 1, forKey: playsKey)
    }
}

/// 팝오버 무대 위의 한 판. 규칙(RunnerGame)과 화면·입력·소리를 잇고, 부딪힘·코인 같은 순간을 화면 효과로 바꾼다.
/// 메인 스레드에서만 쓴다. 그리는 동안 바뀌는 값은 @Published로 두지 않는다 (그리기 중 화면 갱신을 일으키지 않게).
final class GameSession {
    /// 러너 판정 상자. 캐릭터마다 그림 크기가 달라도 같은 조건으로 겨루게 고정한다.
    static let runnerWidth: Double = 24
    static let runnerHeight: Double = 40
    /// 러너 왼쪽 끝의 화면 x. 장애물을 볼 거리를 넉넉히 둔다.
    static let runnerX: CGFloat = 44
    /// 게임 중 캐릭터가 차지할 수 있는 크기 (pt). 판정 상자보다 조금 크게, 옆으로 긴 러너도 이 폭 안에 그린다.
    static let characterHeight: CGFloat = 46
    static let characterWidth: CGFloat = 40

    let game: RunnerGame
    private(set) var character: RunnerCharacter
    /// 사람이 하는 판. 아니면(점검 도구) 키를 받지 않고, 소리를 내지 않고, 기록도 남기지 않는다.
    let live: Bool
    /// 키를 받을 창 (팝오버). 다른 창으로 가는 키는 건드리지 않는다.
    var window: () -> NSWindow? = { nil }
    /// 세션이 열린 뒤 흐른 시간 (그린 장면 기준).
    var clock: Double = 0
    var lastDate: Date?
    var keyMonitor: Any?
    var resignObserver: Any?
    var particles: [Particle] = []
    var popups: [Popup] = []
    var shake: CGFloat = 0
    var flash: CGFloat = 0
    var milestoneGlow: CGFloat = 0
    /// 왼쪽 위 점수판의 불투명도. 러너나 장애물이 그 밑을 지나면 옅어진다.
    var hudAlpha: Double = 1
    var recordBanner: CGFloat = 0
    var finished = false
    /// 캐릭터별 게임 배율. 서 있는 모습을 재서 정한다.
    var scaleCache: [String: CGFloat] = [:]
    /// 판이 끝났을 때 바깥(말풍선)에 알린다.
    var onFinish: (RunnerGame) -> Void = { _ in }
    /// 몇 번째 판인지. 앞 판의 늦은 소리가 다음 판에 나지 않게 비교한다.
    private(set) var runID = 0
    /// 꼬리를 그릴 지난 자리들 (화면 x, 바닥 위 높이). 땅이 흐르는 만큼 뒤로 민다.
    var trail: [CGPoint] = []
    /// 점검 도구가 저장하지 않고 데려가 보는 동료.
    var companionOverride: RunnerCharacter?
    /// 동료가 따라 뛸 러너 높이 (오래된 것부터).
    var buddyHeights: [(time: Double, height: Double)] = []
    /// 점수판으로 날아가는 코인 (화면 좌표).
    struct CoinFlyer {
        let from: CGPoint
        var t: CGFloat = 0
    }
    var coinFlyers: [CoinFlyer] = []
    /// 마지막으로 그린 땅 높이 (코인이 날아오를 자리를 화면 좌표로 바꿀 때).
    var groundY: CGFloat = 135
    /// 착지 반동 (1에서 0으로).
    var landBounce: CGFloat = 0
    /// 하늘 구간. 500점마다 다음 하늘로 넘어가고, 1.5초 동안 섞어 바꾼다.
    var skyFrom = 0
    var skyTo: Int?
    var skyBlend: CGFloat = 1
    var zoneBanner: (text: String, life: CGFloat)?
    /// 게임 밖에서 온 소식 (Claude 작업 끝). 판을 멈추지 않고 아래쪽에 잠깐 띄운다.
    var notice: (text: String, life: CGFloat)?
    var onExit: () -> Void = {}
    /// 이 Mac의 최고 판. 고스트와 겨룰 때 같은 코스와 그때 움직임을 다시 돌린다.
    var savedGhost: GhostRecord?
    /// 지금 겨루는 고스트와 그 고스트를 그릴 러너 (그 판을 달린 러너, 이 Mac에 없으면 호박 잭).
    private(set) var raceTarget: GhostRecord?
    var ghost: GhostRunner?
    var ghostCharacter = Runner.jack.character
    /// 고스트와 겨루는 판. 코스를 미리 알고 하는 판이라 기록과 순위에 넣지 않는다.
    private(set) var isRace = false

    /// 이 판의 난이도. 점검 도구의 판은 늘 보통이다.
    let difficulty: RunDifficulty

    init(character: RunnerCharacter, live: Bool = true) {
        self.character = character
        self.live = live
        difficulty = live ? GameRecords.difficulty : .normal
        var tuning = RunnerGame.Tuning()
        difficulty.apply(to: &tuning)
        tuning.catalog = GameAssets.catalog(runnerHeight: Self.runnerHeight)
        game = RunnerGame(tuning: tuning, runnerWidth: Self.runnerWidth, runnerHeight: Self.runnerHeight,
                          best: live ? GameRecords.best(difficulty) : 0)
        if live {
            savedGhost = GhostStore.load(for: game, difficulty: difficulty)
            installKeys()
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func use(_ character: RunnerCharacter) { self.character = character }

    // MARK: 입력

    func press() {
        let wasOver = game.phase == .over
        let race = (isRace, ghost)
        if game.phase != .playing {
            isRace = false
            ghost = nil
        }
        game.press()
        // 부딪힌 직후라 다시 시작되지 않았으면 끝난 고스트 판 화면을 그대로 둔다
        if wasOver, game.phase == .over { (isRace, ghost) = race }
        game.countsTowardBest = !isRace
        if wasOver, game.phase == .playing { restarted() }
    }

    /// 고스트 판과 같은 코스에서 그 고스트와 함께 달린다.
    func startRace(_ record: GhostRecord?) {
        guard let record, let seed = record.seedValue, game.phase != .playing else { return }
        game.prepare(seed: seed)
        guard game.phase == .ready else { return }   // 부딪힌 직전이라 아직 다시 시작할 수 없음
        game.countsTowardBest = false
        ghost = GhostRunner(tuning: game.tuning, runnerWidth: Self.runnerWidth, runnerHeight: Self.runnerHeight,
                            seed: seed, inputs: record.inputs, abilities: record.abilities ?? RunnerGame.Abilities())
        isRace = true
        raceTarget = record
        ghostCharacter = AppSettings.character(forRunnerID: record.runner) ?? Runner.jack.character
        game.press()
        game.release()
    }

    /// 지금 점수에서 고스트 판의 최종 점수를 뺀 값 (겨루는 중에만). 넘으면 이긴다.
    var raceLead: Int? {
        guard isRace, let raceTarget else { return nil }
        return game.score - raceTarget.score
    }


    func release() { game.release() }

    /// 게임 중 팝오버 창으로 오는, 보조키 없는 키만 받는다. 다룬 키는 삼켜 경고음이 나지 않게 한다.
    /// 누른 키를 모두 놓은 것으로 한다. 키를 누른 채 다른 창을 누르면 뗀 신호가 오지 않아 계속 움직이거나 숙인 채 남는다.
    func releaseAllKeys() {
        game.setMove(back: false, forward: false)
        game.setDuck(false)
        game.release()
    }

    func installKeys() {
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, window === self.window() else { return }
            self.releaseAllKeys()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .rightMouseDown, .rightMouseUp]) {
            [weak self] event in
            guard let self, event.window != nil, event.window === self.window() else { return event }
            // 마우스로만 하는 사람도 낮게 나는 박쥐를 피하게 오른쪽 버튼을 누르는 동안 숙인다
            if event.type == .rightMouseDown || event.type == .rightMouseUp {
                guard self.game.phase == .playing || event.type == .rightMouseUp else { return event }
                self.game.setDuck(event.type == .rightMouseDown)
                return nil
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad, .capsLock]).isEmpty else { return event }
            // 같은 창의 글 칸(순위 닉네임 등)에 치는 글자를 게임이 가져가지 않게 한다
            if self.window()?.firstResponder is NSTextView { return event }
            let down = event.type == .keyDown
            switch event.keyCode {
            case 49, 126, 13:   // 스페이스, ↑, W
                if down, !event.isARepeat { self.press() }
                if !down { self.release() }
                return nil
            case 125, 1:        // ↓, S
                self.game.setDuck(down)
                return nil
            case 123, 0:        // ←, A
                self.game.setMove(back: down)
                return nil
            case 124, 2:        // →, D
                self.game.setMove(forward: down)
                return nil
            case 5:             // G 내 고스트. 판 중에는 삼키기만 한다
                if down, !event.isARepeat, self.game.phase != .playing { self.startRace(self.savedGhost) }
                return nil
            case 53:            // esc
                if down { self.onExit() }
                return nil
            default:
                return event
            }
        }
    }

    func restarted() {
        finished = false
        runID += 1
        particles.removeAll()
        popups.removeAll()
        recordBanner = 0
        trail.removeAll()
        skyTo = nil
        zoneBanner = nil
    }

    // MARK: 한 프레임

    /// 시간을 보내고 일어난 일을 소리·효과로 바꾼다.
    func update(date: Date) {
        let dt = min(max(date.timeIntervalSince(lastDate ?? date), 0), 0.1)
        lastDate = date
        clock += dt
        game.advance(by: dt)
        ghost?.advance(by: dt)
        for event in game.drainEvents() { handle(event) }

        let k = CGFloat(dt)
        shake = max(0, shake - k * 14)
        flash = max(0, flash - k * 6)
        milestoneGlow = max(0, milestoneGlow - k * 1.6)
        recordBanner = max(0, recordBanner - k * 0.55)
        if let current = notice { notice = current.life > k ? (current.text, current.life - k) : nil }
        if let current = zoneBanner { zoneBanner = current.life > k ? (current.text, current.life - k) : nil }
        skyBlend = min(1, skyBlend + k / 1.5)
        updateTrail(k)
        updateBuddy()
        landBounce = max(0, landBounce - k * 7)
        for i in coinFlyers.indices { coinFlyers[i].t += k / 0.45 }
        coinFlyers.removeAll { $0.t >= 1 }
        for i in particles.indices {
            particles[i].velocity.y += particles[i].gravity * k
            particles[i].position.x += particles[i].velocity.x * k - CGFloat(game.phase == .playing ? game.speed : 0) * k * particles[i].drift
            particles[i].position.y += particles[i].velocity.y * k
            particles[i].life -= k
        }
        particles.removeAll { $0.life <= 0 }
        for i in popups.indices {
            popups[i].position.y += 26 * k
            popups[i].life -= k
        }
        popups.removeAll { $0.life <= 0 }
    }

    func handle(_ event: RunnerGame.Event) {
        let feet = CGPoint(runnerLeft + Self.runnerWidth / 2, 0)
        switch event {
        case .started:
            restarted()
        case .jumped:
            play(.jump)
            dust(at: feet, landing: false)
        case .landed:
            dust(at: feet, landing: true)
            landBounce = 1
        case .coin(let id, let value, let combo):
            play(.coin)
            if let coin = game.coins.first(where: { $0.id == id }) {
                let point = CGPoint(screenX(coin.x), CGFloat(coin.y))
                // 콤보가 오를수록 반짝임이 커져 이어 먹는 맛이 난다
                burst(at: point, count: 2 + min(combo, 5), shape: .sprite("plasmaSparkle"), speed: 50 + CGFloat(min(combo, 5)) * 8,
                      life: 0.45, drift: 0.6, size: 1.2...1.6)
                coinFlyers.append(CoinFlyer(from: CGPoint(screenX(coin.x), groundY - CGFloat(coin.y))))
                // 이어서 먹은 코인은 떠 있는 팝업 하나에 더해 글자가 겹치지 않게 한다
                let tag = combo >= 2 ? " ×\(min(combo, game.tuning.maxCoinCombo))" : ""
                if let i = popups.lastIndex(where: { $0.coins > 0 && $0.life > 0.35 }) {
                    popups[i].coins += value
                    popups[i].text = "+\(popups[i].coins)" + tag
                    popups[i].life = 0.8
                } else {
                    popups.append(Popup(text: "+\(value)" + tag, position: point, life: 0.8, coins: value))
                }
            }
        case .milestone:
            play(.milestone)
            milestoneGlow = 1
        case .airJumped:
            play(.airjump)
            let feet = CGPoint(runnerLeft + Self.runnerWidth / 2, CGFloat(game.runnerY))
            burst(at: feet, count: 4, shape: .sprite("puff"), speed: 50, life: 0.45, drift: 0.4, spread: 2, size: 1.3...1.8)
        case .slammed(let id):
            shake = max(shake, 0.35)
            if let o = game.obstacles.first(where: { $0.id == id }) {
                burst(at: CGPoint(screenX(o.x) + CGFloat(o.width) / 2, 0), count: 4, shape: .sprite("smokePoff"), speed: 60,
                      life: 0.5, drift: 1, size: 1.4...2.0)
            }
        case .shieldBroke:
            play(.shield)
            shake = 0.5
            let center = CGPoint(runnerLeft + Self.runnerWidth / 2, CGFloat(game.runnerY + Self.runnerHeight / 2))
            burst(at: center, count: 1, shape: .sprite("plasmaBubble"), speed: 0, life: 0.6, drift: 0, spread: 2, size: 7...7,
                  gravity: 0)
            burst(at: center, count: 8, shape: .sprite("pumpingHeart"), speed: 120, life: 0.6, drift: 0, spread: 2,
                  size: 1.0...1.4)
            popups.append(Popup(text: "보호막!", position: center, life: 0.8))
        case .nearMiss:
            play(.nearmiss)
            let point = CGPoint(runnerLeft + Self.runnerWidth / 2, CGFloat(game.runnerY + Self.runnerHeight * 0.6))
            burst(at: point, count: 4, shape: .sprite("plasmaPuff"), speed: 50, life: 0.4, drift: 0.5, size: 1.0...1.4)
            popups.append(Popup(text: "아슬!", position: point, life: 0.7))
        case .newRecord where !isRace:
            play(.record)
            recordBanner = 1
        case .newRecord:
            break
        case .crashed:
            play(.hit)
            shake = 1
            flash = 1
            let center = CGPoint(runnerLeft + Self.runnerWidth / 2, CGFloat(game.runnerY + Self.runnerHeight / 2))
            crashBurst(at: center)
            // 부딪힌 소리 뒤에 짧은 음악 하나: 이겼으면 팡파르, 아니면 게임 오버
            let won = isRace ? (raceLead ?? 0) > 0 : game.isNewRecord
            let jingle: GameSound.Effect = won ? .fanfare : .gameover
            let run = runID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.runID == run, self.game.phase == .over else { return }
                self.play(jingle)
            }
            if !finished, !isRace {
                finished = true
                if live {
                    GameRecords.finish(difficulty, score: game.score)
                    if game.score > savedGhost?.score ?? 0 {
                        let record = GhostStore.record(of: game, runner: AppSettings.shared.runnerID)
                        if GhostStore.save(record, difficulty: difficulty) { savedGhost = record }
                    }
                }
                onFinish(game)
            }
        }
    }

    func announce(_ text: String, sound: Bool = true) {
        notice = (text, 3.5)
        if sound { play(.record) }
    }

    func play(_ effect: GameSound.Effect) {
        if live { GameSound.shared.play(effect) }
    }

}
