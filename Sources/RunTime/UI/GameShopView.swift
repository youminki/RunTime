import SwiftUI
import GameCore

/// 게임 상점. 맨 위에 행운 상자와 오늘의 특가, 그 아래 갈래별 물건. 물건마다 게임에서 보일 모습을 움직여 보여 주고,
/// 등급(일반·희귀·영웅·전설)을 테두리 색으로 나눈다.
struct GameShopView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var wallet = GameWallet.shared
    @StateObject private var state: ShopState

    init(settings: AppSettings, tab: Tab = .buddy) {
        self.settings = settings
        _state = StateObject(wrappedValue: ShopState(tab: tab))
    }

    static let gold = Color(nsColor: NSColor(hex: 0xFFD45E))

    enum Tab: String, CaseIterable {
        case ability = "능력", buddy = "동료", head = "머리", back = "등", trail = "꼬리", dust = "발먼지", crash = "부딪힘"

        var slots: [Cosmetic.Slot] {
            switch self {
            case .head: [.hat, .face]
            case .back: [.back]
            case .trail: [.trail]
            case .dust: [.dust]
            case .crash: [.crash]
            default: []
            }
        }

        var icon: String {
            switch self {
            case .ability: "bolt.shield.fill"
            case .buddy: "pawprint.fill"
            case .head: "crown.fill"
            case .back: "backpack.fill"
            case .trail: "wind"
            case .dust: "aqi.medium"
            case .crash: "burst.fill"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuckyBoxCard(wallet: wallet, reveal: state.reveal, settings: settings)
            if let deal = wallet.dailyDeal { dealCard(deal) }
            collectionLine
            tabs
            switch state.tab {
            case .ability:
                VStack(spacing: 6) { ForEach(Ability.allCases) { abilityRow($0) } }
            case .buddy:
                CompanionPicker(settings: settings)
            default:
                ForEach(state.tab.slots, id: \.self) { slot in
                    if state.tab.slots.count > 1 {
                        Text(slot.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    grid(Cosmetic.allCases.filter { $0.slot == slot }
                        .sorted { ($0.rarity.rawValue, $0.price) < ($1.rarity.rawValue, $1.price) }.map(ShopItem.cosmetic))
                }
            }
            Text(footnote).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: state.tab) { _ in state.confirming = nil }
    }

    // MARK: 머리 부분

    private var collectionLine: some View {
        let (owned, total) = wallet.collection
        return HStack(spacing: 8) {
            FluentImage(name: "trophy", size: 16)
            Text("도감").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(LinearGradient(colors: [Color(nsColor: Rarity.rare.color), Color(nsColor: Rarity.epic.color),
                                                           Color(nsColor: Rarity.legendary.color)],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(owned) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 5)
            Text("\(owned)/\(total)").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("도감 \(owned)개 모음, 전체 \(total)개")
    }

    private func dealCard(_ item: Cosmetic) -> some View {
        let price = wallet.price(of: item)
        let affordable = wallet.coins >= price
        // 확인 중에 특가 물건이 바뀌면 처음부터 다시 묻게 물건 이름까지 키에 넣는다
        let key = "deal:\(item.rawValue)"
        let asking = state.confirming == key
        return Button {
            if asking {
                state.confirming = nil
                buying { wallet.choose(item) }
            } else if affordable {
                state.confirming = key
            }
        } label: {
            HStack(spacing: 10) {
                ItemPreview(kind: .cosmetic(item), character: settings.character)
                    .frame(width: 110, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("오늘의 특가").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.warning))
                        Text("-\(Int(GameWallet.dealDiscount * 100))%").font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Theme.warning)
                    }
                    Text(item.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary)
                    RarityTag(rarity: item.rarity, slot: item.slot)
                    HStack(spacing: 4) {
                        Text(item.price.formatted()).strikethrough().foregroundStyle(Theme.tertiary)
                        Image(systemName: "dollarsign.circle.fill").foregroundStyle(Self.gold)
                        Text(asking ? "\(price)에 사기?" : price.formatted())
                            .foregroundStyle(asking ? Theme.warning : affordable ? Self.gold : Theme.tertiary)
                    }
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warning.opacity(asking ? 0.16 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.warning.opacity(asking ? 0.8 : 0.35)))
        }
        .buttonStyle(.plain)
        .help(affordable ? "두 번 누르면 삽니다. 내일 다른 물건으로 바뀝니다" : "코인 \(price - wallet.coins)개가 더 필요해요")
        .accessibilityLabel("오늘의 특가 \(item.name), \(price)코인")
    }

    /// 갈래 고르기. 일곱 개라 아이콘과 짧은 이름을 두 줄로 둔다.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let on = state.tab == tab
                Button { state.tab = tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: 11, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(on ? Theme.primary : Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? Color.white.opacity(0.12) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var footnote: String {
        switch state.tab {
        case .ability: "능력은 미니게임에서만 쓰고 다음 판부터 적용됩니다. 순위 점수 계산은 같습니다."
        case .buddy: "받아 둔 Petdex 펫을 공짜로 데려갑니다. 게임과 사용량 창 무대에서 러너 뒤를 따라 달리고, 판정과 점수는 같습니다."
        case .head: "모자와 얼굴 꾸미기는 게임과 사용량 창 무대의 러너에 씌웁니다. 그림 러너는 그림에서 눈을 찾지 못하면 얼굴 꾸미기가 보이지 않습니다."
        case .back: "등 꾸미기는 러너 등 뒤에 메거나 매달립니다. 다시 누르면 뗍니다."
        default: "게임 화면에만 보이고 점수와 판정은 같습니다. 다시 누르면 뗍니다."
        }
    }

    // MARK: 물건 칸

    enum ShopItem: Hashable {
        case cosmetic(Cosmetic)
    }

    private func grid(_ items: [ShopItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(items, id: \.self) { item in
                switch item {
                case .cosmetic(let cosmetic): cosmeticItem(cosmetic)
                }
            }
        }
    }

    /// 코인이 줄었으면(실제로 샀으면) 사는 소리를 낸다. 달기·떼기만 했으면 조용하다.
    private func buying(_ action: () -> Void) {
        let before = wallet.coins
        action()
        if wallet.coins < before { GameSound.shared.play(.purchase) }
    }

    private func cosmeticItem(_ cosmetic: Cosmetic) -> some View {
        let owned = wallet.owned.contains(cosmetic)
        let label = switch cosmetic.slot {
        case .hat, .face: "쓰기"
        case .back: "메기"
        default: "달기"
        }
        return card(key: cosmetic.rawValue, name: cosmetic.name, price: wallet.price(of: cosmetic), rarity: cosmetic.rarity,
                    owned: owned, on: wallet.equipped.contains(cosmetic), ownedLabel: label) {
            ItemPreview(kind: .cosmetic(cosmetic), character: settings.character)
        } action: {
            wallet.choose(cosmetic)
        }
    }

    /// 공통 칸. 안 산 것은 처음 누르면 "사기?"로 바뀌고, 한 번 더 누르면 산다
    /// (팝오버에서 확인 창을 띄우면 팝오버가 닫혀서).
    private func card<Preview: View>(key: String, name: String, price: Int, rarity: Rarity?, owned: Bool, on: Bool,
                                     ownedLabel: String, @ViewBuilder preview: () -> Preview,
                                     action: @escaping () -> Void) -> some View {
        let affordable = owned || wallet.coins >= price
        let asking = state.confirming == key
        let tint = rarity.map { Color(nsColor: $0.color) } ?? Theme.secondary
        let status: String
        let statusColor: Color
        if on {
            status = "쓰는 중"; statusColor = Theme.accent
        } else if owned {
            status = ownedLabel; statusColor = Theme.secondary
        } else if asking {
            status = "\(price)에 사기?"; statusColor = Theme.warning
        } else {
            status = price.formatted(); statusColor = affordable ? Self.gold : Theme.tertiary
        }
        return Button {
            if owned || asking {
                state.confirming = nil
                buying(action)
            } else if affordable {
                state.confirming = key
            }
        } label: {
            VStack(spacing: 5) {
                preview()
                    .frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if let rarity, rarity >= .rare {
                            Text(rarity.title).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(tint.opacity(0.85)))
                                .padding(4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if !owned {
                            Image(systemName: affordable ? "bag.fill" : "lock.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(4)
                                .background(Circle().fill(Color.black.opacity(0.35)))
                                .padding(4)
                        }
                    }
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 2)
                    HStack(spacing: 2) {
                        if !owned && !asking { Image(systemName: "dollarsign.circle.fill") }
                        Text(status)
                    }
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? Theme.accent.opacity(0.16) : asking ? Theme.warning.opacity(0.14) : tint.opacity(0.07)))
            .overlay(RarityBorder(rarity: rarity, highlight: on ? Theme.accent : asking ? Theme.warning : nil))
            .opacity(affordable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(affordable ? (owned ? name : "\(price)코인. 두 번 누르면 삽니다") : "코인 \(price - wallet.coins)개가 더 필요해요")
        .accessibilityLabel("\(name)\(rarity.map { ", \($0.title)" } ?? ""), \(status)")
    }

    // MARK: 능력

    /// 능력 한 줄: 단계, 켜고 끄기, 다음 단계 사기 (두 번 눌러 산다).
    private func abilityRow(_ ability: Ability) -> some View {
        let level = wallet.level(ability)
        let next = wallet.nextPrice(ability)
        let key = "ability:\(ability.rawValue)"
        let asking = state.confirming == key
        return HStack(spacing: 8) {
            Image(systemName: ability.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(level > 0 ? Theme.accent : Theme.tertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(ability.name).font(.system(size: 11.5, weight: .semibold))
                    HStack(spacing: 2) {
                        ForEach(0..<ability.maxLevel, id: \.self) { i in
                            Circle().fill(i < level ? Self.gold : Color.white.opacity(0.15)).frame(width: 5, height: 5)
                        }
                    }
                }
                Text(ability.detail(level: max(level, 1))).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if level > 0 {
                Toggle("", isOn: Binding(get: { wallet.isOn(ability) }, set: { _ in wallet.toggle(ability) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("이번 판에 쓸지")
                    .accessibilityLabel("\(ability.name) 쓰기")
            }
            if let next {
                let affordable = wallet.coins >= next
                Button {
                    if asking {
                        state.confirming = nil
                        buying { wallet.upgrade(ability) }
                    } else if affordable {
                        state.confirming = key
                    }
                } label: {
                    Text(asking ? "\(next)에 사기?" : level == 0 ? "\(next)" : "+1단계 \(next)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(asking ? Theme.warning.opacity(0.25) : Color.white.opacity(0.08)))
                        .foregroundStyle(asking ? Theme.warning : affordable ? Self.gold : Theme.tertiary)
                }
                .buttonStyle(.plain)
                .help(affordable ? "두 번 누르면 삽니다" : "코인 \(next - wallet.coins)개가 더 필요해요")
            } else {
                Text("최대").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.positive)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// 상점 갈래, 사기 직전인 물건, 행운 상자 열기. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class ShopState: ObservableObject {
    @Published var tab: GameShopView.Tab
    @Published var confirming: String?
    let reveal = BoxReveal()

    init(tab: GameShopView.Tab) { self.tab = tab }
}

// MARK: - 등급

/// 등급 이름표: "영웅 · 동료".
struct RarityTag: View {
    let rarity: Rarity
    var slot: Cosmetic.Slot?

    var body: some View {
        Text(slot.map { "\(rarity.title) · \($0.title)" } ?? rarity.title)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(Color(nsColor: rarity.color))
    }
}

/// 칸 테두리. 등급 색으로 두르고, 전설은 금빛이 테두리를 따라 돈다.
struct RarityBorder: View {
    let rarity: Rarity?
    var highlight: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if let highlight {
            shape.strokeBorder(highlight.opacity(0.75), lineWidth: 1)
        } else if rarity == .legendary {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360)
                let gold = Color(nsColor: Rarity.legendary.color)
                shape.strokeBorder(AngularGradient(colors: [gold.opacity(0.3), .white, gold, gold.opacity(0.3), gold.opacity(0.3)],
                                                   center: .center, angle: angle), lineWidth: 1.4)
            }
        } else if let rarity, rarity >= .rare {
            shape.strokeBorder(Color(nsColor: rarity.color).opacity(rarity == .epic ? 0.7 : 0.5), lineWidth: 1)
        } else {
            shape.strokeBorder(Theme.hairline)
        }
    }
}

/// Fluent Emoji 그림 하나 (SwiftUI용).
struct FluentImage: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        if let image = GameFX.image(name, folder: "Fluent") {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

// MARK: - 행운 상자

/// 상자를 연 결과와 연 때. 무대처럼 시간으로 흔들림·터짐·나타남을 그린다.
final class BoxReveal: ObservableObject {
    @Published var result: GameWallet.BoxResult?
    @Published var openedAt: Date?

    func open(_ result: GameWallet.BoxResult) {
        self.result = result
        openedAt = Date()
    }

    func close() {
        result = nil
        openedAt = nil
    }
}

private struct LuckyBoxCard: View {
    @ObservedObject var wallet: GameWallet
    @ObservedObject var reveal: BoxReveal
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            if let result = reveal.result, let openedAt = reveal.openedAt {
                RevealView(result: result, openedAt: openedAt, character: settings.character) {
                    if case .item(let item) = result, !wallet.equipped.contains(item) { wallet.choose(item) }
                    reveal.close()
                } close: {
                    reveal.close()
                }
            } else {
                closedBox
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: reveal.result)
    }

    private var closedBox: some View {
        let free = wallet.freeBoxes
        return HStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle().fill(RadialGradient(colors: [Color(nsColor: Rarity.epic.color).opacity(0.55), .clear],
                                                 center: .center, startRadius: 2, endRadius: 30))
                    FluentImage(name: "gift", size: 40)
                        .rotationEffect(.degrees(sin(t * 2.2) * 5))
                        .offset(y: CGFloat(sin(t * 3)) * 1.5)
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("행운 상자").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.primary)
                Text("없는 꾸미기 하나가 나와요").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                HStack(spacing: 5) {
                    ForEach(Rarity.allCases, id: \.self) { rarity in
                        Text("\(rarity.title) \(rarity.weight)%").font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color(nsColor: rarity.color))
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 4)
            Button(action: open) {
                VStack(spacing: 1) {
                    Text(free > 0 ? "공짜로 열기" : "열기").font(.system(size: 11, weight: .bold))
                    if free > 0 {
                        Text("\(free)개 남음").font(.system(size: 9, weight: .semibold))
                    } else {
                        HStack(spacing: 2) {
                            Image(systemName: "dollarsign.circle.fill")
                            Text("\(GameWallet.boxPrice)")
                        }
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    }
                }
                .foregroundStyle(wallet.canOpenBox ? Color.black.opacity(0.82) : Theme.tertiary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(wallet.canOpenBox ? AnyShapeStyle(LinearGradient(
                    colors: [Color(nsColor: NSColor(hex: 0xFFE38A)), Color(nsColor: NSColor(hex: 0xFFB648))],
                    startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(0.08))))
            }
            .buttonStyle(.plain)
            .disabled(!wallet.canOpenBox)
            .help(wallet.canOpenBox ? "아직 없는 꾸미기가 나옵니다"
                  : wallet.hasUncollected ? "코인 \(GameWallet.boxPrice - wallet.coins)개가 더 필요해요" : "모두 모았어요")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LinearGradient(
            colors: [Color(nsColor: NSColor(hex: 0x2B2350)), Color(nsColor: NSColor(hex: 0x1D2440))],
            startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Color(nsColor: Rarity.epic.color).opacity(0.45)))
    }

    private func open() {
        guard let result = wallet.openBox() else { return }
        GameSound.shared.play(.purchase)
        reveal.open(result)
        // 상자가 흔들린 뒤 터지는 때에 맞춰 등급 소리
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            if case .item(let item) = result {
                GameSound.shared.play(item.rarity >= .epic ? .fanfare : .record)
            } else {
                GameSound.shared.play(.coin)
            }
        }
    }
}

/// 상자가 흔들리다 터지고, 등급 빛 속에서 물건이 나온다.
private struct RevealView: View {
    let result: GameWallet.BoxResult
    let openedAt: Date
    let character: RunnerCharacter
    let equip: () -> Void
    let close: () -> Void

    private static let shake = 0.75

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let age = context.date.timeIntervalSince(openedAt)
            ZStack {
                if age < Self.shake {
                    // 점점 세게 흔들린다
                    let k = age / Self.shake
                    FluentImage(name: "gift", size: 54)
                        .rotationEffect(.degrees(sin(age * 48) * 14 * k))
                        .scaleEffect(1 + 0.12 * k)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    revealed(age: age - Self.shake)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(nsColor: NSColor(hex: 0x1A1D33))))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(glow.opacity(0.7), lineWidth: 1.2))
    }

    private var glow: Color {
        if case .item(let item) = result { return Color(nsColor: item.rarity.color) }
        return GameShopView.gold
    }

    @ViewBuilder
    private func revealed(age: Double) -> some View {
        let pop = min(1, age / 0.25)
        VStack(spacing: 6) {
            ZStack {
                // 등급 빛이 돌며 퍼진다
                Circle().fill(RadialGradient(colors: [glow.opacity(0.8), glow.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: 70))
                    .scaleEffect(0.6 + 0.6 * pop)
                    .opacity(1 - min(1, age / 2.5) * 0.5)
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(glow.opacity(0.5))
                        .frame(width: 2, height: 22)
                        .offset(y: -46)
                        .rotationEffect(.degrees(Double(i) * 30 + age * 25))
                        .opacity(pop * 0.8)
                }
                switch result {
                case .item(let item):
                    ItemPreview(kind: .cosmetic(item), character: character)
                        .frame(width: 150, height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .scaleEffect(0.3 + 0.7 * pop)
                case .refund(let coins):
                    VStack(spacing: 2) {
                        FluentImage(name: "moneybag", size: 44)
                        Text("+\(coins)").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(GameShopView.gold)
                    }
                    .scaleEffect(0.3 + 0.7 * pop)
                }
            }
            .frame(height: 96)
            switch result {
            case .item(let item):
                RarityTag(rarity: item.rarity, slot: item.slot)
                Text(item.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.primary)
                HStack(spacing: 8) {
                    Button("닫기", action: close).controlSize(.small)
                    Button("바로 쓰기", action: equip)
                        .controlSize(.small).keyboardShortcut(.defaultAction)
                }
            case .refund:
                Text("모두 모았어요! 코인으로 돌려받았습니다").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Button("닫기", action: close).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(pop)
    }
}

// MARK: - 미리보기

/// 상점 칸 위의 작은 무대. 게임과 같은 그림 함수로 그 물건이 게임에서 보일 모습을 계속 돌려 보여 준다.
struct ItemPreview: View {
    enum Kind {
        case cosmetic(Cosmetic)
    }

    let kind: Kind
    let character: RunnerCharacter

    var body: some View {
        // 칸이 여럿이라 1초 20장으로 그린다
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
                canvas.withCGContext { cg in draw(cg, size: size, time: time) }
            }
        }
        .accessibilityHidden(true)
    }

    func draw(_ cg: CGContext, size: CGSize, time: Double) {
        let ground = size.height - 9
        // 밤하늘 바탕과 땅. 희귀 이상은 등급 빛을 바닥에 은은하게 깐다
        let colors = [NSColor(hex: 0x1B2140).cgColor, NSColor(hex: 0x33406E).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: ground), options: [.drawsAfterEndLocation])
        }
        if case .cosmetic(let item) = kind, item.rarity >= .rare {
            let glow = [item.rarity.color.withAlphaComponent(item.rarity == .legendary ? 0.45 : 0.3).cgColor,
                        item.rarity.color.withAlphaComponent(0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glow, locations: [0, 1]) {
                let center = CGPoint(x: size.width / 2, y: ground)
                cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width * 0.5,
                                      options: [])
            }
        }
        for i in 0..<9 {
            let twinkle = 0.3 + 0.5 * abs(sin(time * 1.3 + Double(i)))
            cg.setFillColor(NSColor.white.withAlphaComponent(twinkle).cgColor)
            cg.fillEllipse(in: CGRect(x: RunnerStageHash.value(i, 41) * size.width, y: RunnerStageHash.value(i, 42) * (ground - 16) + 3,
                                      width: 1.4, height: 1.4))
        }
        cg.setFillColor(NSColor(hex: 0x1A1F3A).cgColor)
        cg.fill(CGRect(x: 0, y: ground, width: size.width, height: size.height - ground))
        cg.setFillColor(NSColor(hex: 0x6C7BC4).withAlphaComponent(0.8).cgColor)
        cg.fill(CGRect(x: 0, y: ground - 0.5, width: size.width, height: 1.5))
        // 땅 무늬가 흘러 달리는 느낌을 준다
        cg.setFillColor(NSColor(hex: 0x6C7BC4).withAlphaComponent(0.3).cgColor)
        let offset = CGFloat((time * 60).truncatingRemainder(dividingBy: 18))
        var x = -offset
        while x < size.width { cg.fill(CGRect(x: x, y: ground + 4, width: 7, height: 1.5)); x += 18 }

        let runnerX = size.width * 0.66
        switch kind {
        case .cosmetic(let item):
            switch item.slot {
            case .hat, .face:
                drawRunner(cg, centerX: size.width / 2, ground: ground, height: item.fit == .floating ? 44 : 54, theme: .auto,
                           time: time, activity: .walk, hat: item.slot == .hat ? item : nil,
                           face: item.slot == .face ? item : nil)
            case .back:
                drawRunner(cg, centerX: size.width / 2 + 6, ground: ground, height: item.fit == .tethered ? 36 : 48,
                           theme: .auto, time: time, activity: .walk, back: item)
            case .trail:
                let base = ground - 18
                let head = CGPoint(x: runnerX - 8, y: base)
                let points = (0..<22).map { i -> CGPoint in
                    let back = CGFloat(21 - i)
                    return CGPoint(x: head.x - back * 4.2, y: base + CGFloat(sin(time * 4 - Double(i) * 0.33)) * 5 * back / 21)
                }
                GameFX.drawTrail(item, points: points, time: time, cg)
                drawRunner(cg, centerX: runnerX, ground: ground, height: 40, theme: .auto, time: time)
            case .dust:
                // 0.18초마다 디딘 발밑에서 먼지가 인다. 게임에서는 작은 먼지라 칸에서는 키운다
                let feet = CGPoint(x: runnerX - 6, y: ground)
                let spray = GameFX.dust(item, landing: false)
                zoomed(cg, around: feet, by: item.art == nil ? 2 : 1.4) {
                    for k in 0..<4 {
                        let age = CGFloat((time + Double(k) * 0.18).truncatingRemainder(dividingBy: 0.72))
                        GameFX.drawSpray(spray, from: feet, age: age, time: time, cg)
                    }
                }
                drawRunner(cg, centerX: runnerX, ground: ground, height: 40, theme: .auto, time: time)
            case .crash:
                // 장애물에 부딪혀 1.6초마다 터진다
                let center = CGPoint(x: size.width / 2, y: ground - 18)
                if let spikes = GameSprite.spikes.frame(at: time) {
                    GameAssets.draw(spikes, in: CGRect(x: center.x - 18 + 14, y: ground - 36 + 4, width: 36, height: 36), cg)
                }
                drawRunner(cg, centerX: center.x - 18, ground: ground, height: 34, theme: .auto, time: time, activity: .sit)
                let age = CGFloat(time.truncatingRemainder(dividingBy: 1.6))
                zoomed(cg, around: center, by: 1.4) {
                    for part in GameFX.crash(item) {
                        GameFX.drawSpray(part.spray, from: CGPoint(x: center.x + part.offset.x * 0.6, y: center.y - part.offset.y * 0.6),
                                         age: age, time: time, cg)
                    }
                }
            }
        }
    }

    private func zoomed(_ cg: CGContext, around point: CGPoint, by scale: CGFloat, _ draw: () -> Void) {
        cg.saveGState()
        cg.translateBy(x: point.x, y: point.y)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -point.x, y: -point.y)
        draw()
        cg.restoreGState()
    }

    private func drawRunner(_ cg: CGContext, centerX: CGFloat, ground: CGFloat, height: CGFloat, theme: SpriteTheme,
                            time: Double, activity: CharacterPose.Activity = .run, hat: Cosmetic? = nil, face: Cosmetic? = nil,
                            back: Cosmetic? = nil) {
        let cycle: Double = activity == .walk ? 1.25 : 0.72
        let phase = CGFloat(time.truncatingRemainder(dividingBy: cycle * 100) / cycle)
        let scene = CharacterScene(rig: character.rig, pose: CharacterPose(activity: activity, phase: phase))
        let scale = height / Stage.size.height
        cg.saveGState()
        // 캐릭터 무대의 바닥 줄을 땅에 맞춘다
        cg.translateBy(x: centerX - Stage.size.width * scale / 2, y: ground - Stage.ground * scale)
        cg.scaleBy(x: scale, y: scale)
        let rich = character.theme(theme)
        let look = CharacterLook(rich: true, palette: rich.richPalette(character.rig.palette, phase: CGFloat(time / 6)),
                                 tint: .white, outline: max(0.32, 1.1 / scale))
        GameFX.drawBack(back, on: scene, time: time, front: false, cg)
        scene.draw(in: cg, look: look)
        GameFX.drawAccessories(hat: hat, face: face, on: scene, time: time, cg)
        GameFX.drawBack(back, on: scene, time: time, front: true, cg)
        cg.restoreGState()
    }
}

// MARK: - 동료

/// 동료 고르기. 받아 둔 Petdex 펫 가운데 하나를 공짜로 데려가고, 다시 누르면 혼자 달린다.
private struct CompanionPicker: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var wallet = GameWallet.shared
    @ObservedObject private var petdex = PetdexStore.shared
    @StateObject private var hover = HoveredRunner()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(petdex.pets) { pet in
                if let character = petdex.character(for: pet) {
                    let id = PetdexStore.storageID(pet.slug)
                    let on = wallet.companionID == id
                    Button { wallet.companionID = on ? nil : id } label: {
                        tile(character, name: pet.name, on: on, live: on || hover.key == id)
                    }
                    .buttonStyle(.plain)
                    .onHover { hover.update(id, $0) }
                    .help(on ? "다시 누르면 혼자 달립니다" : "\(pet.name)을(를) 동료로 데려가기")
                    .accessibilityLabel(pet.name)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Button { PetdexWindow.shared.show(settings: settings, purpose: .companion) } label: {
                VStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15)).frame(height: 54)
                    Text("Petdex에서 찾기").font(.system(size: 10.5)).lineLimit(1)
                }
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("petdex.dev에서 펫을 받아 바로 동료로 데려가기")
        }
    }

    private func tile(_ character: RunnerCharacter, name: String, on: Bool, live: Bool) -> some View {
        VStack(spacing: 4) {
            Group {
                if live {
                    TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                        CharacterCanvas(character: character, theme: .auto, date: context.date, activity: .run)
                    }
                } else {
                    CharacterCanvas(character: character, theme: .auto, date: nil, activity: .stand)
                }
            }
            .frame(height: 54)
            HStack(spacing: 3) {
                Text(name).font(.system(size: 10.5, weight: on ? .semibold : .regular)).lineLimit(1)
                if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
            }
            .foregroundStyle(on ? Theme.primary : Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(on ? Theme.accent.opacity(0.16) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(on ? Theme.accent.opacity(0.75) : Theme.hairline))
        .contentShape(Rectangle())
    }
}
