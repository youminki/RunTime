import Testing
@testable import GameCore

/// 앱(GameAssets.catalog)과 같은 장애물 목록. 크기는 Assets/Game 스프라이트의 그림 영역을 2배로 잰 값이다.
private func catalog() -> [RunnerGame.ObstacleKind] {
    [
        .init(id: "spikes", width: 36, height: 18, groupSpeed: 300),
        .init(id: "mushroom", width: 24, height: 24),
        .init(id: "cactus", width: 28, height: 36, groupSpeed: 420),
        .init(id: "tree", width: 24, height: 36, minSpeed: 300, minGap: 130),
        .init(id: "crab", width: 30, height: 28, minSpeed: 260, minGap: 140, approachSpeed: 40),
        .init(id: "drill", width: 32, height: 38, minSpeed: 380, minGap: 160, approachSpeed: 70),
        .init(id: "bat", width: 48, height: 34, elevations: [22, 50], minSpeed: 330, minGap: 150),
        .init(id: "spikeball", width: 36, height: 36, minSpeed: 340, minGap: 150, approachSpeed: 110),
        .init(id: "crusher", width: 36, height: 33, minSpeed: 300, minGap: 150, dropFrom: 72),
    ]
}

/// 앱의 판정 상자 (GameSession.runnerWidth, runnerHeight).
private let runnerSize = (width: 24.0, height: 40.0)

private func makeGame(seed: UInt64 = 7, best: Int = 0, catalog: [RunnerGame.ObstacleKind] = catalog()) -> RunnerGame {
    var tuning = RunnerGame.Tuning()
    tuning.catalog = catalog
    return RunnerGame(tuning: tuning, runnerWidth: runnerSize.width, runnerHeight: runnerSize.height, best: best,
                      seed: seed)
}

private func autoplay(_ game: RunnerGame, seconds: Double) {
    let pilot = Autopilot(game: game)
    for _ in 0..<Int(seconds * 60) where game.phase == .playing {
        pilot.step()
        game.advance(by: 1.0 / 60)
    }
}

/// 판정 없이 굴리며 러너 앞끝이 장애물 앞끝에 닿는 시각을 잰다. 걸어오는 적도 실제로 만나는 때로 잰다.
private func meetings(seed: UInt64, seconds: Double) -> [(time: Double, obstacle: RunnerGame.Obstacle)] {
    let game = makeGame(seed: seed)
    game.ignoresCollisions = true
    game.press()
    game.release()
    var met: [Int: (Double, RunnerGame.Obstacle)] = [:]
    for _ in 0..<Int(seconds * 120) {
        game.advance(by: 1.0 / 120)
        for o in game.obstacles where met[o.id] == nil && o.x <= game.runnerBox.maxX {
            met[o.id] = (game.elapsed, o)
        }
    }
    return met.values.sorted { $0.0 < $1.0 }.map { (time: $0.0, obstacle: $0.1) }
}

@Suite struct RunnerGameTests {
    @Test func startsOnFirstPressAndJumps() {
        let game = makeGame()
        #expect(game.phase == .ready)
        game.press()
        #expect(game.phase == .playing)
        game.advance(by: 0.05)
        #expect(game.runnerY > 0)
        #expect(game.drainEvents().contains(.jumped))
    }

    @Test func fullJumpReachesExpectedApexAndLands() {
        let game = makeGame()
        game.press()   // 계속 누르고 있다
        var apex = 0.0
        for _ in 0..<120 {
            game.advance(by: 1.0 / 120)
            apex = max(apex, game.runnerY)
        }
        let expected = game.tuning.jumpVelocity * game.tuning.jumpVelocity / (2 * game.tuning.gravity)
        #expect(abs(apex - expected) < 3)
        #expect(game.isOnGround)
    }

    @Test func shortTapJumpsLower() {
        func apex(holding: Bool) -> Double {
            let game = makeGame()
            game.press()
            game.advance(by: 1.0 / 60)
            if !holding { game.release() }
            var top = 0.0
            for _ in 0..<60 {
                game.advance(by: 1.0 / 60)
                top = max(top, game.runnerY)
            }
            return top
        }
        #expect(apex(holding: false) < apex(holding: true) * 0.8)
    }

