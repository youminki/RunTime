import AppKit
import SwiftUI

/// 앱에 맞춘 스크롤 칸. SwiftUI 스크롤 칸 안의 macOS 스크롤 막대를 `SlimScroller`로 바꿔 끼운다.
/// 막대는 내용이 넘칠 때 늘 보이고, 끌거나 트랙을 눌러 움직일 수 있으며, 오른쪽에 제 자리를 따로 가져 글을 가리지 않는다.
struct SlimScrollView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content.background(ScrollerInstaller().frame(width: 0, height: 0))
        }
    }
}

/// 스크롤 칸 내용 안에 숨어 있다가 감싼 NSScrollView를 찾아 막대를 갈아 끼운다.
private struct ScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }
    func updateNSView(_ view: InstallerView, context: Context) { view.install() }

    final class InstallerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
            // 시스템 설정의 "스크롤 막대 보기"를 바꾸면 macOS가 막대 꼴을 되돌려서 다시 맞춘다
            if observer == nil {
                observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.install() }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func install() {
            guard let scroll = enclosingScrollView else { return }
            SlimScroller.install(on: scroll)
        }
    }
}

/// 얇고 둥근 손잡이만 있는 스크롤 막대. 트랙은 비워 바탕이 그대로 보이고,
/// 마우스를 올리거나 끄는 동안 손잡이가 굵고 진해진다. 막대 폭만큼 내용이 왼쪽으로 물러나 글을 덮지 않는다.
final class SlimScroller: NSScroller {
    static let width: CGFloat = 11
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    /// 한 번만 바꿔 끼우고, 꼴만 되돌려졌으면 다시 맞춘다.
    static func install(on scroll: NSScrollView) {
        if !(scroll.verticalScroller is SlimScroller) {
            scroll.verticalScroller = SlimScroller()
        }
        if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
    }

    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { width }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 트랙과 바탕은 그리지 않는다 (흰 트랙이 화면 색을 가리지 않게)
        drawKnob()
    }

    override func drawKnob() {
        let slot = rect(for: .knob)
        guard slot.height > 0 else { return }
        let thick: CGFloat = hovering ? 7 : 5
        let knob = NSRect(x: slot.midX - thick / 2, y: slot.minY + 3, width: thick, height: max(slot.height - 6, 16))
        NSColor.labelColor.withAlphaComponent(hovering ? 0.42 : 0.24).setFill()
        NSBezierPath(roundedRect: knob, xRadius: thick / 2, yRadius: thick / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// 두 칸 사이 경계. 끌어서 칸 너비를 바꾸고, 두 번 누르면 기본 너비로 돌아간다.
/// 마우스를 올리면 좌우 화살표 손잡이와 커서로 끌 수 있다는 것을 알린다.
struct ColumnDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let standard: CGFloat
    /// 오른쪽 칸 너비를 바꿀 때. 경계를 왼쪽으로 끌면 넓어진다.
    var trailing = false
    /// 두 번 누를 때 고정 너비 대신 자동 너비로 되돌리려면.
    var reset: (() -> Void)?
    @StateObject private var state = DividerState()

    var body: some View {
        Rectangle()
            .fill(state.active ? WL.accent.opacity(0.6) : WL.border)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        state.hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = state.start ?? width
                            state.start = start
                            let moved = trailing ? -value.translation.width : value.translation.width
                            width = min(range.upperBound, max(range.lowerBound, (start + moved).rounded()))
                        }
                        .onEnded { _ in state.start = nil })
                    .onTapGesture(count: 2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if let reset { reset() } else { width = standard }
                        }
                    }
            }
            .overlay {
                // 손잡이: 평소엔 옅은 세 점, 올리면 좌우 화살표
                ZStack {
                    Capsule().fill(WL.surface).frame(width: 14, height: 30)
                        .overlay(Capsule().strokeBorder(WL.border, lineWidth: 1))
                    Image(systemName: state.active ? "arrow.left.and.right" : "ellipsis")
                        .font(.system(size: state.active ? 8 : 9, weight: .bold))
                        .rotationEffect(.degrees(state.active ? 0 : 90))
                        .foregroundStyle(state.active ? WL.accent : WL.faint)
                }
                .opacity(state.active ? 1 : 0.7)
                .allowsHitTesting(false)
            }
            .zIndex(1)
            .tip("끌어서 너비 바꾸기 · 두 번 누르면 기본 너비")
    }
}

@MainActor
final class DividerState: ObservableObject {
    @Published var hovering = false
    @Published var start: CGFloat?
    var active: Bool { hovering || start != nil }
}
