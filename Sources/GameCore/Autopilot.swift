/// 스스로 하는 플레이어. 꼭대기까지 누르고 뛰되, 점프 궤적의 가운데가 장애물 가운데에 오게 뛴다.
/// 서서 지나갈 수 있는 높이 뜬 장애물은 뛰지 않고, 낮게 나는 장애물은 숙여 지나가고, 머리 위에 박쥐가 있는 문은 짧게 뛴다.
/// 규칙 테스트와 화면 점검 도구가 쓴다.
public final class Autopilot {
    private let game: RunnerGame
    private var holding = false
    private var ducking = false

    public init(game: RunnerGame) {
        self.game = game
    }

    /// 한 장면 전에 부른다. 누르거나 뗄 때를 정한다.
    public func step() {
        guard game.phase == .playing else { return }
        if holding, !game.isOnGround, game.velocityY <= 0 {
            game.release()
            holding = false
        }
        let runner = game.runnerBox
        let ahead = game.obstacles.filter { $0.x + $0.width > runner.minX }
        let floor = game.runnerHeight + 2 - game.tuning.hitInset
        let underneath = { (o: RunnerGame.Obstacle) in o.y >= floor }
        let next = ahead.first { !underneath($0) }
        // 낮게 나는 장애물은 지나갈 때까지 숙인다
        let duck = next.map { $0.y > 0 && game.canDuckUnder($0.y) && $0.x - runner.maxX < 30 } ?? false
        // 바깥에서 숙이기를 풀었을 수도 있어 게임 쪽 상태와도 맞춘다
        if duck != ducking || (duck && game.isOnGround && !game.isDucking) {
            game.setDuck(duck)
            ducking = duck
        }
        guard !holding, !duck, game.isOnGround, let next, !(next.y > 0 && game.canDuckUnder(next.y)) else { return }
        let gate = ahead.contains { underneath($0) && $0.x < next.x + next.width && next.x < $0.x + $0.width }
        let closing = game.speed + next.kind.approachSpeed
        let airTime = gate ? game.tuning.shortHop.airTime : game.tuning.airTime
        let lead = (closing * airTime - next.width - game.runnerWidth) / 2
        if next.x - runner.maxX < max(lead, 4) {
            game.press()
            if gate { game.release() } else { holding = true }
        }
    }
}
