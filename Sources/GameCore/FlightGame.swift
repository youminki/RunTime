import Foundation

/// 비행 모드의 규칙. 끝없는 하늘을 누르는 동안 오르고 떼면 내려가며 난다. 멀리 갈수록 빨라진다.
/// 장애물은 조각(`FlightChunk`)으로 그때그때 만들고, 조각마다 사람 입력 간격(0.1초)으로 지나갈 길이 있는지 검사해
/// 길이 없는 조각은 버린다. 그래서 어떻게 해도 못 지나가는 배치는 나오지 않고, 같은 판도 되풀이되지 않는다.
/// 위치·속도는 모두 지나온 거리의 함수라 화면 주사율과 상관없고 같은 씨앗이면 같은 판이다.
///
/// 좌표: x는 앞으로(+), y는 바닥에서 위로(+), 단위 pt. 1/120초 고정 간격으로 진행한다.
public enum FlightDifficulty: String, CaseIterable, Sendable {
    case easy, normal, hard

    public var title: String {
        switch self {
        case .easy: "쉬움"
        case .normal: "보통"
        case .hard: "어려움"
        }
    }

    public var startSpeed: Double {
        switch self {
        case .easy: 230
        case .normal: 300
        case .hard: 380
        }
    }

    public var maxSpeed: Double {
        switch self {
        case .easy: 460
        case .normal: 620
        case .hard: 760
        }
    }

    /// 틈 크기 배율.
    var gapScale: Double {
        switch self {
        case .easy: 1.45
        case .normal: 1.08
        case .hard: 0.88
        }
    }

    /// 조각 사이 시간 배율.
    var spacing: Double {
        switch self {
        case .easy: 1.4
        case .normal: 1.05
        case .hard: 0.85
        }
    }
}

public struct FlightHazard: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case pillar, rock, bat, spikeball, crusher, drill
        /// 닿아도 끝나지 않고 달라붙어 잠깐 무거워진다.
        case slime
    }

    /// 러너가 간 거리에 따라 움직인다.
    public enum Motion: Equatable, Sendable {
        case none
        /// 위아래로 오간다.
        case bob(amplitude: Double, wavelength: Double)
        /// 러너가 `trigger`를 지나면 떨어진다. `rate`는 러너 1pt당 떨어지는 양.
        case fall(trigger: Double, rate: Double)
        /// 러너가 `from`을 지난 뒤 `rate`배 빠르기로 마주 온다.
        case approach(from: Double, rate: Double)
    }

    public let id: Int
    public let kind: Kind
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public var motion: Motion = .none

    /// 러너가 `px`까지 갔을 때의 자리.
    public func position(at px: Double) -> (x: Double, y: Double) {
        switch motion {
        case .none:
            return (x, y)
        case .bob(let amplitude, let wavelength):
            let y = self.y + amplitude * sin(2 * .pi * px / wavelength)
            return (x, min(max(y, 0), FlightGame.ceiling - height))
        case .fall(let trigger, let rate):
            return (x, max(0, y - max(0, px - trigger) * rate))
        case .approach(let from, let rate):
            return (x - max(0, px - from) * rate, y)
        }
    }
}

public struct FlightPickup: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case candy, shield }

    public let id: Int
    public let kind: Kind
    public let x: Double
    public let y: Double
}

/// 만들 수 있는 장애물 조각. 멀리 갈수록 어려운 조각이 열린다.
public enum FlightChunk: String, CaseIterable, Sendable {
    case gates, slalom, islands, batSwarm, stickySlime, movingGates, fallingRocks, bouncers, staircase, drills, tunnel

    /// 이 진행도(0~1)부터 나온다.
    var opensAt: Double {
        switch self {
        case .gates, .slalom, .islands: 0
        case .batSwarm, .stickySlime: 0.03
        case .movingGates, .fallingRocks: 0.1
        case .bouncers, .staircase: 0.2
        case .drills, .tunnel: 0.32
        }
    }
}

