import AppKit
import SwiftUI
import WorkLogCore

/// 업무 일지 화면의 디자인 규칙.
/// 색은 상태를 알릴 때만 쓰고(완료 초록, 진행 파랑, 기다림 주황), 나머지 위계는 글자 굵기와 회색 농도로 만든다.
/// 칸은 8pt 격자, 숫자는 고정폭, 둥근 정도는 바깥 10pt·안쪽 6pt 두 가지만 쓴다.
enum WL {
    // 간격
    static let gutter: CGFloat = 20
    static let gap: CGFloat = 16
    static let rowHeight: CGFloat = 36
    static let outer: CGFloat = 10
    static let inner: CGFloat = 6

    // 글자
    static let pageTitle = Font.system(size: 30, weight: .bold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let heading = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let meta = Font.system(size: 11.5)
    static let caption = Font.system(size: 11)
    static let label = Font.system(size: 10.5, weight: .medium)
    static let number = Font.system(size: 11.5, weight: .medium).monospacedDigit()
    static let figure = Font.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit()

    // 색: 노션처럼 흰 종이에 따뜻한 회색. 강조는 파랑 하나, 상태색은 채도를 낮춘다
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x191919)
    static let sidebar = dynamic(light: 0xF7F7F5, dark: 0x202020)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x252525)
    static let callout = dynamic(light: 0xF7F6F3, dark: 0x252525)
    static let border = dynamic(light: 0xE9E9E7, dark: 0x2F2F2F)
    static let text = dynamic(light: 0x37352F, dark: 0xE6E6E5)
    static let muted = dynamic(light: 0x787774, dark: 0x9B9B9B)
    static let faint = dynamic(light: 0xACABA9, dark: 0x5A5A5A)
    static let accent = dynamic(light: 0x2383E2, dark: 0x529CCA)
    static let done = dynamic(light: 0x448361, dark: 0x4DAB9A)
    static let waiting = dynamic(light: 0xD9730D, dark: 0xFFA344)
    static let quiet = dynamic(light: 0x9B9A97, dark: 0x7F7F7F)
    static let hover = dynamic(light: 0x37352F, dark: 0xFFFFFF, alpha: 0.055)
    static let selected = dynamic(light: 0x2383E2, dark: 0x529CCA, alpha: 0.14)

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(hex: hex).withAlphaComponent(alpha)
        })
    }

    /// 프로젝트 색. 노션 태그 색처럼 채도를 낮춘 아홉 가지. 이름마다 늘 같은 색.
    static func projectColor(_ name: String) -> Color {
        let colors: [Color] = [
            dynamic(light: 0x337EA9, dark: 0x5B97BD), dynamic(light: 0xD9730D, dark: 0xD9730D),
            dynamic(light: 0x448361, dark: 0x4DAB9A), dynamic(light: 0x9065B0, dark: 0x9A6DD7),
            dynamic(light: 0xC14C8A, dark: 0xC14C8A), dynamic(light: 0xCB912F, dark: 0xCA9849),
            dynamic(light: 0x9F6B53, dark: 0x937264), dynamic(light: 0xD44C47, dark: 0xDF5452),
            dynamic(light: 0x787774, dark: 0x9B9B9B),
        ]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 31 }
        return colors[abs(sum) % colors.count]
    }

    static func statusColor(_ status: WorkStatus) -> Color {
        switch status {
        case .done, .percent(100): return done
        case .ongoing: return quiet
        case .percent, .inProgress: return accent
        }
    }
}

// MARK: - 면

extension View {
    /// 흰 면과 가는 테두리. 그림자 없이 테두리로만 나눈다.
    func wlSurface(radius: CGFloat = WL.outer) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(WL.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(WL.border.opacity(0.7), lineWidth: 0.5))
    }
}

/// 줄 사이 가는 선. 글자가 시작하는 자리부터 긋는다.
struct RowDivider: View {
    var inset: CGFloat = 40

    var body: some View {
        Rectangle().fill(WL.border.opacity(0.6)).frame(height: 0.5).padding(.leading, inset)
    }
}

/// 묶음 이름 (작은 회색 글자).
struct SectionLabel: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text).font(WL.label).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(WL.label).foregroundStyle(.tertiary).monospacedDigit() }
        }
    }
}

