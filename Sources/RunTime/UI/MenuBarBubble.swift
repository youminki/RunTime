import AppKit
import SwiftUI

/// 앱 곳곳의 새 소식(업데이트, 레드마인 새 일감, 디자인 변경)을 메뉴바 말풍선으로 보낸다. 앱이 띄울 자리를 정한다.
enum MenuBarNews {
    static var post: (MenuBarBubble.Content) -> Void = { _ in }
    /// 말풍선 단추가 여는 앱 창 화면.
    static var open: (MainPage) -> Void = { _ in }
}

/// 메뉴바 러너 아래, 또는 화면에 꺼낸 펫 위에 뜨는 말풍선. 사용량 창을 열지 않아도 소식을 핵심 몇 줄로 보인다.
/// 사람이 닫기 전에는 닫히지 않고, 앱을 다시 켜도 닫지 않은 소식은 다시 뜬다. 여러 소식이 오면 한 말풍선에 모아
/// 앞뒤로 넘겨 보고, 하나를 닫으면 다음 것을 보인다. 앱을 앞으로 가져오지 않는다.
final class MenuBarBubble {
    static let shared = MenuBarBubble()
    /// 다시 켠 뒤 되살린 소식의 `link`를 단추 동작으로 바꾼다. 앱이 정한다.
    static var resolve: (String) -> (() -> Void)? = { _ in nil }
    private var panel: NSPanel?
    private var host: NSHostingView<BubbleView>?
    private var follow: Timer?
    private var queue: [Content] = []
    /// 지금 보이는 소식의 자리.
    private var index = 0
    /// 말풍선이 붙을 자리와 그 위에 뜨고 싶은지. 자리가 모자라면 반대쪽에 뜬다.
    private var anchor: () -> (rect: NSRect, above: Bool)? = { nil }
    /// 지금 말풍선이 대상 위에 떠 있는지 (꼬리가 아래).
    private var above = false
    /// 꼬리의 가로 자리 (말풍선 왼쪽에서). 화면 끝에서 말풍선이 밀려도 대상을 가리키게 옮긴다.
    private var tail = BubbleView.tail
    private static let savedKey = "menuBarBubbleQueue"
    private static let savedLimit = 20

    struct Content {
        let title: String
        let items: [String]
        var actionTitle: String?
        var action: (() -> Void)?
        /// 다시 켠 뒤에도 단추를 살릴 열쇠 (예: "page:redmine", "notify:workLog"). 없으면 단추 없이 되살린다.
        var link: String?
        /// 다시 켠 뒤에 되살릴지. 곧 낡는 소식(새 버전 안내)은 false.
        var keeps = true
    }

    private struct Saved: Codable {
        let title: String
        let items: [String]
        let actionTitle: String?
        let link: String?
    }

    func show(_ content: Content, below anchor: NSRect) {
        show(content) { (anchor, false) }
    }

    /// 자리를 매번 다시 물어, 펫처럼 움직이는 것 위에서도 따라간다. 자리가 없어지면 닫지 않고 그 자리에 둔다.
    func show(_ content: Content, at anchor: @escaping () -> (rect: NSRect, above: Bool)?) {
        self.anchor = anchor
        // 같은 소식이 다시 오면 겹쳐 쌓지 않는다
        if queue.contains(where: { $0.title == content.title && $0.items == content.items }) {
            if panel == nil { present() }
            return
        }
        queue.append(content)
        save()
        present()
    }