    @Test func jumpPressedJustBeforeLandingIsKept() {
        let game = makeGame()
        game.press()
        game.release()
        game.advance(by: 0.05)   // 떠오른 뒤
        // 내려오다 바닥 가까이에서 누른다 (jumpBuffer 안)
        while !(game.velocityY < 0 && game.runnerY < 12) { game.advance(by: 1.0 / 120) }
        game.press()
        _ = game.drainEvents()
        for _ in 0..<20 { game.advance(by: 1.0 / 120) }
        let events = game.drainEvents()
        #expect(events.contains(.landed))
        #expect(events.contains(.jumped))
    }

    @Test func standingStillCrashesAndKeepsBest() {
        let game = makeGame(best: 3)
        game.press()
        game.release()
        for _ in 0..<1_200 where game.phase == .playing { game.advance(by: 0.05) }
        #expect(game.phase == .over)
        #expect(game.crashedInto != nil)
        #expect(game.best >= 3)
        #expect(game.drainEvents().contains(.crashed))
    }

    @Test func restartWaitsBriefly() {
        let game = makeGame()
        game.press()
        for _ in 0..<1_000 where game.phase == .playing { game.advance(by: 0.1) }
        game.press()
        #expect(game.phase == .over)
        game.advance(by: game.tuning.restartDelay + 0.01)
        game.press()
        #expect(game.phase == .playing)
        #expect(game.score == 0)
        #expect(game.distance == 0)
    }

    @Test func speedRampsUpToMax() {
        let game = makeGame(catalog: [])   // 장애물 없이
        game.press()
        game.advance(by: 0.2)
        let early = game.speed
        for _ in 0..<2_000 { game.advance(by: 0.25) }
        #expect(early < game.speed)
        #expect(game.speed == game.tuning.maxSpeed)
    }

    @Test func speedKeepsRisingSlowlyAfterRamp() {
        let game = makeGame(catalog: [])
        game.press()
        let rampTime = (game.tuning.rampSpeed - game.tuning.startSpeed) / game.tuning.acceleration
        for _ in 0..<Int((rampTime + 10) * 4) { game.advance(by: 0.25) }
        #expect(game.speed > game.tuning.rampSpeed + 5)
        #expect(game.speed < game.tuning.rampSpeed + 15)
    }

    /// 압박이 차면 같은 속도에서도 장애물이 더 촘촘해진다.
    @Test func obstaclesGetDenserOverTime() {
        func perSecond(from start: Double, to end: Double) -> Double {
            var total = 0.0
            for seed in 1...8 as ClosedRange<UInt64> {
                let met = meetings(seed: seed, seconds: end).filter { $0.time >= start && $0.obstacle.y == 0 }
                total += Double(met.count) / (end - start)
            }
            return total / 8
        }
        #expect(perSecond(from: 130, to: 160) > perSecond(from: 40, to: 70) * 1.1)
    }

