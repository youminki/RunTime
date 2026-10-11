import AppKit
import GameCore
import SwiftUI

/// 최고 점수와 판 수. 이 Mac에만 저장한다.
enum GameRecords {
    static let bestKey = "gameBest"
    static let playsKey = "gamePlays"

    static var best: Int { UserDefaults.standard.integer(forKey: bestKey) }
    static var plays: Int { UserDefaults.standard.integer(forKey: playsKey) }

    static func finish(score: Int) {
        let defaults = UserDefaults.standard
        defaults.set(max(best, score), forKey: bestKey)
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
    var recordBanner: CGFloat = 0
    var finished = false
    /// 캐릭터별 게임 배율. 서 있는 모습을 재서 정한다.
    var scaleCache: [String: CGFloat] = [:]
    /// 판이 끝났을 때 바깥(순위 서버·말풍선)에 알린다.
    var onFinish: (RunnerGame) -> Void = { _ in }
    /// 게임 오버 화면에 덧붙일 순위 소식 ("전체 12위 · 340명"). 순위 서버 응답이 오면 바뀐다.
    var rankLine: String?
    /// 몇 번째 판인지. 앞 판의 순위 응답이 늦게 와 다음 판 화면에 붙지 않게 비교한다.
    private(set) var runID = 0
    /// 판을 시작할 때마다 최신 순위에서 앞에 있는 사람들을 받아 목표로 삼는다.
    var rivalSource: () -> [Rival] = { [] } {
        didSet { tracker = RivalTracker(rivals: rivalSource()) }
    }
    var tracker = RivalTracker(rivals: [])
    /// 방금 앞지른 사람 (배너).
    var overtaken: (name: String, life: CGFloat)?
    /// 이번 판 기록 (미션). 판이 끝나면 지갑에 한 번 넣는다.
    var jumps = 0
    var nearMisses = 0
    var credited = false
    /// Claude가 일하는 동안 한 판이면 코인을 두 배로 준다 (기다리는 동안 한 판).
    private(set) var boosted = false
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
    /// 지금 겨루는 고스트와 그 고스트를 그릴 러너 (그 판을 달린 러너, 이 Mac에 없으면 유령).
    private(set) var raceTarget: GhostRecord?
    var ghost: GhostRunner?
    var ghostCharacter = Runner.ghost.character
    /// 고스트와 겨루는 판. 코스를 미리 알고 하는 판이라 기록과 순위에 넣지 않는다.
    private(set) var isRace = false

    init(character: RunnerCharacter, live: Bool = true) {
        self.character = character
        self.live = live
        var tuning = RunnerGame.Tuning()
        tuning.catalog = GameAssets.catalog(runnerHeight: Self.runnerHeight)
        game = RunnerGame(tuning: tuning, runnerWidth: Self.runnerWidth, runnerHeight: Self.runnerHeight,
                          best: live ? GameRecords.best : 0)
        if live {
            savedGhost = GhostStore.load(for: game)
            TopGhost.all.refresh(for: game)
            TopGhost.week.refresh(for: game)
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
        if game.phase != .playing {
            isRace = false
            ghost = nil
            if live { game.setAbilities(GameWallet.shared.abilities) }
        }
        game.press()
        if wasOver, game.phase == .playing { restarted() }
    }

    /// 고스트 판과 같은 코스에서 그 고스트와 함께 달린다.
    func startRace(_ record: GhostRecord?) {
        guard let record, let seed = record.seedValue, game.phase != .playing else { return }
        game.prepare(seed: seed)
        guard game.phase == .ready else { return }   // 부딪힌 직전이라 아직 다시 시작할 수 없음
        ghost = GhostRunner(tuning: game.tuning, runnerWidth: Self.runnerWidth, runnerHeight: Self.runnerHeight,
                            seed: seed, inputs: record.inputs, abilities: record.abilities ?? RunnerGame.Abilities())
        if live { game.setAbilities(GameWallet.shared.abilities) }
        isRace = true
        raceTarget = record
        ghostCharacter = AppSettings.character(forRunnerID: record.runner) ?? Runner.ghost.character
        game.press()
        game.release()
    }

    /// 주간 1위 고스트. 전체 1위와 같은 판이면 두 번 보이지 않게 뺀다.
    var weekGhost: GhostRecord? {
        guard let week = TopGhost.week.record else { return nil }
        let all = TopGhost.all.record
        return all?.seed == week.seed && all?.score == week.score ? nil : week
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
            case 5, 18, 19:     // G 내 고스트, 1 전체 1위, 2 주간 1위 고스트. 판 중에는 삼키기만 한다
                if down, !event.isARepeat, self.game.phase != .playing {
                    switch event.keyCode {
                    case 5: self.startRace(self.savedGhost)
                    case 18: self.startRace(TopGhost.all.record)
                    default: self.startRace(self.weekGhost)
                    }
                }
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
        rankLine = nil
        runID += 1
        tracker = RivalTracker(rivals: isRace ? [] : rivalSource())
        overtaken = nil
        particles.removeAll()
        popups.removeAll()
        recordBanner = 0
        jumps = 0
        nearMisses = 0
        credited = false
        boosted = false
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
        if game.phase == .playing {
            for rival in tracker.update(score: game.score) { pass(rival) }
        }

        let k = CGFloat(dt)
        shake = max(0, shake - k * 14)
        flash = max(0, flash - k * 6)
        milestoneGlow = max(0, milestoneGlow - k * 1.6)
        recordBanner = max(0, recordBanner - k * 0.55)
        if let current = overtaken { overtaken = current.life > k ? (current.name, current.life - k) : nil }
        if let current = notice { notice = current.life > k ? (current.text, current.life - k) : nil }
        if let current = zoneBanner { zoneBanner = current.life > k ? (current.text, current.life - k) : nil }
        skyBlend = min(1, skyBlend + k / 1.5)
        updateTrail(k)
        updateBuddy()
        landBounce = max(0, landBounce - k * 7)
        for i in coinFlyers.indices { coinFlyers[i].t += k / 0.45 }
        coinFlyers.removeAll { $0.t >= 1 }
        if live, game.phase == .playing, !boosted, UsageEngine.isClaudeWorking { boosted = true }
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
            jumps += 1
            dust(at: feet, landing: false)
        case .landed:
            dust(at: feet, landing: true)
            landBounce = 1
        case .coin(let id):
            play(.coin)
            if let coin = game.coins.first(where: { $0.id == id }) {
                let point = CGPoint(screenX(coin.x), CGFloat(coin.y))
                burst(at: point, count: 8, color: NSColor(hex: 0xFFD45E), speed: 70, life: 0.45, drift: 0.6)
                coinFlyers.append(CoinFlyer(from: CGPoint(screenX(coin.x), groundY - CGFloat(coin.y))))
                popups.append(Popup(text: "+\(game.tuning.coinValue)", position: point, life: 0.8))
            }
        case .milestone:
            play(.milestone)
            milestoneGlow = 1
        case .airJumped:
            play(.airjump)
            jumps += 1
            let feet = CGPoint(runnerLeft + Self.runnerWidth / 2, CGFloat(game.runnerY))
            burst(at: feet, count: 10, colors: [.white, NSColor(hex: 0x8FD3FF)], shape: .spark, speed: 70, life: 0.4,
                  drift: 0.4, spread: 2)
        case .slammed(let id):
            shake = max(shake, 0.35)
            if let o = game.obstacles.first(where: { $0.id == id }) {
                burst(at: CGPoint(screenX(o.x) + CGFloat(o.width) / 2, 0), count: 10, color: NSColor(white: 0.85, alpha: 1),
                      speed: 80, life: 0.45, drift: 1)
            }
        case .shieldBroke:
            play(.shield)
            shake = 0.5
            let center = CGPoint(runnerLeft + Self.runnerWidth / 2, CGFloat(game.runnerY + Self.runnerHeight / 2))
            burst(at: center, count: 14, colors: [NSColor(hex: 0x8FD3FF), .white], shape: .spark, speed: 140, life: 0.6,
                  drift: 0, spread: 2)
            popups.append(Popup(text: "보호막!", position: center, life: 0.8))
        case .nearMiss:
            play(.nearmiss)
            nearMisses += 1
            let point = CGPoint(runnerLeft + Self.runnerWidth / 2, CGFloat(game.runnerY + Self.runnerHeight * 0.6))
            burst(at: point, count: 6, color: NSColor(hex: 0x8FD3FF), speed: 60, life: 0.4, drift: 0.5)
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
            let missionDone = creditRun()
            // 부딪힌 소리 뒤에 짧은 음악 하나: 이겼으면 팡파르, 미션을 채웠으면 미션 음악, 아니면 게임 오버
            let won = isRace ? (raceLead ?? 0) > 0 : game.isNewRecord
            let jingle: GameSound.Effect = won ? .fanfare : missionDone ? .mission : .gameover
            let run = runID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.runID == run, self.game.phase == .over else { return }
                self.play(jingle)
            }
            if !finished, !isRace {
                finished = true
                if live {
                    GameRecords.finish(score: game.score)
                    if game.score > savedGhost?.score ?? 0 {
                        let record = GhostStore.record(of: game, runner: AppSettings.shared.runnerID)
                        if GhostStore.save(record) { savedGhost = record }
                    }
                }
                onFinish(game)
            }
        }
    }

