import AppKit
import Combine
import UsageCore

/// 러너 속도 설정 점검 (`--pace-check`). 실제 엔진에 흉내 낸 타자를 넣고 민감도, 달리기 속도, 기록 확인 주기를 바꿔 가며
/// 러너 단계, 빠르기, 메뉴바 레이어 재생 속도, 틱 간격이 설정대로 바뀌는지 본다.
/// Claude 폴더는 빈 임시 폴더로 바꾸고 공식 연동을 꺼서 이 Mac의 Claude 기록과 로그인을 건드리지 않는다. 바꾼 설정은 끝나면 되돌린다.
@MainActor
enum PaceCheck {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String) {
        print((ok ? "통과  " : "실패  ") + name + "  (" + detail + ")")
        fflush(stdout)
        if !ok { failures += 1 }
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 흉내 낸 키보드. 켜 둔 동안 1분에 평균 `perMinute`타를 한 타씩 누른다.
    /// 사람 손처럼 키 사이 간격이 평균의 60~140%로 흔들린다 (같은 씨앗이라 매번 같은 순서로 흔들린다).
    /// 엔진의 workQueue와 메인에서 함께 읽는다.
    final class Keys: @unchecked Sendable {
        private let lock = NSLock()
        private var count: UInt32 = 0
        private var perMinute: Double = 0
        private var nextKey = Date.distantFuture
        private var lastKey = Date.distantPast
        private var seed: UInt64 = 0x2545F4914F6CDD1D

        func type(perMinute: Double) {
            lock.lock(); defer { lock.unlock() }
            advance()
            guard perMinute != self.perMinute else { return }
            self.perMinute = perMinute
            nextKey = perMinute > 0 ? Date().addingTimeInterval(gap()) : .distantFuture
        }

        var total: UInt32 {
            lock.lock(); defer { lock.unlock() }
            advance()
            return count
        }

        var idle: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            advance()
            return Date().timeIntervalSince(lastKey)
        }

        private func advance() {
            let now = Date()
            while nextKey <= now {
                count += 1
                lastKey = nextKey
                nextKey = nextKey.addingTimeInterval(gap())
            }
        }

