import Foundation

/// 한 번 가져와서 찾은 변경. 화면 하나 또는 제·개정 이력 한 줄에 대한 것이다.
public struct DesignEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case changed
        case added
        case removed
        /// 같은 화면 ID의 새 프레임이 옛 프레임을 대신했다 (복제해서 고친 뒤 옛 것을 지운 경우)
        case replaced
        /// 디자이너가 제·개정 이력 표에 적은 줄
        case changelog
    }

    public var id: UUID
    public var fileKey: String
    public var fileName: String
    public var frameID: String?
    public var screenID: String
    public var title: String
    public var menuPath: String
    public var detectedAt: Date
    /// 이 변경이 생긴 구간. 시작은 직전에 확인한 때, 끝은 파일이 마지막으로 고쳐진 때다.
    public var windowStart: Date?
    public var windowEnd: Date
    public var kind: Kind
    public var changes: [SpecChange]
    public var note: String?
    /// 바뀔 때 화면이 어떤 단계였는지. 이 칸이 생기기 전 기록은 nil이고 중요한 변경으로 본다.
    public var phase: Phase?
    /// 바뀌기 전과 뒤의 파일 버전. 상세에서 그 버전 그대로 프레임 이미지를 받아 견준다 (이 칸이 생기기 전 기록은 nil).
    public var beforeVersion: String?
    public var afterVersion: String?
    /// 새 프레임으로 바꾼 화면은 이전 이미지를 옛 프레임으로 그린다.
    public var beforeFrameID: String?
    /// 제·개정 이력 줄이 대괄호로 적은 메뉴들 (화면 경로). 이력을 그 메뉴의 변경으로 보이게 한다.
    public var menus: [String]?

    /// 이 변경이 그 경로(아래 경로 포함)의 것인지. 이력 줄은 적은 메뉴로도 본다.
    public func concerns(_ path: String) -> Bool {
        DesignStatus.covers(path, menuPath) || (menus ?? []).contains { DesignStatus.covers(path, $0) || DesignStatus.covers($0, path) }
    }

    public enum Phase: String, Codable, Sendable {
        /// 완료된 화면이 다시 바뀌었다 (알림 대상)
        case afterDone
        /// 이번 변경으로 완료됐다 (알림 대상: 이제 개발을 시작해도 된다)
        case completed
        /// 작업 중인 화면이 바뀌었다. 같은 날 여러 번 바뀌면 한 건으로 합친다
        case working
    }

    /// 완료 후 변경, 막 완료됨, 디자이너가 적은 이력. 미확인 건수와 알림은 이것만 센다.
    public var isImportant: Bool { phase != .working }

    public init(id: UUID = UUID(), fileKey: String, fileName: String, frameID: String?, screenID: String, title: String,
                menuPath: String, detectedAt: Date, windowStart: Date?, windowEnd: Date, kind: Kind,
                changes: [SpecChange], note: String? = nil, phase: Phase? = nil) {
        self.id = id
        self.fileKey = fileKey
        self.fileName = fileName
        self.frameID = frameID
        self.screenID = screenID
        self.title = title
        self.menuPath = menuPath
        self.detectedAt = detectedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.kind = kind
        self.changes = changes
        self.note = note
        self.phase = phase
    }

    /// 번호만 밀린 명세는 세지 않는다. 앞에 하나 끼우면 뒤가 다 밀려 변경이 부풀어 보인다.
    public func count(_ layer: SpecChange.Layer) -> Int {
        changes.filter { $0.layer == layer && $0.op != .renumbered }.count
    }

    public var renumberedCount: Int { changes.filter { $0.op == .renumbered }.count }

    /// `명세 2 · 문구 3`
    public var summary: String {
        switch kind {
        case .added: return "새 화면"
        case .removed: return "화면 삭제"
        case .changelog: return "제·개정 이력"
        case .changed, .replaced:
            let names: [(SpecChange.Layer, String)] = [(.spec, "명세"), (.text, "문구"), (.header, "화면 정보"), (.component, "컴포넌트")]
            let parts = names.compactMap { layer, name in count(layer) > 0 ? "\(name) \(count(layer))" : nil }
            let body = parts.isEmpty ? (renumberedCount > 0 ? "명세 번호 이동 \(renumberedCount)" : "변경 없음") : parts.joined(separator: " · ")
            return kind == .replaced ? "새 프레임 · " + body : body
        }
    }

    /// 레드마인·MR에 붙일 글. 회사 양식대로 대괄호 머리와 명사형 줄로 쓴다.
    public var report: String {
        var lines = ["[디자인 변경] \(screenID) \(title)".trimmingCharacters(in: .whitespaces)]
        if !menuPath.isEmpty { lines.append("- 화면 경로: \(menuPath)") }
        switch kind {
        case .added: lines.append("- 새 화면 추가")
        case .removed: lines.append("- 화면 삭제")
        case .changelog: if let note, !note.isEmpty { lines.append("- 이력: \(DesignText.headline(note, limit: 200))") }
        case .replaced: lines.append("- 새 프레임으로 교체")
        case .changed: break
        }
        for change in changes where change.op != .renumbered { lines.append("- " + Self.line(change)) }
        if renumberedCount > 0 { lines.append("- 명세 번호 이동 \(renumberedCount)건") }
        return lines.joined(separator: "\n")
    }

    static func line(_ change: SpecChange) -> String {
        // 목업 요소는 어느 영역인지 붙여 마크업할 곳을 바로 찾게 한다
        let containers = change.place.map { Array($0.path.dropLast()) } ?? []
        let text = body(change)
        return containers.isEmpty ? text : text + " (위치: " + containers.joined(separator: " › ") + ")"
    }

    private static func body(_ change: SpecChange) -> String {
        let layer = ["header": "화면 정보", "spec": "명세", "text": "문구", "component": "컴포넌트"][change.layer.rawValue] ?? ""
        let one = { (text: String?) in DesignText.headline(text ?? "", limit: 80) }
        switch change.op {
        case .added: return "\(layer) 추가: \(change.layer == .spec ? change.label : one(change.after))"
        case .removed: return "\(layer) 삭제: \(change.layer == .spec ? change.label : one(change.before))"
        case .renumbered: return "\(layer) 번호 변경: \(change.before ?? "") → \(change.after ?? "") \(DesignText.headline(change.label))"
        case .modified:
            if change.layer == .spec { return "\(layer) 수정: \(change.label)" }
            return "\(change.layer == .header ? change.label : layer) 수정: \(one(change.before)) → \(one(change.after))"
        }
    }
}

