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
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(GameKit.gold)
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
            FluentImage(name: boxes > 0 ? "gift" : "moneybag", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("받을 보상 \(wallet.pending.count)개").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.primary)
                Text(wallet.pending.prefix(2).map(\.title).joined(separator: ", ")
                     + (wallet.pending.count > 2 ? " 외 \(wallet.pending.count - 2)개" : ""))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                if boxes > 0 {
                    Text("행운 상자 \(boxes)개 포함 · 상점에서 열기").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                let coins = wallet.claimAll()
                claims.fire(coins: coins, boxes: boxes, big: true)
            } label: {
                HStack(spacing: 3) {
                    Text("모두 받기")
                    CoinIcon(size: 12)
                    Text(total.formatted())
                }
            }
            .buttonStyle(GameButtonStyle(kind: .gold, height: 26))
            .accessibilityLabel("보상 모두 받기, 코인 \(total)개")
        }
        .padding(12)
        .rarityFrame(nil, highlight: GameKit.gold, radius: 10)
    }

    // MARK: 레벨 · 출석

    private var progressCard: some View {
        let level = wallet.runnerLevel
        let streak = wallet.attendance.current(on: GameWallet.dayNumber())
        let checkedToday = wallet.attendance.lastDay == GameWallet.dayNumber()
        let next = RunnerLevel.reward(reaching: level.level + 1)
        // 이번 7일 주기에서 지난 날
        let inCycle = streak == 0 ? 0 : (streak - 1) % Attendance.rewards.count + 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LevelEmblem(level: level.level, size: 42)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("러너 레벨").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.primary)
                        Spacer()
                        Text("\(level.xp.formatted()) / \(level.needed.formatted()) XP")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                    GaugeTrack(fraction: Double(level.xp) / Double(max(level.needed, 1)))
                    HStack(spacing: 3) {
                        Text("레벨 \(level.level + 1) 보상").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                        CoinAmount(amount: next.coins, size: 10)
                        if next.box { FluentImage(name: "gift", size: 12) }
                    }
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("출석").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.primary)
                    Text(streak > 0 ? "\(streak)일 연속" : "오늘 한 판 하면 1일째")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                    Spacer()
                    if streak > 0 && !checkedToday {
                        Text("오늘 한 판 남음").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.warning)
                    }
                }
                HStack(spacing: 5) {
                    ForEach(0..<Attendance.rewards.count, id: \.self) { i in
                        AttendanceDay(day: i + 1, coins: Attendance.rewards[i], last: i == Attendance.rewards.count - 1,
                                      reached: i < inCycle, next: i == inCycle && !checkedToday)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(streak > 0 ? "출석 \(streak)일 연속" : "오늘 한 판으로 출석")
        }
        .padding(12)
        .rarityFrame(nil, radius: 10)
    }

    // MARK: 목록

    /// 카드 바깥에 갈래 이름과 진행, 안에 줄을 둔다 (설정 화면과 같은 짜임).
    private func list<Content: View>(_ title: String, count: String, note: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GameSectionHeader(title: title, count: count, note: note)
            VStack(spacing: 0) { content() }
                .rarityFrame(nil, radius: 10)
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
                    CoinAmount(amount: reward, size: 11).opacity(done ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { Hairline().padding(.leading, 44) }
        }
        .accessibilityElement(children: .combine)
    }

    private func claimButton(_ id: String, coins: Int) -> some View {
        Button {
            if let reward = wallet.claim(id) { claims.fire(coins: reward.coins, boxes: reward.boxes, big: false) }
        } label: {
            HStack(spacing: 3) {
                Text("받기")
                CoinIcon(size: 12)
                Text(coins.formatted())
            }
        }
        .buttonStyle(GameButtonStyle(kind: .gold, height: 22))
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
                    CoinAmount(amount: next.reward, size: 11)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { Hairline().padding(.leading, 44) }
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
                Circle().fill(Theme.positive)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .black)).foregroundStyle(.white)
            } else {
                Circle().stroke(Theme.track, lineWidth: 3)
                Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(GameKit.gold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// 출석 하루 칸. 지난 날은 금빛에 체크, 오늘 할 날은 금테, 7일째는 상자.
private struct AttendanceDay: View {
    let day: Int
    let coins: Int
    let last: Bool
    let reached: Bool
    let next: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(spacing: 2) {
            ZStack {
                if last {
                    FluentImage(name: "gift", size: 18).saturation(reached ? 1 : 0.6)
                } else {
                    CoinIcon(size: 15, dimmed: !reached && !next)
                }
                if reached {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white, Theme.positive)
                        .offset(x: 9, y: 7)
                }
            }
            .frame(height: 19)
            Text("\(day)일").font(.system(size: 9, weight: .bold)).foregroundStyle(reached || next ? Theme.primary : Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(shape.fill(reached ? GameKit.gold.opacity(0.16) : Color.white.opacity(0.04)))
        .overlay(shape.strokeBorder(next ? GameKit.gold : reached ? GameKit.gold.opacity(0.45) : Theme.hairline,
                                    lineWidth: next ? 1.5 : 1))
        .tip("\(day)일째 \(coins)코인\(last ? "과 행운 상자" : "")")
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
                        // 값을 먼저 구해 둔다. 수식을 수정자 안에 바로 쓰면 컴파일러가 타입 추론에 오래 걸린다
                        let age: Double = context.date.timeIntervalSince(burst.at)
                        let boxes: String = burst.boxes > 0 ? "  상자 \(burst.boxes)" : ""
                        let size: CGFloat = burst.big ? 22 : 16
                        let rise: CGFloat = 48 - CGFloat(age) * 36
                        let fade: Double = max(0, 1 - age / 1.2)
                        let pop: CGFloat = 1 + 0.25 * CGFloat(max(0, 1 - age * 4))
                        Text("+\(burst.coins)" + boxes)
                            .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(GameShopView.gold)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .offset(y: rise)
                            .opacity(fade)
                            .scaleEffect(pop)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}
