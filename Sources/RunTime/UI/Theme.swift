import SwiftUI
import UsageCore

/// 팝오버 디자인 토큰. 색은 상태를 알릴 때만 쓰고, 나머지는 글자 농도와 크기로 위계를 만든다.
/// 팝오버와 러너 화면은 늘 어두운 모습으로 띄우고, 앱 창의 사용량 화면은 시스템 모습을 따라 밝게도 그린다.
enum Theme {
    static let primary = dynamic(light: .black.withAlphaComponent(0.86), dark: .white.withAlphaComponent(0.92))
    // 카드 위 작은 글씨가 읽히는 농도 (보조 글자 대비 약 4.5:1)
    static let secondary = dynamic(light: .black.withAlphaComponent(0.62), dark: .white.withAlphaComponent(0.68))
    static let tertiary = dynamic(light: .black.withAlphaComponent(0.48), dark: .white.withAlphaComponent(0.5))
    static let hairline = dynamic(light: .black.withAlphaComponent(0.09), dark: .white.withAlphaComponent(0.09))
    static let track = dynamic(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.11))
    static let hover = dynamic(light: .black.withAlphaComponent(0.05), dark: .white.withAlphaComponent(0.08))
    static let pressed = dynamic(light: .black.withAlphaComponent(0.1), dark: .white.withAlphaComponent(0.14))
    /// 바탕. 반투명이면 흰 창 위에서 흰 글자·차트가 묻혀 불투명하게 칠한다. 밝을 때는 설정 화면과 같은 회색.
    static let background = dynamic(light: NSColor(hex: 0xF2F2F7), dark: NSColor(white: 0.135, alpha: 1))
    /// 카드 바탕. 구획선 대신 옅은 면으로 묶어 숫자가 먼저 읽히게 한다. 밝을 때는 흰 카드.
    static let surface = dynamic(light: .white, dark: .white.withAlphaComponent(0.045))

    // 시스템 색은 모습마다 알맞은 값으로 바뀐다 (다크에서는 iOS 다크 모드 값과 같다)
    static let accent = Color(nsColor: .systemBlue)
    static let warning = Color(nsColor: .systemOrange)
    static let critical = Color(nsColor: .systemRed)
    static let positive = Color(nsColor: .systemGreen)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// 사용률 링 색: 80% 전 파랑, 80% 주황, 95% 빨강.
    static func ring(_ percent: Double) -> Color {
        switch percent {
        case ..<80: return accent
        case ..<95: return warning
        default: return critical
        }
    }

    /// 섹션 이름 (세션, 주간, 속도…).
    static let label = Font.system(size: 11, weight: .medium)
    static let caption = Font.system(size: 11)
    static let value = Font.system(size: 13, weight: .medium).monospacedDigit()
}

/// 구획선.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

/// 정보 묶음 카드.
struct Card<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// 시간 대비 사용 속도 배지 (여유·적정·빠름·한도 임박).
struct PaceBadge: View {
    let pace: GaugeMath.Pace

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private var title: String {
        switch pace {
        case .relaxed: return "여유"
        case .steady: return "적정"
        case .fast: return "빠름"
        case .critical: return "한도 임박"
        }
    }

    private var color: Color {
        switch pace {
        case .relaxed: return Theme.positive
        case .steady: return Theme.secondary
        case .fast: return Theme.warning
        case .critical: return Theme.critical
        }
    }
}

/// 팝오버 아래 도구 막대의 아이콘 버튼. 배경 없이 두고 올렸을 때만 옅은 바탕을 깐다.
struct ToolbarButtonStyle: ButtonStyle {
    var tint: Color = Theme.primary

    func makeBody(configuration: Configuration) -> some View {
        ToolbarButtonBody(configuration: configuration, tint: tint)
    }

    private struct ToolbarButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @StateObject private var hover = HoverFlag()

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(hover.on ? tint : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(configuration.isPressed ? Theme.pressed : (hover.on ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
                .onHover { hover.on = $0 }
        }
    }
}

/// macOS 27 SDK의 `@State`는 매크로라 Command Line Tools만으로는 빌드되지 않는다.
/// install.sh가 Xcode 없이도 돌도록 뷰 상태를 ObservableObject로 둔다.
final class HoverFlag: ObservableObject {
    @Published var on = false
}