/// 지켜보는 피그마 파일 하나의 마지막 상태.
public struct DesignFileRecord: Codable, Equatable, Sendable {
    public var name: String
    public var lastModified: String?
    /// 마지막으로 받은 파일 버전 ID. 다음 변경의 "이전" 이미지를 이 버전으로 그린다.
    public var version: String?
    /// 프레임 ID → 마지막으로 본 화면
    public var screens: [String: ScreenSnapshot]
    /// 프레임 ID → 마지막으로 확인한 때. 변경 구간의 시작이다.
    public var checkedAt: [String: Date]
    /// 프레임 ID → 내용을 받았을 때의 파일 버전(lastModified). 받지 않은 화면은 확인한 것으로 치지 않는다.
    public var fetchedVersion: [String: String]
    public var changelog: [ChangelogEntry]
    public var syncedAt: Date
    /// 받아 보니 화면설계서 화면이 아니었던 후보 (간지, 상태 화면 등)와 그렇게 본 때. 한동안 다시 받지 않는다.
    public var ignored: [String: Date]
    /// 오늘 작업 중 변경을 합칠 때 견줄 처음 상태. 프레임 ID → 그날 첫 변경 직전의 화면.
    public var mergeBase: [String: ScreenSnapshot]?

    /// 화면이 아니었던 후보도 디자이너가 고쳤을 수 있어 이만큼 지나면 다시 받아 본다.
    public static let ignoreDays = 7.0

