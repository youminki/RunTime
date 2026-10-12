import SwiftUI
import GameCore

/// 퀘스트: 받을 보상, 러너 레벨과 출석, 오늘의 미션, 이번 주 도전, 업적.
/// 채운 퀘스트의 보상은 여기서 눌러 받는다 (받는 순간 코인이 튀어 오른다).
struct QuestView: View {
    @ObservedObject private var wallet = GameWallet.shared
    @StateObject private var claims = ClaimBursts()
    @StateObject private var page = QuestPage()

    /// 업적은 끝내기 가까운 것만 먼저 보인다.
    private static let achievementsShown = 3

    var body: some View {
        let daily = wallet.missions
        let weekly = wallet.weekly
        let pendingIDs = Set(wallet.pending.map(\.id))
        VStack(alignment: .leading, spacing: 10) {
            if !wallet.pending.isEmpty { pendingCard }
            levelCard
            section("오늘의 미션", icon: "sun.max.fill",
                    trailing: "\(daily.doneCount)/\(daily.missions.count) · \(Self.untilTomorrow())") {
                ForEach(Array(daily.missions.enumerated()), id: \.offset) { index, mission in
                    row(icon: mission.icon, title: mission.title(weekly: false), progress: daily.progress[index],
                        target: mission.target, reward: mission.reward, done: daily.isDone(index),
                        claimID: pendingIDs.contains("d\(daily.day)-\(index)") ? "d\(daily.day)-\(index)" : nil)
                }
            }
            section("이번 주 도전", icon: "calendar",
                    trailing: "\(weekly.doneCount)/\(weekly.missions.count) · \(Self.untilNextWeek())") {
                ForEach(Array(weekly.missions.enumerated()), id: \.offset) { index, mission in
                    row(icon: mission.icon, title: mission.title(weekly: false), progress: weekly.progress[index],
                        target: mission.target, reward: mission.reward, done: weekly.isDone(index),
                        claimID: pendingIDs.contains("w\(weekly.day)-\(index)") ? "w\(weekly.day)-\(index)" : nil)
                }
            }
            let book = wallet.achievements
            let done = Achievements.Kind.allCases.reduce(0) { $0 + book.levels($1) }
            let total = Achievements.Kind.allCases.reduce(0) { $0 + Achievements.maxLevel($1) }
            let kinds = sortedAchievements(book)
            section("업적", icon: "rosette", trailing: "\(done)/\(total)") {
                ForEach(page.allAchievements ? kinds : Array(kinds.prefix(Self.achievementsShown)), id: \.self) { kind in
                    achievementRow(kind, book: book)
                }
                if kinds.count > Self.achievementsShown {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { page.allAchievements.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(page.allAchievements ? "접기" : "업적 \(kinds.count)개 모두 보기")
                            Image(systemName: page.allAchievements ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("판이 끝나면 채운 보상이 맨 위에 쌓입니다. 날마다 한 판 하면 출석이 이어지고, 7일째와 5레벨마다 행운 상자를 줍니다.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .overlay { ClaimBurstLayer(claims: claims) }
    }

    // MARK: 레벨 · 출석

    private var levelCard: some View {
        let level = wallet.runnerLevel
        let streak = wallet.attendance.current(on: GameWallet.dayNumber())
        let checkedToday = wallet.attendance.lastDay == GameWallet.dayNumber()
        let next = RunnerLevel.reward(reaching: level.level + 1)
        return Card(padding: 10) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Theme.accent)
                        VStack(spacing: -2) {
                            Text("Lv").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                            Text("\(level.level)").font(.system(size: 15, weight: .heavy, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("러너 레벨").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                            Spacer()
                            Text("\(level.xp)/\(level.needed) XP").font(Theme.caption.monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                        }
                        ProgressTrack(fraction: Double(level.xp) / Double(max(level.needed, 1)), done: false,
                                      color: Theme.accent, height: 6)
                        Text("레벨 \(level.level + 1) 보상 \(next.coins)코인\(next.box ? " · 행운 상자" : "")")
                            .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                }
                Hairline()
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(streak > 0 ? Theme.warning : Theme.tertiary)
                        .frame(width: 16)
                    Text(streak > 0 ? "\(streak)일 연속" : "오늘 한 판으로 출석")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary)
                    Spacer(minLength: 4)
                    // 이번 7일 주기에서 지난 날과 남은 날
                    let inCycle = streak == 0 ? 0 : (streak - 1) % Attendance.rewards.count + 1
                    HStack(spacing: 3) {
                        ForEach(0..<Attendance.rewards.count, id: \.self) { i in
                            let reached = i < inCycle
                            let isNext = i == inCycle && !checkedToday
                            ZStack {
                                Circle().fill(reached ? GameShopView.gold : Color.white.opacity(isNext ? 0.16 : 0.07))
                                if i == Attendance.rewards.count - 1 {
                                    Image(systemName: "gift.fill").font(.system(size: 7.5, weight: .bold))
                                        .foregroundStyle(reached ? .black.opacity(0.7) : Theme.tertiary)
                                } else if reached {
                                    Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.black.opacity(0.7))
                                } else {
                                    Text("\(i + 1)").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.tertiary)
                                }
                            }
                            .frame(width: 17, height: 17)
                            .overlay(Circle().strokeBorder(isNext ? GameShopView.gold.opacity(0.8) : .clear, lineWidth: 1))
                            .help("\(i + 1)일째 +\(Attendance.rewards[i])\(i == Attendance.rewards.count - 1 ? " · 행운 상자" : "")")
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(streak > 0 ? "출석 \(streak)일 연속" : "오늘 한 판으로 출석")
            }
        }
    }

    // MARK: 받을 보상

    private var pendingCard: some View {
        let total = wallet.pending.reduce(0) { $0 + $1.coins }
        let boxes = wallet.pending.reduce(0) { $0 + $1.boxes }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gift.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(GameShopView.gold)
                Text("받을 보상 \(wallet.pending.count)개").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
                Spacer()
                Button {
                    let coins = wallet.claimAll()
                    claims.fire(coins: coins, boxes: boxes, big: true)
                } label: {
                    HStack(spacing: 3) {
                        Text("모두 받기")
                        Text("+\(total)").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(GameShopView.gold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("보상 모두 받기, 코인 \(total)개")
            }
            ForEach(wallet.pending.prefix(4)) { reward in
                HStack(spacing: 6) {
                    Text(reward.title).font(Theme.caption).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if reward.boxes > 0 {
                        Image(systemName: "gift.fill").font(.system(size: 9)).foregroundStyle(GameShopView.gold)
                    }
                    claimButton(reward.id, coins: reward.coins)
                }
            }
            if wallet.pending.count > 4 {
                Text("그 밖 \(wallet.pending.count - 4)개").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            if boxes > 0 {
                Text("행운 상자 \(boxes)개는 받은 뒤 상점에서 공짜로 엽니다").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(GameShopView.gold.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(GameShopView.gold.opacity(0.45)))
    }

    private func claimButton(_ id: String, coins: Int) -> some View {
        Button {
            if let reward = wallet.claim(id) { claims.fire(coins: reward.coins, boxes: reward.boxes, big: false) }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "dollarsign.circle.fill").font(.system(size: 9, weight: .bold))
                Text("받기 +\(coins)")
            }
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(.black.opacity(0.8))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(GameShopView.gold))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("받기, 코인 \(coins)개")
    }

    // MARK: 줄

    private func section<Content: View>(_ title: String, icon: String, trailing: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .frame(width: 16)
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                    Spacer()
                    Text(trailing).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                content()
            }
        }
    }

    private func row(icon: String, title: String, progress: Int, target: Int, reward: Int, done: Bool,
                     claimID: String?) -> some View {
        let value = min(progress, target)
        return HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(done ? Theme.positive : Theme.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(Theme.caption).foregroundStyle(done && claimID == nil ? Theme.tertiary : Theme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(done ? "완료" : "\(value.formatted())/\(target.formatted())")
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                ProgressTrack(fraction: Double(value) / Double(max(target, 1)), done: done)
            }
            if let claimID {
                claimButton(claimID, coins: reward)
            } else {
                rewardChip(reward, done: done)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 끝내기 가까운 것 순서. 다 깬 업적은 맨 뒤. 받을 보상은 맨 위 카드에 따로 나오므로 순서에 넣지 않는다
    /// (넣으면 받는 순간 줄이 다른 자리로 옮겨 마우스 밑 줄이 바뀐다).
    private func sortedAchievements(_ book: Achievements) -> [Achievements.Kind] {
        func rank(_ kind: Achievements.Kind) -> (Int, Double) {
            guard let next = book.next(kind) else { return (1, 0) }
            return (0, -Double(book.value(kind)) / Double(max(next.target, 1)))
        }
        return Achievements.Kind.allCases.sorted { rank($0) < rank($1) }
    }

    /// 업적 한 줄: 이름과 단계 점, 다음 목표까지의 수, 막대. 목표 문장은 마우스를 올리면 보인다.
    private func achievementRow(_ kind: Achievements.Kind, book: Achievements) -> some View {
        let level = book.levels(kind)
        let max = Achievements.maxLevel(kind)
        let next = book.next(kind)
        let claim = level > 0 ? wallet.pending.first { $0.id.hasPrefix("a\(kind.rawValue)-") } : nil
        return HStack(spacing: 8) {
            Image(systemName: next == nil ? "checkmark.circle.fill" : kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(next == nil ? Theme.positive : Theme.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(kind.name).font(Theme.caption).foregroundStyle(next == nil ? Theme.tertiary : Theme.primary)
                        .lineLimit(1)
                    HStack(spacing: 2) {
                        ForEach(0..<max, id: \.self) { i in
                            Circle().fill(i < level ? GameShopView.gold : Color.white.opacity(0.15)).frame(width: 4, height: 4)
                        }
                    }
                    Spacer(minLength: 4)
                    if let next {
                        Text("\(min(book.value(kind), next.target).formatted())/\(next.target.formatted())")
                            .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                    } else {
                        Text("완료").font(Theme.caption).foregroundStyle(Theme.tertiary)
                    }
                }
                ProgressTrack(fraction: next.map { Double(book.value(kind)) / Double(Swift.max($0.target, 1)) } ?? 1,
                              done: next == nil)
            }
            if let claim {
                claimButton(claim.id, coins: claim.coins)
            } else if let next {
                rewardChip(next.reward, done: false)
            } else {
                rewardChip(nil, done: true)
            }
        }
        .help(next.map { "\(level + 1)단계: \(kind.goal($0.target))" } ?? "모든 단계를 채웠습니다")
        .accessibilityElement(children: .combine)
    }

    private func rewardChip(_ reward: Int?, done: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: done ? "checkmark" : "dollarsign.circle.fill").font(.system(size: 9, weight: .bold))
            if let reward { Text("+\(reward)") }
        }
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .foregroundStyle(done ? Theme.tertiary : GameShopView.gold)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(done ? Color.white.opacity(0.05) : GameShopView.gold.opacity(0.14)))
        .frame(minWidth: 46, alignment: .trailing)
    }

    /// "5시간 뒤 바뀜"
    static func untilTomorrow(now: Date = Date()) -> String {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return "" }
        return "\(Format.duration(tomorrow.timeIntervalSince(now))) 뒤 바뀜"
    }

    /// 다음 월요일 0시까지 (ISO 주).
    static func untilNextWeek(now: Date = Date()) -> String {
        let calendar = Calendar(identifier: .iso8601)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return "" }
        return "\(Format.duration(week.end.timeIntervalSince(now))) 뒤 바뀜"
    }
}

/// 업적을 모두 펼쳤는지. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class QuestPage: ObservableObject {
    @Published var allAchievements = false
}

/// 얇은 진행 막대.
struct ProgressTrack: View {
    let fraction: Double
    let done: Bool
    var color: Color = GameShopView.gold
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(done ? Theme.positive : color)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 받는 순간

/// 보상을 받은 순간들. 코인이 사방으로 튀어 오르고 "+N"이 떠오른다.
final class ClaimBursts: ObservableObject {
    struct Burst: Identifiable {
        let id = UUID()
        let coins: Int
        let boxes: Int
        let big: Bool
        let at = Date()
    }