public final class FlightGame {
    public enum Phase: Equatable, Sendable {
        case ready, playing, over
    }

    public enum Event: Equatable, Sendable {
        case started
        case candy(id: Int)
        case shieldPicked
        case shieldBroke
        case stuck
        case nearMiss
        /// 새 구역에 들어왔다 (1부터).
        case zone(Int)
        case newBest
        case crashed
    }

    public static let step = 1.0 / 120
    public static let ceiling = 106.0
    public static let runnerWidth = 22.0
    public static let runnerHeight = 20.0
    /// 판정은 보이는 그림보다 조금 너그럽게 한다.
    public static let hitInset = 2.0
    /// 한 구역의 길이 (pt).
    public static let zoneLength = 9000.0
    /// 가속 중 빠르기와 점수 배율.
    public static let boostFactor = 1.35
    /// 끝난 뒤 다시 시작을 받기까지. 누르던 손에 바로 새 판이 시작되지 않게.
    static let restartDelay = 0.4

    public let difficulty: FlightDifficulty
    public private(set) var phase: Phase = .ready
    public private(set) var x = 0.0
    public private(set) var y = FlightGame.ceiling / 2
    public private(set) var velocityY = 0.0
    public private(set) var isHolding = false
    public private(set) var isBoosting = false
    public private(set) var hasShield = false
    /// 슬라임이 붙어 있는 남은 시간.
    public private(set) var heavy = 0.0
    public private(set) var hazards: [FlightHazard] = []
    public private(set) var pickups: [FlightPickup] = []
    public private(set) var candies = 0
    public private(set) var nearMisses = 0
    public private(set) var chunks: [FlightChunk] = []
    public private(set) var best: Int
    public private(set) var isNewBest = false
    public private(set) var crashedInto: Int?
    private var boostScore = 0.0
    private var events: [Event] = []
    private var overTimer = 0.0
    private var invulnerable = 0.0
    private var zone = 1
    private var nextChunkX = 0.0
    private var nextID = 0
    private var random: SplitMix64
    private var seed: UInt64
    private var frontier: [PlanState] = []
    private var sinceShield = 0
    private var passed = Set<Int>()
    private var closest: [Int: Double] = [:]

    public init(difficulty: FlightDifficulty, best: Int = 0, seed: UInt64 = .random(in: 1...UInt64.max)) {
        self.difficulty = difficulty
        self.best = best
        self.seed = seed
        random = SplitMix64(seed: seed)
        reset(seed: seed)
    }

    // MARK: 값

    /// 진행도 (0~1). 빠르기와 난이도가 함께 오른다.
    public func progress(at x: Double) -> Double { 1 - exp(-x / 26000) }

    public func speed(at x: Double) -> Double {
        difficulty.startSpeed + (difficulty.maxSpeed - difficulty.startSpeed) * progress(at: x)
    }

    public var currentSpeed: Double { speed(at: x) * (isBoosting ? Self.boostFactor : 1) }
    public var score: Int { Int(x / 12 + boostScore) + candies * 5 + nearMisses * 5 }
    public var zoneNumber: Int { zone }

    public func drainEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    // MARK: 입력

    public func press() {
        switch phase {
        case .ready:
            phase = .playing
            events.append(.started)
        case .over:
            guard overTimer <= 0 else { return }
            let next = random.next() | 1
            reset(seed: next)
            phase = .playing
            events.append(.started)
        case .playing:
            break
        }
        isHolding = true
    }

    public func release() { isHolding = false }

    public func setBoost(_ on: Bool) { isBoosting = on }

