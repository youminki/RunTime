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
/// 화면의 대표 동작 단추. 금색으로 눈에 띄게 둔다.
struct PrimaryGameButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var fontSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, height: height, fontSize: fontSize)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            // 누를 수 없을 때는 금색을 빼고 회색으로 두어 탁한 금색처럼 보이지 않게 한다
            configuration.label
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(enabled ? Color(white: 0.1) : Color.white.opacity(0.35))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled ? GameKit.gold.opacity(configuration.isPressed ? 0.8 : 1) : Color.white.opacity(0.07)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct GameButtonStyle: ButtonStyle {
    var height: CGFloat = 24
    var fontSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        GameButtonBody(configuration: configuration, height: height, fontSize: fontSize)
    }

    private struct GameButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var enabled
        @StateObject private var hover = HoverFlag()

        var body: some View {
            let pressed = configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            let colors = palette
            configuration.label
                .font(.system(size: fontSize, weight: .bold).monospacedDigit())
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
        return font(.system(size: 12, weight: .bold))
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
    var text = "장착"

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark").font(.system(size: 7.5, weight: .black))
            Text(text).font(.system(size: 9, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(height: 14)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent))
    }
}

/// 섹션 머리: 이름과 개수, 오른쪽 작은 메모.
struct GameSectionHeader: View {
    let title: String
    var count: String?
    var note: String?
    /// 앱 창처럼 넓은 곳에서는 한 단계 크게.
    var large = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).font(.system(size: large ? 14 : 12.5, weight: .semibold)).foregroundStyle(Theme.secondary)
            if let count { Text(count).font(.system(size: large ? 13 : 12).monospacedDigit()).foregroundStyle(Theme.tertiary) }
            Spacer()
            if let note { Text(note).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1) }
        }
        .padding(.horizontal, 2)
    }
}

/// 창 러너 화면의 공통 틀. 탭과 왼쪽 칸 폭을 맞춰 탭을 옮겨도 칸 경계가 같은 자리에 있다.
enum RunnerHubLayout {
    static let sideWidth: CGFloat = 340
    static let gap: CGFloat = 16
}

/// 왼쪽 칸의 고르는 줄: 아이콘, 이름과 지금 값, 오른쪽 덧붙임. 고른 줄은 밝게 칠한다.
struct SideItem<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? GameKit.gold : Theme.secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(selected ? 0.1 : 0.05)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14.5, weight: .bold)).foregroundStyle(selected ? Theme.primary : Theme.secondary)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.horizontal, 10)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(selected ? 0.12 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? GameKit.gold.opacity(0.55) : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension SideItem where Trailing == EmptyView {
    init(icon: String, title: String, detail: String, selected: Bool, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, detail: detail, selected: selected, action: action) { EmptyView() }
    }
}

/// 무대 안 난이도 판. 무대 높이 150 기준 크기에 `scale`을 곱해 그린다.
/// 다 그린 뒤 키우면 글자가 그림처럼 늘어나 흐려져서, 글자 크기와 칸 크기를 처음부터 키운다.
/// 난이도마다 최고 점수를 보이고, 지난번에 고른 난이도는 금색 테두리로 표시한다. 누르면 바로 시작한다.
struct DifficultyCard: View {
    let kind: StageAction.Kind
    var scale: CGFloat = 1
    let choose: () -> Void
    let close: () -> Void

    private var flight: Bool { kind == .flight }
    private func z(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: z(7)) {
            HStack(spacing: z(5)) {
                Image(systemName: flight ? "paperplane.fill" : "figure.run").font(.system(size: z(10.5), weight: .bold))
                    .foregroundStyle(GameKit.gold)
                Text(flight ? "비행" : "달리기").font(.system(size: z(12.5), weight: .bold)).foregroundStyle(.white)
                Text("난이도를 고르면 바로 시작해요").font(.system(size: z(10))).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: z(4))
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: z(8.5), weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: z(18), height: z(18))
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("닫기")
            }
            HStack(spacing: z(5)) {
                ForEach(0..<3, id: \.self) { index in
                    let level = levels[index]
                    Button {
                        if flight { FlightRecords.difficulty = FlightDifficulty.allCases[index] } else {
                            GameRecords.difficulty = RunDifficulty.allCases[index]
                        }
                        choose()
                    } label: {
                        VStack(spacing: z(2)) {
                            HStack(spacing: z(3)) {
                                Text("\(index + 1)").font(.system(size: z(8.5), weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.45))
                                Text(level.title).font(.system(size: z(12), weight: .bold)).foregroundStyle(.white)
                            }
                            Text(level.best > 0 ? "최고 \(level.best.formatted())" : "기록 없음")
                                .font(.system(size: z(9.5)).monospacedDigit())
                                .foregroundStyle(level.current ? GameKit.gold : .white.opacity(0.55))
                        }
                        .frame(width: z(80), height: z(42))
                        .background(RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(Color.white.opacity(level.current ? 0.12 : 0.06)))
                        .overlay(RoundedRectangle(cornerRadius: z(7), style: .continuous)
                            .strokeBorder(level.current ? GameKit.gold.opacity(0.8) : Color.white.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(level.title)로 시작")
                }
            }
            Text(flight ? "누르는 동안 올라가요 · 1·2·3 또는 return" : "스페이스로 점프, ↓ 숙이기 · 1·2·3 또는 return")
                .font(.system(size: z(9.5))).foregroundStyle(.white.opacity(0.55))
        }
        .padding(z(10))
        .background(RoundedRectangle(cornerRadius: z(10), style: .continuous).fill(Color(white: 0.07).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: z(10), style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .fixedSize()
    }

    private var levels: [(title: String, best: Int, current: Bool)] {
        if flight {
            return FlightDifficulty.allCases.map { ($0.title, FlightRecords.best($0), $0 == FlightRecords.difficulty) }
        }
        return RunDifficulty.allCases.map { ($0.title, GameRecords.best($0), $0 == GameRecords.difficulty) }
    }
}