        private func gap() -> TimeInterval {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(seed >> 11) / Double(1 << 53)
            return 60 / perMinute * (0.6 + 0.8 * unit)
        }
    }

    /// 틱 시각. workQueue에서 쌓고 메인에서 읽는다.
    final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Date] = []

        func append(_ date: Date) { lock.lock(); times.append(date); lock.unlock() }
        func reset() { lock.lock(); times = []; lock.unlock() }
        var gaps: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
        }
    }

    static func run() async -> Bool {
        let settings = AppSettings.shared
        let saved = (settings.sensitivity, settings.runnerSpeed, settings.pollInterval,
                     settings.officialEnabled, settings.typingRunnerEnabled)
        // 엔진은 만들 때의 설정으로 첫 조회를 정하므로 공식 연동은 엔진보다 먼저 끈다
        settings.officialEnabled = false
        settings.typingRunnerEnabled = true
        settings.sensitivity = .normal
        settings.runnerSpeed = 1
        settings.pollInterval = 1

        let keys = Keys()
        let ticks = Ticks()
        let engine = UsageEngine(settings: settings)
        // 키 입력과 '아무 입력'만 흉내 낸다. 마우스는 오래 쉰 것으로 두어 멈추면 둘러보지 않고 선다
        engine.input = .init(keyDownCount: { keys.total },
                             secondsSince: { $0 == .keyDown || $0.rawValue == ~0 ? keys.idle : 1000 })
        engine.onTick = { ticks.append($0) }
        let animator = SpriteAnimator()
        let tempo = engine.$tempo.removeDuplicates().sink { animator.setTempo($0) }
        engine.start()

        // 같은 타자 빠르기(165타/분)에서 민감도만 바꾼다. 경계: 낮음 240·500, 보통 120·250, 높음 60·125·200
        keys.type(perMinute: 165)
        let expected: [(Thresholds.Sensitivity, CatState)] = [(.low, .walking), (.normal, .running), (.high, .dashing)]
        for (sensitivity, state) in expected {
            settings.sensitivity = sensitivity
            await settle(5)   // 설정 반영 0.2초 + 타자 구간 3초 + 타자 타이머 1초
            check("민감도 \(sensitivity.displayName): 165타/분이면 \(state)", engine.catState == state, "실제 \(engine.catState)")
        }

        // 민감도를 낮추면 바로 따라온다: 높음에서 질주하던 165타/분이 낮음에서는 걷기여야 하고, 앞 단계를 붙잡지 않는다
        settings.sensitivity = .high
        await settle(5)
        settings.sensitivity = .low
        await settle(4)
        check("민감도를 높음에서 낮음으로 바꾸면 바로 걷는다 (165타/분)", engine.catState == .walking, "실제 \(engine.catState)")

        // 보통 민감도로 달리는 동안 배율만 바꾼다. 단계 안 빠르기는 0.85~1.3이고 늦은 밤이면 0.8을 더 곱한다
        settings.sensitivity = .normal
        let night = Pace.isNight(Date()) ? Pace.nightTempo : 1
        var measured: [Double: Double] = [:]
        for speed in [1, 0.5, 2.0] {
            settings.runnerSpeed = speed
            await settle(3)
            let value = engine.tempo
            measured[speed] = value
            let range = (0.85 * speed * night - 0.01)...(1.3 * speed * night + 0.01)
            check("달리기 속도 \(speed)배: 빠르기가 \(fmt(range.lowerBound))~\(fmt(range.upperBound))",
                  engine.catState == .running && range.contains(value), "단계 \(engine.catState), 빠르기 \(fmt(value))")
            let layer = Double(animator.layer.speed)
            check("달리기 속도 \(speed)배: 메뉴바 러너가 같은 빠르기로 재생", abs(layer - min(max(value, 0.25), 3)) < 0.011,
                  "레이어 \(fmt(layer))")
        }
        if let base = measured[1], let slow = measured[0.5], let fast = measured[2] {
            check("배율이 빠르기에 그대로 곱해진다", abs(slow / base - 0.5) < 0.08 && abs(fast / base - 2) < 0.3,
                  "1배 \(fmt(base)), 0.5배 \(fmt(slow)), 2배 \(fmt(fast))")
        }

        // 손을 떼면 2초 뒤 멈춘다. 서 있는 동안은 배율을 곱하지 않는다
        keys.type(perMinute: 0)
        await settle(4)
        check("멈춰 있을 때는 배율을 곱하지 않는다", engine.catState == .standing && engine.tempo == 1 && animator.layer.speed == 1,
              "단계 \(engine.catState), 빠르기 \(fmt(engine.tempo)), 레이어 \(fmt(Double(animator.layer.speed)))")

        // 기록 확인 주기를 바꾸면 틱 간격이 따라 바뀐다. 타이머 여유(10%)만큼 흔들린다
        for interval in [1.0, 3.0] {
            settings.pollInterval = interval
            await settle(1)
            ticks.reset()
            await settle(interval * 4 + 0.5)
            let gaps = ticks.gaps
            let average = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
            check("기록 확인 주기 \(Int(interval))초: 틱 간격", gaps.count >= 3 && abs(average - interval) <= interval * 0.15,
                  "평균 \(fmt(average))초, \(gaps.count)번")
        }

        settings.pollInterval = 3
        await typingResponse(engine: engine, keys: keys)

        tempo.cancel()
        (settings.sensitivity, settings.runnerSpeed, settings.pollInterval,
         settings.officialEnabled, settings.typingRunnerEnabled) = saved
        print(failures == 0 ? "모두 통과" : "실패 \(failures)건")
        return failures == 0
    }

    /// 0.1초마다 러너 단계를 적는다. `script`는 지난 시간(초)마다 불려 타자를 바꾼다.
    private static func record(_ engine: UsageEngine, seconds: Double,
                               script: (Double) -> Void = { _ in }) async -> [(time: Double, state: CatState)] {
        var samples: [(time: Double, state: CatState)] = []
        let start = Date()
        while true {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= seconds { break }
            script(elapsed)
            samples.append((elapsed, engine.catState))
            await settle(0.1)
        }
        return samples
    }

    private static func firstTime(_ samples: [(time: Double, state: CatState)], _ match: (CatState) -> Bool) -> Double? {
        samples.first { match($0.state) }?.time
    }

    private static func changes(_ samples: [(time: Double, state: CatState)]) -> Int {
        zip(samples.dropFirst(), samples).filter { $0.state != $1.state }.count
    }

    private static func isMoving(_ state: CatState) -> Bool {
        [.walking, .running, .dashing, .rainbow].contains(state)
    }

    /// 실제 타자처럼 치기 시작, 손 떼기, 빨라지기, 느려지기, 경계 근처, 생각하며 쉬기를 흉내 내 반응을 잰다 (보통 민감도).
    private static func typingResponse(engine: UsageEngine, keys: Keys) async {
        keys.type(perMinute: 0)
        await settle(4)
        print("타자 반응 (키 간격을 사람처럼 흔든 흉내 입력, 보통 민감도)")
        let start = await record(engine, seconds: 6) { _ in keys.type(perMinute: 200) }
        let ran = firstTime(start) { $0 == .running }
        check("치기 시작하면 1.5초 안에 달린다 (200타/분)", ran.map { $0 <= 1.5 } ?? false, "\(ran.map(fmt) ?? "못 달림")초")

        let stop = await record(engine, seconds: 5) { _ in keys.type(perMinute: 0) }
        let stopped = firstTime(stop) { !isMoving($0) }
        // 생각하며 잠깐 쉬는 동안 멈추지 않게 마지막 키 뒤 2초를 기다린다
        check("손을 떼면 2.5초 안에 선다", stopped.map { $0 <= 2.5 } ?? false, "\(stopped.map(fmt) ?? "안 멈춤")초")

        keys.type(perMinute: 150)
        await settle(5)
        let up = await record(engine, seconds: 6) { _ in keys.type(perMinute: 320) }
        let faster = firstTime(up) { $0 == .dashing }
        check("빨라지면 3.5초 안에 질주한다 (150 → 320타/분)", faster.map { $0 <= 3.5 } ?? false, "\(faster.map(fmt) ?? "못 따라감")초")
        let down = await record(engine, seconds: 6) { _ in keys.type(perMinute: 150) }
        let slower = firstTime(down) { $0 == .running }
        check("느려지면 4.5초 안에 달리기로 내려온다 (320 → 150타/분)", slower.map { $0 <= 4.5 } ?? false,
              "\(slower.map(fmt) ?? "못 따라감")초")

        for rate in [124.0, 246.0] {
            keys.type(perMinute: rate)
            await settle(4)
            let edge = await record(engine, seconds: 12)
            // 키 간격이 흔들려 3초 구간에서 한두 타가 모자라는 순간이 있어 내렸다 다시 오르는 한 번의 깜빡임은 허용한다
            check("경계 근처(\(Int(rate))타/분)로 이어 치면 단계가 자주 바뀌지 않는다", changes(edge) <= 2,
                  "12초 동안 \(changes(edge))번 바뀜")
        }

        // 3초 치고 1.2초 생각하기를 네 번
        let thinking = await record(engine, seconds: 16.8) { t in
            keys.type(perMinute: t.truncatingRemainder(dividingBy: 4.2) < 3 ? 220 : 0)
        }
        let stops = zip(thinking.dropFirst(), thinking).filter { isMoving($1.state) && !isMoving($0.state) }.count
        check("생각하며 1.2초씩 쉬어도 멈추지 않는다", stops == 0, "멈춤 \(stops)번, 단계 바뀜 \(changes(thinking))번")
        keys.type(perMinute: 0)
    }

    /// 실제 키보드로 쳐 보며 엔진이 세는 타수를 눈으로 본다 (`--typing-count-check`). 앱은 키를 읽지 않고 시스템이 세는 횟수만 본다.
    /// 1초마다 지난 1초의 키 누름 수, 3초 구간 타/분, 지금 러너 단계를 적는다. 20초 뒤 끝난다.
    static func typingCount() async {
        var meter = TypingMeter()
        var last = UsageEngine.InputSource.system.keyDownCount()
        var total: UInt32 = 0
        print("20초 동안 키보드로 쳐 보세요. 예) 평소 속도로 20타, 한 글자를 꾹 눌러 반복, 한글 입력, 단축키(⌘C)")
        print("초  | 이번 1초 | 3초 구간 타/분 | 합계")
        for second in 1...20 {
            await settle(1)
            let count = UsageEngine.InputSource.system.keyDownCount()
            let delta = count &- last
            last = count
            total &+= delta
            let rate = meter.rate(count: count, now: Date())
            print(String(format: "%2d초 | %8u | %14.0f | %u", second, delta, rate, total))
            fflush(stdout)
        }
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
}
