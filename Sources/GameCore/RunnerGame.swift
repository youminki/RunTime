import Foundation

/// 팝오버 무대에서 하는 장애물 피하기 게임의 규칙. 화면·입력·소리와 떨어진 순수 시뮬레이션이라
/// 같은 씨앗이면 같은 판이 나온다.
///
/// 장애물 간격과 종류를 늘려 가는 방식은 Chromium T-Rex Runner(components/neterror/resources/offline.js,
/// Copyright 2014 The Chromium Authors, BSD 3-Clause)를 따랐다. 간격은 장애물 폭 × 속도 + 종류별 최소 간격 × 계수이고
/// 1.5배까지 무작위로 늘린다. 같은 종류는 두 번까지만 잇달아 나오고, 여러 개 붙은 장애물과 나는 장애물은 일정 속도부터 나온다.
/// 여기에 점프 시간으로 잰 하한을 더해, 넘을 수 없는 배치는 만들지 않는다.
///
/// 최고 속도에 닿은 뒤에도 같은 판이 되풀이되지 않게, 시간이 갈수록(압박) 속도가 조금씩 더 오르고 간격이 좁아지며
/// 걸어오는 적이 빨라진다. 일정 속도부터는 머리 위에 박쥐가 낮게 뜬 장애물(문)이 나와 짧게 뛰어야만 지나간다.
///
/// 좌표: x는 앞으로(+), y는 바닥에서 위로(+), 단위 pt. 1/120초 고정 간격으로 진행해 화면 주사율과 상관없이 같다.
public final class RunnerGame {
    public enum Phase: Equatable {
        case ready, playing, over
    }

    /// 화면이 소리·파티클로 받는 일.
    public enum Event: Equatable {
        case started
        case jumped
        case landed
        case coin(id: Int)
        /// 100점마다.
        case milestone(Int)
        /// 이번 판에서 처음으로 지난 최고 점수를 넘었을 때 한 번.
        case newRecord
        /// 장애물을 아주 가깝게 넘기거나 지나쳤다. 점수는 주지 않고 화면 연출만 한다.
        case nearMiss(id: Int)
        /// 공중에서 한 번 더 뛰었다 (이단 점프).
        case airJumped
        /// 보호막이 부딪힘을 막고 깨졌다.
        case shieldBroke(id: Int)
        case crashed
    }

    public struct ObstacleKind: Equatable {
        public let id: String
        public let width: Double
        public let height: Double
        /// 바닥에서 띄운 높이 후보. 비어 있으면 땅 위에 놓인다.
        public let elevations: [Double]
        /// 이 속도(pt/초)부터 나온다.
        public let minSpeed: Double
        /// 이 속도부터 2~3개를 붙여 낸다. nil이면 늘 하나.
        public let groupSpeed: Double?
        /// 종류별 최소 간격(pt). T-Rex Runner의 minGap처럼 계수를 곱해 쓴다.
        public let minGap: Double
        /// 땅보다 빠르게 다가오는 속도(pt/초). 걸어오는 적.
        public let approachSpeed: Double

        public init(id: String, width: Double, height: Double, elevations: [Double] = [], minSpeed: Double = 0,
                    groupSpeed: Double? = nil, minGap: Double = 120, approachSpeed: Double = 0) {
            self.id = id
            self.width = width
            self.height = height
            self.elevations = elevations
            self.minSpeed = minSpeed
            self.groupSpeed = groupSpeed
            self.minGap = minGap
            self.approachSpeed = approachSpeed
        }
    }

    public struct Obstacle: Equatable, Identifiable {
        public let id: Int
        public let kind: ObstacleKind
        /// 왼쪽 끝 (세계 x).
        public internal(set) var x: Double
        /// 아래끝 높이.
        public let y: Double
        /// 붙여 낸 개수.
        public let count: Int
        /// 만들 때의 땅 속도. 속도는 줄지 않으니 이보다 느릴 때 만나는 일은 없다.
        public let spawnSpeed: Double

        public var width: Double { kind.width * Double(count) }
        public var height: Double { kind.height }
    }

    public struct Coin: Equatable, Identifiable {
        public let id: Int
        /// 가운데 (세계 x, 바닥 위 높이).
        public internal(set) var x: Double
        public internal(set) var y: Double
        public internal(set) var taken = false
    }

    /// 판에 들어온 입력. 같은 씨앗에 같은 틱으로 다시 넣으면 같은 판이 나온다 (고스트).
    public enum Input: Equatable, Codable {
        case press, release
        case duck(Bool), back(Bool), forward(Bool)
    }

