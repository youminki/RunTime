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
    var openWorkLog: () -> Void = {}
    var openDesign: () -> Void = {}
    /// 팝오버를 닫고 같은 화면을 창으로 띄운다. 창 안에서는 비워 두어 단추를 숨긴다.
    var openAsWindow: (() -> Void)?
    /// 팝오버에서 앱 창의 러너 화면을 연다.
    var openRunners: (() -> Void)?
    /// 무대에서 러너를 누르거나 메뉴에서 동작을 고르면 메뉴바 러너도 같은 동작을 한다.
    var performTrick: (Trick) -> Void = { _ in }
    /// 화면 점검에서 러너·꾸미기 화면을 바로 띄울 때.
    var startSection: PopoverPage.Section?
    /// 화면 점검 도구가 무대를 게임 중(키 입력과 기록 없이)이나 난이도 판을 연 채로 찍을 때.
    var stageRehearsal: StageAction.Kind?
    /// 팝오버인지, 앱 창의 어느 화면인지. 창에서는 사용량과 러너(게임·꾸미기)를 따로 크게 보인다.
    var layout: Layout = .popover

    enum Layout { case popover, usagePage, runnersPage }

    /// 앱 창의 화면은 메뉴바 창보다 넓어 작은 글자를 한 단계 키운다.
    private var labelFont: Font { layout == .popover ? Theme.label : .system(size: 12.5, weight: .medium) }
    private var captionFont: Font { layout == .popover ? Theme.caption : .system(size: 12.5) }

    private var windowed: Bool { layout != .popover }

    @StateObject private var sparklineHover = HoverIndex()
    @StateObject private var page = PopoverPage()
    @ObservedObject private var customRunners = CustomRunnerStore.shared
    @ObservedObject private var petdex = PetdexStore.shared
    @ObservedObject private var design = DesignSync.shared
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var switcher = AccountSwitcher.shared

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
            case .runnersPage: runnersPage
            }
        }
        .background(Theme.background)
        .onAppear {
            if let startSection {
                page.section = startSection
                page.showsRunners = true
            }
            if let stageRehearsal { DispatchQueue.main.async { page.stageAction = StageAction(kind: stageRehearsal) } }
        }
    }

    private var stage: some View { stage(height: RunnerStage.height) }

    /// 무대. 앱 창에서는 `height`만큼 키우고, 폭은 놓인 자리가 정한다.
    private func stage(height: CGFloat) -> some View {
        RunnerStage(display: display, character: settings.character, theme: settings.spriteTheme,
                    onPet: performTrick,
                    trickRequest: page.trick,
                    stageAction: page.stageAction,
                    claudeFinished: engine.turnEnded.eraseToAnyPublisher(), tempo: engine.tempo,
                    reactions: engine.reacted.eraseToAnyPublisher(), height: height)
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
    /// 무대와 게임은 러너 화면으로 떼어 숫자만 차분히 보이게 한다.
    private var usagePage: some View {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 화면 이름은 창 위 막대에 있어, 여기는 어느 계정 값인지와 언제 받았는지, 새로고침만 한 줄에 둔다
                HStack(alignment: .center, spacing: 12) {
                    accountLine
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText).font(captionFont).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    Button { engine.refreshNow(forceOfficial: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(ToolbarButtonStyle())
                        .keyboardShortcut("r")
                        .tip("새로고침 (⌘R)")
                        .accessibilityLabel("새로고침")
                }
                .frame(minHeight: 28)
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

    /// 창 무대의 가로세로 비율. 평소와 게임 중이 같아 게임을 켜도 무대가 움직이지 않고, 창 크기가 달라도 장면 폭이 같다.
    /// 장면 폭(높이 150 기준 540)이 장애물을 미리 까는 거리(러너 x 44 + lookAhead 520)보다 좁아야
    /// 장애물이 화면 안에서 갑자기 생기지 않는다.
    static let windowStageRatio: CGFloat = 3.6
    /// 무대 아래 탭에 남길 높이. 아주 넓은 창에서는 무대 높이가 여기서 멈추고 폭은 그대로 창을 채운다.
    private static let minHubHeight: CGFloat = 320

    /// 창의 러너 화면: 위에 고정 비율 무대, 아래에 펫·꾸미기 탭. 게임은 무대 안에서 고르고 하며, 그동안에도 탭은 그대로 둔다.
    private var runnersPage: some View {
        GeometryReader { geo in
            let full = geo.size.width - Self.pagePadding.width * 2
            let room = geo.size.height - Self.pagePadding.height * 2
            let height = max(RunnerStage.height, min(full / Self.windowStageRatio, room - Self.minHubHeight))
            VStack(spacing: Self.columnGap) {
                stage(height: height)
                runnerPage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, Self.pagePadding.width)
            .padding(.vertical, Self.pagePadding.height)
        }
    }

    private static let pagePadding = CGSize(width: 24, height: 18)
    private static let columnGap: CGFloat = 12

    @ViewBuilder
    private var usageContent: some View {
        usageCards
        footer.padding(.top, 10)
    }

    /// 게이지가 어느 계정 값인지. 기억한 계정이 둘 이상이면 여기서 바로 바꾼다.
    @ViewBuilder
    private var accountLine: some View {
        if let account = engine.account {
            let plan = account.organizationType.map(AccountSwitcher.Account.planName)
            let others = switcher.accounts.filter { $0.id != account.uuid }
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle").foregroundStyle(Theme.tertiary)
                Text(account.email).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                if let plan { Text(plan).foregroundStyle(Theme.tertiary) }
                if switcher.switching { ProgressView().controlSize(.mini) }
                if !windowed { Spacer(minLength: 4) }
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { other in
                            Button(other.label + Self.usageSuffix(other.lastUsage)) { switcher.switchTo(other.id) }
                                .disabled(other.needsLogin == true)
                        }
                    } label: {
                        if windowed {
                            HStack(spacing: 3) {
                                Text("계정 바꾸기")
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().fill(Theme.surface))
                            .overlay(Capsule().strokeBorder(Theme.hairline))
                        } else {
                            Text("계정 바꾸기").foregroundStyle(Theme.tertiary)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(switcher.switching)
                    .tip("기억한 다른 Claude 계정으로 바꿉니다")
                }
            }
            .font(captionFont)
            .padding(.top, windowed ? 0 : 10)
            .tip("지금 Claude Code에 로그인한 계정. 사용률은 이 계정 기준입니다")
        }
    }

    /// 메뉴 항목 옆 마지막 사용률. 리셋이 지난 창은 0%로 본다.
    static func usageSuffix(_ usage: ClaudeLogin.LastUsage?) -> String {
        guard let usage else { return "" }
        let now = Date()
        func value(_ pct: Double?, _ reset: Date?) -> String {
            guard let pct else { return "-" }
            if let reset, reset <= now { return "0%" }
            return "\(Int(pct))%"
        }
        return "  세션 \(value(usage.sessionPercent, usage.sessionResetsAt)) · 주간 \(value(usage.weeklyPercent, usage.weeklyResetsAt))"
    }

    @ViewBuilder
    private var usageCards: some View {
        // 창에서는 화면 맨 위 줄에 따로 둔다
        if !windowed { accountLine }
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
                .font(labelFont)
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
                .font(labelFont)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(page.showsRunners ? "사용량으로 돌아가기" : "러너 바꾸기·꾸미기")
            }
            Spacer(minLength: 8)
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

    private func play(_ trick: Trick) {
        page.trick = TrickRequest(trick: trick)
        performTrick(trick)
    }

    // MARK: 러너 고르기

    /// 팝오버는 펫 고르기만, 앱 창은 펫·꾸미기·게임 탭을 둔다. 무대는 위에 그대로 두어 고른 것이 바로 보인다.
    @ViewBuilder
    private var runnerPage: some View {
        if windowed {
            // 머리줄은 탭마다 같은 것을 같은 자리에 두고, 탭 내용은 왼쪽 고정 폭 칸과 오른쪽 넓은 칸으로 나눈다
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    hubTabs.frame(width: RunnerHubLayout.sideWidth)
                    Spacer(minLength: 8)
                    stageCaption.fixedSize()
                    petActions
                }
                Group {
                    switch page.section {
                    case .pets:
                        RunnerPicker(settings: settings, importInPlace: importRunner, gameStyle: true, large: true)
                    case .decor:
                        RunnerDecorView(settings: settings, large: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            popoverRunnerPage
        }
    }

    private var popoverRunnerPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            SlimScrollView {
                RunnerPicker(settings: settings, importInPlace: importRunner, gameStyle: true, large: false)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
            }
            // 사용량 화면과 높이를 맞춰 전환할 때 출렁이지 않게 고정한다
            .frame(height: 304)
            HStack(spacing: 6) {
                Button { page.showsRunners = false } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                        Text("사용량")
                    }
                }
                .buttonStyle(GameButtonStyle(height: 24))
                .keyboardShortcut(.cancelAction)
                Spacer()
                if let openRunners {
                    Button(action: openRunners) { Text("꾸미기·기록") }
                        .buttonStyle(GameButtonStyle(height: 24))
                        .tip("앱 창에서 배경, 효과, 코스 기록 보기")
                }
                petActions
            }
            .padding(.bottom, 2)
        }
    }

    /// 자주 찾는 두 가지: Petdex에서 펫 받기, 펫을 화면에 꺼내기. 창에서는 글과 함께 크게, 팝오버에서는 짧게 둔다.
    private var petActions: some View {
        let height: CGFloat = windowed ? 30 : 24
        let size: CGFloat = windowed ? 13 : 12
        return HStack(spacing: 8) {
            Button { PetdexWindow.shared.show(settings: settings) } label: {
                Label(windowed ? "Petdex에서 펫 찾기" : "Petdex", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(GameButtonStyle(height: height, fontSize: size))
            .tip("petdex.dev에 올라온 펫 수천 개 중에서 골라 받아요")
            Button { DesktopPet.shared.toggle() } label: {
                Label(settings.desktopPet ? "펫 넣기" : (windowed ? "화면에 펫 꺼내기" : "꺼내기"),
                      systemImage: settings.desktopPet ? "tray.and.arrow.down.fill" : "macwindow.on.rectangle")
            }
            .buttonStyle(GameButtonStyle(height: height, fontSize: size))
            .tip(settings.desktopPet ? "화면에 꺼내 둔 펫을 넣어요"
                 : "펫이 화면 가장자리를 돌아다녀요. 끌어다 놓으면 그 자리에 머물고, 오른쪽 클릭하면 크기를 바꾸거나 앱 화면으로 바로 가요")
        }
        .fixedSize()
    }

    /// 펫·꾸미기·게임 탭. 폭을 똑같이 나눠 어디서든 같은 자리에서 누른다. 아래 왼쪽 칸과 폭이 같다.
    private var hubTabs: some View {
        HStack(spacing: 2) {
            ForEach(PopoverPage.Section.allCases, id: \.self) { section in
                let on = page.section == section
                Button { page.section = section } label: {
                    HStack(spacing: 5) {
                        Image(systemName: section.icon).font(.system(size: 13, weight: .semibold))
                        Text(section.title).font(.system(size: 14, weight: on ? .bold : .medium))
                    }
                    .foregroundStyle(on ? Theme.primary : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(on ? 0.14 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GameKit.slot))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
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
                Text(window).font(captionFont).foregroundStyle(Theme.tertiary)
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
                Text("최근 30분").font(labelFont).foregroundStyle(Theme.secondary)
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
            .font(.system(size: layout == .popover ? 9.5 : 11.5))
            .foregroundStyle(layout == .popover ? Theme.tertiary : Theme.secondary)
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
                .font(captionFont)
                .foregroundStyle(Theme.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip("설정 열기")
            Spacer(minLength: 8)
            if let openAsWindow {
                Button(action: openAsWindow) { Image(systemName: "macwindow") }
                    .tip("앱 창에서 열기: 날짜별 사용량, 러너, 업무 일지, 디자인을 한 창에서 오갑니다")
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
            .font(captionFont.monospacedDigit())
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
    /// 러너 화면의 갈래. 펫(만들기·고르기), 꾸미기(배경·꼬리·발먼지·부딪힘). 게임은 무대 오른쪽 위에서 고른다.
    enum Section: CaseIterable {
        case pets, decor

        var title: String {
            switch self {
            case .pets: "펫"
            case .decor: "꾸미기"
            }
        }

        var icon: String {
            switch self {
            case .pets: "pawprint.fill"
            case .decor: "sparkles"
            }
        }
    }

    @Published var showsRunners = false
    @Published var section: Section = .pets
    @Published var trick: TrickRequest?
    /// 펫 카드에서 누른 간식 주기·포토카드. 무대가 받아 그 자리에서 한다.
    @Published var stageAction: StageAction?
}

