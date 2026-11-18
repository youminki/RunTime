import Cocoa

/// 저장해 둔 창 배치 하나: 앱마다 창 자리. Rectangle에는 없는 RunTime 기능이다.
public struct SavedWindowLayout: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    var windows: [Entry]
    /// 저장할 때의 모니터 구성.
    var screens: String
    /// 모니터 구성이 저장할 때와 같아지면 저절로 불러온다 (노트북을 모니터에 꽂고 뺄 때).
    public var autoRestore: Bool

    struct Entry: Codable, Hashable {
        /// 번들 ID. 번들 없이 도는 앱은 실행 파일 경로.
        let bundleID: String
        let appName: String
        let title: String
        /// 화면 왼쪽 위 기준 좌표 (손쉬운 사용 API와 같다).
        let frame: CGRect
        /// 창 번호. 창이 열려 있는 동안은 바뀌지 않아, 제목이 바뀌는 창(브라우저 탭)도 같은 창으로 짝짓는다.
        /// 예전에 저장한 배치에는 없다.
        var windowID: CGWindowID?
    }

    public var slot: WindowShortcutSlot { WindowShortcutSlot(defaultsKey: "layout.\(id.uuidString)", title: "‘\(name)’ 불러오기") }
    public var windowCount: Int { windows.count }
    /// 앱 이름 (겹치지 않게, 저장한 차례로).
    public var appNames: [String] {
        var seen = Set<String>()
        return windows.map(\.appName).filter { seen.insert($0).inserted }
    }
    public var matchesCurrentScreens: Bool { screens == WindowLayouts.screenSignature() }
}

public final class WindowLayouts {
    public static let shared = WindowLayouts()

    public private(set) var saved: [SavedWindowLayout] = []
    public var onChange: () -> Void = {}
    /// 불러오기를 마치면 알린다 (옮긴 창 수, 실행 중이 아니라 건너뛴 앱).
    public var onRestore: (SavedWindowLayout, Int, [String]) -> Void = { _, _, _ in }

    private static let storeKey = "savedLayouts"
    private static let rememberKey = "rememberPerScreen"
    private static let snapshotsKey = "screenSnapshots"
    private var screenObserver: NSObjectProtocol?
    private var pendingAuto: DispatchWorkItem?
    var lastScreens = WindowLayouts.screenSignature()
    /// 모니터 구성마다 마지막으로 본 창 자리 (Rectangle 이슈 #127·#1552). 구성이 바뀌면 그 구성의 자리로 되돌린다.
    private(set) var snapshots: [String: [Entry]] = [:]
    private var snapshotTimer: Timer?
    private(set) var capturing = false
    /// 모니터가 바뀐 직후에는 macOS가 옮겨 놓은 엉뚱한 자리를 찍지 않게 잠깐 쉰다.
    var quietUntil = Date.distantPast
    private let captureQueue = DispatchQueue(label: "dev.runtime.window.snapshot", qos: .utility)

    /// 모니터를 꽂거나 빼면 그 구성에서 쓰던 창 자리로 저절로 되돌린다 (기본 켬).
    public var remembersPerScreen: Bool {
        get { WindowDefaults.store.object(forKey: Self.rememberKey) as? Bool ?? true }
        set {
            WindowDefaults.store.set(newValue, forKey: Self.rememberKey)
            if !newValue {
                snapshots = [:]
                WindowDefaults.store.removeObject(forKey: Self.snapshotsKey)
            }
            onChange()
        }
    }

    private init() {
        guard let data = WindowDefaults.store.data(forKey: Self.storeKey) else { return }
        if let layouts = try? JSONDecoder().decode([SavedWindowLayout].self, from: data) {
            saved = layouts
        } else if WindowDefaults.store.data(forKey: Self.storeKey) != nil {
            // 형식이 바뀌어 읽지 못하면 다음 저장이 덮어쓰기 전에 원본을 옮겨 둔다
            WindowDefaults.store.set(data, forKey: Self.storeKey + ".unreadable")
            Logger.log("저장한 배치를 읽지 못해 \(Self.storeKey).unreadable로 옮겼습니다")
        }
    }

