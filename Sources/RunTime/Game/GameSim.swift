import Foundation
import GameCore

/// 난이도 점검 (`--game-sim [판 수] [목표 점수]`): 실제 장애물 목록으로 여러 판을 화면 없이 돌린다.
/// 완벽한 자동 플레이어(Autopilot)가 죽으면 넘을 수 없는 배치라 버그이고,
/// 누르는 때가 조금씩 어긋나는 사람 플레이어로는 몇 점쯤에서 끝나는지 본다.
enum GameSim {
    struct Run {
        var score = 0
        var seconds = 0.0
        var speed = 0.0
        var crashedInto: String?
        /// 목표 점수까지 1000점마다 걸린 시간(초).
        var splits: [Double] = []
    }

    static func run(runs: Int, target: Int) {
        window(runs: runs)
        print("\n판 \(runs)개, 목표 \(target)점")
        report("완벽", (0..<runs).map { play(seed: UInt64($0 + 1), target: target, timing: nil) }, target: target)
        // 누르는 때 표준편차: 숙련 25ms, 보통 45ms, 처음 70ms
        for (name, sigma) in [("숙련", 0.025), ("보통", 0.045), ("처음", 0.07)] {
            report(name, (0..<runs).map { play(seed: UInt64($0 + 1), target: target, timing: sigma) }, target: target)
        }
    }

    /// 모든 장면에서 같은 만큼 일찍·늦게 눌렀을 때 첫 300점을 넘기는 판의 비율. 초반 타이밍 창의 너비를 본다.
    static func window(runs: Int) {
        let offsets = stride(from: -0.12, through: 0.12, by: 0.02).map { $0 }
        let line = offsets.map { offset -> String in
            let alive = (0..<runs).filter { play(seed: UInt64($0 + 1), target: 300, timing: 0, offset: offset).score >= 300 }.count
            return "\(Int((offset * 1000).rounded()))ms \(alive * 100 / runs)%"
        }
        print("초반 타이밍 창 (300점까지 산 비율, -는 일찍): " + line.joined(separator: " · "))
    }

    static func play(seed: UInt64, target: Int, timing: Double?, offset: Double = 0) -> Run {
        var tuning = RunnerGame.Tuning()
        // 실험용: GAME_SIM_INSET=4 처럼 판정 여유를 바꿔 본다
        if let inset = ProcessInfo.processInfo.environment["GAME_SIM_INSET"].flatMap(Double.init) { tuning.hitInset = inset }
        if let jump = ProcessInfo.processInfo.environment["GAME_SIM_JUMP"].flatMap(Double.init) { tuning.jumpVelocity = jump }
        tuning.catalog = GameAssets.catalog(runnerHeight: GameSession.runnerHeight)
        let game = RunnerGame(tuning: tuning, runnerWidth: GameSession.runnerWidth,
                              runnerHeight: GameSession.runnerHeight, seed: seed)
        var pilot: (() -> Void)
        if let timing {
            let human = HumanPilot(game: game, sigma: timing, offset: offset, seed: seed &* 31 &+ 7)
            pilot = human.step
        } else {
            let auto = Autopilot(game: game)
            pilot = auto.step
        }
        game.press()
        game.release()
        var run = Run()
        var nextSplit = 1000
        let frame = 1.0 / 60
        while game.phase == .playing, game.score < target, game.elapsed < 1200 {
            pilot()
            game.advance(by: frame)
            if game.score >= nextSplit {
                run.splits.append(game.elapsed)
                nextSplit += 1000
            }
        }
        run.score = game.score
        run.seconds = game.elapsed
        run.speed = game.speed
        if game.phase == .over, let id = game.crashedInto {
            run.crashedInto = game.obstacles.first { $0.id == id }.map { "\($0.kind.id)×\($0.count)@\(Int($0.y))" } ?? "?"
        }
        return run
    }

