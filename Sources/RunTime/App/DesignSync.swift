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
    /// 섹션에 [완료]·[수정중] 같은 표시가 없는 화면은 완료로 본다.
    @Published var untaggedIsDone: Bool { didSet { defaults.set(untaggedIsDone, forKey: "design.untaggedIsDone") } }
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
        untaggedIsDone = defaults.object(forKey: "design.untaggedIsDone") as? Bool ?? true
        favorites = defaults.stringArray(forKey: "design.favorites") ?? []
        tokenHint = Keychain.exists(Self.tokenAccount) ? "저장됨" : nil
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(sources), forKey: "design.sources")
    }

    /// 키체인을 읽는다. 허용 창이 뜰 수 있어 가져올 때만 부른다.
    var token: String? {
        guard ProcessInfo.processInfo.environment["RUNTIME_NO_KEYCHAIN"] == nil else {
            return ProcessInfo.processInfo.environment["RUNTIME_FIGMA_TOKEN"]
        }
        return Keychain.read(Self.tokenAccount).flatMap { $0.isEmpty ? nil : $0 }
    }

    var hasToken: Bool { tokenHint != nil }

    @discardableResult
    func saveToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Keychain.write(trimmed, account: Self.tokenAccount) else { return false }
        tokenHint = "••••" + trimmed.suffix(4)
        return true
    }

    func clearToken() {
        Keychain.delete(Self.tokenAccount)
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
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest, lane: Lane = .content) async throws -> Data {
        for attempt in 0..<3 {
            // 기다리기 전에 차례를 먼저 잡는다. actor는 sleep 동안 다른 호출을 받아서, 나중에 잡으면 둘이 같이 나간다
            let slot = max(Date(), (last[lane] ?? .distantPast).addingTimeInterval(spacing(lane)))
            last[lane] = slot
            let wait = slot.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let (data, response) = try await session.data(for: request)
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
    }

    func start() {
        reschedule()
    }

    /// 주기를 바꾸면 다시 맞춘다.
    func reschedule() {
        timer?.invalidate()
        // 프로젝트마다 주기가 달라 1분마다 둘러보고 때가 된 것만 받는다
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

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

    /// 마지막으로 받으려 한 때나 받은 때.
    func lastChecked(_ fileKey: String) -> Date {
        max(attempted[fileKey] ?? .distantPast, history.files[fileKey]?.syncedAt ?? .distantPast)
    }

    /// 주기를 정해 저절로 받는 프로젝트 수.
    var automaticCount: Int { settings.sources.filter { !$0.isHidden && interval(for: $0) > 0 }.count }

    /// 받는 중이거나 받을 차례를 기다리는지.
    func isBusy(_ fileKey: String) -> Bool { fetching == fileKey || queued.contains(fileKey) || (queuedAll && source(fileKey)?.isHidden == false) }

    /// 숨긴 프로젝트·메뉴를 뺀, 확인하지 않은 중요한 변경.
    var unseenCount: Int { history.events.filter { $0.isImportant && !history.isSeen($0) && !isHidden($0) }.count }

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
                        capture.menus = Set(current)
                        capture.rules = rules(for: source.fileKey)
                        let events = history.record(capture, at: Date())
                        found += events
                        counts[source.fileKey] = events.count
                        rename(source.fileKey, to: capture.fileName)
                    }
                    if menusChanged.remove(source.fileKey) != nil { history.files[source.fileKey]?.lastModified = nil }
                    errors[source.fileKey] = nil
                } catch let failure as FigmaAPI.Failure {
                    errors[source.fileKey] = failure.message
                } catch {
                    errors[source.fileKey] = error.localizedDescription
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
        let title = completed == picked.count ? "디자인 완료 \(completed)건" : "완료된 디자인에 변경 \(picked.count - completed)건"
            + (completed > 0 && completed < picked.count ? " · 완료 \(completed)건" : "")
        let names = picked.prefix(3).map { $0.title.isEmpty ? $0.screenID : $0.title }
        let body = names.joined(separator: ", ") + (picked.count > 3 ? " 외 \(picked.count - 3)건" : "")
        Notifier.shared.send(title: title, body: body, opens: .design)
    }

    func shouldAlert(_ event: DesignEvent) -> Bool {
        guard let source = settings.sources.first(where: { $0.fileKey == event.fileKey }), !source.hides(event.menuPath) else { return false }
        guard event.isImportant || settings.notifyWorking else { return false }
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

    // MARK: 알림 메뉴와 상태

    func rules(for fileKey: String) -> DesignStatusRules {
        let source = settings.sources.first { $0.fileKey == fileKey }
        return DesignStatusRules(overrides: source?.statusOverrides ?? [:], untaggedIsDone: untaggedIsDone(fileKey, source: source))
    }

    /// 프로젝트에서 직접 정한 것 → 상태·버전을 쓰는 파일이면 전체 설정 → 쓰지 않는 파일이면 완료.
    private func untaggedIsDone(_ fileKey: String, source: DesignSource?) -> Bool {
        if let manual = source?.untaggedIsDone { return manual }
        return usesMarks(fileKey) ? settings.untaggedIsDone : true
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

    /// 주소를 확인하고 파일을 더한다. 문제가 있으면 그 이유.
    func addSource(_ input: String) async -> String? {
        guard let key = FigmaFileURL.fileKey(from: input) else { return "피그마 디자인 파일 주소가 아닙니다" }
        guard !settings.sources.contains(where: { $0.fileKey == key }) else { return "이미 지켜보는 파일입니다" }
        guard let token = settings.token else { return "피그마 토큰을 먼저 넣으세요" }
        do {
            let info = try FigmaAPI.parseFile(await FigmaClient.shared.send(FigmaAPI.fileRequest(fileKey: key, token: token)))
            settings.sources.append(DesignSource(fileKey: key, name: info.name))
            return nil
        } catch let failure as FigmaAPI.Failure {
            return failure.message
        } catch {
            return error.localizedDescription
        }
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
    func checkToken() async -> Result<String, FigmaAPI.Failure> {
        guard let token = settings.token else { return .failure(.unauthorized) }
        do {
            if !settings.sources.isEmpty {
                for source in settings.sources {
                    _ = try FigmaAPI.parseFile(await FigmaClient.shared.send(FigmaAPI.fileRequest(fileKey: source.fileKey, token: token)))
                }
                return .success("연결됐습니다 · 화면설계서 \(settings.sources.count)개를 읽을 수 있습니다")
            }
            do {
                let handle = try FigmaAPI.parseMe(await FigmaClient.shared.send(FigmaAPI.meRequest(token: token)))
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
