import AppKit
import SwiftUI

/// 앱 곳곳의 새 소식(업데이트, 레드마인 새 일감, 디자인 변경)을 메뉴바 말풍선으로 보낸다. 앱이 띄울 자리를 정한다.
enum MenuBarNews {
    static var post: (MenuBarBubble.Content) -> Void = { _ in }
    /// 말풍선 단추가 여는 앱 창 화면.
    static var open: (MainPage) -> Void = { _ in }
}

/// 메뉴바 러너 아래, 또는 화면에 꺼낸 펫 위에 뜨는 말풍선. 사용량 창을 열지 않아도 소식을 핵심 몇 줄로 보인다.
/// 사람이 닫기 전에는 닫히지 않는다. 여러 소식이 오면 줄을 세워 하나를 닫으면 다음 것을 보인다. 앱을 앞으로 가져오지 않는다.
final class MenuBarBubble {
    static let shared = MenuBarBubble()
    private var panel: NSPanel?
    private var follow: Timer?
    private var queue: [Content] = []
    /// 말풍선이 붙을 자리. `above`면 그 위에 꼬리를 아래로 두고 뜬다.
    private var anchor: () -> (rect: NSRect, above: Bool)? = { nil }

    struct Content {
        let title: String
        let items: [String]
        var actionTitle: String?
        var action: (() -> Void)?
    }

    func show(_ content: Content, below anchor: NSRect) {
        show(content) { (anchor, false) }
    }

    /// 자리를 매번 다시 물어, 펫처럼 움직이는 것 위에서도 따라간다. 자리가 없어지면(펫을 넣으면) 닫지 않고 그 자리에 둔다.
    func show(_ content: Content, at anchor: @escaping () -> (rect: NSRect, above: Bool)?) {
        self.anchor = anchor
        // 같은 소식이 다시 오면 겹쳐 쌓지 않는다
        if let current = queue.first, current.title == content.title, current.items == content.items { return }
        queue.removeAll { $0.title == content.title && $0.items == content.items }
        queue.append(content)
        present()
    }

    /// 점검 도구가 읽는 지금 말풍선 자리와 줄 선 소식 수.
    var frame: NSRect? { panel?.frame }
    var pending: Int { queue.count }

    /// 점검 도구가 지금 말풍선을 PNG로 남긴다.
    func snapshot(to file: URL) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    /// 줄 선 소식을 모두 닫는다.
    func hide() {
        queue.removeAll()
        close()
    }

    /// 지금 소식만 닫고 다음 소식을 보인다.
    private func dismissCurrent() {
        if !queue.isEmpty { queue.removeFirst() }
        if queue.isEmpty { close() } else { present() }
    }

    private func close() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private var above = false

    private func present() {
        guard let content = queue.first else { return close() }
        let spot = anchor()
        above = spot?.above ?? above
        let view = BubbleView(content: content, remaining: queue.count - 1, tailBelow: above,
                              close: { [weak self] in self?.dismissCurrent() },
                              closeAll: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return panel
        }()
        panel.contentView = host
        panel.setContentSize(size)
        self.panel = panel
        place(at: spot?.rect)
        panel.orderFrontRegardless()
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let spot = self.anchor() else { return }
            if spot.above != self.above { self.present() } else { self.place(at: spot.rect) }
        }
    }

    /// 꼬리가 대상 가운데를 가리키게 두고, 화면 끝을 넘지 않게 민다.
    private func place(at anchor: NSRect?) {
        guard let panel, let anchor else { return }
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - BubbleView.tail, screen.minX + 8), screen.maxX - size.width - 8)
        let y = above ? min(anchor.maxY + 4, screen.maxY - size.height) : anchor.minY - size.height - 4
        let origin = NSPoint(x: x.rounded(), y: y.rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private struct BubbleView: View {
        let content: Content
        /// 이 소식 뒤에 줄 선 소식 수.
        let remaining: Int
        /// 펫 위에 뜨면 꼬리를 아래에 둔다.
        let tailBelow: Bool
        let close: () -> Void
        let closeAll: () -> Void
        /// 꼬리의 가로 자리 (말풍선 왼쪽에서).
        static let tail: CGFloat = 26

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(GameKit.gold)
                    Text(content.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Spacer(minLength: 8)
                    if remaining > 0 {
                        Button("모두 닫기", action: closeAll)
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(remaining > 0 ? "닫고 다음 소식 보기" : "닫기")
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(content.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(GameKit.gold).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            Text(item).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if remaining > 0 {
                    Text("소식 \(remaining)건 더 있어요. 닫으면 다음 소식이 나와요.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                if let title = content.actionTitle, let action = content.action {
                    Button {
                        action()
                        close()
                    } label: {
                        Text(title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryGameButtonStyle(height: 28))
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .overlay(alignment: tailBelow ? .bottomLeading : .topLeading) {
                // 러너·펫을 가리키는 꼬리
                Rectangle().fill(Color(white: 0.11)).frame(width: 10, height: 10).rotationEffect(.degrees(45))
                    .offset(x: Self.tail - 5, y: tailBelow ? 4 : -4)
            }
            .padding(tailBelow ? .bottom : .top, 6)
            .environment(\.colorScheme, .dark)
        }
    }
}
