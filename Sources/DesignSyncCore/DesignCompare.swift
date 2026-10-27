import Foundation

/// 한 파일 버전에서 받은 화면. 버전은 바뀌지 않아 한 번 받은 후보는 다시 받지 않는다.
public struct VersionSnapshot: Codable, Equatable, Sendable {
    public var fileKey: String
    public var version: String
    public var pages: [SpecExtractor.Page]?
    public var candidates: [FigmaAPI.Candidate]?
    /// 뼈대를 받은 페이지. nil이면 모든 페이지다. 화면 하나만 견줄 때는 그 페이지만 받는다.
    public var outlined: Set<String>?
    /// 후보 ID → 그 후보에서 찾은 화면. 그 버전에 없던 후보는 빈 배열이다.
    public var screens: [String: [ScreenSnapshot]]
    /// 이력 후보 ID → 그 표의 줄.
    public var changelog: [String: [ChangelogEntry]]

    public init(fileKey: String, version: String) {
        self.fileKey = fileKey
        self.version = version
        screens = [:]
        changelog = [:]
    }

    /// 앱이 마지막으로 가져온 상태를 그 버전의 화면으로 쓴다. 오늘과 견줄 때 최신 버전을 다시 받지 않는다.
    public init?(record: DesignFileRecord, fileKey: String) {
        guard let version = record.version else { return nil }
        self.init(fileKey: fileKey, version: version)
        var candidates: [String: FigmaAPI.Candidate] = [:]
        for screen in record.screens.values {
            screens[screen.candidateID, default: []].append(screen)
            candidates[screen.candidateID] = FigmaAPI.Candidate(id: screen.candidateID, name: screen.frameName, pageID: screen.pageID,
                                                                sectionName: screen.sectionName, isChangelog: false)
        }
        for entry in record.changelog {
            let id = entry.frameID ?? "changelog:" + entry.pageID
            changelog[id, default: []].append(entry)
            candidates[id] = FigmaAPI.Candidate(id: id, name: "", pageID: entry.pageID, sectionName: "", isChangelog: true)
        }
        self.candidates = Array(candidates.values)
    }

    public var allScreens: [ScreenSnapshot] { screens.values.flatMap { $0 } }
    public var allChangelog: [ChangelogEntry] { changelog.values.flatMap { $0 } }

    /// 그 페이지의 뼈대를 받았는지.
    public func outlines(_ pageID: String) -> Bool {
        candidates != nil && (outlined?.contains(pageID) ?? true)
    }

    /// 이 버전에서 받을 것이 남았는지.
    public func missing(_ wanted: (FigmaAPI.Candidate) -> Bool) -> [FigmaAPI.Candidate] {
        (candidates ?? []).filter { candidate in
            wanted(candidate) && (candidate.isChangelog ? changelog[candidate.id] == nil : screens[candidate.id] == nil)
        }
    }
}