    public struct InputRecord: Equatable, Codable {
        /// 이 입력 뒤에 처음 진행한 틱 번호.
        public let tick: Int
        public let input: Input

        public init(tick: Int, input: Input) {
            self.tick = tick
            self.input = input
        }
    }

    /// 상점에서 산 능력. 속도와 점수 계산은 그대로라 순위 서버 규칙(시간당 거리, 장애물당 코인)을 넘지 않는다.
    /// 고스트도 같은 능력으로 돌려야 같은 판이 나와서 고스트 기록에 함께 남긴다.
    public struct Abilities: Equatable, Codable {
        /// 공중에서 더 뛸 수 있는 횟수.
        public var airJumps = 0
        /// 판마다 막아 주는 부딪힘 수.
        public var shields = 0
        /// 코인을 끌어오는 거리 단계 (0이면 없음).
        public var magnet = 0
        /// 뛴 채 누르고 있으면 천천히 내려온다.
        public var glide = false

        public init(airJumps: Int = 0, shields: Int = 0, magnet: Int = 0, glide: Bool = false) {
            self.airJumps = airJumps
            self.shields = shields
            self.magnet = magnet
            self.glide = glide
        }

        public var isEmpty: Bool { self == Abilities() }

        /// 자석이 코인을 끌어오는 거리 (pt).
        public var magnetRange: Double { [0, 60, 95, 130][min(max(magnet, 0), 3)] }
    }

    public struct Tuning {
        public var gravity: Double = 2400
        public var jumpVelocity: Double = 560
        /// 점프 키를 일찍 떼면 오르는 속도를 여기까지 줄인다. 짧게 누르면 낮게 뛴다.
        public var releaseVelocity: Double = 280
        /// 아무리 짧게 눌러도 여기까지는 오른 뒤에 끊는다 (T-Rex Runner의 MIN_JUMP_HEIGHT).
        public var minJumpHeight: Double = 30
        /// 공중에서 숙이기를 누르면 빨리 내려온다.
        public var fastFallGravity: Double = 6200
        /// ←→로 땅 위에서 앞뒤로 움직이는 속도(pt/초)와 범위. 점수는 거리로만 세서 움직여도 점수 상한은 같다.
        /// 앞으로 갈수록 장애물을 볼 시간이 줄고, 공중에서 앞으로 밀면 더 길게 넘는다.
        public var moveSpeed: Double = 170
        public var maxAdvance: Double = 110
        public var maxRetreat: Double = 24
        public var startSpeed: Double = 220
        /// 여기까지는 빨리 오르고, 그 뒤로는 lateAcceleration으로 천천히 maxSpeed까지 오른다.
        public var rampSpeed: Double = 440
        /// 무대 폭(약 290pt 앞까지 보임)에서 장애물을 보고 반응할 시간이 0.5초는 남게 둔다.
        public var maxSpeed: Double = 540
        /// 초당 늘어나는 속도.
        public var acceleration: Double = 6
        public var lateAcceleration: Double = 1
        /// 땅을 막 떠난 뒤에도 점프를 받아 주는 시간, 착지 직전에 누른 점프를 기억해 두는 시간.
        public var coyoteTime: Double = 0.08
        public var jumpBuffer: Double = 0.12
        /// T-Rex Runner의 GAP_COEFFICIENT, MAX_GAP_COEFFICIENT, MAX_OBSTACLE_DUPLICATION.
        public var gapCoefficient: Double = 0.6
        public var maxGapCoefficient: Double = 1.5
        public var maxDuplication = 2
        /// 착지한 뒤 다시 뛰기까지 사람에게 주는 시간. 압박이 다 차면 lateReactionTime까지 줄인다.
        public var reactionTime: Double = 0.28
        public var lateReactionTime: Double = 0.22
        /// 압박이 시작되는 시각과 다 차기까지 걸리는 시간(초).
        public var pressureStart: Double = 25
        public var pressureSpan: Double = 95
        /// 압박이 다 찼을 때의 간격 계수. 최소 간격 쪽으로도 더 자주 뽑는다.
        public var lateGapCoefficient: Double = 0.45
        public var lateMaxGapCoefficient: Double = 1.15
        /// 압박이 다 찼을 때 걸어오는 적이 더 빨라지는 비율.
        public var lateApproachBoost: Double = 0.6
        /// 이 속도부터 문(머리 위 박쥐 + 땅 장애물)이 나오고, 압박에 따라 확률이 오른다.
        public var gateSpeed: Double = 450
        public var gateChance: Double = 0.12
        public var lateGateChance: Double = 0.3
        /// 숙인 키 (선 키 대비).
        public var duckRatio: Double = 0.55
        /// 판정은 보이는 모습보다 조금 너그럽게 한다.
        public var hitInset: Double = 2.5
        /// 장애물과 위아래로 이보다 가깝게 지나가면 아슬아슬하게 피한 것으로 친다.
        public var nearMissGap: Double = 7
        /// 이단 점프는 처음 점프보다 조금 낮게 뛴다.
        public var airJumpVelocity: Double = 500
        /// 글라이드 중 떨어지는 속도 상한과 그동안의 중력.
        public var glideFallSpeed: Double = 110
        public var glideGravity: Double = 600
        /// 보호막이 깨진 뒤 장애물을 지나쳐 갈 시간.
        public var shieldGrace: Double = 0.7
        /// 1pt당 점수와 코인 하나의 점수.
        public var scorePerPoint: Double = 0.04
        public var coinValue = 10
        /// 장애물·코인을 미리 깔아 두는 거리 (보이는 폭보다 넉넉히).
        public var lookAhead: Double = 520
        /// 부딪힌 뒤 다시 시작을 받기까지. 누르던 손에 바로 새 판이 시작되지 않게.
        public var restartDelay: Double = 0.45
        public var catalog: [ObstacleKind] = []