    /// 판이 끝나면 코인과 미션을 지갑에 넣는다. 고스트와 겨룬 판도 넣는다 (꾸미기에만 쓰는 코인이라).
    /// 미션·도전·업적을 새로 채웠으면 true.
    func creditRun() -> Bool {
        guard live, !credited else { return false }
        credited = true
        let run = DailyMissions.Run(coins: game.coinsTaken, nearMisses: nearMisses, score: game.score, jumps: jumps,
                                    wonRace: (raceLead ?? 0) > 0)
        let completed = GameWallet.shared.finishRun(run, bonusCoins: boosted ? game.coinsTaken : 0)
        if !completed.isEmpty {
            let reward = completed.reduce(0) { $0 + $1.coins }
            // 줄이 길면 무대 폭을 넘어 첫 보상과 개수만 쓴다
            let what = completed.count == 1 ? completed[0].title : "\(completed[0].title) 외 \(completed.count - 1)개"
            announce("\(what) +\(reward) · 퀘스트에서 받기", sound: false)
        }
        // 출석·레벨만 오른 판은 미션 음악을 내지 않는다 (날마다 첫 판이 늘 미션 음악이 되지 않게)
        return completed.contains { $0.id.first.map("dwa".contains) ?? false }
    }

    func announce(_ text: String, sound: Bool = true) {
        notice = (text, 3.5)
        if sound { play(.record) }
    }

    func play(_ effect: GameSound.Effect) {
        if live { GameSound.shared.play(effect) }
    }

    func pass(_ rival: Rival) {
        play(.milestone)
        overtaken = (rival.name, 1.6)
        let center = CGPoint(runnerLeft + Self.runnerWidth / 2, CGFloat(game.runnerY + Self.runnerHeight))
        burst(at: center, count: 10, color: NSColor(hex: 0xFFD45E), speed: 90, life: 0.6, drift: 0.4)
    }

    /// 다음 목표 깃발의 화면 x. 러너가 닿으면 점수가 목표를 넘는다 (코인을 먹으면 깃발이 당겨진다).
    /// 점수는 거리로만 세므로 앞뒤로 움직인 만큼 깃발도 같이 옮겨, 러너가 닿는 때와 넘는 때를 맞춘다.
    func flagX() -> CGFloat? {
        guard game.phase == .playing, let next = tracker.next else { return nil }
        let need = Double(next.score + 1 - game.coinsTaken * game.tuning.coinValue) / game.tuning.scorePerPoint
        return screenX(need) + CGFloat(game.runnerOffset) + CGFloat(Self.runnerWidth) / 2
    }
}
