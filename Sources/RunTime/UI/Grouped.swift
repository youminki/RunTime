import AppKit
import SwiftUI

/// 앱 창 크기. 사용량·게임·업무 일지·설정을 한 창에서 오가며, 처음엔 이 크기로 열고 늘이고 줄일 수 있다.
/// 업무 일지가 왼쪽 아이콘 막대 옆에 세 칸을 나란히 두려면 이만큼 필요하다.
enum AppWindow {
    static let size = CGSize(width: 1240, height: 760)
    static let minSize = CGSize(width: 1100, height: 660)
}

/// iOS 시스템 색. 다크·라이트에서 각각 iOS가 쓰는 값을 그대로 쓴다.
enum Palette {
    static let blue = dynamic(light: 0x007AFF, dark: 0x0A84FF)
    static let green = dynamic(light: 0x34C759, dark: 0x30D158)
    static let orange = dynamic(light: 0xFF9500, dark: 0xFF9F0A)
    static let red = dynamic(light: 0xFF3B30, dark: 0xFF453A)
    static let indigo = dynamic(light: 0x5856D6, dark: 0x5E5CE6)
    static let purple = dynamic(light: 0xAF52DE, dark: 0xBF5AF2)
    static let pink = dynamic(light: 0xFF2D55, dark: 0xFF375F)
    static let teal = dynamic(light: 0x30B0C7, dark: 0x40C8E0)
    static let yellow = dynamic(light: 0xFFCC00, dark: 0xFFD60A)
    static let gray = dynamic(light: 0x8E8E93, dark: 0x8E8E93)

    /// 묶음 목록 바탕과 그 위의 줄 바탕 (iOS systemGroupedBackground / secondarySystemGroupedBackground).
    static let groupedBackground = dynamic(light: 0xF2F2F7, dark: 0x1C1C1E)
    static let groupedRow = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let separator = dynamic(light: 0xC6C6C8, dark: 0x3D3D41)
    /// 캐릭터를 올리는 바탕. 흰 캐릭터(토끼·오리·판다)도 묻히지 않게 라이트에서도 옅은 청회색을 깐다.
    static let characterBackdrop = dynamic(light: 0xDCE3EC, dark: 0x3A3A40)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// 둥근 묶음 하나. 위에 작은 머리말, 아래에 설명 각주를 둔다 (iOS 설정 앱의 inset grouped 목록).
struct GroupedSection<Content: View>: View {
    private let header: String?
    private let footer: String?
    private let content: Content

    init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
            // 줄마다 위에 구분선을 긋고, 맨 위 줄의 선은 1pt 올려 둥근 모서리 밖으로 잘라 낸다
            VStack(spacing: 0) { content }
                .padding(.top, -1)
                .background(Palette.groupedRow)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }
}

/// 묶음 안의 한 줄: 아이콘, 제목, 오른쪽 조작. 위쪽 구분선은 아이콘 오른쪽부터 긋는다.
/// 줄 아이콘은 색 없이 둔다. 줄마다 색이 다르면 무엇이 중요한지 가리지 못하고 눈만 바쁘다 (색은 왼쪽 목록과 경고에만 쓴다).
struct GroupedRow<Trailing: View>: View {
    private let icon: String?
    private let title: String
    private let trailing: Trailing

    init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, icon == nil ? 12 : 42)
        }
    }
}

extension GroupedRow where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil) {
        self.init(title, icon: icon) { EmptyView() }
    }
}

/// 스위치 한 줄.
struct ToggleRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        GroupedRow(title, icon: icon) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Palette.green)
                .accessibilityLabel(title)
        }
    }
}

/// 묶음 목록 화면. 바탕을 깔고 묶음 사이를 iOS처럼 넓게 띄운다.
struct GroupedList<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        SlimScrollView {
            // 넓은 창에서 줄이 끝없이 늘어나지 않게 너비를 두되, 스크롤 막대는 창 오른쪽 끝에 남긴다
            VStack(alignment: .leading, spacing: 22) { content }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.groupedBackground)
    }
}