    /// 문은 최고 속도 근처에서 나오고, 끝까지 누른 점프는 박쥐에 닿지만 가장 짧은 점프는 지나간다.
    @Test func gatesNeedShortHop() {
        let game = makeGame()
        let tuning = game.tuning
        let ceiling = tuning.gateCeiling(runnerHeight: runnerSize.height)
        #expect(tuning.shortHop.apex + runnerSize.height < ceiling + tuning.hitInset)
        let fullApex = tuning.jumpVelocity * tuning.jumpVelocity / (2 * tuning.gravity)
        #expect(fullApex + runnerSize.height > ceiling + tuning.hitInset + 8)
        var gates = 0
        for seed in 1...10 as ClosedRange<UInt64> {
            let met = meetings(seed: seed, seconds: 150)
            for (time, o) in met where o.y == ceiling {
                gates += 1
                #expect(time > 30)
                let ground = met.first { $0.obstacle.y == 0 && abs($0.time - time) < 0.1 }?.obstacle
                #expect(ground != nil)
                if let ground {
                    #expect(game.canHop(width: ground.width, top: ground.height, ceiling: ceiling,
                                        closingSpeed: ground.spawnSpeed))
                }
            }
        }
        #expect(gates > 10)
    }

    @Test func scoreGrowsWithDistanceAndCoins() {
        let game = makeGame(catalog: [])
        game.press()
        game.advance(by: 0.25)
        game.advance(by: 0.25)
        #expect(game.score == Int(game.distance * game.tuning.scorePerPoint))
    }

    @Test func sameSeedSamePattern() {
        let a = makeGame(seed: 42), b = makeGame(seed: 42)
        a.press(); b.press()
        a.advance(by: 0.2); b.advance(by: 0.2)
        #expect(a.obstacles.map(\.x) == b.obstacles.map(\.x))
        #expect(a.obstacles.map(\.kind.id) == b.obstacles.map(\.kind.id))
    }

    /// 어떤 씨앗이든 만든 장애물은 뛰어넘거나 아래로 지나갈 수 있다.
    @Test(arguments: Array(UInt64(1)...UInt64(40)))
    func everyObstacleIsPassable(seed: UInt64) {
        let game = makeGame(seed: seed)
        let met = meetings(seed: seed, seconds: 100)
        #expect(met.count > 70)
        #expect(Set(met.map(\.obstacle.kind.id)).count == catalog().count)
        for (_, o) in met {
            let closing = o.spawnSpeed + o.kind.approachSpeed
            let under = o.y + game.tuning.hitInset >= runnerSize.height + 2
            let duck = o.y > 0 && game.canDuckUnder(o.y)
            let over = game.canJump(width: o.width, top: o.y + o.height, closingSpeed: closing)
            #expect(under || duck || over, "seed \(seed) \(o.kind.id) ×\(o.count) at y \(o.y) closing \(closing)")
        }
    }

    /// 걸어오는 적까지 포함해, 앞 장애물을 만난 뒤 다음 장애물을 만나기까지 한 번 뛰고 다시 뛸 시간이 있다.
    @Test(arguments: Array(UInt64(1)...UInt64(40)))
    func everyGapLeavesTimeToLandAndJumpAgain(seed: UInt64) {
        let tuning = RunnerGame.Tuning()
        // 문 위 박쥐는 땅 장애물과 같이 만나니 서서 지나가는 높이의 장애물은 뺀다
        let met = meetings(seed: seed, seconds: 150).filter { $0.obstacle.y + tuning.hitInset < runnerSize.height + 2 }
        for (a, b) in zip(met, met.dropFirst()) {
            let between = b.time - a.time
            #expect(between >= tuning.airTime + tuning.lateReactionTime - 0.03,
                    "seed \(seed) \(a.obstacle.kind.id) → \(b.obstacle.kind.id): \(between)s")
        }
    }

    @Test func sameKindNeverMoreThanTwiceInARow() {
        let game = makeGame(seed: 9)
        game.ignoresCollisions = true
        game.press()
        var order: [Int: String] = [:]
        for _ in 0..<3_000 {
            for o in game.obstacles { order[o.id] = o.kind.id }
            game.advance(by: 1.0 / 30)
        }
        let kinds = order.sorted { $0.key < $1.key }.map(\.value)
        for i in 2..<max(kinds.count, 2) where kinds.count > 2 {
            #expect(!(kinds[i] == kinds[i - 1] && kinds[i] == kinds[i - 2]))
        }
    }

    @Test(arguments: [UInt64(3), 11, 29])
    func autoplayerSurvivesLongWhenJumpingAtTheRightTime(seed: UInt64) {
        let game = makeGame(seed: seed)
        game.press()
        game.release()
        autoplay(game, seconds: 120)
        let hit = game.obstacles.first { $0.id == game.crashedInto }
        #expect(game.elapsed > 60, "crashed at \(game.elapsed)s speed \(game.speed) into \(hit.map { "\($0.kind.id)×\($0.count) y\($0.y)" } ?? "-") runnerY \(game.runnerY)")
    }

    /// 내리찍는 상자는 러너가 닿기 전에 땅에 내려와, 내려온 걸 보고 뛸 시간이 남는다.
    @Test func crusherLandsWellBeforeRunnerArrives() {
        var landedAhead: [Double] = []
        for seed in 1...10 as ClosedRange<UInt64> {
            let game = makeGame(seed: seed)
            game.ignoresCollisions = true
            game.press()
            game.release()
            var seen = Set<Int>()
            for _ in 0..<(120 * 90) {
                game.advance(by: 1.0 / 120)
                for case .slammed(let id) in game.drainEvents() {
                    guard let o = game.obstacles.first(where: { $0.id == id }), seen.insert(id).inserted else { continue }
                    landedAhead.append((o.x - game.runnerBox.maxX) / game.speed)
                }
            }
        }
        #expect(landedAhead.count > 5)
        // 떨어지는 데 0.2초쯤 걸리니 닿기 0.45초 넘게 앞서 내려온다
        #expect(landedAhead.allSatisfy { $0 > 0.45 }, "\(landedAhead)")
    }

    /// 낮게 나는 박쥐를 뛰어넘을 수 있다고 칠 때는 사람이 누를 시각에 여유가 있어야 한다.
    @Test func lowFlyerJumpNeedsSlackOtherwiseDuck() {
        let game = makeGame()
        let bat = catalog().first { $0.id == "bat" }!
        #expect(!game.canJump(width: bat.width, top: 22 + bat.height, closingSpeed: 400))
        #expect(game.canDuckUnder(22))
        #expect(!game.canDuckUnder(10))
    }

    @Test func duckingPassesLowFlyer() {
        let bat = RunnerGame.ObstacleKind(id: "bat", width: 36, height: 20, elevations: [26], minGap: 150)
        let game = makeGame(seed: 1, catalog: [bat])
        game.press()
        game.release()
        game.setDuck(true)
        var passed = Set<Int>()
        for _ in 0..<400 where game.phase == .playing {
            game.advance(by: 1.0 / 30)
            for o in game.obstacles where o.x + o.width < game.runnerBox.minX { passed.insert(o.id) }
        }
        #expect(game.phase == .playing)
        #expect(passed.count >= 3)
    }

    @Test func newRecordAnnouncedOnceWhenPassingBest() {
        let game = makeGame(best: 5, catalog: [])
        game.press()
        var records = 0
        for _ in 0..<40 {
            game.advance(by: 0.25)
            records += game.drainEvents().filter { $0 == .newRecord }.count
        }
        #expect(records == 1)
        #expect(game.isNewRecord)
    }

    @Test func milestoneEveryHundred() {
        let game = makeGame(catalog: [])
        game.press()
        var milestones: [Int] = []
        for _ in 0..<200 {
            game.advance(by: 0.25)
            for case .milestone(let m) in game.drainEvents() { milestones.append(m) }
        }
        #expect(milestones.prefix(3) == [100, 200, 300])
    }
}

