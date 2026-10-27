import AppKit
import UsageCore

/// `--account-check`: 기억한 Claude 계정을 실제로 점검하고 바꿔 본다. 토큰은 찍지 않는다.
///   RunTime --account-check                 계정마다 저장본, 토큰 주인, 공식 사용률
///   RunTime --account-check switch <이메일>   그 계정으로 바꾸고 결과 확인
///   RunTime --account-check simulate-limit   지금 계정이 세션 한도에 막힌 것처럼 넣어 자동 전환 확인
///   RunTime --account-check refresh          쓰지 않는 계정 토큰이 곧 만료되면 새로 받아 저장한 뒤 점검
enum AccountCheck {

    static func run(_ args: [String]) -> Never {
        DispatchQueue.main.async {
            // 토큰을 돌리거나 계정을 바꾸는 일은 켜 둔 앱과 같은 리프레시 토큰을 동시에 쓰면 한쪽 로그인이 풀린다.
            // 앱이 켜져 있으면 읽기만 한다
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.runtime.RunTime")
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if running, ["switch", "simulate-limit", "refresh"].contains(args.first ?? "") {
                print("RunTime 앱이 켜져 있어 \(args.first ?? "")은 하지 않습니다. 앱을 끄고 다시 실행하거나, 앱 메뉴에서 하세요")
                exit(1)
            }
            switch args.first {
            case "switch": switchTo(args.dropFirst().first ?? "")
            case "simulate-limit": simulateLimit()
            case "refresh": keepAlive()
            default: report { exit(0) }
            }
        }
        dispatchMain()
    }

    private static var switcher: AccountSwitcher { .shared }