    private static func report(_ name: String, _ runs: [Run], target: Int) {
        let scores = runs.map(\.score).sorted()
        let reached = runs.filter { $0.score >= target }.count
        func percentile(_ p: Double) -> Int { scores[min(scores.count - 1, Int(Double(scores.count - 1) * p))] }
        print("\n[\(name)] 목표 도달 \(reached)/\(runs.count)  점수 중앙값 \(percentile(0.5))  하위 25% \(percentile(0.25))  상위 25% \(percentile(0.75))")
        let splits = (0..<(target / 1000)).map { k in runs.compactMap { $0.splits.count > k ? $0.splits[k] : nil } }
        let line = splits.enumerated().map { k, times in
            times.isEmpty ? "\((k + 1) * 1000)점 -" : "\((k + 1) * 1000)점 \(Int(times.reduce(0, +) / Double(times.count)))초"
        }
        print("  평균 도달 시간: " + line.joined(separator: " · "))
        var causes: [String: Int] = [:]
        for run in runs { if let c = run.crashedInto { causes[c.split(separator: "×").first.map(String.init) ?? c, default: 0] += 1 } }
        if !causes.isEmpty {
            print("  부딪힌 장애물: " + causes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if name == "완벽" {
            for (i, run) in runs.enumerated() where run.score < target {
                print("  ! 씨앗 \(i + 1): \(run.score)점, \(Int(run.seconds))초, 속도 \(Int(run.speed)), \(run.crashedInto ?? "시간 초과")")
            }
        }
    }
}

/// 사람처럼 하는 플레이어. Autopilot과 같은 판단을 하되, 장애물마다 누르는 때가 정규분포로 어긋나고
/// 숙이기는 반응 시간만큼 늦게 시작한다.
final class HumanPilot {
    private let game: RunnerGame
    private let sigma: Double
    private let offset: Double
    private var random: UInt64
    private var holding = false
    private var ducking = false
    /// 장애물 id마다 정한 타이밍 오차(초). 양수면 늦게 누른다.
    private var errors: [Int: Double] = [:]

    init(game: RunnerGame, sigma: Double, offset: Double = 0, seed: UInt64) {
        self.game = game
        self.sigma = sigma
        self.offset = offset
        random = seed
    }

    private func uniform() -> Double {
        random &+= 0x9E37_79B9_7F4A_7C15
        var z = random
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    private func gaussian() -> Double {
        let u = max(uniform(), 1e-9), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    func step() {
        guard game.phase == .playing else { return }
        if holding, !game.isOnGround, game.velocityY <= 0 {
            game.release()
            holding = false
        }
        let runner = game.runnerBox
        let ahead = game.obstacles.filter { $0.x + $0.width > runner.minX }
        let floor = game.runnerHeight + 2 - game.tuning.hitInset
        let underneath = { (o: RunnerGame.Obstacle) in o.y >= floor }
        guard let next = ahead.first(where: { !underneath($0) }) else { return }
        let error = errors[next.id] ?? {
            let e = gaussian() * sigma + offset
            errors[next.id] = e
            return e
        }()
        let closing = game.speed + next.kind.approachSpeed
        let canDuck = next.y > 0 && game.canDuckUnder(next.y)
        // 숙이기는 반응이 늦은 만큼 가까이 와서야 시작한다
        let duck = canDuck && next.x - runner.maxX < 30 - max(0, error) * closing
        if duck != ducking || (duck && game.isOnGround && !game.isDucking) {
            game.setDuck(duck)
            ducking = duck
        }
        guard !holding, !duck, !canDuck, game.isOnGround else { return }
        let gate = ahead.contains { underneath($0) && $0.x < next.x + next.width && next.x < $0.x + $0.width }
        let airTime = gate ? game.tuning.shortHop.airTime : game.tuning.airTime
        let lead = (closing * airTime - next.width - game.runnerWidth) / 2 - error * closing
        if next.x - runner.maxX < max(lead, 4) {
            game.press()
            if gate { game.release() } else { holding = true }
        }
    }
}