@Suite struct RunnerGameJumpTests {
    @Test func evenATinyTapClearsMinimumHeight() {
        var tuning = RunnerGame.Tuning()
        tuning.catalog = []
        let game = RunnerGame(tuning: tuning, runnerWidth: runnerSize.width, runnerHeight: runnerSize.height, seed: 1)
        game.press()
        game.release()   // 한 프레임도 안 누름
        var apex = 0.0
        for _ in 0..<120 {
            game.advance(by: 1.0 / 120)
            apex = max(apex, game.runnerY)
        }
        #expect(apex >= tuning.minJumpHeight)
        #expect(apex < tuning.jumpVelocity * tuning.jumpVelocity / (2 * tuning.gravity) * 0.85)
    }
}

@Suite struct RunnerGameCrashTests {
    @Test func crashingInTheAirFallsToTheGround() {
        let bat = RunnerGame.ObstacleKind(id: "bat", width: 36, height: 20, elevations: [60], minGap: 150)
        var tuning = RunnerGame.Tuning()
        tuning.catalog = [bat]
        let game = RunnerGame(tuning: tuning, runnerWidth: runnerSize.width, runnerHeight: runnerSize.height, seed: 2)
        game.press()   // 계속 누른 채 뛰어 높은 박쥐에 부딪힌다
        for _ in 0..<2_000 where game.phase == .playing {
            if game.isOnGround {
                game.release()
                game.press()
            }
            game.advance(by: 1.0 / 60)
        }
        #expect(game.phase == .over)
        let crashedAt = game.runnerY
        game.advance(by: 1)
        #expect(crashedAt > 0)
        #expect(game.runnerY == 0)
        #expect(game.isOnGround)
    }
}