    /// 지난번에 닫지 않고 끈 소식을 다시 띄운다.
    func restore(at anchor: @escaping () -> (rect: NSRect, above: Bool)?) {
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey),
              let saved = try? JSONDecoder().decode([Saved].self, from: data), !saved.isEmpty else { return }
        let restored = saved.map { item -> Content in
            let action = item.link.flatMap(Self.resolve)
            return Content(title: item.title, items: item.items, actionTitle: action == nil ? nil : item.actionTitle,
                           action: action, link: item.link)
        }
        queue = restored + queue.filter { new in !restored.contains { $0.title == new.title && $0.items == new.items } }
        index = 0
        self.anchor = anchor
        save()
        present()
    }

    /// 점검 도구가 읽는 지금 말풍선 자리, 펫 위에 떴는지, 줄 선 소식 수.
    var frame: NSRect? { panel?.frame }
    var isAbove: Bool { above }
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
        index = 0
        save()
        close()
    }

    /// 지금 소식만 닫고 다음 소식을 보인다 (마지막이었으면 앞 소식).
    private func dismissCurrent() {
        if queue.indices.contains(index) { queue.remove(at: index) }
        index = min(index, max(queue.count - 1, 0))
        save()
        if queue.isEmpty { close() } else { present() }
    }

    /// 앞뒤 소식으로 넘긴다. 점검 도구도 쓴다.
    func turn(_ step: Int) {
        guard !queue.isEmpty else { return }
        index = (index + step + queue.count) % queue.count
        present()
    }

    /// 점검 도구가 읽는 지금 소식 제목.
    var currentTitle: String? { queue.indices.contains(index) ? queue[index].title : nil }

    private func save() {
        let saved = queue.filter(\.keeps).suffix(Self.savedLimit)
            .map { Saved(title: $0.title, items: $0.items, actionTitle: $0.actionTitle, link: $0.link) }
        if saved.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        } else if let data = try? JSONEncoder().encode(Array(saved)) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
    }

    private func close() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }

    private func view(for content: Content) -> BubbleView {
        BubbleView(content: content, position: index + 1, total: queue.count, tailBelow: above, tailX: tail,
                   close: { [weak self] in self?.dismissCurrent() },
                   closeAll: { [weak self] in self?.hide() },
                   turn: { [weak self] in self?.turn($0) })
    }

    private func present() {
        index = min(index, max(queue.count - 1, 0))
        guard queue.indices.contains(index) else { return close() }
        let content = queue[index]
        let host = self.host ?? NSHostingView(rootView: view(for: content))
        host.rootView = view(for: content)
        host.layoutSubtreeIfNeeded()
        // 높이는 꼬리 쪽과 상관없어 먼저 재고, 그 크기로 위아래 어디에 뜰지 정한다
        let size = host.fittingSize
        let spot = anchor()
        if let spot {
            let side = Self.side(for: spot, size: size)
            if side != above {
                above = side
                host.rootView = view(for: content)
            }
        }
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
        if panel.contentView !== host { panel.contentView = host }
        panel.setContentSize(size)
        self.panel = panel
        self.host = host
        place(at: spot?.rect)
        panel.orderFrontRegardless()
        if follow == nil {
            follow = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self, let panel = self.panel, let spot = self.anchor() else { return }
                if Self.side(for: spot, size: panel.frame.size) != self.above { self.present() } else { self.place(at: spot.rect) }
            }
        }
    }

    private static func screen(around rect: NSRect) -> NSRect {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
    }

    /// 바라는 쪽에 자리가 모자라면(천장을 걷는 펫, 화면 아래 끝 메뉴바) 반대쪽에 띄운다.
    private static func side(for spot: (rect: NSRect, above: Bool), size: NSSize) -> Bool {
        let screen = screen(around: spot.rect)
        let fitsAbove = spot.rect.maxY + 4 + size.height <= screen.maxY
        let fitsBelow = spot.rect.minY - 4 - size.height >= screen.minY
        return spot.above ? (fitsAbove || !fitsBelow) : (!fitsBelow && fitsAbove)
    }

    /// 꼬리가 대상 가운데를 가리키게 두고, 화면 끝을 넘지 않게 민다.
    private func place(at anchor: NSRect?) {
        guard let panel, let anchor else { return }
        let size = panel.frame.size
        let screen = Self.screen(around: anchor)
        let x = min(max(anchor.midX - BubbleView.tail, screen.minX + 8), screen.maxX - size.width - 8)
        let y = above ? min(anchor.maxY + 4, screen.maxY - size.height) : max(anchor.minY - size.height - 4, screen.minY)
        let origin = NSPoint(x: x.rounded(), y: y.rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        let pointing = min(max(anchor.midX - origin.x, 16), size.width - 16).rounded()
        if pointing != tail, queue.indices.contains(index) {
            let content = queue[index]
            tail = pointing
            host?.rootView = view(for: content)
        }
    }

    struct BubbleView: View {
        let content: Content
        /// 지금 소식이 몇 번째인지와 모두 몇 건인지.
        let position: Int
        let total: Int
        /// 펫 위에 뜨면 꼬리를 아래에 둔다.
        let tailBelow: Bool
        /// 꼬리의 가로 자리 (말풍선 왼쪽에서).
        let tailX: CGFloat
        let close: () -> Void
        let closeAll: () -> Void
        let turn: (Int) -> Void
        /// 꼬리의 기본 가로 자리 (말풍선 왼쪽에서).
        static let tail: CGFloat = 26

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(GameKit.gold)
                    Text(content.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Spacer(minLength: 8)
                    if total > 1 {
                        HStack(spacing: 2) {
                            arrow("chevron.left", label: "앞 소식") { turn(-1) }
                            Text("\(position)/\(total)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.6))
                            arrow("chevron.right", label: "다음 소식") { turn(1) }
                        }
                    }
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(total > 1 ? "이 소식 닫기" : "닫기")
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
                if total > 1 {
                    HStack(spacing: 6) {
                        Text("소식 \(total)건 · 닫으면 다음 소식이 나와요").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        Spacer(minLength: 4)
                        Button("모두 닫기", action: closeAll)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
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
            .overlay(alignment: tailBelow ? .bottomLeading : .topLeading) {
                // 러너·펫을 가리키는 꼬리
                Rectangle().fill(Color(white: 0.11)).frame(width: 10, height: 10).rotationEffect(.degrees(45))
                    .offset(x: tailX - 5, y: tailBelow ? 4 : -4)
            }
            .padding(tailBelow ? .bottom : .top, 6)
            .environment(\.colorScheme, .dark)
        }

        private func arrow(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }
}
