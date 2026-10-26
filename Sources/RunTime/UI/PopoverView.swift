import SwiftUI
import UsageCore

/// 러너 클릭 시 팝오버 (§F3). 맨 위는 러너가 달리는 무대, 아래는 세션·주간·속도·오늘.
/// 게이지 % = 공식 엔드포인트, 토큰량·속도·스파크라인 = 로컬 JSONL.
struct PopoverView: View {
    @ObservedObject var engine: UsageEngine
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void = {}
    /// 팝오버를 닫고 그림 파일을 골라 내 러너를 만든다 (팝오버 안에서는 파일 창을 띄울 수 없어서).
    var importRunner: () -> Void = {}
    var openDailyDetail: () -> Void = {}
    var openWorkLog: () -> Void = {}
    var openDesign: () -> Void = {}
    var openLeaderboard: () -> Void = {}
    /// 팝오버를 닫고 같은 화면을 창으로 띄운다. 창 안에서는 비워 두어 단추를 숨긴다.
    var openAsWindow: (() -> Void)?
    /// 무대에서 러너를 누르거나 메뉴에서 동작을 고르면 메뉴바 러너도 같은 동작을 한다.
    var performTrick: (Trick) -> Void = { _ in }
    /// 화면 점검에서 러너·상점·퀘스트 화면을 바로 띄울 때.
    var startSection: PopoverPage.Section?
    /// 팝오버인지, 앱 창의 어느 화면인지. 창에서는 사용량·게임·러너를 따로 크게 보인다.
    var layout: Layout = .popover

    enum Layout { case popover, usagePage, gamePage, runnersPage }

    private var windowed: Bool { layout != .popover }

