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
    static let pageTitle = Font.system(size: 26, weight: .bold)
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
        // 완료는 초록 체크로 이미 보여 글을 비운다. 줄마다 초록 글이 서면 아직 안 끝난 일이 묻힌다.
        // 보고서에 `(100%)`로 나가는 줄은 `완료`와 달리 적히니 옅게 남긴다
        Text(status == .done ? "" : status.label)
            .font(WL.number)
            .foregroundStyle(status.isFinished ? WL.muted : status == .ongoing ? WL.muted : WL.accent)
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
        .tip(posted == true ? "레드마인에 보냄" : posted == false ? "레드마인에 아직 보내지 않음" : "레드마인 일감")
    }
}

/// 줄 오른쪽 일감 번호 칸. 번호가 없는 줄도 같은 너비를 비워 두어 상태 글자 세로줄이 맞는다.
struct IssueSlot: View {
    let issue: Int?
    var posted: Bool? = nil
    /// 번호가 없어도 자리를 비워 둘지. 묶음에 일감이 하나도 없으면 비워 두지 않아 내용이 그만큼 넓게 쓴다.
    var reserve = true
    /// 하루 보기 줄처럼 출처 표시를 둘 줄인지와 그 출처. 출처는 따로 칸을 두면 좁은 창에서 내용이 그만큼 꺾여 번호 앞에 작게 붙인다.
    var showsSource = false
    var source: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            // 출처 자리는 늘 같은 너비로 두어 출처 아이콘이 번호 자리로 밀리지 않게 한다
            if showsSource { Group { if let source { SourceMark(source: source) } }.frame(width: 12) }
            if issue != nil || reserve {
                Group { if let issue { IssueLabel(issue: issue, posted: posted) } else { Color.clear } }
                    .frame(width: 72, height: 16, alignment: .trailing)
            }
        }
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

/// 페이지 머리: 큰 제목, 그 아래 요약 한 줄, 오른쪽에 이 페이지에서 바로 할 일.
/// 속성 표를 두면 제목과 같은 말(날짜·기간)이 되풀이되고 목록이 화면 아래로 밀려, 요약은 한 줄로 끝낸다.
struct PageHeading<Meta: View, Accessory: View>: View {
    let title: String
    let meta: Meta
    let accessory: Accessory

    init(_ title: String, @ViewBuilder meta: () -> Meta, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.meta = meta()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(WL.pageTitle).monospacedDigit().foregroundStyle(WL.text).lineLimit(1)
            // 좁은 창에서 요약 글이 `열…`처럼 잘리지 않게, 한 줄에 다 들어가지 않으면 할 일 단추를 다음 줄로 내린다
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    summary
                    Spacer(minLength: 12)
                    accessory
                }
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    accessory
                }
            }
            .frame(minHeight: 28)
        }
        .padding(.bottom, 26)
    }

    private var summary: some View {
        HStack(spacing: 14) { meta }
            .font(.system(size: 13))
            .foregroundStyle(WL.muted)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 요약 줄의 작은 꼬리표 (`오늘`, `어제`).
struct DayBadge: View {
    let text: String
    var tint: Color = WL.accent

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// 숫자와 이름을 붙여 쓰는 요약 조각: `● 완료 6`. 0이면 점과 숫자를 옅게 해 눈이 가지 않게 한다.
struct Tally: View {
    let title: String
    let value: Int
    var tint: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let tint { Circle().fill(value == 0 ? WL.faint : tint).frame(width: 6, height: 6) }
            Text(title).foregroundStyle(WL.muted)
            Text("\(value)").fontWeight(.semibold).monospacedDigit().foregroundStyle(value == 0 ? WL.faint : WL.text)
        }
    }
}

