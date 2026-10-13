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

    static let gold = GameKit.gold

    enum Tab: String, CaseIterable {
        case ability = "능력", buddy = "동료", track = "트랙", weather = "날씨", trail = "꼬리", dust = "발먼지", crash = "부딪힘"

        var slots: [Cosmetic.Slot] {
            switch self {
            case .track: [.track]
            case .weather: [.weather]
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
            case .track: "flag.checkered"
            case .weather: "cloud.sun.fill"
            case .trail: "wind"
            case .dust: "shoeprints.fill"
            case .crash: "burst.fill"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuckyBoxCard(wallet: wallet, reveal: state.reveal, settings: settings) {
                if let deal = wallet.dailyDeal { dealTile(deal) }
            }
            tabs
            switch state.tab {
            case .ability:
                VStack(spacing: 6) { ForEach(Ability.allCases) { abilityRow($0) } }
            case .buddy:
                CompanionPicker(settings: settings)
            default:
                ForEach(state.tab.slots, id: \.self) { slot in
                    slotHeader(slot)
                    grid(Cosmetic.allCases.filter { $0.slot == slot }
                        .sorted { ($0.rarity.rawValue, $0.price) < ($1.rarity.rawValue, $1.price) }.map(ShopItem.cosmetic))
                }
            }
            Text(footnote).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: state.tab) { _ in state.confirming = nil }
        // 입어 보던 중에 닫혀도 무대와 게임이 원래 꾸미기로 돌아가게 한다
        .onDisappear { wallet.tryingOn = nil }
    }

    // MARK: 머리 부분

    /// 갈래 이름과 그 갈래에서 모은 수.
    private func slotHeader(_ slot: Cosmetic.Slot) -> some View {
        let items = Cosmetic.allCases.filter { $0.slot == slot }
        let owned = items.filter { wallet.owned.contains($0) }.count
        return HStack {
            Text(slot.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            Spacer()
            Text("\(owned)/\(items.count) 모음").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 2)
        .help("도감 \(wallet.collection.owned)/\(wallet.collection.total)")
    }

    /// 오늘의 특가 타일. 행운 상자 옆에 같은 크기로 두고, 물건이 게임에서 보일 모습을 위에 돌린다.
    private func dealTile(_ item: Cosmetic) -> some View {
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
            VStack(alignment: .leading, spacing: 5) {
                ItemPreview(kind: .cosmetic(item), character: settings.character)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text("특가 -\(Int(GameWallet.dealDiscount * 100))%")
                            .font(.system(size: 9, weight: .heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(height: 14)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.critical))
                            .padding(4)
                    }
                    .overlay(alignment: .topTrailing) {
                        if item.rarity >= .rare { RarityRibbon(rarity: item.rarity).padding(4) }
                    }
                HStack(spacing: 4) {
                    Text(item.name).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(QuestView.untilTomorrow().replacingOccurrences(of: " 뒤 바뀜", with: " 남음"))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.tertiary)
                        .help("내일 다른 물건으로 바뀝니다")
                }
                HStack(spacing: 5) {
                    if asking {
                        Text("한 번 더 누르면 구매").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.warning)
                    } else {
                        Text(item.price.formatted()).strikethrough()
                            .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Theme.tertiary)
                        Image(systemName: "arrow.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.tertiary)
                        CoinAmount(amount: price, size: 11, affordable: affordable)
                    }
                }
                .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .rarityFrame(item.rarity, highlight: asking ? Theme.warning : nil, radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { tryOn(item, $0) }
        .help(affordable ? "\(item.rarity.title) \(item.slot.title). 두 번 누르면 삽니다. 내일 다른 물건으로 바뀝니다"
              : "코인 \(price - wallet.coins)개가 더 필요해요")
        .accessibilityLabel("오늘의 특가 \(item.name), \(price)코인")
    }

    /// 트랙·날씨에 마우스를 올리면 위 무대가 그 풍경으로 바뀐다.
    private func tryOn(_ item: Cosmetic, _ inside: Bool) {
        guard item.slot == .track || item.slot == .weather else { return }
        wallet.tryingOn = inside ? item : nil
    }

    /// 갈래 고르기. 일곱 개라 아이콘과 짧은 이름을 두 줄로 두고, 고른 칸은 금빛 바닥줄로 표시한다.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let on = state.tab == tab
                Button { state.tab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 13, weight: .semibold))
                            .frame(height: 15)
                        Text(tab.rawValue).font(.system(size: 10, weight: on ? .bold : .medium))
                    }
                    .foregroundStyle(on ? GameKit.gold : Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(on ? 0.07 : 0)))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(GameKit.gold).frame(width: 18, height: 2).opacity(on ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(GameKit.slot))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .animation(.easeOut(duration: 0.15), value: state.tab)
    }

    private var footnote: String {
        switch state.tab {
        case .ability: "능력은 미니게임에서만 쓰고 다음 판부터 적용됩니다. 순위 점수 계산은 같습니다."
        case .buddy: "받아 둔 Petdex 펫을 공짜로 데려갑니다. 게임과 사용량 창 무대에서 러너 뒤를 따라 달리고, 판정과 점수는 같습니다."
        case .track: "마우스를 올리면 위 무대가 그 트랙으로 바뀝니다. 하늘은 지금 시각을 따르고, 미니게임에서도 같은 곳을 달립니다."
        case .weather: "마우스를 올리면 위 무대에 날씨가 보입니다. 러너 뒤로 지나가서 게임 장애물을 가리지 않습니다."
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
        // 사거나 떼는 순간 칸이 사라지거나 바뀌어 마우스가 떠났다는 신호가 오지 않을 수 있다
        wallet.tryingOn = nil
        let before = wallet.coins
        action()
        if wallet.coins < before { GameSound.shared.play(.purchase) }
    }

    private func cosmeticItem(_ cosmetic: Cosmetic) -> some View {
        let owned = wallet.owned.contains(cosmetic)
        let label = switch cosmetic.slot {
        case .track: "고르기"
        case .weather: "켜기"
        default: "달기"
        }
        return card(key: cosmetic.rawValue, name: cosmetic.name, price: wallet.price(of: cosmetic), rarity: cosmetic.rarity,
                    owned: owned, on: wallet.equipped.contains(cosmetic), ownedLabel: label) {
            ItemPreview(kind: .cosmetic(cosmetic), character: settings.character)
        } action: {
            wallet.choose(cosmetic)
        }
        .onHover { tryOn(cosmetic, $0) }
    }

    /// 공통 칸. 안 산 것은 처음 누르면 "한 번 더 누르면 구매"로 바뀌고, 한 번 더 누르면 산다
    /// (팝오버에서 확인 창을 띄우면 팝오버가 닫혀서).
    private func card<Preview: View>(key: String, name: String, price: Int, rarity: Rarity?, owned: Bool, on: Bool,
                                     ownedLabel: String, @ViewBuilder preview: () -> Preview,
                                     action: @escaping () -> Void) -> some View {
        let affordable = owned || wallet.coins >= price
        let asking = state.confirming == key
        let status = on ? "쓰는 중" : owned ? ownedLabel : asking ? "\(price)에 사기?" : "\(price)코인"
        return Button {
            if owned || asking {
                state.confirming = nil
                buying(action)
            } else if affordable {
                state.confirming = key
            }
        } label: {
            VStack(spacing: 6) {
                preview()
                    .frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.4)))
                    .overlay(alignment: .topLeading) {
                        if let rarity, rarity >= .rare { RarityRibbon(rarity: rarity).padding(4) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if on { EquippedBadge().padding(4) }
                    }
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 2)
                    Group {
                        if on {
                            Text("쓰는 중").foregroundStyle(Theme.accent)
                        } else if owned {
                            Text(ownedLabel).foregroundStyle(Theme.secondary)
                        } else if asking {
                            Text("한 번 더").foregroundStyle(Theme.warning)
                        } else {
                            CoinAmount(amount: price, size: 10.5, affordable: affordable)
                        }
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .lineLimit(1)
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 1)
            }
            .padding(5)
            .rarityFrame(rarity, highlight: on ? Theme.accent : asking ? Theme.warning : nil)
            .opacity(owned || affordable ? 1 : 0.82)
            .contentShape(Rectangle())
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
        return HStack(spacing: 10) {
            AbilityIcon(ability: ability, active: level > 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ability.name).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
                    LevelPips(level: level, max: ability.maxLevel)
                }
                Text(ability.detail(level: max(level, 1))).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
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
                    if asking {
                        Text("사기?")
                    } else {
                        HStack(spacing: 3) {
                            if level > 0 { Image(systemName: "arrow.up").font(.system(size: 8, weight: .black)) }
                            CoinIcon(size: 12, dimmed: !affordable)
                            Text(next.formatted())
                        }
                    }
                }
                .buttonStyle(GameButtonStyle(kind: asking ? .warning : .gold, height: 22))
                .disabled(!affordable && !asking)
                .help(affordable ? (level == 0 ? "두 번 누르면 삽니다" : "다음 단계. 두 번 누르면 삽니다")
                      : "코인 \(next - wallet.coins)개가 더 필요해요")
                .accessibilityLabel(level == 0 ? "\(ability.name) 사기, \(next)코인" : "\(ability.name) 올리기, \(next)코인")
            } else {
                Text("MAX").font(GameFont.pixel(12)).foregroundStyle(GameKit.gold)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .rarityFrame(nil, highlight: asking ? Theme.warning : nil)
    }
}