        public init() {}

        /// 점프 한 번에 공중에 머무는 시간.
        public var airTime: Double { 2 * jumpVelocity / gravity }

        /// 누르자마자 뗀 가장 짧은 점프의 높이 곡선. 최소 높이까지는 그대로 오르고, 그 뒤 releaseVelocity로 끊긴다.
        public func shortHop(at t: Double) -> Double {
            let v = jumpVelocity, g = gravity
            let cut = (v - (v * v - 2 * g * minJumpHeight).squareRoot()) / g
            guard t > cut else { return v * t - g * t * t / 2 }
            let u = t - cut, rise = min(v - g * cut, releaseVelocity)
            return minJumpHeight + rise * u - g * u * u / 2
        }

        /// 가장 짧은 점프가 공중에 머무는 시간과 꼭대기 높이.
        public var shortHop: (airTime: Double, apex: Double) {
            let v = jumpVelocity, g = gravity
            let cut = (v - (v * v - 2 * g * minJumpHeight).squareRoot()) / g
            let rise = min(v - g * cut, releaseVelocity)
            let fall = (rise + (rise * rise + 2 * g * minJumpHeight).squareRoot()) / g
            return (cut + fall, minJumpHeight + rise * rise / (2 * g))
        }

        /// 문 위 박쥐의 아래끝. 짧은 점프는 머리가 닿지 않고, 끝까지 누른 점프는 닿는다.
        public func gateCeiling(runnerHeight: Double) -> Double {
            (shortHop.apex + runnerHeight - hitInset + 6).rounded()
        }
    }

    public let tuning: Tuning
    /// 러너 판정 상자 (선 자세).
    public let runnerWidth: Double
    public let runnerHeight: Double

    public private(set) var phase: Phase = .ready
    /// 이번 판의 씨앗. 새 판마다 바뀐다.
    public private(set) var seed: UInt64
    /// 이번 판에 들어온 입력. 시작할 때 누르고 있던 키부터 담는다.
    public private(set) var inputLog: [InputRecord] = []
    /// 판이 시작된 뒤 진행한 고정 간격 수.
    public private(set) var ticks = 0
    /// 틱마다 진행하기 직전에 부른다 (고스트가 그 틱의 입력을 넣는다).
    public var beforeTick: ((Int) -> Void)?
    public private(set) var distance: Double = 0
    public private(set) var speed: Double
    /// 판이 시작된 뒤 흐른 시간. 부딪히면 멈춘다.
    public private(set) var elapsed: Double = 0
    public private(set) var runnerY: Double = 0
    public private(set) var velocityY: Double = 0
    public private(set) var isOnGround = true
    /// 시작 자리에서 앞(+)·뒤(-)로 움직인 거리.
    public private(set) var runnerOffset: Double = 0
    /// 지금 누르고 있는 방향 (-1 뒤, 0, 1 앞).
    public var moveDirection: Int { (rightHeld ? 1 : 0) - (leftHeld ? 1 : 0) }
    public private(set) var obstacles: [Obstacle] = []
    public private(set) var coins: [Coin] = []
    public private(set) var coinsTaken = 0
    public private(set) var score = 0
    public private(set) var best: Int
    /// 판이 시작할 때의 최고 점수. 신기록인지 가른다.
    public private(set) var bestAtStart: Int
    public private(set) var crashedInto: Int?
    /// 이번 판에 쓰는 능력. 판 사이에만 바꾼다.
    public private(set) var abilities: Abilities
    public private(set) var shieldsLeft = 0
    public private(set) var airJumpsLeft = 0
    /// 보호막이 깨진 뒤 남은 무적 시간.
    public private(set) var invulnerable: Double = 0
    public private(set) var isGliding = false
    public var isNewRecord: Bool { score > bestAtStart && bestAtStart > 0 }

