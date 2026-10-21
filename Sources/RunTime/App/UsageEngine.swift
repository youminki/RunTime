import Foundation
import Combine
import os.log
import UsageCore

/// 공식 usage 연동 상태 (팝오버 푸터·설정 화면 표시용).
enum OfficialStatus: Equatable {
    case disabled
    case waiting                  // 첫 조회 전
    case live
    case stale(reason: String)    // 조회 실패, 직전 공식 값 유지 중
    case failed(reason: String)   // 조회 실패, 게이지 비움
}

/// JSONL 감시 → 집계 → burn rate → 고양이 상태 + 공식 % 폴링 + 한도 알림을 묶는 엔진.
/// 역할 분담(§2 하이브리드): 게이지 % = 공식 엔드포인트, 속도·토큰량·스파크라인 = 로컬 JSONL.
final class UsageEngine: ObservableObject {

    @Published var snapshot: UsageStore.Snapshot?
    @Published var burnRate: Double = 0
    @Published var catState: CatState = .sleeping
    /// 같은 단계 안에서의 빠르기 (0.85~1.3). 메뉴바와 무대 러너의 걸음 빠르기에 곱한다.
    @Published var tempo: Double = 1
    /// 한도 임박 오버라이드 (§F2: 80% 지침, 95% 경고). 세션/주간 중 높은 쪽 기준.
    @Published var alertLevel: UsageAlertLevel = .normal

    /// 마지막 공식 usage 성공 응답. nil = 미조회/실패/연동 off → 게이지를 비운다.
    /// 화면용 사본이고 원본은 workQueue의 `officialValue`.
    @Published var official: OfficialUsage?
    @Published var officialStatus: OfficialStatus = .waiting
    /// 공식 값이 없으면 nil. 로컬 기록으로 추정하면 `/usage`와 어긋나서 비워 둔다.
    @Published var sessionGauge: GaugeReading?
    @Published var weeklyGauge: GaugeReading?
    /// 현재 속도로 세션 한도에 닿기까지 남은 분. 속도가 없으면 nil.
    @Published var sessionMinutesLeft: Int?
    /// 공식 세션 창의 리셋 시각.
    @Published var sessionResetsAt: Date?
    /// 공식 응답에서 알아낸 다음 주간 리셋. 조회가 끊겨도 7일 단위로 굴려 유지한다.
    @Published var nextWeeklyReset: Date?
    /// 주간 사용처별 비중 (Claude Code, 채팅 등). 공식 값이 있을 때만.
    @Published var weeklyBreakdown: [UsageShare] = []

    let settings: AppSettings

    /// 공식 폴링 간격 180초 고정 (429 방지 안전 간격).
    static let officialPollInterval: TimeInterval = 180
    /// 팝오버 열 때 재조회 생략 기준: 직전 조회 30초 이내.
    static let officialRefreshThrottle: TimeInterval = 30
    /// 조회가 실패해도 이 시간 안의 공식 값은 계속 쓴다. 일시적 실패로 게이지가 비지 않게.
    static let officialGrace: TimeInterval = 15 * 60
    /// 429를 받으면 이만큼 조회를 쉰다.
    static let rateLimitBackoff: TimeInterval = 10 * 60
    /// 공식 창이 초기화된 뒤 새 값을 받을 때까지 다시 조회하는 간격.
    static let rolloverRefetchInterval: TimeInterval = 30

    private let watcher = JSONLWatcher()
    private var turnDetector = TurnEndDetector()
    /// Claude가 대화 차례를 마쳤다 (폴더 이름, 일한 시간). 메인 스레드에서 보낸다.
    let turnEnded = PassthroughSubject<TurnEndDetector.FinishedTurn, Never>()
    /// 사용량 흐름에서 러너가 반응할 순간 (부스트, 다시 시작, 세션 단계, 동시 작업, 새 세션). 메인 스레드에서 보낸다.
    let reacted = PassthroughSubject<UsageReactions.Reaction, Never>()
    /// 마지막 기록과 마지막으로 차례가 끝난 때. 메인 스레드에서 읽고 쓴다.
    static private(set) var lastActivity: Date?
    static private(set) var lastTurnEnd: Date?

