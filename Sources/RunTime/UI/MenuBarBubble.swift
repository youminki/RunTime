import AppKit
import SwiftUI

/// 앱 곳곳의 새 소식(업데이트, 레드마인 새 일감, 디자인 변경)을 메뉴바 말풍선으로 보낸다. 앱이 띄울 자리를 정한다.
enum MenuBarNews {
    static var post: (MenuBarBubble.Content) -> Void = { _ in }
    /// 말풍선 단추가 여는 앱 창 화면.
    static var open: (MainPage) -> Void = { _ in }
}

/// 메뉴바 러너 바로 아래에 잠깐 뜨는 말풍선. 사용량 창을 열지 않아도 업데이트 소식을 핵심 몇 줄로 보인다.
/// 마우스를 올리면 닫히지 않고, 단추를 누르거나 15초가 지나면 닫힌다. 앱을 앞으로 가져오지 않는다.
final class MenuBarBubble {
    static let shared = MenuBarBubble()
    private var panel: NSPanel?
    private var closeWork: DispatchWorkItem?
    private let hover = HoverFlag()

    struct Content {
        let title: String
        let items: [String]
        var actionTitle: String?
        var action: (() -> Void)?
    }

    func show(_ content: Content, below anchor: NSRect) {
        hide()
        let view = BubbleView(content: content, hover: hover, close: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        // 러너 가운데 아래에 꼬리가 오게 두고, 화면 오른쪽 끝을 넘지 않게 민다
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - BubbleView.tail, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 4))
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleClose()
    }

    /// 점검 도구가 지금 말풍선을 PNG로 남긴다.
    func snapshot(to file: URL) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    func hide() {
        closeWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hover.on { self.scheduleClose() } else { self.hide() }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private struct BubbleView: View {
        let content: Content
        @ObservedObject var hover: HoverFlag
        let close: () -> Void
        /// 꼬리의 가로 자리 (말풍선 왼쪽에서).
        static let tail: CGFloat = 26

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(GameKit.gold)
                    Text(content.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("닫기")
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
            .overlay(alignment: .topLeading) {
                // 러너를 가리키는 꼬리
                Rectangle().fill(Color(white: 0.11)).frame(width: 10, height: 10).rotationEffect(.degrees(45))
                    .offset(x: Self.tail - 5, y: -4)
            }
            .padding(.top, 6)
            .onHover { hover.on = $0 }
            .environment(\.colorScheme, .dark)
        }
    }
}