@Suite struct RunnerGameDuckTests {
    @Test func jumpingWhileHoldingDuckStillReachesMinimumHeight() {
        let game = makeGame(catalog: [])
        game.press()
        game.release()
        game.advance(by: 0.3)   // 첫 점프가 끝나게
        game.setDuck(true)
        game.press()
        var apex = 0.0
        for _ in 0..<120 {
            game.advance(by: 1.0 / 120)
            apex = max(apex, game.runnerY)
        }
        #expect(apex >= game.tuning.minJumpHeight)
    }
}

@Suite struct RunnerGameMoveTests {
    @Test func movesWithinRange() {
        let game = makeGame(catalog: [])
        game.press()
        game.release()
        game.setMove(forward: true)
        game.advance(by: 0.25)
        #expect(game.runnerOffset > 0)
        game.advance(by: 0.25)
        game.advance(by: 0.25)
        game.advance(by: 0.25)
        #expect(game.runnerOffset == game.tuning.maxAdvance)
        game.setMove(back: true)
        game.advance(by: 0.25)
        #expect(game.runnerOffset == game.tuning.maxAdvance)   // 둘 다 누르면 서 있는다
        game.setMove(forward: false)
        for _ in 0..<8 { game.advance(by: 0.25) }
        #expect(game.runnerOffset == -game.tuning.maxRetreat)
    }

    @Test func doesNotMoveBeforeStart() {
        let game = makeGame(catalog: [])
        game.setMove(forward: true)
        game.advance(by: 1)
        #expect(game.runnerOffset == 0)
    }

    @Test func movingShiftsHitBoxButNotScore() {
        let still = makeGame(seed: 3)
        let moving = makeGame(seed: 3)
        for game in [still, moving] {
            game.ignoresCollisions = true
            game.press()
            game.release()
        }
        moving.setMove(forward: true)
        for _ in 0..<600 {
            still.advance(by: 1.0 / 120)
            moving.advance(by: 1.0 / 120)
        }
        #expect(moving.runnerBox.minX - still.runnerBox.minX == moving.runnerOffset)
        #expect(moving.runnerOffset == moving.tuning.maxAdvance)
        // 코인을 더 먹었을 수 있으니 거리 점수만 비교한다
        let distanceScore = { (g: RunnerGame) in g.score - g.coinsTaken * g.tuning.coinValue }
        #expect(distanceScore(moving) == distanceScore(still))
    }

    @Test func restartReturnsHomeAndReleasesKeys() {
        let game = makeGame()
        game.press()
        game.release()
        game.setMove(forward: true)
        for _ in 0..<(60 * 60) where game.phase == .playing { game.advance(by: 1.0 / 60) }
        #expect(game.phase == .over)
        #expect(game.runnerOffset > 0)
        game.advance(by: 1)
        game.press()
        #expect(game.phase == .playing)
        #expect(game.runnerOffset == 0)
        #expect(game.moveDirection == 0)
    }
}

@Suite struct GhostRunnerTests {
    /// 사람처럼 들쭉날쭉한 프레임 간격에, 프레임 사이에 키를 넣으며 한 판을 끝까지 한다.
    private func playOnce(_ game: RunnerGame, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let pilot = Autopilot(game: game)
        game.setDuck(true)   // 시작 전부터 누르고 있던 키도 고스트가 따라 해야 한다
        game.press()
        game.setDuck(false)
        for frame in 0..<(60 * 120) where game.phase == .playing {
            pilot.step()
            if frame % 47 == 0 { game.setMove(forward: rng.unit() < 0.5) }
            if frame % 31 == 0 { game.setMove(back: rng.unit() < 0.3) }
            if frame % 53 == 0 { game.setDuck(rng.unit() < 0.2) }
            game.advance(by: 1.0 / 60 + (rng.unit() - 0.5) * 0.008)
        }
    }