    /// 시간이 갈수록 0에서 1로 차는 난이도. 간격·걸어오는 적·문 확률을 정한다.
    public var pressure: Double {
        min(1, max(0, (elapsed - tuning.pressureStart) / tuning.pressureSpan))
    }

    /// 숙이기를 누르고 있고 땅에 있으면 숙인다.
    public var isDucking: Bool { duckHeld && isOnGround }

    private var random: SplitMix64
    private var events: [Event] = []
    private var accumulator: Double = 0
    private var crashTime: Double = 0
    private var overClock: Double = 0
    private var jumpHeld = false
    /// 최소 높이에 닿기 전에 뗀 점프. 닿는 순간 끊는다.
    private var cutPending = false
    private var duckHeld = false
    private var leftHeld = false
    private var rightHeld = false
    private var coyote: Double = 0
    private var buffered: Double = 0
    private var nextSpawnX: Double = 0
    /// 다음에 놓을 종류. 간격을 정할 때 그 장애물이 걸어오는지 알아야 해서 미리 고른다.
    private var upcoming: ObstacleKind?
    private var recentKinds: [String] = []
    private var lastMilestone = 0
    /// 러너와 앞뒤로 겹친 동안 장애물과 위아래로 가장 가까웠던 거리.
    private var closestGap: [Int: Double] = [:]
    private var announcedRecord = false
    private var nextID = 0
    /// 판정 없이 배치만 길게 볼 때 (테스트).
    var ignoresCollisions = false

    public static let step: Double = 1.0 / 120

    /// 순위 서버가 점수를 가릴 때 쓰는 규칙 번호. 속도·점수에 관한 Tuning 기본값을 바꾸면 올리고
    /// server/leaderboard/src/rules.js에 같은 번호로 값을 더한다.
    public static let rulesVersion = 2

    public init(tuning: Tuning, runnerWidth: Double, runnerHeight: Double, best: Int = 0,
                seed: UInt64 = UInt64.random(in: 0...UInt64.max), abilities: Abilities = Abilities()) {
        self.tuning = tuning
        self.abilities = abilities
        self.runnerWidth = runnerWidth
        self.runnerHeight = runnerHeight
        self.best = best
        bestAtStart = best
        speed = tuning.startSpeed
        self.seed = seed
        random = SplitMix64(seed: seed)
        nextSpawnX = Self.firstSpawn(tuning)
    }

    /// 처음 장애물은 시작하고 2초쯤 뒤에 닿게 둔다.
    private static func firstSpawn(_ tuning: Tuning) -> Double { tuning.startSpeed * 2 }

    // MARK: 입력

    /// 점프 키를 눌렀다. 대기 중이면 시작하며 뛰고, 끝났으면 잠깐 뒤부터 새 판을 연다.
    /// 다시 시작할 때도 처음 시작처럼 뛰어서, 고스트는 어느 판이든 같은 입력 하나로 시작한다.
    public func press() {
        switch phase {
        case .ready:
            start()
        case .playing:
            break
        case .over:
            guard overClock >= tuning.restartDelay else { return }
            reset()
            start()
        }
        jumpHeld = true
        buffered = tuning.jumpBuffer
        record(.press)
    }

    /// 끝난 판을 치우고 이 씨앗으로 다음 판을 준비한다 (고스트와 같은 코스).
    public func prepare(seed: UInt64) {
        guard phase != .playing else { return }
        if phase == .over {
            guard overClock >= tuning.restartDelay else { return }
            reset()
        }
        self.seed = seed
        random = SplitMix64(seed: seed)
    }

    /// 다음 판부터 쓸 능력. 판 중에는 바꾸지 않는다.
    public func setAbilities(_ abilities: Abilities) {
        guard phase != .playing else { return }
        self.abilities = abilities
    }

    /// 기록해 둔 입력을 다시 넣는다.
    public func apply(_ input: Input) {
        switch input {
        case .press: press()
        case .release: release()
        case .duck(let held): setDuck(held)
        case .back(let held): setMove(back: held)
        case .forward(let held): setMove(forward: held)
        }
    }

    private func record(_ input: Input) {
        guard phase == .playing else { return }
        inputLog.append(InputRecord(tick: ticks, input: input))
    }