    @StateObject private var sparklineHover = HoverIndex()
    @StateObject private var page = PopoverPage()
    @ObservedObject private var customRunners = CustomRunnerStore.shared
    @ObservedObject private var petdex = PetdexStore.shared
    @ObservedObject private var wallet = GameWallet.shared
    @ObservedObject private var design = DesignSync.shared
    @ObservedObject private var updater = AppUpdater.shared

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
        Group {
            switch layout {
            case .popover: narrowBody
            case .usagePage: usagePage
            case .gamePage: gamePage
            case .runnersPage: runnersPage
            }
        }
        .background(Theme.background)
        .onAppear {
            if let startSection {
                page.section = startSection
                page.showsRunners = true
            }
        }
    }

    private var stage: some View { stage(height: RunnerStage.height) }

    /// 무대. 앱 창에서는 `height`만큼 키우고, 폭은 장면 비율(348×150)대로 둔다.
    private func stage(height: CGFloat) -> some View {
        RunnerStage(display: display, character: settings.character, theme: settings.spriteTheme,
                    onPet: performTrick, openLeaderboard: openLeaderboard, trickRequest: page.trick,
                    claudeFinished: engine.turnEnded.eraseToAnyPublisher(), tempo: engine.tempo,
                    reactions: engine.reacted.eraseToAnyPublisher(), height: height)
            .frame(width: windowed ? height * Self.stageRatio : nil)
    }

    private var narrowBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            stage
            if let notes = updater.patchNotes {
                PatchNotesBubble(notes: notes) { withAnimation(.easeOut(duration: 0.18)) { updater.dismissPatchNotes() } }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
            stageCaption.padding(.top, 10).padding(.horizontal, 2)
            if page.showsRunners {
                runnerPage.padding(.top, 10)
            } else {
                usageContent
            }
        }
        .padding(14)
        .frame(width: 376)
    }

    /// 창의 사용량 화면: 위에 공식 값 상태, 세션·주간, 30분 그래프와 오늘 수치, 아래에 최근 8일 날짜별 사용량.
    /// 무대와 게임은 게임 화면으로 떼어 숫자만 차분히 보이게 한다.
    private var usagePage: some View {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 화면 이름은 창 위 막대에 있어, 여기는 공식 값을 언제 받았는지와 새로고침만 둔다
                HStack(alignment: .center) {
                    Text("이 Mac의 Claude Code와 공식 사용률").font(Theme.label).foregroundStyle(Theme.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText).font(Theme.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    Button { engine.refreshNow(forceOfficial: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(ToolbarButtonStyle())
                        .keyboardShortcut("r")
                        .tip("새로고침 (⌘R)")
                        .accessibilityLabel("새로고침")
                }
                usageCards
                Text("최근 8일").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                    .padding(.top, 28).padding(.bottom, 10)
                DailyDetailView(engine: engine)
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 창의 게임 화면: 왼쪽에 키운 무대와 조작법·내 기록, 오른쪽에 순위.
    private var gamePage: some View {
        HStack(alignment: .top, spacing: 28) {
            GeometryReader { geo in
                // 장면은 팝오버 무대와 같은 348×150으로 계산하고 비율을 지킨 채 키운다.
                // 장면 폭이 창마다 달라지면 장애물을 미리 보는 거리가 달라져 순위 점수가 공정하지 않다.
                // 2배보다 크게 키우면 픽셀 그림·효과 그림이 흐려지고 점수판 글자가 화면을 가려 그만큼에서 멈춘다
                let height = max(RunnerStage.height,
                                 min(geo.size.width / Self.stageRatio, geo.size.height - 190,
                                     RunnerStage.height * Self.maxStageZoom))
                VStack(alignment: .leading, spacing: 14) {
                    stage(height: height)
                    stageCaption
                    gameKeys
                    gameRecord
                }
                .frame(width: height * Self.stageRatio)
                // 무대를 다 키워도 남는 높이는 위아래로 나눠 가운데 둔다
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(Theme.hairline).frame(width: 1)
            LeaderboardView()
                .frame(width: 320)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    /// 팝오버 무대의 장면 크기 (팝오버 폭 376에서 안쪽 여백 14씩을 뺀 폭).
    static let stageScene = CGSize(width: 348, height: RunnerStage.height)
    static let stageRatio = stageScene.width / stageScene.height
    static let maxStageZoom: CGFloat = 2

    /// 게임 조작법. 무대 위 도움말을 읽지 않아도 보이게 키 모양으로 늘어놓고, 좁으면 다음 줄로 넘긴다.
    private var gameKeys: some View {
        FlowLayout(spacing: 8) {
            ForEach([("스페이스 · ↑", "점프 (길게 누르면 높이)"), ("↓", "숙이기"), ("← →", "이동"),
                     ("G", "고스트와 겨루기"), ("esc", "나가기")], id: \.0) { key, action in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
                    Text(action).font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                .fixedSize()
                .padding(.trailing, 8)
            }
        }
    }

    /// 이 Mac의 최고 점수, 판 수, 코인. 순위 서버에 참여하지 않아도 보인다.
    private var gameRecord: some View {
        Card(padding: 0) {
            HStack(spacing: 0) {
                StatColumn(label: "내 최고 점수", value: GameRecords.best.formatted())
                Rectangle().fill(Theme.hairline).frame(width: 1)
                StatColumn(label: "한 판 수", value: GameRecords.plays.formatted(), unit: "판")
                Rectangle().fill(Theme.hairline).frame(width: 1)
                StatColumn(label: "코인", value: wallet.coins.formatted())
                    .tip("러너 화면의 상점에서 꾸미기를 삽니다")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// 창의 러너 화면: 왼쪽에 무대(산 꾸미기를 바로 써 보게)와 퀘스트, 오른쪽에 러너·상점·창고.
    /// 무대를 장면 비율 그대로 두어 여기서 게임을 해도 팝오버·게임 화면과 같은 거리에서 장애물이 나온다.
    private var runnersPage: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                stage(height: Self.sideStageWidth / Self.stageRatio)
                stageCaption.padding(.top, 10).padding(.horizontal, 2)
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 14)
                ScrollView { QuestView().padding(.horizontal, 2).padding(.bottom, 4) }
            }
            .frame(width: Self.sideStageWidth)
            runnerPage
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if page.section == .quests { page.section = .runners } }
    }

    static let sideStageWidth: CGFloat = 400

    @ViewBuilder
    private var usageContent: some View {
        usageCards
        footer.padding(.top, 10)
    }

    @ViewBuilder
    private var usageCards: some View {
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
    }

    // MARK: 무대 아래 한 줄

    private var stageCaption: some View {
        HStack(spacing: 8) {
            if windowed {
                // 창에서는 러너 화면이 늘 펼쳐져 있어 이름은 누르는 단추가 아니다
                HStack(spacing: 4) {
                    Text(settings.character.name).foregroundStyle(Theme.primary)
                    Text("·").foregroundStyle(Theme.tertiary)
                    Text(stateLabel).foregroundStyle(display.isCritical ? Theme.critical : Theme.secondary)
                }
                .font(Theme.label)
            } else {
            Button { page.showsRunners.toggle() } label: {
                HStack(spacing: 4) {
                    Text(settings.character.name).foregroundStyle(Theme.primary)
                    Text("·").foregroundStyle(Theme.tertiary)
                    Text(stateLabel).foregroundStyle(display.isCritical ? Theme.critical : Theme.secondary)
                    Image(systemName: page.showsRunners ? "chevron.up" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }
                .font(Theme.label)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(page.showsRunners ? "사용량으로 돌아가기" : "러너 바꾸기")
            }
            Spacer(minLength: 8)
            tricksMenu
        }
    }

    private var stateLabel: String {
        switch display {
        case .normal(let state): return state.label
        case .tired: return "지침"
        case .alert: return "한도 임박"
        case .straining(let state, let critical): return "\(state.label) · \(critical ? "한도 임박" : "지침")"
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
                Image(systemName: "hand.tap").font(.system(size: 9.5, weight: .semibold))
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
        .disabled(display.isLimited)
        .tip(display.isLimited ? "한도에 가까워 경고를 보이는 중이라 동작을 하지 않아요" : "동작 해보기")
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
            SlimScrollView {
                Group {
                    switch page.section {
                    case .runners: RunnerPicker(settings: settings, importInPlace: importRunner, gameStyle: true)
                    case .shop: GameShopView(settings: settings)
                    case .storage: StorageView(settings: settings) { page.section = .shop }
                    case .quests: QuestView()
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }
            // 팝오버는 사용량 화면과 높이를 맞춰 전환할 때 출렁이지 않게 고정하고, 창에서는 남은 높이를 다 쓴다
            .frame(height: windowed ? nil : 304)
            .frame(maxHeight: windowed ? .infinity : nil)
            // 시스템 단추 대신 상점·창고와 같은 단추로 둔다
            HStack(spacing: 6) {
                if !windowed {
                    Button { page.showsRunners = false } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                            Text("사용량")
                        }
                    }
                    .buttonStyle(GameButtonStyle(kind: .plain, height: 22))
                    .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if page.section == .runners {
                    Menu {
                        Picker("색상", selection: $settings.spriteTheme) {
                            ForEach(SpriteTheme.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        // 메뉴는 단추 꼴을 시스템이 그려서 같은 모습을 이름표에 직접 칠한다
                        HStack(spacing: 4) {
                            Image(systemName: "paintpalette.fill").font(.system(size: 9.5))
                            Text(settings.spriteTheme.displayName)
                            Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.7)
                        }
                        .gameChip()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .tip("러너 색상")
                    Button(action: pickRandomRunner) {
                        HStack(spacing: 3) {
                            Image(systemName: "shuffle").font(.system(size: 9, weight: .bold))
                            Text("아무거나")
                        }
                    }
                    .buttonStyle(GameButtonStyle(kind: .plain, height: 22))
                    .tip("다른 러너 하나를 아무거나 고르기")
                }
            }
            .padding(.bottom, 2)
        }
    }

    /// 러너·상점·창고·퀘스트. 퀘스트에는 오늘 남은 미션 수를 붙인다.
    private var hubTabs: some View {
        HStack(spacing: 2) {
            ForEach(PopoverPage.Section.allCases.filter { !windowed || $0 != .quests }, id: \.self) { section in
                let on = page.section == section
                Button { page.section = section } label: {
                    HStack(spacing: 4) {
                        Text(section.title)
                        if section == .quests, questsLeft > 0 {
                            Text("\(questsLeft)")
                                .font(.system(size: 9, weight: .heavy).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(Circle().fill(wallet.pending.isEmpty ? Theme.critical : Theme.positive))
                        }
                    }
                    .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.primary : Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(on ? 0.14 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section == .quests && questsLeft > 0
                    ? "\(section.title), \(wallet.pending.isEmpty ? "남은 미션" : "받을 보상") \(questsLeft)개" : section.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(GameKit.slot))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    /// 받을 보상이 있으면 그 수, 없으면 오늘 남은 미션 수.
    private var questsLeft: Int {
        if !wallet.pending.isEmpty { return wallet.pending.count }
        let daily = wallet.missions
        return daily.missions.count - daily.doneCount
    }

    private var coinBalance: some View {
        HStack(spacing: 4) {
            CoinIcon(size: 15)
            Text(wallet.coins.formatted()).contentTransition(.numericText())
                .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(GameKit.gold)
        }
        .padding(.leading, 4).padding(.trailing, 9)
        .frame(height: 24)
        .background(Capsule().fill(GameKit.slot))
        .overlay(Capsule().strokeBorder(GameKit.gold.opacity(0.3)))
        .animation(.easeOut(duration: 0.25), value: wallet.coins)
        .tip("미니게임에서 먹은 코인과 퀘스트 보상. Claude가 일하는 동안 한 판은 두 배")
        .accessibilityElement(children: .ignore)
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
            .tip("이번 세션에 이 Mac의 Claude Code가 쓴 토큰: \(Format.tokens(engine.snapshot?.currentBlock?.totalTokens ?? 0))"
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
        .tip(elapsedNote(elapsed).trimmingCharacters(in: .newlines))
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
            // 아래 두 줄 자리를 늘 잡아 둔다. 공식 값을 받아 "Opus 100%" 같은 줄이 열린 뒤에 생기면
            // 팝오버가 위로 자라 위쪽 모니터 쪽으로 넘어가 잘린다
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) { caption(" "); caption(" ") }.hidden()
                VStack(alignment: .leading, spacing: 2) {
                    caption(detail)
                    extra()
                }
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
                .tip("사용 \(gauge.displayPercent)% · 시간 \(Int((elapsed * 100).rounded()))% 지남"
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
            Sparkline(values: values, hoverIndex: $sparklineHover.index, height: windowed ? 150 : 44)
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
                .tip(programmatic > 0 ? "SDK 사용 \(Format.tokens(programmatic)) 토큰 포함 (별도 한도)" : "이 Mac의 Claude Code 기록 기준")
            Rectangle().fill(Theme.hairline).frame(width: 1)
            StatColumn(label: "추정 비용", value: Format.usd(engine.snapshot?.todayCostUSD ?? 0))
                .tip("오늘 쓴 토큰을 API 단가로 환산한 참고값")
            Rectangle().fill(Theme.hairline).frame(width: 1)
            StatColumn(label: "지금 속도", value: engine.burnRate >= 1 ? Format.tokens(Int(engine.burnRate)) : "0", unit: "/분")
                .tip("최근 1분 동안 쓴 토큰")
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
            .tip("설정 열기")
            Spacer(minLength: 8)
            if let openAsWindow {
                Button(action: openAsWindow) { Image(systemName: "macwindow") }
                    .tip("앱 창에서 열기: 사용량·게임·업무 일지·디자인을 한 창에서 오갑니다")
                    .accessibilityLabel("창으로 보기")
            }
            Button(action: openWorkLog) { Image(systemName: "checklist") }
                .tip("업무 일지")
                .accessibilityLabel("업무 일지")
            Button(action: openDesign) {
                Image(systemName: "paintpalette")
                    // 완료된 시안에 확인하지 않은 변경이 있으면 업무 일지처럼 놓치지 않게 점을 붙인다
                    .overlay(alignment: .topTrailing) {
                        if design.unseenCount > 0 {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
            }
            .tip(design.unseenCount > 0 ? "디자인 변경 · 완료 후 변경 \(design.unseenCount)건" : "디자인 변경")
            .accessibilityLabel(design.unseenCount > 0 ? "디자인 변경, 확인 안 함 \(design.unseenCount)건" : "디자인 변경")
            Button(action: openDailyDetail) { Image(systemName: "chart.bar") }
                .tip("일별 사용량")
                .accessibilityLabel("일별 사용량")
            Button { engine.refreshNow(forceOfficial: true) } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
                .tip("새로고침 (⌘R)")
                .accessibilityLabel("새로고침")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .keyboardShortcut(",")
                .tip("설정 (⌘,)")
                .accessibilityLabel("설정")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(ToolbarButtonStyle(tint: Theme.critical))
                .keyboardShortcut("q")
                .tip("RunTime 종료 (⌘Q)")
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
        case runners, shop, storage, quests

        var title: String {
            switch self {
            case .runners: "러너"
            case .shop: "상점"
            case .storage: "창고"
            case .quests: "퀘스트"
            }
        }
    }

    @Published var showsRunners = false
    @Published var section: Section = .runners
    @Published var trick: TrickRequest?
}