    public init(name: String, lastModified: String?, version: String? = nil, screens: [String: ScreenSnapshot], checkedAt: [String: Date],
                fetchedVersion: [String: String] = [:], changelog: [ChangelogEntry], syncedAt: Date, ignored: [String: Date] = [:]) {
        self.version = version
        self.name = name
        self.lastModified = lastModified
        self.screens = screens
        self.checkedAt = checkedAt
        self.fetchedVersion = fetchedVersion
        self.changelog = changelog
        self.syncedAt = syncedAt
        self.ignored = ignored
    }

    /// 다음에 받을 후보. 화면이 아니었던 것은 빼고, `menus`가 있으면 그 경로의 화면을 품은 후보와 처음 보는 후보만.
    public func candidatesToFetch(_ candidates: [String], menus: Set<String>) -> [String] {
        // 틀 프레임 하나에 여러 메뉴의 화면이 섞일 수 있어 후보마다 경로를 모두 모은다
        var known: [String: Set<String>] = [:]
        for screen in screens.values { known[screen.candidateID, default: []].insert(screen.menuPath) }
        return candidates.filter { id in
            guard ignored[id] == nil else { return false }
            guard !menus.isEmpty, let paths = known[id] else { return true }
            return !paths.isDisjoint(with: menus)
        }
    }
}

/// 한 번 가져온 결과.
public struct DesignCapture: Sendable {
    public var fileKey: String
    public var fileName: String
    public var lastModified: String
    /// 이번에 살펴본 페이지들. 그 밖의 페이지에 있던 화면은 그대로 둔다.
    public var coveredPages: Set<String>
    /// 살펴본 페이지에 지금 있는 화면 후보 프레임 전부. 여기 없는 후보에서 나온 옛 화면은 지워진 것이다.
    public var present: Set<String>
    /// 이번에 내용을 실제로 받은 후보. 받지 못했거나 받지 않은 후보의 화면은 바뀌지 않은 것으로 본다.
    public var fetched: Set<String>
    /// 받은 후보에서 찾은 화면.
    public var screens: [ScreenSnapshot]
    /// 받지 못했으면 nil. nil이면 직전 이력을 그대로 둔다.
    public var changelog: [ChangelogEntry]?
    /// 받은 파일 버전 ID.
    public var version: String?
    /// 지켜보는 화면 경로. 비어 있으면 전부. 이 밖의 화면은 기준만 고치고 변경으로 남기지 않는다.
    public var menus: Set<String>
    /// 화면이 완료됐는지 정하는 규칙.
    public var rules = DesignStatusRules()

    public init(fileKey: String, fileName: String, lastModified: String, coveredPages: Set<String>, present: Set<String>,
                fetched: Set<String>, screens: [ScreenSnapshot], version: String? = nil, changelog: [ChangelogEntry]?,
                menus: Set<String> = []) {
        self.version = version
        self.fileKey = fileKey
        self.fileName = fileName
        self.lastModified = lastModified
        self.coveredPages = coveredPages
        self.present = present
        self.fetched = fetched
        self.screens = screens
        self.changelog = changelog
        self.menus = menus
    }

    /// 받았지만 화면이 하나도 없던 후보.
    var nonScreens: Set<String> { fetched.subtracting(screens.map(\.candidateID)) }

    func watches(_ path: String) -> Bool { menus.isEmpty || menus.contains(path) }
}

public struct DesignHistory: Codable, Equatable, Sendable {
    public var files: [String: DesignFileRecord]
    /// 오래된 것이 앞.
    public var events: [DesignEvent]
    public var seen: Set<UUID>
    /// 마크업에 반영을 마친 변경. 목록·배지·알림에서 빠지고 "반영 완료" 보기에만 남는다.
    public var applied: Set<UUID>
    /// 변경 ID 문자열 → 그 안에서 반영한 항목 (`SpecChange.key`). UUID 열쇠는 JSON에서 배열이 되어 문자열로 둔다.
    public var checked: [String: Set<String>]

    /// 이보다 오래된 변경은 지운다. 화면설계서는 몇 달이면 다시 짜인다.
    public static let keepDays = 365
    public static let keepCount = 5000

