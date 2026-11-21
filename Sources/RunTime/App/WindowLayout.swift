import AppKit
import WindowKit

/// 창 배치(Rectangle에서 옮긴 기능)를 켜고 끈다. 손쉬운 사용 권한이 있어야 창을 옮길 수 있어,
/// 켰는데 권한이 없으면 허용할 때까지 1초마다 보고 허용하는 대로 시작한다.
final class WindowLayout: ObservableObject {
    static let shared = WindowLayout()

    private static let enabledKey = "windowLayoutEnabled"
    private static let statusIconKey = "windowLayoutStatusIcon"
    private let control = WindowControl.shared
    private var waitTimer: Timer?
    private var statusItem: NSStatusItem?
    /// 앱이 주소로 처음 켜지면 창 배치가 시작되기 전에 주소가 온다. 시작한 뒤 처리한다.
    private var pendingURLs: [URL] = []
    let menu = WindowMenu()

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? begin(prompt: true) : end()
        }
    }
    /// Rectangle처럼 메뉴바에 창 배치 아이콘을 따로 둔다 (기본 켬). 꺼도 RunTime 아이콘 오른쪽 클릭 메뉴에 남는다.
    @Published var statusIcon: Bool {
        didSet {
            UserDefaults.standard.set(statusIcon, forKey: Self.statusIconKey)
            updateStatusItem()
        }
    }
    @Published private(set) var trusted = WindowControl.trusted
    @Published private(set) var running = false
    /// 설정 화면을 다시 그리게 하는 신호 (단축키·설정·배치가 바뀜).
    @Published private(set) var revision = 0

    var openSettings: () -> Void = {} {
        didSet { menu.openSettings = openSettings }
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        statusIcon = UserDefaults.standard.object(forKey: Self.statusIconKey) as? Bool ?? true
        // RunTime 단축키와 겹치는 창 배치 기본값은 비워 둔다: 사용량 열기(⌃⌥U, ⌃⌥ 묶음의 왼쪽 위), 한 줄 적기(⌃⌥L),
        // 펫이 창 배치에 ⌃⌥ 방향키를 내주고 물러나는 ⌃⌥⇧ 방향키·스페이스 (⌃⌥ 묶음의 높이만 최대화가 ⌃⌥⇧↑다)
        control.reservedKeys = { Self.reservedKeys }
        let changed = { [weak self] in
            guard let self else { return }
            self.running = self.control.running
            self.revision += 1
        }
        control.onChange = changed
        WindowLayouts.shared.onChange = changed
        WindowLayouts.shared.onRestore = { layout, moved, missing in
            let skipped = missing.isEmpty ? "" : " 실행 중이 아니라 건너뜀: \(missing.joined(separator: ", "))"
            Notifier.shared.send(title: "창 배치", body: "‘\(layout.name)’ 배치로 창 \(moved)개를 옮겼습니다.\(skipped)")
        }
        WindowLayouts.shared.onScreenRestore = { moved in
            Notifier.shared.send(title: "창 배치", body: "모니터 구성이 바뀌어 창 \(moved)개를 이 구성에서 쓰던 자리로 옮겼습니다.")
        }
        menu.openPalette = { WindowPalette.shared.show() }
    }

    static var reservedKeys: [WindowKey] {
        [GlobalHotKey.shared.combo, GlobalHotKey.quickCombo].map { WindowKey(carbonKeyCode: $0.keyCode, carbonModifiers: $0.modifiers) }
            + PetKeys.fallbackKeys + Clipboard.reservedKeys
    }

    /// 앱을 켤 때 부른다. 켜 둔 채 권한이 풀렸으면 묻지 않고 기다린다 (켤 때마다 시스템 창이 뜨지 않게).
    func launch() {
        if enabled { begin(prompt: false) }
    }

    func requestAccess() {
        WindowControl.requestAccess()
        WindowControl.openAccessibilitySettings()
        waitForTrust()
    }

    /// runtime-window://… 창 배치 URL. 다른 앱이 보낸 '쓰지 않을 앱' 바꾸기는 묻고 한다.
    func open(_ url: URL) -> Bool {
        guard WindowControl.isWindowURL(url) else { return false }
        guard running else {
            if enabled {
                pendingURLs.append(url)
            } else {
                Notifier.shared.send(title: "창 배치", body: "창 배치가 꺼져 있어 주소로 온 명령을 하지 않았습니다. 설정 > 창 배치에서 켜세요.")
            }
            return true
        }
        return control.handle(url: url) { task in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "창 배치 설정을 바꿀까요?"
            alert.informativeText = "다른 앱이 요청했습니다. \(task)"
            alert.addButton(withTitle: "바꾸기")
            alert.addButton(withTitle: "취소")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func begin(prompt: Bool) {
        trusted = WindowControl.trusted
        guard trusted else {
            if prompt { WindowControl.requestAccess() }
            waitForTrust()
            return
        }
        waitTimer?.invalidate()
        waitTimer = nil
        // 펫이 ⌃⌥ 방향키를 먼저 잡았으면 창 배치 단축키가 등록되지 않는다. 펫을 놓았다가 다시 잡아 비켜 준다 (⌃⌥⇧으로 물러난다)
        let petShown = DesktopPet.shared.isShown
        if petShown { PetKeys.shared.unregister() }
        running = control.start()
        if petShown { PetKeys.shared.register() }
        WindowPalette.shared.bindKey()
        updateStatusItem()
        revision += 1
        let urls = pendingURLs
        pendingURLs = []
        if running { urls.forEach { _ = open($0) } }
    }

    private func end() {
        waitTimer?.invalidate()
        waitTimer = nil
        control.stop()
        running = false
        updateStatusItem()
        if DesktopPet.shared.isShown {
            PetKeys.shared.unregister()
            PetKeys.shared.register()
        }
    }

    private func updateStatusItem() {
        let show = enabled && statusIcon
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "RunTime 창 배치"
            item.button?.image = WindowMenu.statusIcon
            item.button?.setAccessibilityLabel("창 배치")
            item.menu = menu.menu
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func waitForTrust() {
        guard waitTimer == nil else { return }
        waitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = WindowControl.trusted
            if trusted != self.trusted { self.trusted = trusted }
            guard trusted, self.enabled else { return }
            self.begin(prompt: false)
        }
    }
}
