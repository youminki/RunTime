import SwiftUI
import GameCore

/// 상점·창고·퀘스트가 함께 쓰는 게임 화면 부품. 시스템 기호 대신 코인 그림을 쓰고,
/// 면은 평평한 색 하나로 칠한다. 번지는 빛과 그러데이션은 쓰지 않는다.
enum GameKit {
    static let gold = Color(nsColor: NSColor(hex: 0xFFD45E))
    static let goldEdge = Color(nsColor: NSColor(hex: 0x9A5B0C))
    static let ink = Color(nsColor: NSColor(hex: 0x3A2306))
    /// 칸 바탕. 카드보다 한 단계 짙게 두어 그림이 떠 보이게 한다.
    static let slot = Color(white: 0.105)
}

/// 코인 그림 하나.
struct CoinIcon: View {
    var size: CGFloat = 12
    var dimmed = false

    var body: some View {
        FluentImage(name: "coin", size: size)
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.55 : 1)
            .accessibilityHidden(true)
    }
}

/// 코인 그림과 수. 모자라면 회색으로 둔다.
struct CoinAmount: View {
    let amount: Int
    var size: CGFloat = 10.5
    var affordable = true

    var body: some View {
        HStack(spacing: 3) {
            CoinIcon(size: size + 2, dimmed: !affordable)
            Text(amount.formatted())
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(affordable ? GameKit.gold : Theme.tertiary)
        }
    }
}

/// 아래 모서리에 두께가 있는 단추. 금색은 사기·받기·열기처럼 코인이 오가는 일, 보통은 그 밖의 일에 쓴다.
struct GameButtonStyle: ButtonStyle {
    enum Kind { case gold, plain, warning }

    var kind: Kind = .gold
    var height: CGFloat = 24
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        GameButtonBody(configuration: configuration, kind: kind, height: height, fill: fill)
    }

    private struct GameButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let height: CGFloat
        let fill: Bool
        @Environment(\.isEnabled) private var enabled
        @StateObject private var hover = HoverFlag()

        var body: some View {
            let pressed = configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            let colors = palette
            configuration.label
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(colors.text)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: height)
                .background(shape.fill(colors.top).brightness(enabled && hover.on && !pressed ? 0.05 : 0))
                // 아래 모서리만 짙게 두어 두께를 보인다
                .background(shape.fill(colors.edge).offset(y: pressed ? 0 : 2))
                .offset(y: pressed ? 1.5 : 0)
                .contentShape(shape)
                .onHover { hover.on = $0 }
                .animation(.easeOut(duration: 0.08), value: pressed)
        }

        private var palette: (top: Color, bottom: Color, edge: Color, text: Color) {
            guard enabled else {
                return (Color(white: 0.22), Color(white: 0.22), Color(white: 0.13), Color.white.opacity(0.38))
            }
            switch kind {
            case .gold: return (GameKit.gold, GameKit.gold, GameKit.goldEdge, GameKit.ink)
            case .warning: return (Theme.warning, Theme.warning, Color(nsColor: NSColor(hex: 0x9A4A06)), GameKit.ink)
            case .plain: return (Color(white: 0.3), Color(white: 0.3), Color(white: 0.16), Theme.primary)
            }
        }
    }
}

extension View {
    /// 보통 단추와 같은 모습. 메뉴처럼 단추 꼴을 시스템이 정하는 곳의 이름표에 쓴다.
    func gameChip(height: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(shape.fill(Color(white: 0.3)))
            .background(shape.fill(Color(white: 0.16)).offset(y: 2))
            .contentShape(shape)
    }
}

extension Rarity {
    /// 테두리 위쪽에 쓰는 밝은 등급 색.
    var light: Color { Color(nsColor: color.blended(withFraction: 0.35, of: .white) ?? color) }
    var swiftColor: Color { Color(nsColor: color) }
}

/// 물건 칸 틀. 희귀 이상만 등급 색 테를 두르고, 고른 칸은 그 색으로 옅게 칠한다.
struct RarityFrame: ViewModifier {
    let rarity: Rarity?
    var highlight: Color?
    var radius: CGFloat = 9

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = highlight ?? rarity.flatMap { $0 >= .rare ? $0.swiftColor : nil }
        return content
            .background(shape.fill(highlight.map { $0.opacity(0.1) } ?? GameKit.slot))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(highlight != nil ? 0.9 : 0.55) } ?? Color.white.opacity(0.1),
                                        lineWidth: highlight != nil ? 1.5 : 1))
    }
}

extension View {
    func rarityFrame(_ rarity: Rarity?, highlight: Color? = nil, radius: CGFloat = 9) -> some View {
        modifier(RarityFrame(rarity: rarity, highlight: highlight, radius: radius))
    }
}

/// 등급 띠. 그림 위에 얹어도 읽히게 짙은 바탕에 등급 색 글자를 쓴다.
struct RarityRibbon: View {
    let rarity: Rarity

    var body: some View {
        Text(rarity.title)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(rarity == .legendary ? GameKit.ink : .white)
            .padding(.horizontal, 5)
            .frame(height: 14)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(rarity.swiftColor)
            )
    }
}

/// 쓰는 중 표시. 칸 오른쪽 위에 얹는다.
struct EquippedBadge: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark").font(.system(size: 7.5, weight: .black))
            Text("장착").font(.system(size: 9, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(height: 14)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent))
    }
}

/// 레벨 문장. 방패꼴 안에 픽셀 글꼴로 레벨 수를 새긴다.
struct LevelEmblem: View {
    let level: Int
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Shield().fill(GameKit.gold)
            Shield().inset(size * 0.1).fill(Color(nsColor: NSColor(hex: 0x222B4A)))
            VStack(spacing: 0) {
                Text("LV").font(.system(size: size * 0.18, weight: .heavy)).foregroundStyle(GameKit.gold.opacity(0.85))
                Text("\(level)").font(GameFont.pixel(level >= 100 ? 12 : 18)).foregroundStyle(.white)
            }
            .offset(y: -size * 0.03)
        }
        .frame(width: size, height: size * 1.1)
        .accessibilityHidden(true)
    }

    /// 위가 평평하고 아래가 뾰족한 방패.
    private struct Shield: Shape {
        var amount: CGFloat = 0

        func inset(_ by: CGFloat) -> Shield { Shield(amount: by) }

        func path(in rect: CGRect) -> Path {
            let r = rect.insetBy(dx: amount, dy: amount)
            var p = Path()
            let corner = r.width * 0.16
            p.move(to: CGPoint(x: r.minX + corner, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - corner, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + corner), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.52))
            p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), control: CGPoint(x: r.maxX, y: r.minY + r.height * 0.82))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.52), control: CGPoint(x: r.minX, y: r.minY + r.height * 0.82))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + corner))
            p.addQuadCurve(to: CGPoint(x: r.minX + corner, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.closeSubpath()
            return p
        }
    }
}

/// 경험치·진행 막대.
struct GaugeTrack: View {
    let fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let f = CGFloat(min(max(fraction, 0), 1))
            let width = f > 0 ? max(height, geo.size.width * f) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 섹션 머리: 왼쪽 굵은 이름, 옆에 진행, 오른쪽 작은 메모.
struct GameSectionHeader: View {
    let title: String
    var count: String?
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(GameKit.gold).frame(width: 3, height: 11)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
            if let count { Text(count).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.secondary) }
            Spacer()
            if let note { Text(note).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1) }
        }
        .padding(.horizontal, 2)
    }
}
