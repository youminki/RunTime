import SwiftUI

/// 창고: 산 물건을 갈래별로 모아 두고 바로 쓰거나 뗀다. 상점은 사는 곳, 창고는 고르는 곳이다.
struct StorageView: View {
    @ObservedObject var settings: AppSettings
    var openShop: () -> Void = {}
    @ObservedObject private var wallet = GameWallet.shared

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
                            if ability != abilities.last { Hairline().padding(.leading, 46) }
                        }
                    }
                }
                ForEach(groups, id: \.slot) { group in
                    let using = group.items.first { wallet.equipped.contains($0) }
                    self.group(group.slot.title, trailing: using.map { "\($0.name) 쓰는 중" } ?? "쓰지 않음") {
                        ForEach(group.items) { item in
                            itemRow(item)
                            if item != group.items.last { Hairline().padding(.leading, 46) }
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
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
            Text("아직 산 물건이 없어요").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
            Text("상점에서 산 트랙, 날씨, 꼬리와 능력이 여기에 모입니다.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("상점 보기", action: openShop).controlSize(.small).padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// 설정 화면처럼 바깥에 갈래 이름, 안에 줄을 둔다.
    private func group<Content: View>(_ title: String, trailing: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(trailing).font(Theme.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func itemRow(_ item: Cosmetic) -> some View {
        let on = wallet.equipped.contains(item)
        return Button {
            wallet.tryingOn = nil
            wallet.choose(item)
        } label: {
            HStack(spacing: 10) {
                ItemGlyph(item: item, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(Theme.primary)
                    Text(item.rarity.title).font(.system(size: 10)).foregroundStyle(Color(nsColor: item.rarity.color))
                }
                Spacer(minLength: 4)
                if on {
                    Label("쓰는 중", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                } else {
                    Text("쓰기").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            guard item.slot == .track || item.slot == .weather else { return }
            wallet.tryingOn = inside ? item : nil
        }
        .help(on ? "다시 누르면 뗍니다" : "\(item.name) 쓰기")
        .accessibilityLabel("\(item.name), \(on ? "쓰는 중" : "쓰지 않음")")
    }

    private func abilityRow(_ ability: Ability) -> some View {
        let level = wallet.level(ability)
        return HStack(spacing: 10) {
            Image(systemName: ability.icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(wallet.isOn(ability) ? Theme.accent : Theme.tertiary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(ability.name).font(.system(size: 12)).foregroundStyle(Theme.primary)
                Text("\(level)/\(ability.maxLevel)단계 · \(ability.detail(level: level))")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { wallet.isOn(ability) }, set: { _ in wallet.toggle(ability) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("\(ability.name) 쓰기")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}