/// 두 날짜(버전)의 화면설계서를 견준다. 지켜보며 쌓은 기록이 없던 때도 피그마 버전 기록으로 본다.
public enum DesignCompare {
    /// 그 날 끝(다음 날 0시) 전에 저장된 마지막 버전. 버전 목록은 최근 것부터다.
    public static func version(atEndOf day: Date, in versions: [FigmaAPI.FileVersion], calendar: Calendar = .current) -> FigmaAPI.FileVersion? {
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return nil }
        return versions.filter { $0.createdAt < end }.max { $0.createdAt < $1.createdAt }
    }

    /// 새로 받은 첫 쪽과 저장해 둔 목록을 잇는다. 첫 쪽이 저장한 것 가운데 가장 새 버전까지 닿지 않으면 사이가 비어 nil.
    public static func merge(latest: [FigmaAPI.FileVersion], saved: [FigmaAPI.FileVersion]) -> [FigmaAPI.FileVersion]? {
        guard let oldest = latest.last, let newestSaved = saved.first, latest.contains(where: { $0.id == newestSaved.id }) else { return nil }
        let ids = Set(latest.map(\.id))
        return latest + saved.filter { !ids.contains($0.id) && $0.createdAt <= oldest.createdAt }
    }

    /// 두 버전 사이에 디자이너가 이름을 붙여 저장한 버전 (오래된 것부터).
    public static func named(between from: FigmaAPI.FileVersion, and to: FigmaAPI.FileVersion, in versions: [FigmaAPI.FileVersion]) -> [FigmaAPI.FileVersion] {
        versions.filter { $0.label != nil && $0.createdAt > from.createdAt && $0.createdAt <= to.createdAt }.sorted { $0.createdAt < $1.createdAt }
    }

    /// `snapshot`에 비어 있는 것을 채운다: 페이지 목록 → 페이지 뼈대 → `wanted` 후보와 이력 표.
    /// `pageIDs`를 주면 그 페이지만 살펴 받는다. 페이지마다 요청 한 번이 들어 화면 하나를 견줄 때 크게 줄어든다.
    public static func fill(_ snapshot: inout VersionSnapshot, skippedPages: Set<String> = [], pageIDs: Set<String>? = nil, token: String,
                            wanted: (FigmaAPI.Candidate) -> Bool, transport: DesignSyncEngine.Transport,
                            progress: @Sendable (String) -> Void = { _ in }) async throws {
        let key = snapshot.fileKey, version = snapshot.version
        // 페이지를 골랐으면 페이지 목록 없이 그 페이지들만 한 번에 받는다 (이름도 함께 온다).
        // 그렇게 받은 목록은 일부라, 모든 페이지를 볼 때 다시 받는다
        if pageIDs == nil, snapshot.pages == nil || snapshot.outlined != nil {
            let info = try FigmaAPI.parseFile(await transport(FigmaAPI.fileRequest(fileKey: key, version: version, token: token)))
            snapshot.pages = info.pages.filter { !FigmaAPI.isSkippedPage($0.name) && !skippedPages.contains($0.id) }
            // 화면마다 페이지를 따로 받아 이미 모든 페이지를 살폈으면 전체로 본다
            if let outlined = snapshot.outlined, outlined.isSuperset(of: (snapshot.pages ?? []).map(\.id)) { snapshot.outlined = nil }
        }
        var pages = snapshot.pages ?? []
        let todo = pageIDs.map { ids in ids.filter { !skippedPages.contains($0) && !snapshot.outlines($0) }.sorted() }
            ?? pages.map(\.id).filter { !snapshot.outlines($0) }
        if !todo.isEmpty || snapshot.candidates == nil {
            var found = snapshot.candidates ?? []
            let had = Set(found.map(\.id))
            let batches = pageIDs == nil ? todo.map { [$0] }
                : stride(from: 0, to: todo.count, by: FigmaAPI.nodesPerRequest).map { Array(todo[$0..<min($0 + FigmaAPI.nodesPerRequest, todo.count)]) }
            for (index, ids) in batches.enumerated() {
                progress(batches.count > 1 ? "페이지 살펴보는 중 \(index + 1)/\(batches.count)" : "페이지 살펴보는 중")
                let outline = try FigmaAPI.parseNodes(await transport(
                    FigmaAPI.nodesRequest(fileKey: key, ids: ids, depth: FigmaAPI.outlineDepth, version: version, token: token)))
                for id in ids {
                    guard let node = outline[id] else { continue }
                    if !pages.contains(where: { $0.id == id }) {
                        guard !FigmaAPI.isSkippedPage(node.name) else { continue }
                        pages.append(SpecExtractor.Page(id: id, name: node.name))
                    }
                    found += FigmaAPI.candidates(in: node, pageID: id).filter { !had.contains($0.id) }
                }
            }
            let outlinedBefore = snapshot.candidates == nil ? [] : snapshot.outlined
            snapshot.pages = pages
            snapshot.candidates = found
            snapshot.outlined = pageIDs == nil ? nil : outlinedBefore.map { $0.union(todo) }
        }
        let missing = snapshot.missing { (pageIDs?.contains($0.pageID) ?? true) && wanted($0) }
        let pageByID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chunks = stride(from: 0, to: missing.count, by: FigmaAPI.nodesPerRequest)
            .map { Array(missing[$0..<min($0 + FigmaAPI.nodesPerRequest, missing.count)]) }
        for (index, chunk) in chunks.enumerated() {
            progress("화면 받는 중 \(index + 1)/\(chunks.count)")
            let nodes = try FigmaAPI.parseNodes(await transport(
                FigmaAPI.nodesRequest(fileKey: key, ids: chunk.map(\.id), version: version, token: token)))
            for candidate in chunk {
                guard let page = pageByID[candidate.pageID] else { continue }
                let node = nodes[candidate.id]
                if candidate.isChangelog {
                    snapshot.changelog[candidate.id] = node.map { SpecExtractor.changelog(in: $0, page: page) } ?? []
                } else {
                    snapshot.screens[candidate.id] = node.map { SpecExtractor.screens(in: $0, page: page, sectionName: candidate.sectionName) } ?? []
                }
            }
        }
    }

    /// 앞 버전과 뒤 버전에서 `include`에 드는 화면의 변경. 이력은 두 날짜 사이에 적힌 새 줄만.
    /// 두 버전 모두에서 받은 후보, 또는 한쪽 뼈대에만 있는 후보(새로 생겼거나 지운 것)만 견줘 받지 않은 것을 지운 것으로 보지 않는다.
    public static func events(fileKey: String, fileName: String, before: VersionSnapshot, after: VersionSnapshot,
                              beforeDate: Date, afterDate: Date, include: (ScreenSnapshot) -> Bool,
                              rules: DesignStatusRules = DesignStatusRules(), knownPaths: Set<String> = []) -> [DesignEvent] {
        let beforeOutline = Set((before.candidates ?? []).map(\.id)), afterOutline = Set((after.candidates ?? []).map(\.id))
        let pageOf = Dictionary(((before.candidates ?? []) + (after.candidates ?? [])).map { ($0.id, $0.pageID) }, uniquingKeysWith: { first, _ in first })
        // 다른 버전에서 그 페이지를 살펴보지 않았으면 없다고 볼 수 없다
        func comparable(_ candidate: String, other: VersionSnapshot, otherOutline: Set<String>) -> Bool {
            other.screens[candidate] != nil || (!otherOutline.contains(candidate) && pageOf[candidate].map(other.outlines) ?? true)
        }
        let old = before.screens.filter { comparable($0.key, other: after, otherOutline: afterOutline) }.values.flatMap { $0 }.filter(include)
        let new = after.screens.filter { comparable($0.key, other: before, otherOutline: beforeOutline) }.values.flatMap { $0 }.filter(include)
        let oldByFrame = Dictionary(old.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        let newFrames = Set(new.map(\.frameID))

        func state(_ screen: ScreenSnapshot) -> ScreenState { DesignStatus.state(of: screen, rules: rules) }
        func phase(_ from: ScreenSnapshot?, _ to: ScreenSnapshot?) -> DesignEvent.Phase {
            if from.map(state) == .done { return .afterDone }
            if to.map(state) == .done { return from == nil ? .afterDone : .completed }
            return .working
        }
        func make(_ kind: DesignEvent.Kind, _ screen: ScreenSnapshot, _ changes: [SpecChange], from: ScreenSnapshot?, to: ScreenSnapshot?) -> DesignEvent {
            var event = DesignEvent(fileKey: fileKey, fileName: fileName, frameID: screen.frameID, screenID: screen.screenID, title: screen.title,
                                    menuPath: screen.menuPath, detectedAt: afterDate, windowStart: beforeDate, windowEnd: afterDate, kind: kind,
                                    changes: changes, phase: phase(from, to))
            event.beforeVersion = kind == .added ? nil : before.version
            event.afterVersion = kind == .removed ? nil : after.version
            return event
        }

        var found: [DesignEvent] = []
        var gone = old.filter { !newFrames.contains($0.frameID) }
        for screen in new.sorted(by: { ($0.menuPath, $0.screenID, $0.frameID) < ($1.menuPath, $1.screenID, $1.frameID) }) {
            if let previous = oldByFrame[screen.frameID] {
                let changes = SpecDiff.changes(from: previous, to: screen)
                if !changes.isEmpty { found.append(make(.changed, screen, changes, from: previous, to: screen)) }
            } else if let index = gone.firstIndex(where: { $0.screenID == screen.screenID }) {
                let previous = gone.remove(at: index)
                var event = make(.replaced, screen, SpecDiff.changes(from: previous, to: screen), from: previous, to: screen)
                event.beforeFrameID = previous.frameID
                event.note = previous.frameName
                found.append(event)
            } else {
                found.append(make(.added, screen, [], from: nil, to: screen))
            }
        }
        for screen in gone { found.append(make(.removed, screen, [], from: screen, to: nil)) }

        // 이력 표는 날짜 칸으로 두 날짜 사이 줄만 고른다. 앞 버전에 이미 있던 줄은 뺀다
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.dateFormat = "yyyy-MM-dd"
        let start = format.string(from: beforeDate), end = format.string(from: afterDate)
        let known = Set(before.allChangelog.map(\.key))
        // 메뉴 하나만 받았으면 다른 메뉴 이름을 몰라 그 메뉴 이력을 페이지 이력으로 잘못 넣는다. 아는 경로를 모두 쓴다
        let paths = Set(after.allScreens.map(\.menuPath)).union(knownPaths)
        let watched = Set(new.map(\.menuPath))
        let watchedIDs = Set(new.map(\.screenID))
        for entry in after.allChangelog.sorted(by: { ($0.date, $0.order) < ($1.date, $1.order) })
        where entry.date >= start && entry.date <= end && !known.contains(entry.key) {
            let named = entry.menus(in: paths)
            let ids = entry.screenIDs
            // 메뉴나 화면 ID를 적은 줄은 그것으로, 아무것도 적지 않은 줄은 보는 화면이 있는 페이지의 줄이면 넣는다
            let relevant: Bool
            if !named.isEmpty || !ids.isEmpty {
                relevant = named.contains { menu in watched.contains { DesignStatus.covers(menu, $0) } } || !watchedIDs.isDisjoint(with: ids)
            } else {
                relevant = after.allScreens.contains { $0.pageID == entry.pageID && watched.contains($0.menuPath) }
            }
            guard relevant else { continue }
            var event = DesignEvent(fileKey: fileKey, fileName: fileName, frameID: entry.frameID, screenID: ids.joined(separator: ", "),
                                    title: [entry.version.map { "v\($0)" }, entry.date].compactMap { $0 }.joined(separator: " "),
                                    menuPath: named.first ?? entry.pageName, detectedAt: afterDate, windowStart: beforeDate, windowEnd: afterDate,
                                    kind: .changelog, changes: [], note: entry.text, phase: .afterDone)
            event.menus = named.isEmpty ? nil : named
            found.append(event)
        }
        return found
    }
}
