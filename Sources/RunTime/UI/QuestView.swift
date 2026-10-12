import SwiftUI
import GameCore

/// 퀘스트: 받을 보상, 레벨과 출석, 오늘·이번 주 미션, 업적.
/// 줄마다 진행 링, 이름, 진행 수치, 보상 코인만 둔다. 다 채운 줄은 그 자리에서 받는다.
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
        let book = wallet.achievements
        let kinds = sortedAchievements(book)
        VStack(alignment: .leading, spacing: 14) {
            if !wallet.pending.isEmpty { pendingBanner }
            progressCard
            list("오늘", count: "\(daily.doneCount)/\(daily.missions.count)", note: Self.untilTomorrow()) {
                ForEach(Array(daily.missions.enumerated()), id: \.offset) { index, mission in
                    let id = "d\(daily.day)-\(index)"
                    missionRow(title: mission.title(weekly: false), progress: daily.progress[index],
                               target: mission.target, reward: mission.reward, done: daily.isDone(index),
                               claimID: pendingIDs.contains(id) ? id : nil, last: index == daily.missions.count - 1)
                }
            }
            list("이번 주", count: "\(weekly.doneCount)/\(weekly.missions.count)", note: Self.untilNextWeek()) {
                ForEach(Array(weekly.missions.enumerated()), id: \.offset) { index, mission in
                    let id = "w\(weekly.day)-\(index)"
                    missionRow(title: mission.title(weekly: false), progress: weekly.progress[index],
                               target: mission.target, reward: mission.reward, done: weekly.isDone(index),
                               claimID: pendingIDs.contains(id) ? id : nil, last: index == weekly.missions.count - 1)
                }
            }
            let done = Achievements.Kind.allCases.reduce(0) { $0 + book.levels($1) }
            let total = Achievements.Kind.allCases.reduce(0) { $0 + Achievements.maxLevel($1) }
            let shown = page.allAchievements ? kinds : Array(kinds.prefix(Self.achievementsShown))
            list("업적", count: "\(done)/\(total)", note: "단계마다 보상") {
                ForEach(Array(shown.enumerated()), id: \.element) { index, kind in
                    achievementRow(kind, book: book, last: index == shown.count - 1 && kinds.count <= Self.achievementsShown)
                }
                if kinds.count > Self.achievementsShown {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { page.allAchievements.toggle() }
                    } label: {
                        Text(page.allAchievements ? "접기" : "업적 \(kinds.count)개 모두 보기")
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("판이 끝나면 채운 보상이 쌓입니다. 날마다 한 판 하면 출석이 이어지고, 7일째와 5레벨마다 행운 상자를 줍니다.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .overlay { ClaimBurstLayer(claims: claims) }
    }

    // MARK: 받을 보상

    private var pendingBanner: some View {
        let total = wallet.pending.reduce(0) { $0 + $1.coins }
        let boxes = wallet.pending.reduce(0) { $0 + $1.boxes }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("받을 보상 \(wallet.pending.count)개").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(wallet.pending.prefix(2).map(\.title).joined(separator: ", ")
                     + (wallet.pending.count > 2 ? " 외 \(wallet.pending.count - 2)개" : ""))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                if boxes > 0 {
                    Text("행운 상자 \(boxes)개 포함, 받은 뒤 상점에서 엽니다").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button {
                let coins = wallet.claimAll()
                claims.fire(coins: coins, boxes: boxes, big: true)
            } label: {
                Text("모두 받기 · \(total)코인")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(GameShopView.gold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("보상 모두 받기, 코인 \(total)개")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(GameShopView.gold.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(GameShopView.gold.opacity(0.35)))
    }

    // MARK: 레벨 · 출석

    private var progressCard: some View {
        let level = wallet.runnerLevel
        let streak = wallet.attendance.current(on: GameWallet.dayNumber())
        let checkedToday = wallet.attendance.lastDay == GameWallet.dayNumber()
        let next = RunnerLevel.reward(reaching: level.level + 1)
        // 이번 7일 주기에서 지난 날
        let inCycle = streak == 0 ? 0 : (streak - 1) % Attendance.rewards.count + 1
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("레벨 \(level.level)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                    Spacer()
                    Text("\(level.xp)/\(level.needed) XP").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                ProgressTrack(fraction: Double(level.xp) / Double(max(level.needed, 1)), done: false, color: Theme.accent, height: 5)
                Text("레벨 \(level.level + 1)이 되면 \(next.coins)코인\(next.box ? "과 행운 상자" : "")")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                Hairline().padding(.vertical, 2)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("출석").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                        Text(streak > 0 ? "\(streak)일 연속\(checkedToday ? "" : ", 오늘 한 판 남음")" : "오늘 한 판 하면 1일째")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 5) {
                        ForEach(0..<Attendance.rewards.count, id: \.self) { i in
                            let reached = i < inCycle
                            let isNext = i == inCycle && !checkedToday
                            let last = i == Attendance.rewards.count - 1
                            Group {
                                if last {
                                    Image(systemName: "gift.fill").font(.system(size: 9))
                                        .foregroundStyle(reached ? GameShopView.gold : Theme.tertiary)
                                } else {
                                    Circle().fill(reached ? GameShopView.gold : Color.white.opacity(0.12))
                                        .overlay(Circle().strokeBorder(isNext ? GameShopView.gold : .clear, lineWidth: 1))
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .frame(width: 10, height: 10)
                            .help("\(i + 1)일째 \(Attendance.rewards[i])코인\(last ? "과 행운 상자" : "")")
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(streak > 0 ? "출석 \(streak)일 연속" : "오늘 한 판으로 출석")
            }
        }
    }

    // MARK: 목록

    /// 카드 바깥에 갈래 이름과 진행, 안에 줄을 둔다 (설정 화면과 같은 짜임).
    private func list<Content: View>(_ title: String, count: String, note: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(count).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                Spacer()
                Text(note).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    /// 한 줄: 진행 링, 이름과 진행, 보상. 채웠지만 받지 않았으면 보상 자리에 받기 단추.
    private func missionRow(title: String, progress: Int, target: Int, reward: Int, done: Bool,
                            claimID: String?, last: Bool) -> some View {
        let value = min(progress, target)
        let fraction = Double(value) / Double(max(target, 1))
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressRing(fraction: done ? 1 : fraction, done: done)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12)).foregroundStyle(done && claimID == nil ? Theme.tertiary : Theme.primary)
                        .lineLimit(1)
                    Text(done ? "완료" : "\(value.formatted()) / \(target.formatted())")
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let claimID {
                    claimButton(claimID, coins: reward)
                } else {
                    Text("\(reward)코인").font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(done ? Theme.tertiary : Theme.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { Hairline().padding(.leading, 40) }
        }
        .accessibilityElement(children: .combine)
    }

    private func claimButton(_ id: String, coins: Int) -> some View {
        Button {
            if let reward = wallet.claim(id) { claims.fire(coins: reward.coins, boxes: reward.boxes, big: false) }
        } label: {
            Text("받기 \(coins)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.black.opacity(0.82))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(GameShopView.gold))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("받기, 코인 \(coins)개")
    }

    /// 끝내기 가까운 것 순서. 다 깬 업적은 맨 뒤. 받을 보상은 맨 위 배너에 따로 나오므로 순서에 넣지 않는다
    /// (넣으면 받는 순간 줄이 다른 자리로 옮겨 마우스 밑 줄이 바뀐다).
    private func sortedAchievements(_ book: Achievements) -> [Achievements.Kind] {
        func rank(_ kind: Achievements.Kind) -> (Int, Double) {
            guard let next = book.next(kind) else { return (1, 0) }
            return (0, -Double(book.value(kind)) / Double(max(next.target, 1)))
        }
        return Achievements.Kind.allCases.sorted { rank($0) < rank($1) }
    }

    /// 업적 한 줄: "점프 2단계", 그 아래 다음 목표와 진행.
    private func achievementRow(_ kind: Achievements.Kind, book: Achievements, last: Bool) -> some View {
        let level = book.levels(kind)
        let max = Achievements.maxLevel(kind)
        let next = book.next(kind)
        let claim = level > 0 ? wallet.pending.first { $0.id.hasPrefix("a\(kind.rawValue)-") } : nil
        let value = next.map { min(book.value(kind), $0.target) } ?? 0
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressRing(fraction: next.map { Double(value) / Double(Swift.max($0.target, 1)) } ?? 1, done: next == nil)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(kind.name).font(.system(size: 12)).foregroundStyle(next == nil ? Theme.tertiary : Theme.primary)
                        Text(next == nil ? "모두 달성" : "\(level + 1)/\(max)단계")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    }
                    if let next {
                        Text("\(kind.goal(next.target)) · \(value.formatted()) / \(next.target.formatted())")
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let claim {
                    claimButton(claim.id, coins: claim.coins)
                } else if let next {
                    Text("\(next.reward)코인").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { Hairline().padding(.leading, 40) }
        }
        .accessibilityElement(children: .combine)
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

/// 진행 링. 다 채우면 초록 체크.
struct ProgressRing: View {
    let fraction: Double
    let done: Bool

    var body: some View {
        ZStack {
            if done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Theme.positive)
            } else {
                Circle().stroke(Theme.track, lineWidth: 2.5)
                Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
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