    private static func report(then done: @escaping () -> Void) {
        let accounts = switcher.accounts
        let active = switcher.activeID
        DispatchQueue.global().async {
            let live = ClaudeLogin.liveCredentials()
            let liveOwner = live.map { owner in wait { await ClaudeLogin.owner(of: owner) } }
            print("~/.claude.json 계정: \(ClaudeLogin.currentAccount()?.email ?? "없음")")
            print("키체인 토큰 주인: \(describe(liveOwner, accounts: accounts))")
            print("자동 전환: \(switcher.autoSwitch ? "켬" : "끔") (기준 \(Int(AccountSwitcher.autoSwitchLimit))%)")
            for account in accounts {
                let mark = account.id == active ? "*" : " "
                print("\(mark) \(account.email) [\(account.plan.map(AccountSwitcher.Account.planName) ?? "-")]")
                guard let credentials = switcher.storedCredentials(for: account.id),
                      let parsed = OAuthUsageProvider.parseCredentials(credentials)
                else { print("    저장본: 없음"); continue }
                let left = Int(parsed.expiresAt.timeIntervalSinceNow / 60)
                let hasRefresh = ClaudeLogin.refreshToken(in: credentials) != nil
                let refreshDays = ((try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any])
                    .flatMap { ($0["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] as? NSNumber }
                    .map { " (\(Int(($0.doubleValue / 1000 - Date().timeIntervalSince1970) / 86400))일 남음)" } ?? ""
                print("    저장본: 있음, 액세스 토큰 \(left > 0 ? "\(left)분 남음" : "만료"), 리프레시 토큰 \(hasRefresh ? "있음" + refreshDays : "없음")\(account.needsLogin == true ? ", 다시 로그인 필요" : "")")
                guard left > 0 else { continue }
                let owner = wait { await ClaudeLogin.owner(of: credentials) }
                print("    토큰 주인: \(describe(owner, accounts: accounts))\(owner == .account(account.id) ? " (맞음)" : " (다름!)")")
                let usage: String = wait {
                    do {
                        let u = try await OAuthUsageProvider.fetch(token: parsed.token,
                                                                   userAgent: OAuthUsageProvider.userAgent(clientVersion: nil))
                        return "세션 \(u.sessionPercent.map { "\(Int($0))%" } ?? "-"), 주간 \(u.weeklyPercent.map { "\(Int($0))%" } ?? "-")"
                    } catch { return "받지 못함 (\(error))" }
                }
                print("    공식 사용률: \(usage)")
                if let last = account.lastUsage {
                    print("    앱이 기억한 값: 세션 \(last.sessionPercent.map { "\(Int($0))%" } ?? "-"), 주간 \(last.weeklyPercent.map { "\(Int($0))%" } ?? "-"), 지금 기준 \(Int(last.effectivePercent(now: Date())))%")
                }
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    private static func switchTo(_ query: String) {
        guard let target = switcher.accounts.first(where: { $0.email == query || $0.id == query }) else {
            print("그런 계정이 없습니다: \(query)")
            exit(1)
        }
        print("\(switcher.active?.email ?? "?") → \(target.email)")
        switcher.switchTo(target.id) { error in
            if let error { print("실패: \(error)"); exit(1) }
            verify(expected: target)
        }
    }

    private static func keepAlive() {
        switcher.keepOthersFresh { results in
            for (account, freshness) in results {
                let result: String
                switch freshness {
                case .usable: result = "쓸 수 있음"
                case .rejected: result = "리프레시 토큰 거절 (다시 로그인 필요)"
                case .mismatch: result = "저장본이 다른 계정 것"
                case .unavailable: result = "새로 받지 못함"
                }
                print("\(account.email): \(result)")
            }
            report { exit(0) }
        }
    }

    private static func simulateLimit() {
        guard switcher.accounts.count > 1, let from = switcher.active else {
            print("계정이 둘 이상 있어야 합니다")
            exit(1)
        }
        var saved: [String: ClaudeLogin.LastUsage?] = [:]
        for account in switcher.accounts { saved[account.id] = account.lastUsage }
        let wasOn = switcher.autoSwitch
        switcher.autoSwitch = true
        let hit = LimitHit(timestamp: Date(), window: .session, resetsAt: Date().addingTimeInterval(3600))
        print("\(from.email)이 세션 한도에 막힌 기록을 넣습니다")
        switcher.limitReached(hit)
        // 바꾸기는 계정 큐에서 돌고 끝나면 switching이 꺼진다
        func poll(_ tries: Int) {
            if switcher.switching && tries < 120 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll(tries + 1) }
                return
            }
            switcher.autoSwitch = wasOn
            switcher.restoreUsage(saved)
            guard let now = switcher.active, now.id != from.id else {
                print("실패: 바뀌지 않았습니다 \(switcher.lastError.map { "(\($0))" } ?? "")")
                exit(1)
            }
            verify(expected: now)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll(0) }
    }

    /// 키체인 토큰 주인과 ~/.claude.json 계정이 모두 기대한 계정인지 본다.
    private static func verify(expected: AccountSwitcher.Account) {
        let accounts = switcher.accounts
        DispatchQueue.global().async {
            let config = ClaudeLogin.currentAccount()?.uuid
            let owner = ClaudeLogin.liveCredentials().map { live in wait { await ClaudeLogin.owner(of: live) } }
            print("~/.claude.json: \(config == expected.id ? "맞음" : "다름!")")
            print("키체인 토큰 주인: \(describe(owner, accounts: accounts))")
            let ok = config == expected.id && (owner == .account(expected.id) || owner == .expired)
            print(ok ? "통과: \(expected.email)로 바뀜" : "실패")
            exit(ok ? 0 : 1)
        }
    }

    private static func describe(_ owner: ClaudeLogin.Owner?, accounts: [AccountSwitcher.Account]) -> String {
        switch owner {
        case .account(let id)?: return accounts.first { $0.id == id }?.email ?? "모르는 계정 \(id.prefix(8))"
        case .expired?: return "확인 못함 (액세스 토큰 만료)"
        case .unknown?: return "확인 못함"
        case nil: return "토큰 없음"
        }
    }

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
}