    public init(files: [String: DesignFileRecord] = [:], events: [DesignEvent] = [], seen: Set<UUID> = [],
                applied: Set<UUID> = [], checked: [String: Set<String>] = [:]) {
        self.files = files
        self.events = events
        self.seen = seen
        self.applied = applied
        self.checked = checked
    }

    private enum CodingKeys: String, CodingKey { case files, events, seen, applied, checked }

    /// 반영 칸이 생기기 전 파일도 읽는다.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([String: DesignFileRecord].self, forKey: .files)
        events = try container.decode([DesignEvent].self, forKey: .events)
        seen = try container.decode(Set<UUID>.self, forKey: .seen)
        applied = try container.decodeIfPresent(Set<UUID>.self, forKey: .applied) ?? []
        checked = try container.decodeIfPresent([String: Set<String>].self, forKey: .checked) ?? [:]
    }

    /// 가져온 화면을 직전 상태와 비교해 바뀐 것만 남긴다. 파일을 처음 가져올 때는 기준만 세운다.
    @discardableResult
    public mutating func record(_ capture: DesignCapture, at date: Date, calendar: Calendar = .current) -> [DesignEvent] {
        let edited = Self.date(capture.lastModified).map { min($0, date) } ?? date
        let fetchedScreens = Dictionary(capture.screens.map { ($0.frameID, capture.lastModified) }, uniquingKeysWith: { _, last in last })
        guard var file = files[capture.fileKey] else {
            files[capture.fileKey] = DesignFileRecord(
                name: capture.fileName, lastModified: capture.lastModified, version: capture.version,
                screens: Dictionary(capture.screens.map { ($0.frameID, $0) }, uniquingKeysWith: { _, last in last }),
                checkedAt: Dictionary(capture.screens.map { ($0.frameID, date) }, uniquingKeysWith: { _, last in last }),
                fetchedVersion: fetchedScreens, changelog: capture.changelog ?? [], syncedAt: date,
                ignored: Dictionary(capture.nonScreens.map { ($0, date) }, uniquingKeysWith: { first, _ in first }))
            return []
        }
        func event(_ kind: DesignEvent.Kind, _ screen: ScreenSnapshot, _ changes: [SpecChange], since: Date?, note: String? = nil,
                   phase: DesignEvent.Phase) -> DesignEvent {
            // 받지 않은 채 확인 시각만 앞선 화면이라도 구간이 거꾸로 나오지 않게 한다
            var made = DesignEvent(fileKey: capture.fileKey, fileName: capture.fileName, frameID: screen.frameID, screenID: screen.screenID,
                                   title: screen.title, menuPath: screen.menuPath, detectedAt: date, windowStart: since.map { min($0, edited) },
                                   windowEnd: edited, kind: kind, changes: changes, note: note, phase: phase)
            // 새 화면은 이전이 없고, 지운 화면은 이후가 없다
            made.beforeVersion = kind == .added ? nil : file.version
            made.afterVersion = kind == .removed ? nil : capture.version
            return made
        }
        func state(_ screen: ScreenSnapshot) -> ScreenState { DesignStatus.state(of: screen, rules: capture.rules) }
        /// 바뀌기 전에 완료였으면 완료 후 변경, 이번에 완료가 됐으면 완료됨, 아니면 작업 중.
        func phase(from old: ScreenSnapshot?, to new: ScreenSnapshot?) -> DesignEvent.Phase {
            let before = old.map(state)
            let after = new.map(state)
            if before == .done { return .afterDone }
            if after == .done { return old == nil ? .afterDone : .completed }
            return .working
        }
        // 오늘 아직 확인하지 않은 작업 중 변경만 합칠 수 있다. 그 밖의 비교 기준은 버린다
        let mergeable = Dictionary(events.enumerated().filter { _, old in
            old.fileKey == capture.fileKey && old.kind == .changed && old.phase == .working && !isSeen(old)
                && calendar.isDate(old.detectedAt, inSameDayAs: date)
        }.compactMap { index, old in old.frameID.map { ($0, index) } }, uniquingKeysWith: { _, last in last })
        var bases = (file.mergeBase ?? [:]).filter { mergeable[$0.key] != nil }
        var dropped = Set<Int>()

        var created: [DesignEvent] = []
        let extracted = Set(capture.screens.map(\.frameID))
        let producers = Set(file.screens.values.map(\.candidateID))
        let gone = file.screens.values
            .filter { old in
                // 틀을 풀어 다른 후보에서 다시 읽힌 화면은 지워진 것이 아니다
                guard capture.coveredPages.contains(old.pageID), !extracted.contains(old.frameID) else { return false }
                if !capture.present.contains(old.candidateID) { return true }
                return capture.fetched.contains(old.candidateID)
            }
            .sorted { $0.frameID < $1.frameID }
        var replaced = Set<String>()
        for screen in capture.screens {
            if let old = file.screens[screen.frameID] {
                let changes = SpecDiff.changes(from: old, to: screen)
                let stage = phase(from: old, to: screen)
                if !changes.isEmpty, capture.watches(screen.menuPath) || capture.watches(old.menuPath) {
                    if stage == .working, let index = mergeable[screen.frameID], let base = bases[screen.frameID] {
                        // 작업 중 화면은 하루에 몇 번이고 바뀌어서, 그날 처음 상태와 견준 한 건으로 고친다
                        let merged = SpecDiff.changes(from: base, to: screen)
                        if merged.isEmpty {
                            dropped.insert(index)
                        } else {
                            events[index].changes = merged
                            events[index].detectedAt = date
                            events[index].windowEnd = max(edited, events[index].windowStart ?? edited)
                            events[index].title = screen.title
                            events[index].menuPath = screen.menuPath
                            // 합친 건의 이전은 그날 처음 상태 그대로, 이후만 지금 버전으로
                            events[index].afterVersion = capture.version
                        }
                    } else {
                        created.append(event(.changed, screen, changes, since: file.checkedAt[screen.frameID], phase: stage))
                        if stage == .working { bases[screen.frameID] = old }
                    }
                }
            } else if let old = gone.first(where: { $0.screenID == screen.screenID && !replaced.contains($0.frameID) }) {
                replaced.insert(old.frameID)
                if capture.watches(screen.menuPath) || capture.watches(old.menuPath) {
                    var made = event(.replaced, screen, SpecDiff.changes(from: old, to: screen),
                                     since: file.checkedAt[old.frameID], note: old.frameName, phase: phase(from: old, to: screen))
                    made.beforeFrameID = old.frameID
                    created.append(made)
                }
            } else if capture.watches(screen.menuPath) {
                // 완료로 보는 메뉴에 새 화면이 생기면 그것도 추가 작업이다
                created.append(event(.added, screen, [], since: file.syncedAt, phase: phase(from: nil, to: screen)))
            }
            file.screens[screen.frameID] = screen
            file.checkedAt[screen.frameID] = date
            file.fetchedVersion[screen.frameID] = capture.lastModified
        }
        for old in gone {
            if !replaced.contains(old.frameID), capture.watches(old.menuPath) {
                created.append(event(.removed, old, [], since: file.checkedAt[old.frameID],
                                     phase: state(old) == .done ? .afterDone : .working))
            }
            file.screens[old.frameID] = nil
            file.checkedAt[old.frameID] = nil
            file.fetchedVersion[old.frameID] = nil
        }

        if let entries = capture.changelog {
            let known = Dictionary(file.changelog.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let watchedScreens = Set(file.screens.values.filter { capture.watches($0.menuPath) }.map(\.screenID))
            let watchedPages = Set(file.screens.values.filter { capture.watches($0.menuPath) }.map(\.pageID))
            let allPaths = Set(file.screens.values.map(\.menuPath))
            // 페이지 이름은 `(10/19 수정)`처럼 자주 바뀌어서 내용이 같으면 같은 줄로 본다
            for entry in entries where known[entry.key]?.text != entry.text {
                // 메뉴를 골랐으면 그 화면을 적은 줄, 화면 ID가 없으면 그 화면이 있는 페이지의 줄만
                let ids = entry.screenIDs
                let named = entry.menus(in: allPaths)
                let watchesNamed = named.contains { menu in capture.menus.contains { DesignStatus.covers(menu, $0) || DesignStatus.covers($0, menu) } }
                guard capture.menus.isEmpty || !watchedScreens.isDisjoint(with: ids) || watchesNamed
                        || (ids.isEmpty && named.isEmpty && watchedPages.contains(entry.pageID))
                else { continue }
                let before = known[entry.key]
                let title = [entry.version.map { "v\($0)" }, entry.date].compactMap { $0 }.joined(separator: " ")
                let changes = before.map { [SpecChange(layer: .header, op: .modified, label: "이력", before: $0.text, after: entry.text)] } ?? []
                // 디자이너가 이력에 적었다는 것 자체가 손본 시안이라는 뜻이라 중요한 변경으로 둔다
                var made = DesignEvent(fileKey: capture.fileKey, fileName: capture.fileName, frameID: entry.frameID,
                                       screenID: ids.joined(separator: ", "), title: title,
                                       menuPath: named.first ?? entry.pageName, detectedAt: date, windowStart: min(file.syncedAt, edited),
                                       windowEnd: edited, kind: .changelog, changes: changes, note: entry.text, phase: .afterDone)
                made.menus = named.isEmpty ? nil : named
                created.append(made)
            }
            file.changelog = entries
        }

        for index in dropped.sorted(by: >) {
            forgetState(events[index].id)
            events.remove(at: index)
        }
        file.mergeBase = bases.isEmpty ? nil : bases
        file.name = capture.fileName
        file.lastModified = capture.lastModified
        if let version = capture.version { file.version = version }
        file.syncedAt = date
        // 한때 화면을 냈던 후보는 잠깐 헤더를 숨겼을 수 있어 무시하지 않는다. 무시한 지 오래된 후보는 다시 받아 본다
        let limit = date.addingTimeInterval(-DesignFileRecord.ignoreDays * 86_400)
        file.ignored = file.ignored.filter { $0.value > limit }
        for id in capture.nonScreens.subtracting(producers) where file.ignored[id] == nil { file.ignored[id] = date }
        files[capture.fileKey] = file
        events.append(contentsOf: created)
        prune(now: date)
        return created
    }

    /// 파일이 직전과 같은 버전이면 그때까지 바뀐 게 없으니, 다음 변경 구간의 시작을 지금으로 당긴다.
    /// 메뉴를 골라 받지 않은 화면은 내용이 옛 버전이라 당기지 않는다.
    public mutating func confirmUnchanged(fileKey: String, at date: Date) {
        guard var file = files[fileKey] else { return }
        for key in file.checkedAt.keys where file.fetchedVersion[key] == file.lastModified { file.checkedAt[key] = date }
        file.syncedAt = date
        files[fileKey] = file
    }

    /// 더 지켜보지 않는 파일의 기록을 지운다.
    public mutating func forget(fileKey: String) {
        files[fileKey] = nil
        let removed = Set(events.filter { $0.fileKey == fileKey }.map(\.id))
        events.removeAll { removed.contains($0.id) }
        seen.subtract(removed)
        applied.subtract(removed)
        for id in removed { checked[id.uuidString] = nil }
    }

    public mutating func prune(now: Date) {
        let limit = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        events.removeAll { $0.detectedAt < limit }
        if events.count > Self.keepCount { events.removeFirst(events.count - Self.keepCount) }
        let ids = Set(events.map(\.id))
        seen.formIntersection(ids)
        applied.formIntersection(ids)
        checked = checked.filter { key, _ in UUID(uuidString: key).map(ids.contains) ?? false }
    }

    private mutating func forgetState(_ id: UUID) {
        seen.remove(id)
        applied.remove(id)
        checked[id.uuidString] = nil
    }

    /// 반영까지 마친 변경은 본 것으로 친다.
    public func isSeen(_ event: DesignEvent) -> Bool { seen.contains(event.id) || applied.contains(event.id) }

    public func isApplied(_ event: DesignEvent) -> Bool { applied.contains(event.id) }

    public func checkedKeys(_ event: DesignEvent) -> Set<String> { checked[event.id.uuidString] ?? [] }

    /// 반영한 항목 수와 반영할 항목 수 (번호만 바뀐 명세는 고칠 것이 없어 뺀다).
    public func progress(_ event: DesignEvent) -> (done: Int, total: Int) {
        let keys = Set(event.changes.filter { $0.op != .renumbered }.map(\.key))
        return ((checked[event.id.uuidString] ?? []).intersection(keys).count, keys.count)
    }

    /// 확인하지 않은 중요한 변경. 작업 중 변경은 세지 않는다.
    public var unseenCount: Int { events.filter { $0.isImportant && !isSeen($0) }.count }

    // MARK: 보기

    public struct Menu: Equatable, Hashable, Identifiable, Sendable {
        public var fileKey: String
        public var fileName: String
        public var path: String
        public var screenCount: Int
        public var unseen: Int
        public var lastChange: Date?

        public var id: String { fileKey + "|" + path }
    }

    /// 파일마다 화면 경로 목록. 화면이 없어진 경로도 변경 기록이 남아 있으면 보여 준다.
    public func menus() -> [Menu] {
        var table: [String: Menu] = [:]
        for (key, file) in files {
            for screen in file.screens.values {
                let id = key + "|" + screen.menuPath
                table[id, default: Menu(fileKey: key, fileName: file.name, path: screen.menuPath, screenCount: 0, unseen: 0)]
                    .screenCount += 1
            }
        }
        for event in events {
            // 이력 줄이 메뉴 여럿을 적었으면 그 메뉴마다 센다
            for path in Set([event.menuPath] + (event.menus ?? [])) {
                let id = event.fileKey + "|" + path
                var menu = table[id] ?? Menu(fileKey: event.fileKey, fileName: event.fileName, path: path, screenCount: 0, unseen: 0)
                if event.isImportant && !isSeen(event) { menu.unseen += 1 }
                menu.lastChange = max(menu.lastChange ?? event.detectedAt, event.detectedAt)
                table[id] = menu
            }
        }
        return table.values.sorted { ($0.fileName, $0.path) < ($1.fileName, $1.path) }
    }

    public struct Day: Identifiable, Equatable, Sendable {
        public var day: Date
        public var events: [DesignEvent]

        public var id: Date { day }
    }

    /// 감지한 날짜별로, 최근 날과 최근 변경이 위.
    public static func days(_ events: [DesignEvent], calendar: Calendar = .current) -> [Day] {
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.detectedAt) }
        return grouped.keys.sorted(by: >).map { day in
            Day(day: day, events: grouped[day]!.sorted { $0.detectedAt != $1.detectedAt ? $0.detectedAt > $1.detectedAt : $0.screenID < $1.screenID })
        }
    }

    /// 피그마가 주는 `2026-10-19T08:21:33Z` (밀리초가 붙기도 한다).
    public static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// 디자인 변경 기록 파일. 화면 내용은 이 Mac에만 둔다.
public enum DesignHistoryFile {
    /// `RUNTIME_DESIGN_HISTORY`로 다른 파일을 쓰게 할 수 있다.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["RUNTIME_DESIGN_HISTORY"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunTime/design-history.json")
    }

    /// 파일이 없으면 빈 기록. 깨진 파일은 덮어쓰지 않게 오류를 낸다.
    public static func load(_ url: URL = defaultURL) throws -> DesignHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return DesignHistory() }
        return try decode(Data(contentsOf: url))
    }

    public static func save(_ history: DesignHistory, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(history).write(to: url, options: .atomic)
    }

    public static func encode(_ history: DesignHistory) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        // 화면 스냅샷이 커서 줄을 나누지 않는다. 키 순서만 고정해 저장할 때마다 내용이 흔들리지 않게 한다
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(history)
    }

    public static func decode(_ data: Data) throws -> DesignHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        return try decoder.decode(DesignHistory.self, from: data)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