    /// Claude가 지금 일하는 중인지. 1분 안에 기록이 있고, 그 뒤로 차례가 끝나지 않았다.
    static var isClaudeWorking: Bool {
        guard let last = lastActivity, Date().timeIntervalSince(last) < 60 else { return false }
        return lastTurnEnd.map { last > $0 } ?? true
    }
    private let store = UsageStore()
    private let meter = BurnRateMeter()
    private let provider = OAuthUsageProvider()
    private let workQueue = DispatchQueue(label: "runtime.engine", qos: .utility)
    private var jsonlTimer: DispatchSourceTimer?
    private var officialTimer: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    // 이하 상태는 workQueue 전용
    private var config: Config
    private var officialValue: OfficialUsage?
    private var clientVersion: String?
    private var alertTracker: LimitAlertTracker = {
        var tracker = LimitAlertTracker()
        tracker.saved = UserDefaults.standard.dictionary(forKey: UsageEngine.limitAlertsKey) as? [String: String] ?? [:]
        return tracker
    }()
    private static let limitAlertsKey = "limitAlertsSent"
    private var lastBlockStart: Date?
    private var lastWeeklyReset: Date?
    private var lastTickAt: Date?
    private var lastOfficialAttempt: Date?
    private var officialInFlight = false
    private var officialBackoffUntil: Date?
    private var lastOfficialFailure = ""
    /// 켠 뒤 공식 조회 결과를 한 번이라도 받았는지. 그 전에는 주간 경계를 모른다.
    private var officialAnswered = false
    private var knownWeeklyReset: Date?
    /// 최근 공식 세션 %의 오름세. "약 N분 뒤 한도"를 공식 값만으로 계산한다.
    private var sessionTrend = OfficialTrend()
    private var reactions = UsageReactions()
    /// 폴더별 마지막 기록 시각. 1분 안에 기록이 있는 폴더 수로 동시 작업을 센다.
    private var projectSeen: [String: Date] = [:]

    /// 진단용: `log stream --predicate 'subsystem == "dev.runtime.RunTime"' --info`
    private let log = Logger(subsystem: "dev.runtime.RunTime", category: "engine")

    init(settings: AppSettings = .shared) {
        self.settings = settings
        self.config = Config(settings)
    }

    func start() {
        let interval = settings.pollInterval
        log.info("엔진 시작: 폴링 \(interval)s, 공식 폴링 \(Self.officialPollInterval)s")
        // App Nap 방지: 메뉴바 전용 앱은 냅 대상이 되어 백그라운드 타이머가
        // 지연·정지될 수 있다(고양이 애니메이션은 돌지만 데이터만 멈춘 것처럼 보임).
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "토큰 사용량 폴링")

        let jsonlTimer = DispatchSource.makeTimerSource(queue: workQueue)
        jsonlTimer.setEventHandler { [weak self] in self?.tick() }
        self.jsonlTimer = jsonlTimer
        workQueue.async { self.applyPollInterval(interval) }
        jsonlTimer.resume()

        let officialTimer = DispatchSource.makeTimerSource(queue: workQueue)
        officialTimer.schedule(deadline: .now() + 1, repeating: Self.officialPollInterval)
        officialTimer.setEventHandler { [weak self] in self?.fetchOfficial(minInterval: 0) }
        officialTimer.resume()
        self.officialTimer = officialTimer