    /// 점프 키를 뗐다. 오르는 중이면 짧게 끊는다.
    public func release() {
        record(.release)
        jumpHeld = false
        cutPending = !isOnGround || buffered > 0
        cutJumpIfHighEnough()
    }

    private func cutJumpIfHighEnough() {
        guard cutPending, !isOnGround, runnerY >= tuning.minJumpHeight else { return }
        cutPending = false
        if velocityY > tuning.releaseVelocity { velocityY = tuning.releaseVelocity }
    }

    public func setDuck(_ held: Bool) {
        if held || held != duckHeld { record(.duck(held)) }   // 누르고 있는 동안 반복 입력도 점프 예약을 지운다
        duckHeld = held
        if held { buffered = 0 }
    }

    /// ←·→를 누르거나 뗐다. 둘 다 누르면 서 있는다.
    public func setMove(back: Bool? = nil, forward: Bool? = nil) {
        if let back, back != leftHeld {
            record(.back(back))
            leftHeld = back
        }
        if let forward, forward != rightHeld {
            record(.forward(forward))
            rightHeld = forward
        }
    }

    /// 쌓인 일을 꺼내 간다 (그린 뒤 소리·파티클로).
    public func drainEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    // MARK: 진행

    /// 화면 한 장면만큼 시간을 보낸다. 오래 멈췄다 와도 한 번에 0.25초까지만 따라잡는다.
    public func advance(by seconds: Double) {
        if phase == .over {
            overClock += max(0, seconds)
            fallAfterCrash(min(max(0, seconds), 0.25))
        }
        guard phase == .playing else { return }
        accumulator += min(max(0, seconds), 0.25)
        while accumulator >= Self.step, phase == .playing {
            beforeTick?(ticks)
            guard phase == .playing else { break }
            tick(Self.step)
            accumulator -= Self.step
        }
    }

    /// 판을 연다. 시작 전부터 누르고 있던 키를 입력 기록 맨 앞에 둔다.
    private func start() {
        phase = .playing
        inputLog = []
        if duckHeld { record(.duck(true)) }
        if leftHeld { record(.back(true)) }
        if rightHeld { record(.forward(true)) }
        shieldsLeft = abilities.shields
        airJumpsLeft = abilities.airJumps
        invulnerable = 0
        isGliding = false
        events.append(.started)
    }

    private func reset() {
        phase = .ready
        seed = random.next()
        random = SplitMix64(seed: seed)
        ticks = 0
        distance = 0
        speed = tuning.startSpeed
        elapsed = 0
        runnerY = 0
        velocityY = 0
        isOnGround = true
        runnerOffset = 0
        obstacles = []
        coins = []
        coinsTaken = 0
        score = 0
        bestAtStart = best
        crashedInto = nil
        accumulator = 0
        overClock = 0
        jumpHeld = false
        cutPending = false
        leftHeld = false
        rightHeld = false
        coyote = 0
        buffered = 0
        nextSpawnX = Self.firstSpawn(tuning)
        upcoming = nil
        recentKinds = []
        lastMilestone = 0
        closestGap = [:]
        announcedRecord = false
    }

    private func tick(_ dt: Double) {
        ticks += 1
        elapsed += dt
        let acceleration = speed < tuning.rampSpeed ? tuning.acceleration : tuning.lateAcceleration
        speed = min(tuning.maxSpeed, speed + acceleration * dt)
        distance += speed * dt
        runnerOffset = min(tuning.maxAdvance,
                           max(-tuning.maxRetreat, runnerOffset + Double(moveDirection) * tuning.moveSpeed * dt))
        for i in obstacles.indices where obstacles[i].kind.approachSpeed > 0 {
            obstacles[i].x -= obstacles[i].kind.approachSpeed * dt
        }

        // 점프: 착지 직전에 누른 것도, 땅을 막 떠난 뒤에 누른 것도 받아 준다
        coyote = isOnGround ? tuning.coyoteTime : coyote - dt
        buffered -= dt
        if buffered > 0, coyote > 0 {
            velocityY = tuning.jumpVelocity
            cutPending = !jumpHeld
            isOnGround = false
            coyote = 0
            buffered = 0
            events.append(.jumped)
        } else if buffered > 0, !isOnGround, coyote <= 0, airJumpsLeft > 0 {
            // 이단 점프. 남은 횟수가 없으면 누른 것은 착지 때까지 기다린다
            velocityY = tuning.airJumpVelocity
            cutPending = !jumpHeld
            airJumpsLeft -= 1
            buffered = 0
            events.append(.airJumped)
        }
        // 숙인 채 뛰어도 최소 높이까지는 오른 뒤에 빨리 내려온다
        let fastFall = duckHeld && !isOnGround && (velocityY <= 0 || runnerY >= tuning.minJumpHeight)
        isGliding = abilities.glide && jumpHeld && !duckHeld && !isOnGround && velocityY <= 0
        let gravity = fastFall ? tuning.fastFallGravity : isGliding ? tuning.glideGravity : tuning.gravity
        velocityY -= gravity * dt
        if isGliding { velocityY = max(velocityY, -tuning.glideFallSpeed) }
        runnerY += velocityY * dt
        if runnerY <= 0 {
            runnerY = 0
            velocityY = 0
            if !isOnGround { events.append(.landed) }
            isOnGround = true
            cutPending = false
            airJumpsLeft = abilities.airJumps
        } else {
            isOnGround = false
            cutJumpIfHighEnough()
        }

        spawn()
        obstacles.removeAll { $0.x + $0.width < distance - 120 }
        coins.removeAll { $0.x < distance - 120 }

        pullCoins(dt)
        collectCoins()
        invulnerable = max(0, invulnerable - dt)
        if !ignoresCollisions, invulnerable <= 0, let hit = obstacles.first(where: hits) {
            if shieldsLeft > 0 {
                shieldsLeft -= 1
                invulnerable = tuning.shieldGrace
                closestGap[hit.id] = nil
                events.append(.shieldBroke(id: hit.id))
            } else {
                crash(into: hit)
                return
            }
        }
        trackNearMisses()
        updateScore()
    }

