import SwiftUI
import UsageCore

/// 러너 클릭 시 팝오버 (§F3). 맨 위는 러너가 달리는 무대, 아래는 세션·주간·속도·오늘.
/// 게이지 % = 공식 엔드포인트, 토큰량·속도·스파크라인 = 로컬 JSONL.
struct PopoverView: View {
    @ObservedObject var engine: UsageEngine
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void = {}
    /// 설정 창의 러너 구역을 연다 (Petdex 받기·그림 불러오기).
    var openRunnerSettings: () -> Void = {}
    var openDailyDetail: () -> Void = {}
    var openLeaderboard: () -> Void = {}
    /// 무대에서 러너를 누르거나 메뉴에서 동작을 고르면 메뉴바 러너도 같은 동작을 한다.
    var performTrick: (Trick) -> Void = { _ in }
    /// 화면 점검에서 러너·상점·퀘스트 화면을 바로 띄울 때.
    var startSection: PopoverPage.Section?

    @StateObject private var sparklineHover = HoverIndex()
    @StateObject private var page = PopoverPage()
    @ObservedObject private var customRunners = CustomRunnerStore.shared
    @ObservedObject private var petdex = PetdexStore.shared
    @ObservedObject private var wallet = GameWallet.shared

    private var customSelection: Binding<String?> {
        Binding(get: { settings.customRunnerID },
                set: { id in
                    if petdex.pet(storageID: id) != nil {
                        settings.customRunnerID = id
                    } else if let custom = customRunners.runner(id: id) {
                        settings.select(custom)
                    }
                })
    }

    /// 기본 러너, Petdex 펫, 내 러너를 통틀어 지금과 다른 러너 하나.
    private func pickRandomRunner() {
        let builtIns = Runner.allCases.filter { settings.customRunnerID != nil || $0 != settings.runner }
        let others = (petdex.pets.map { PetdexStore.storageID($0.slug) }
            + customRunners.runners.map(\.id)).filter { $0 != settings.customRunnerID }
        let index = Int.random(in: 0..<(builtIns.count + others.count))
        if index < builtIns.count {
            settings.select(builtIns[index])
        } else {
            customSelection.wrappedValue = others[index - builtIns.count]
        }
    }