    func start() {
        bindKeys()
        if snapshots.isEmpty, let data = WindowDefaults.store.data(forKey: Self.snapshotsKey),
           let stored = try? JSONDecoder().decode([String: [Entry]].self, from: data) {
            snapshots = stored
        }
        if snapshotTimer == nil {
            // 창 자리는 자주 바뀌지 않아 30초마다면 충분하다. 찍는 일은 다른 스레드에서 해 앱을 멈추지 않는다
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.snapshot() }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            snapshotTimer = timer
            snapshot()
        }
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        // 잠자는 동안 모니터를 빼고 다시 꽂으면 구성 문자열은 그대로인데 macOS는 창을 주 화면에 몰아 둔다 (Rectangle #1552).
        // 잠들기 전에 찍고, 깨어나면 쉬는 시간을 둔 뒤 되돌린다
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.snapshot()
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lastScreens = ""
                self.screensChanged()
            },
        ]
    }

    private var sleepObservers: [NSObjectProtocol] = []

    func snapshot() {
        guard !WindowRuntime.paused, remembersPerScreen, !capturing, Date() > quietUntil else { return }
        let screens = Self.screenSignature()
        capturing = true
        captureQueue.async { [weak self] in
            let entries = Self.captureWindows()
            let alive = Self.liveWindowIDs()
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                // 찍는 동안 모니터가 바뀌었거나, 기억을 껐거나, 창 배치를 껐으면 버린다
                guard !entries.isEmpty, screens == Self.screenSignature(), Date() > self.quietUntil,
                      self.remembersPerScreen, !WindowRuntime.paused else { return }
                let merged = Self.merge(old: self.snapshots[screens] ?? [], new: entries, alive: alive)
                guard self.snapshots[screens] != merged else { return }
                self.snapshots[screens] = merged
                if let data = try? JSONEncoder().encode(self.snapshots) {
                    WindowDefaults.store.set(data, forKey: Self.snapshotsKey)
                }
            }
        }
    }

    /// 지금 본 창으로 바꾸되, 지금 안 보이는 창(다른 데스크톱, 전체 화면 뒤)은 아직 열려 있으면 남긴다.
    /// 전체 화면 앱 하나만 보이는 동안 찍어도 다른 창의 기억이 지워지지 않게 한다.
    static func merge(old: [Entry], new: [Entry], alive: Set<CGWindowID>) -> [Entry] {
        let seen = Set(new.compactMap(\.windowID))
        let seenApps = Set(new.map(\.bundleID))
        let kept = old.filter { entry in
            guard let id = entry.windowID else { return !seenApps.contains(entry.bundleID) }
            return !seen.contains(id) && alive.contains(id)
        }
        return new + kept
    }

    /// 열려 있는 모든 창 번호 (다른 데스크톱 포함). 다른 스레드에서 불러도 된다.
    static func liveWindowIDs() -> Set<CGWindowID> {
        let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(infos.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// 모니터를 꽂거나 뺀 뒤 macOS가 창을 다 옮길 때까지 조금 기다렸다가 맞는 배치를 불러온다.
    /// '모니터를 연결하면 저절로'를 켠 저장 배치가 있으면 그것을, 없으면 그 구성에서 마지막으로 본 자리를 쓴다.
    func screensChanged() {
        let now = Self.screenSignature()
        guard now != lastScreens else { return }
        lastScreens = now
        quietUntil = Date().addingTimeInterval(5)
        pendingAuto?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !WindowRuntime.paused else { return }
            let screens = Self.screenSignature()
            if let layout = self.saved.last(where: { $0.autoRestore && $0.screens == screens }) {
                self.restore(layout)
            } else if self.remembersPerScreen, let entries = self.snapshots[screens] {
                self.placeInBackground(entries) { moved, _ in
                    Logger.log("모니터 구성이 바뀌어 창 \(moved)개를 되돌림 (기억한 창 \(entries.count)개)")
                    if moved > 0 { self.onScreenRestore(moved) }
                    self.quietUntil = Date().addingTimeInterval(2)
                }
                return
            }
            self.quietUntil = Date().addingTimeInterval(2)
        }
        pendingAuto = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - 저장

    @discardableResult
    public func save(named name: String) -> SavedWindowLayout {
        let windows = Self.captureWindows()
        if let index = saved.firstIndex(where: { $0.name == name }) {
            saved[index].windows = windows
            saved[index].screens = Self.screenSignature()
            persist()
            return saved[index]
        }
        let layout = SavedWindowLayout(id: UUID(), name: name, windows: windows, screens: Self.screenSignature(), autoRestore: false)
        saved.append(layout)
        persist()
        return layout
    }

    /// 이름을 물어 지금 배치를 저장한다 (메뉴에서).
    public func saveInteractively() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "지금 창 배치 저장"
        alert.informativeText = "열려 있는 창의 자리를 앱마다 기억합니다. 같은 이름이 있으면 새 배치로 바꿉니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "예: 개발, 회의, 집 모니터"
        field.stringValue = "배치 \(saved.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        save(named: name.isEmpty ? "배치 \(saved.count + 1)" : name)
    }

    public func update(_ layout: SavedWindowLayout) {
        guard let index = saved.firstIndex(where: { $0.id == layout.id }) else { return }
        saved[index].windows = Self.captureWindows()
        saved[index].screens = Self.screenSignature()
        persist()
    }

    public func rename(_ layout: SavedWindowLayout, to name: String) {
        guard let index = saved.firstIndex(where: { $0.id == layout.id }), !name.isEmpty else { return }
        saved[index].name = name
        persist()
    }

    public func setAutoRestore(_ layout: SavedWindowLayout, _ on: Bool) {
        guard let index = saved.firstIndex(where: { $0.id == layout.id }) else { return }
        saved[index].autoRestore = on
        persist()
    }

    public func delete(_ layout: SavedWindowLayout) {
        saved.removeAll { $0.id == layout.id }
        MASShortcutBinder.shared()?.breakBinding(withDefaultsKey: layout.slot.defaultsKey)
        WindowDefaults.store.removeObject(forKey: layout.slot.defaultsKey)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { WindowDefaults.store.set(data, forKey: Self.storeKey) }
        bindKeys()
        onChange()
    }

    /// 배치마다 단축키를 달 수 있다.
    private func bindKeys() {
        guard let binder = MASShortcutBinder.shared() else { return }
        for layout in saved {
            let id = layout.id
            binder.bindShortcut(withDefaultsKey: layout.slot.defaultsKey) { [weak self] in
                guard let self, let layout = self.saved.first(where: { $0.id == id }) else { return }
                self.restore(layout)
            }
        }
    }

    // MARK: - 불러오기

    public func restore(named name: String) {
        if let layout = saved.first(where: { $0.name == name }) { restore(layout) }
    }

    public func restore(_ layout: SavedWindowLayout) {
        guard !WindowRuntime.paused else { return }
        placeInBackground(layout.windows) { [weak self] moved, missing in self?.onRestore(layout, moved, missing) }
    }

    /// 모니터 구성이 바뀌어 창을 제자리로 옮겼으면 알린다 (옮긴 창 수).
    public var onScreenRestore: (Int) -> Void = { _ in }

    /// 점검 도구가 사용자 창을 건드리지 않게 이 앱(키)의 창만 옮기게 한다.
    var onlyApp: String?

    /// 창을 찾고 옮기는 일은 손쉬운 사용 호출이 많아 다른 스레드에서 한다 (답이 느린 앱 때문에 메뉴바가 멈추지 않게).
    private func placeInBackground(_ entries: [Entry], done: @escaping (Int, [String]) -> Void) {
        let only = onlyApp
        let screens = NSScreen.screens.map { $0.frame.screenFlipped }
        captureQueue.async {
            let (moved, missing) = Self.place(entries, only: only, screens: screens)
            DispatchQueue.main.async { done(moved, missing) }
        }
    }

    /// 앱마다 창을 창 번호 → 제목 → 저장한 자리와 가장 가까운 창 차례로 짝지어 옮긴다. 이미 그 자리인 창은 세지 않는다.
    /// 한 앱이 여러 프로세스로 떠 있으면 모든 프로세스의 창에서 찾는다. 전체 화면 창은 건드리지 않는다.
    static func place(_ entries: [Entry], only: String?, screens: [CGRect]) -> (moved: Int, missing: [String]) {
        var moved = 0
        var missing: [String] = []
        let own = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != own }
        for (bundleID, group) in Dictionary(grouping: entries, by: \.bundleID) where only == nil || only == bundleID {
            let apps = running.filter { key(of: $0) == bundleID }
            guard !apps.isEmpty else {
                missing.append(group[0].appName)
                continue
            }
            // 답하지 않는 앱 하나 때문에 오래 멈추지 않게
            var windows = apps.flatMap { app -> [AccessibilityElement] in
                let element = AccessibilityElement(app.processIdentifier)
                element.setMessagingTimeout(1)
                return element.windowElements ?? []
            }
            .filter { $0.isMinimized != true && $0.isSheet != true && $0.isStandardWindow != false && $0.isFullScreen != true }
            var pairs: [(AccessibilityElement, CGRect)] = []
            var rest = group
            func take(_ match: (AccessibilityElement, Entry) -> Bool) {
                rest = rest.filter { entry in
                    guard let index = windows.firstIndex(where: { match($0, entry) }) else { return true }
                    pairs.append((windows.remove(at: index), entry.frame))
                    return false
                }
            }
            take { window, entry in entry.windowID != nil && window.getWindowId() == entry.windowID }
            take { window, entry in !entry.title.isEmpty && (window.title ?? "") == entry.title }
            // 남은 창은 저장한 자리와 가장 가까운 창끼리 (같은 앱 창끼리 자리가 뒤바뀌지 않게)
            for entry in rest {
                guard let index = windows.indices.min(by: {
                    windows[$0].frame.centerPoint.distance(to: entry.frame.centerPoint)
                        < windows[$1].frame.centerPoint.distance(to: entry.frame.centerPoint)
                }) else { break }
                pairs.append((windows.remove(at: index), entry.frame))
            }
            // 지금 없는 모니터에 있던 창은 화면 밖으로 보내지 않고 둔다
            for (window, frame) in pairs where screens.contains(where: { $0.intersects(frame) }) {
                window.setMessagingTimeout(1)
                guard window.frame != frame else { continue }
                window.setFrame(frame)
                // 다른 모니터로 건너가면 macOS가 크기를 한 번 더 고친다
                if window.frame.size != frame.size { window.setFrame(frame) }
                moved += 1
            }
        }
        return (moved, missing.sorted())
    }

    typealias Entry = SavedWindowLayout.Entry

    // MARK: - 창 모으기

    /// 보이는 창을 앞에서부터 모은다. 다른 스레드에서도 부를 수 있게 Rectangle의 창 목록 캐시를 쓰지 않고,
    /// 답하지 않는 앱 때문에 오래 멈추지 않게 앱마다 1초만 기다린다.
    static func captureWindows() -> [Entry] {
        let own = ProcessInfo.processInfo.processIdentifier
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids: [pid_t] = []
        for info in infos where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != own, !pids.contains(pid) else { continue }
            pids.append(pid)
        }
        return pids.flatMap { pid -> [Entry] in
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundleID = key(of: app) else { return [] }
            let element = AccessibilityElement(pid)
            element.setMessagingTimeout(1)
            return (element.windowElements ?? []).compactMap { window -> Entry? in
                window.setMessagingTimeout(1)
                guard window.isStandardWindow != false, window.isMinimized != true, window.isSheet != true,
                      window.isFullScreen != true else { return nil }
                let frame = window.frame
                guard !frame.isNull, frame.width > 40, frame.height > 40 else { return nil }
                return Entry(bundleID: bundleID, appName: app.localizedName ?? bundleID, title: window.title ?? "", frame: frame,
                             windowID: window.getWindowId())
            }
        }
    }

    static func key(of app: NSRunningApplication) -> String? {
        app.bundleIdentifier ?? app.executableURL?.path
    }

    /// 모니터 구성. 크기와 놓인 자리가 같으면 같은 구성으로 본다.
    static func screenSignature() -> String {
        NSScreen.screens.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .sorted().joined(separator: ";")
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
