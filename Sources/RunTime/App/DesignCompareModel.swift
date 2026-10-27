import DesignSyncCore
import Foundation

/// 날짜 비교: 두 날짜의 피그마 버전을 받아 견주고, 그 사이 쌓인 기록도 함께 보인다.
@MainActor
final class DesignCompareModel: ObservableObject {
    static let shared = DesignCompareModel()

    @Published var fileKey: String?
    /// 비교할 화면 경로 (그 아래 포함). nil이면 프로젝트 전체.
    @Published var path: String?
    /// 화면 하나만 견줄 때 그 화면.
    @Published var screen: Target?
    @Published var from: Date = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
    @Published var to = Date()
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var error: String?
    @Published private(set) var result: Result?

    struct Target: Equatable {
        var frameID: String
        var screenID: String
        var title: String
        var candidateID: String
        var menuPath: String
        var pageID: String

        init(_ screen: ScreenSnapshot) {
            frameID = screen.frameID
            screenID = screen.screenID
            title = screen.title.isEmpty ? screen.screenID : screen.title
            candidateID = screen.candidateID
            menuPath = screen.menuPath
            pageID = screen.pageID
        }
    }

    struct Result {
        var fileKey: String
        var path: String?
        var screen: Target?
        var fromDay: Date
        var toDay: Date
        var from: FigmaAPI.FileVersion
        var to: FigmaAPI.FileVersion
        /// 뒤 버전으로 마지막으로 가져온 상태를 썼다.
        var toIsRecord: Bool
        var named: [FigmaAPI.FileVersion]
        var events: [DesignEvent]
    }

    /// 파일마다 받아 둔 버전 목록. 자주 바뀌어서 몇 분 지나면 첫 쪽부터 다시 받는다.
    private var versions: [String: (list: [FigmaAPI.FileVersion], next: URL?, at: Date)] = [:]

    private let sync = DesignSync.shared

    func open(fileKey: String, path: String?, screen: Target? = nil) {
        error = nil
        self.fileKey = fileKey
        self.path = path
        self.screen = screen
    }

    /// 지금 고른 프로젝트·범위·날짜로 낸 결과인지. 조건을 바꾸면 옛 결과를 새 것처럼 보이지 않게 한다.
    var currentResult: Result? {
        guard let result, result.fileKey == fileKey, result.path == path, result.screen == screen else { return nil }
        let calendar = Calendar.current
        let (from, to) = (min(self.from, self.to), max(self.from, self.to))
        guard calendar.isDate(result.fromDay, inSameDayAs: from), calendar.isDate(result.toDay, inSameDayAs: to) else { return nil }
        return result
    }

    /// 결과가 있지만 조건이 바뀌었다.
    var resultIsStale: Bool { result != nil && currentResult == nil && !running }

    /// 이 변경이 고른 화면의 것인지. 같은 화면 ID를 쓰는 다른 프레임(상태별 화면)은 빼고, 지금 없는 옛 프레임은 넣는다.
    private func belongs(_ event: DesignEvent, to target: Target) -> Bool {
        if event.kind == .changelog {
            // 화면 ID를 적은 줄은 그 ID로만 가린다. 같은 메뉴의 다른 화면 줄이 섞이지 않게 한다
            let ids = event.screenID.isEmpty ? [] : event.screenID.components(separatedBy: ", ")
            if !ids.isEmpty { return ids.contains(target.screenID) }
            return (event.menus ?? []).contains { DesignStatus.covers($0, target.menuPath) }
        }
        if event.frameID == target.frameID || event.beforeFrameID == target.frameID { return true }
        return event.screenID == target.screenID && !siblings(of: target).contains(event.frameID ?? "")
    }

    /// 같은 화면 ID를 쓰는 지금 있는 다른 프레임.
    private func siblings(of target: Target) -> Set<String> {
        guard let fileKey, let screens = sync.history.files[fileKey]?.screens.values else { return [] }
        return Set(screens.filter { $0.screenID == target.screenID && $0.frameID != target.frameID }.map(\.frameID))
    }