    @Published var bursts: [Burst] = []

    func fire(coins: Int, boxes: Int, big: Bool) {
        guard coins > 0 || boxes > 0 else { return }
        GameSound.shared.play(big ? .mission : .coin)
        let burst = Burst(coins: coins, boxes: boxes, big: big)
        bursts.append(burst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.bursts.removeAll { $0.id == burst.id }
        }
    }
}

private struct ClaimBurstLayer: View {
    @ObservedObject var claims: ClaimBursts

    /// 튀어 오른 코인 하나: 사방으로 날아가다 떨어지며 사라진다.
    static func drawCoin(_ i: Int, of count: Int, big: Bool, age: Double, origin: CGPoint, _ cg: CGContext) {
        let jitter = Double(RunnerStageHash.value(i, 4)) * 0.4
        let angle = Double(i) / Double(count) * .pi * 2 + jitter
        let base: Double = big ? 150 : 100
        let speed = base * (0.6 + Double(RunnerStageHash.value(i, 6)) * 0.6)
        let dx = cos(angle) * speed * age
        let dy = sin(angle) * speed * age - 120 * age + 260 * age * age
        let alpha = CGFloat(max(0, 1 - age / 1.1))
        guard let coin = GameSprite.coin.frame(at: age * 3 + Double(i)) else { return }
        cg.saveGState()
        cg.setAlpha(alpha)
        let rect = CGRect(x: origin.x + CGFloat(dx) - 7, y: origin.y + CGFloat(dy) - 7, width: 14, height: 14)
        GameAssets.draw(coin, in: rect, cg)
        cg.restoreGState()
    }

    var body: some View {
        if !claims.bursts.isEmpty {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                Canvas { canvas, size in
                    canvas.withCGContext { cg in
                        for burst in claims.bursts {
                            let age = context.date.timeIntervalSince(burst.at)
                            let origin = CGPoint(x: size.width / 2, y: 60)
                            let count = burst.big ? 22 : 10
                            for i in 0..<count { Self.drawCoin(i, of: count, big: burst.big, age: age, origin: origin, cg) }
                        }
                    }
                }
                .overlay(alignment: .top) {
                    ForEach(claims.bursts) { burst in
                        let age = context.date.timeIntervalSince(burst.at)
                        Text("+\(burst.coins)\(burst.boxes > 0 ? "  상자 \(burst.boxes)" : "")")
                            .font(.system(size: burst.big ? 22 : 16, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(GameShopView.gold)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .offset(y: 48 - CGFloat(age) * 36)
                            .opacity(max(0, 1 - age / 1.2))
                            .scaleEffect(1 + 0.25 * max(0, 1 - age * 4))
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}