/// 프로젝트 표시: 모서리를 조금 둥글린 작은 네모.
struct ProjectSwatch: View {
    let name: String
    var size: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(WL.projectColor(name))
            .frame(width: size, height: size)
    }
}

// MARK: - 상태

/// 상태 표시. 완료는 채운 원에 체크, 진행은 얼마나 왔는지 호, 정하지 않은 진행은 점, 상시는 점선 원.
struct StatusGlyph: View {
    let status: WorkStatus
    var size: CGFloat = 15

    var body: some View {
        let color = WL.statusColor(status)
        ZStack {
            switch status {
            case .done, .percent(100):
                Circle().fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            case .percent(let value):
                Circle().strokeBorder(color.opacity(0.3), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: CGFloat(value) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(0.75)
                Circle().fill(color).frame(width: size * 0.28, height: size * 0.28)
            case .inProgress:
                Circle().strokeBorder(color, lineWidth: 1.5)
                Circle().fill(color).frame(width: size * 0.36, height: size * 0.36)
            case .ongoing:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.label)
    }
}

/// 상태 글자. 줄 오른쪽 고정폭 칸에 둔다.
struct StatusText: View {
    let status: WorkStatus

    var body: some View {
        Text(status.label)
            .font(WL.number)
            .foregroundStyle(status.isFinished ? WL.done : status == .ongoing ? WL.muted : WL.accent)
            .frame(width: 44, alignment: .trailing)
    }
}

/// 일감 번호. 아직 안 보냈으면 주황 점, 보냈으면 초록 체크를 앞에 붙인다.
struct IssueLabel: View {
    let issue: Int
    var posted: Bool? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let posted {
                if posted {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(WL.done)
                } else {
                    Circle().fill(WL.waiting).frame(width: 5, height: 5)
                }
            }
            Text("#" + String(issue)).font(WL.number).foregroundStyle(WL.muted)
        }
        .help(posted == true ? "레드마인에 보냄" : posted == false ? "레드마인에 아직 보내지 않음" : "레드마인 일감")
    }
}

/// 줄 오른쪽 일감 번호 칸. 번호가 없는 줄도 같은 너비를 비워 두어 상태 글자 세로줄이 맞는다.
struct IssueSlot: View {
    let issue: Int?
    var posted: Bool? = nil

    var body: some View {
        Group {
            if let issue { IssueLabel(issue: issue, posted: posted) } else { Color.clear }
        }
        .frame(width: 72, height: 16, alignment: .trailing)
    }
}

// MARK: - 숫자 묶음

struct Metric: Identifiable {
    let id: String
    let value: String
    let tint: Color?

    init(_ title: String, _ value: Int, tint: Color? = nil) {
        id = title
        self.value = String(value)
        self.tint = tint
    }

    init(_ title: String, text: String, tint: Color? = nil) {
        id = title
        value = text
        self.tint = tint
    }
}

/// 맨 위 숫자 줄. 큰 숫자 아래 작은 이름, 칸 사이는 세로 선.
struct MetricBar: View {
    let metrics: [Metric]
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 { Rectangle().fill(WL.border.opacity(0.55)).frame(width: 1, height: 30) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.value).font(WL.figure).foregroundStyle(metric.tint ?? .primary)
                    Text(metric.id).font(WL.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let action {
                Button(action: action.run) {
                    HStack(spacing: 4) {
                        Text(action.title)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WL.waiting)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 10)
        .wlSurface()
    }
}

// MARK: - 단추

/// 머리줄의 네모 아이콘 단추. 평소엔 테두리만, 누르면 옅게 채운다.
struct SquareIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0)))
            .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.border, lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}

/// 줄 안의 작은 아이콘 단추. 테두리 없이 올렸을 때만 바탕.
struct GhostIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration)
    }

    private struct GhostBody: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var hover = HoverFlag()

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hover.on ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hover.on ? 0.06 : 0)))
                .contentShape(Rectangle())
                .onHover { hover.on = $0 }
        }
    }
}

/// 글자 단추. 링크처럼 보이되 밑줄 없이 강조색.
struct TextLinkButtonStyle: ButtonStyle {
    var tint: Color = WL.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}

// MARK: - 사이드바 바탕