    /// 기록에 남은 변경 가운데 두 날짜 사이에 파일이 고쳐진 것. 요청 없이 바로 보인다.
    func recorded() -> [DesignEvent] {
        guard let fileKey, !fileKey.isEmpty else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(from, to))
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to))) ?? to
        return sync.history.events.filter { event in
            guard event.fileKey == fileKey, event.windowEnd >= start, event.windowEnd < end, !sync.isHidden(event) else { return false }
            if let screen { return belongs(event, to: screen) }
            return path.map(event.concerns) ?? true
        }
        .sorted { $0.windowEnd > $1.windowEnd }
    }

    func run() {
        guard !running, let fileKey, !fileKey.isEmpty else { return }
        guard let token = sync.settings.token else { error = "피그마 토큰을 넣으세요"; return }
        let path = self.path, screen = self.screen
        let (from, to) = (min(self.from, self.to), max(self.from, self.to))
        running = true
        error = nil
        result = nil
        Task {
            defer { running = false; progress = "" }
            do {
                let list = try await loadVersions(fileKey, until: from, token: token)
                let calendar = Calendar.current
                guard let before = DesignCompare.version(atEndOf: from, in: list) else {
                    let oldest = list.last.map { " 피그마에 남은 가장 오래된 버전은 \(DesignFormat.stamp($0.createdAt))입니다." } ?? ""
                    error = "\(DesignCompareModel.day(from)) 이전 버전이 없습니다.\(oldest)"
                    return
                }
                let include = includeRule(path: path, screen: screen)
                // 오늘과 견주면 마지막으로 가져온 상태를 쓴다. 자동 저장이 30분마다 새 버전을 만들어 매번 파일 전체를 다시 받게 된다.
                // 그 기록이 기준보다 오래됐거나, 메뉴를 골라 받아 고른 범위의 내용이 옛것일 수 있으면 피그마 최신 버전을 받는다
                var recorded: (snapshot: VersionSnapshot, version: FigmaAPI.FileVersion)?
                if calendar.isDateInToday(to), let record = sync.history.files[fileKey], let snapshot = VersionSnapshot(record: record, fileKey: fileKey) {
                    let at = record.lastModified.flatMap { ISO8601DateFormatter().date(from: $0) } ?? record.syncedAt
                    let menus = Set(sync.source(fileKey)?.menus ?? [])
                    let scoped = record.screens.values.filter(include)
                    let fresh = !scoped.isEmpty && (menus.isEmpty || (path != nil && scoped.allSatisfy { menus.contains($0.menuPath) }))
                    if at >= before.createdAt && fresh { recorded = (snapshot, FigmaAPI.FileVersion(id: snapshot.version, createdAt: at)) }
                }
                guard let after = recorded?.version ?? (calendar.isDateInToday(to) ? list.first : DesignCompare.version(atEndOf: to, in: list)) else {
                    error = "\(DesignCompareModel.day(to)) 이전 버전이 없습니다."
                    return
                }
                let named = DesignCompare.named(between: before, and: after, in: list)
                @MainActor func finish(_ events: [DesignEvent]) {
                    result = Result(fileKey: fileKey, path: path, screen: screen, fromDay: from, toDay: to, from: before, to: after,
                                    toIsRecord: recorded != nil, named: named, events: events)
                }
                guard before.id != after.id else { finish([]); return }
                let wanted = wantedCandidates(fileKey, path: path, screen: screen)
                let pageIDs = wantedPages(fileKey, path: path, screen: screen)
                progress = ""
                let skipped = Set(sync.source(fileKey)?.skippedPages ?? [])
                var snapshots: [VersionSnapshot] = []
                for (label, version) in [("기준", before), ("비교", after)] {
                    if label == "비교", let recorded {
                        snapshots.append(recorded.snapshot)
                        continue
                    }
                    var snapshot = DesignVersionCache.load(fileKey: fileKey, version: version.id) ?? VersionSnapshot(fileKey: fileKey, version: version.id)
                    let loaded = snapshot
                    try await DesignCompare.fill(&snapshot, skippedPages: skipped, pageIDs: pageIDs, token: token, wanted: wanted,
                                                 transport: { try await FigmaClient.shared.send($0) },
                                                 progress: { text in
                                                     Task { @MainActor in
                                                         let model = DesignCompareModel.shared
                                                         if model.running { model.progress = "\(label) 버전: \(text)" }
                                                     }
                                                 })
                    // 그 화면이 이 버전에 없으면 다른 페이지에 있던 옛 프레임일 수 있다. 이름에 화면 ID가 든 프레임만 찾아 받는다
                    if let screen, pageIDs != nil, !snapshot.allScreens.contains(where: { $0.screenID == screen.screenID }) {
                        try await DesignCompare.fill(&snapshot, skippedPages: skipped, token: token,
                                                     wanted: { $0.isChangelog ? pageIDs?.contains($0.pageID) == true
                                                         : ($0.name + " " + $0.sectionName).contains(screen.screenID) },
                                                     transport: { try await FigmaClient.shared.send($0) },
                                                     progress: { text in
                                                         Task { @MainActor in
                                                             let model = DesignCompareModel.shared
                                                             if model.running { model.progress = "\(label) 버전: 다른 페이지에서 이 화면 찾는 중 · \(text)" }
                                                         }
                                                     })
                    }
                    if snapshot != loaded { DesignVersionCache.save(snapshot) }
                    snapshots.append(snapshot)
                }
                let events = DesignCompare.events(fileKey: fileKey, fileName: sync.history.files[fileKey]?.name ?? sync.projectName(fileKey),
                                                  before: snapshots[0], after: snapshots[1], beforeDate: before.createdAt, afterDate: after.createdAt,
                                                  include: include, rules: sync.rules(for: fileKey),
                                                  knownPaths: Set(sync.history.files[fileKey]?.screens.values.map(\.menuPath) ?? []))
                finish(screen.map { target in events.filter { belongs($0, to: target) } } ?? events)
            } catch let failure as FigmaAPI.Failure {
                if case .missingScope = failure {
                    error = failure.message + ". 피그마 토큰에 file_versions:read 범위를 더해 다시 만드세요"
                } else {
                    error = failure.message
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// 고른 범위에 드는 화면. 화면 하나면 그 프레임과, 같은 화면 ID의 지금 없는 옛 프레임.
    private func includeRule(path: String?, screen: Target?) -> (ScreenSnapshot) -> Bool {
        if let screen {
            let siblings = siblings(of: screen)
            return { $0.frameID == screen.frameID || ($0.screenID == screen.screenID && !siblings.contains($0.frameID)) }
        }
        return { candidate in path.map { DesignStatus.covers($0, candidate.menuPath) } ?? true }
    }

    /// 경로를 골랐으면 그 경로의 화면을 낸 후보만 받는다. 기록이 없으면 전부.
    /// 기록에 없는 후보(그 사이 지웠거나 새로 생긴 프레임)는 어느 메뉴인지 몰라 함께 받고, 받은 뒤 경로로 거른다.
    /// 화면이 아니라고 본 후보(간지 등)는 받지 않는다.
    private func wantedCandidates(_ fileKey: String, path: String?, screen: Target?) -> (FigmaAPI.Candidate) -> Bool {
        guard let record = sync.history.files[fileKey], path != nil || screen != nil else { return { _ in true } }
        let known = Set(record.screens.values.map(\.candidateID)).union(record.ignored.keys)
        if let screen { return { $0.id == screen.candidateID || !known.contains($0.id) } }
        let ids = Set(record.screens.values.filter { DesignStatus.covers(path ?? "", $0.menuPath) }.map(\.candidateID))
        return { ids.contains($0.id) || !known.contains($0.id) }
    }

    /// 화면이나 메뉴를 골랐으면 그 화면이 있는 페이지와, 그 화면·메뉴를 적은 이력 표가 있는 페이지만 살펴본다.
    /// 기록이 없거나 고른 범위의 화면을 기록에서 못 찾으면 모든 페이지.
    private func wantedPages(_ fileKey: String, path: String?, screen: Target?) -> Set<String>? {
        guard let record = sync.history.files[fileKey], path != nil || screen != nil else { return nil }
        let scope = screen?.menuPath ?? path ?? ""
        var pages = screen.map { [$0.pageID] } ?? Set(record.screens.values.filter { DesignStatus.covers(scope, $0.menuPath) }.map(\.pageID))
        guard !pages.isEmpty else { return nil }
        let paths = Set(record.screens.values.map(\.menuPath))
        for entry in record.changelog where !pages.contains(entry.pageID) {
            let named = entry.menus(in: paths).contains { DesignStatus.covers(scope, $0) || DesignStatus.covers($0, scope) }
            if named || screen.map({ entry.screenIDs.contains($0.screenID) }) == true { pages.insert(entry.pageID) }
        }
        return pages
    }

    /// 오늘과 견줄 때 쓴 기록이 이보다 오래되면 최신으로 다시 받아 견주라고 알린다.
    static let staleRecord: TimeInterval = 3600

    /// 프로젝트를 지금 가져온 뒤 같은 조건으로 다시 견준다.
    func refreshAndRun() {
        guard let fileKey, !running else { return }
        progress = "최신 상태 가져오는 중"
        running = true
        sync.sync(only: fileKey) { [weak self] _ in
            self?.running = false
            self?.run()
        }
    }

    /// `until` 날짜 이전 버전이 나올 때까지 버전 목록을 받는다.
    private func loadVersions(_ fileKey: String, until day: Date, token: String) async throws -> [FigmaAPI.FileVersion] {
        let start = Calendar.current.startOfDay(for: day)
        var entry = versions[fileKey].flatMap { Date().timeIntervalSince($0.at) < 300 ? $0 : nil }
        // 저장해 둔 목록을 이었으면 새로 받은 첫 쪽. 저장한 커서가 듣지 않으면 이것부터 다시 받는다
        var fresh: (list: [FigmaAPI.FileVersion], next: URL?)?
        if entry == nil {
            progress = "버전 기록 받는 중"
            let page = try FigmaAPI.parseVersions(await FigmaClient.shared.send(FigmaAPI.versionsRequest(fileKey: fileKey, token: token)))
            entry = (page.versions, page.next, Date())
            // 지난 버전은 바뀌지 않아, 저장해 둔 목록과 이어지면 예전 쪽을 다시 받지 않는다
            if let saved = DesignVersionCache.versions(fileKey), let list = DesignCompare.merge(latest: page.versions, saved: saved.list) {
                entry = (list, saved.next, Date())
                fresh = (page.versions, page.next)
            }
        }
        var (list, next, at) = entry!
        // 자동 저장이 잦은 파일은 한 쪽(50개)이 이틀 남짓이라 기준 날짜 전 버전이 나올 때까지 더 받는다
        var pages = 0
        while let cursor = next, (list.last?.createdAt ?? .distantPast) >= start, pages < 40 {
            pages += 1
            progress = "버전 기록 받는 중 (\(DesignFormat.stamp(list.last?.createdAt ?? Date())) 이전)"
            let page: (versions: [FigmaAPI.FileVersion], next: URL?)
            do {
                page = try FigmaAPI.parseVersions(await FigmaClient.shared.send(FigmaAPI.versionsRequest(fileKey: fileKey, next: cursor, token: token)))
            } catch {
                guard let restart = fresh else { throw error }
                fresh = nil
                (list, next) = restart
                continue
            }
            fresh = nil
            list += page.versions.filter { version in !list.contains { $0.id == version.id } }
            next = page.next
        }
        versions[fileKey] = (list, next, at)
        DesignVersionCache.saveVersions(fileKey, list: list, next: next)
        return list
    }

    /// `3시간`, `2일`
    static func age(_ date: Date) -> String {
        let hours = Int(Date().timeIntervalSince(date) / 3600)
        return hours < 24 ? "\(max(hours, 1))시간" : "\(hours / 24)일"
    }

    static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "ko_KR")
        format.dateFormat = "M/d"
        return format.string(from: date)
    }
}

/// 받은 버전의 화면. 버전은 바뀌지 않아 같은 비교를 다시 하면 요청 없이 바로 나온다.
enum DesignVersionCache {
    static let keepCount = 40

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunTime/design-versions", isDirectory: true)
    }

    private static func file(_ fileKey: String, _ version: String) -> URL {
        folder.appendingPathComponent("\(fileKey)-\(version).json")
    }

    private struct VersionList: Codable {
        var list: [FigmaAPI.FileVersion]
        var next: URL?
    }

    private static func listFile(_ fileKey: String) -> URL {
        folder.appendingPathComponent("versions-\(fileKey).json")
    }

    static func versions(_ fileKey: String) -> (list: [FigmaAPI.FileVersion], next: URL?)? {
        guard let data = try? Data(contentsOf: listFile(fileKey)), let saved = try? JSONDecoder().decode(VersionList.self, from: data) else { return nil }
        return (saved.list, saved.next)
    }

    static func saveVersions(_ fileKey: String, list: [FigmaAPI.FileVersion], next: URL?) {
        let url = listFile(fileKey), saved = VersionList(list: list, next: next)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load(fileKey: String, version: String) -> VersionSnapshot? {
        guard let data = try? Data(contentsOf: file(fileKey, version)) else { return nil }
        return try? JSONDecoder().decode(VersionSnapshot.self, from: data)
    }

    static func save(_ snapshot: VersionSnapshot) {
        let url = file(snapshot.fileKey, snapshot.version)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            prune()
        }
    }

    /// 오래 안 쓴 버전부터 지워 개수를 지킨다.
    private static func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ !$0.lastPathComponent.hasPrefix("versions-") }), files.count > keepCount else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - keepCount) { try? manager.removeItem(at: url) }
    }
}
