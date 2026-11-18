import Cocoa

/// RunTime이 창 배치를 켜고 끄고 설정하는 입구. Rectangle의 AppDelegate가 하던 일(관리자 만들기, 메뉴, URL, 설정 파일)을 맡는다.
public final class WindowControl {
    public static let shared = WindowControl()

    /// 켜짐·단축키 등록 실패·설정이 바뀌면 부른다 (설정 화면 다시 그리기).
    public var onChange: () -> Void = {}
    /// RunTime이 이미 쓰는 단축키(사용량 열기 등). 기본 묶음에서 이와 겹치는 명령은 비워 둔다.
    public var reservedKeys: () -> [WindowKey] = { [] }

    public var running: Bool { started && !WindowRuntime.paused }

    private var started = false
    private var windowManager: WindowManager!
    private var shortcutManager: ShortcutManager!
    private(set) var applicationToggle: ApplicationToggle!
    private var snappingManager: SnappingManager!
    private var stackBadgeManager: StackBadgeManager!
    private var titleBarManager: TitleBarManager!
    private var greenButtonManager: GreenButtonManager!
    private var newWindowManager: NewWindowActionManager!
    private let binder = MASShortcutBinder.shared()!

    private init() {
        Self.trimHiddenSettings()
        firstRun()
        binder.onFailuresChanged = { [weak self] in self?.onChange() }
        for name in [Notification.Name.configImported, .changeDefaults, .todoMenuToggled, .stackBadgeChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.onChange() }
        }
    }

    /// 설정 화면에서 뺀 설정(겹친 창 표시, 할 일 모드, 미리보기 꾸미기 등)을 예전 화면에서 바꿔 두었으면
    /// 보이지 않는 채로 계속 적용되므로 한 번 지워 기본값으로 돌린다. Defaults는 처음 읽을 때 값을 들고 있어
    /// Defaults를 읽기 전에 저장소에서 지운다.
    private static func trimHiddenSettings() {
        let store = WindowDefaults.store
        let doneKey = "hiddenSettingsTrimmed"
        guard !store.bool(forKey: doneKey) else { return }
        let suite = ProcessInfo.processInfo.environment["RUNTIME_WINDOW_DEFAULTS"] ?? "dev.runtime.RunTime.window"
        let shown: Set<String> = ["windowSnapping", "subsequentExecutionMode", "gapSize", "experimentalWindowAnimations",
                                  "alternateDefaultShortcuts", "disabledApps", "lastVersion", "installVersion", "allowAnyShortcut",
                                  "internalTilingNotified", "notifiedOfProblemApps", "savedLayouts", "savedLayouts.unreadable",
                                  "reservedClearedShortcuts", "commandPalette"]
        let shortcuts = Set(WindowAction.active.map(\.name))
        for key in store.persistentDomain(forName: suite)?.keys ?? [:].keys
        where !shown.contains(key) && !shortcuts.contains(key) && !key.hasPrefix("layout.") {
            store.removeObject(forKey: key)
        }
        store.set(true, forKey: doneKey)
    }

    /// Rectangle의 checkVersion과 환영 창에서 '권장'을 고른 것과 같다: ⌃⌥ 묶음, 거듭 누르면 옆 모니터로.
    private func firstRun() {
        if Defaults.lastVersion.value == nil {
            // 가운데 2/3 기본 단축키(⌃⌥R)는 설치 버전이 94보다 새로울 때만 준다
            Defaults.installVersion.value = "100"
            Defaults.allowAnyShortcut.enabled = true
            Defaults.alternateDefaultShortcuts.enabled = true
            Defaults.subsequentExecutionMode.value = .acrossMonitor
        }
        MASShortcutMigration.syncRenamedSideShortcutAliases()
        Defaults.lastVersion.value = "100"
    }

    public static var trusted: Bool { AXIsProcessTrusted() }

    /// 손쉬운 사용 권한을 묻는 시스템 창을 띄운다. 이미 허용했으면 아무것도 하지 않는다.
    public static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - 켜고 끄기

    /// 권한이 없으면 false.
    @discardableResult
    public func start() -> Bool {
        guard Self.trusted else { return false }
        guard !running else { return true }
        WindowRuntime.paused = false
        clearReservedDefaults()
        if !started {
            started = true
            // Rectangle AppDelegate.accessibilityTrusted()와 같은 차례
            _ = WindowCalculationFactory()
            windowManager = WindowManager()
            shortcutManager = ShortcutManager(windowManager: windowManager)
            applicationToggle = ApplicationToggle(shortcutManager: shortcutManager)
            snappingManager = SnappingManager()
            stackBadgeManager = StackBadgeManager()
            titleBarManager = TitleBarManager()
            greenButtonManager = GreenButtonManager()
            newWindowManager = NewWindowActionManager()
            initializeTodo(false)
            WindowLayouts.shared.start()
            checkForProblematicApps()
        } else {
            refreshManagers()
            shortcutManager.bindShortcuts()
            initializeTodo(false)
        }
        bindExtras()
        binder.refreshAll()
        MacTilingDefaults.checkForBuiltInTiling(skipIfAlreadyNotified: true)
        onChange()
        return true
    }

    public func stop() {
        guard running else { return }
        WindowRuntime.paused = true
        shortcutManager.unbindShortcuts()
        binder.refreshAll()
        refreshManagers()
        onChange()
    }

    /// RunTime이 더한 명령(포커스·조금씩 옮기기)을 달고, 누르고 있으면 되풀이할 키를 정한다.
    private func bindExtras() {
        for command in WindowExtraCommand.allCases {
            binder.bindShortcut(withDefaultsKey: command.slot.defaultsKey) { command.perform() }
        }
        binder.repeatingKeys = Set([WindowAction.larger, .smaller, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight].map(\.name)
            + WindowExtraCommand.allCases.filter(\.repeats).map(\.slot.defaultsKey))
    }

    /// 쉬는 중 표시를 바꾼 뒤 각 관리자가 감시를 다시 판단하게 한다.
    private func refreshManagers() {
        Notification.Name.windowSnapping.post()
        Notification.Name.windowTitleBar.post()
        Notification.Name.greenButtonOverride.post()
        Notification.Name.stackBadgeChanged.post()
        newWindowManager.reloadFromDefaults()
    }

    func initializeTodo(_ bringToFront: Bool = true) {
        TodoManager.registerUnregisterToggleShortcut()
        TodoManager.registerUnregisterReflowShortcut()
        TodoManager.startReflowOnDisplayChanges()
        TodoManager.moveAllIfNeeded(bringToFront)
    }

    /// 드래그 감시와 잘 맞지 않는 앱이 깔려 있으면 한 번 알린다 (Rectangle checkForProblematicApps).
    private func checkForProblematicApps() {
        guard !Defaults.windowSnapping.userDisabled, !Defaults.notifiedOfProblemApps.enabled else { return }
        let ids = ["com.mathworks.matlab", "com.live2d.cubism.CECubismEditorApp", "com.aquafold.datastudio.DataStudio",
                   "com.adobe.illustrator", "com.adobe.AfterEffects"]
        let names = ids.compactMap { id -> String? in
            guard !applicationToggle.isDisabled(bundleId: id),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return FileManager.default.displayName(atPath: url.path)
        }
        guard !names.isEmpty else { return }
        Defaults.notifiedOfProblemApps.enabled = true
        AlertUtil.oneButtonAlert(question: "끌어다 붙이기와 잘 맞지 않는 앱이 있습니다",
                                 text: names.joined(separator: "\n") + "\n\n이 앱들에서 창을 끌 때 문제가 생기면 설정 > 창 배치에서 '쓰지 않을 앱'에 넣거나 끌어다 붙이기를 끄세요.")
    }

    /// 다른 창 배치 앱이 켜져 있으면 단축키가 겹친다 (Rectangle checkForConflictingApps).
    public var conflictingApps: [String] {
        let known = ["com.knollsoft.Rectangle": "Rectangle", "com.knollsoft.Hookshot": "Rectangle Pro",
                     "com.divisiblebyzero.Spectacle": "Spectacle", "com.crowdcafe.windowmagnet": "Magnet",
                     "com.hegenberg.BetterSnapTool": "BetterSnapTool", "com.manytricks.Moom": "Moom"]
        return NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.flatMap { known[$0] } }
    }

    // MARK: - 실행

    /// 메뉴·명령 찾기에서 바로 실행한다. 앞에 있는 창에 한다.
    public func run(_ command: WindowCommand) {
        guard running else { return }
        command.action.postMenu()
    }

    /// runtime-window://execute-action?name=left-half, runtime-window://execute-task?name=ignore-app&app-bundle-id=…
    /// - Returns: 창 배치 URL이었는지
    /// 창 배치 주소인지만 본다 (켜져 있는지는 보지 않는다).
    public static func isWindowURL(_ url: URL) -> Bool {
        ["execute-action", "execute-task"].contains(url.host ?? "")
    }

    @discardableResult
    public func handle(url: URL, confirm: (String) -> Bool) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true), components.path.isEmpty,
              ["execute-action", "execute-task"].contains(components.host) else { return false }
        let name = components.queryItems?.first { $0.name == "name" }?.value
        func urlName(_ name: String) -> String { name.map { $0.isUppercase ? "-" + $0.lowercased() : String($0) }.joined() }
        switch (components.host, name) {
        case ("execute-action", let name?):
            let action = WindowAction.active.first { ($0.aliasName.map(urlName) == name) || urlName($0.name) == name }
            if running { action?.postUrl() }
        case ("execute-task", "ignore-app"), ("execute-task", "unignore-app"):
            guard running, let id = components.queryItems?.first(where: { $0.name == "app-bundle-id" })?.value ?? ApplicationToggle.frontAppId,
                  !id.isEmpty else { break }
            let ignore = name == "ignore-app"
            guard confirm("\(ignore ? "쓰지 않을 앱에 넣기" : "쓰지 않을 앱에서 빼기"): \(id)") else { break }
            ignore ? applicationToggle.disableApp(appBundleId: id) : applicationToggle.enableApp(appBundleId: id)
            onChange()
        case ("execute-task", "save-layout"), ("execute-task", "restore-layout"):
            guard running, let layout = components.queryItems?.first(where: { $0.name == "layout" })?.value?
                .trimmingCharacters(in: .whitespaces), !layout.isEmpty else { break }
            if name == "restore-layout" {
                WindowLayouts.shared.restore(named: layout)
            } else if !WindowLayouts.shared.saved.contains(where: { $0.name == layout }) || confirm("‘\(layout)’ 배치를 지금 창 자리로 바꾸기") {
                // 이미 있는 배치를 덮어쓰면 되돌릴 수 없어 묻는다
                WindowLayouts.shared.save(named: layout)
            }
        default:
            break
        }
        return true
    }

    // MARK: - 설정 (설정 화면에 두는 몇 가지만. 나머지 Rectangle 설정은 기본값 그대로 쓴다)

    /// 창을 화면 가장자리·모서리로 끌면 붙이기.
    public var snapping: Bool {
        get { !Defaults.windowSnapping.userDisabled }
        set {
            Defaults.windowSnapping.enabled = newValue
            Notification.Name.windowSnapping.post()
            onChange()
        }
    }

    /// 같은 단축키를 거듭 누를 때.
    public var repeatMode: WindowRepeatMode {
        get {
            switch Defaults.subsequentExecutionMode.value {
            case .acrossMonitor, .acrossAndResize, .cycleMonitor: return .nextDisplay
            case .none: return .nothing
            default: return .resize
            }
        }
        set {
            Defaults.subsequentExecutionMode.value = newValue.mode
            onChange()
        }
    }

    /// 창 사이와 화면 가장자리 여백 (pt).
    public var gapSize: Double {
        get { Double(Defaults.gapSize.value) }
        set {
            Defaults.gapSize.value = Float(max(0, newValue.rounded()))
            onChange()
        }
    }

    /// 창을 옮길 때 미끄러지듯 움직이기.
    public var animations: Bool {
        get { Defaults.experimentalWindowAnimations.enabled }
        set {
            Defaults.experimentalWindowAnimations.enabled = newValue
            Notification.Name.windowAnimationPreferencesChanged.post()
            onChange()
        }
    }

    // MARK: - macOS 창 정렬

    /// macOS 15부터 들어간 기본 창 정렬(가장자리로 끌기)이 켜져 있어 끌어다 붙이기와 겹치는지.
    public var macTilingConflicts: Bool {
        running && !Defaults.windowSnapping.userDisabled
            && (MacTilingDefaults.tilingByEdgeDrag.enabled || MacTilingDefaults.tilingOptionAccelerator.enabled)
    }

    public func disableMacTiling() {
        MacTilingDefaults.tilingByEdgeDrag.disable()
        MacTilingDefaults.tilingOptionAccelerator.disable()
        MacTilingDefaults.topTilingByEdgeDrag.disable()
        onChange()
    }

    // MARK: - 쓰지 않을 앱

    /// 앞에 있는 앱. 메뉴바 메뉴를 열어도 앞 앱은 그대로라 그 앱을 가리킨다.
    /// (Rectangle의 ApplicationToggle은 앱을 한 번 바꾸기 전까지 처음 값을 들고 있어 바로 묻는다)
    private var frontApp: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
    }

    public var frontAppName: String? { frontApp?.localizedName }
    public var frontAppIgnored: Bool { frontApp?.bundleIdentifier.map { ignoredApps.contains($0) } ?? false }

    public func toggleFrontApp() {
        guard running, let id = frontApp?.bundleIdentifier else { return }
        frontAppIgnored ? applicationToggle.enableApp(appBundleId: id) : applicationToggle.disableApp(appBundleId: id)
        onChange()
    }

    /// 단축키와 끌어다 붙이기를 쓰지 않을 앱의 번들 ID.
    public var ignoredApps: [String] {
        get { (Defaults.disabledApps.typedValue ?? []).sorted() }
        set {
            Defaults.disabledApps.typedValue = Set(newValue)
            applicationToggle?.reloadFromDefaults()
            onChange()
        }
    }

    // MARK: - 단축키

    public var preset: WindowKeyPreset {
        get { Defaults.alternateDefaultShortcuts.enabled ? .rectangle : .spectacle }
        set {
            Defaults.alternateDefaultShortcuts.enabled = newValue == .rectangle
            resetKeys()
        }
    }

    public func key(for slot: WindowShortcutSlot) -> WindowKey? {
        MASShortcutBinder.storedShortcut(forKey: slot.defaultsKey).map(WindowKey.init)
    }

    public func key(for command: WindowCommand) -> WindowKey? { key(for: WindowShortcutSlot(command)) }

    /// nil이면 지운다. 같은 조합을 여러 명령에 주면 누를 때마다 차례로 돈다 (Rectangle과 같다).
    public func setKey(_ key: WindowKey?, for slot: WindowShortcutSlot) {
        let value = key.flatMap { MASDictionaryTransformer().reverseTransformedValue($0.shortcut) } ?? [String: Any]()
        WindowDefaults.store.set(value, forKey: slot.defaultsKey)
        onChange()
    }

    /// 모든 명령과 주어진 자리의 지금 단축키 (설정 화면이 한 번 그릴 때 한 번만 읽는다).
    public func keyTable(extra: [WindowShortcutSlot]) -> WindowKeyTable {
        let slots = WindowCommand.all.map(WindowShortcutSlot.init) + extra
        var keys: [String: WindowKey] = [:]
        for slot in slots { keys[slot.defaultsKey] = key(for: slot) }
        return WindowKeyTable(slots: slots, keys: keys, failed: failedSlots)
    }

    /// 이 조합을 함께 쓰는 다른 명령 (명령끼리는 누를 때마다 차례로 돈다).
    public func sharing(_ key: WindowKey, except slot: WindowShortcutSlot) -> [WindowShortcutSlot] {
        guard slot.isCommand else { return [] }
        return WindowCommand.all.map(WindowShortcutSlot.init).filter { $0 != slot && self.key(for: $0) == key }
    }

    /// 이 조합과 겹쳐 둘 중 하나만 동작하는 RunTime 안의 다른 자리 (명령 찾기·할 일 모드·배치 단축키, 또는 명령과 그것들).
    public func clashing(_ key: WindowKey, except slot: WindowShortcutSlot, among others: [WindowShortcutSlot]) -> [WindowShortcutSlot] {
        let all = WindowCommand.all.map(WindowShortcutSlot.init) + others
        return all.filter { $0 != slot && ($0.isCommand != slot.isCommand || !slot.isCommand) && self.key(for: $0) == key }
    }

    /// 이 묶음을 고르면 쓰게 될 명령 단축키 (점검용). 사용자가 직접 정한 것은 그대로, 나머지는 묶음 기본값에서 예약 키를 뺀 것.
    public func effectiveKeys(preset: WindowKeyPreset) -> [(title: String, key: WindowKey)] {
        let reserved = Set(reservedKeys())
        let stored = WindowDefaults.store.persistentDomain(forName: suiteName) ?? [:]
        let cleared = Set(WindowDefaults.store.stringArray(forKey: Self.reservedClearedKey) ?? [])
        return WindowAction.active.compactMap { action in
            if stored[action.name] != nil, !cleared.contains(action.name) {
                return MASShortcutBinder.storedShortcut(forKey: action.name).map { (action.koreanTitle, WindowKey($0)) }
            }
            guard let preset = preset == .rectangle ? action.alternateDefault : action.spectacleDefault else { return nil }
            let key = WindowKey(MASShortcut(keyCode: preset.keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: preset.modifierFlags)))
            return reserved.contains(key) ? nil : (action.koreanTitle, key)
        }
    }

    /// 지금 쓰는 단축키 전부 (점검용): 명령, RunTime이 더한 명령, 할 일 모드 등.
    public var boundKeys: [(title: String, key: WindowKey)] {
        let slots = WindowCommand.all.map(WindowShortcutSlot.init) + WindowExtraCommand.allCases.map(\.slot)
        return slots.compactMap { slot in key(for: slot).map { (slot.title, $0) } }
    }

    /// RunTime이 더하는 단축키(명령 찾기 등)를 단다. 사용자가 정한 적 없으면 기본 조합을 쓴다. 창 배치가 꺼지면 같이 쉰다.
    public func bindExtra(_ slot: WindowShortcutSlot, default key: WindowKey?, action: @escaping () -> Void) {
        if let key { binder.registerDefaultShortcuts([slot.defaultsKey: key.shortcut]) }
        binder.bindShortcut(withDefaultsKey: slot.defaultsKey, toAction: action)
    }

    /// 직접 바꾼 명령 단축키를 지우고 기본 묶음으로 돌린다.
    public func resetKeys() {
        for action in WindowAction.active { WindowDefaults.store.removeObject(forKey: action.name) }
        WindowDefaults.store.removeObject(forKey: Self.reservedClearedKey)
        Notification.Name.changeDefaults.post()
        clearReservedDefaults()
        onChange()
    }

    /// 등록하지 못한 자리 (다른 앱이 같은 조합을 먼저 잡음).
    public var failedSlots: Set<String> { running ? binder.failedKeys : [] }

    /// 단축키를 새로 기록하는 동안 모두 놓는다. 잡고 있으면 같은 조합을 눌렀을 때 Carbon이 먼저 가져간다.
    public func suspendKeys() {
        Notification.Name.shortcutRecording.post(object: true)
        WindowRuntime.recording = true
        binder.refreshAll()
    }

    public func resumeKeys() {
        WindowRuntime.recording = false
        Notification.Name.shortcutRecording.post(object: false)
        binder.refreshAll()
    }

    /// 사용량 열기 단축키 같은 RunTime 단축키를 바꾸면 부른다. 비워 둔 기본값을 다시 판단한다.
    public func reservedKeysChanged() {
        clearReservedDefaults()
        onChange()
    }

    private static let reservedClearedKey = "reservedClearedShortcuts"

    /// 사용자가 정하지 않았는데 기본 묶음이 RunTime 단축키와 겹치면 비워 둔다 (⌃⌥ 묶음의 왼쪽 위 ⌃⌥U).
    /// 비운 명령은 따로 적어 두었다가, 더는 겹치지 않으면 기본값으로 돌린다.
    private func clearReservedDefaults() {
        let reserved = Set(reservedKeys())
        var cleared = Set(WindowDefaults.store.stringArray(forKey: Self.reservedClearedKey) ?? [])
        for action in WindowAction.active {
            let preset = (Defaults.alternateDefaultShortcuts.enabled ? action.alternateDefault : action.spectacleDefault)
                .map { WindowKey(MASShortcut(keyCode: $0.keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: $0.modifierFlags))) }
            let clashes = preset.map(reserved.contains) ?? false
            let userSet = WindowDefaults.store.persistentDomain(forName: suiteName)?[action.name] != nil
            if cleared.contains(action.name) {
                guard !clashes else { continue }
                // 우리가 비운 것만 되돌린다. 그 뒤 사용자가 직접 정했으면 그대로 둔다
                if (WindowDefaults.store.dictionary(forKey: action.name) ?? [:]).isEmpty {
                    WindowDefaults.store.removeObject(forKey: action.name)
                }
                cleared.remove(action.name)
            } else if clashes && !userSet {
                WindowDefaults.store.set([String: Any](), forKey: action.name)
                cleared.insert(action.name)
            }
        }
        WindowDefaults.store.set(Array(cleared).sorted(), forKey: Self.reservedClearedKey)
    }

    private var suiteName: String {
        ProcessInfo.processInfo.environment["RUNTIME_WINDOW_DEFAULTS"] ?? "dev.runtime.RunTime.window"
    }

    // MARK: - 설정 파일

    /// Rectangle과 같은 형식의 JSON. Rectangle에서 내보낸 파일도 그대로 읽는다.
    public func exportConfig() -> String? { Defaults.encoded() }

    public func importConfig(from url: URL) {
        Notification.Name.windowSnapping.post(object: false)
        Defaults.load(fileUrl: url)
        Notification.Name.windowSnapping.post(object: true)
        clearReservedDefaults()
        onChange()
    }

    /// 이 Mac에 깔린 Rectangle의 설정(단축키 포함)을 읽어 온다. Rectangle을 쓰다 옮겨 올 때.
    public var rectangleSettingsAvailable: Bool {
        !(UserDefaults(suiteName: "com.knollsoft.Rectangle")?.dictionaryRepresentation().keys
            .filter { $0 == "leftHalf" || $0 == "subsequentExecutionMode" || $0 == "alternateDefaultShortcuts" }.isEmpty ?? true)
    }

    public func importRectangleSettings() {
        guard let rectangle = CFPreferencesCopyMultiple(nil, "com.knollsoft.Rectangle" as CFString,
                                                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        else { return }
        // 값은 각 Default가 메모리에도 들고 있어, 설정 파일 가져오기와 같은 길(load(from:))로 넣는다
        for setting in Defaults.array {
            guard let raw = rectangle[setting.key], let codable = Self.codable(raw, like: setting) else { continue }
            setting.load(from: codable)
        }
        let shortcutKeys = Set(WindowAction.active.map(\.name) + WindowShortcutSlot.extras.map(\.defaultsKey))
        for (key, value) in rectangle where shortcutKeys.contains(key) {
            WindowDefaults.store.set(value, forKey: key)
        }
        clearReservedDefaults()
        Notification.Name.configImported.post()
        Notification.Name.changeDefaults.post()
        onChange()
    }
}