/// 능력 아이콘. 산 능력은 파란 원, 안 산 능력은 옅은 원.
struct AbilityIcon: View {
    let ability: Ability
    let active: Bool

    var body: some View {
        Image(systemName: ability.icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(active ? .white : Theme.tertiary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(active ? Theme.accent : Color.white.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

/// 능력 단계. 채운 단계는 금빛 마름모.
struct LevelPips: View {
    let level: Int
    let max: Int

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<max, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? GameKit.gold : Color.white.opacity(0.14))
                    .frame(width: 5, height: 5)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("\(level)/\(max)단계")
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

/// 칸 테두리. 희귀 이상만 등급 색을 옅게 두른다.
struct RarityBorder: View {
    let rarity: Rarity?
    var highlight: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if let highlight {
            shape.strokeBorder(highlight.opacity(0.75), lineWidth: 1)
        } else if let rarity, rarity >= .rare {
            shape.strokeBorder(Color(nsColor: rarity.color).opacity(rarity == .legendary ? 0.6 : 0.35), lineWidth: 1)
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

/// 물건 그림. 트랙은 하늘·풍경·땅 색 띠로, 날씨는 그 기호로, 나머지는 Fluent 그림이나 갈래 아이콘으로 그린다.
struct ItemGlyph: View {
    let item: Cosmetic
    var size: CGFloat = 30

    var body: some View {
        if let track = Backdrop.track(item) {
            VStack(spacing: 0) {
                Color(nsColor: NSColor(hex: 0x8FB4D8))
                Color(nsColor: track.far)
                Color(nsColor: track.ground)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else if let art = item.art {
            FluentImage(name: art, size: size)
        } else if let symbol = item.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(Color(nsColor: item.color))
                .frame(width: size, height: size)
        } else {
            let color = Color(nsColor: item.color)
            ZStack {
                Circle().fill(color.opacity(0.16))
                Image(systemName: GameShopView.Tab.allCases.first { $0.slots.contains(item.slot) }?.icon ?? "sparkle")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
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

/// 행운 상자 타일과 그 옆 특가 타일. 상자를 열면 그 자리에 여는 장면을 넓게 띄운다.
private struct LuckyBoxCard<Deal: View>: View {
    @ObservedObject var wallet: GameWallet
    @ObservedObject var reveal: BoxReveal
    @ObservedObject var settings: AppSettings
    @ViewBuilder var deal: () -> Deal

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
                HStack(spacing: 8) {
                    closedBox
                    deal()
                }
                .frame(height: 116)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: reveal.result)
    }

    private var closedBox: some View {
        let free = wallet.freeBoxes
        let odds = Rarity.allCases.map { "\($0.title) \($0.weight)%" }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 5) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                // 열 수 있을 때만 가끔 들썩이고 둘레에 작은 별이 번갈아 반짝인다
                let nudge = wallet.canOpenBox ? max(0, sin(t * 1.6)) : 0
                Canvas { canvas, size in
                    guard wallet.canOpenBox else { return }
                    canvas.withCGContext { cg in
                        let spots: [(CGFloat, CGFloat, Double)] = [(0.3, 0.3, 0), (0.7, 0.25, 0.9), (0.66, 0.72, 1.7), (0.34, 0.7, 2.4)]
                        for (x, y, offset) in spots {
                            let k = max(0, sin(t * 2.4 + offset))
                            SpriteEffects.sparkle(cg, at: CGPoint(x: size.width * x, y: size.height * y), radius: 4 * k,
                                                  color: NSColor(hex: 0xFFE7A0).withAlphaComponent(0.9))
                        }
                    }
                }
                .background(Color(nsColor: NSColor(hex: 0x2A2216)))
                .overlay {
                    FluentImage(name: "gift", size: 36)
                        .rotationEffect(.degrees(sin(t * 14) * 6 * pow(nudge, 6)))
                        .offset(y: -2 * pow(nudge, 6))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if free > 0 {
                    Text("무료 \(free)")
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(height: 14)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.positive))
                        .padding(4)
                }
            }
            HStack(spacing: 4) {
                Text("행운 상자").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
                Spacer(minLength: 2)
                OddsBar().frame(width: 46)
            }
            Button(action: open) {
                if free > 0 {
                    Text("무료로 열기")
                } else {
                    HStack(spacing: 3) {
                        Text("열기")
                        CoinIcon(size: 12, dimmed: !wallet.canOpenBox)
                        Text(GameWallet.boxPrice.formatted())
                    }
                }
            }
            .buttonStyle(GameButtonStyle(kind: .gold, height: 22, fill: true))
            .disabled(!wallet.canOpenBox)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .rarityFrame(nil, highlight: wallet.canOpenBox ? GameKit.gold : nil, radius: 10)
        .help(wallet.canOpenBox ? "아직 없는 꾸미기 하나. 등급 확률: \(odds)"
              : wallet.hasUncollected ? "코인 \(GameWallet.boxPrice - wallet.coins)개가 더 필요해요" : "모두 모았어요")
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

/// 등급 확률을 색 띠 하나로. 칸 너비가 확률에 비례한다.
private struct OddsBar: View {
    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(Rarity.allCases.reduce(0) { $0 + $1.weight })
            HStack(spacing: 1) {
                ForEach(Rarity.allCases, id: \.self) { rarity in
                    Rectangle().fill(rarity.swiftColor)
                        .frame(width: max(2, (geo.size.width - 3) * CGFloat(rarity.weight) / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityHidden(true)
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
        .rarityFrame(nil, highlight: glow, radius: 10)
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
                // 등급 색 원판이 톡 커지며 물건 뒤를 받친다
                Circle().fill(glow.opacity(0.14))
                    .frame(width: 96, height: 96)
                    .scaleEffect(0.6 + 0.4 * pop)
                // 열리는 순간 등급 색 고리가 한 번 퍼진다
                Circle().strokeBorder(glow.opacity(0.7 * (1 - min(1, age / 0.6))), lineWidth: 1.5)
                    .frame(width: 60 + 80 * min(1, age / 0.6), height: 60 + 80 * min(1, age / 0.6))
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
                    Button("닫기", action: close).buttonStyle(GameButtonStyle(kind: .plain, height: 24))
                    Button("바로 쓰기", action: equip).buttonStyle(GameButtonStyle(kind: .gold, height: 24))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            case .refund:
                Text("모두 모아서 코인으로 돌려받았습니다").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Button("닫기", action: close).buttonStyle(GameButtonStyle(kind: .plain, height: 24))
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

    /// 멈춘 한 장. 창고처럼 칸이 많은 곳에서 쓰지 않는 칸을 그린다.
    struct Still: View {
        let kind: Kind
        let character: RunnerCharacter

        var body: some View {
            Canvas { canvas, size in
                canvas.withCGContext { cg in ItemPreview(kind: kind, character: character).draw(cg, size: size, time: 0.35) }
            }
            .accessibilityHidden(true)
        }
    }

    func draw(_ cg: CGContext, size: CGSize, time: Double) {
        let ground = size.height - 9
        if case .cosmetic(let item) = kind, item.slot == .track || item.slot == .weather {
            // 트랙은 낮, 반딧불은 밤 하늘에서 보여야 풍경이 잘 보인다
            var sky = Sky.at(hour: item == .fireflyWeather ? 22 : 12, space: false)
            sky.clouds *= 0.12   // 작은 칸에서는 구름이 풍경을 가린다
            let t = CGFloat(time)
            Backdrop.draw(cg, size: size, sky: sky, time: t, groundY: ground, scroll: t * 40, speed: 40,
                          track: item.slot == .track ? item : nil, weather: item.slot == .weather ? item : nil)
            drawRunner(cg, centerX: size.width * 0.38, ground: ground, height: 34, theme: .auto, time: time)
            return
        }
        // 바탕은 칸과 같은 중립색으로 두고 땅 줄만 흐르게 해 달리는 느낌만 남긴다
        cg.setFillColor(NSColor(white: 1, alpha: 0.035).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        cg.setFillColor(NSColor(white: 1, alpha: 0.14).cgColor)
        cg.fill(CGRect(x: 0, y: ground - 0.5, width: size.width, height: 1))
        cg.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor)
        let offset = CGFloat((time * 60).truncatingRemainder(dividingBy: 18))
        var x = -offset
        while x < size.width { cg.fill(CGRect(x: x, y: ground + 4, width: 7, height: 1)); x += 18 }

        let runnerX = size.width * 0.66
        switch kind {
        case .cosmetic(let item):
            switch item.slot {
            case .track, .weather:
                break
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
                            time: Double, activity: CharacterPose.Activity = .run) {
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
        scene.draw(in: cg, look: look)
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
    @StateObject private var rename = RenameState()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(petdex.pets) { pet in
                if let character = petdex.character(for: pet) {
                    let id = PetdexStore.storageID(pet.slug)
                    let on = wallet.companionID == id
                    Group {
                        // 이름을 고치는 동안은 단추로 감싸지 않아야 입력 칸이 클릭을 받는다
                        if rename.id == id {
                            tile(character, name: pet.name, key: id, on: on, live: true)
                        } else {
                            Button { wallet.companionID = on ? nil : id } label: {
                                tile(character, name: pet.name, key: id, on: on, live: on || hover.key == id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onHover { hover.update(id, $0) }
                    .contextMenu {
                        Button("이름 바꾸기") { rename.start(id, name: pet.name) { petdex.rename(pet, to: $0) } }
                    }
                    .help(on ? "다시 누르면 혼자 달립니다. 오른쪽 클릭으로 이름 바꾸기"
                          : "\(pet.name)을(를) 동료로 데려가기. 오른쪽 클릭으로 이름 바꾸기")
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
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("petdex.dev에서 펫을 받아 바로 동료로 데려가기")
        }
    }

    private func tile(_ character: RunnerCharacter, name: String, key: String, on: Bool, live: Bool) -> some View {
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
            TileName(name: name, key: key, selected: on, rename: rename)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .overlay(alignment: .topTrailing) { if on { EquippedBadge().padding(4) } }
        .rarityFrame(nil, highlight: on ? Theme.accent : nil)
        .contentShape(Rectangle())
    }
}
