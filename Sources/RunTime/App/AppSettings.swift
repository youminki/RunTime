import Foundation
import Combine
import UsageCore

/// §F5 설정 (UserDefaults 저장). 변경 즉시 게이지에 반영되도록 ObservableObject.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    static let pollIntervalOptions: [Double] = [1, 3, 5, 10]

    private enum Key: String {
        case officialEnabled, sensitivity, pollInterval, limitAlertsEnabled, newSessionAlertEnabled, weeklyResetAlertEnabled, claudeDoneAlertEnabled, weeklySummaryEnabled, globalHotKeyEnabled, spriteTheme
        case menuBarLabel, menuBarLabelLast, runner, smoothness, tricksEnabled, customRunner, runnerSize
    }

    private let defaults = UserDefaults.standard

    /// 공식 사용량 연동 on/off (기본 on). 끄면 세션·주간 게이지를 비우고 로컬 통계만 보인다.
    @Published var officialEnabled: Bool { didSet { save(officialEnabled, .officialEnabled) } }

    @Published var sensitivity: Thresholds.Sensitivity { didSet { save(sensitivity.rawValue, .sensitivity) } }

    @Published var pollInterval: Double { didSet { save(pollInterval, .pollInterval) } }

    /// 80%/95% 한도 알림 (기본 on).
    @Published var limitAlertsEnabled: Bool { didSet { save(limitAlertsEnabled, .limitAlertsEnabled) } }

    /// 5시간 블록 리셋 알림 (§F4 — 기본 off).
    @Published var newSessionAlertEnabled: Bool { didSet { save(newSessionAlertEnabled, .newSessionAlertEnabled) } }
    /// ⌃⌥U로 어디서든 사용량 창 열기 (기본 켬).
    @Published var globalHotKeyEnabled: Bool { didSet { save(globalHotKeyEnabled, .globalHotKeyEnabled) } }
    /// 주간 사용량이 초기화되면 알림 (기본 끔).
    @Published var weeklyResetAlertEnabled: Bool { didSet { save(weeklyResetAlertEnabled, .weeklyResetAlertEnabled) } }
    /// 사용량 창이 닫혀 있을 때 1분 넘게 걸린 Claude 작업이 끝나면 알린다.
    @Published var claudeDoneAlertEnabled: Bool { didSet { save(claudeDoneAlertEnabled, .claudeDoneAlertEnabled) } }
    /// 한 주가 끝나면 지난주 사용량 요약을 알린다.
    @Published var weeklySummaryEnabled: Bool { didSet { save(weeklySummaryEnabled, .weeklySummaryEnabled) } }

    /// 메뉴바 러너 종류와 색상 (색은 코드로 그린 러너에만 적용).
    @Published var runner: Runner { didSet { save(runner.rawValue, .runner) } }
    @Published var spriteTheme: SpriteTheme { didSet { save(spriteTheme.rawValue, .spriteTheme) } }

    /// 내 러너(사용자가 불러온 그림), Petdex 펫을 쓰는 중이면 그 id. 기본 러너를 고르면 nil.
    @Published var customRunnerID: String? { didSet { save(customRunnerID ?? "", .customRunner) } }

    /// 지금 그릴 러너. 내 러너를 지웠으면 기본 러너로 돌아간다.
    var character: RunnerCharacter {
        CustomRunnerStore.shared.runner(id: customRunnerID)?.character
            ?? PetdexStore.shared.pet(storageID: customRunnerID).flatMap(PetdexStore.shared.character(for:))
            ?? runner.character
    }

    /// 지금 러너를 가리키는 이름. 내 고스트에 남겨, 고스트가 그 판을 달린 러너 모습으로 보이게 한다.
    var runnerID: String { customRunnerID ?? runner.rawValue }

    /// 남에게 보내도 되는 러너 이름. 기본 러너와 Petdex 펫만 (내 그림은 이 Mac 밖으로 보내지 않는다).
    var shareableRunnerID: String? {
        guard let custom = customRunnerID else { return runner.rawValue }
        return custom.hasPrefix(PetdexStore.storageID("")) ? custom : nil
    }

    /// 러너 이름으로 모습을 찾는다. 이 Mac에 없는 러너(받지 않은 펫 등)면 nil.
    static func character(forRunnerID id: String?) -> RunnerCharacter? {
        guard let id else { return nil }
        if let runner = Runner(rawValue: id) { return runner.character }
        return CustomRunnerStore.shared.runner(id: id)?.character
            ?? PetdexStore.shared.pet(storageID: id).flatMap(PetdexStore.shared.character(for:))
    }

    func select(_ runner: Runner) {
        customRunnerID = nil
        self.runner = runner
    }

    func select(_ custom: CustomRunner) {
        customRunnerID = custom.id
    }

    /// 메뉴바 애니메이션 fps 상한 (기본 30fps).
    @Published var smoothness: SpriteSmoothness { didSet { save(smoothness.rawValue, .smoothness) } }

    /// 가끔 혼자 장난치기 (점프, 하트, 춤 등). 끄면 상태가 바뀔 때만 움직임이 달라진다.
    @Published var tricksEnabled: Bool { didSet { save(tricksEnabled, .tricksEnabled) } }

    /// 메뉴바 러너 크기 (기본 크게).
    @Published var runnerSize: RunnerSize { didSet { save(runnerSize.rawValue, .runnerSize) } }

    /// 메뉴바 고양이 옆에 띄울 사용률 (기본 끔).
    @Published var menuBarLabel: MenuBarLabel {
        didSet {
            save(menuBarLabel.rawValue, .menuBarLabel)
            if menuBarLabel != .off { save(menuBarLabel.rawValue, .menuBarLabelLast) }
        }
    }

    /// 메뉴바 사용률 켜기/끄기. 켤 때는 마지막에 고른 값(처음엔 높은 쪽)을 다시 쓴다.
    var showsMenuBarLabel: Bool {
        get { menuBarLabel != .off }
        set {
            let last = MenuBarLabel(rawValue: UserDefaults.standard.string(forKey: Key.menuBarLabelLast.rawValue) ?? "")
            menuBarLabel = newValue ? (last ?? .higher) : .off
        }
    }

    /// 로그인 시 자동 시작 (SMAppService, 번들 앱에서만 동작). 시스템 상태가 원본이라 저장하지 않는다.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !syncingLaunchAtLogin else { return }
            do { try LaunchAtLogin.set(launchAtLogin) }
            catch { launchAtLogin = oldValue }   // 실패 시 토글 원복
        }
    }
    private var syncingLaunchAtLogin = false

    /// 시스템 설정 > 로그인 항목에서 바꾼 값을 토글에 다시 읽어 온다. 시스템 상태를 건드리지 않는다.
    func reloadLaunchAtLogin() {
        let current = LaunchAtLogin.isEnabled
        guard current != launchAtLogin else { return }
        syncingLaunchAtLogin = true
        launchAtLogin = current
        syncingLaunchAtLogin = false
    }

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: Key, _ fallback: Bool) -> Bool { d.object(forKey: key.rawValue) as? Bool ?? fallback }
        func string(_ key: Key) -> String { d.string(forKey: key.rawValue) ?? "" }

        officialEnabled = bool(.officialEnabled, true)
        sensitivity = Thresholds.Sensitivity(rawValue: string(.sensitivity)) ?? .normal
        let poll = d.double(forKey: Key.pollInterval.rawValue)
        pollInterval = poll > 0 ? poll : 3.0
        limitAlertsEnabled = bool(.limitAlertsEnabled, true)
        newSessionAlertEnabled = bool(.newSessionAlertEnabled, false)
        weeklyResetAlertEnabled = bool(.weeklyResetAlertEnabled, false)
        claudeDoneAlertEnabled = bool(.claudeDoneAlertEnabled, true)
        weeklySummaryEnabled = bool(.weeklySummaryEnabled, true)
        globalHotKeyEnabled = bool(.globalHotKeyEnabled, true)
        runner = Runner(rawValue: string(.runner)) ?? .cat
        // 산 적 없는 상점 색은 기본으로 (설정 파일을 직접 고친 경우)
        spriteTheme = SpriteTheme(rawValue: string(.spriteTheme)) ?? .auto
        // 내 러너 목록에서 사라진 id는 버린다 (그대로 두면 메뉴·고르기에서 아무 것도 선택되지 않아 보인다)
        let savedCustom = string(.customRunner)
        let known = CustomRunnerStore.shared.runner(id: savedCustom) != nil
            || PetdexStore.shared.pet(storageID: savedCustom) != nil
        customRunnerID = known ? savedCustom : nil
        smoothness = SpriteSmoothness(rawValue: string(.smoothness)) ?? .smooth
        tricksEnabled = bool(.tricksEnabled, true)
        let label = MenuBarLabel(rawValue: string(.menuBarLabel)) ?? .off
        menuBarLabel = label
        // 이 키가 생기기 전에 고른 값도 끄고 다시 켰을 때 돌아오게 (init에서는 didSet이 불리지 않는다)
        if label != .off, string(.menuBarLabelLast).isEmpty { d.set(label.rawValue, forKey: Key.menuBarLabelLast.rawValue) }
        runnerSize = RunnerSize(rawValue: string(.runnerSize)) ?? .large
        LaunchAtLogin.restoreAfterRename()
        LaunchAtLogin.enableOnFirstInstall()
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}

/// 메뉴바 고양이 옆 사용률 표시.
enum MenuBarLabel: String, CaseIterable {
    case off, session, weekly, higher

    var displayName: String {
        switch self {
        case .off: return "끔"
        case .session: return "세션"
        case .weekly: return "주간"
        case .higher: return "높은 쪽"
        }
    }
}

/// 메뉴바 러너 크기. 메뉴바 높이는 정해져 있어 크게는 효과 자리로 남긴 위아래 여백만 줄여 키운다.
/// 키운 만큼 칸이 옆으로 넓어지고, 칸 위아래를 벗어나는 장난은 그 순간만 줄여 그린다 (MenuBarCanvas).
enum RunnerSize: String, CaseIterable {
    case compact, full, large

    var displayName: String {
        switch self {
        case .compact: return "작게"
        case .full: return "보통"
        case .large: return "크게"
        }
    }

    var zoom: CGFloat {
        switch self {
        case .compact: return 0.8
        case .full: return 1
        case .large: return 1.1
        }
    }
}