/// 머리 오른쪽의 할 일 단추. 할 일이 있으면 색을 채우고, 없으면 옅은 글로 상태만 알린다.
struct HeadingAction: View {
    let title: String
    var icon: String?
    var tint: Color = WL.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(tint.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
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

// MARK: - 빠른 도움말

extension View {
    /// 아이콘 단추에 올리면 0.35초 뒤 이름표를 띄운다. macOS 기본 도움말(.help)은 1~2초 뒤에야 떠서 아이콘만으로는 무슨 단추인지 알기 어렵다.
    func tip(_ text: String) -> some View { modifier(QuickTip(text: text)) }
}

private struct QuickTip: ViewModifier {
    let text: String
    @StateObject private var anchor = TipAnchor()

    func body(content: Content) -> some View {
        content
            .background(TipAnchorView(anchor: anchor))
            .onHover { inside in if inside { anchor.schedule(text) } else { anchor.cancel() } }
            .accessibilityHint(text)
    }
}

/// 이름표를 붙일 자리. 화면 좌표를 얻으려고 뒤에 빈 NSView를 깐다.
final class TipAnchor: ObservableObject {
    weak var view: NSView?
    private var work: DispatchWorkItem?
    private var press: Any?

    func schedule(_ text: String) {
        work?.cancel()
        // 조건에 따라 비워 둔 도움말(오류가 없을 때 등)은 띄우지 않는다
        guard !text.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in
            // 누르는 중이거나 이미 마우스가 떠났으면 띄우지 않는다. 메뉴를 열면 메뉴가 마우스를 가져가
            // 올림이 끝났다는 소식이 오지 않아, 이 확인이 없으면 열린 메뉴 위에 이름표가 뜬다
            guard let view = self?.view, let window = view.window, window.isVisible, NSEvent.pressedMouseButtons == 0,
                  view.bounds.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil)),
                  window.attachedSheet == nil else { return }
            TipWindow.shared.show(text, below: window.convertToScreen(view.convert(view.bounds, to: nil)),
                                  appearance: window.effectiveAppearance)
        }
        work = item
        // 이름표가 뜨기 전에 누르면 띄우지 않는다 (누른 단추가 연 팝오버 위에 겹치지 않게)
        if press == nil {
            press = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.work?.cancel()
                return event
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    func cancel() {
        removePress()
        guard work != nil else { return }
        work?.cancel()
        work = nil
        TipWindow.shared.hide()
    }

    private func removePress() {
        if let press { NSEvent.removeMonitor(press) }
        press = nil
    }

    deinit {
        work?.cancel()
        removePress()
    }
}

private struct TipAnchorView: NSViewRepresentable {
    let anchor: TipAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// 이름표 창 하나를 돌려 쓴다. 따로 띄운 창에 그려 스크롤 칸·옆 칸·팝오버에 가려지지 않는다.
final class TipWindow {
    static let shared = TipWindow()
    private let panel: NSPanel
    private let host = NSHostingView(rootView: TipLabel(text: "", width: 0))
    private var monitor: Any?
    private var autoHide: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // 팝오버 위에서도 보이게 메뉴보다 한 단 위에 둔다
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.transient, .ignoresCycle]
        // 메뉴바 앱이라 다른 앱이 앞에 있을 때도 일지 창에 올리면 보이게 한다
        panel.hidesOnDeactivate = false
        panel.contentView = host
    }

    func show(_ text: String, below rect: NSRect, appearance: NSAppearance) {
        // 긴 설명은 280pt에서 줄을 바꾼다. 짧은 이름표는 글 너비만큼만 쓴다
        let natural = text.components(separatedBy: "\n").map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]).width
        }.max() ?? 0
        host.rootView = TipLabel(text: text, width: min(ceil(natural) + 1, 280))
        panel.appearance = appearance
        let size = host.fittingSize
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
        if let screen = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            // 화면 아래 끝이면 단추 위로 올린다
            if origin.y < screen.minY + 4 { origin.y = rect.maxY + 6 }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
        // 누르거나 굴리면 바로 숨긴다. 단추가 사라져 올림이 끝났다는 소식이 오지 않아도 남지 않게 시간이 지나면 숨긴다
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                self?.hide()
                return event
            }
        }
        autoHide?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    func hide() {
        autoHide?.cancel()
        autoHide = nil
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct TipLabel: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(WL.text)
            .lineSpacing(2)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.surface))
            .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
    }
}

/// 같은 메뉴 경로로 묶은 줄들의 작은 제목 (내 일감의 메뉴·화면 제목과 같은 꼴).
struct PathHeading: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(WL.muted)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 1)
            .tip(path)
    }
}

/// 경로 묶음마다 제목을 달고 줄을 늘어놓는다. `row`는 줄과, 묶음 안이면 그 경로를 받는다.
/// 줄은 묶음에 들어가고 나와도 같은 id로 두어, 고치던 글 칸이 새로 만들어지지 않게 한다.
struct PathGroupedRows<Row: View>: View {
    let entries: [WorkEntry]
    var pinned: [UUID: String] = [:]
    @ViewBuilder let row: (WorkEntry, String?) -> Row

    private enum Item: Identifiable {
        case heading(String)
        case row(WorkEntry, String?)

        var id: String {
            switch self {
            case .heading(let path): return "path:" + path
            case .row(let entry, _): return entry.id.uuidString
            }
        }
    }

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .heading(let path): PathHeading(path: path)
            case .row(let entry, let path): row(entry, path)
            }
        }
    }

    private var items: [Item] {
        WorkLogFormat.pathGroups(entries, pinned: pinned).flatMap { group -> [Item] in
            (group.path.map { [Item.heading($0)] } ?? []) + group.entries.map { Item.row($0, group.path) }
        }
    }
}