    private func replay(_ game: RunnerGame) -> RunnerGame {
        let ghost = GhostRunner(tuning: game.tuning, runnerWidth: game.runnerWidth, runnerHeight: game.runnerHeight,
                                seed: game.seed, inputs: game.inputLog)
        for _ in 0..<(60 * 180) where ghost.game.phase == .playing { ghost.advance(by: 1.0 / 90) }
        return ghost.game
    }

    @Test(arguments: [1, 2, 3] as [UInt64]) func replaysTheSameRun(seed: UInt64) {
        let game = makeGame(seed: seed)
        playOnce(game, seed: seed)
        #expect(game.phase == .over)
        let ghost = replay(game)
        #expect(ghost.phase == .over)
        #expect(ghost.ticks == game.ticks)
        #expect(ghost.score == game.score)
        #expect(ghost.coinsTaken == game.coinsTaken)
        #expect(ghost.runnerOffset == game.runnerOffset)
    }

    @Test func restartedRunGetsNewSeedAndReplays() {
        let game = makeGame(seed: 5)
        playOnce(game, seed: 5)
        let first = game.seed
        game.advance(by: 1)
        playOnce(game, seed: 6)
        #expect(game.seed != first)
        #expect(replay(game).score == game.score)
    }

    @Test func preparedSeedGivesSameCourse() {
        let a = makeGame(seed: 1)
        let b = makeGame(seed: 2)
        a.prepare(seed: 99)
        b.prepare(seed: 99)
        for game in [a, b] {
            game.ignoresCollisions = true
            game.press()
            game.advance(by: 5)
        }
        #expect(a.obstacles == b.obstacles)
        #expect(a.coins == b.coins)
    }
}

@Suite struct RunnerGameNearMissTests {
    private func nearMisses(seed: UInt64, gap: Double) -> (ids: [Int], game: RunnerGame) {
        var tuning = RunnerGame.Tuning()
        tuning.catalog = catalog()
        tuning.nearMissGap = gap
        let game = RunnerGame(tuning: tuning, runnerWidth: runnerSize.width, runnerHeight: runnerSize.height, seed: seed)
        let pilot = Autopilot(game: game)
        game.press()
        var ids: [Int] = []
        for _ in 0..<(60 * 60) where game.phase == .playing {
            pilot.step()
            game.advance(by: 1.0 / 60)
            for case .nearMiss(let id) in game.drainEvents() { ids.append(id) }
        }
        return (ids, game)
    }

    @Test func firesOncePerObstacleWithoutChangingScore() {
        var total = 0
        for seed in 1...6 as ClosedRange<UInt64> {
            let (ids, _) = nearMisses(seed: seed, gap: 7)
            #expect(Set(ids).count == ids.count)
            total += ids.count
        }
        #expect(total > 0)
        // 연출만 하므로 같은 판이면 기준을 바꿔도 점수가 같다
        let loose = nearMisses(seed: 3, gap: 1000).game
        let strict = nearMisses(seed: 3, gap: -1000).game
        #expect(loose.score == strict.score)
    }

    @Test func wideClearanceIsNotNearMiss() {
        #expect(nearMisses(seed: 2, gap: -1000).ids.isEmpty)
    }
}

@Suite struct RunnerGameAbilityTests {
    private func game(_ abilities: RunnerGame.Abilities, catalog: [RunnerGame.ObstacleKind] = [], seed: UInt64 = 7) -> RunnerGame {
        var tuning = RunnerGame.Tuning()
        tuning.catalog = catalog
        return RunnerGame(tuning: tuning, runnerWidth: runnerSize.width, runnerHeight: runnerSize.height, seed: seed,
                          abilities: abilities)
    }

    private func apex(_ game: RunnerGame, pressAgainAfter: Double?) -> Double {
        game.press()
        var top = 0.0, t = 0.0, pressed = false
        for _ in 0..<240 {
            game.advance(by: 1.0 / 120)
            t += 1.0 / 120
            if let after = pressAgainAfter, t >= after, !pressed {
                game.release()
                game.press()
                pressed = true
            }
            top = max(top, game.runnerY)
        }
        return top
    }

    @Test func airJumpGoesHigherOnlyWhenOwned() {
        let plain = apex(game(.init()), pressAgainAfter: 0.2)
        let double = apex(game(.init(airJumps: 1)), pressAgainAfter: 0.2)
        #expect(double > plain + 20)
    }

