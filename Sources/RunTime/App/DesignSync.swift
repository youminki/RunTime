import AppKit
import DesignSyncCore
import Foundation
import WorkLogCore

/// 디자인 변경 기록 설정. 파일 목록은 UserDefaults, 피그마 토큰은 키체인에 둔다.
@MainActor
final class DesignSyncSettings: ObservableObject {
    static let shared = DesignSyncSettings()
    private let defaults = UserDefaults.standard
    static let tokenAccount = "figma-token"

    @Published var sources: [DesignSource] { didSet { save() } }
    /// 0이면 가져오기를 누를 때만 받는다.
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: "design.interval") } }
    @Published var notify: Bool { didSet { defaults.set(notify, forKey: "design.notify") } }
    /// 작업 중인 화면의 변경도 알린다. 작업 중 시안은 계속 바뀌어 기본은 끈다.
    @Published var notifyWorking: Bool { didSet { defaults.set(notifyWorking, forKey: "design.notifyWorking") } }
    /// 섹션에 [완료]·[수정중] 같은 표시가 없는 화면. nil이면 판단하지 않고(알림 받는 메뉴는 바뀔 때마다 알림),
    /// true면 완료, false면 작업 중으로 본다. 표시를 아예 안 쓰는 화면설계서를 모두 완료로 보면 변경이 전부 완료 후 변경으로 쏟아진다.
    @Published var untaggedIsDone: Bool? {
        didSet { defaults.set(untaggedIsDone.map { $0 ? 1 : 2 } ?? 0, forKey: "design.untagged") }
    }
    @Published private(set) var tokenHint: String?
    /// 즐겨찾기한 메뉴 (`파일키|화면 경로`). 놓은 순서대로 보인다.
    @Published var favorites: [String] { didSet { defaults.set(favorites, forKey: "design.favorites") } }

    static let intervals = [0, 30, 60, 180]

    private init() {
        sources = (defaults.data(forKey: "design.sources")).flatMap { try? JSONDecoder().decode([DesignSource].self, from: $0) } ?? []
        // 화면설계서는 반영할 때만 보면 돼서, 정하지 않았으면 가져오기를 누른 프로젝트만 받는다
        intervalMinutes = defaults.object(forKey: "design.interval") as? Int ?? 0
        notify = defaults.object(forKey: "design.notify") as? Bool ?? true
        notifyWorking = defaults.object(forKey: "design.notifyWorking") as? Bool ?? false
        untaggedIsDone = [1: true, 2: false][defaults.integer(forKey: "design.untagged")]
        favorites = defaults.stringArray(forKey: "design.favorites") ?? []
        tokenHint = Keychain.exists(Self.tokenAccount) ? "저장됨" : nil
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(sources), forKey: "design.sources")
    }

    /// 키체인을 읽는다. 허용 창이 뜰 수 있어 가져올 때만 부르고, 한 번 읽으면 메모리에 둔다
    /// (상세 그림을 넘길 때마다 /usr/bin/security를 띄우지 않게).
    var token: String? {
        guard ProcessInfo.processInfo.environment["RUNTIME_NO_KEYCHAIN"] == nil else {
            return ProcessInfo.processInfo.environment["RUNTIME_FIGMA_TOKEN"]
        }
        if let cachedToken { return cachedToken }
        cachedToken = Keychain.read(Self.tokenAccount).flatMap { $0.isEmpty ? nil : $0 }
        return cachedToken
    }
    private var cachedToken: String?

    var hasToken: Bool { tokenHint != nil }

    @discardableResult
    func saveToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Keychain.write(trimmed, account: Self.tokenAccount) else { return false }
        cachedToken = trimmed
        tokenHint = "••••" + trimmed.suffix(4)
        return true
    }

    func clearToken() {
        Keychain.delete(Self.tokenAccount)
        cachedToken = nil
        tokenHint = nil
    }
}

/// 피그마 호출 창구. 한 번에 하나씩, 간격을 두고 보내 호출 한도에 덜 걸리게 한다.
actor FigmaClient {
    static let shared = FigmaClient()
    /// 이미지는 가져오기와 줄을 따로 세운다. 같은 줄이면 상세를 열 때마다 가져오기가 끝나기를 기다린다.
    enum Lane { case content, images }

    /// 파일 내용 API는 좌석에 따라 분당 10회 안팎이라 6초씩 띄운다.
    /// 이미지는 누를 때만 묶어서 보내 드물어서 짧게 띄우고, 한도에 걸리면 아래에서 알려 준 만큼 쉰다.
    private func spacing(_ lane: Lane) -> TimeInterval { lane == .content ? 6 : 1.5 }
    private var last: [Lane: Date] = [:]
    /// 한도에 오래(5분 넘게, 또는 기한 없이) 걸렸을 때 그때까지 모든 호출을 보내지 않는다.
    /// 프로젝트·이미지·날짜 비교가 저마다 다시 두드려 한도가 길어지지 않게.
    private(set) var blockedUntil: Date?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // 큰 화면설계서는 한 묶음 응답이 수십 MB라 2분으로는 끊긴다
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest, lane: Lane = .content) async throws -> Data {
        if let blockedUntil, blockedUntil > Date() {
            throw FigmaAPI.Failure.rateLimited(retryAfter: Int(blockedUntil.timeIntervalSinceNow.rounded(.up)))
        }
        var transient = 0
        for attempt in 0..<3 {
            // 기다리기 전에 차례를 먼저 잡는다. actor는 sleep 동안 다른 호출을 받아서, 나중에 잡으면 둘이 같이 나간다
            let slot = max(Date(), (last[lane] ?? .distantPast).addingTimeInterval(spacing(lane)))
            last[lane] = slot
            let wait = slot.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) && transient < 2 {
                // 잠깐 끊긴 것이면 몇 초 쉬고 다시 보낸다 (큰 파일을 받다 한 묶음이 끊겨 전부 버리지 않게)
                transient += 1
                try await Task.sleep(nanoseconds: UInt64(transient * 3) * 1_000_000_000)
                continue
            }
            let http = response as? HTTPURLResponse
            guard let failure = FigmaAPI.failure(status: http?.statusCode ?? 0,
                                                 retryAfter: http?.value(forHTTPHeaderField: "Retry-After"), body: data) else {
                return data
            }
            // 한도에 걸리면 알려 준 만큼(길면 5분까지) 쉬고 두 번까지 다시 보낸다. 다음 차례가 그때 오도록 줄을 미뤄 두면
            // 다시 보낼 때 간격만큼 더 기다리지 않고, 그사이 들어온 다른 호출도 그 뒤로 선다
            if case .rateLimited(let after) = failure, attempt < 2, let after, (0...300).contains(after) {
                last[lane] = max(last[lane] ?? .distantPast, Date().addingTimeInterval(TimeInterval(after) - spacing(lane)))
                continue
            }
            if case .rateLimited(let after) = failure {
                blockedUntil = Date().addingTimeInterval(TimeInterval(after ?? 60))
            }
            // 피그마 쪽 일시 오류(502·503·504)는 한 번 더 보낸다
            if case .server(let status) = failure, [500, 502, 503, 504].contains(status), transient < 2 {
                transient += 1
                try await Task.sleep(nanoseconds: UInt64(transient * 3) * 1_000_000_000)
                continue
            }
            throw failure
        }
        throw FigmaAPI.Failure.rateLimited(retryAfter: nil)
    }
}