    private func reset(seed: UInt64) {
        self.seed = seed
        random = SplitMix64(seed: seed)
        x = 0
        y = Self.ceiling / 2
        velocityY = 0
        isBoosting = false
        hasShield = false
        heavy = 0
        hazards = []
        pickups = []
        candies = 0
        nearMisses = 0
        chunks = []
        isNewBest = false
        crashedInto = nil
        boostScore = 0
        invulnerable = 0
        zone = 1
        sinceShield = 0
        passed = []
        closest = [:]
        // 처음에는 빈 하늘을 조금 날며 손에 익힌다
        nextChunkX = speed(at: 0) * 1.4
        frontier = [PlanState(y: y, velocity: 0, path: [])]
        fill()
    }

    // MARK: 진행

    public func advance(by seconds: Double) {
        accumulator += seconds
        while accumulator >= Self.step {
            tick()
            accumulator -= Self.step
        }
    }

    private var accumulator = 0.0

    private func tick() {
        let dt = Self.step
        switch phase {
        case .ready:
            return
        case .over:
            overTimer -= dt
            return
        case .playing:
            break
        }
        let speed = currentSpeed
        x += speed * dt
        if isBoosting { boostScore += speed * dt / 12 * (Self.boostFactor - 1) }
        var state = PlanState(y: y, velocity: velocityY, path: [])
        Self.move(&state, hold: isHolding, speed: speed, heavy: heavy > 0, dt: dt)
        y = state.y
        velocityY = state.velocity
        heavy = max(0, heavy - dt)
        invulnerable = max(0, invulnerable - dt)

        let reached = 1 + Int(x / Self.zoneLength)
        if reached > zone {
            zone = reached
            events.append(.zone(zone))
        }
        if score > best, !isNewBest, best > 0 {
            isNewBest = true
            events.append(.newBest)
        }
        fill()
        collect()
        collide()
        hazards.removeAll { $0.position(at: x).x + $0.width < x - 120 }
        pickups.removeAll { $0.x < x - 60 }
    }

    /// 한 간격의 위아래 움직임. 게임과 길 검사가 같이 쓴다.
    static func move(_ state: inout PlanState, hold: Bool, speed: Double, heavy: Bool, dt: Double) {
        // 빠를수록 위아래도 빠르게 해 빠른 구간에서도 틈을 맞출 수 있게 한다
        let lift = (1250 + speed * 0.9) * (heavy ? 0.55 : 1)
        let gravity = 1050 + speed * 0.9
        let limit = 200 + speed * 0.42
        state.velocity += (hold ? lift : -gravity) * dt
        state.velocity = min(max(state.velocity, -limit), limit)
        state.y += state.velocity * dt
        let top = ceiling - runnerHeight
        if state.y <= 0 {
            state.y = 0
            state.velocity = max(state.velocity, 0)
        } else if state.y >= top {
            state.y = top
            state.velocity = min(state.velocity, 0)
        }
    }

    private func collect() {
        for pickup in pickups where abs(pickup.x - (x + Self.runnerWidth / 2)) < 18
            && abs(pickup.y - (y + Self.runnerHeight / 2)) < 18 {
            switch pickup.kind {
            case .candy:
                candies += 1
                events.append(.candy(id: pickup.id))
            case .shield:
                hasShield = true
                events.append(.shieldPicked)
            }
            pickups.removeAll { $0.id == pickup.id }
        }
    }

    private func collide() {
        for hazard in hazards {
            let p = hazard.position(at: x)
            guard p.x < x + Self.runnerWidth + 30, p.x + hazard.width > x - 30 else { continue }
            let hits = Self.overlaps(px: x, py: y, hazard: hazard, at: x, inset: Self.hitInset)
            if !hits, hazard.kind != .slime, !passed.contains(hazard.id) {
                if p.x < x + Self.runnerWidth, p.x + hazard.width > x {
                    let gap = max(y - (p.y + hazard.height), p.y - (y + Self.runnerHeight))
                    closest[hazard.id] = min(closest[hazard.id] ?? .infinity, gap)
                } else if p.x + hazard.width <= x {
                    passed.insert(hazard.id)
                    if let gap = closest[hazard.id], gap < 7 {
                        nearMisses += 1
                        events.append(.nearMiss)
                    }
                }
            }
            guard hits, invulnerable <= 0 else { continue }
            if hazard.kind == .slime {
                if heavy <= 0 { events.append(.stuck) }
                heavy = 2.2
                continue
            }
            if hasShield {
                hasShield = false
                invulnerable = 0.8
                events.append(.shieldBroke)
                return
            }
            phase = .over
            overTimer = Self.restartDelay
            crashedInto = hazard.id
            isHolding = false
            isBoosting = false
            best = max(best, score)
            events.append(.crashed)
            return
        }
    }