extension WindowControl {
    /// 그 설정이 쓰는 형(toCodable이 채우는 칸)에 맞춰 plist 값을 담는다.
    static func codable(_ raw: Any, like setting: Default) -> CodableDefault? {
        let shape = setting.toCodable()
        if let text = raw as? String { return CodableDefault(string: text) }
        guard let number = raw as? NSNumber else { return nil }
        if shape.bool != nil { return CodableDefault(bool: number.boolValue) }
        if shape.int != nil { return CodableDefault(int: number.intValue) }
        if shape.float != nil { return CodableDefault(float: number.floatValue) }
        if shape.double != nil { return CodableDefault(double: number.doubleValue) }
        return nil
    }
}

/// 한 번 읽어 둔 단축키 표. 칸마다 겹침·번갈아 하기를 따지면서 저장소를 다시 읽지 않는다.
public struct WindowKeyTable {
    let slots: [WindowShortcutSlot]
    let keys: [String: WindowKey]
    let failed: Set<String>

    public func key(for slot: WindowShortcutSlot) -> WindowKey? { keys[slot.defaultsKey] }

    /// 칸에 띄울 문제 (겹침, 다른 앱이 잡음, 번갈아 하기). 없으면 nil.
    public func problem(for slot: WindowShortcutSlot) -> String? {
        guard let key = keys[slot.defaultsKey] else { return nil }
        let same = slots.filter { $0 != slot && keys[$0.defaultsKey] == key }
        let clashes = same.filter { $0.isCommand != slot.isCommand || !slot.isCommand }
        if !clashes.isEmpty { return "‘\(clashes.map(\.title).joined(separator: ", "))’와 겹쳐 하나만 동작합니다" }
        if failed.contains(slot.defaultsKey) { return "다른 앱이 이 조합을 쓰고 있어 동작하지 않습니다" }
        let cycles = same.filter(\.isCommand)
        if slot.isCommand && !cycles.isEmpty { return "누를 때마다 ‘\(cycles.map(\.title).joined(separator: ", "))’와 번갈아 합니다" }
        return nil
    }
}

public enum WindowRepeatMode: String, CaseIterable, Identifiable {
    case resize, nextDisplay, nothing
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .resize: return "크기 바꾸기"
        case .nextDisplay: return "옆 모니터로"
        case .nothing: return "그대로"
        }
    }
    public var detail: String {
        switch self {
        case .resize: return "왼쪽 절반을 또 누르면 2/3, 1/3로 바뀝니다."
        case .nextDisplay: return "왼쪽 절반을 또 누르면 왼쪽 모니터로 넘어갑니다."
        case .nothing: return "또 눌러도 그 자리에 둡니다."
        }
    }
    var mode: SubsequentExecutionMode {
        switch self {
        case .resize: return .resize
        case .nextDisplay: return .acrossAndResize
        case .nothing: return .none
        }
    }
}

public enum WindowKeyPreset: String, CaseIterable, Identifiable {
    case rectangle, spectacle
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .rectangle: return "⌃⌥ 묶음 (Rectangle 권장)"
        case .spectacle: return "⌥⌘ 묶음 (Spectacle)"
        }
    }
}