/// 지켜보는 피그마 파일을 주기마다 가져와 화면설계서 변경을 기록한다.
@MainActor
final class DesignSync: ObservableObject {
    static let shared = DesignSync()

    @Published private(set) var history: DesignHistory
    @Published private(set) var syncing = false
    @Published private(set) var progress = ""
    /// 파일 키 → 마지막 오류
    @Published private(set) var errors: [String: String] = [:]
    /// 지금 받고 있는 프로젝트.
    @Published private(set) var fetching: String?
    /// 받는 동안 가져오기를 누른 프로젝트. 끝나면 이어서 받는다.
    @Published private(set) var queued = Set<String>()
    /// 기록 파일을 읽지 못했으면 덮어쓰지 않게 저장을 막는다.
    private(set) var loadError: String?

    let settings = DesignSyncSettings.shared
    private var timer: Timer?
    /// 가져오는 동안 메뉴를 바꾼 파일. 끝난 뒤 다음에 새로 받도록 버전을 비운다.
    private var menusChanged = Set<String>()
    /// 받는 동안 전부 가져오기를 눌렀다.
    private var queuedAll = false
    /// 받는 동안 들어온 요청의 끝 알림. 그 요청이 고른 프로젝트(nil이면 전부)에서 찾은 건수를 넘긴다.
    private var queuedCompletions: [(keys: Set<String>?, done: (Int) -> Void)] = []
    private let saveQueue = DispatchQueue(label: "dev.runtime.RunTime.design-history", qos: .utility)

    private init() {
        do {
            history = try DesignHistoryFile.load()
        } catch {
            history = DesignHistory()
            loadError = "디자인 기록 파일을 읽지 못해 새 기록을 저장하지 않습니다: \(error.localizedDescription)"
        }
        markUnmarkedOnce()
    }

    /// 상태 표시를 쓰지 않는 화면설계서를 모두 완료로 보던 때 남긴 변경을 "상태 모름"으로 고친다. 한 번만 한다.
    private func markUnmarkedOnce() {
        let flag = "design.unmarkedMigrated"
        guard loadError == nil, !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        guard settings.untaggedIsDone == nil else { return }
        let plain = Set(history.files.filter { key, file in
            source(key)?.untaggedIsDone == nil && source(key)?.statusOverrides.isEmpty != false && !DesignStatus.usesMarks(file.screens.values)
        }.keys)
        var changed = false
        for index in history.events.indices where plain.contains(history.events[index].fileKey) && history.events[index].kind != .changelog
            && [.afterDone, .completed].contains(history.events[index].phase) {
            history.events[index].phase = .unmarked
            changed = true
        }
        if changed { persist() }
    }

    func start() {
        reschedule()
    }