    static func overlaps(px: Double, py: Double, hazard: FlightHazard, at position: Double, inset: Double) -> Bool {
        let p = hazard.position(at: position)
        return px + runnerWidth - inset > p.x && px + inset < p.x + hazard.width
            && py + runnerHeight - inset > p.y && py + inset < p.y + hazard.height
    }

    // MARK: 조각 만들기

    private func fill() {
        generate(until: x + speed(at: x) * 4)
    }

    func generate(until end: Double) {
        while nextChunkX < end { makeChunk() }
    }

    func addForTest(_ hazard: FlightHazard) { hazards.append(hazard) }

    /// 아직 안 지나간 모든 장애물 사이로 처음부터 `end`까지 갈 길이 있는지 처음부터 다시 찾는다 (규칙 테스트용).
    /// 조각을 만들 때 쓴 앞선 계산과 따로 돌려 그 계산이 맞는지 확인한다.
    func hasPath(until end: Double) -> Bool {
        var states = [PlanState(y: Self.ceiling / 2, velocity: 0, path: [])]
        var position = 0.0
        while position < end {
            let v = speed(at: position)
            let near = hazards.filter {
                $0.position(at: position).x < position + 500 && $0.position(at: position + 120).x + $0.width > position - 40
            }
            var next: [PlanState] = []
            var seen = Set<Int>()
            for state in states {
                for hold in [false, true] {
                    var moved = state
                    var px = position
                    var alive = true
                    for _ in 0..<12 {
                        px += v * Self.step
                        Self.move(&moved, hold: hold, speed: v, heavy: false, dt: Self.step)
                        if near.contains(where: { Self.overlaps(px: px, py: moved.y, hazard: $0, at: px, inset: Self.hitInset) }) {
                            alive = false
                            break
                        }
                    }
                    guard alive, seen.insert(Int(moved.y) * 1000 + Int((moved.velocity + 1000) / 20)).inserted else { continue }
                    next.append(moved)
                }
            }
            guard !next.isEmpty else { return false }
            states = next
            position += v * Self.step * 12
        }
        return true
    }

    private func makeChunk() {
        let start = nextChunkX
        let pressure = progress(at: start)
        let open = FlightChunk.allCases.filter { $0.opensAt <= pressure }
        // 같은 조각이 잇달지 않게 최근 셋은 빼고 고른다
        let recent = chunks.suffix(3)
        let pool = open.filter { !recent.contains($0) }
        for _ in 0..<6 {
            let chunk = (pool.isEmpty ? open : pool)[Int(random.next() % UInt64((pool.isEmpty ? open : pool).count))]
            let idBefore = nextID
            let built = build(chunk, at: start, pressure: pressure)
            guard let plan = advancePlan(hazards + built.hazards, from: start, to: built.end) else {
                nextID = idBefore
                continue
            }
            hazards.append(contentsOf: built.hazards)
            frontier = plan.states
            chunks.append(chunk)
            placePickups(along: plan.best, from: start)
            let rest = speed(at: built.end) * (0.38 + 0.25 * (1 - pressure)) * difficulty.spacing
            // 조각 사이 빈 하늘까지 길을 이어 간다
            if let after = advancePlan(hazards, from: built.end, to: built.end + rest) { frontier = after.states }
            nextChunkX = built.end + rest
            return
        }
        // 어느 조각도 길이 없으면 빈 하늘을 준다. 길이 넓어져 다음 조각을 놓을 수 있다
        let end = start + speed(at: start) * 0.8
        if let after = advancePlan(hazards, from: start, to: end) { frontier = after.states }
        nextChunkX = end
    }