    /// 공중에서 부딪히면 그 자리에 떠 있지 않고 바닥으로 떨어진다 (판정 없이 모습만).
    private func fallAfterCrash(_ dt: Double) {
        guard runnerY > 0 else { return }
        velocityY = min(velocityY, 0) - tuning.gravity * dt
        runnerY = max(0, runnerY + velocityY * dt)
        if runnerY == 0 {
            velocityY = 0
            isOnGround = true
        }
    }

    private func crash(into obstacle: Obstacle) {
        crashedInto = obstacle.id
        phase = .over
        overClock = 0
        crashTime = elapsed
        updateScore()
        best = max(best, score)
        events.append(.crashed)
    }

    private func updateScore() {
        score = Int(distance * tuning.scorePerPoint) + coinsTaken * tuning.coinValue
        let milestone = score / 100
        if milestone > lastMilestone {
            lastMilestone = milestone
            events.append(.milestone(milestone * 100))
        }
        if !announcedRecord, bestAtStart > 0, score > bestAtStart {
            announcedRecord = true
            events.append(.newRecord)
        }
    }

    // MARK: 판정

    /// 러너 상자 (세계 좌표). 러너의 왼쪽 끝이 distance + runnerOffset에 있다.
    public var runnerBox: Box {
        let height = isDucking ? runnerHeight * tuning.duckRatio : runnerHeight
        let left = distance + runnerOffset
        return Box(minX: left + 2, maxX: left + runnerWidth - 2, minY: runnerY, maxY: runnerY + height)
    }

    public struct Box: Equatable {
        public let minX, maxX, minY, maxY: Double

        func intersects(_ other: Box) -> Bool {
            minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
        }
    }

    private func box(_ obstacle: Obstacle) -> Box {
        let inset = tuning.hitInset
        return Box(minX: obstacle.x + inset, maxX: obstacle.x + obstacle.width - inset,
                   minY: obstacle.y + (obstacle.y > 0 ? inset : 0), maxY: obstacle.y + obstacle.height - inset)
    }

    private func hits(_ obstacle: Obstacle) -> Bool { runnerBox.intersects(box(obstacle)) }

    private func trackNearMisses() {
        let runner = runnerBox
        for obstacle in obstacles {
            let b = box(obstacle)
            if b.minX < runner.maxX, runner.minX < b.maxX {
                let gap = max(runner.minY - b.maxY, b.minY - runner.maxY)
                closestGap[obstacle.id] = min(closestGap[obstacle.id] ?? .infinity, gap)
            } else if b.maxX <= runner.minX, let gap = closestGap.removeValue(forKey: obstacle.id) {
                // 겹친 채 지나간 것(보호막으로 뚫고 간 것)은 아슬아슬이 아니다
                if gap >= 0, gap < tuning.nearMissGap { events.append(.nearMiss(id: obstacle.id)) }
            }
        }
    }

    /// 자석: 범위 안 코인을 러너 가운데로 끌어온다.
    private func pullCoins(_ dt: Double) {
        let range = abilities.magnetRange
        guard range > 0 else { return }
        let runner = runnerBox
        let cx = (runner.minX + runner.maxX) / 2, cy = (runner.minY + runner.maxY) / 2
        let step = 420 * dt
        for i in coins.indices where !coins[i].taken {
            let dx = cx - coins[i].x, dy = cy - coins[i].y
            let d = (dx * dx + dy * dy).squareRoot()
            guard d < range, d > 0 else { continue }
            let k = min(1, step / d)
            coins[i].x += dx * k
            coins[i].y += dy * k
        }
    }

