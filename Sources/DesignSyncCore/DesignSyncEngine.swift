import Foundation

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

    public init(fileKey: String, name: String = "", menus: [String] = [], skippedPages: [String] = [],
                alerts: [String] = [], statusOverrides: [String: Bool] = [:], hiddenMenus: [String] = [], isHidden: Bool = false) {
        self.hiddenMenus = hiddenMenus
        self.isHidden = isHidden
        self.fileKey = fileKey
        self.name = name
        self.menus = menus
        self.skippedPages = skippedPages
        self.alerts = alerts
        self.statusOverrides = statusOverrides
    }

    private enum CodingKeys: String, CodingKey { case fileKey, name, menus, skippedPages, alerts, statusOverrides, hiddenMenus, isHidden, intervalMinutes, untaggedIsDone }

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

        let pages = info.pages.filter { !FigmaAPI.isSkippedPage($0.name) && !source.skippedPages.contains($0.id) }
        var candidates: [FigmaAPI.Candidate] = []
        for (index, page) in pages.enumerated() {
            progress("\(info.name): 페이지 살펴보는 중 \(index + 1)/\(pages.count)")
            let outline = try FigmaAPI.parseNodes(await transport(
                FigmaAPI.outlineRequest(fileKey: source.fileKey, pageIDs: [page.id], version: info.version, token: token)))
            if let node = outline[page.id] { candidates += FigmaAPI.candidates(in: node, pageID: page.id) }
        }

        let screenCandidates = candidates.filter { !$0.isChangelog }
        let screenIDs = screenCandidates.map(\.id)
        let wanted = known?.candidatesToFetch(screenIDs, menus: Set(source.menus)) ?? screenIDs
        // 제·개정 이력은 작아서 늘 받는다
        let fetchIDs = candidates.filter(\.isChangelog).map(\.id) + wanted
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pageByID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var screens: [ScreenSnapshot] = []
        var changelog: [ChangelogEntry] = []
        var received = Set<String>()
        let changelogIDs = Set(candidates.filter(\.isChangelog).map(\.id))
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
        return .captured(DesignCapture(
            fileKey: source.fileKey, fileName: info.name, lastModified: info.lastModified,
            coveredPages: Set(pages.map(\.id)), present: Set(screenIDs), fetched: received.subtracting(changelogIDs),
            screens: screens,
            version: info.version,
            // 이력 프레임을 하나라도 못 받으면 지난 이력을 그대로 둔다. 비운 뒤 다시 받으면 옛 줄이 모두 새 줄로 보인다
            changelog: !changelogIDs.isEmpty && changelogIDs.isSubset(of: received) ? changelog : nil,
            menus: Set(source.menus)))
    }
}