    private func id() -> Int {
        nextID += 1
        return nextID
    }

    private func unit() -> Double { Double(random.next() % 1_000_000) / 1_000_000 }

    private func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }

    private func build(_ chunk: FlightChunk, at start: Double, pressure: Double) -> (hazards: [FlightHazard], end: Double) {
        let v = speed(at: start)
        let beatTime = (0.56 + 0.22 * (1 - pressure)) * difficulty.spacing
        let beat = v * beatTime
        let gap = max(44, (66 - 16 * pressure) * difficulty.gapScale)
        let top = Self.ceiling
        var list: [FlightHazard] = []
        var cursor = start
        func gate(_ x: Double, center: Double, gap: Double, width: Double = 26, motion: FlightHazard.Motion = .none) {
            let low = center - gap / 2, high = center + gap / 2
            if low > 2 { list.append(FlightHazard(id: id(), kind: .pillar, x: x, y: 0, width: width, height: low, motion: motion)) }
            if high < top - 2 {
                list.append(FlightHazard(id: id(), kind: .pillar, x: x, y: high, width: width, height: top - high, motion: motion))
            }
        }
        func center() -> Double { range(gap / 2 + 4, top - gap / 2 - 4) }

        switch chunk {
        case .gates:
            var c = center()
            for _ in 0..<(2 + Int(random.next() % 3)) {
                gate(cursor, center: c, gap: gap)
                let move = range(18, 34 + 14 * pressure) * (unit() < 0.5 ? -1 : 1)
                c = min(max(c + move, gap / 2 + 4), top - gap / 2 - 4)
                cursor += beat
            }
        case .slalom:
            // 위아래 번갈아 내민 벽
            var fromTop = unit() < 0.5
            for _ in 0..<(3 + Int(random.next() % 3)) {
                let reach = range(top * 0.45, top * (0.62 + 0.08 * pressure))
                let y = fromTop ? top - reach : 0
                list.append(FlightHazard(id: id(), kind: .pillar, x: cursor, y: y, width: 24, height: reach))
                fromTop.toggle()
                cursor += beat * 0.9
            }
        case .islands:
            // 하늘에 떠 있는 바위들
            for _ in 0..<(3 + Int(random.next() % 3)) {
                let height = range(20, 40)
                list.append(FlightHazard(id: id(), kind: .rock, x: cursor + range(0, beat * 0.3), y: range(4, top - height - 4),
                                         width: range(26, 46), height: height))
                cursor += beat * 0.62
            }
        case .batSwarm:
            // 물결치며 마주 오는 박쥐 떼
            let wavelength = range(v * 0.7, v * 1.1)
            for k in 0..<(4 + Int(random.next() % 3)) {
                let line = range(14, top - 30)
                var bat = FlightHazard(id: id(), kind: .bat, x: cursor, y: line, width: 26, height: 16)
                bat.motion = k % 2 == 0 ? .bob(amplitude: range(10, 22), wavelength: wavelength) : .none
                list.append(bat)
                cursor += beat * 0.5
            }
        case .stickySlime:
            for _ in 0..<(3 + Int(random.next() % 3)) {
                list.append(FlightHazard(id: id(), kind: .slime, x: cursor, y: range(6, top - 26), width: 20, height: 18))
                cursor += beat * 0.45
            }
        case .movingGates:
            for _ in 0..<(2 + Int(random.next() % 2)) {
                let c = range(gap + 6, top - gap - 6)
                gate(cursor, center: c, gap: gap + 8,
                     motion: .bob(amplitude: range(12, 20), wavelength: v * range(1.3, 1.9)))
                cursor += beat * 1.2
            }
        case .fallingRocks:
            for _ in 0..<(3 + Int(random.next() % 2)) {
                let width = 30.0
                let height = 24.0
                let lead = v * 0.62
                list.append(FlightHazard(id: id(), kind: .crusher, x: cursor, y: top - height, width: width, height: height,
                                         motion: .fall(trigger: cursor - lead, rate: 0.55)))
                cursor += beat * 0.95
            }
        case .bouncers:
            for _ in 0..<(3 + Int(random.next() % 2)) {
                var ball = FlightHazard(id: id(), kind: .spikeball, x: cursor, y: top / 2 - 11, width: 22, height: 22)
                ball.motion = .bob(amplitude: top / 2 - 11, wavelength: v * range(0.9, 1.3))
                list.append(ball)
                cursor += beat * 0.85
            }
        case .staircase:
            // 틈이 한쪽으로 차곡차곡 옮겨 간다
            let down = unit() < 0.5
            let count = 4
            for k in 0..<count {
                let t = Double(k) / Double(count - 1)
                let c = (gap / 2 + 5) + (top - gap - 10) * (down ? 1 - t : t)
                gate(cursor, center: c, gap: gap + 4)
                cursor += beat * 0.78
            }
        case .drills:
            // 마주 날아오는 드릴
            let from = start - v * 1.1
            for k in 0..<(3 + Int(random.next() % 2)) {
                let lane = range(4, top - 22)
                list.append(FlightHazard(id: id(), kind: .drill, x: cursor + v * 0.6 + Double(k) * v * 0.4, y: lane, width: 32, height: 16,
                                         motion: .approach(from: from + Double(k) * v * 0.15, rate: 0.5)))
                cursor += beat * 0.55
            }
        case .tunnel:
            // 구불구불한 굴: 짧은 기둥을 촘촘히 잇는다
            var c = center()
            let wide = gap + 10
            let segments = 14
            let width = 22.0
            let phase = range(0, 6.28)
            for k in 0..<segments {
                c = (top / 2) + (top / 2 - wide / 2 - 4) * sin(phase + Double(k) * 0.55)
                gate(cursor, center: c, gap: wide, width: width)
                cursor += width
            }
        }
        return (list, cursor)
    }

    /// 후보 조각을 넘을 수 있는지 사람 입력 간격으로 앞을 내다본다. 지나갈 길이 없으면 nil.
    private func advancePlan(_ all: [FlightHazard], from start: Double, to end: Double) -> (states: [PlanState], best: [PlanPoint])? {
        var states = frontier
        var position = start
        // 여유: 판정을 그림만큼 키워도 지나갈 수 있어야 사람 몫이 남는다
        let inset = Self.hitInset - 4
        let near = all.filter { $0.position(at: start).x < end + 400 && $0.position(at: end).x + $0.width > start - 60 }
        while position < end {
            let v = speed(at: position)
            var next: [PlanState] = []
            var seen = Set<Int>()
            let span = v * Self.step * 12
            for state in states {
                for hold in [false, true] {
                    var moved = state
                    var px = position
                    var alive = true
                    for _ in 0..<12 {
                        px += v * Self.step
                        Self.move(&moved, hold: hold, speed: v, heavy: false, dt: Self.step)
                        if near.contains(where: { Self.overlaps(px: px, py: moved.y, hazard: $0, at: px, inset: inset) }) {
                            alive = false
                            break
                        }
                    }
                    guard alive else { continue }
                    let key = Int(moved.y / 5) * 1000 + Int((moved.velocity + 1000) / 60)
                    guard seen.insert(key).inserted else { continue }
                    moved.path.append(PlanPoint(x: px, y: moved.y))
                    if moved.path.count > 40 { moved.path.removeFirst() }
                    next.append(moved)
                }
            }
            guard !next.isEmpty else { return nil }
            // 넓은 높이에 고루 남긴다
            if next.count > 40 {
                next.sort { $0.y < $1.y }
                let step = Double(next.count) / 40
                next = (0..<40).map { next[Int(Double($0) * step)] }
            }
            states = next
            position += span
        }
        let middle = states.min { abs($0.y - Self.ceiling / 2) < abs($1.y - Self.ceiling / 2) }
        return (states, middle?.path ?? [])
    }

    /// 지나갈 길을 따라 사탕을 놓는다. 사탕을 따라가면 자연스럽게 틈으로 들어간다.
    private func placePickups(along path: [PlanPoint], from start: Double) {
        let inside = path.filter { $0.x >= start }
        guard !inside.isEmpty else { return }
        sinceShield += 1
        if sinceShield >= 9, let spot = inside.dropFirst(inside.count / 2).first {
            sinceShield = 0
            pickups.append(FlightPickup(id: id(), kind: .shield, x: spot.x, y: spot.y + Self.runnerHeight / 2))
            return
        }
        guard unit() < 0.7 else { return }
        for (index, point) in inside.enumerated() where index % 2 == 0 {
            pickups.append(FlightPickup(id: id(), kind: .candy, x: point.x, y: point.y + Self.runnerHeight / 2))
        }
    }
}