    @Test func airJumpsRefillOnLanding() {
        let g = game(.init(airJumps: 1))
        g.press(); g.release()
        g.advance(by: 0.15)
        g.press(); g.release()
        g.advance(by: 1.0 / 60)
        #expect(g.drainEvents().contains(.airJumped))
        #expect(g.airJumpsLeft == 0)
        for _ in 0..<90 { g.advance(by: 1.0 / 60) }
        #expect(g.isOnGround)
        #expect(g.airJumpsLeft == 1)
    }

    @Test func glideFallsSlower() {
        func timeToLand(_ glide: Bool) -> Double {
            let g = game(.init(glide: glide))
            g.press()   // 누른 채로 둔다
            var t = 0.0
            g.advance(by: 0.05)
            while !g.isOnGround, t < 5 { g.advance(by: 1.0 / 120); t += 1.0 / 120 }
            return t
        }
        #expect(timeToLand(true) > timeToLand(false) + 0.3)
    }

    @Test func shieldAbsorbsOneHitThenCrashes() {
        let wall = [RunnerGame.ObstacleKind(id: "mushroom", width: 24, height: 24)]
        let g = game(.init(shields: 1), catalog: wall)
        g.press(); g.release()
        var broke = 0
        for _ in 0..<(60 * 60) where g.phase == .playing {
            g.advance(by: 1.0 / 60)
            broke += g.drainEvents().filter { if case .shieldBroke = $0 { return true } else { return false } }.count
        }
        #expect(broke == 1)
        #expect(g.phase == .over)
        #expect(g.shieldsLeft == 0)
    }

    @Test func magnetCollectsCoinsOtherwiseMissed() {
        func coins(_ magnet: Int) -> Int {
            let g = game(.init(magnet: magnet), catalog: catalog(), seed: 4)
            let pilot = Autopilot(game: g)
            g.press()
            for _ in 0..<(60 * 40) where g.phase == .playing {
                pilot.step()
                g.advance(by: 1.0 / 60)
            }
            return g.coinsTaken
        }
        #expect(coins(3) > coins(0))
    }

    @Test func ghostReplaysWithAbilities() {
        let abilities = RunnerGame.Abilities(airJumps: 1, shields: 2, magnet: 2, glide: true)
        let g = game(abilities, catalog: catalog(), seed: 9)
        var rng = SplitMix64(seed: 9)
        g.press()
        for frame in 0..<(60 * 90) where g.phase == .playing {
            if frame % 23 == 0 { rng.unit() < 0.5 ? g.press() : g.release() }
            g.advance(by: 1.0 / 60)
        }
        let ghost = GhostRunner(tuning: g.tuning, runnerWidth: g.runnerWidth, runnerHeight: g.runnerHeight,
                                seed: g.seed, inputs: g.inputLog, abilities: abilities)
        #expect(ghost.finalScore(maxTicks: 120 * 600) == g.score)
        let without = GhostRunner(tuning: g.tuning, runnerWidth: g.runnerWidth, runnerHeight: g.runnerHeight,
                                  seed: g.seed, inputs: g.inputLog)
        #expect(without.finalScore(maxTicks: 120 * 600) != g.score)
    }
}

@Suite struct RunnerGameReleaseTests {
    /// 앱이 포커스를 잃을 때 부르는 것과 같은 순서로 놓으면 멈추고, 고스트도 같은 판을 돌린다.
    @Test func releasingEverythingStopsMovementAndReplays() {
        var tuning = RunnerGame.Tuning()
        tuning.catalog = []
        let game = RunnerGame(tuning: tuning, runnerWidth: 24, runnerHeight: 40, seed: 3)
        game.press()
        game.setMove(forward: true)
        game.setDuck(true)
        for _ in 0..<30 { game.advance(by: 1.0 / 60) }
        game.setMove(back: false, forward: false)
        game.setDuck(false)
        game.release()
        let offset = game.runnerOffset
        for _ in 0..<30 { game.advance(by: 1.0 / 60) }
        #expect(game.moveDirection == 0)
        #expect(game.runnerOffset == offset)
        #expect(!game.isDucking)
    }
}