    private func collectCoins() {
        let runner = runnerBox
        let reach = 9.0   // 코인 반지름보다 조금 넉넉히
        for i in coins.indices where !coins[i].taken {
            let c = coins[i]
            if c.x + reach > runner.minX, c.x - reach < runner.maxX, c.y + reach > runner.minY, c.y - reach < runner.maxY {
                coins[i].taken = true
                coinsTaken += 1
                events.append(.coin(id: c.id))
            }
        }
    }

    // MARK: 장애물 만들기

    /// 높이 `top`까지 솟은 폭 `width` 장애물을 지금 속도로 뛰어넘을 수 있는지.
    /// 그 높이보다 위에 떠 있는 시간 동안 러너가 장애물과 자기 폭을 모두 지나가야 한다.
    public func canJump(width: Double, top: Double, closingSpeed: Double) -> Bool {
        let v = tuning.jumpVelocity, g = tuning.gravity
        let clearance = top - tuning.hitInset
        let disc = v * v - 2 * g * clearance
        guard disc > 0 else { return false }
        let window = 2 * disc.squareRoot() / g
        return window * closingSpeed >= width + runnerWidth - tuning.hitInset * 2 + 6
    }

    /// 가장 짧은 점프로 머리 위 `ceiling` 아래를 지나며 폭 `width`, 높이 `top` 장애물을 넘을 수 있는지 (문).
    public func canHop(width: Double, top: Double, ceiling: Double, closingSpeed: Double) -> Bool {
        let hop = tuning.shortHop
        guard hop.apex + runnerHeight < ceiling + tuning.hitInset - 1 else { return false }
        let clearance = top - tuning.hitInset
        var above = 0.0, t = 0.0
        while t < hop.airTime {
            if tuning.shortHop(at: t) > clearance { above += Self.step }
            t += Self.step
        }
        return above * closingSpeed >= width + runnerWidth - tuning.hitInset * 2 + 6
    }

    /// 서서 그 아래로 지나갈 수 있는지 (높이 떠 있는 장애물).
    private func canPassUnder(_ bottom: Double) -> Bool { bottom + tuning.hitInset >= runnerHeight + 2 }

    private func spawn() {
        while nextSpawnX < distance + tuning.lookAhead {
            guard let kind = upcoming ?? pickKind() else { return }
            let closing = speed + kind.approachSpeed
            let y = pickElevation(kind, closing: closing)
            var count = 1
            if let groupSpeed = kind.groupSpeed, speed >= groupSpeed {
                count = 1 + Int(random.next() % 3)
                while count > 1, !canJump(width: kind.width * Double(count), top: kind.height, closingSpeed: closing) {
                    count -= 1
                }
            }
            if count == 1, y == 0, kind.approachSpeed == 0, let ceiling = gateCeiling(over: kind) {
                let ground = Obstacle(id: makeID(), kind: kind, x: nextSpawnX, y: 0, count: 1, spawnSpeed: speed)
                obstacles.append(ground)
                obstacles.append(Obstacle(id: makeID(), kind: ceiling, x: ground.x + (kind.width - ceiling.width) / 2,
                                          y: tuning.gateCeiling(runnerHeight: runnerHeight), count: 1, spawnSpeed: speed))
                recentKinds.append(kind.id)
                if recentKinds.count > tuning.maxDuplication { recentKinds.removeFirst() }
                upcoming = pickKind()
                nextSpawnX = ground.x + ground.width + gap(after: ground, next: upcoming)
                continue
            }
            let obstacle = Obstacle(id: makeID(), kind: kind, x: nextSpawnX, y: y, count: count, spawnSpeed: speed)
            obstacles.append(obstacle)
            recentKinds.append(kind.id)
            if recentKinds.count > tuning.maxDuplication { recentKinds.removeFirst() }
            placeCoins(near: obstacle)
            upcoming = pickKind()
            nextSpawnX = obstacle.x + obstacle.width + gap(after: obstacle, next: upcoming)
        }
    }

