import Foundation
import Combine
import UsageCore

/// Claude Code 계정 여러 개를 기억해 두고 바꿔 쓴다.
/// Claude Code에서 `/login`으로 들어온 계정은 저절로 기억하고, 고르면 키체인의 로그인 정보와
/// `~/.claude.json`의 계정 정보를 그 계정 것으로 바꾼다. 토큰은 키체인에만 두고 어디로도 보내지 않는다.
/// 토큰 저장본은 Claude Code 항목과 같이 `/usr/bin/security`로 만든다. 앱이 직접 만든 항목은 자체 서명 앱을
/// 다시 빌드할 때마다 키체인이 다시 물어서, 업데이트 뒤 자동 전환이 암호 창에 막힌다.
final class AccountSwitcher: ObservableObject {

    static let shared = AccountSwitcher()

    struct Account: Codable, Identifiable, Equatable {
        let id: String           // accountUuid
        var email: String
        var name: String?
        var plan: String?
        var lastUsage: ClaudeLogin.LastUsage?
        /// `~/.claude.json`의 oauthAccount 원본. 비밀이 아니라 설정에 둔다.
        var configAccount: Data?
        /// 저장한 리프레시 토큰이 거절됐다. 그 계정으로 /login을 다시 해야 바꿀 수 있다.
        var needsLogin: Bool?

        /// 메뉴에 보일 이름. 이메일 앞부분과 요금제.
        var label: String {
            let plan = plan.map { " · " + Self.planName($0) } ?? ""
            return email + plan
        }

        static func planName(_ type: String) -> String {
            switch type {
            case "claude_pro": return "Pro"
            case "claude_max": return "Max"
            case "claude_team": return "Team"
            case "claude_enterprise": return "Enterprise"
            default: return type
            }
        }
    }

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeID: String?
    @Published private(set) var switching = false
    @Published private(set) var lastError: String?
    /// 세션·주간 사용률이 한도에 닿으면 여유 있는 다른 계정으로 바꾼다 (기본 끔).
    @Published var autoSwitch: Bool { didSet { defaults.set(autoSwitch, forKey: Self.autoKey) } }

    /// 자동 전환 기준 사용률. 한도를 다 쓴 계정만 떠난다.
    static let autoSwitchLimit: Double = 100
    /// 자동 전환이 잇달아 일어나지 않게 둔 간격. 한도에 막힌 기록으로 바꿀 때는 건너뛴다.
    static let autoSwitchCooldown: TimeInterval = 2 * 60
    /// 바꾼 직후 이만큼은 막힘 기록을 새 계정 것으로 보지 않는다. 바꾸기 전에 보낸 요청이 늦게 막힐 수 있다.
    static let switchSettle: TimeInterval = 20
    static let keychainService = "RunTime Claude account"
    /// 앱이 직접 만들던 예전 저장소. 켤 때 한 번 옮기고 지운다.
    static let legacyKeychainService = "dev.runtime.RunTime.accounts"

    /// 로그인 정보를 바꾼 직후, 지금 계정 표시를 바꾸기 전에 부른다. 계정 큐에서 부른다.
    var willActivate: () -> Void = {}
    /// 계정을 바꾼 뒤 부른다. 메인 스레드.
    var onSwitched: (Account, _ automatic: Bool) -> Void = { _, _ in }

