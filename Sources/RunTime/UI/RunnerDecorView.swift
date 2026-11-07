import SwiftUI
import GameCore

/// 러너 화면의 꾸미기 갈래: 배경, 꼬리, 발먼지, 부딪힘. 고르면 무대에 바로 보인다.
struct RunnerDecorView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var decor = GameDecor.shared
    @StateObject private var hover = HoveredRunner()
    @StateObject private var filter = SceneFilter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kindTabs
            switch filter.kind {
            case .track:
                sceneChips
                grid(filter.items, minimum: 170, previewHeight: 84)
            case let slot:
                grid(Cosmetic.allCases.filter { $0.slot == slot }, minimum: 130, previewHeight: 58)
            }
            hint(filter.kind == .track ? "마우스를 올리면 무대에서 미리 봐요. 고른 배경을 다시 누르면 기본 배경으로 돌아가요."
                 : "고른 것을 다시 누르면 떼요. 달릴 때와 게임에서 보여요.")
        }
        // 써 보던 중에 닫혀도 무대와 게임이 원래 배경으로 돌아가게 한다
        .onDisappear { decor.tryingOn = nil }
    }

    /// 꾸밀 곳 고르기. 지금 쓰는 것의 이름도 함께 보인다.
    private var kindTabs: some View {
        HStack(spacing: 8) {
            ForEach([Cosmetic.Slot.track, .trail, .dust, .crash], id: \.self) { slot in
                let on = filter.kind == slot
                Button { filter.kind = slot } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slot == .track ? "배경" : slot.title).font(.system(size: 13, weight: .bold))
                            .foregroundStyle(on ? Theme.primary : Theme.secondary)
                        Text(decor.equipped(slot)?.name ?? (slot == .track ? "구름 숲" : "없음")).font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(on ? 0.13 : 0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    /// 배경 갈래. 59개를 한 줄로 내리지 않고 숲·바다·도시처럼 묶어 고른다.
    private var sceneChips: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(SceneFilter.groups.enumerated()), id: \.offset) { index, group in
                let on = filter.group == index
                Button { filter.group = index } label: {
                    Text(group.name)
                        .font(.system(size: 12, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? Theme.primary : Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(Capsule().fill(Color.white.opacity(on ? 0.16 : 0.05)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// 창이 넓어지면 칸 수가 늘어난다.
    private func grid(_ items: [Cosmetic], minimum: CGFloat, previewHeight: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 6)], spacing: 6) {
            ForEach(items) { itemCard($0, previewHeight: previewHeight) }
        }
    }

    /// 물건 칸: 게임에서 보일 모습을 위에 돌리고, 누르면 쓰거나 뗀다.
    /// 움직임은 쓰는 것과 마우스를 올린 것만 돌려 칸이 많아도 가볍게 둔다.
    private func itemCard(_ item: Cosmetic, previewHeight: CGFloat) -> some View {
        let on = decor.equipped.contains(item)
        let live = on || hover.key == item.rawValue
        return Button {
            decor.tryingOn = nil
            decor.choose(item)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if live {
                        ItemPreview(kind: .cosmetic(item), character: settings.character)
                    } else {
                        ItemPreview.Still(kind: .cosmetic(item), character: settings.character)
                    }
                }
                .frame(height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.4)))
                .overlay(alignment: .topTrailing) {
                    if on { EquippedBadge().padding(3) }
                }
                Text(item.name).font(.system(size: 12, weight: on ? .bold : .semibold))
                    .foregroundStyle(on ? Theme.primary : Theme.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
            }
            .padding(4)
            .slotFrame(highlight: on ? Theme.accent : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover.update(item.rawValue, inside)
            guard item.slot == .track else { return }
            decor.tryingOn = inside ? item : nil
        }
        .tip(on ? "다시 누르면 떼요" : "\(item.name) 쓰기")
        .accessibilityLabel("\(item.name), \(on ? "쓰는 중" : "쓰지 않음")")
    }

}

/// 게임 조작법. 키 모양으로 늘어놓고 좁으면 다음 줄로 넘긴다.
struct GameKeys: View {
    var body: some View {
        FlowLayout(spacing: 8) {
            // 고스트는 한 판을 끝내야 생긴다
            ForEach([("스페이스 · ↑", "점프 (길게 누르면 높이)"), ("↓", "숙이기"), ("← →", "이동")]
                    + (GameRecords.plays > 0 ? [("G", "고스트와 겨루기")] : []) + [("esc", "나가기")], id: \.0) { key, action in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
                    Text(action).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                .fixedSize()
                .padding(.trailing, 8)
            }
        }
    }
}

/// 능력 아이콘. 게임에서 그 능력이 보이는 도트 그림 (보호막은 하트, 글라이드는 구름 등).
struct AbilityIcon: View {
    let ability: Ability
    let active: Bool

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                GameFX.drawSprite(ability.sprite, at: CGPoint(size.width / 2, size.height / 2), height: size.height * 0.62,
                                  progress: 0.3, time: 0, alpha: active ? 1 : 0.4, cg)
            }
        }
        .frame(width: 30, height: 30)
        .background(Circle().fill(active ? Theme.accent.opacity(0.35) : Color.white.opacity(0.06)))
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
        if case .cosmetic(let item) = kind, item.slot == .track {
            // 트랙은 낮 하늘에서 보여야 풍경이 잘 보인다
            let sky = Sky.at(hour: 12, space: false)
            let t = CGFloat(time)
            Backdrop.draw(cg, size: size, sky: sky, time: t, groundY: ground, scroll: t * 40, speed: 40,
                          track: item)
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
            case .track:
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
                zoomed(cg, around: feet, by: 1.4) {
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

/// 배경 갈래 고르기. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class SceneFilter: ObservableObject {
    @Published var group = 0
    @Published var kind = Cosmetic.Slot.track

    /// Cosmetic에 적은 트랙 순서대로 갈래를 자른다.
    static let groups: [(name: String, items: [Cosmetic])] = {
        let tracks = Cosmetic.allCases.filter { $0.slot == .track }
        var rest = tracks[...]
        var result: [(name: String, items: [Cosmetic])] = [("전체", tracks)]
        for (name, count) in [("숲·눈", 12), ("언덕·마을", 10), ("사막", 6), ("바다", 8), ("하늘", 9), ("도시·밤", 9), ("동굴", 5)] {
            result.append((name, Array(rest.prefix(count))))
            rest = rest.dropFirst(count)
        }
        return result
    }()

    var items: [Cosmetic] { Self.groups[group].items }
}