    private var display: SpriteDisplay {
        SpriteDisplay(state: engine.catState, level: engine.alertLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RunnerStage(display: display, character: settings.character, theme: settings.spriteTheme,
                        onPet: performTrick, openLeaderboard: openLeaderboard, trickRequest: page.trick,
                        claudeFinished: engine.turnEnded.eraseToAnyPublisher(), tempo: engine.tempo,
                        reactions: engine.reacted.eraseToAnyPublisher())
            stageCaption.padding(.top, 10).padding(.horizontal, 2)
            if page.showsRunners {
                runnerPage.padding(.top, 10)
            } else {
                usageContent
            }
        }
        .padding(14)
        .frame(width: 376)
        .background(Theme.background)
        .onAppear {
            if let startSection {
                page.section = startSection
                page.showsRunners = true
            }
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        // 세션과 주간을 나란히 두어 두 값을 한눈에 견준다
        Card(padding: 0) {
            HStack(alignment: .top, spacing: 0) {
                sessionRow
                Rectangle().fill(Theme.hairline).frame(width: 1)
                weeklyRow
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
        Card(padding: 0) {
            VStack(spacing: 0) {
                activitySection.padding(12)
                Hairline()
                statColumns
            }
        }
        .padding(.top, 8)
        footer.padding(.top, 10)
    }

    // MARK: 무대 아래 한 줄

    private var stageCaption: some View {
        HStack(spacing: 8) {
            Button { page.showsRunners.toggle() } label: {
                HStack(spacing: 4) {
                    Text(settings.character.name).foregroundStyle(Theme.primary)
                    Text("·").foregroundStyle(Theme.tertiary)
                    Text(stateLabel).foregroundStyle(display == .alert ? Theme.critical : Theme.secondary)
                    Image(systemName: page.showsRunners ? "chevron.up" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }
                .font(Theme.label)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(page.showsRunners ? "사용량으로 돌아가기" : "러너 바꾸기")
            Spacer(minLength: 8)
            tricksMenu
        }
    }

    private var stateLabel: String {
        switch display {
        case .normal(let state): return state.label
        case .tired: return "지침"
        case .alert: return "한도 임박"
        }
    }

    /// 동작 해보기: 무대와 메뉴바 러너가 같은 동작을 한다.
    private var tricksMenu: some View {
        Menu {
            ForEach(Trick.allCases.filter { Trick.awake.contains($0) }, id: \.self) { trick in
                Button(trick.label) { play(trick) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold))
                Text("동작")
            }
            .font(Theme.label)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("동작")
        // 지쳤거나 한도 경고 중에는 메뉴바 러너가 그 모습을 유지해야 해서 동작을 받지 않는다
        .disabled(display == .tired || display == .alert)
        .help(display == .tired || display == .alert ? "한도에 가까워 쉬는 중이라 동작을 하지 않아요" : "동작 해보기")
    }

    private func play(_ trick: Trick) {
        page.trick = TrickRequest(trick: trick)
        performTrick(trick)
    }

    // MARK: 러너 고르기

    /// 러너 이름을 누르면 아래 사용량 대신 러너·상점·퀘스트 화면을 띄운다. 무대는 위에 그대로 두어 고른 러너와 꾸미기가 바로 보인다.
    private var runnerPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                hubTabs
                Spacer(minLength: 4)
                coinBalance
            }
            ScrollView {
                Group {
                    switch page.section {
                    case .runners: RunnerPicker(settings: settings, openFullPicker: openRunnerSettings)
                    case .shop: GameShopView(settings: settings)
                    case .quests: QuestView()
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }
            .frame(height: 304)   // 사용량 화면과 높이를 맞춰 전환할 때 팝오버가 출렁이지 않게
            HStack(spacing: 8) {
                Button { page.showsRunners = false } label: {
                    Label("사용량", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if page.section == .runners {
                    Picker("색상", selection: $settings.spriteTheme) {
                        ForEach(SpriteTheme.owned(current: settings.spriteTheme), id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button("아무거나", action: pickRandomRunner)
                }
            }
            .controlSize(.small)
        }
    }

    /// 러너·상점·퀘스트. 퀘스트에는 오늘 남은 미션 수를 붙인다.
    private var hubTabs: some View {
        HStack(spacing: 2) {
            ForEach(PopoverPage.Section.allCases, id: \.self) { section in
                let on = page.section == section
                Button { page.section = section } label: {
                    HStack(spacing: 4) {
                        Text(section.title)
                        if section == .quests, questsLeft > 0 {
                            Text("\(questsLeft)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.black.opacity(0.8))
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(GameShopView.gold))
                        }
                    }
                    .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.primary : Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(on ? Color.white.opacity(0.13) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section == .quests && questsLeft > 0
                    ? "\(section.title), \(wallet.pending.isEmpty ? "남은 미션" : "받을 보상") \(questsLeft)개" : section.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    /// 받을 보상이 있으면 그 수, 없으면 오늘 남은 미션 수.
    private var questsLeft: Int {
        if !wallet.pending.isEmpty { return wallet.pending.count }
        let daily = wallet.missions
        return daily.missions.count - daily.doneCount
    }

    private var coinBalance: some View {
        HStack(spacing: 3) {
            Image(systemName: "dollarsign.circle.fill")
            Text(wallet.coins.formatted()).contentTransition(.numericText())
        }
        .font(Theme.value)
        .foregroundStyle(GameShopView.gold)
        .animation(.easeOut(duration: 0.25), value: wallet.coins)
        .help("미니게임에서 먹은 코인과 퀘스트 보상. Claude가 일하는 동안 한 판은 두 배")
        .accessibilityLabel("코인 \(wallet.coins)개")
    }

    // MARK: 세션 · 주간

    private var sessionRow: some View {
        let gauge = engine.sessionGauge
        let elapsed = gauge == nil ? nil : elapsed(until: engine.sessionResetsAt, duration: BlockCalculator.blockDuration)
        let detail: String
        if gauge == nil {
            detail = unavailableNote
        } else if gauge?.source == .rolledOver {
            detail = "초기화됨 · 새 값 확인 중"
        } else if let reset = engine.sessionResetsAt {
            detail = Format.resetCountdown(until: reset)
        } else {
            detail = "사용하면 5시간 창 시작"
        }
        return limitRow(title: "세션", window: "5시간", gauge: gauge, elapsed: elapsed, detail: detail,
                        reachesLimit: sessionReachesLimit) { sessionOutlook }
            .help("이번 세션에 이 Mac의 Claude Code가 쓴 토큰: \(Format.tokens(engine.snapshot?.currentBlock?.totalTokens ?? 0))"
                  + elapsedNote(elapsed))
    }

    private var weeklyRow: some View {
        let gauge = engine.weeklyGauge
        let elapsed = gauge == nil ? nil : elapsed(until: engine.nextWeeklyReset, duration: WeeklyWindow.duration)
        let detail: String
        if gauge == nil {
            detail = unavailableNote
        } else if let reset = engine.nextWeeklyReset {
            detail = "\(Format.weekdayTime(reset)) 초기화"
        } else {
            detail = "사용하면 7일 창 시작"
        }
        return limitRow(title: "주간", window: "7일", gauge: gauge, elapsed: elapsed, detail: detail, reachesLimit: false) {
            if let shares = weeklyShares { caption(shares, color: Theme.tertiary) }
        }
        .help(elapsedNote(elapsed).trimmingCharacters(in: .newlines))
    }

    /// 한도 한 칸: 이름과 속도 배지, 큰 %, 시간 눈금이 있는 막대, 초기화 시각.
    private func limitRow<Extra: View>(title: String, window: String, gauge: GaugeReading?, elapsed: Double?,
                                       detail: String, reachesLimit: Bool,
                                       @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(window).font(Theme.caption).foregroundStyle(Theme.tertiary)
                Spacer(minLength: 2)
                paceBadge(gauge: gauge, elapsed: elapsed, reachesLimit: reachesLimit)
            }
            .frame(height: 18)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(gauge.map { "\($0.displayPercent)" } ?? "--")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("%").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(gauge == nil ? Theme.tertiary : gauge!.percent >= 80 ? Theme.ring(gauge!.percent) : Theme.primary)
            .animation(.easeOut(duration: 0.25), value: gauge?.displayPercent)
            .padding(.top, 4)
            GaugeBar(percent: gauge?.percent, elapsed: elapsed)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                caption(detail)
                extra()
            }
            .padding(.top, 7)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sessionOutlook: some View {
        if let gauge = engine.sessionGauge, gauge.percent < 100,
           let outlook = GaugeMath.limitOutlook(minutesLeft: engine.sessionMinutesLeft,
                                                resetsAt: engine.sessionResetsAt, now: Date()) {
            switch outlook {
            case .reachesLimit(let minutes):
                caption("약 \(Format.minutes(minutes)) 뒤 한도", color: gauge.percent >= 80 ? Theme.warning : Theme.tertiary)
            case .clearUntilReset:
                caption("초기화 전까지 여유", color: Theme.tertiary)
            }
        }
    }

    /// 최근 속도로는 초기화 전에 한도에 닿는지. 평균 페이스가 여유여도 배지를 빠름으로 올려 아래 문구와 맞춘다.
    private var sessionReachesLimit: Bool {
        guard case .reachesLimit = GaugeMath.limitOutlook(minutesLeft: engine.sessionMinutesLeft,
                                                         resetsAt: engine.sessionResetsAt, now: Date()) else { return false }
        return true
    }

    private func elapsedNote(_ elapsed: Double?) -> String {
        elapsed.map { "\n막대 위 눈금: 이번 창 시간의 \(Int(($0 * 100).rounded()))% 지남" } ?? ""
    }

    /// 시간 대비 속도 배지. 눈금을 읽지 않아도 지금 페이스가 보이게 한다.
    @ViewBuilder
    private func paceBadge(gauge: GaugeReading?, elapsed: Double?, reachesLimit: Bool) -> some View {
        if let gauge, gauge.source != .rolledOver, let elapsed {
            let pace = GaugeMath.pace(percent: gauge.percent, elapsed: elapsed)
            PaceBadge(pace: reachesLimit && (pace == .relaxed || pace == .steady) ? .fast : pace)
                .help("사용 \(gauge.displayPercent)% · 시간 \(Int((elapsed * 100).rounded()))% 지남"
                      + (reachesLimit ? "\n최근 속도로는 초기화 전에 한도에 닿습니다" : ""))
        }
    }

    /// 게이지를 비운 이유. 자세한 사유는 아래 상태 줄에 있다.
    private var unavailableNote: String {
        switch engine.officialStatus {
        case .waiting: return "공식 값 조회 중"
        case .disabled: return "공식 연동 꺼짐"
        case .failed: return "조회 실패"
        case .live, .stale: return "공식 값 없음"   // 응답에 이 창이 빠졌을 때
        }
    }

    /// 사용처가 둘 이상이면 공식 비중(Claude Code·채팅…), 아니면 이 기기의 모델 비중.
    private var weeklyShares: String? {
        let used = engine.weeklyBreakdown.filter { $0.percent >= 1 }.sorted { $0.percent > $1.percent }
        if used.count > 1 {
            return used.prefix(2).map { "\($0.name) \(Int($0.percent))%" }.joined(separator: " · ")
        }
        guard let modelTokens = engine.snapshot?.weeklyModelTokens, !modelTokens.isEmpty else { return nil }
        let total = modelTokens.values.reduce(0, +)
        guard total > 0 else { return nil }
        // 반올림해 0%가 되는 모델은 뺀다 ("Sonnet 0%"는 정보가 없다)
        return modelTokens.map { (Format.modelName($0.key), Int((Double($0.value) / Double(total) * 100).rounded())) }
            .filter { $0.1 >= 1 }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map { "\($0.0) \($0.1)%" }
            .joined(separator: " · ")
    }

    // MARK: 속도 · 오늘

    private var activitySection: some View {
        let values = engine.snapshot?.sparkline ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("최근 30분").font(Theme.label).foregroundStyle(Theme.secondary)
                Spacer()
                if let i = sparklineHover.index, values.indices.contains(i) {
                    let minutesAgo = values.count - 1 - i
                    caption("\(minutesAgo == 0 ? "지금" : "\(minutesAgo)분 전") \(Format.tokens(values[i]))/분",
                            color: Theme.primary)
                } else if let peak = values.max(), peak > 0 {
                    caption("최고 \(Format.tokens(peak))/분", color: Theme.tertiary)
                } else {
                    caption("쓴 기록 없음", color: Theme.tertiary)
                }
            }
            Sparkline(values: values, hoverIndex: $sparklineHover.index)
            HStack {
                Text("30분 전")
                Spacer()
                Text("지금")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.tertiary)
        }
    }

    /// 오늘 쓴 양, 예상 비용, 지금 속도. 모두 이 Mac의 Claude Code 기록 기준.
    private var statColumns: some View {
        let today = engine.snapshot?.todayTokens ?? 0
        let programmatic = engine.snapshot?.todayProgrammaticTokens ?? 0
        return HStack(spacing: 0) {
            StatColumn(label: programmatic > 0 ? "오늘 (SDK 포함)" : "오늘", value: Format.tokens(today), unit: "토큰")
                .help(programmatic > 0 ? "SDK 사용 \(Format.tokens(programmatic)) 토큰 포함 (별도 한도)" : "이 Mac의 Claude Code 기록 기준")
            Rectangle().fill(Theme.hairline).frame(width: 1)
            StatColumn(label: "추정 비용", value: Format.usd(engine.snapshot?.todayCostUSD ?? 0))
                .help("오늘 쓴 토큰을 API 단가로 환산한 참고값")
            Rectangle().fill(Theme.hairline).frame(width: 1)
            StatColumn(label: "지금 속도", value: engine.burnRate >= 1 ? Format.tokens(Int(engine.burnRate)) : "0", unit: "/분")
                .help("최근 1분 동안 쓴 토큰")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 상태 · 도구

    private var footer: some View {
        HStack(spacing: 2) {
            Button(action: openSettings) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(statusText).lineLimit(1)
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("설정 열기")
            Spacer(minLength: 8)
            Button(action: openDailyDetail) { Image(systemName: "chart.bar") }
                .help("일별 사용량")
                .accessibilityLabel("일별 사용량")
            Button { engine.refreshNow(forceOfficial: true) } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
                .help("새로고침 (⌘R)")
                .accessibilityLabel("새로고침")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .keyboardShortcut(",")
                .help("설정 (⌘,)")
                .accessibilityLabel("설정")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(ToolbarButtonStyle(tint: Theme.critical))
                .keyboardShortcut("q")
                .help("RunTime 종료 (⌘Q)")
                .accessibilityLabel("RunTime 종료")
        }
        .buttonStyle(ToolbarButtonStyle())
    }

    private var statusText: String {
        switch engine.officialStatus {
        case .live:
            guard let official = engine.official else { return "공식 사용량" }
            let age = Int(Date().timeIntervalSince(official.fetchedAt) / 60)
            return age < 1 ? "공식 사용량 · 방금 갱신" : "공식 사용량 · \(age)분 전 갱신"
        case .waiting: return "공식 사용량 조회 중"
        case .stale(let reason): return "직전 공식 값 · \(reason)"
        case .failed(let reason): return "조회 실패 · \(reason)"
        case .disabled: return "공식 연동 꺼짐"
        }
    }

    private var statusColor: Color {
        switch engine.officialStatus {
        case .live: return Theme.positive
        case .waiting, .disabled: return Theme.tertiary
        case .stale, .failed: return Theme.warning
        }
    }

    // MARK: 헬퍼

    private func elapsed(until resetsAt: Date?, duration: TimeInterval) -> Double? {
        resetsAt.map { GaugeMath.elapsedFraction(resetsAt: $0, duration: duration, now: Date()) }
    }

    private func caption(_ text: String, color: Color = Theme.secondary) -> some View {
        Text(text)
            .font(Theme.caption.monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// 스파크라인에서 마우스가 가리키는 분. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class HoverIndex: ObservableObject {
    @Published var index: Int?
}

/// 팝오버 안 화면과 무대에 보낼 동작. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class PopoverPage: ObservableObject {
    enum Section: CaseIterable {
        case runners, shop, quests

        var title: String {
            switch self {
            case .runners: "러너"
            case .shop: "상점"
            case .quests: "퀘스트"
            }
        }
    }

    @Published var showsRunners = false
    @Published var section: Section = .runners
    @Published var trick: TrickRequest?
}
