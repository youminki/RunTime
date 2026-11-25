import SwiftUI
import UsageCore

/// 설정 창. iOS 설정 앱처럼 색 아이콘 줄을 둥근 묶음으로 모으고, 설명은 묶음 아래 각주로 둔다.
/// 왼쪽 목록은 RunTime·도구·연동 세 묶음이고 모두 한 번 눌러 닿는다(안에 또 탭을 두지 않는다). 화면마다 제목 아래 한 줄 설명을 둔다.
/// 변경은 UserDefaults에 바로 저장되고 메뉴바와 팝오버에 바로 반영된다.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: UsageEngine
    /// 앱이 들고 있는 탭 상태. 다른 화면에서 특정 구역을 열 수 있게 바깥에서 받는다.
    @ObservedObject var tab: SettingsTabState
    /// 업무 일지 연동 칸(GitLab·레드마인…)은 업무 일지 화면과 같은 상태를 쓴다. 고른 칸도 거기 둔다.
    @ObservedObject var workLog: WorkLogPage
    /// 러너 고르기는 무대가 있는 러너 화면에서 한다.
    var openRunners: () -> Void = {}
    @ObservedObject private var workLogSettings = WorkLogSettings.shared
    @ObservedObject private var workLogSync = WorkLogSync.shared
    @ObservedObject private var permissionHook = PermissionHookFile.shared
    @ObservedObject private var design = DesignSyncSettings.shared

    enum Tab: Hashable { case general, runner, usage, accounts, alerts, windows, clipboard, workLog, figma }

    init(settings: AppSettings, engine: UsageEngine, tab: SettingsTabState, workLog: WorkLogPage, openRunners: @escaping () -> Void = {}) {
        self.openRunners = openRunners
        self.settings = settings
        self.engine = engine
        self.tab = tab
        self.workLog = workLog
    }

    var body: some View {
        // 창이 넓어 위 세그먼트 대신 왼쪽에 구역 목록을 두고, 설정 글은 읽기 좋은 너비로 가운데에 둔다
        HStack(spacing: 0) {
            SlimScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    navHeader("RunTime")
                    navRow(.general, "일반", icon: "gearshape.fill", tint: Palette.gray)
                    navRow(.runner, "러너", icon: "hare.fill", tint: Palette.orange)
                    navRow(.usage, "사용량", icon: "chart.bar.fill", tint: Palette.blue)
                    navRow(.accounts, "Claude 계정", icon: "person.crop.circle.fill", tint: Palette.blue)
                    navRow(.alerts, "알림", icon: "bell.fill", tint: Palette.red)
                    navHeader("도구").padding(.top, 14)
                    navRow(.windows, "창 배치", icon: "rectangle.split.2x1.fill", tint: Palette.teal)
                    navRow(.clipboard, "클립보드", icon: "doc.on.clipboard.fill", tint: Palette.teal)
                    navHeader("연동").padding(.top, 14)
                    ForEach(WorkLogPage.SettingsSection.allCases, id: \.self) { section in
                        workLogRow(section)
                    }
                    navRow(.figma, "피그마", icon: "paintpalette.fill", tint: Palette.purple,
                           dot: design.hasToken && !design.sources.isEmpty ? WL.done : .clear)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .frame(width: 220)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.groupedRow.opacity(0.5))
            Rectangle().fill(WL.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                    Text(summary)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 2)
                switch tab.selection {
                case .general: general
                case .runner: runner
                case .usage: usage
                case .accounts: GroupedList { AccountSection(switcher: AccountSwitcher.shared, engine: engine) }
                case .alerts: alerts
                case .windows: WindowLayoutSettingsView(layout: .shared)
                case .clipboard: ClipboardSettingsView(clipboard: .shared)
                case .workLog:
                    WorkLogSettingsView(settings: workLogSettings, sync: workLogSync, page: workLog, store: .shared)
                        .padding(.leading, -12)
                case .figma:
                    DesignSettingsView(sync: .shared, settings: .shared)
                        .padding(.leading, -12)
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background([.workLog, .figma].contains(tab.selection) ? WL.canvas : Palette.groupedBackground)
        }
        .background(Palette.groupedBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch tab.selection {
        case .general: return "일반"
        case .runner: return "러너"
        case .usage: return "사용량"
        case .accounts: return "Claude 계정"
        case .alerts: return "알림"
        case .windows: return "창 배치"
        case .clipboard: return "클립보드"
        case .workLog: return workLog.settingsSection.rawValue
        case .figma: return "피그마"
        }
    }

    /// 제목 아래 한 줄.
    private var summary: String {
        switch tab.selection {
        case .general: return "켤 때와 메뉴바 표시, 업데이트, 문제 기록."
        case .runner: return "메뉴바에서 달리는 러너의 모습과 화면에 꺼낸 펫."
        case .usage: return "Claude 사용률을 받는 방법과 러너가 달리는 빠르기."
        case .accounts: return "Claude Code에 로그인했던 계정을 바꾸거나 지웁니다."
        case .alerts: return "RunTime이 보내는 알림을 한곳에서 켜고 끕니다."
        case .windows: return "앞에 있는 창을 단축키나 끌기로 절반·모서리에 놓습니다."
        case .clipboard: return "복사한 것을 쌓아 두고 골라 붙입니다."
        case .workLog: return WorkLogSettingsView.note(workLog.settingsSection)
        case .figma: return "피그마 화면설계서를 가져와 바뀐 화면을 날짜별로 남기고, 맡은 메뉴가 바뀌면 알립니다."
        }
    }

    private func navHeader(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 2)
    }

    /// 업무 일지 연동 칸. 고른 칸은 업무 일지 화면과 같은 상태(WorkLogPage)에 두어, 업무 일지·레드마인 화면의 "연결" 단추가 바로 그 칸을 연다.
    private func workLogRow(_ section: WorkLogPage.SettingsSection) -> some View {
        let on = tab.selection == .workLog && workLog.settingsSection == section
        let dot = WorkLogSettingsView.dot(section, settings: workLogSettings, sync: workLogSync, store: .shared)
        return navItem(section.rawValue, icon: section.icon, tint: section.tint, dot: dot, on: on) {
            workLog.settingsSection = section
            tab.selection = .workLog
        }
    }

    /// 왼쪽 목록 한 줄. 연동 칸은 오른쪽 점으로 켜짐(초록)·확인 필요(주황)를 보인다.
    private func navRow(_ value: Tab, _ title: String, icon: String, tint: Color, dot: Color = .clear) -> some View {
        navItem(title, icon: icon, tint: tint, dot: dot, on: tab.selection == value) { tab.selection = value }
    }

    private func navItem(_ title: String, icon: String, tint: Color, dot: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint))
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: 일반

    private var general: some View {
        GroupedList {
            GroupedSection("시작과 메뉴바", footer: "사용률 표시를 켜면 러너 옆에 숫자를 함께 보입니다.") {
                ToggleRow(title: "로그인 시 자동 시작", icon: "power", isOn: $settings.launchAtLogin)
                    .disabled(!LaunchAtLogin.available)
                ToggleRow(title: "메뉴바에 사용률 표시", icon: "percent", isOn: $settings.showsMenuBarLabel)
                if settings.showsMenuBarLabel {
                    GroupedRow("표시할 값", icon: "textformat.123") {
                        segmented("표시할 값", $settings.menuBarLabel, MenuBarLabel.allCases.filter { $0 != .off }) { $0.displayName }
                    }
                }
            }
            if !LaunchAtLogin.available { devOnlyNote("자동 시작") }

            GroupedSection("업데이트", footer: "설치한 폴더에서 다시 빌드합니다. 1~2분 동안 러너가 잠깐 사라졌다가 돌아옵니다. 자동 업데이트를 켜면 묻지 않고 설치합니다.") {
                UpdateRows(updater: AppUpdater.shared)
            }

            GroupedSection("문제 기록", footer: "실패하거나 멈춘 일을 이 Mac에 적어 둡니다. 만든 사람에게 알리기를 켜면 설치 ID, 버전, 실패한 자리와 까닭만 보내고 키·토큰·일지 내용은 보내지 않습니다.") {
                DiagnosticsRows(usage: { officialStatusText })
            }

            GroupedSection("정보", footer: "RunTime은 Anthropic과 관계없는 개인 프로젝트입니다.") {
                GroupedRow("버전", icon: "info.circle") {
                    Text(Self.versionText).foregroundStyle(.secondary)
                }
                GroupedRow("Claude Code 기록 폴더", icon: "folder") {
                    Button("열기") { NSWorkspace.shared.open(Self.projectsDirectory) }
                        .controlSize(.small)
                }
                .tip(Self.projectsDirectory.path)
                Link(destination: URL(string: "https://github.com/youminki/RunTime")!) {
                    GroupedRow("GitHub 저장소", icon: "chevron.left.forwardslash.chevron.right") {
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 러너

    private var runner: some View {
        GroupedList {
            runnerHero

            GroupedSection("모습", footer: "'크게'는 머리 위 여백을 줄여 캐릭터를 키웁니다. 움직임은 1초에 그리는 그림 수로, 많을수록 매끄럽지만 CPU를 조금 더 씁니다.") {
                GroupedRow("메뉴바 크기", icon: "textformat.size") {
                    segmented("메뉴바 크기", $settings.runnerSize, RunnerSize.allCases) { $0.displayName }
                }
                GroupedRow("색상", icon: "paintpalette.fill") {
                    menu("색상", $settings.spriteTheme, SpriteTheme.allCases) { $0.displayName }
                }
                GroupedRow("움직임", icon: "film.stack") {
                    segmented("움직임", $settings.smoothness, SpriteSmoothness.allCases) { $0.displayName }
                }
                ToggleRow(title: "가끔 혼자 장난치기", icon: "hand.wave.fill", isOn: $settings.tricksEnabled)
            }

            GroupedSection("화면에 꺼낸 펫", footer: "펫을 끌어다 놓으면 그 자리에 머뭅니다. ⌃⌥+방향키로 움직이고 ⌃⌥+스페이스로 뜁니다(다른 앱이 쓰는 키면 ⌃⌥⇧). 오른쪽 클릭으로 앱의 각 화면을 바로 엽니다.") {
                ToggleRow(title: "펫을 화면에 꺼내 두기", icon: "macwindow.on.rectangle",
                          isOn: Binding(get: { settings.desktopPet },
                                        set: { $0 ? DesktopPet.shared.show() : DesktopPet.shared.hide() }))
                // 꺼내 두지 않았을 때 바꿔도 보이는 것이 없어 흐리게 둔다
                Group {
                    GroupedRow("펫 크기", icon: "arrow.up.left.and.arrow.down.right") {
                        HStack(spacing: 8) {
                            Slider(value: $settings.desktopPetSize, in: 0.6...2).frame(width: 160)
                            Text("\(Int((settings.desktopPetSize * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    GroupedRow("움직이는 방식", icon: "figure.walk") {
                        menu("움직이는 방식", Binding(get: { settings.desktopPetMode },
                                             set: { DesktopPet.shared.setMode($0) ; settings.desktopPetMode = $0 }),
                             DesktopPet.Mode.allCases) { $0.title }
                    }
                }
                .disabled(!settings.desktopPet)
                .opacity(settings.desktopPet ? 1 : 0.5)
            }

            PetMakerStorageSection()
        }
    }

    /// 지금 고른 러너를 크게 보여 주는 머리 카드 (iOS 설정 앱 맨 위 계정 카드 자리).
    private var runnerHero: some View {
        HStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                CharacterCanvas(character: settings.character, theme: settings.spriteTheme, date: context.date)
            }
            .frame(width: 92, height: 60)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.characterBackdrop))
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.character.name).font(.system(size: 17, weight: .semibold))
                Text("토큰을 빨리 쓸수록 메뉴바에서 빨리 달립니다.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // 러너 고르기·꾸미기·만들기는 무대가 있는 러너 화면에서 한다
            Button("러너 바꾸기", action: openRunners)
                .tip("러너 화면에서 고르거나 만들고 꾸밉니다")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.groupedRow))
    }

    // MARK: 사용량

    private var usage: some View {
        GroupedList {
            GroupedSection("공식 사용량",
                           footer: "Anthropic 계정 기준 사용률을 3분마다 받습니다. 받지 못하면 사용률은 비워 두고, 속도와 오늘 사용량은 이 Mac의 기록으로 보입니다.") {
                ToggleRow(title: "공식 사용량 연동", icon: "chart.pie.fill", isOn: $settings.officialEnabled)
                GroupedRow("상태", icon: "antenna.radiowaves.left.and.right") {
                    HStack(spacing: 8) {
                        Circle().fill(officialStatusColor).frame(width: 7, height: 7)
                        Text(officialStatusText).foregroundStyle(.secondary).lineLimit(1)
                        Button("지금 받기") { engine.refreshNow(forceOfficial: true) }
                            .controlSize(.small)
                            .disabled(!settings.officialEnabled)
                    }
                }
                .tip(officialStatusText)
                if let account = engine.account {
                    GroupedRow("계정", icon: "person.crop.circle") {
                        Text(account.email + (account.organizationType.map { " · " + AccountSwitcher.Account.planName($0) } ?? ""))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .tip("지금 Claude Code에 로그인한 계정. 아래 사용률은 이 계정 기준입니다")
                }
                GroupedRow("세션 (5시간)", icon: "clock") {
                    Text(Self.gaugeText(engine.sessionGauge, reset: engine.sessionResetsAt.map { Format.resetCountdown(until: $0) }))
                        .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                GroupedRow("주간 (7일)", icon: "calendar") {
                    Text(Self.gaugeText(engine.weeklyGauge, reset: engine.nextWeeklyReset.map { "\(Format.weekdayTime($0)) 초기화" }))
                        .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if let shares = weeklySharesText {
                    GroupedRow("주간 사용처", icon: "chart.bar") {
                        Text(shares).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            GroupedSection("러너 속도", footer: "민감도가 높을수록 적은 사용량에도 빨리 달리고, 달리기 속도는 자동으로 정해진 속도에 곱해집니다. 확인 주기가 짧을수록 빨리 반응합니다. Claude가 답을 마치면 멈추고 5분 넘게 자리를 비우면 잠듭니다.") {
                GroupedRow("민감도", icon: "speedometer") {
                    segmented("민감도", $settings.sensitivity, Thresholds.Sensitivity.allCases) { $0.displayName }
                }
                GroupedRow("달리기 속도", icon: "hare") {
                    menu("달리기 속도", $settings.runnerSpeed, AppSettings.runnerSpeedOptions) { Self.speedName($0) }
                }
                GroupedRow("기록 확인 주기", icon: "timer") {
                    menu("기록 확인 주기", $settings.pollInterval, AppSettings.pollIntervalOptions) { String(format: "%.0f초", $0) }
                }
            }

            GroupedSection("입력 반응", footer: "키보드를 치는 빠르기로도 걷고 달리고, 손을 떼면 바로 멈춥니다. 누른 키는 읽지 않고 횟수만 셉니다.") {
                ToggleRow(title: "타자에 맞춰 달리기", icon: "keyboard", isOn: $settings.typingRunnerEnabled)
            }
        }
    }

    // MARK: 알림

    private var alerts: some View {
        GroupedList {
            GroupedSection("Claude", footer: permissionHook.error ?? "작업 끝 알림은 러너가 보이지 않을 때 1분 넘게 걸린 작업만 알립니다. 승인 기다림을 켜면 Claude Code 설정(~/.claude/settings.json)에 훅 하나를 더해 승인을 기다리는 동안 러너가 물음표를 띄웁니다. 끄면 더한 훅만 뺍니다.") {
                ToggleRow(title: "작업이 끝나면 알리기", icon: "checkmark.bubble",
                          isOn: $settings.claudeDoneAlertEnabled)
                ToggleRow(title: "승인을 기다리면 러너로 알리기", icon: "hand.raised",
                          isOn: Binding(get: { permissionHook.installed }, set: { permissionHook.set($0) }))
            }
            .onAppear { permissionHook.refresh() }

            GroupedSection("사용량", footer: "초기화 알림은 창이 새로 시작될 때 한 번씩 보냅니다. 주간 초기화는 공식 사용량 연동을 켜야 알 수 있습니다.") {
                ToggleRow(title: "세션이 초기화되면 알리기", icon: "arrow.clockwise",
                          isOn: $settings.newSessionAlertEnabled)
                ToggleRow(title: "주간 사용량이 초기화되면 알리기", icon: "calendar",
                          isOn: $settings.weeklyResetAlertEnabled)
                    .disabled(!settings.officialEnabled)   // 주간 창은 공식 값으로만 안다
                ToggleRow(title: "주간 요약 받기", icon: "chart.bar.doc.horizontal",
                          isOn: $settings.weeklySummaryEnabled)
            }

            GroupedSection("피그마", footer: "알림 받을 메뉴에서 완료된 화면이 바뀌거나 디자이너가 이력에 적으면 알립니다. [수정중]처럼 작업 중인 시안은 자주 바뀌어 기본은 기록만 합니다.") {
                ToggleRow(title: "화면설계서가 바뀌면 알리기", icon: "paintpalette", isOn: $design.notify)
                ToggleRow(title: "작업 중 변경도 알리기", icon: "pencil.and.outline", isOn: $design.notifyWorking)
                    .disabled(!design.notify)
                GroupedRow("알림 받을 메뉴", icon: "list.bullet.indent") {
                    HStack(spacing: 8) {
                        Text(figmaAlertSummary).foregroundStyle(.secondary).lineLimit(1)
                        Button("고르기") { tab.selection = .figma }.controlSize(.small)
                    }
                }
            }

            GroupedSection("보이는 방식", footer: "펫을 화면에 꺼내 두면 알림이 펫 위 말풍선으로 뜹니다. 할 일이 남은 알림은 직접 닫을 때까지 남고, 나머지는 1분쯤 보인 뒤 저절로 닫힙니다.") {
                if Notifier.shared.available { NotificationStyleRow() }
                GroupedRow("알림 보내 보기", icon: "paperplane") {
                    Button("보내기") {
                        Notifier.shared.send(title: "RunTime 알림", body: "알림이 이렇게 옵니다.")
                    }
                    .controlSize(.small)
                    .disabled(!Notifier.shared.available)
                }
                .tip("알림이 오지 않으면 시스템 설정 > 알림 > RunTime에서 허용을 확인하세요.")
            }
            if !Notifier.shared.available { devOnlyNote("알림") }
        }
    }

    /// 알림 받을 메뉴를 고른 화면설계서 수.
    private var figmaAlertSummary: String {
        guard !design.sources.isEmpty else { return "화면설계서 없음" }
        let picked = design.sources.filter { !$0.alerts.isEmpty }.count
        return picked == 0 ? "고른 메뉴 없음" : "화면설계서 \(picked)개에서 고름"
    }

    // MARK: 조각

    /// 이름은 화면에 줄 제목으로 따로 있어 숨기지만, VoiceOver가 읽도록 Picker에도 넘긴다.
    private func segmented<Value: Hashable>(_ name: String, _ selection: Binding<Value>, _ values: [Value],
                                            title: @escaping (Value) -> String) -> some View {
        Picker(name, selection: selection) {
            ForEach(values, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// iOS의 오른쪽 값 + 위아래 화살표 메뉴.
    private func menu<Value: Hashable>(_ name: String, _ selection: Binding<Value>, _ values: [Value],
                                       title: @escaping (Value) -> String) -> some View {
        Picker(name, selection: selection) {
            ForEach(values, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private static func speedName(_ value: Double) -> String {
        value == 1 ? "보통 (1배)" : String(format: "%g배", value)
    }

    private func devOnlyNote(_ feature: String) -> some View {
        Text("\(feature)은 install.sh로 설치한 RunTime.app에서만 동작합니다.")
            .font(.system(size: 11)).foregroundStyle(Palette.orange)
            .padding(.horizontal, 14)
            .padding(.top, -12)
    }

    private static let projectsDirectory = ClaudePaths.configDirectory.appendingPathComponent("projects")

    /// install.sh로 설치한 빌드가 어느 커밋인지 (build-app.sh가 Info.plist에 남긴다).
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "개발 실행" }
        let build = (info?["CFBundleVersion"] as? String).map { " · 빌드 \($0)" } ?? ""
        return (info?["RunTimeCommit"] as? String).map { "\(version)\(build) (\($0))" } ?? version + build
    }

    /// "42% · 2시간 10분 뒤 초기화". 공식 값이 없으면 "-".
    static func gaugeText(_ gauge: GaugeReading?, reset: String?) -> String {
        guard let gauge else { return "-" }
        return ["\(gauge.displayPercent)%", reset].compactMap { $0 }.joined(separator: " · ")
    }

    private var weeklySharesText: String? {
        let used = engine.weeklyBreakdown.filter { $0.percent >= 1 }.sorted { $0.percent > $1.percent }
        guard !used.isEmpty else { return nil }
        return used.map { "\($0.name) \(Int($0.percent))%" }.joined(separator: " · ")
    }

    private var officialStatusText: String {
        switch engine.officialStatus {
        case .live:
            let age = engine.official.map { Int(Date().timeIntervalSince($0.fetchedAt) / 60) } ?? 0
            return age < 1 ? "연동 중 · 방금 받음" : "연동 중 · \(age)분 전 받음"
        case .waiting: return "받는 중…"
        case .stale(let reason): return "직전 값 사용 중 · \(reason)"
        case .failed(let reason): return "받지 못함 · \(reason)"
        case .disabled: return "꺼짐"
        }
    }

    private var officialStatusColor: Color {
        switch engine.officialStatus {
        case .live: return Palette.green
        case .waiting, .disabled: return Palette.gray
        case .stale, .failed: return Palette.orange
        }
    }
}

/// 문제 기록 묶음. 새 기록이 생기면 바로 다시 읽는다.
/// macOS 알림이 배너(잠깐 뜨고 사라짐)인지 알림(직접 닫을 때까지)인지 보이고, 바꿀 곳을 연다.
/// 스타일은 사용자만 바꿀 수 있어 앱이 정해 둘 수 없다.
private struct NotificationStyleRow: View {
    private final class Model: ObservableObject { @Published var style: Notifier.Style? }
    @StateObject private var model = Model()

    var body: some View {
        GroupedRow("펫을 넣어 두었을 때", icon: "rectangle.stack.badge.person.crop") {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("바꾸기") {
                    let id = Bundle.main.bundleIdentifier ?? ""
                    let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
                    if let url { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
        }
        .tip("직접 닫을 때까지 남기려면 시스템 설정에서 RunTime의 알림 스타일을 '알림'으로 고르세요.")
        .onAppear(perform: load)
        // 시스템 설정에서 바꾸고 돌아오면 다시 읽는다
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in load() }
    }

    private var label: String {
        switch model.style {
        case .alert: "직접 닫을 때까지 남습니다"
        case .banner: "잠깐 뜨고 사라집니다"
        case .off: "꺼져 있습니다"
        case nil: ""
        }
    }

    private func load() {
        Notifier.shared.style { [model] in model.style = $0 }
    }
}

private struct DiagnosticsRows: View {
    let usage: () -> String
    @StateObject private var model = DiagnosticsModel()

    var body: some View {
        ToggleRow(title: "문제를 만든 사람에게 알리기", icon: "paperplane.fill",
                  isOn: Binding(get: { model.reports }, set: { model.reports = $0 }))
        GroupedRow("최근 기록", icon: "stethoscope") {
            HStack(spacing: 8) {
                // 쌓인 기록 수보다 오늘 생긴 수가 지금 문제가 있는지 알려 준다
                Text(model.today == 0 ? "오늘은 없음" : "오늘 \(model.today)건")
                    .foregroundStyle(model.today == 0 ? Color.secondary : Palette.orange)
                Button("열기") { NSWorkspace.shared.open(Diagnostics.logURL) }
                    .controlSize(.small)
                    .disabled(model.recent.isEmpty)
                Button(model.copied ? "복사됨" : "진단 복사") {
                    Diagnostics.copyReport(usage: usage())
                    model.markCopied()
                }
                .controlSize(.small)
                .tip("빌드, macOS, 화면 구성, 업데이트 상태와 최근 기록을 클립보드에 담습니다")
            }
        }
        // 기록 본문은 "열기"로 보고, 여기는 마지막 한 건을 마우스를 올렸을 때만 보인다 (설정 화면을 기록으로 채우지 않게)
        .tip(model.recent.last.map { "마지막 기록: \($0)" } ?? Diagnostics.logURL.path)
        GroupedRow("문제 보내기", icon: "exclamationmark.bubble.fill") {
            Button("쓰기") { ProblemReportWindow.shared.show(usage: usage()) }
                .controlSize(.small)
        }
        .tip("오류는 안 났지만 이상하게 도는 것을 적고 찍은 화면을 붙여 보냅니다. 메뉴바 오른쪽 클릭 메뉴에서도 엽니다")
    }
}

/// 문제 기록 묶음의 상태. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var recent: [String] = []
    /// 최근 기록 가운데 오늘 날짜로 시작하는 줄 수.
    @Published private(set) var today = 0
    @Published private(set) var copied = false
    @Published var reports = ProblemReporter.isOn { didSet { ProblemReporter.isOn = reports } }
    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: Diagnostics.recorded, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// 기록 파일은 256KB까지 커져 메인 스레드에서 읽지 않는다.
    func reload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 오늘 건수는 파일 전체에서 세고, 화면에 들고 있는 것은 마지막 50줄만
            let lines = Diagnostics.recent(.max)
            let prefix = Self.day.string(from: Date())
            let today = lines.reversed().prefix { $0.hasPrefix(prefix) }.count
            DispatchQueue.main.async {
                self?.recent = Array(lines.suffix(50))
                self?.today = today
            }
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func markCopied() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copied = false }
    }
}

/// 업데이트 묶음의 줄들. 새 커밋이 있으면 단추 하나로 받아 다시 빌드한다.
private struct UpdateRows: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        GroupedRow("새 버전", icon: "arrow.down.circle.fill") {
            HStack(spacing: 8) {
                Text(status).foregroundStyle(statusColor).lineLimit(1).truncationMode(.middle)
                switch updater.state {
                case .available:
                    Button("업데이트") { updater.update() }.controlSize(.small)
                case .failed where updater.installFailed:
                    Button("다시 시도") { updater.update() }.controlSize(.small)
                case .updating:
                    if let progress = updater.progress {
                        UpdateGauge(fraction: progress.fraction, track: Color.secondary.opacity(0.2))
                            .frame(width: 70, height: 5)
                        Text("\(Int(progress.fraction * 100))%").foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .checking:
                    ProgressView().controlSize(.small)
                case .unavailable:
                    EmptyView()
                default:
                    Button("확인") { updater.check() }.controlSize(.small)
                }
            }
        }
        .tip(helpText)
        // 받을 변경을 최근 것부터 몇 줄 보여 준다
        if case .available = updater.state {
            if let blocked = updater.blocked {
                GroupedRow(blocked) { EmptyView() }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.orange)
            }
            ForEach(Array(updater.incoming.enumerated()), id: \.offset) { _, title in
                GroupedRow("· \(title)") { EmptyView() }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        if updater.canCheck {
            ToggleRow(title: "자동으로 업데이트", icon: "arrow.triangle.2.circlepath", isOn: $updater.autoUpdate)
        }
    }

    private var status: String {
        switch updater.state {
        case .unavailable: return "설치한 앱에서만 확인"
        case .idle: return "매일 9시, 30분마다 확인"
        case .checking: return "확인 중…"
        case .upToDate: return "최신 버전"
        case .available(let count, _): return updater.blocked == nil ? "새 커밋 \(count)개" : "새 커밋 \(count)개 · 미룸"
        case .updating:
            guard let progress = updater.progress else { return "설치하는 중…" }
            return progress.remaining.map { "\(progress.step) · \(UpdateProgressPanel.remainingText($0))" } ?? progress.step
        case .failed(let reason): return reason
        }
    }

    /// 줄이 좁아 잘리는 긴 내용(사유, 최신 커밋 제목)은 마우스를 올리면 보인다.
    private var helpText: String {
        switch updater.state {
        case .unavailable(let reason): return reason
        case .available(_, let latest): return updater.blocked.map { "\($0)\n최신: \(latest)" } ?? latest
        case .failed(let reason): return reason
        default: return ""
        }
    }

    private var statusColor: Color {
        switch updater.state {
        case .available: return Palette.blue
        case .failed: return Palette.orange
        case .updating: return Palette.teal
        default: return .secondary
        }
    }
}

/// 설정 창의 고른 탭. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class SettingsTabState: ObservableObject {
    @Published var selection: SettingsView.Tab

    init(_ selection: SettingsView.Tab) {
        self.selection = selection
    }
}

/// Claude Code 계정 목록. 고르면 바꾸고, 쓰지 않는 계정은 지운다.
private struct AccountSection: View {
    @ObservedObject var switcher: AccountSwitcher
    @ObservedObject var engine: UsageEngine

    /// 지금 계정은 방금 받은 값을, 다른 계정은 10분마다 받아 둔 값을 쓴다.
    private func usageText(_ account: AccountSwitcher.Account) -> String {
        if account.id == engine.account?.uuid, engine.sessionGauge != nil || engine.weeklyGauge != nil {
            return "세션 \(engine.sessionGauge.map { "\($0.displayPercent)%" } ?? "-") · 주간 \(engine.weeklyGauge.map { "\($0.displayPercent)%" } ?? "-")"
        }
        return PopoverView.usageSuffix(account.lastUsage).trimmingCharacters(in: .whitespaces)
    }

    private func usageTip(_ account: AccountSwitcher.Account) -> String {
        guard let usage = account.lastUsage else { return "아직 사용률을 받지 못했습니다" }
        let now = Date()
        func line(_ name: String, _ reset: Date?) -> String? {
            reset.map { $0 > now ? "\(name) \(Format.weekdayTime($0)) 초기화" : "\(name) 초기화됨" }
        }
        return [line("세션", usage.sessionResetsAt), line("주간", usage.weeklyResetsAt)].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        GroupedSection("로그인한 계정", footer: footer) {
            ForEach(switcher.accounts) { account in
                GroupedRow(account.label, icon: account.id == switcher.activeID ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle") {
                    HStack(spacing: 6) {
                        if account.needsLogin == true {
                            Text("다시 로그인 필요").foregroundStyle(Palette.orange)
                                .tip("저장한 로그인이 풀렸습니다. 이 계정으로 Claude Code에서 /login 하면 다시 기억합니다")
                        } else if !usageText(account).isEmpty {
                            Text(usageText(account)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                                .tip(usageTip(account))
                        }
                        if account.id == switcher.activeID {
                            Text("사용 중").foregroundStyle(.secondary)
                        } else {
                            Button("바꾸기") { switcher.switchTo(account.id) }
                                .controlSize(.small)
                                .disabled(switcher.switching)
                            // 저장한 로그인까지 지워져 그 계정으로 /login을 다시 해야 하므로 한 번 묻는다.
                            // 바꾸기 옆에 같은 꼴로 두면 잘못 누르기 쉬워 작은 휴지통으로 둔다
                            Button {
                                let alert = NSAlert()
                                alert.messageText = "\(account.email)의 저장된 로그인을 지울까요?"
                                alert.informativeText = "다시 쓰려면 그 계정으로 Claude Code에서 /login 해야 합니다."
                                alert.addButton(withTitle: "지우기")
                                alert.addButton(withTitle: "취소")
                                alert.buttons.first?.hasDestructiveAction = true
                                if alert.runModal() == .alertFirstButtonReturn { switcher.remove(account.id) }
                            } label: {
                                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .tip("저장한 로그인 지우기")
                            .accessibilityLabel("\(account.email) 지우기")
                        }
                    }
                }
            }
            if switcher.accounts.isEmpty {
                GroupedRow("기억한 계정 없음", icon: "person.crop.circle.badge.questionmark") { EmptyView() }
            }
            // 바꿀 계정이 하나뿐이면 쓸 일이 없어 숨긴다
            if switcher.accounts.count >= 2 {
                ToggleRow(title: "한도에 닿으면 자동으로 바꾸기", icon: "arrow.left.arrow.right",
                          isOn: $switcher.autoSwitch)
            }
            if let error = switcher.lastError {
                GroupedRow(error, icon: "exclamationmark.triangle.fill") { EmptyView() }
            }
        }
    }

    private var footer: String {
        "Claude Code에서 /login으로 들어간 계정이 여기에 쌓입니다. 바꾸기를 누르면 열려 있는 세션도 곧 그 계정을 씁니다. 자동으로 바꾸기를 켜면 사용률이 \(Int(AccountSwitcher.autoSwitchLimit))%에 닿을 때 여유가 가장 많은 계정으로 바꿉니다. 로그인 정보는 이 Mac의 키체인에만 둡니다."
    }
}

/// 펫 만들기 모델이 차지하는 자리와 지우기. 받아 둔 모델이 있을 때만 보인다.
private struct PetMakerStorageSection: View {
    @ObservedObject private var factory = PetFactory.shared

    var body: some View {
        if factory.isPrepared {
            GroupedSection("저장 공간", footer: "지우면 다음에 펫을 만들 때 다시 받습니다. 만든 펫은 남습니다.") {
                GroupedRow("펫 만들기 모델", icon: "externaldrive") {
                    HStack(spacing: 8) {
                        Text(ByteCountFormatter.string(fromByteCount: factory.storageSize, countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button("지우기") { factory.removeTools() }
                            .controlSize(.small)
                            .disabled(factory.isWorking)
                    }
                }
            }
        }
    }
}

