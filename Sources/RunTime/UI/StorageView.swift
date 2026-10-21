import SwiftUI

/// 창고: 산 물건을 갈래별로 모아 두고 바로 쓰거나 뗀다. 상점은 사는 곳, 창고는 고르는 곳이다.
struct StorageView: View {
    @ObservedObject var settings: AppSettings
    var openShop: () -> Void = {}
    @ObservedObject private var wallet = GameWallet.shared
    @StateObject private var hover = HoveredRunner()

    var body: some View {
        let groups = Cosmetic.Slot.allCases.compactMap { slot -> (slot: Cosmetic.Slot, items: [Cosmetic])? in
            let items = Cosmetic.allCases.filter { $0.slot == slot && wallet.owned.contains($0) }
                .sorted { ($0.rarity.rawValue, $0.price) < ($1.rarity.rawValue, $1.price) }
            return items.isEmpty ? nil : (slot, items)
        }
        let abilities = Ability.allCases.filter { wallet.level($0) > 0 }
        VStack(alignment: .leading, spacing: 12) {
            if groups.isEmpty && abilities.isEmpty {
                emptyState
            } else {
                if !abilities.isEmpty {
                    group("능력", trailing: "\(abilities.filter(wallet.isOn).count)개 켜짐") {
                        ForEach(abilities) { ability in
                            abilityRow(ability)
                            if ability != abilities.last { Hairline().padding(.leading, 50) }
                        }
                    }
                }
                ForEach(groups, id: \.slot) { group in
                    let using = group.items.first { wallet.equipped.contains($0) }
                    VStack(alignment: .leading, spacing: 6) {
                        GameSectionHeader(title: group.slot.title, count: "\(group.items.count)",
                                          note: using.map { "\($0.name) 쓰는 중" } ?? "쓰지 않음")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                            ForEach(group.items) { itemCard($0) }
                        }
                    }
                }
                Text("갈래마다 하나씩 씁니다. 다른 것을 고르면 쓰던 것은 내려가고, 쓰는 것을 다시 누르면 뗍니다.")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { wallet.tryingOn = nil }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.white.opacity(0.05)))
            VStack(spacing: 4) {
                Text("창고가 비어 있어요").font(.system(size: 13.5, weight: .bold)).foregroundStyle(Theme.primary)
                Text("상점에서 산 트랙, 날씨, 꼬리와 능력이 여기에 모입니다.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: openShop) {
                HStack(spacing: 4) {
                    Image(systemName: "bag.fill").font(.system(size: 10, weight: .bold))
                    Text("상점 가기")
                }
            }
            .buttonStyle(GameButtonStyle(kind: .gold, height: 26))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    /// 바깥에 갈래 이름, 안에 줄을 둔다.
    private func group<Content: View>(_ title: String, trailing: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GameSectionHeader(title: title, note: trailing)
            VStack(spacing: 0) { content() }
                .rarityFrame(nil, radius: 10)
        }
    }

    /// 물건 칸: 상점과 같이 게임에서 보일 모습을 위에 돌리고, 누르면 쓰거나 뗀다.
    /// 움직임은 쓰는 것과 마우스를 올린 것만 돌려 칸이 많아도 가볍게 둔다.
    private func itemCard(_ item: Cosmetic) -> some View {
        let on = wallet.equipped.contains(item)
        let live = on || hover.key == item.rawValue
        return Button {
            wallet.tryingOn = nil
            wallet.choose(item)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if live {
                        ItemPreview(kind: .cosmetic(item), character: settings.character)
                    } else {
                        ItemPreview.Still(kind: .cosmetic(item), character: settings.character)
                    }
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.4)))
                .overlay(alignment: .topLeading) {
                    if item.rarity >= .rare { RarityRibbon(rarity: item.rarity).padding(4) }
                }
                .overlay(alignment: .topTrailing) {
                    if on { EquippedBadge().padding(4) }
                }
                HStack(spacing: 4) {
                    Text(item.name).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(on ? "빼기" : "쓰기")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(on ? Theme.secondary : Theme.accent)
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 1)
            }
            .padding(5)
            .rarityFrame(item.rarity, highlight: on ? Theme.accent : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover.update(item.rawValue, inside)
            guard item.slot == .track || item.slot == .weather else { return }
            wallet.tryingOn = inside ? item : nil
        }
        .tip(on ? "다시 누르면 뗍니다" : "\(item.name) 쓰기")
        .accessibilityLabel("\(item.name), \(item.rarity.title), \(on ? "쓰는 중" : "쓰지 않음")")
    }

    private func abilityRow(_ ability: Ability) -> some View {
        let level = wallet.level(ability)
        return HStack(spacing: 10) {
            AbilityIcon(ability: ability, active: wallet.isOn(ability))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ability.name).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
                    LevelPips(level: level, max: ability.maxLevel)
                }
                Text(ability.detail(level: level)).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { wallet.isOn(ability) }, set: { _ in wallet.toggle(ability) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("\(ability.name) 쓰기")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}
