import SwiftUI
import GameCore

@MainActor
private final class DecorPage: ObservableObject {
    static let shared = DecorPage(tab: .track)

    @Published var tab: RunnerDecorView.Tab

    init(tab: RunnerDecorView.Tab) { self.tab = tab }
}

/// 꾸미기: 트랙·날씨·꼬리·발먼지·부딪힘과 능력, 동료를 조건 없이 고른다. 고르면 무대에 바로 보인다.
struct RunnerDecorView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var decor = GameDecor.shared
    /// 러너 탭에 다녀와도 고르던 갈래가 남게 하나를 함께 쓴다.
    @ObservedObject private var page: DecorPage
    @StateObject private var hover = HoveredRunner()

    init(settings: AppSettings, tab: Tab? = nil) {
        self.settings = settings
        page = tab.map(DecorPage.init) ?? .shared
    }

    enum Tab: String, CaseIterable {
        case track = "트랙", weather = "날씨", trail = "꼬리", dust = "발먼지", crash = "부딪힘", buddy = "동료", ability = "능력"

        var slot: Cosmetic.Slot? {
            switch self {
            case .track: .track
            case .weather: .weather
            case .trail: .trail
            case .dust: .dust
            case .crash: .crash
            default: nil
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
            tabs
            switch page.tab {
            case .ability:
                VStack(spacing: 0) {
                    ForEach(Ability.allCases) { ability in
                        abilityRow(ability)
                        if ability != Ability.allCases.last { Hairline().padding(.leading, 50) }
                    }
                }
                .slotFrame(radius: 10)
            case .buddy:
                CompanionPicker(settings: settings)
            default:
                if let slot = page.tab.slot {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(Cosmetic.allCases.filter { $0.slot == slot }) { itemCard($0) }
                    }
                }
            }
            Text(footnote).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 써 보던 중에 닫혀도 무대와 게임이 원래 꾸미기로 돌아가게 한다
        .onDisappear { decor.tryingOn = nil }
    }

    private var footnote: String {
        switch page.tab {
        case .ability: "다음 판부터 적용됩니다."
        case .buddy: "받아 둔 Petdex 펫이 게임과 무대에서 러너 뒤를 따라 달립니다."
        case .track, .weather: "마우스를 올리면 무대에서 미리 봅니다. 고른 것을 다시 누르면 뗍니다."
        default: "고른 것을 다시 누르면 뗍니다. 게임 화면에서 보입니다."
        }
    }

    /// 갈래 고르기. 일곱 개라 아이콘과 짧은 이름을 두 줄로 둔다.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let on = page.tab == tab
                Button { page.tab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 13, weight: .semibold))
                            .frame(height: 15)
                        Text(tab.rawValue).font(.system(size: 10, weight: on ? .bold : .medium))
                    }
                    .foregroundStyle(on ? Theme.primary : Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(on ? 0.1 : 0)))
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
        .animation(.easeOut(duration: 0.15), value: page.tab)
    }

    /// 물건 칸: 게임에서 보일 모습을 위에 돌리고, 누르면 쓰거나 뗀다.
    /// 움직임은 쓰는 것과 마우스를 올린 것만 돌려 칸이 많아도 가볍게 둔다.
    private func itemCard(_ item: Cosmetic) -> some View {
        let on = decor.equipped.contains(item)
        let live = on || hover.key == item.rawValue
        return Button {
            decor.tryingOn = nil
            decor.choose(item)
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
                .overlay(alignment: .topTrailing) {
                    if on { EquippedBadge().padding(4) }
                }
                Text(item.name).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.primary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
                    .padding(.bottom, 1)
            }
            .padding(5)
            .slotFrame(highlight: on ? Theme.accent : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover.update(item.rawValue, inside)
            guard item.slot == .track || item.slot == .weather else { return }
            decor.tryingOn = inside ? item : nil
        }
        .tip(on ? "다시 누르면 뗍니다" : "\(item.name) 쓰기")
        .accessibilityLabel("\(item.name), \(on ? "쓰는 중" : "쓰지 않음")")
    }

    private func abilityRow(_ ability: Ability) -> some View {
        HStack(spacing: 10) {
            AbilityIcon(ability: ability, active: decor.isOn(ability))
            VStack(alignment: .leading, spacing: 2) {
                Text(ability.name).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
                Text(ability.detail).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { decor.isOn(ability) }, set: { _ in decor.toggle(ability) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("\(ability.name) 쓰기")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
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

/// 꾸미기 칸 위의 작은 무대. 게임과 같은 그림 함수로 그 물건이 게임에서 보일 모습을 계속 돌려 보여 준다.
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

    /// 멈춘 한 장. 칸이 많아 쓰지 않는 칸은 이것으로 그린다.
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

/// 동료 고르기. 받아 둔 Petdex 펫 가운데 하나를 공짜로 데려가고, 다시 누르면 혼자 달린다.
private struct CompanionPicker: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var decor = GameDecor.shared
    @ObservedObject private var petdex = PetdexStore.shared
    @StateObject private var hover = HoveredRunner()
    @StateObject private var rename = RenameState()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(petdex.pets) { pet in
                if let character = petdex.character(for: pet) {
                    let id = PetdexStore.storageID(pet.slug)
                    let on = decor.companionID == id
                    Group {
                        // 이름을 고치는 동안은 단추로 감싸지 않아야 입력 칸이 클릭을 받는다
                        if rename.id == id {
                            tile(character, name: pet.name, key: id, on: on, live: true)
                        } else {
                            Button { decor.companionID = on ? nil : id } label: {
                                tile(character, name: pet.name, key: id, on: on, live: on || hover.key == id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onHover { hover.update(id, $0) }
                    .contextMenu {
                        Button("이름 바꾸기") { rename.start(id, name: pet.name) { petdex.rename(pet, to: $0) } }
                    }
                    .tip(on ? "다시 누르면 혼자 달립니다. 오른쪽 클릭으로 이름 바꾸기"
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
            .tip("petdex.dev에서 펫을 받아 바로 동료로 데려가기")
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
        .slotFrame(highlight: on ? Theme.accent : nil)
        .contentShape(Rectangle())
    }
}