    /// 걸어오는 적은 압박만큼 빨라진다. 간격을 정할 때도 이 속도로 재도록 고를 때 바꿔 둔다.
    private func pickKind() -> ObstacleKind? {
        let open = tuning.catalog.filter { speed >= $0.minSpeed }
        // 같은 종류는 maxDuplication번까지만 잇달아
        let repeated = recentKinds.count == tuning.maxDuplication && Set(recentKinds).count == 1 ? recentKinds.first : nil
        let pool = open.filter { $0.id != repeated }
        let choices = pool.isEmpty ? open : pool
        guard !choices.isEmpty else { return nil }
        let kind = choices[Int(random.next() % UInt64(choices.count))]
        guard kind.approachSpeed > 0 else { return kind }
        return ObstacleKind(id: kind.id, width: kind.width, height: kind.height, elevations: kind.elevations,
                            minSpeed: kind.minSpeed, groupSpeed: kind.groupSpeed, minGap: kind.minGap,
                            approachSpeed: kind.approachSpeed * (1 + tuning.lateApproachBoost * pressure))
    }

    /// 이 땅 장애물 위에 문을 세운다면 쓸 박쥐. 속도·확률이 안 되거나 짧은 점프로 못 넘으면 nil.
    private func gateCeiling(over kind: ObstacleKind) -> ObstacleKind? {
        guard speed >= tuning.gateSpeed,
              let flyer = tuning.catalog.first(where: { !$0.elevations.isEmpty && speed >= $0.minSpeed }) else { return nil }
        let chance = tuning.gateChance + (tuning.lateGateChance - tuning.gateChance) * pressure
        guard random.unit() < chance,
              canHop(width: kind.width, top: kind.height, ceiling: tuning.gateCeiling(runnerHeight: runnerHeight),
                     closingSpeed: speed) else { return nil }
        return flyer
    }

    /// 떠 있는 장애물은 서서 지나가거나 뛰어넘을 수 있는 높이만 고른다. 숙이기는 키보드가 있어야 해서 필수로 두지 않는다.
    private func pickElevation(_ kind: ObstacleKind, closing: Double) -> Double {
        let fair = kind.elevations.filter {
            canPassUnder($0) || canJump(width: kind.width, top: $0 + kind.height, closingSpeed: closing)
        }
        guard !fair.isEmpty else { return kind.elevations.max() ?? 0 }
        return fair[Int(random.next() % UInt64(fair.count))]
    }

    /// T-Rex Runner의 간격 공식에, 착지하고 다시 뛸 시간을 하한으로 더한다.
    /// 다음 장애물이 걸어오는 적이면 만날 때까지 다가오는 거리만큼 더 띄운다. 보이기 시작할 때(lookAhead)부터
    /// 만날 때까지 걷는 거리가 가장 길어서 그 값으로 잡는다.
    /// 압박이 찰수록 계수와 반응 시간을 줄이고, 최소 간격 쪽으로 치우쳐 뽑는다.
    private func gap(after obstacle: Obstacle, next: ObstacleKind?) -> Double {
        let p = pressure
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        let chrome = obstacle.width * (speed / 60) + obstacle.kind.minGap * blend(tuning.gapCoefficient, tuning.lateGapCoefficient)
        let landing = speed * (tuning.airTime + blend(tuning.reactionTime, tuning.lateReactionTime))
        let approach = next.map { $0.approachSpeed * tuning.lookAhead / (speed + $0.approachSpeed) } ?? 0
        let minGap = max(chrome, landing) + approach
        let maxGap = minGap * blend(tuning.maxGapCoefficient, tuning.lateMaxGapCoefficient)
        return minGap + (maxGap - minGap) * pow(random.unit(), 1 + 1.5 * p)
    }

    /// 땅 장애물 위에 점프 궤적을 따라 코인 셋, 가끔은 다음 장애물 앞 바닥에 코인 줄.
    /// 걸어오는 적은 만날 때 자리가 달라져 궤적과 어긋나니 두지 않는다.
    private func placeCoins(near obstacle: Obstacle) {
        guard obstacle.y == 0, obstacle.kind.approachSpeed == 0 else { return }
        let roll = random.unit()
        if roll < 0.32 {
            let center = obstacle.x + obstacle.width / 2
            let top = obstacle.height + 20
            for (dx, lift) in [(-26.0, 0.72), (0, 1.0), (26, 0.72)] {
                coins.append(Coin(id: makeID(), x: center + dx, y: top * lift + 6))
            }
        } else if roll < 0.45 {
            let start = obstacle.x + obstacle.width + speed * (tuning.airTime * 0.9)
            for k in 0..<3 {
                coins.append(Coin(id: makeID(), x: start + Double(k) * 22, y: 12))
            }
        }
    }

    private func makeID() -> Int {
        nextID += 1
        return nextID
    }
}

/// 씨앗이 같으면 같은 수열을 내는 난수 (SplitMix64).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 이상 1 미만.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