    /// 주기를 바꾸면 다시 맞춘다.
    func reschedule() {
        timer?.invalidate()
        // 프로젝트마다 주기가 달라 1분마다 둘러보고 때가 된 것만 받는다. 메뉴를 펼친 동안에도 돌게 .common에 건다
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // 깨어나면 망이 붙을 틈을 준 뒤 밀린 것을 받는다
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                             queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { Task { @MainActor in self?.tick() } }
            }
        }
    }
    private var wakeObserver: NSObjectProtocol?

    /// 마지막으로 가져오려 한 때. 실패해도 주기만큼은 다시 묻지 않게 한다.
    private var attempted: [String: Date] = [:]

    /// 프로젝트 주기(분). 따로 정하지 않았으면 전체 설정, 0이면 손으로만.
    func interval(for source: DesignSource) -> Int { source.intervalMinutes ?? settings.intervalMinutes }

    static let projectIntervals: [Int?] = [nil, 30, 60, 180, 1440, 0]

    func intervalLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "기본 (\(intervalLabel(settings.intervalMinutes)))" }
        switch minutes {
        case 0: return "누를 때만"
        case 1440: return "하루마다"
        case let m where m < 60: return "\(m)분마다"
        default: return "\(minutes / 60)시간마다"
        }
    }

    func setInterval(_ minutes: Int?, for fileKey: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        settings.sources[index].intervalMinutes = minutes
    }

    /// 주기를 정한 프로젝트 가운데 때가 된 것만 받는다. 누를 때만 받는 프로젝트는 건드리지 않는다.
    private func tick() {
        guard !syncing, settings.hasToken else { return }
        let due = dueKeys(now: Date())
        guard !due.isEmpty else { return }
        sync(keys: due)
    }

    func dueKeys(now: Date) -> Set<String> {
        Set(settings.sources.filter { source in
            let minutes = interval(for: source)
            guard !source.isHidden, minutes > 0 else { return false }
            return now.timeIntervalSince(lastChecked(source.fileKey)) >= Double(minutes * 60)
        }.map(\.fileKey))
    }

    /// 실패한 프로젝트를 `date`에 다시 받게 마지막 시도 시각을 당겨 둔다 (주기를 정한 프로젝트만 저절로 받는다).
    private func retry(_ fileKey: String, at date: Date) {
        guard let source = settings.sources.first(where: { $0.fileKey == fileKey }) else { return }
        let minutes = interval(for: source)
        guard minutes > 0 else { return }
        attempted[fileKey] = date.addingTimeInterval(-Double(minutes * 60))
    }

    /// 마지막으로 받으려 한 때나 받은 때.
    func lastChecked(_ fileKey: String) -> Date {
        max(attempted[fileKey] ?? .distantPast, history.files[fileKey]?.syncedAt ?? .distantPast)
    }

    /// 주기를 정해 저절로 받는 프로젝트 수.
    var automaticCount: Int { settings.sources.filter { !$0.isHidden && interval(for: $0) > 0 }.count }

    /// 받는 중이거나 받을 차례를 기다리는지.
    func isBusy(_ fileKey: String) -> Bool { fetching == fileKey || queued.contains(fileKey) || (queuedAll && source(fileKey)?.isHidden == false) }

    /// 확인하지 않은 내 변경 (`follows`). 메뉴바·사이드바가 그릴 때마다 부르므로 기록이나 설정이 바뀔 때만 다시 센다
    /// (변경은 수천 건까지 쌓인다). `fileKey`를 주면 그 프로젝트만.
    func unseenCount(in fileKey: String? = nil) -> Int {
        let key = UnseenKey(events: history.events.count, last: history.events.last?.id, seen: history.seen.count + history.applied.count,
                            sources: settings.sources.map { "\($0.fileKey)\($0.isHidden)\($0.hiddenMenus)\($0.alerts)" }, project: fileKey)
        if let cached = unseenCache[fileKey ?? ""], cached.key == key { return cached.count }
        let count = history.events.filter { event in
            (fileKey == nil || event.fileKey == fileKey) && event.isImportant && !history.isSeen(event) && follows(event)
        }.count
        unseenCache[fileKey ?? ""] = (key, count)
        return count
    }
    var unseenCount: Int { unseenCount() }
    private struct UnseenKey: Equatable { let events: Int; let last: UUID?; let seen: Int; let sources: [String]; let project: String? }
    private var unseenCache: [String: (key: UnseenKey, count: Int)] = [:]

    /// 내가 볼 변경. 알림 받을 메뉴를 고른 프로젝트는 그 메뉴의 변경만, 아직 고르지 않은 프로젝트는 전부.
    /// 숨긴 프로젝트·메뉴는 빠진다.
    func follows(_ event: DesignEvent) -> Bool {
        guard let source = source(event.fileKey) else { return true }
        guard !source.hides(event.menuPath) else { return false }
        return source.alerts.isEmpty || inAlerts(event, source: source)
    }

    /// 알림 받는 메뉴의 변경인지. 이력 줄은 적힌 메뉴나 화면 ID로 가린다.
    func inAlerts(_ event: DesignEvent, source: DesignSource) -> Bool {
        guard !source.alerts.isEmpty else { return false }
        if event.kind != .changelog { return source.alerts(event.menuPath) }
        if let menus = event.menus, !menus.isEmpty {
            return menus.contains { menu in source.alerts(menu) || source.alerts.contains { DesignStatus.covers(menu, $0) } }
        }
        // 이력 줄은 페이지 단위라, 적힌 화면 ID나 그 페이지의 화면이 알림 메뉴에 있을 때만
        let screens = history.files[event.fileKey]?.screens.values.filter { source.alerts($0.menuPath) } ?? []
        let ids = event.screenID.components(separatedBy: ", ").filter { !$0.isEmpty }
        if !ids.isEmpty { return screens.contains { ids.contains($0.screenID) } }
        return screens.contains { SpecExtractor.stripNote($0.pageName) == event.menuPath }
    }

    func source(_ fileKey: String) -> DesignSource? { settings.sources.first { $0.fileKey == fileKey } }

    /// 숨긴 프로젝트나 숨긴 메뉴의 변경.
    func isHidden(_ event: DesignEvent) -> Bool {
        source(event.fileKey)?.hides(event.menuPath) == true
    }

    /// `[VeloX] 화면설계서` → `VeloX`. 업무 일지 프로젝트 이름·색과 맞춘다.
    func projectName(_ fileKey: String) -> String {
        let name = source(fileKey)?.name ?? history.files[fileKey]?.name ?? fileKey
        return Self.project(from: name)
    }

    /// 지금 시안의 화면. `path`가 있으면 그 경로(아래 경로 포함)만, `exact`면 그 경로만.
    func screens(_ fileKey: String, under path: String? = nil, exact: Bool = false) -> [ScreenSnapshot] {
        let all = history.files[fileKey]?.screens.values ?? [:].values
        return all.filter { screen in
            guard let path else { return true }
            return exact ? screen.menuPath == path : DesignStatus.covers(path, screen.menuPath)
        }
        .sorted { ($0.menuPath, $0.screenID, $0.title, $0.frameID) < ($1.menuPath, $1.screenID, $1.title, $1.frameID) }
    }

    /// 이 화면에 생긴 변경과 화면 ID를 적은 이력. 최근 것이 앞.
    func events(for screen: ScreenSnapshot, in fileKey: String) -> [DesignEvent] {
        history.events.filter { event in
            guard event.fileKey == fileKey else { return false }
            if event.kind == .changelog {
                return event.screenID.components(separatedBy: ", ").contains(screen.screenID)
                    || (event.menus ?? []).contains { DesignStatus.covers($0, screen.menuPath) }
            }
            return event.frameID == screen.frameID || event.beforeFrameID == screen.frameID
        }
        .sorted { $0.detectedAt > $1.detectedAt }
    }

    /// 이 화면에서 아직 반영하지 않은 변경 (이력 줄 제외).
    func pendingEvents(for screen: ScreenSnapshot, in fileKey: String) -> [DesignEvent] {
        events(for: screen, in: fileKey).filter { $0.kind != .changelog && !history.isApplied($0) }
    }

    /// Claude Code에 붙일 글. 반영할 변경이 있으면 그 변경만, 없으면 화면을 처음 마크업하는 글.
    func claudePrompt(for screen: ScreenSnapshot, in fileKey: String) -> String {
        let link = FigmaFileURL.link(fileKey: fileKey, nodeID: screen.frameID)
        let pending = pendingEvents(for: screen, in: fileKey)
        guard !pending.isEmpty else { return ClaudePrompt.build(screen, project: projectName(fileKey), link: link, built: history.built(screen, in: fileKey)) }
        return ClaudePrompt.changes(pending, screen: screen, project: projectName(fileKey), link: link, done: checkedMap(pending))
    }

    func claudePrompt(for event: DesignEvent) -> String {
        let screen = event.frameID.flatMap { history.files[event.fileKey]?.screens[$0] }
        let link = event.frameID.flatMap { FigmaFileURL.link(fileKey: event.fileKey, nodeID: $0) }
        return ClaudePrompt.changes([event], screen: screen, project: projectName(event.fileKey), link: link, done: checkedMap([event]))
    }

    private func checkedMap(_ events: [DesignEvent]) -> [UUID: Set<String>] {
        Dictionary(events.map { ($0.id, history.checkedKeys($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// 업무 일지 오늘 칸에 이 화면 마크업을 할 일로 넣는다.
    func addToWorkLog(_ screen: ScreenSnapshot, in fileKey: String) -> Bool {
        let title = "\(screen.screenID) \(screen.title) 마크업".trimmingCharacters(in: .whitespaces)
        return WorkLogStore.shared.add(day: WorkDay.today(), project: projectName(fileKey), title: title, status: .inProgress) != nil
    }

    // MARK: 즐겨찾기·숨기기·순서

    static func favoriteKey(_ fileKey: String, _ path: String) -> String { fileKey + "|" + path }

    func isFavorite(_ fileKey: String, _ path: String) -> Bool { settings.favorites.contains(Self.favoriteKey(fileKey, path)) }

    func toggleFavorite(_ fileKey: String, _ path: String) {
        let key = Self.favoriteKey(fileKey, path)
        if let index = settings.favorites.firstIndex(of: key) { settings.favorites.remove(at: index) } else { settings.favorites.append(key) }
    }

    func setMenuHidden(_ path: String, hidden: Bool, in fileKey: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        var paths = settings.sources[index].hiddenMenus.filter { !DesignStatus.covers(path, $0) }
        if hidden { paths.append(path) }
        settings.sources[index].hiddenMenus = paths.sorted()
    }

    func setProjectHidden(_ fileKey: String, hidden: Bool) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        settings.sources[index].isHidden = hidden
    }

    /// 끌어다 놓은 자리로 옮긴다 (`from`을 `to` 자리에).
    func moveProject(_ from: String, to: String) {
        guard let source = settings.sources.firstIndex(where: { $0.fileKey == from }),
              let target = settings.sources.firstIndex(where: { $0.fileKey == to }), source != target else { return }
        let item = settings.sources.remove(at: source)
        settings.sources.insert(item, at: target)
    }

    func moveFavorite(_ from: String, to: String) {
        guard let source = settings.favorites.firstIndex(of: from), let target = settings.favorites.firstIndex(of: to), source != target else { return }
        let item = settings.favorites.remove(at: source)
        settings.favorites.insert(item, at: target)
    }

    // MARK: 가져오기

    func sync(only fileKey: String? = nil, completion: ((Int) -> Void)? = nil) {
        sync(keys: fileKey.map { [$0] }, completion: completion)
    }

    /// `keys`가 없으면 숨기지 않은 프로젝트 전부, 있으면 그 프로젝트만 (숨겼어도 지금 가져오기로 고른 것은 받는다).
    func sync(keys: Set<String>?, completion: ((Int) -> Void)? = nil) {
        guard !syncing else {
            // 받는 중에 누른 프로젝트는 이번 차례가 끝나면 그 프로젝트만 받는다
            if let keys { queued.formUnion(keys.subtracting(fetching.map { [$0] } ?? [])) } else { queuedAll = true }
            if let completion { queuedCompletions.append((keys, completion)) }
            return
        }
        run(keys: keys) { counts in completion?(counts.values.reduce(0, +)) }
    }

    /// 한 차례 받는다. 끝나면 프로젝트별로 찾은 변경 수를 넘긴다.
    private func run(keys: Set<String>?, completion: @escaping ([String: Int]) -> Void) {
        if let loadError {
            errors["*"] = loadError
            completion([:])
            return
        }
        // 숨긴 프로젝트는 가져오지 않아 피그마 요청을 아낀다
        let sources = settings.sources.filter { source in keys.map { $0.contains(source.fileKey) } ?? !source.isHidden }
        for source in sources { attempted[source.fileKey] = Date() }
        guard !sources.isEmpty else { completion([:]); return }
        guard let token = settings.token else {
            errors["*"] = "피그마 토큰을 넣으세요"
            completion([:])
            return
        }
        errors["*"] = nil
        syncing = true
        Task {
            var found: [DesignEvent] = []
            var counts: [String: Int] = [:]
            for source in sources {
                // 가져오는 사이 지운 파일은 기록하지 않는다 (지운 뒤 고아 기록이 생긴다)
                guard settings.sources.contains(where: { $0.fileKey == source.fileKey }) else { continue }
                fetching = source.fileKey
                queued.remove(source.fileKey)
                do {
                    let outcome = try await DesignSyncEngine.run(
                        source: source, token: token, known: history.files[source.fileKey],
                        transport: { try await FigmaClient.shared.send($0) },
                        progress: { text in Task { @MainActor in DesignSync.shared.progress = text } })
                    guard settings.sources.contains(where: { $0.fileKey == source.fileKey }) else { continue }
                    // 받는 사이 메뉴를 바꿨으면 이번 결과는 옛 메뉴 기준이라, 다음에 새 메뉴로 다시 받는다
                    let current = settings.sources.first { $0.fileKey == source.fileKey }?.menus ?? []
                    switch outcome {
                    case .unchanged(let info):
                        history.confirmUnchanged(fileKey: source.fileKey, at: Date())
                        // 버전을 기록하기 전에 세운 기준도 다음 변경의 "이전" 이미지를 그릴 수 있게 채운다
                        if history.files[source.fileKey]?.version == nil { history.files[source.fileKey]?.version = info.version }
                    case .captured(var capture):
                        // 링크로 고른 화면만 받았으면 그 화면의 경로를 엔진이 정해 둔다
                        if !capture.scoped { capture.menus = Set(current) }
                        capture.rules = rules(for: source.fileKey)
                        let events = history.record(capture, at: Date())
                        found += events
                        counts[source.fileKey] = events.count
                        rename(source.fileKey, to: capture.fileName)
                        resolve(source.fileKey, capture.resolved)
                    }
                    if menusChanged.remove(source.fileKey) != nil { history.files[source.fileKey]?.lastModified = nil }
                    errors[source.fileKey] = nil
                    if case .captured(let capture) = outcome {
                        let blank = capture.resolved.filter { $0.frames?.isEmpty == true && !capture.missing.contains($0.nodeID) }
                        if !capture.missing.isEmpty {
                            errors[source.fileKey] = "링크한 화면 \(capture.missing.count)개를 찾지 못했습니다. 지워졌거나 화면 프레임 안쪽 요소의 링크일 수 있습니다"
                            // 찾지 못한 링크는 다음에 다시 찾게 파일이 그대로여도 다시 받는다
                            history.files[source.fileKey]?.lastModified = nil
                        } else if let first = blank.first {
                            errors[source.fileKey] = "‘\(first.name)’에서 화면설계서 틀(화면 ID·Description)을 찾지 못했습니다. 화면설계서의 화면 프레임 링크인지 확인하세요"
                        }
                    }
                } catch let failure as FigmaAPI.Failure {
                    errors[source.fileKey] = failure.message
                    if case .rateLimited = failure {
                        // 한도가 풀리면 다시 받게 그때로 미뤄 두고, 남은 프로젝트는 한도를 더 두드리지 않게 건너뛴다
                        let until = await FigmaClient.shared.blockedUntil ?? Date().addingTimeInterval(60)
                        for rest in sources { retry(rest.fileKey, at: until) }
                        break
                    }
                    if case .server = failure { retry(source.fileKey, at: Date().addingTimeInterval(300)) }
                } catch {
                    errors[source.fileKey] = error.localizedDescription
                    // 깬 직후처럼 망이 잠깐 끊긴 것이면 주기를 통째로 기다리지 않고 5분 뒤 다시 받는다
                    retry(source.fileKey, at: Date().addingTimeInterval(300))
                }
            }
            persist()
            syncing = false
            fetching = nil
            progress = ""
            announce(found)
            completion(counts)
            // 이번 차례에 다 받은 요청은 바로 알리고, 나머지는 다음 차례로 넘긴다
            let handled = Set(sources.map(\.fileKey))
            var carried: [(keys: Set<String>?, done: (Int) -> Void)] = []
            for item in queuedCompletions {
                if let keys = item.keys, keys.isSubset(of: handled), keys.isDisjoint(with: queued) {
                    item.done(keys.reduce(0) { $0 + (counts[$1] ?? 0) })
                } else {
                    carried.append(item)
                }
            }
            // 전부 가져오기와 숨긴 프로젝트 요청이 함께 기다리면 둘 다 받는다
            let next = queuedAll ? Set(settings.sources.filter { !$0.isHidden }.map(\.fileKey)).union(queued) : queued
            queuedAll = false
            queued = []
            queuedCompletions = []
            guard !next.isEmpty else {
                carried.forEach { $0.done(0) }
                return
            }
            run(keys: next) { counts in
                for item in carried { item.done((item.keys ?? next).reduce(0) { $0 + (counts[$1] ?? 0) }) }
            }
        }
    }

    /// 창을 열 때. 주기를 정한 프로젝트 가운데 때가 지난 것만 받는다. 누를 때만 받는 프로젝트는 가져오기를 눌러야 받는다.
    func syncIfStale() {
        // 화면 점검(--ui-shots)은 예시 기록을 찍을 뿐이라 진짜 피그마에 묻지 않는다
        guard !CommandLine.arguments.contains("--ui-shots") else { return }
        tick()
    }

    /// 앱을 끌 때 남은 저장을 마친다.
    func flush() {
        saveQueue.sync {}
    }

    private func rename(_ fileKey: String, to name: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }), settings.sources[index].name != name else { return }
        settings.sources[index].name = name
    }

    /// 🔔를 켠 메뉴의 중요한 변경(완료 후 변경, 막 완료됨, 이력)만 알린다. 작업 중 변경은 설정을 켰을 때만.
    private func announce(_ events: [DesignEvent]) {
        guard settings.notify else { return }
        let picked = events.filter(shouldAlert)
        guard !picked.isEmpty else { return }
        let completed = picked.filter { $0.phase == .completed }.count
        let title = completed == picked.count ? "디자인 완료 \(completed)건" : "알림 받는 메뉴에 디자인 변경 \(picked.count - completed)건"
            + (completed > 0 && completed < picked.count ? " · 완료 \(completed)건" : "")
        let names = picked.prefix(3).map { $0.title.isEmpty ? $0.screenID : $0.title }
        let body = names.joined(separator: ", ") + (picked.count > 3 ? " 외 \(picked.count - 3)건" : "")
        Notifier.shared.send(title: title, body: body, opens: .design)
    }

    func shouldAlert(_ event: DesignEvent) -> Bool {
        guard let source = settings.sources.first(where: { $0.fileKey == event.fileKey }), !source.hides(event.menuPath) else { return false }
        guard event.isImportant || settings.notifyWorking else { return false }
        return inAlerts(event, source: source)
    }

    // MARK: 알림 메뉴와 상태

    func rules(for fileKey: String) -> DesignStatusRules {
        let source = settings.sources.first { $0.fileKey == fileKey }
        return DesignStatusRules(overrides: source?.statusOverrides ?? [:], untaggedIsDone: untaggedIsDone(fileKey, source: source))
    }

    /// 프로젝트에서 직접 정한 것, 없으면 전체 설정. 전체 설정의 기본은 판단하지 않음(nil)이다.
    private func untaggedIsDone(_ fileKey: String, source: DesignSource?) -> Bool? {
        source?.untaggedIsDone ?? settings.untaggedIsDone
    }

    /// 파일마다 상태 표시를 쓰는지. 사이드바가 그릴 때마다 화면을 모두 훑지 않게 화면 수가 같으면 다시 쓴다.
    private var marksCache: [String: (count: Int, uses: Bool)] = [:]

    /// 이 프로젝트에서 상태 표시 없는 화면을 어떻게 보는지 (nil: 자동).
    func setUntaggedIsDone(_ value: Bool?, for fileKey: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        settings.sources[index].untaggedIsDone = value
    }

    /// 섹션에 상태나 버전을 쓰는 프로젝트인지. 아직 받지 않았으면 쓰는 것으로 둔다.
    func usesMarks(_ fileKey: String) -> Bool {
        guard let screens = history.files[fileKey]?.screens.values else { return true }
        if let cached = marksCache[fileKey], cached.count == screens.count { return cached.uses }
        let uses = DesignStatus.usesMarks(screens)
        marksCache[fileKey] = (screens.count, uses)
        return uses
    }

    func state(of screen: ScreenSnapshot, in fileKey: String) -> ScreenState {
        DesignStatus.state(of: screen, rules: rules(for: fileKey))
    }

    /// 경로(묶음이면 그 아래 전부)의 알림을 켜고 끈다. 아래 경로에 따로 켠 것은 묶음에 합친다.
    func setAlert(_ path: String, on: Bool, in fileKey: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        var alerts = settings.sources[index].alerts.filter { !DesignStatus.covers(path, $0) }
        if on { alerts.append(path) } else {
            // 묶음에 켠 알림 안의 한 메뉴만 끄면, 묶음을 풀고 나머지 메뉴를 하나씩 켠다
            if let parent = alerts.first(where: { DesignStatus.covers($0, path) }) {
                alerts.removeAll { $0 == parent }
                let siblings = Set(history.files[fileKey]?.screens.values.map(\.menuPath) ?? [])
                    .filter { DesignStatus.covers(parent, $0) && !DesignStatus.covers(path, $0) }
                alerts += siblings
            }
        }
        settings.sources[index].alerts = alerts.sorted()
    }

    /// 완료·작업 중을 직접 정한다. nil이면 섹션 표시대로 되돌린다.
    func setStatus(_ key: String, done: Bool?, in fileKey: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        settings.sources[index].statusOverrides[key] = done
    }

    private func persist() {
        guard loadError == nil else { return }
        let snapshot = history
        saveQueue.async {
            do {
                try DesignHistoryFile.save(snapshot)
            } catch {
                Task { @MainActor in DesignSync.shared.errors["*"] = "디자인 기록을 저장하지 못했습니다: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: 파일

    /// 붙여 넣은 링크를 더한 결과. `nodeID`가 있으면 그 화면을 연다.
    struct AddedLink {
        let fileKey: String
        let nodeID: String?
        /// 새로 받아야 그 화면이 보인다.
        let needsFetch: Bool
        let message: String
    }

    struct LinkProblem: Error {
        let message: String
    }

    /// 링크로 고를 수 있는 노드. 글자·도형 같은 안쪽 요소는 화면을 가리지 못한다.
    static let linkableTypes: Set<String> = ["CANVAS", "SECTION", "FRAME", "GROUP", "COMPONENT", "COMPONENT_SET", "INSTANCE"]

    /// 피그마 링크를 더한다. `node-id`가 있으면 그 화면(프레임·섹션·페이지)만, 없으면 파일 전체를 지켜본다.
    /// 같은 파일의 다른 화면 링크는 그 파일의 화면 목록에 더한다.
    func addLink(_ input: String) async -> Result<AddedLink, LinkProblem> {
        guard let key = FigmaFileURL.fileKey(from: input) else { return .failure(LinkProblem(message: "피그마 디자인 파일 주소가 아닙니다")) }
        let node = FigmaFileURL.nodeID(from: input)
        guard let token = settings.token else { return .failure(LinkProblem(message: "피그마 토큰을 먼저 넣으세요")) }
        do {
            if let index = settings.sources.firstIndex(where: { $0.fileKey == key }) {
                let source = settings.sources[index]
                let name = projectName(key)
                guard let node else {
                    guard !source.scope.isEmpty else { return .failure(LinkProblem(message: "이미 지켜보는 파일입니다")) }
                    widen(key)
                    return .success(AddedLink(fileKey: key, nodeID: nil, needsFetch: true, message: "‘\(name)’ 전체를 지켜봅니다"))
                }
                if source.isHidden { setProjectHidden(key, hidden: false) }
                if source.scope.isEmpty || source.scope.contains(where: { $0.nodeID == node }) {
                    // 이미 받는 화면이면 기다리지 않고 바로 연다
                    let known = screen(for: node, in: key) != nil
                    return .success(AddedLink(fileKey: key, nodeID: node, needsFetch: !known,
                                              message: source.scope.isEmpty ? "‘\(name)’ 전체를 지켜보고 있어 이 화면도 들어 있습니다" : "이미 지켜보는 화면입니다"))
                }
                let scope = try await linkedNode(node, in: key, token: token)
                settings.sources[index].scope.append(scope)
                // 새 화면은 파일이 그대로여도 받아야 한다
                history.files[key]?.lastModified = nil
                persist()
                return .success(AddedLink(fileKey: key, nodeID: node, needsFetch: true, message: "‘\(scope.name)’ 화면을 더했습니다"))
            }
            let info = try FigmaAPI.parseFile(await FigmaClient.shared.send(FigmaAPI.fileRequest(fileKey: key, token: token)))
            guard let node else {
                settings.sources.append(DesignSource(fileKey: key, name: info.name))
                return .success(AddedLink(fileKey: key, nodeID: nil, needsFetch: true, message: "‘\(Self.project(from: info.name))’ 전체를 지켜봅니다"))
            }
            let scope = try await linkedNode(node, in: key, token: token)
            settings.sources.append(DesignSource(fileKey: key, name: info.name, scope: [scope]))
            return .success(AddedLink(fileKey: key, nodeID: node, needsFetch: true, message: "‘\(scope.name)’ 화면만 지켜봅니다"))
        } catch let problem as LinkProblem {
            return .failure(problem)
        } catch let failure as FigmaAPI.Failure {
            return .failure(LinkProblem(message: failure.message))
        } catch {
            return .failure(LinkProblem(message: error.localizedDescription))
        }
    }

    /// 링크한 노드의 이름과 종류를 묻는다. 한 단계만 받아 가볍다.
    private func linkedNode(_ node: String, in fileKey: String, token: String) async throws -> DesignScope {
        let nodes = try FigmaAPI.parseNodes(await FigmaClient.shared.send(FigmaAPI.nodesRequest(fileKey: fileKey, ids: [node], depth: 1, token: token)))
        guard let found = nodes[node] else { throw LinkProblem(message: "링크한 화면을 찾지 못했습니다. 지워졌거나 볼 권한이 없는 노드입니다") }
        guard Self.linkableTypes.contains(found.type) else {
            throw LinkProblem(message: "화면 프레임이나 섹션, 페이지 링크를 붙여 넣으세요. 이 링크는 화면 안쪽 요소(\(found.name))를 가리킵니다")
        }
        return DesignScope(nodeID: node, name: found.name, pageID: found.type == "CANVAS" ? node : nil)
    }

    /// 링크한 노드에서 읽은 화면. 노드가 화면 프레임이 아니면(섹션·틀·페이지) 그 안의 첫 화면.
    func screen(for nodeID: String, in fileKey: String) -> ScreenSnapshot? {
        guard let file = history.files[fileKey] else { return nil }
        if let screen = file.screens[nodeID] { return screen }
        let frames = source(fileKey)?.scope.first { $0.nodeID == nodeID }?.frames ?? []
        let screens = file.screens.values.filter { frames.contains($0.frameID) || $0.candidateID == nodeID || $0.pageID == nodeID }
        return screens.min { ($0.menuPath, $0.screenID) < ($1.menuPath, $1.screenID) }
    }

    /// 가져오며 찾은 페이지·프레임을 링크에 적어 둔다. 받는 사이 빼거나 더한 링크는 건드리지 않는다.
    private func resolve(_ fileKey: String, _ resolved: [DesignScope]) {
        guard !resolved.isEmpty, let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        let byNode = Dictionary(resolved.map { ($0.nodeID, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = settings.sources[index].scope.map { scope in
            guard let found = byNode[scope.nodeID] else { return scope }
            var scope = scope
            scope.pageID = found.pageID
            scope.frames = found.frames
            return scope
        }
        if updated != settings.sources[index].scope { settings.sources[index].scope = updated }
    }

    /// 링크로 고른 화면만 보던 파일을 전체로 넓힌다. 다음에 가져올 때 모든 화면을 받는다.
    func widen(_ fileKey: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }), !settings.sources[index].scope.isEmpty else { return }
        settings.sources[index].scope = []
        if syncing { menusChanged.insert(fileKey) }
        history.files[fileKey]?.lastModified = nil
        persist()
    }

    /// 링크한 화면 하나를 그만 지켜본다. 마지막 화면이면 파일을 뺀다 (비우면 전체가 되므로).
    func removeScope(_ nodeID: String, from fileKey: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        let scope = settings.sources[index].scope
        guard let removed = scope.first(where: { $0.nodeID == nodeID }) else { return }
        guard scope.count > 1 else { removeSource(fileKey); return }
        settings.sources[index].scope.removeAll { $0.nodeID == nodeID }
        let kept = Set(settings.sources[index].scope.flatMap { $0.frames ?? [] })
        history.forget(frames: (removed.frames ?? []).filter { !kept.contains($0) }, in: fileKey)
        persist()
    }

    func removeSource(_ fileKey: String) {
        settings.sources.removeAll { $0.fileKey == fileKey }
        history.forget(fileKey: fileKey)
        errors[fileKey] = nil
        persist()
    }

    /// 지켜볼 메뉴를 바꾼다. 새로 고른 메뉴는 파일이 그대로여도 다음에 받도록 버전을 비운다.
    func setMenus(_ menus: [String], for fileKey: String) {
        guard let index = settings.sources.firstIndex(where: { $0.fileKey == fileKey }) else { return }
        let before = Set(settings.sources[index].menus)
        let after = Set(menus)
        guard before != after else { return }
        settings.sources[index].menus = after.sorted()
        // 새로 고른 메뉴(전부로 넓힌 것 포함)의 화면은 받은 적이 없을 수 있어 파일이 그대로여도 다음에 받는다
        guard !after.subtracting(before).isEmpty || (after.isEmpty && !before.isEmpty) else { return }
        if syncing { menusChanged.insert(fileKey) }
        history.files[fileKey]?.lastModified = nil
        persist()
    }

    /// 연결 확인. 지켜보는 화면설계서가 있으면 실제로 읽어 본다 (가져오기에 필요한 범위는 file_content:read, 날짜 비교는 file_versions:read도 쓴다).
    /// 없으면 토큰이 맞는지만 본다. `/v1/me`는 current_user:read 범위가 따로 있어야 해서, 범위가 없다는 답은 토큰이 맞다는 뜻이다.
    /// 토큰을 바꿔 연결이 되면 옛 토큰 때문에 남은 오류(만료·권한)를 지운다. 누를 때만 받는 프로젝트도 바로 깨끗해지게.
    private func clearAuthErrors() {
        let auth = Set([FigmaAPI.Failure.unauthorized.message, "피그마 토큰을 넣으세요"])
        for (key, message) in errors where auth.contains(message) || message.hasPrefix("토큰에 ") { errors[key] = nil }
    }

    func checkToken() async -> Result<String, FigmaAPI.Failure> {
        guard let token = settings.token else { return .failure(.unauthorized) }
        do {
            if !settings.sources.isEmpty {
                for source in settings.sources {
                    _ = try FigmaAPI.parseFile(await FigmaClient.shared.send(FigmaAPI.fileRequest(fileKey: source.fileKey, token: token)))
                }
                clearAuthErrors()
                return .success("연결됐습니다 · 화면설계서 \(settings.sources.count)개를 읽을 수 있습니다")
            }
            do {
                let handle = try FigmaAPI.parseMe(await FigmaClient.shared.send(FigmaAPI.meRequest(token: token)))
                clearAuthErrors()
                return .success("연결됐습니다 · \(handle) 계정 토큰")
            } catch FigmaAPI.Failure.missingScope {
                return .success("연결됐습니다 · 화면설계서를 더하면 읽을 수 있는지 바로 확인합니다")
            }
        } catch let failure as FigmaAPI.Failure {
            return .failure(failure)
        } catch {
            return .failure(.server(0))
        }
    }

    // MARK: 확인

    func markSeen(_ ids: [UUID]) {
        let before = history.seen.count
        history.seen.formUnion(ids)
        if history.seen.count != before { persist() }
    }

    func markUnseen(_ id: UUID) {
        guard history.seen.remove(id) != nil else { return }
        persist()
    }

    // MARK: 반영

    /// 마크업에 반영을 마쳤다. 목록에서 빠지고 "반영 완료" 보기에만 남는다.
    func setApplied(_ id: UUID, _ applied: Bool) {
        if applied {
            guard history.applied.insert(id).inserted else { return }
            history.seen.insert(id)
        } else {
            guard history.applied.remove(id) != nil else { return }
        }
        persist()
    }

    /// 지금 시안 화면의 기능 명세 하나를 구현했는지 표시한다.
    func toggleBuilt(_ item: SpecItem, of screen: ScreenSnapshot, in fileKey: String) {
        history.toggleBuilt(item, of: screen, in: fileKey)
        persist()
    }

    /// 변경 안 항목 하나를 반영했는지 표시한다.
    func toggleChecked(_ change: SpecChange, in id: UUID) {
        var keys = history.checked[id.uuidString] ?? []
        if keys.remove(change.key) == nil { keys.insert(change.key) }
        history.checked[id.uuidString] = keys.isEmpty ? nil : keys
        persist()
    }

    /// 업무 일지 오늘 칸에 할 일로 넣는다. 프로젝트는 피그마 파일 이름에서 대괄호 안을 쓴다.
    func addToWorkLog(_ event: DesignEvent) -> Bool {
        let project = Self.project(from: event.fileName)
        let title = "\(event.screenID) \(event.title) 디자인 변경 반영".trimmingCharacters(in: .whitespaces)
        return WorkLogStore.shared.add(day: WorkDay.today(), project: project, title: title, status: .inProgress) != nil
    }

    /// `[Demo] 화면설계서` → `Demo`
    static func project(from fileName: String) -> String {
        if let open = fileName.firstIndex(of: "["), let close = fileName[open...].firstIndex(of: "]"), fileName.index(after: open) < close {
            return String(fileName[fileName.index(after: open)..<close])
        }
        return fileName
    }
}