        // 틱이 메인 스레드를 기다리지 않도록 설정은 바뀔 때마다 메인에서 모아 workQueue로 넘긴다.
        // 입력 중 연타는 묶는다.
        settings.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushConfig() }
            .store(in: &cancellables)
    }

    /// JSONL 즉시 재스캔 + 공식 재조회.
    /// 팝오버 열림: 30초 스로틀(§F3). 새로고침 버튼: forceOfficial=true로 우회
    /// (연타 방지 5초만 유지) — 버튼이 팝오버 열림 직후 스로틀에 걸려 아무것도
    /// 안 하던 문제 방지.
    func refreshNow(forceOfficial: Bool = false) {
        workQueue.async { [weak self] in
            self?.tick()
            self?.fetchOfficial(minInterval: forceOfficial ? 5 : Self.officialRefreshThrottle)
        }
    }

    private func applyPollInterval(_ interval: TimeInterval) {
        lastTickAt = nil   // 간격이 바뀐 직후 지연 경고가 뜨지 않게
        jsonlTimer?.schedule(deadline: .now(), repeating: interval)
    }

    // MARK: - 설정

    /// 틱 계산에 쓰는 설정 사본. 메인에서 만들어 workQueue로 넘긴다.
    private struct Config: Equatable {
        let officialEnabled: Bool
        let sensitivity: Thresholds.Sensitivity
        let limitAlertsEnabled: Bool
        let newSessionAlertEnabled: Bool
        let weeklyResetAlertEnabled: Bool
        let weeklySummaryEnabled: Bool
        let pollInterval: TimeInterval

        init(_ settings: AppSettings) {
            officialEnabled = settings.officialEnabled
            sensitivity = settings.sensitivity
            limitAlertsEnabled = settings.limitAlertsEnabled
            newSessionAlertEnabled = settings.newSessionAlertEnabled
            weeklyResetAlertEnabled = settings.weeklyResetAlertEnabled
            weeklySummaryEnabled = settings.weeklySummaryEnabled
            pollInterval = settings.pollInterval
        }
    }

    private func pushConfig() {
        let new = Config(settings)
        workQueue.async { [weak self] in self?.apply(new) }
    }

    private func apply(_ new: Config) {
        let old = config
        // 테마·메뉴바 표시처럼 틱과 무관한 설정은 건너뛴다. BurnRateMeter가 틱 단위 EMA라 틱이 늘면 속도가 달라진다.
        guard new != old else { return }
        config = new
        if new.officialEnabled != old.officialEnabled {
            if new.officialEnabled {
                // 토글 연타로 요청이 몰려 429를 맞지 않게 5초 스로틀은 유지하고, 걸리면 풀린 뒤 다시 조회한다.
                let started = fetchOfficial(minInterval: 5)
                if started || lastOfficialFailure.isEmpty {
                    if !started {
                        workQueue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.fetchOfficial(minInterval: 5) }
                    }
                    publishOfficial(nil, status: .waiting)
                } else {
                    publishOfficial(nil, status: .failed(reason: lastOfficialFailure))
                }
            } else {
                officialValue = nil
                publishOfficial(nil, status: .disabled)   // 연동 off → 게이지를 바로 비운다
            }
        }
        if new.pollInterval != old.pollInterval {
            applyPollInterval(new.pollInterval)   // 타이머가 바로 한 번 돈다
        } else {
            tick()   // 설정 변경을 다음 틱까지 기다리지 않고 반영
        }
    }

    private func publishOfficial(_ usage: OfficialUsage?, status: OfficialStatus) {
        DispatchQueue.main.async {
            self.official = usage
            self.officialStatus = status
        }
    }

    // MARK: - JSONL 틱

    private func tick() {
        let now = Date()
        let config = self.config
        // 틱 간격이 폴링 주기의 3배를 넘으면 타이머가 지연/정지된 것 — 진단 신호
        if let last = lastTickAt, now.timeIntervalSince(last) > config.pollInterval * 3 {
            log.warning("tick 지연: \(Int(now.timeIntervalSince(last)))초 만에 재개")
        }
        lastTickAt = now

        // 유예 시간을 넘긴 공식 값은 버린다 (조회가 계속 실패하거나 잠자기에서 깬 경우).
        let official = UsageEvaluator.usableOfficial(officialValue, enabled: config.officialEnabled,
                                                     now: now, grace: Self.officialGrace)
        if config.officialEnabled, officialValue != nil, official == nil {
            officialValue = nil
            // 실패 없이 오래되기만 했으면(잠자기) 곧 다시 조회하므로 실패로 보이지 않게 한다.
            publishOfficial(nil, status: lastOfficialFailure.isEmpty ? .waiting : .failed(reason: lastOfficialFailure))
            if lastOfficialFailure.isEmpty { fetchOfficial(minInterval: Self.officialRefreshThrottle) }
        }

        if let reset = official?.weeklyResetsAt { knownWeeklyReset = reset }
        let nextWeeklyReset = knownWeeklyReset.map { WeeklyWindow.nextReset(from: $0, now: now) }
        checkWeeklyReset(nextWeeklyReset, enabled: config.weeklyResetAlertEnabled)
        // 주간 모델 비중도 공식 주간 창으로 집계해 게이지와 같은 기간을 보게 한다.
        let weeklyStart = nextWeeklyReset.map { $0.addingTimeInterval(-WeeklyWindow.duration) }
            ?? WeeklyWindow.rollingStart(now: now)

        let scanned = watcher.scan(now: now)
        // 켠 직후 공식 리셋을 아직 모르면 월요일을 주의 시작으로 잘못 보고 지난주 요약을 한 번 더 보낸다
        let weeklyBoundaryKnown = nextWeeklyReset != nil || !config.officialEnabled || officialAnswered
        defer {
            if weeklyBoundaryKnown {
                checkWeeklySummary(nextReset: nextWeeklyReset, now: now, enabled: config.weeklySummaryEnabled)
            }
        }
        let finished = turnDetector.finishedTurns(in: scanned, now: now)
        store.add(scanned)
        let lastEvent = scanned.map(\.timestamp).max()
        let lastEnd = finished.map(\.endedAt).max()
        DispatchQueue.main.async {
            if let lastEvent, lastEvent > Self.lastActivity ?? .distantPast { Self.lastActivity = lastEvent }
            if let lastEnd { Self.lastTurnEnd = max(lastEnd, Self.lastTurnEnd ?? .distantPast) }
            if let last = finished.last { self.turnEnded.send(last) }
        }
        let snap = store.snapshot(now: now, weeklySince: weeklyStart)
        if let version = snap.latestClientVersion { clientVersion = version }
        let rate = meter.update(tokensInLastMinute: snap.tokensLast60s)
        let idle = snap.lastEventDate.map { now.timeIntervalSince($0) } ?? .infinity
        let thresholds = Thresholds.preset(sensitivity: config.sensitivity)
        let state = thresholds.state(burnRate: rate, idleSeconds: idle)
        let tempo = thresholds.tempo(burnRate: rate, state: state)
        for event in scanned {
            guard let project = event.project, event.timestamp > projectSeen[project] ?? .distantPast else { continue }
            projectSeen[project] = event.timestamp
        }
        projectSeen = projectSeen.filter { now.timeIntervalSince($0.value) < 10 * 60 }
        let activeProjects = projectSeen.values.filter { now.timeIntervalSince($0) < 60 }.count

        let blockTokens = snap.currentBlock?.totalTokens ?? 0
        let result = UsageEvaluator.evaluate(UsageEvaluator.Input(
            official: official, now: now,
            // 이 기기에서 지금 쓰고 있지 않으면 한도 도달 시간을 보여 주지 않는다
            sessionRatePerMinute: rate >= 1 ? sessionTrend.ratePerMinute(now: now) : nil))
        // 조회 뒤 공식 창이 초기화됐으면 다음 정기 조회(최대 3분)를 기다리지 않고 새 값을 받는다.
        if result.needsRefresh { fetchOfficial(minInterval: Self.rolloverRefetchInterval) }

        if config.limitAlertsEnabled {
            fireLimitAlerts(snap: snap, nextWeeklyReset: nextWeeklyReset, result: result)
        }
        // 새 세션은 공식 창으로만 센다. 로컬 블록과 섞으면 공식 값이 오가며 창이 바뀐 것처럼 보인다
        let window = result.sessionResetsAt.map(LimitAlertTracker.windowId(resetsAt:))
        let reaction = reactions.update(.init(rate: rate, runThreshold: thresholds.run, idleSeconds: idle,
                                              sessionPercent: result.session?.percent, sessionWindow: window,
                                              activeProjects: activeProjects, now: now))
        checkNewBlock(snap: snap, enabled: config.newSessionAlertEnabled)

        log.debug("tick: today=\(snap.todayTokens) block=\(blockTokens) last60s=\(snap.tokensLast60s) rate=\(Int(rate)) state=\(state.rawValue, privacy: .public) 세션%=\(result.session.map { String(format: "%.1f", $0.percent) } ?? "없음", privacy: .public)")

        let breakdown = official?.weeklyBreakdown ?? []
        DispatchQueue.main.async {
            self.snapshot = snap
            self.burnRate = rate
            self.catState = state
            if abs(self.tempo - tempo) > 0.02 { self.tempo = tempo }
            if let reaction { self.reacted.send(reaction) }
            self.alertLevel = result.level
            self.sessionGauge = result.session
            self.weeklyGauge = result.weekly
            self.sessionMinutesLeft = result.sessionMinutesLeft
            self.sessionResetsAt = result.sessionResetsAt
            self.nextWeeklyReset = result.weeklyResetsAt ?? nextWeeklyReset
            self.weeklyBreakdown = breakdown
        }
    }

    // MARK: - 한도 알림 (§F4: 80%/95% 각 1회)

    private func fireLimitAlerts(snap: UsageStore.Snapshot, nextWeeklyReset: Date?, result: UsageEvaluator.Result) {
        // 창 식별자는 창이 유지되는 동안 바뀌지 않는 값이어야 한다.
        // now-7d처럼 매 틱 바뀌거나 조회마다 흔들리는 값을 그대로 쓰면 추적기가 리셋돼 알림이 다시 나간다.
        let sessionWindow = result.sessionResetsAt.map(LimitAlertTracker.windowId(resetsAt:))
            ?? snap.currentBlock.map { "\($0.start.timeIntervalSince1970)" } ?? "none"
        let weeklyWindow = (result.weeklyResetsAt ?? nextWeeklyReset).map(LimitAlertTracker.windowId(resetsAt:))
            ?? "rolling"

        if let session = result.session {
            for threshold in alertTracker.alertsToFire(kind: .session, percent: session.percent,
                                                       windowId: sessionWindow) {
                notify(threshold: threshold, kind: "세션",
                       remaining: result.sessionMinutesLeft.map { "현재 속도로 약 \(Format.minutes($0)) 뒤 한도에 닿습니다." })
            }
        }
        if let weekly = result.weekly {
            for threshold in alertTracker.alertsToFire(kind: .weekly, percent: weekly.percent,
                                                       windowId: weeklyWindow) {
                notify(threshold: threshold, kind: "주간", remaining: nil)
            }
        }
        // 리셋 시각을 모를 때의 고정 ID는 저장하면 다음 창에서도 알림이 막힌다
        UserDefaults.standard.set(alertTracker.saved.filter { !$0.value.hasPrefix("rolling|") && !$0.value.hasPrefix("none|") },
                                  forKey: Self.limitAlertsKey)
    }

    private func notify(threshold: LimitAlertTracker.Threshold, kind: String, remaining: String?) {
        let title = "\(kind) 사용량 \(threshold.rawValue)%"
        let body = remaining ?? "Claude Code에서 /usage로 남은 양을 확인할 수 있습니다."
        DispatchQueue.main.async { Notifier.shared.send(title: title, body: body) }
    }

    /// 5시간 블록 리셋 감지 → "새 세션 시작!" (옵션, 기본 off).
    private func checkNewBlock(snap: UsageStore.Snapshot, enabled: Bool) {
        let start = snap.currentBlock?.start
        defer { lastBlockStart = start ?? lastBlockStart }
        guard enabled, let start, let previous = lastBlockStart, start != previous else { return }
        DispatchQueue.main.async {
            Notifier.shared.send(title: "세션 초기화", body: "5시간 사용량이 초기화되었습니다.")
        }
    }

    /// 공식 주간 창이 다음 창으로 넘어가면 "주간 초기화" (옵션, 기본 off).
    /// resets_at은 조회마다 흔들리고 계정을 바꾸면 기준이 옮겨 가서, 거의 정확히 7일 뒤로 넘어갈 때만 새 창으로 본다.
    private func checkWeeklyReset(_ next: Date?, enabled: Bool) {
        guard let next else { return }
        defer { lastWeeklyReset = next }
        guard enabled, let previous = lastWeeklyReset,
              abs(next.timeIntervalSince(previous) - WeeklyWindow.duration) < 12 * 3600 else { return }
        DispatchQueue.main.async {
            Notifier.shared.send(title: "주간 초기화", body: "주간 사용량이 초기화되었습니다.")
        }
    }

    // MARK: - 주간 요약

    private static let summaryBoundaryKey = "weeklySummaryBoundary"

    /// 새 주가 시작된 뒤 처음 보는 틱에 지난 7일을 한 번 요약해 알린다. 처음 설치한 주에는 기준만 잡는다.
    /// 공식 연동을 켜고 끄면 주의 경계가 공식 리셋과 월요일 사이를 오가 한 번 더 알릴 수 있다.
    private func checkWeeklySummary(nextReset: Date?, now: Date, enabled: Bool) {
        let boundary = WeeklyWindow.currentStart(nextReset: nextReset, now: now)
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Self.summaryBoundaryKey)
        guard stored == 0 || boundary.timeIntervalSince1970 > stored + 3600 else { return }
        defaults.set(boundary.timeIntervalSince1970, forKey: Self.summaryBoundaryKey)
        // 처음이거나, 잠자기·꺼짐으로 이틀 넘게 지난 주의 요약은 보내지 않는다
        guard stored != 0, enabled, now.timeIntervalSince(boundary) < 2 * 24 * 3600 else { return }
        let summary = store.summary(from: boundary.addingTimeInterval(-WeeklyWindow.duration), to: boundary)
        guard summary.tokens > 0 else { return }
        let body = Self.describe(summary)
        DispatchQueue.main.async { Notifier.shared.send(title: "지난주 Claude 사용 요약", body: body, opens: .daily) }
    }

    static func describe(_ summary: UsageStore.PeriodSummary) -> String {
        var parts = ["\(Format.tokens(summary.tokens)) 토큰", "약 \(Format.usd(summary.costUSD))"]
        if let day = summary.busiestDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "EEEE"
            parts.append("가장 많이 쓴 날 \(formatter.string(from: day))")
        }
        if let project = summary.topProject {
            parts.append("\(project) \(Int((summary.topProjectShare * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 공식 % 폴링 (180초)

    /// 조회를 시작했거나 이미 진행 중이면(결과가 곧 온다) true, 백오프·스로틀로 건너뛰면 false.
    @discardableResult
    private func fetchOfficial(minInterval: TimeInterval) -> Bool {
        guard config.officialEnabled else {
            publishOfficial(nil, status: .disabled)
            return false
        }
        let now = Date()
        // 키체인 프롬프트가 응답을 기다리는 동안 다음 폴링이 겹치지 않게 한다.
        guard !officialInFlight else { return true }
        if let until = officialBackoffUntil, now < until { return false }
        if minInterval > 0, let last = lastOfficialAttempt, now.timeIntervalSince(last) < minInterval { return false }
        lastOfficialAttempt = now
        officialInFlight = true

        let version = clientVersion
        Task { [weak self] in
            guard let self else { return }
            let result: Result<OfficialUsage, Error>
            do {
                result = .success(try await self.provider.fetch(clientVersion: version))
            } catch {
                result = .failure(error)
            }
            self.workQueue.async { self.handleOfficial(result) }
        }
        return true
    }

    private func handleOfficial(_ result: Result<OfficialUsage, Error>) {
        officialInFlight = false
        officialAnswered = true
        switch result {
        case .success(let usage):
            officialBackoffUntil = nil
            if !lastOfficialFailure.isEmpty { Diagnostics.record("사용량", "공식 조회 다시 됨") }
            lastOfficialFailure = ""
            log.info("공식 조회 성공: 세션 \(usage.sessionPercent ?? -1)% 주간 \(usage.weeklyPercent ?? -1)%")
            // 응답을 기다리는 사이 연동을 끈 경우
            guard config.officialEnabled else { return }
            if let window = usage.sessionWindow { sessionTrend.record(window) }
            officialValue = usage
            // 게이지를 먼저 내보낸다. 상태가 먼저 .live가 되면 팝오버에 "공식 값 없음"이 잠깐 보인다.
            tick()
            publishOfficial(usage, status: .live)
        case .failure(let error):
            // 실패해도 앱은 죽지 않는다 (§8). 유예 시간 동안은 직전 값, 그 뒤로는 게이지를 비운다.
            if case OAuthUsageProvider.ProviderError.http(429) = error {
                officialBackoffUntil = Date().addingTimeInterval(Self.rateLimitBackoff)
            }
            let reason = Self.describe(error)
            // 실패가 이어지는 동안은 까닭이 바뀔 때만 남긴다
            if reason != lastOfficialFailure { Diagnostics.record("사용량", "공식 조회 실패: \(reason)") }
            lastOfficialFailure = reason
            log.error("공식 조회 실패(\(reason, privacy: .public)): \(String(describing: error))")
            guard config.officialEnabled else { return }
            if let current = officialValue, Date().timeIntervalSince(current.fetchedAt) < Self.officialGrace {
                publishOfficial(current, status: .stale(reason: reason))
            } else {
                officialValue = nil
                publishOfficial(nil, status: .failed(reason: reason))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let error as OAuthUsageProvider.ProviderError:
            switch error {
            case .tokenNotFound: return "로그인 정보 없음"
            case .http(401), .http(403): return "인증 만료"
            case .http(429): return "요청 제한, 10분 뒤 재시도"
            case .http(let code): return "HTTP \(code)"
            case .badResponse: return "응답 형식이 바뀜"
            }
        case is URLError:
            return "네트워크 오류"
        default:
            return "알 수 없는 오류"
        }
    }
}

/// 상태는 workQueue 전용과 메인 스레드 전용으로 나뉘어 있고, 큐를 건널 때는 항상 async/sync로 넘긴다.
extension UsageEngine: @unchecked Sendable {}