    private static let listKey = "claudeAccounts"
    private static let autoKey = "claudeAccountAutoSwitch"
    private let defaults = UserDefaults.standard
    /// 키체인 `security` 호출은 허용 창이 뜨면 끝나지 않으므로 이 큐에서만 한다.
    private let queue = DispatchQueue(label: "runtime.accounts", qos: .utility)
    private var lastAutoSwitch: Date?
    private var lastSwitchAt: Date?
    /// 지금 계정으로 바꾸기 시작한 때. 엔진이 앞 계정 토큰을 버리게 알린 시각이다.
    private var activatedAt: Date?
    /// 메인 전용. 계정별로 지금 계정에서 물러난 때. 그 계정으로 열어 둔 Claude Code 세션은 옛 리프레시 토큰을
    /// 메모리에 든 채 계속 도니, 그동안 앱이 먼저 토큰을 돌리면 그 세션의 로그인이 풀린다.
    private var leftAt: [String: Date] = [:]
    /// 물러난 계정 토큰을 미리 새로 받지 않는 시간 (액세스 토큰 한 번의 수명).
    static let departedGrace: TimeInterval = 8 * 3600
    /// 쓰지 않는 계정 토큰은 만료 이만큼 전에 새로 받아 둔다. 오래 두면 리프레시 토큰까지 만료된다.
    static let keepAliveMargin: TimeInterval = 30 * 60
    /// 새로 받지 못했으면(429 등) 이만큼 쉬고 다시 해 본다. 계정을 바꿀 때는 기다리지 않는다.
    static let refreshRetryDelay: TimeInterval = 60 * 60
    /// queue 전용. 계정별로 마지막으로 새로 받지 못한 때.
    private var refreshFailedAt: [String: Date] = [:]
    /// 쓰지 않는 계정 사용률을 받는 간격. 공식 조회 간격(3분)보다 길게 잡아 요청을 늘리지 않는다.
    static let othersRefreshInterval: TimeInterval = 10 * 60
    private var othersFetchedAt: [String: Date] = [:]
    /// 모든 계정이 한도라고 알린 때. 같은 상황을 되풀이해 알리지 않는다.
    private var exhaustedNoticeUntil: Date?
    /// 모든 계정이 한도에 닿았을 때 부른다 (가장 먼저 풀리는 계정, 풀리는 때). 메인 스레드.
    var onExhausted: (Account?, Date?) -> Void = { _, _ in }
    private var keychainOff: Bool { WorkLogSettings.keychainOff }

    private init() {
        autoSwitch = defaults.bool(forKey: Self.autoKey)
        if let data = defaults.data(forKey: Self.listKey),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
        activeID = ClaudeLogin.currentAccount()?.uuid
        migrateLegacy()
    }

