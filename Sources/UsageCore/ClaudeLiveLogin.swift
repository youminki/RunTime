import Foundation

/// Claude Code가 토큰을 새로 받을 때 잡는 잠금. 같은 잠금을 잡아 둘이 한꺼번에 리프레시 토큰을 돌리지 않게 한다.
/// Claude Code(proper-lockfile)는 `<설정 폴더>/.oauth_refresh.lock`과 `<설정 폴더>.lock` 폴더를 만들어 잠그고,
/// 60초 넘게 고쳐지지 않은 잠금은 버려진 것으로 본다. 주인 기록이 없는 잠금은 빼앗지 않는다 (claude-code 2.1.318).
public struct ClaudeRefreshLock {

    public static let staleAfter: TimeInterval = 60

    let paths: [URL]

    public static func defaultPaths(configDirectory: URL = ClaudePaths.configDirectory) -> [URL] {
        let resolved = configDirectory.resolvingSymlinksInPath()
        return [configDirectory.appendingPathComponent(".oauth_refresh.lock"),
                URL(fileURLWithPath: resolved.path + ".lock")]
    }

    /// 잠금을 모두 잡으면 돌려준다. 하나라도 다른 쪽이 쥐고 있으면 잡은 것을 풀고 nil.
    public static func acquire(paths: [URL] = defaultPaths(), now: Date = Date()) -> ClaudeRefreshLock? {
        var held: [URL] = []
        for path in paths {
            if take(path, now: now) {
                held.append(path)
            } else {
                held.forEach(remove)
                return nil
            }
        }
        return ClaudeRefreshLock(paths: held)
    }

    /// 잡을 때까지 `waiting`초 기다린다. Claude Code나 앱의 다른 곳이 토큰을 새로 받는 동안 계정을 바꾸지 않으려고 쓴다.
    public static func acquire(paths: [URL] = defaultPaths(), waiting: TimeInterval) -> ClaudeRefreshLock? {
        let deadline = Date().addingTimeInterval(waiting)
        while true {
            if let lock = acquire(paths: paths) { return lock }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public func release() {
        paths.reversed().forEach(Self.remove)
    }

    /// 오래 쥐고 있을 때 버려진 잠금으로 보이지 않게 고친 시각을 지금으로 맞춘다.
    public func touch() {
        for path in paths { utimes(path.path, nil) }
    }

    private static func take(_ path: URL, now: Date) -> Bool {
        if mkdir(path.path, 0o755) == 0 { return true }
        guard errno == EEXIST else { return false }
        // 버려진 잠금(앱이 죽은 뒤 등)만 치우고 한 번 더 잡아 본다
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        guard let modified, now.timeIntervalSince(modified) > staleAfter else { return false }
        remove(path)
        return mkdir(path.path, 0o755) == 0
    }

    private static func remove(_ path: URL) {
        rmdir(path.path)
    }
}

/// `~/.claude.json`의 지금 계정을 싸게 읽는다. 파일이 바뀌었을 때만 다시 푼다 (Claude Code가 수백 KB로 키운다).
public final class ClaudeAccountWatcher {

    private let file: () -> URL
    private var lastModified: Date?
    private var lastSize: Int?
    private var cached: ClaudeAccountInfo?

    public init(file: @escaping () -> URL = { ClaudeLogin.globalConfigFile }) {
        self.file = file
    }

    /// 지금 계정. 파일이 없거나 계정이 없으면 nil.
    public func current() -> ClaudeAccountInfo? {
        let url = file().resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue
        if attributes != nil, modified == lastModified, size == lastSize { return cached }
        lastModified = modified
        lastSize = size
        // 잠깐 없거나 쓰는 도중이면 앞 값을 둔다. 로그아웃으로 보면 공식 값을 버리고 다시 받는다
        guard let data = try? Data(contentsOf: url) else {
            lastModified = nil
            return cached
        }
        if let info = ClaudeLogin.account(inConfig: data) {
            cached = info
        } else if (try? JSONSerialization.jsonObject(with: data)) != nil {
            cached = nil   // 제대로 된 파일에 계정이 없다 (로그아웃)
        } else {
            lastModified = nil   // 반쯤 쓴 파일. 다음 번에 다시 읽는다
        }
        return cached
    }
}

extension ClaudeAccountWatcher: @unchecked Sendable {}