/// macOS 사이드바 재질. 창 뒤 바탕화면 색이 비쳐 앱 안의 다른 칸과 구분된다.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - 알림 띠

struct Toast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(WL.border.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// 줄이 넘치면 다음 줄로 꺾어 놓는다.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            let extra = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += extra + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// 작은 테두리 칩 (다른 프로젝트에 적기, 요일 고르기).
struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(selected ? WL.accent : Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
            .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .strokeBorder(selected ? Color.clear : WL.border, lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}


// MARK: - 노션식 부품

/// 밑줄 탭 (노션 데이터베이스 보기 탭처럼). 고른 것만 진한 글자와 2pt 밑줄.
/// `fill`이 아니면 탭마다 글자 너비만 쓴다. 굵은 글자 너비를 미리 잡아 두어 골라도 옆 탭이 밀리지 않는다.
struct PageTabs<Value: Hashable>: View {
    let items: [(value: Value, title: String)]
    @Binding var selection: Value
    var fill = false
    @StateObject private var hover = HoveredKey()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let on = item.value == selection
                Button { selection = item.value } label: {
                    VStack(spacing: 0) {
                        ZStack {
                            Text(item.title).font(.system(size: 13, weight: .semibold)).hidden()
                            Text(item.title)
                                .font(.system(size: 13, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? WL.text : WL.muted)
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(hover.key == item.title && !on ? WL.hover : .clear))
                        Rectangle().fill(on ? WL.text : .clear).frame(height: 2)
                    }
                    .fixedSize(horizontal: !fill, vertical: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover.update(item.title, $0) }
            }
        }
    }
}

/// 페이지 속성 한 줄: 회색 이름 칸과 값 (노션 페이지 머리의 속성처럼).
struct PropertyRow<Value: View>: View {
    let icon: String
    let title: String
    let value: Value

    init(_ title: String, icon: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.icon = icon
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(WL.faint).frame(width: 16)
                Text(title).font(.system(size: 13)).foregroundStyle(WL.muted)
            }
            .frame(width: 128, alignment: .leading)
            value.font(.system(size: 13)).foregroundStyle(WL.text)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }
}

/// 숫자와 이름을 붙여 쓰는 속성 값 조각: `● 완료 6`.
struct Tally: View {
    let title: String
    let value: Int
    var tint: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
            Text(title).foregroundStyle(WL.muted)
            Text("\(value)").fontWeight(.medium).monospacedDigit()
        }
    }
}

/// 노션 단추. 주 단추는 파랑으로 채우고, 보조는 가는 테두리, 둘 다 모서리 6.
struct NotionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    var fill = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.white : WL.text)
            .lineLimit(1)
            .fixedSize(horizontal: !fill, vertical: false)
            .padding(.horizontal, 12)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(kind == .primary ? WL.accent.opacity(configuration.isPressed ? 0.8 : 1)
                      : configuration.isPressed ? WL.hover : WL.surface))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(kind == .primary ? Color.clear : WL.border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// 접고 펴는 묶음 머리 (노션 토글 제목처럼). 화살표는 올렸을 때 진해진다.
struct ToggleHeading<Trailing: View>: View {
    let collapsed: Bool
    let toggle: () -> Void
    let label: AnyView
    let trailing: Trailing
    @StateObject private var hover = HoverFlag()

    init<Label: View>(collapsed: Bool, toggle: @escaping () -> Void, @ViewBuilder label: () -> Label,
                      @ViewBuilder trailing: () -> Trailing) {
        self.collapsed = collapsed
        self.toggle = toggle
        self.label = AnyView(label())
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hover.on ? WL.muted : WL.faint)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: 16, height: 16)
                    label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            trailing.opacity(hover.on ? 1 : 0.0)
        }
        .frame(height: 34)
        .onHover { hover.on = $0 }
    }
}

/// 옅은 회색 상자 (노션 콜아웃). 안내나 미리보기 글에 쓴다.
struct Callout<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.callout))
    }
}

/// 올렸을 때만 옅은 바탕이 깔리는 줄.
struct HoverRow: ViewModifier {
    @StateObject private var hover = HoverFlag()

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hover.on ? WL.hover : .clear))
            .onHover { hover.on = $0 }
    }
}

extension View {
    func hoverRow() -> some View { modifier(HoverRow()) }
}