    /// 예전 저장소(앱이 만든 키체인 항목)의 저장본을 `security` 항목으로 옮긴다.
    /// 다시 빌드한 앱이면 키체인이 한 번 물을 수 있다. 못 읽으면 그 계정은 /login을 한 번 더 하면 된다.
    private func migrateLegacy() {
        guard !keychainOff else { return }
        let ids = accounts.map(\.id).filter { AppKeychain.exists($0, service: Self.legacyKeychainService) }
        guard !ids.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for id in ids {
                if let text = AppKeychain.read(id, service: Self.legacyKeychainService),
                   let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: Data(text.utf8)),
                   let part = ClaudeLogin.oauthPart(of: legacy.credentials),
                   ClaudeLogin.writeKeychain(part, service: Self.keychainService, account: id) {
                    DispatchQueue.main.sync {
                        if let index = self.accounts.firstIndex(where: { $0.id == id }) {
                            self.accounts[index].configAccount = legacy.account
                            self.persist()
                        }
                    }
                    AppKeychain.delete(id, service: Self.legacyKeychainService)
                }
            }
        }
    }

    var active: Account? { accounts.first { $0.id == activeID } }
    var others: [Account] { accounts.filter { $0.id != activeID } }

    // MARK: - 기억하기

    /// 지금 Claude Code에 로그인한 계정과 토큰을 기억한다. 켤 때와 공식 값을 받을 때마다 부른다.
    /// Claude Code가 리프레시 토큰을 돌려 쓰므로, 바뀐 토큰을 그때그때 남겨야 나중에 이 계정으로 돌아올 수 있다.
    func captureCurrent() {
        guard !keychainOff else { return }
        queue.async { [weak self] in
            guard let self, let info = ClaudeLogin.currentAccount() else { return }
            self.saveSnapshot(info)
        }
    }

    /// 지금 Claude Code 계정을 다시 읽어 맞춘 뒤 메인 스레드에서 `then`을 부른다.
    private func resync(then: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if let info = ClaudeLogin.currentAccount() { self.saveSnapshot(info) }
            DispatchQueue.main.async {
                // 저장하지 못해도(토큰 주인 불일치 등) 계정 표시만은 설정 파일을 따른다
                if let current = ClaudeLogin.currentAccount()?.uuid, self.accounts.contains(where: { $0.id == current }) {
                    self.activeID = current
                }
                then()
            }
        }
    }

    private enum SaveResult { case saved, unchanged, mismatch, unverified, failed }

    /// queue 전용. 지금 Claude 로그인 토큰을 키체인에, 계정 정보를 설정에 남긴다.
    /// 토큰이 정말 이 계정 것인지 Anthropic에 물어 보고, 다른 계정 것이면 남기지 않는다.
    @discardableResult
    private func saveSnapshot(_ info: ClaudeAccountInfo) -> SaveResult {
        guard let live = ClaudeLogin.liveCredentials(), let part = ClaudeLogin.oauthPart(of: live) else { return .failed }
        let stored = storedCredentials(for: info.uuid)
        if stored == part {
            markActive(info)
            return .unchanged
        }
        switch Self.wait({ await ClaudeLogin.owner(of: part) }) {
        case .account(let owner) where owner != info.uuid:
            // 옛 계정으로 열린 세션이 토큰을 새로 받아 써 넣었다. 그 계정의 가장 새 토큰이라 그 계정 자리에 남긴다
            if owner != DispatchQueue.main.sync(execute: { self.activeID }), isNewer(part, than: storedCredentials(for: owner)) {
                keep(part, for: owner)
            }
            return .mismatch
        case .account:
            break
        case .expired:
            // 오래 쉬어 액세스 토큰이 만료됐다. 리프레시 토큰이 다른 계정 저장본과 같으면 남의 것이고,
            // 아니면 이 계정이 마지막으로 받은 토큰이라 남긴다. 혹시 몰라 앞 저장본은 따로 둔다.
            let refresh = ClaudeLogin.refreshToken(in: part)
            let others = DispatchQueue.main.sync { self.accounts.map(\.id) }.filter { $0 != info.uuid }
            if refresh != nil, others.contains(where: { self.storedCredentials(for: $0).flatMap(ClaudeLogin.refreshToken(in:)) == refresh }) {
                return .mismatch
            }
            if let stored { ClaudeLogin.writeKeychain(stored, service: Self.keychainService, account: info.uuid + ".previous") }
        case .unknown:
            // 네트워크 등으로 묻지 못했다. 처음 보는 계정이면 남기고, 아니면 다음에 다시 본다.
            if stored != nil { return .unverified }
        }
        guard ClaudeLogin.writeKeychain(part, service: Self.keychainService, account: info.uuid) else { return .failed }
        markActive(info)
        return .saved
    }

    /// queue 전용. 목록의 이름·요금제를 맞추고 지금 계정으로 표시한다.
    /// 앱 밖에서(`/login` 등) 계정이 바뀌었으면 엔진이 앞 계정 토큰을 버리게 먼저 알린다.
    private func markActive(_ info: ClaudeAccountInfo) {
        let previous = DispatchQueue.main.sync { self.activeID }
        let changed = previous != nil && previous != info.uuid
        let activatedAt = Date()
        if changed { willActivate() }
        DispatchQueue.main.sync {
            if changed {
                self.activatedAt = activatedAt
                if let previous { self.leftAt[previous] = activatedAt }
            }
            var account = self.accounts.first { $0.id == info.uuid }
                ?? Account(id: info.uuid, email: info.email, name: nil, plan: nil, lastUsage: nil)
            account.email = info.email
            account.name = info.displayName
            account.plan = info.organizationType
            account.configAccount = info.raw
            account.needsLogin = nil
            if let index = self.accounts.firstIndex(where: { $0.id == info.uuid }) {
                if self.accounts[index] != account { self.accounts[index] = account }
            } else {
                self.accounts.append(account)
            }
            if self.activeID != info.uuid { self.activeID = info.uuid }
            self.persist()
        }
    }

    /// queue 전용. 비동기 조회를 이 큐에서 기다린다 (Swift 동시성 스레드는 붙잡지 않는다).
    private static func wait<T>(_ work: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task.detached {
            result = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }

    func remove(_ id: String) {
        guard id != activeID else { return }
        accounts.removeAll { $0.id == id }
        persist()
        queue.async {
            ClaudeLogin.deleteKeychain(service: Self.keychainService, account: id)
            ClaudeLogin.deleteKeychain(service: Self.keychainService, account: id + ".previous")
        }
    }

    // MARK: - 바꾸기

    func switchTo(_ id: String, automatic: Bool = false, resynced: Bool = false, completion: ((String?) -> Void)? = nil) {
        if !resynced, let current = ClaudeLogin.currentAccount()?.uuid, current != activeID {
            resync { self.switchTo(id, automatic: automatic, resynced: true, completion: completion) }
            return
        }
        guard !switching, id != activeID, !keychainOff else {
            completion?(switching ? "이미 바꾸는 중입니다" : id == activeID ? "이미 쓰는 계정입니다" : "키체인을 쓰지 않는 실행입니다")
            return
        }
        switching = true
        lastError = nil
        queue.async { [weak self] in
            guard let self else { return }
            let error = self.performSwitch(to: id)
            DispatchQueue.main.async {
                self.switching = false
                self.lastError = error
                if error == nil, let account = self.accounts.first(where: { $0.id == id }) {
                    self.lastSwitchAt = Date()
                    self.onSwitched(account, automatic)
                }
                completion?(error)
            }
        }
    }

    /// queue 전용. 실패하면 까닭, 성공하면 nil.
    private func performSwitch(to id: String) -> String? {
        // Claude Code가 그동안 토큰을 새로 받았을 수 있어, 떠나는 계정은 지금 토큰으로 다시 남긴다
        if let current = ClaudeLogin.currentAccount() {
            switch saveSnapshot(current) {
            case .failed: return "지금 계정의 로그인 정보를 읽지 못했습니다"
            case .mismatch: return "키체인의 로그인 정보가 \(current.email) 것이 아닙니다. 다른 계정으로 열린 Claude Code 세션을 닫고 다시 시도해 주세요"
            case .unverified: return "지금 계정의 토큰을 확인하지 못했습니다. 네트워크를 확인하고 다시 시도해 주세요"
            case .saved, .unchanged: break
            }
        }
        let target = DispatchQueue.main.sync { self.accounts.first { $0.id == id } }
        let configAccount = target?.configAccount
        // 오래 쉰 계정은 바꾸기 전에 토큰을 새로 받아 둔다. 리프레시 토큰이 죽었으면 바꿔도 Claude Code가 로그인을 다시 묻는다
        switch freshCredentials(for: id, forSwitch: true) {
        case .rejected: return "\(target?.email ?? "그 계정")의 로그인이 풀렸습니다. 그 계정으로 Claude Code에서 /login 해 주세요"
        case .mismatch: return "저장된 \(target?.email ?? "그 계정") 로그인 정보가 다른 계정 것입니다. 그 계정으로 Claude Code에서 /login 해 주세요"
        case .usable, .unavailable: break
        }
        let previous = ClaudeLogin.liveCredentials()
        // 저장본에는 Claude 로그인만 있다 (예전 저장본은 MCP 토큰까지 들어 있어 떼어 쓴다). MCP 토큰은 지금 값을 둔다.
        guard let part = storedCredentials(for: id).flatMap(ClaudeLogin.oauthPart(of:)),
              let credentials = ClaudeLogin.merging(oauthPart: part, into: previous),
              let configAccount
        else { return "저장된 로그인 정보가 없습니다. 그 계정으로 Claude Code에서 /login 해 주세요" }
        // 토큰과 계정 정보가 서로 다른 계정을 가리키지 않게, 어느 단계에서 실패해도 토큰을 되돌린다
        guard ClaudeLogin.setLiveCredentials(credentials) else {
            if let previous { _ = ClaudeLogin.setLiveCredentials(previous) }
            return "키체인에 로그인 정보를 쓰지 못했습니다"
        }
        guard ClaudeLogin.setCurrentAccount(configAccount) else {
            if let previous { _ = ClaudeLogin.setLiveCredentials(previous) }
            return "~/.claude.json을 고치지 못했습니다"
        }
        // 지금 계정 표시를 바꾸기 전에 엔진이 앞 계정 토큰으로 받은 값을 버리게 한다
        let activatedAt = Date()
        willActivate()
        DispatchQueue.main.sync {
            self.activatedAt = activatedAt
            if let old = self.activeID, old != id { self.leftAt[old] = activatedAt }
            self.leftAt[id] = nil
            self.activeID = id
            self.persist()
        }
        return nil
    }

    // MARK: - 사용률과 자동 전환

    /// 받은 공식 값을 지금 계정에 적고, 켜져 있으면 자동 전환을 본다. 메인 스레드.
    func record(_ usage: OfficialUsage) {
        guard let id = activeID, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        // 계정을 바꾸기 시작하기 전에 받은 값은 앞 계정 것이다 (메인 큐에서 바꾼 뒤에 늦게 도착할 수 있다)
        if let activatedAt, usage.fetchedAt < activatedAt { return }
        accounts[index].lastUsage = ClaudeLogin.LastUsage(
            sessionPercent: usage.sessionPercent, sessionResetsAt: usage.sessionResetsAt,
            weeklyPercent: usage.weeklyPercent, weeklyResetsAt: usage.weeklyResetsAt)
        persist()
        considerAutoSwitch()
    }

    /// 쓰지 않는 계정의 사용률을 저장해 둔 토큰으로 받는다. 토큰이 곧 만료되면 먼저 새로 받아 둔다.
    func refreshOthers(now: Date = Date()) {
        guard !keychainOff else { return }
        let due = others.filter { now.timeIntervalSince(othersFetchedAt[$0.id] ?? .distantPast) >= Self.othersRefreshInterval }
        guard !due.isEmpty else { return }
        for account in due { othersFetchedAt[account.id] = now }
        queue.async { [weak self] in
            guard let self else { return }
            for account in due {
                guard case .usable(let credentials) = self.freshCredentials(for: account.id, retryNow: false),
                      let parsed = OAuthUsageProvider.parseCredentials(credentials),
                      parsed.expiresAt > Date().addingTimeInterval(OAuthUsageProvider.expiryMargin)
                else { continue }
                let usage: OfficialUsage? = Self.wait {
                    try? await OAuthUsageProvider.fetch(token: parsed.token,
                                                        userAgent: OAuthUsageProvider.userAgent(clientVersion: nil))
                }
                guard let usage else { continue }
                DispatchQueue.main.async {
                    // 받는 사이 이 계정으로 바꿨으면 엔진 값이 맞다
                    guard account.id != self.activeID,
                          let index = self.accounts.firstIndex(where: { $0.id == account.id }) else { return }
                    self.accounts[index].lastUsage = ClaudeLogin.LastUsage(
                        sessionPercent: usage.sessionPercent, sessionResetsAt: usage.sessionResetsAt,
                        weeklyPercent: usage.weeklyPercent, weeklyResetsAt: usage.weeklyResetsAt)
                    self.persist()
                }
            }
        }
    }

    /// Claude Code 요청이 한도에 막혔다. 지금 계정을 그 창에서 100%로 적고, 켜져 있으면 바로 다른 계정으로 바꾼다. 메인 스레드.
    func limitReached(_ hit: LimitHit, now: Date = Date(), resynced: Bool = false) {
        // 앱 밖에서(/login 등) 바꾼 계정을 아직 모르면 막힌 계정을 잘못 적는다. 먼저 맞춘 뒤 다시 본다.
        if !resynced, let current = ClaudeLogin.currentAccount()?.uuid, current != activeID {
            resync { self.limitReached(hit, now: now, resynced: true) }
            return
        }
        guard let id = activeID, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let last = lastSwitchAt, hit.timestamp < last.addingTimeInterval(Self.switchSettle) { return }
        var usage = accounts[index].lastUsage
            ?? ClaudeLogin.LastUsage(sessionPercent: nil, sessionResetsAt: nil, weeklyPercent: nil, weeklyResetsAt: nil)
        switch hit.window {
        case .session:
            usage.sessionPercent = 100
            usage.sessionResetsAt = hit.resetsAt ?? usage.sessionResetsAt
        case .weekly:
            usage.weeklyPercent = 100
            usage.weeklyResetsAt = hit.resetsAt ?? usage.weeklyResetsAt
        }
        accounts[index].lastUsage = usage
        persist()
        considerAutoSwitch(now: now, ignoreCooldown: true)
    }

    private func considerAutoSwitch(now: Date = Date(), ignoreCooldown: Bool = false) {
        guard autoSwitch, !switching, let id = activeID, accounts.count > 1 else { return }
        if !ignoreCooldown, let last = lastAutoSwitch, now.timeIntervalSince(last) < Self.autoSwitchCooldown { return }
        var usage: [String: ClaudeLogin.LastUsage] = [:]
        for account in accounts { usage[account.id] = account.lastUsage }
        guard let mine = usage[id], mine.effectivePercent(now: now) >= Self.autoSwitchLimit else { return }
        guard let target = ClaudeLogin.autoSwitchTarget(current: id, usage: usage, candidates: accounts.map(\.id),
                                                        limit: Self.autoSwitchLimit, now: now)
        else {
            noticeExhausted(now: now)
            return
        }
        lastAutoSwitch = now
        switchTo(target, automatic: true)
    }

    /// 바꿀 계정이 없으면 가장 먼저 풀리는 계정을 한 번 알린다. 그 계정이 풀릴 때까지 다시 알리지 않는다.
    private func noticeExhausted(now: Date) {
        if let until = exhaustedNoticeUntil, now < until { return }
        let soonest = accounts.compactMap { account -> (Account, Date)? in
            guard let usage = account.lastUsage else { return nil }
            let resets = [usage.sessionPercent.flatMap { $0 >= Self.autoSwitchLimit ? usage.sessionResetsAt : nil },
                          usage.weeklyPercent.flatMap { $0 >= Self.autoSwitchLimit ? usage.weeklyResetsAt : nil }]
                .compactMap { $0 }.filter { $0 > now }
            return resets.max().map { (account, $0) }
        }.min { $0.1 < $1.1 }
        exhaustedNoticeUntil = soonest?.1 ?? now.addingTimeInterval(30 * 60)
        onExhausted(soonest?.0, soonest?.1)
    }

    // MARK: - 쓰지 않는 계정 토큰 살려 두기

    enum Freshness: Equatable {
        case usable(Data)
        /// 리프레시 토큰이 거절됐다
        case rejected
        /// 저장본이 없거나 네트워크 등으로 새로 받지 못했다. 저장본은 그대로 둔다
        case unavailable
        /// 저장본이 다른 계정 토큰이었다
        case mismatch
    }

    /// 쓰지 않는 계정들의 토큰을 살려 둔다. 계정 큐에서 돌고 끝나면 메인 스레드에서 결과를 넘긴다 (점검용).
    func keepOthersFresh(completion: @escaping ([(Account, Freshness)]) -> Void) {
        let others = others
        queue.async { [weak self] in
            guard let self else { return }
            let results = others.map { ($0, self.freshCredentials(for: $0.id)) }
            DispatchQueue.main.async { completion(results) }
        }
    }

    /// 앞 토큰보다 만료가 늦은지. 앞 토큰이 없으면 새것으로 본다.
    private func isNewer(_ part: Data, than other: Data?) -> Bool {
        guard let other, let theirs = OAuthUsageProvider.parseCredentials(other)?.expiresAt else { return true }
        guard let mine = OAuthUsageProvider.parseCredentials(part)?.expiresAt else { return false }
        return mine > theirs
    }

    /// queue 전용. 쓰지 않는 계정의 저장본을 돌려준다. 액세스 토큰이 곧 만료되면 리프레시 토큰으로 새로 받아 저장한다.
    /// 지금 계정은 Claude Code가 토큰을 돌리므로 손대지 않는다. 계정 바꾸기도 이 큐에서 하므로 그 사이에 지금 계정이 되지 않는다.
    /// `forSwitch`면 곧 그 계정으로 바꾸려는 것이라 물러난 지 얼마 안 됐어도 새로 받는다.
    func freshCredentials(for id: String, retryNow: Bool = true, forSwitch: Bool = false) -> Freshness {
        guard let stored = storedCredentials(for: id), let part = ClaudeLogin.oauthPart(of: stored) else { return .unavailable }
        let (active, left) = DispatchQueue.main.sync { (self.activeID, self.leftAt[id]) }
        guard id != active, ClaudeLogin.needsRefresh(part, margin: Self.keepAliveMargin) else { return .usable(part) }
        // 막 물러난 계정은 그 계정으로 열어 둔 Claude Code 세션이 아직 돌 수 있어 미리 돌리지 않는다
        if !forSwitch, let left, Date().timeIntervalSince(left) < Self.departedGrace { return .usable(part) }
        // 키체인에 이 리프레시 토큰이 들어 있으면 Claude Code가 쓰는 중이다. 돌리면 Claude Code 로그인이 풀린다
        let refresh = ClaudeLogin.refreshToken(in: part)
        if refresh == nil || ClaudeLogin.liveCredentials().flatMap(ClaudeLogin.refreshToken(in:)) == refresh { return .usable(part) }
        if !retryNow, let failed = refreshFailedAt[id], Date().timeIntervalSince(failed) < Self.refreshRetryDelay { return .usable(part) }
        let result = Self.wait({ await ClaudeLogin.refresh(part) })
        if case .unknown = result { refreshFailedAt[id] = Date() } else { refreshFailedAt[id] = nil }
        switch result {
        case .refreshed(let updated, let owner):
            // 저장 자리가 섞였으면 받은 토큰은 그 주인 것이다
            if let owner, owner != id {
                if owner != active { keep(updated, for: owner) }
                return .mismatch
            }
            // 서버는 이미 리프레시 토큰을 돌려서, 저장하지 못하면 옛 저장본도 쓸 수 없다
            if keep(updated, for: id) || keep(updated, for: id) { return .usable(updated) }
            DispatchQueue.main.sync { self.setNeedsLogin(id, true) }
            return .rejected
        case .rejected:
            DispatchQueue.main.sync { self.setNeedsLogin(id, true) }
            return .rejected
        case .unknown:
            return .unavailable
        }
    }

    /// queue 전용. 기억한 계정의 토큰을 저장하고 다시 로그인할 필요 표시를 지운다.
    @discardableResult
    private func keep(_ part: Data, for id: String) -> Bool {
        guard DispatchQueue.main.sync(execute: { self.accounts.contains { $0.id == id } }),
              ClaudeLogin.writeKeychain(part, service: Self.keychainService, account: id)
        else { return false }
        DispatchQueue.main.sync { self.setNeedsLogin(id, false) }
        return true
    }

    private func setNeedsLogin(_ id: String, _ value: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), (accounts[index].needsLogin ?? false) != value else { return }
        accounts[index].needsLogin = value ? true : nil
        persist()
    }

    // MARK: - 점검 (--account-check)

    /// 저장해 둔 자격증명. `security`를 기다리므로 메인 스레드에서 부르지 않는다.
    func storedCredentials(for id: String) -> Data? {
        ClaudeLogin.readKeychain(service: Self.keychainService, account: id)
    }

    /// 점검이 바꾼 마지막 사용률을 되돌린다. 메인 스레드.
    func restoreUsage(_ saved: [String: ClaudeLogin.LastUsage?]) {
        for index in accounts.indices {
            if let usage = saved[accounts[index].id] { accounts[index].lastUsage = usage }
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: Self.listKey) }
    }

    // MARK: - 예전 저장본 꼴

    private struct LegacySnapshot: Codable {
        let credentials: Data
        let account: Data
    }
}
