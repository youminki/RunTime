import Foundation

/// 링크로 고른 화면 하나. 화면 프레임이나 섹션, 페이지일 수 있다.
public struct DesignScope: Codable, Equatable, Hashable, Sendable {
    public var nodeID: String
    public var name: String
    /// 찾아 둔 페이지. 알면 다음부터 그 페이지만 살펴본다.
    public var pageID: String?
    /// 마지막으로 가져올 때 이 링크에서 읽은 화면 프레임. nil이면 아직 가져오지 않았다.
    public var frames: [String]?

    public init(nodeID: String, name: String = "", pageID: String? = nil, frames: [String]? = nil) {
        self.nodeID = nodeID
        self.name = name
        self.pageID = pageID
        self.frames = frames
    }
}

/// 지켜보는 피그마 파일 하나와 그 범위.
public struct DesignSource: Codable, Equatable, Identifiable, Sendable {
    public var fileKey: String
    public var name: String
    /// 지켜볼 화면 경로. 비어 있으면 전부.
    public var menus: [String]
    /// 지켜보지 않을 페이지 ID. 구분선·공통·백업 페이지는 따로 적지 않아도 뺀다.
    public var skippedPages: [String]
    /// 알림을 받을 화면 경로. 묶음(`데이터셋`)을 넣으면 그 아래에 새로 생기는 화면까지 받는다. 비어 있으면 알리지 않는다.
    public var alerts: [String]
    /// 직접 정한 완료·작업 중 상태 (DesignStatusRules.overrides 참고).
    public var statusOverrides: [String: Bool]
    /// 숨긴 화면 경로 (그 아래 경로 포함). 목록·건수·알림에서 뺀다.
    public var hiddenMenus: [String]
    /// 프로젝트를 통째로 숨겼다. 보이지 않고 가져오지도 않는다.
    public var isHidden: Bool
    /// 이 프로젝트만 따로 정한 가져오기 주기(분). nil이면 전체 설정을, 0이면 손으로만 가져온다.
    public var intervalMinutes: Int?
    /// 상태 표시가 없는 화면을 완료로 볼지 이 프로젝트만 따로 정한다. nil이면 자동.
    public var untaggedIsDone: Bool?
    /// 링크로 고른 화면만 지켜본다. 비어 있으면 파일 전체.
    public var scope: [DesignScope]

    public init(fileKey: String, name: String = "", menus: [String] = [], skippedPages: [String] = [],
                alerts: [String] = [], statusOverrides: [String: Bool] = [:], hiddenMenus: [String] = [], isHidden: Bool = false,
                scope: [DesignScope] = []) {
        self.scope = scope
        self.hiddenMenus = hiddenMenus
        self.isHidden = isHidden
        self.fileKey = fileKey
        self.name = name
        self.menus = menus
        self.skippedPages = skippedPages
        self.alerts = alerts
        self.statusOverrides = statusOverrides
    }

    private enum CodingKeys: String, CodingKey { case fileKey, name, menus, skippedPages, alerts, statusOverrides, hiddenMenus, isHidden, intervalMinutes, untaggedIsDone, scope }

    /// 알림·상태 칸이 생기기 전에 저장한 설정도 읽는다.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileKey = try container.decode(String.self, forKey: .fileKey)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        menus = try container.decodeIfPresent([String].self, forKey: .menus) ?? []
        skippedPages = try container.decodeIfPresent([String].self, forKey: .skippedPages) ?? []
        alerts = try container.decodeIfPresent([String].self, forKey: .alerts) ?? []
        statusOverrides = try container.decodeIfPresent([String: Bool].self, forKey: .statusOverrides) ?? [:]
        hiddenMenus = try container.decodeIfPresent([String].self, forKey: .hiddenMenus) ?? []
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes)
        untaggedIsDone = try container.decodeIfPresent(Bool.self, forKey: .untaggedIsDone)
        scope = try container.decodeIfPresent([DesignScope].self, forKey: .scope) ?? []
    }

    /// 숨긴 프로젝트이거나 숨긴 경로 아래면 true.
    public func hides(_ path: String) -> Bool {
        isHidden || hiddenMenus.contains { DesignStatus.covers($0, path) }
    }

    public var id: String { fileKey }

    /// 이 경로에 알림을 받는지.
    public func alerts(_ path: String) -> Bool {
        alerts.contains { DesignStatus.covers($0, path) }
    }
}

