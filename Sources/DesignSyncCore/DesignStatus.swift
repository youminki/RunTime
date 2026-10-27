import Foundation

/// 화면이 완료된 시안인지. 알림은 완료된 화면이 다시 바뀔 때만 보내려고 가린다.
public enum ScreenState: String, Codable, Sendable {
    case done
    case working
    /// 섹션에 상태 표시가 없다
    case unknown
}

/// 화면 상태를 정하는 규칙. 자동 판정이 틀릴 수 있어 메뉴·화면마다 직접 정한 것이 먼저다.
public struct DesignStatusRules: Codable, Equatable, Sendable {
    /// 직접 정한 상태. 키는 화면 경로(그 아래 경로 포함) 또는 `screen:화면 ID`, 값이 true면 완료.
    public var overrides: [String: Bool]
    /// 상태 표시가 없는 화면. true면 완료, false면 작업 중, nil이면 모르는 채로 둔다 (알림 받는 메뉴만 알린다).
    public var untaggedIsDone: Bool?

    public init(overrides: [String: Bool] = [:], untaggedIsDone: Bool? = true) {
        self.overrides = overrides
        self.untaggedIsDone = untaggedIsDone
    }

    public static func screenKey(_ screenID: String) -> String { "screen:" + screenID }
}

public enum DesignStatus {
    /// 섹션 이름에 붙는 상태. 이 밖의 글자는 모르는 상태로 둔다.
    static let doneTags: Set<String> = ["완료"]
    static let workingTags: Set<String> = ["수정중", "수정 중", "작업중", "작업 중", "작업예정", "작업 예정", "보류", "작업 중/보류", "검토중", "검토 중"]

    /// 직접 정한 것 → 섹션의 상태 표시 → 표시가 없으면 규칙대로.
    public static func state(of screen: ScreenSnapshot, rules: DesignStatusRules) -> ScreenState {
        if let manual = rules.overrides[DesignStatusRules.screenKey(screen.screenID)] { return manual ? .done : .working }
        if let manual = override(for: screen.menuPath, in: rules.overrides) { return manual ? .done : .working }
        let found = tagged(screen)
        if found == .unknown { return rules.untaggedIsDone.map { $0 ? .done : .working } ?? .unknown }
        return found
    }

    /// 경로에 걸린 직접 정한 상태. 가장 긴(가장 구체적인) 경로가 이긴다.
    static func override(for path: String, in overrides: [String: Bool]) -> Bool? {
        overrides.filter { !$0.key.hasPrefix("screen:") && covers($0.key, path) }
            .max { $0.key.count < $1.key.count }?.value
    }

    /// `상품 관리`는 `상품 관리`와 `상품 관리 > 목록`을 덮지만 `상품 관리자`는 덮지 않는다.
    public static func covers(_ prefix: String, _ path: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + " > ")
    }

    /// 섹션에 `[완료]` 같은 상태나 `_v0.4` 같은 버전을 적는 화면설계서인지.
    /// 둘 다 쓰지 않는 디자이너는 다듬은 화면만 올려서, 표시 없는 화면을 작업 중으로 보면 완료 후 변경을 하나도 못 잡는다.
    public static func usesMarks<S: Sequence>(_ screens: S) -> Bool where S.Element == ScreenSnapshot {
        screens.contains { !segments($0.sectionName).isEmpty || hasVersion($0.sectionName) }
    }

    /// 사이드바가 그릴 때마다 화면 수만큼 부르므로 한 번만 만든다.
    private static let segmentPattern = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]([^\\[]*)")

    /// 섹션 이름의 `[상태] 구간`들. `[완료] 데이터셋 > 목록 / [수정중] 데이터셋 생성`처럼 한 섹션에 여럿일 수 있다.
    static func segments(_ section: String) -> [(tag: String, label: String)] {
        let pattern = segmentPattern
        let range = NSRange(section.startIndex..., in: section)
        return pattern.matches(in: section, range: range).compactMap { match in
            guard let tag = Range(match.range(at: 1), in: section), let label = Range(match.range(at: 2), in: section) else { return nil }
            let text = section[label].trimmingCharacters(in: CharacterSet(charactersIn: " /+,·").union(.whitespaces))
            return (section[tag].trimmingCharacters(in: .whitespaces), text)
        }
    }

    /// 섹션 상태 표시로 본 상태. 구간이 여럿이면 화면 경로·화면명과 가장 잘 맞는 구간을 쓴다.
    static func tagged(_ screen: ScreenSnapshot) -> ScreenState {
        let parts = segments(screen.sectionName)
        // 상태 대신 `API Gateway_v0.4`처럼 배포 버전을 붙이는 디자이너는 버전을 단 섹션을 내보낸 시안으로 쓴다
        guard !parts.isEmpty else { return hasVersion(screen.sectionName) ? .done : .unknown }
        let best = parts.count == 1 ? parts[0] : parts.max { score($0.label, screen) < score($1.label, screen) }!
        if doneTags.contains(best.tag) { return .done }
        if workingTags.contains(best.tag) { return .working }
        return .unknown
    }

    static let versionSuffix = "(?:^|[\\s_\\-(])[vV]\\d+(?:\\.\\d+)*\\)?\\s*$"

    /// `위젯관리_v0.4`, `상품 v1.2`, `상품 (v2)` → true
    static func hasVersion(_ section: String) -> Bool {
        section.range(of: versionSuffix, options: .regularExpression) != nil
    }

    /// 경로가 같으면 가장 높다. 그다음은 화면명에서 경로를 뺀 부분(탭·모달 이름)이 구간 이름과 겹칠 때다.
    /// `[완료] 상세 / [수정중] 컬럼 정보 탭`의 `상세 : (2)컬럼 정보` 화면은 경로가 `상세`여도 뒤 구간이다.
    static func score(_ label: String, _ screen: ScreenSnapshot) -> Double {
        guard !label.isEmpty else { return 0 }
        let squeeze = { (text: String) in text.filter { !$0.isWhitespace } }
        let labelLast = squeeze(last(label))
        let pathLast = squeeze(last(screen.menuPath))
        let title = squeeze(screen.title)
        // 탭·모달 이름이 겹치는 것이 경로가 같은 것보다 구체적이다
        let tail = title.replacingOccurrences(of: pathLast, with: "").filter { $0.isLetter }
        if commonRun(label.filter(\.isLetter), tail) >= 4 { return 2.5 }
        if label == screen.menuPath { return 2 }
        if labelLast == pathLast { return 1.5 }
        for (a, b) in [(squeeze(label), pathLast), (squeeze(label), title), (labelLast, pathLast)] where a.count >= 2 && b.count >= 2 {
            if a.contains(b) || b.contains(a) { return 1 }
        }
        return max(SpecDiff.similarity(labelLast, pathLast), SpecDiff.similarity(label, screen.title))
    }

    /// 두 글에 함께 들어 있는 가장 긴 연속 글자 수.
    static func commonRun(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var best = 0
        var previous = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var current = Array(repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }

    private static func last(_ path: String) -> String {
        path.components(separatedBy: ">").last?.trimmingCharacters(in: .whitespaces) ?? path
    }
}
