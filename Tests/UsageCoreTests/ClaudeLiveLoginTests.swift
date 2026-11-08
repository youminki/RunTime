import Foundation
import Testing
@testable import UsageCore

struct ClaudeRefreshLockTests {

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func pathsMatchClaudeCode() {
        let paths = ClaudeRefreshLock.defaultPaths(configDirectory: URL(fileURLWithPath: "/tmp/cfg/.claude"))
        #expect(paths.map(\.lastPathComponent) == [".oauth_refresh.lock", ".claude.lock"])
    }

    @Test func secondAcquireWaitsUntilRelease() throws {
        let dir = try tempDirectory()
        let paths = ClaudeRefreshLock.defaultPaths(configDirectory: dir.appendingPathComponent("cfg"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("cfg"), withIntermediateDirectories: true)
        let first = try #require(ClaudeRefreshLock.acquire(paths: paths))
        #expect(ClaudeRefreshLock.acquire(paths: paths) == nil)
        first.release()
        let again = try #require(ClaudeRefreshLock.acquire(paths: paths))
        again.release()
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func heldLegacyLockReleasesTheOther() throws {
        let dir = try tempDirectory()
        let paths = [dir.appendingPathComponent("a.lock"), dir.appendingPathComponent("b.lock")]
        try FileManager.default.createDirectory(at: paths[1], withIntermediateDirectories: false)
        #expect(ClaudeRefreshLock.acquire(paths: paths) == nil)
        // 잡다 만 첫 잠금을 남기면 Claude Code가 60초 동안 토큰을 새로 받지 못한다
        #expect(!FileManager.default.fileExists(atPath: paths[0].path))
    }

    @Test func staleLockIsTakenOver() throws {
        let dir = try tempDirectory()
        let path = dir.appendingPathComponent("a.lock")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let lock = try #require(ClaudeRefreshLock.acquire(paths: [path], now: Date().addingTimeInterval(61)))
        lock.release()
    }

    @Test func freshLockIsRespected() throws {
        let dir = try tempDirectory()
        let path = dir.appendingPathComponent("a.lock")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(ClaudeRefreshLock.acquire(paths: [path], now: Date().addingTimeInterval(30)) == nil)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
}

struct ClaudeAccountWatcherTests {

    private func config(_ uuid: String, padding: Int = 0) -> Data {
        Data(("{\"pad\": \"" + String(repeating: "x", count: padding) + "\", \"oauthAccount\": {\"accountUuid\": \"\(uuid)\", \"emailAddress\": \"\(uuid)@x.com\"}}").utf8)
    }

    @Test func followsLoginChanges() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        let watcher = ClaudeAccountWatcher(file: { file })
        #expect(watcher.current() == nil)
        try config("a").write(to: file, options: .atomic)
        #expect(watcher.current()?.uuid == "a")
        try config("b", padding: 3).write(to: file, options: .atomic)
        #expect(watcher.current()?.uuid == "b")
        try Data(#"{"numStartups": 1}"#.utf8).write(to: file, options: .atomic)
        #expect(watcher.current() == nil)
    }

    @Test func halfWrittenFileKeepsLastAccount() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        let watcher = ClaudeAccountWatcher(file: { file })
        try config("a").write(to: file, options: .atomic)
        #expect(watcher.current()?.uuid == "a")
        try Data(#"{"oauthAccount": {"accountUu"#.utf8).write(to: file)
        #expect(watcher.current()?.uuid == "a")
        try config("b", padding: 9).write(to: file, options: .atomic)
        #expect(watcher.current()?.uuid == "b")
    }
}

/// 지금 계정 토큰을 앱이 대신 새로 받는 흐름. 키체인·네트워크는 바꿔 끼운다.
struct LiveTokenRefreshTests {

    final class Box: @unchecked Sendable {
        var credentials: Data
        var written: [Data] = []
        var sent: [String] = []
        var refreshCalls = 0
        var reads = 0
        init(_ credentials: Data) { self.credentials = credentials }
    }

    static func credentials(token: String, expiresIn: TimeInterval, refresh: String = "r-1") -> Data {
        let ms = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
        return Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"\#(refresh)","expiresAt":\#(ms)},"mcpOAuth":{"srv":"keep"}}"#.utf8)
    }

    static let usage = OfficialUsage(sessionPercent: 12, sessionResetsAt: nil, weeklyPercent: 34, weeklyResetsAt: nil, fetchedAt: Date())

    private func provider(_ box: Box, accepts: Set<String>, refresh: ClaudeLogin.RefreshResult) throws -> OAuthUsageProvider {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let provider = OAuthUsageProvider()
        provider.readCredentials = { box.reads += 1; return box.credentials }
        provider.writeCredentials = { box.written.append($0); box.credentials = $0; return true }
        provider.currentAccountID = { "acc" }
        provider.lockPaths = { [dir.appendingPathComponent("a.lock"), dir.appendingPathComponent("b.lock")] }
        provider.refreshLive = { _, _ in box.refreshCalls += 1; return refresh }
        provider.send = { token, _ in
            box.sent.append(token)
            guard accepts.contains(token) else { throw OAuthUsageProvider.ProviderError.http(401) }
            return Self.usage
        }
        return provider
    }

    private func refreshed(_ token: String, owner: String? = "acc") -> ClaudeLogin.RefreshResult {
        let ms = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
        return .refreshed(Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r-2","expiresAt":\#(ms)}}"#.utf8), owner: owner)
    }

    @Test func expiredTokenIsRefreshedBeforeAsking() async throws {
        let box = Box(Self.credentials(token: "old", expiresIn: -60))
        let provider = try provider(box, accepts: ["new"], refresh: refreshed("new"))
        let usage = try await provider.fetch()
        #expect(usage.weeklyPercent == 34)
        #expect(box.sent == ["new"])   // 만료된 토큰으로 헛걸음하지 않는다
        #expect(box.refreshCalls == 1)
        let written = try #require(box.written.last)
        #expect(OAuthUsageProvider.parseCredentials(written)?.token == "new")
        #expect(ClaudeLogin.refreshToken(in: written) == "r-2")
        // 같은 항목의 MCP 토큰은 그대로 둔다
        let root = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect((root["mcpOAuth"] as? [String: Any])?["srv"] as? String == "keep")
    }

    @Test func validTokenIsLeftToClaudeCode() async throws {
        let box = Box(Self.credentials(token: "ok", expiresIn: 3600))
        let provider = try provider(box, accepts: ["ok"], refresh: refreshed("new"))
        _ = try await provider.fetch()
        _ = try await provider.fetch()
        #expect(box.refreshCalls == 0)
        #expect(box.written.isEmpty)
        #expect(box.reads == 1)   // 캐시가 살아 있는 동안 키체인을 다시 읽지 않는다
    }

    @Test func revokedTokenIsRefreshedAfterReread() async throws {
        let box = Box(Self.credentials(token: "revoked", expiresIn: 3600))
        let provider = try provider(box, accepts: ["new"], refresh: refreshed("new"))
        _ = try await provider.fetch()
        #expect(box.sent == ["revoked", "revoked", "new"])
        #expect(box.refreshCalls == 1)
    }

    @Test func tokenRefreshedElsewhereIsUsedAsIs() async throws {
        let box = Box(Self.credentials(token: "old", expiresIn: -60))
        let provider = try provider(box, accepts: ["other"], refresh: refreshed("new"))
        // 잠금을 잡고 다시 읽을 때는 Claude Code가 이미 받아 둔 토큰이 있다
        provider.readCredentials = {
            box.reads += 1
            return box.reads == 1 ? Self.credentials(token: "old", expiresIn: -60) : Self.credentials(token: "other", expiresIn: 3600)
        }
        _ = try await provider.fetch()
        #expect(box.refreshCalls == 0)
        #expect(box.written.isEmpty)
        #expect(box.sent == ["other"])
    }

    @Test func busyLockLeavesRefreshToClaudeCode() async throws {
        let box = Box(Self.credentials(token: "old", expiresIn: -60))
        let provider = try provider(box, accepts: [], refresh: refreshed("new"))
        let held = try #require(ClaudeRefreshLock.acquire(paths: provider.lockPaths()))
        defer { held.release() }
        await #expect(throws: OAuthUsageProvider.ProviderError.self) { try await provider.fetch() }
        #expect(box.refreshCalls == 0)
        #expect(provider.lockPaths().allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func expiredTokenIsNotSentWhenRefreshFails() async throws {
        let box = Box(Self.credentials(token: "old", expiresIn: -60))
        let provider = try provider(box, accepts: [], refresh: .unknown)
        await #expect(throws: OAuthUsageProvider.ProviderError.self) { try await provider.fetch() }
        #expect(box.sent.isEmpty)   // 401이 뻔한 요청으로 사용량 한도를 쓰지 않는다
    }

    @Test func rejectedRefreshAsksForLoginOnce() async throws {
        let box = Box(Self.credentials(token: "old", expiresIn: -60))
        let provider = try provider(box, accepts: [], refresh: .rejected)
        do {
            _ = try await provider.fetch()
            Issue.record("성공하면 안 된다")
        } catch let error as OAuthUsageProvider.ProviderError {
            #expect(error == .loginRequired)
        }
        // 이어진 조회는 토큰 서버를 다시 두드리지 않는다
        await #expect(throws: OAuthUsageProvider.ProviderError.loginRequired) { try await provider.fetch() }
        #expect(box.refreshCalls == 1)
        #expect(box.written.isEmpty)
        #expect(provider.lockPaths().allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func tokenOfAnotherAccountIsSavedButNotShown() async throws {
        let box = Box(Self.credentials(token: "old", expiresIn: -60))
        let provider = try provider(box, accepts: ["new"], refresh: refreshed("new", owner: "someone-else"))
        _ = try? await provider.fetch()
        // 서버가 이미 돌린 리프레시 토큰이라 저장은 하되, 이 계정 사용률로 보내지 않는다
        #expect(box.written.count == 1)
        #expect(!box.sent.contains("new"))
        // 저장소를 다시 읽어 그 토큰이 나와도 보내지 않는다
        _ = try? await provider.fetch()
        #expect(!box.sent.contains("new"))
        #expect(box.refreshCalls == 1)
    }

    @Test func revokedAgainAfterRefreshDoesNotRotateEveryPoll() async throws {
        let box = Box(Self.credentials(token: "t0", expiresIn: 3600))
        let provider = try provider(box, accepts: [], refresh: refreshed("t1"))
        _ = try? await provider.fetch()
        _ = try? await provider.fetch()
        #expect(box.refreshCalls == 1)
    }
}

/// 검토에서 나온 갈래 (C12, C13, C17, C18).
struct LiveTokenRefreshEdgeTests {
    typealias Box = LiveTokenRefreshTests.Box

    final class Clock: @unchecked Sendable { var now = Date() }

    private func provider(_ box: Box, clock: Clock, refresh: @escaping () -> ClaudeLogin.RefreshResult,
                          write: Bool = true) throws -> OAuthUsageProvider {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let provider = OAuthUsageProvider()
        provider.readCredentials = { box.reads += 1; return box.credentials }
        provider.writeCredentials = { data in
            guard write else { return false }
            box.written.append(data); box.credentials = data; return true
        }
        provider.currentAccountID = { "acc" }
        provider.lockPaths = { [dir.appendingPathComponent("a.lock"), dir.appendingPathComponent("b.lock")] }
        provider.clock = { clock.now }
        provider.refreshLive = { _, _ in box.refreshCalls += 1; return refresh() }
        provider.send = { token, _ in box.sent.append(token); throw OAuthUsageProvider.ProviderError.http(401) }
        return provider
    }

    @Test func deadRefreshTokenIsNotRetriedEveryPoll() async throws {
        let box = Box(LiveTokenRefreshTests.credentials(token: "old", expiresIn: -60, refresh: "dead"))
        let clock = Clock()
        let provider = try provider(box, clock: clock, refresh: { .rejected })
        for _ in 0..<4 {
            await #expect(throws: OAuthUsageProvider.ProviderError.loginRequired) { try await provider.fetch() }
            clock.now = clock.now.addingTimeInterval(180)   // 공식 폴링 간격
        }
        #expect(box.refreshCalls == 1)
        // /login으로 리프레시 토큰이 바뀌면 다시 해 본다
        box.credentials = LiveTokenRefreshTests.credentials(token: "old2", expiresIn: -60, refresh: "fresh")
        provider.invalidateCachedToken()
        _ = try? await provider.fetch()
        #expect(box.refreshCalls == 2)
    }

    @Test func accountChangeClearsPreviousFailure() async throws {
        let box = Box(LiveTokenRefreshTests.credentials(token: "a", expiresIn: -60, refresh: "ra"))
        let clock = Clock()
        var answer: ClaudeLogin.RefreshResult = .unknown
        let provider = try provider(box, clock: clock, refresh: { answer })
        _ = try? await provider.fetch()
        #expect(box.refreshCalls == 1)
        // 바로 다른 계정으로 바뀌었고 그 계정 토큰도 만료됐다
        box.credentials = LiveTokenRefreshTests.credentials(token: "b", expiresIn: -60, refresh: "rb")
        answer = .rejected
        provider.resetForAccountChange()
        _ = try? await provider.fetch()
        #expect(box.refreshCalls == 2)
    }

    @Test func failedWriteDoesNotUseOrRetryToken() async throws {
        let box = Box(LiveTokenRefreshTests.credentials(token: "old", expiresIn: -60))
        let clock = Clock()
        let ms = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
        let provider = try provider(box, clock: clock, refresh: {
            .refreshed(Data(#"{"claudeAiOauth":{"accessToken":"new","refreshToken":"r-2","expiresAt":\#(ms)}}"#.utf8), owner: "acc")
        }, write: false)
        _ = try? await provider.fetch()
        _ = try? await provider.fetch()
        #expect(!box.sent.contains("new"))
        #expect(box.refreshCalls == 1)
        #expect(provider.lockPaths().allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}

struct ClaudeAccountWatcherEdgeTests {
    @Test func unreadableFileKeepsAccount() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        let watcher = ClaudeAccountWatcher(file: { file })
        try Data(#"{"oauthAccount": {"accountUuid": "a", "emailAddress": "a@x.com"}}"#.utf8).write(to: file, options: .atomic)
        #expect(watcher.current()?.uuid == "a")
        try FileManager.default.removeItem(at: file)
        #expect(watcher.current()?.uuid == "a")
        try Data().write(to: file)
        #expect(watcher.current()?.uuid == "a")
        try Data(#"{"oauthAccount": {"accountUuid": "a", "emailAddress": "a@x.com"}, "numStartups": 2}"#.utf8).write(to: file, options: .atomic)
        #expect(watcher.current()?.uuid == "a")
        try Data(#"{"numStartups": 3}"#.utf8).write(to: file, options: .atomic)
        #expect(watcher.current() == nil)
    }
}

struct ClaudeRefreshLockWaitTests {
    @Test func waitingAcquireGetsLockAfterRelease() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let paths = [dir.appendingPathComponent("a.lock")]
        let held = try #require(ClaudeRefreshLock.acquire(paths: paths))
        // 테스트를 나란히 돌리면 공용 스레드가 모두 기다리는 테스트로 차 늦게 풀릴 수 있어 전용 스레드에서 푼다
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.4)
            held.release()
        }
        let start = Date()
        let lock = try #require(ClaudeRefreshLock.acquire(paths: paths, waiting: 15))
        #expect(Date().timeIntervalSince(start) >= 0.3)
        lock.release()
        // 끝내 못 잡으면 기다린 뒤 nil
        let other = try #require(ClaudeRefreshLock.acquire(paths: paths))
        #expect(ClaudeRefreshLock.acquire(paths: paths, waiting: 0.3) == nil)
        other.release()
    }
}

/// 갱신하는 동안 잠금을 쥐고 있어 계정 전환이 끼어들지 못하는지 (C25), 쓰기 재시도 (C26).
struct LiveTokenRefreshLockHoldTests {
    typealias Box = LiveTokenRefreshTests.Box

    final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
    }

    private func setUp(_ box: Box, write: @escaping (Data) -> Bool, refresh: @escaping () async -> ClaudeLogin.RefreshResult) throws -> OAuthUsageProvider {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let provider = OAuthUsageProvider()
        provider.readCredentials = { box.reads += 1; return box.credentials }
        provider.writeCredentials = { data in
            guard write(data) else { return false }
            box.written.append(data); box.credentials = data; return true
        }
        provider.currentAccountID = { "acc" }
        provider.lockPaths = { [dir.appendingPathComponent("a.lock"), dir.appendingPathComponent("b.lock")] }
        provider.refreshLive = { _, _ in box.refreshCalls += 1; return await refresh() }
        provider.send = { token, _ in
            box.sent.append(token)
            guard token == "new" else { throw OAuthUsageProvider.ProviderError.http(401) }
            return LiveTokenRefreshTests.usage
        }
        return provider
    }

    private static func refreshed() -> ClaudeLogin.RefreshResult {
        let ms = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
        return .refreshed(Data(#"{"claudeAiOauth":{"accessToken":"new","refreshToken":"r-2","expiresAt":\#(ms)}}"#.utf8), owner: "acc")
    }

    @Test func switchCannotTakeLockWhileRefreshing() async throws {
        let box = Box(LiveTokenRefreshTests.credentials(token: "old", expiresIn: -60))
        let gate = Gate()
        let provider = try setUp(box, write: { _ in true }, refresh: {
            gate.entered.signal()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { gate.proceed.wait(); continuation.resume() }
            }
            return Self.refreshed()
        })
        let fetch = Task { try await provider.fetch() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { gate.entered.wait(); continuation.resume() }
        }
        // 토큰 서버 응답을 기다리는 동안 계정 전환은 잠금을 잡지 못한다
        #expect(ClaudeRefreshLock.acquire(paths: provider.lockPaths(), waiting: 0.2) == nil)
        gate.proceed.signal()
        let usage = try await fetch.value
        #expect(usage.weeklyPercent == 34)
        #expect(box.written.count == 1)
        // 끝난 뒤에는 잡힌다
        let lock = try #require(ClaudeRefreshLock.acquire(paths: provider.lockPaths(), waiting: 1))
        lock.release()
    }

    @Test func secondWriteAttemptIsUsed() async throws {
        let box = Box(LiveTokenRefreshTests.credentials(token: "old", expiresIn: -60))
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let provider = try setUp(box, write: { _ in count.n += 1; return count.n >= 2 }, refresh: { Self.refreshed() })
        let usage = try await provider.fetch()
        #expect(usage.sessionPercent == 12)
        #expect(count.n == 2)
        #expect(box.sent == ["new"])
        #expect(box.refreshCalls == 1)
        #expect(provider.lockPaths().allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}