/// 파일 하나를 가져오는 순서. 보내는 일은 `transport`가 한다(앱은 URLSession, 테스트는 가짜 응답).
public enum DesignSyncEngine {
    public typealias Transport = @Sendable (URLRequest) async throws -> Data

    public enum Outcome: Sendable {
        /// 직전에 가져온 뒤로 파일이 고쳐지지 않았다
        case unchanged(FigmaAPI.FileInfo)
        case captured(DesignCapture)
    }

    public static func run(source: DesignSource, token: String, known: DesignFileRecord?, transport: Transport,
                           progress: @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        let info = try FigmaAPI.parseFile(await transport(FigmaAPI.fileRequest(fileKey: source.fileKey, token: token)))
        // 몇 분 걸려 받는 사이 디자이너가 고쳐도 모든 쪽이 처음 본 버전 그대로 오게 버전을 고정한다 (이후 그림과 변경 표시가 맞게)
        if let known, known.lastModified == info.lastModified { return .unchanged(info) }

        let scoped = Set(source.scope.map(\.nodeID))
        // 링크로 고른 화면은 공통·백업 같은 이름의 페이지에 있어도 찾는다. 받는 것은 찾은 화면뿐이다
        let pages = scoped.isEmpty
            ? info.pages.filter { !FigmaAPI.isSkippedPage($0.name) && !source.skippedPages.contains($0.id) }
            : info.pages
        var candidates: [FigmaAPI.Candidate] = []
        var outlined: [SpecExtractor.Page] = []
        func outline(_ batch: [SpecExtractor.Page]) async throws {
            for (index, page) in batch.enumerated() {
                progress("\(info.name): 페이지 살펴보는 중 \(index + 1)/\(batch.count)")
                let outline = try FigmaAPI.parseNodes(await transport(
                    FigmaAPI.outlineRequest(fileKey: source.fileKey, pageIDs: [page.id], version: info.version, token: token)))
                if let node = outline[page.id] { candidates += FigmaAPI.candidates(in: node, pageID: page.id) }
                outlined.append(page)
            }
        }
        if scoped.isEmpty {
            try await outline(pages)
        } else {
            // 찾아 둔 페이지부터 보고, 거기서 못 찾은 화면이 있을 때만 나머지 페이지를 뒤진다 (화면을 다른 페이지로 옮겼을 수 있다)
            let hinted = Set(source.scope.compactMap(\.pageID)).union(scoped)
            try await outline(pages.filter { hinted.contains($0.id) })
            if !scoped.subtracting(located(scoped, in: candidates).keys).isEmpty {
                try await outline(pages.filter { !hinted.contains($0.id) })
            }
        }

        // 링크로 고른 화면이 있으면 그 화면이 있는 페이지만 살펴본 것으로 친다. 다른 페이지의 화면은 그대로 둔다
        let found = located(scoped, in: candidates)
        let watchedPages = scoped.isEmpty ? Set(outlined.map(\.id)) : Set(found.values)
        let pageScreens = candidates.filter { !$0.isChangelog && watchedPages.contains($0.pageID) }
        let screenCandidates = scoped.isEmpty ? pageScreens : pageScreens.filter { FigmaAPI.covers(scoped, $0) }
        let screenIDs = screenCandidates.map(\.id)
        let wanted = known?.candidatesToFetch(screenIDs, menus: Set(source.menus)) ?? screenIDs
        // 제·개정 이력은 작아서 늘 받는다
        let fetchIDs = candidates.filter { $0.isChangelog && watchedPages.contains($0.pageID) }.map(\.id) + wanted
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pageByID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var screens: [ScreenSnapshot] = []
        var changelog: [ChangelogEntry] = []
        var received = Set<String>()
        let changelogIDs = Set(candidates.filter { $0.isChangelog && watchedPages.contains($0.pageID) }.map(\.id))
        let chunks = stride(from: 0, to: fetchIDs.count, by: FigmaAPI.nodesPerRequest)
            .map { Array(fetchIDs[$0..<min($0 + FigmaAPI.nodesPerRequest, fetchIDs.count)]) }
        for (index, chunk) in chunks.enumerated() {
            progress("\(info.name): 화면 받는 중 \(index + 1)/\(chunks.count)")
            let nodes = try FigmaAPI.parseNodes(await transport(
                FigmaAPI.nodesRequest(fileKey: source.fileKey, ids: chunk, version: info.version, token: token)))
            for id in chunk {
                // null로 온 노드(받는 사이 지워졌거나 권한 없음)는 받지 않은 것으로 둔다
                guard let node = nodes[id], let candidate = byID[id], let page = pageByID[candidate.pageID] else { continue }
                received.insert(id)
                if candidate.isChangelog {
                    changelog += SpecExtractor.changelog(in: node, page: page)
                } else {
                    screens += SpecExtractor.screens(in: node, page: page, sectionName: candidate.sectionName)
                }
            }
        }
        // 링크가 화면 프레임 자체면 그 화면만, 섹션·틀·페이지면 그 안에서 읽은 화면 전부를 링크의 화면으로 친다
        var frames: [String: [String]] = [:]
        if !scoped.isEmpty {
            let extracted = Set(screens.map(\.frameID))
            for scope in source.scope where found[scope.nodeID] != nil {
                frames[scope.nodeID] = extracted.contains(scope.nodeID) ? [scope.nodeID]
                    : screens.filter { screen in byID[screen.candidateID].map { FigmaAPI.covers([scope.nodeID], $0) } ?? false }.map(\.frameID)
            }
            let kept = Set(frames.values.joined())
            screens = screens.filter { kept.contains($0.frameID) }
        }
        var capture = DesignCapture(
            fileKey: source.fileKey, fileName: info.name, lastModified: info.lastModified,
            coveredPages: watchedPages, present: Set(pageScreens.map(\.id)), fetched: received.subtracting(changelogIDs),
            screens: screens,
            version: info.version,
            // 이력 프레임을 하나라도 못 받으면 지난 이력을 그대로 둔다. 비운 뒤 다시 받으면 옛 줄이 모두 새 줄로 보인다
            changelog: !changelogIDs.isEmpty && changelogIDs.isSubset(of: received) ? changelog : nil,
            menus: Set(source.menus))
        if !scoped.isEmpty {
            // 고른 화면의 경로만 기록한다. 이력도 그 화면을 적은 줄만 남는다
            capture.menus = Set(screens.map(\.menuPath))
            capture.scoped = true
            capture.resolved = source.scope.map { scope in
                guard let page = found[scope.nodeID] else { return scope }
                var scope = scope
                scope.pageID = page
                scope.frames = frames[scope.nodeID] ?? []
                return scope
            }
            capture.missing = source.scope.map(\.nodeID).filter { found[$0] == nil }
            // 처음 가져오는 링크의 화면은 기준만 세운다. 새로 생긴 화면이 아니라 이제 막 지켜보기 시작한 화면이다
            let fresh = Set(source.scope.filter { $0.frames == nil }.map(\.nodeID))
            capture.fresh = Set(screenCandidates.filter { FigmaAPI.covers(fresh, $0) }.map(\.id))
        }
        return .captured(capture)
    }

    /// 링크로 고른 노드 → 그 노드가 있는 페이지. 후보이거나 후보를 감싸거나 후보 바로 안에 있으면 찾은 것이다.
    static func located(_ nodeIDs: Set<String>, in candidates: [FigmaAPI.Candidate]) -> [String: String] {
        var found: [String: String] = [:]
        for candidate in candidates {
            for id in nodeIDs where found[id] == nil && FigmaAPI.covers([id], candidate) { found[id] = candidate.pageID }
        }
        return found
    }
}
