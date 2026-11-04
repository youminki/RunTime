import SwiftUI
import GameCore

/// 러너·꾸미기가 함께 쓰는 게임 화면 부품.
/// 면은 평평한 색 하나로 칠한다. 번지는 빛과 그러데이션은 쓰지 않는다.
enum GameKit {
    static let gold = Color(nsColor: NSColor(hex: 0xFFD45E))
    /// 칸 바탕. 카드보다 한 단계 짙게 두어 그림이 떠 보이게 한다.
    static let slot = Color(white: 0.105)
}

/// 아래 모서리에 두께가 있는 단추.
struct GameButtonStyle: ButtonStyle {
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        GameButtonBody(configuration: configuration, height: height)
    }

    private struct GameButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
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
            return (Color(white: 0.3), Color(white: 0.3), Color(white: 0.16), Theme.primary)
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

/// 물건 칸 틀. 고른 칸은 그 색으로 옅게 칠한다.
struct SlotFrame: ViewModifier {
    var highlight: Color?
    var radius: CGFloat = 9

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(highlight.map { $0.opacity(0.1) } ?? GameKit.slot))
            .overlay(shape.strokeBorder(highlight.map { $0.opacity(0.9) } ?? Color.white.opacity(0.1),
                                        lineWidth: highlight != nil ? 1.5 : 1))
    }
}

extension View {
    func slotFrame(highlight: Color? = nil, radius: CGFloat = 9) -> some View {
        modifier(SlotFrame(highlight: highlight, radius: radius))
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
