import Foundation
import GameCore

/// 순위 소식. 요약을 주기적으로 받아 지난번과 견주고, 러너가 말풍선으로 알릴 문구를 쌓는다.
/// 팝오버가 열려 있으면 30초마다, 순위에 참여 중이면 닫혀 있어도 10분마다 받는다. 메인 스레드에서만 쓴다.
final class LeaderboardFeed {
    static let shared = LeaderboardFeed()

    private static let snapshotKey = "leaderboardSnapshot"
    private static let stageInterval: TimeInterval = 30
    private static let backgroundInterval: TimeInterval = 10 * 60

    private(set) var summary: Leaderboard.Summary?
    /// 말풍선으로 알릴 소식. 같은 종류는 마지막 것만 둔다 (1위 경신이 여러 번 쌓이지 않게).
    /// 메모리에만 두어, 앱을 끄면 못다 한 소식은 버린다.
    private var pending: [(kind: String, line: String)] = []
    private var stageTimer: Timer?
    private var backgroundTimer: Timer?
    private var loading = false
    /// 새 소식이 생겼을 때 (무대가 듣는다).
    var onNews: () -> Void = {}

    private init() {}

    /// 앱이 켜질 때. 참여 중이면 팝오버를 열지 않아도 가끔 받아 소식을 모아 둔다.
    func start() {
        backgroundTimer?.invalidate()
        let timer = Timer(timeInterval: Self.backgroundInterval, repeats: true) { [weak self] _ in
            guard Leaderboard.shared.isOn else { return }
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
        if Leaderboard.shared.isOn { refresh() }
    }

    /// 보이는 무대 수. 앱 창에서 화면을 바꾸면 새 무대가 옛 무대보다 먼저 나타나기도 해서,
    /// 마지막 무대가 사라질 때만 타이머를 끈다.
    private var visibleStages = 0

    func stageAppeared() {
        visibleStages += 1
        refresh()
        guard stageTimer == nil else { return }
        let timer = Timer(timeInterval: Self.stageInterval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        stageTimer = timer
    }

    func stageDisappeared() {
        visibleStages = max(0, visibleStages - 1)
        guard visibleStages == 0 else { return }
        stageTimer?.invalidate()
        stageTimer = nil
    }

    var hasNews: Bool { !pending.isEmpty }

    func takeNews() -> [String] {
        defer { pending.removeAll() }
        return pending.map(\.line)
    }

    /// 비교 기준을 버린다. 다음 요약은 기준으로만 쓴다 (내 기록을 지운 뒤 등).
    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        pending.removeAll()
    }

    /// 게임 중 목표로 삼을 사람들: 나를 빼고, 이 Mac의 최고 점수보다 위에 있는 사람만.
    /// 이미 넘은 사람까지 넣으면 상위권은 판마다 추월 알림이 수십 번 뜬다.
    var rivals: [Rival] {
        let me = Leaderboard.shared.playerKey
        let floor = max(GameRecords.best, summary?.you?.score ?? 0)
        return (summary?.rivals ?? [])
            .filter { $0.key != me && $0.score > floor }
            .map { Rival(name: $0.nickname, score: $0.score) }
    }

    func refresh() {
        guard Leaderboard.shared.isAvailable, !loading else { return }
        loading = true
        Leaderboard.shared.fetchSummary { [weak self] result in
            guard let self else { return }
            self.loading = false
            guard case .success(let summary) = result else { return }
            self.summary = summary
            self.compare(summary)
        }
    }

    private func compare(_ summary: Leaderboard.Summary) {
        let me = Leaderboard.shared.playerKey
        let now = RankSnapshot(topKey: summary.top?.key, topName: summary.top?.nickname, topScore: summary.top?.score,
                               topIsYou: summary.top?.key == me, weekTopKey: summary.weekTop?.key,
                               weekTopName: summary.weekTop?.nickname, weekTopScore: summary.weekTop?.score,
                               weekTopIsYou: summary.weekTop?.key == me, myRank: summary.you?.rank)
        let defaults = UserDefaults.standard
        let before = defaults.data(forKey: Self.snapshotKey).flatMap { try? JSONDecoder().decode(RankSnapshot.self, from: $0) }
        if let data = try? JSONEncoder().encode(now) { defaults.set(data, forKey: Self.snapshotKey) }
        let news = RankFeed.news(from: before, to: now)
        guard !news.isEmpty else { return }
        for item in news {
            let kind = Self.kind(item)
            pending.removeAll { $0.kind == kind }
            pending.append((kind, Self.line(item)))
        }
        onNews()
    }

    private static func kind(_ news: RankNews) -> String {
        switch news {
        case .newChampion, .championImproved, .youAreChampion: return "champion"
        case .newWeeklyChampion: return "week"
        case .overtaken: return "overtaken"
        }
    }

    static func line(_ news: RankNews) -> String {
        switch news {
        case .newChampion(let name, let score): return "새 1위! \(name) \(score)점"
        case .championImproved(let name, let score): return "\(name), 1위 기록 경신 \(score)점"
        case .youAreChampion(let score): return "내가 전체 1위! \(score)점"
        case .newWeeklyChampion(let name, let score): return "이번 주 1위는 \(name) \(score)점"
        case .overtaken(let from, let to): return "누가 나를 추월했어 (\(from)위 → \(to)위)"
        }
    }
}