struct PlanPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct PlanState: Sendable {
    var y: Double
    var velocity: Double
    var path: [PlanPoint]
}

/// 스스로 나는 플레이어. 0.1초마다 앞을 내다보고 고른다. 규칙 테스트와 화면 점검 도구가 쓴다.
public final class FlightPilot {
    private let game: FlightGame
    private var countdown = 0
    /// 이 확률로 고른 것과 반대로 손을 움직인다. 사람의 실수를 흉내 낸다.
    private let mistakes: Double
    private var random: SplitMix64
    private var holding = false

    public init(game: FlightGame, mistakes: Double = 0, seed: UInt64 = 1) {
        self.game = game
        self.mistakes = mistakes
        random = SplitMix64(seed: seed)
    }

    /// 틱마다 부른다.
    public func step() {
        guard game.phase == .playing else { return }
        countdown -= 1
        guard countdown <= 0 else { return }
        countdown = 12
        var hold = decide()
        if Double(random.next() % 1000) / 1000 < mistakes { hold.toggle() }
        if hold, !holding { game.press() }
        if !hold, holding { game.release() }
        holding = hold
    }

    private func decide() -> Bool {
        let speed = game.currentSpeed
        let hazards = game.hazards
        struct Node { var state: PlanState; var x: Double; var first: Bool? }
        var nodes = [Node(state: PlanState(y: game.y, velocity: game.velocityY, path: []), x: game.x, first: nil)]
        for _ in 0..<15 {
            var next: [Node] = []
            var seen = Set<Int>()
            for node in nodes {
                for hold in [true, false] {
                    var moved = node.state
                    var px = node.x
                    var alive = true
                    for _ in 0..<12 {
                        px += speed * FlightGame.step
                        FlightGame.move(&moved, hold: hold, speed: speed, heavy: game.heavy > 0, dt: FlightGame.step)
                        if hazards.contains(where: { FlightGame.overlaps(px: px, py: moved.y, hazard: $0, at: px, inset: -1) }) {
                            alive = false
                            break
                        }
                    }
                    guard alive else { continue }
                    let key = Int(moved.y / 6) * 1000 + Int((moved.velocity + 1000) / 80)
                    guard seen.insert(key).inserted else { continue }
                    next.append(Node(state: moved, x: px, first: node.first ?? hold))
                }
            }
            if next.isEmpty { break }
            if next.count > 60 {
                next.sort { $0.state.y < $1.state.y }
                let step = Double(next.count) / 60
                next = (0..<60).map { next[Int(Double($0) * step)] }
            }
            nodes = next
        }
        let target = FlightGame.ceiling / 2 - FlightGame.runnerHeight / 2
        return nodes.min { abs($0.state.y - target) < abs($1.state.y - target) }?.first ?? false
    }
}

