import SwiftUI
import UsageCore

/// 설정 창. iOS 설정 앱처럼 색 아이콘 줄을 둥근 묶음으로 모으고, 설명은 묶음 아래 각주로 둔다.
/// 왼쪽 목록으로 일반·러너·사용량을 고른다. 변경은 UserDefaults에 바로 저장되고 메뉴바와 팝오버에 바로 반영된다.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: UsageEngine
    /// 앱이 들고 있는 탭 상태. 다른 화면에서 특정 구역을 열 수 있게 바깥에서 받는다.
    @ObservedObject var tab: SettingsTabState
    /// 업무 일지 연동 칸(GitLab·레드마인…)은 업무 일지 화면과 같은 상태를 쓴다. 고른 칸도 거기 둔다.
    @ObservedObject var workLog: WorkLogPage
    @ObservedObject private var workLogSettings = WorkLogSettings.shared
    @ObservedObject private var workLogSync = WorkLogSync.shared
    @StateObject private var hotKeyRecorder = HotKeyRecorder()

    enum Tab: Hashable { case general, runner, usage, workLog, design, designAlerts }

    init(settings: AppSettings, engine: UsageEngine, tab: SettingsTabState, workLog: WorkLogPage) {
        self.settings = settings
        self.engine = engine
        self.tab = tab
        self.workLog = workLog
    }

    var body: some View {
        // 창이 넓어 위 세그먼트 대신 왼쪽에 구역 목록을 두고, 설정 글은 읽기 좋은 너비로 가운데에 둔다
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                navHeader("앱")
                navRow(.general, "일반", icon: "gearshape", tint: Palette.gray)
                navRow(.runner, "러너", icon: "hare.fill", tint: Palette.orange)
                navRow(.usage, "사용량", icon: "chart.bar.fill", tint: Palette.blue)
                navHeader("업무 일지").padding(.top, 14)
                ForEach(WorkLogPage.SettingsSection.allCases, id: \.self) { section in
                    workLogRow(section)
                }
                navHeader("디자인").padding(.top, 14)
                navRow(.design, "피그마", icon: "paintpalette.fill", tint: Palette.purple)
                navRow(.designAlerts, "알림", icon: "bell.fill", tint: Palette.purple)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(width: 220)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.groupedRow.opacity(0.5))
            Rectangle().fill(Palette.separator.opacity(0.5)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                switch tab.selection {
                case .general: general
                case .runner: runner
                case .usage: usage
                case .workLog:
                    WorkLogSettingsView(settings: workLogSettings, sync: workLogSync, page: workLog, store: .shared)
                        .padding(.leading, -12)
                case .design, .designAlerts:
                    DesignSettingsView(sync: .shared, settings: .shared, section: tab.selection == .design ? .figma : .alerts)
                        .id(tab.selection)
                        .padding(.leading, -12)
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background([.workLog, .design, .designAlerts].contains(tab.selection) ? WL.canvas : Palette.groupedBackground)
        }
        .background(Palette.groupedBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch tab.selection {
        case .general: return "일반"
        case .runner: return "러너"
        case .usage: return "사용량"
        case .workLog: return workLog.settingsSection.rawValue
        case .design: return "피그마"
        case .designAlerts: return "디자인 알림"
        }
    }

    private func navHeader(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 2)
    }

    /// 업무 일지 연동 칸. 오른쪽 점은 켜짐(초록)·확인 필요(주황).
    private func workLogRow(_ section: WorkLogPage.SettingsSection) -> some View {
        let on = tab.selection == .workLog && workLog.settingsSection == section
        let dot = WorkLogSettingsView.dot(section, settings: workLogSettings, sync: workLogSync, store: .shared)
        return Button {
            workLog.settingsSection = section
            tab.selection = .workLog
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.indigo))
                Text(section.rawValue).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer()
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navRow(_ value: Tab, _ title: String, icon: String, tint: Color) -> some View {
        let on = tab.selection == value
        return Button { tab.selection = value } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint))
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 일반

    private var general: some View {
        GroupedList {
            GroupedSection(footer: "자동 시작을 켜면 Mac에 로그인할 때 러너를 띄웁니다. 단축키를 켜면 어느 앱에서든 \(GlobalHotKey.displayName)로 사용량 창을 엽니다. 단축키를 눌러 다른 조합으로 바꿀 수 있습니다. 기본은 러너만 보이고, 사용률 표시를 켜면 러너 바로 옆에 숫자로 함께 보여 줍니다.") {
                ToggleRow(title: "로그인 시 자동 시작", icon: "power", tint: Palette.green, isOn: $settings.launchAtLogin)
                    .disabled(!LaunchAtLogin.available)
                ToggleRow(title: "단축키로 사용량 열기", icon: "command", tint: Palette.gray,
                          isOn: $settings.globalHotKeyEnabled)
                if settings.globalHotKeyEnabled {
                    GroupedRow("단축키", icon: "keyboard", tint: Palette.gray) {
                        HStack(spacing: 6) {
                            if GlobalHotKey.shared.combo != .standard && !hotKeyRecorder.recording {
                                Button("기본으로") { hotKeyRecorder.reset() }
                            }
                            Button(hotKeyRecorder.recording ? "새 조합을 누르세요 (esc 취소)" : GlobalHotKey.displayName) {
                                hotKeyRecorder.toggle()
                            }
                            .tip("누른 뒤 원하는 조합을 누르면 바뀝니다")
                        }
                        .controlSize(.small)
                    }
                    .onDisappear { hotKeyRecorder.stop() }   // 다른 구역으로 넘어가면 기록을 멈춘다
                    if let hint = hotKeyRecorder.hint {
                        GroupedRow(hint) { EmptyView() }
                            .foregroundStyle(Palette.orange)
                    }
                }
                if settings.globalHotKeyEnabled && GlobalHotKey.shared.failed && hotKeyRecorder.hint == nil {
                    GroupedRow("다른 앱이 이 단축키를 쓰고 있어 등록하지 못했습니다.") { EmptyView() }
                        .foregroundStyle(Palette.orange)
                }
                ToggleRow(title: "메뉴바에 사용률 표시", icon: "percent", tint: Palette.blue, isOn: $settings.showsMenuBarLabel)
                if settings.showsMenuBarLabel {
                    GroupedRow("표시할 값") {
                        segmented("표시할 값", $settings.menuBarLabel, MenuBarLabel.allCases.filter { $0 != .off }) { $0.displayName }
                    }
                }
            }
            if !LaunchAtLogin.available { devOnlyNote("자동 시작") }

            GroupedSection("업데이트", footer: "새 버전은 설치한 폴더에서 다시 빌드합니다. 1~2분 동안 러너가 잠깐 사라졌다가 돌아옵니다. 자동으로 업데이트를 켜면 묻지 않고 설치합니다.") {
                UpdateRows(updater: AppUpdater.shared)
            }

            GroupedSection("문제 기록", footer: "업데이트를 미루거나 실패한 일, 사용량 창이 화면 밖으로 넘친 일, 공식 사용량을 받지 못한 일을 이 Mac에만 적어 둡니다. 다른 Mac에서 문제가 생기면 그 Mac에서 '진단 복사'를 눌러 붙여 넣으면 빌드·화면 구성·최근 기록을 한 번에 볼 수 있습니다. 키나 일지 내용은 담지 않습니다.") {
                DiagnosticsRows(usage: { officialStatusText })
            }

            GroupedSection("정보", footer: "RunTime은 Anthropic과 관계없는 개인 프로젝트입니다.") {
                GroupedRow("버전", icon: "info", tint: Palette.gray) {
                    Text(Self.versionText).foregroundStyle(.secondary)
                }
                GroupedRow("Claude Code 기록 폴더", icon: "folder.fill", tint: Palette.teal) {
                    Button("열기") { NSWorkspace.shared.open(Self.projectsDirectory) }
                        .controlSize(.small)
                }
                .tip(Self.projectsDirectory.path)
                Link(destination: URL(string: "https://github.com/youminki/RunTime")!) {
                    GroupedRow("GitHub 저장소", icon: "chevron.left.forwardslash.chevron.right", tint: Color(white: 0.2)) {
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

            GroupedSection("모습", footer: "'크게'는 머리 위 여백을 줄여 캐릭터를 키웁니다. 움직임은 1초에 바뀌는 그림 수(절약 12, 부드럽게 30, 최고 60)로, 메뉴바와 사용량 창 무대에 함께 쓰입니다. 많을수록 매끄럽지만 CPU를 조금 더 씁니다. '본래 색'을 고르면 메뉴바에서도 캐릭터 고유색으로 그립니다.") {
                GroupedRow("메뉴바 크기", icon: "textformat.size", tint: Palette.indigo) {
                    segmented("메뉴바 크기", $settings.runnerSize, RunnerSize.allCases) { $0.displayName }
                }
                GroupedRow("색상", icon: "paintpalette.fill", tint: Palette.pink) {
                    menu("색상", $settings.spriteTheme, SpriteTheme.allCases) { $0.displayName }
                }
                GroupedRow("움직임", icon: "film.stack", tint: Palette.orange) {
                    segmented("움직임", $settings.smoothness, SpriteSmoothness.allCases) { $0.displayName }
                }
                ToggleRow(title: "가끔 혼자 장난치기", icon: "hand.wave.fill", tint: Palette.purple, isOn: $settings.tricksEnabled)
            }

            GroupedSection("러너 고르기", footer: "직접 만들었거나 쓸 권리가 있는 그림만 불러오세요. 불러온 그림은 이 Mac에만 저장되고 어디로도 보내지 않습니다.") {
                RunnerPicker(settings: settings)
                    .padding(12)
            }
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
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.groupedRow))
    }

    // MARK: 사용량

    private var usage: some View {
        GroupedList {
            GroupedSection("공식 사용량",
                           footer: "Anthropic 계정 기준 사용률을 3분마다 받습니다. 끄거나 받지 못하면 사용률은 비워 두고, 속도와 오늘 사용량은 이 Mac의 기록으로 계속 보여 줍니다.") {
                ToggleRow(title: "공식 사용량 연동", icon: "chart.pie.fill", tint: Palette.indigo, isOn: $settings.officialEnabled)
                GroupedRow("상태", icon: "antenna.radiowaves.left.and.right", tint: officialStatusColor) {
                    Text(officialStatusText).foregroundStyle(.secondary).lineLimit(1)
                }
                .tip(officialStatusText)
            }

            AccountSection(switcher: AccountSwitcher.shared)

            GroupedSection("속도", footer: "민감도가 높을수록 적은 사용량에도 빨리 달립니다. 확인 주기가 짧을수록 러너가 빨리 반응합니다.") {
                GroupedRow("민감도", icon: "hare.fill", tint: Palette.orange) {
                    segmented("민감도", $settings.sensitivity, Thresholds.Sensitivity.allCases) { $0.displayName }
                }
                GroupedRow("기록 확인 주기", icon: "timer", tint: Palette.blue) {
                    menu("기록 확인 주기", $settings.pollInterval, AppSettings.pollIntervalOptions) { String(format: "%.0f초", $0) }
                }
            }

            GroupedSection("알림", footer: "한도 임박 알림은 세션·주간 사용률이 80%, 95%에 닿을 때 한 번씩, 초기화 알림은 5시간·주간 창이 새로 시작될 때 보냅니다. 주간 초기화는 공식 사용량 연동을 켜야 알 수 있습니다. Claude 작업 끝 알림은 사용량 창이 닫혀 있고 1분 넘게 걸린 작업만 알립니다. 주간 요약은 한 주가 끝나면 지난 7일의 토큰, 비용, 가장 많이 쓴 날과 프로젝트를 한 번 알립니다.") {
                ToggleRow(title: "한도 임박 알림", icon: "bell.badge.fill", tint: Palette.red, isOn: $settings.limitAlertsEnabled)
                ToggleRow(title: "세션 초기화 알림", icon: "arrow.clockwise", tint: Palette.green,
                          isOn: $settings.newSessionAlertEnabled)
                ToggleRow(title: "주간 초기화 알림", icon: "calendar", tint: Palette.teal,
                          isOn: $settings.weeklyResetAlertEnabled)
                    .disabled(!settings.officialEnabled)   // 주간 창은 공식 값으로만 안다
                ToggleRow(title: "Claude 작업 끝 알림", icon: "checkmark.bubble.fill", tint: Palette.orange,
                          isOn: $settings.claudeDoneAlertEnabled)
                ToggleRow(title: "주간 요약 알림", icon: "chart.bar.doc.horizontal", tint: Palette.indigo,
                          isOn: $settings.weeklySummaryEnabled)
                GroupedRow("알림 보내 보기", icon: "paperplane.fill", tint: Palette.blue) {
                    Button("보내기") {
                        Notifier.shared.send(title: "RunTime 알림", body: "알림이 이렇게 와요. 사용률이 80%, 95%에 닿으면 알려 드릴게요.")
                    }
                    .controlSize(.small)
                    .disabled(!Notifier.shared.available)
                }
                .tip("알림이 오지 않으면 시스템 설정 > 알림 > RunTime에서 허용을 확인하세요.")
            }
            if !Notifier.shared.available { devOnlyNote("알림") }
        }
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
private struct DiagnosticsRows: View {
    let usage: () -> String
    @StateObject private var model = DiagnosticsModel()

    var body: some View {
        GroupedRow("최근 기록", icon: "stethoscope", tint: Palette.orange) {
            HStack(spacing: 8) {
                Text(model.recent.isEmpty ? "없음" : "\(model.recent.count)건").foregroundStyle(.secondary)
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
        .tip(Diagnostics.logURL.path)
        // 최근 세 건은 바로 보이게 한다
        ForEach(Array(model.recent.suffix(3).reversed().enumerated()), id: \.offset) { _, line in
            GroupedRow(line) { EmptyView() }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .tip(line)
        }
    }
}

/// 문제 기록 묶음의 상태. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var recent: [String] = []
    @Published private(set) var copied = false
    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: Diagnostics.recorded, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func reload() { recent = Diagnostics.recent(50) }

    func markCopied() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copied = false }
    }
}

/// 업데이트 묶음의 줄들. 새 커밋이 있으면 단추 하나로 받아 다시 빌드한다.
private struct UpdateRows: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        GroupedRow("새 버전", icon: "arrow.down.circle.fill", tint: Palette.blue) {
            HStack(spacing: 8) {
                Text(status).foregroundStyle(statusColor).lineLimit(1).truncationMode(.middle)
                switch updater.state {
                case .available:
                    Button("업데이트") { updater.update() }.controlSize(.small)
                case .checking, .updating:
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
            ToggleRow(title: "자동으로 업데이트", icon: "arrow.triangle.2.circlepath", tint: Palette.teal, isOn: $updater.autoUpdate)
        }
    }

    private var status: String {
        switch updater.state {
        case .unavailable: return "설치한 앱에서만 확인"
        case .idle: return "30분마다 확인"
        case .checking: return "확인 중…"
        case .upToDate: return "최신 버전"
        case .available(let count, _): return updater.blocked == nil ? "새 커밋 \(count)개" : "새 커밋 \(count)개 · 미룸"
        case .updating: return "설치하는 중…"
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

    var body: some View {
        GroupedSection("Claude 계정", footer: footer) {
            ForEach(switcher.accounts) { account in
                GroupedRow(account.label, icon: account.id == switcher.activeID ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle",
                           tint: account.id == switcher.activeID ? Palette.green : Palette.gray) {
                    HStack(spacing: 6) {
                        if let usage = account.lastUsage {
                            Text("\(Int(usage.effectivePercent(now: Date())))%").foregroundStyle(.secondary).monospacedDigit()
                        }
                        if account.id == switcher.activeID {
                            Text("사용 중").foregroundStyle(.secondary)
                        } else {
                            Button("지우기") { switcher.remove(account.id) }
                            Button("바꾸기") { switcher.switchTo(account.id) }
                                .disabled(switcher.switching)
                        }
                    }
                }
            }
            if switcher.accounts.isEmpty {
                GroupedRow("기억한 계정 없음", icon: "person.crop.circle.badge.questionmark", tint: Palette.gray) { EmptyView() }
            }
            ToggleRow(title: "한도에 닿으면 자동으로 바꾸기", icon: "arrow.left.arrow.right", tint: Palette.blue,
                      isOn: $switcher.autoSwitch)
                .disabled(switcher.accounts.count < 2)
            if let error = switcher.lastError {
                GroupedRow(error, icon: "exclamationmark.triangle.fill", tint: Palette.orange) { EmptyView() }
            }
        }
    }

    private var footer: String {
        "Claude Code에서 /login으로 다른 계정에 들어가면 여기에 자동으로 추가됩니다. 바꾸기를 누르면 Claude Code의 로그인 정보를 그 계정 것으로 바꾸고, 열려 있는 세션도 곧 그 계정을 씁니다. 자동으로 바꾸기를 켜면 Claude Code가 한도에 막히거나 사용률이 \(Int(AccountSwitcher.autoSwitchLimit))%에 닿을 때 여유가 가장 많은 계정으로 바로 바꾸고, 바꿀 계정이 없으면 언제 풀리는지 알립니다. 쓰지 않는 계정의 사용률은 10분마다 받고, 저장한 토큰이 만료됐으면 마지막으로 받은 값을 보여 줍니다. 로그인 정보는 이 Mac의 키체인에만 둡니다."
    }
}
