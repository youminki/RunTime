import AppKit
import SwiftUI

/// 꺼낸 펫을 오른쪽 클릭하면 펫 옆에 뜨는 옵션 창. 시스템 메뉴는 하위 메뉴를 따라가야 하고 글자만 있어,
/// 자주 바꾸는 움직임을 설명이 붙은 큰 카드로 두고 크기·일일보고·바로 가기를 한눈에 보인다.
/// 움직임과 크기는 골라도 닫지 않아 바뀐 모습을 보며 고른다. 창 밖을 누르거나 Esc를 누르면 닫힌다. 메인 스레드에서만 쓴다.
final class PetOptions {
    static let shared = PetOptions()

    struct Actions {
        var mode: (DesktopPet.Mode) -> Void
        var size: (CGFloat) -> Void
        var page: (MainPage) -> Void
        var report: (DailyReportBubble.Kind) -> Void
        var putBack: () -> Void
        var closed: () -> Void
    }

    final class Model: ObservableObject {
        @Published var mode: DesktopPet.Mode
        @Published var size: CGFloat
        let keys: String?
        init(mode: DesktopPet.Mode, size: CGFloat, keys: String?) {
            (self.mode, self.size, self.keys) = (mode, size, keys)
        }
    }

    private var panel: OptionsPanel?
    private var monitors: [Any] = []
    /// 펫 창. 그 창의 오른쪽 클릭은 펫이 여닫기를 맡아, 여기서 닫으면 바로 다시 열린다.
    weak var petWindow: NSWindow?
    private var actions: Actions?
    private(set) var model: Model?

    var isShown: Bool { panel != nil }

    /// 점검 도구가 지금 옵션 창을 PNG로 남긴다.
    func snapshot(to file: URL) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }
    /// 점검 도구가 읽는 창 자리.
    var frame: NSRect? { panel?.frame }

    /// 펫 몸(`body`, 화면 좌표) 옆에 띄운다. 오른쪽에 자리가 없으면 왼쪽에 둔다.
    func show(near body: CGRect, mode: DesktopPet.Mode, size: CGFloat, keys: String?, actions: Actions) {
        close()
        let model = Model(mode: mode, size: size, keys: keys)
        self.model = model
        self.actions = actions
        let view = OptionsView(model: model,
                               mode: { [weak self] in model.mode = $0; self?.actions?.mode($0) },
                               size: { [weak self] in model.size = $0; self?.actions?.size($0) },
                               page: { [weak self] page in self?.finish { $0.page(page) } },
                               report: { [weak self] kind in self?.finish { $0.report(kind) } },
                               putBack: { [weak self] in self?.finish { $0.putBack() } },
                               close: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        let fitted = host.fittingSize
        let panel = OptionsPanel(contentRect: NSRect(origin: .zero, size: fitted), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.close() }
        panel.setFrameOrigin(Self.origin(for: fitted, near: body))
        self.panel = panel
        // 앱을 앞으로 가져오지 않고 Esc만 받는다
        panel.orderFrontRegardless()
        panel.makeKey()
        // 창 밖을 누르면 닫는다 (다른 앱 창이든 이 앱 창이든)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.close()
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let toggledByPet = event.type == .rightMouseDown && event.window != nil && event.window === self?.petWindow
            if event.window !== self?.panel, !toggledByPet { self?.close() }
            return event
        }) { monitors.append(local) }
    }

    func close() {
        guard let panel else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.orderOut(nil)
        self.panel = nil
        model = nil
        let actions = self.actions
        self.actions = nil
        actions?.closed()
    }

    /// 창을 닫고 고른 일을 한다. 앱 창을 여는 일은 닫은 뒤에 해야 새 창이 이 창 밑에 깔리지 않는다.
    private func finish(_ work: (Actions) -> Void) {
        guard let actions else { return }
        close()
        work(actions)
    }

    private static func origin(for size: CGSize, near body: CGRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: body.midX, y: body.midY)) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 10
        let right = body.maxX + gap
        let x = right + size.width <= screen.maxX - 8 ? right : body.minX - gap - size.width
        let y = body.midY - size.height / 2
        return NSPoint(x: min(max(x, screen.minX + 8), screen.maxX - size.width - 8).rounded(),
                       y: min(max(y, screen.minY + 8), screen.maxY - size.height - 8).rounded())
    }
}

/// Esc를 받으려고 키 창이 될 수 있는 테두리 없는 창. 앱을 앞으로 가져오지 않는다.
private final class OptionsPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
    }
}

private struct OptionsView: View {
    @ObservedObject var model: PetOptions.Model
    let mode: (DesktopPet.Mode) -> Void
    let size: (CGFloat) -> Void
    let page: (MainPage) -> Void
    let report: (DailyReportBubble.Kind) -> Void
    let putBack: () -> Void
    let close: () -> Void

    private static let sizes: [(String, CGFloat)] = [("작게", 0.7), ("보통", 1.0), ("크게", 1.4), ("아주 크게", 2.0)]
    private static let pages: [(String, String, MainPage)] = [
        ("사용량", "chart.bar.fill", .usage), ("펫 꾸미기", "pawprint.fill", .runners), ("업무 일지", "list.bullet.rectangle", .workLog),
        ("레드마인", "checklist", .redmine), ("디자인", "paintpalette", .design), ("설정", "gearshape", .settings),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("펫 옵션").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("닫기")
            }
            section("움직임") {
                VStack(spacing: 6) {
                    ForEach(DesktopPet.Mode.allCases, id: \.self) { item in modeCard(item) }
                }
            }
            section("크기") {
                HStack(spacing: 4) {
                    ForEach(Self.sizes, id: \.1) { title, value in
                        let on = abs(model.size - value) < 0.05
                        Button { size(value) } label: {
                            Text(title).font(.system(size: 12, weight: on ? .bold : .medium))
                                .foregroundStyle(on ? Color(white: 0.1) : .white.opacity(0.8))
                                .frame(maxWidth: .infinity).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(on ? GameKit.gold : Color.white.opacity(0.06)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            section("오늘 일일보고") {
                HStack(spacing: 6) {
                    ForEach(DailyReportBubble.Kind.allCases, id: \.self) { kind in
                        tile(kind.name, icon: kind == .plan ? "sunrise" : "sunset") { report(kind) }
                    }
                }
            }
            section("바로 가기") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Self.pages, id: \.2) { title, icon, target in tile(title, icon: icon) { page(target) } }
                }
            }
            HStack {
                if let keys = model.keys {
                    Text("\(keys)+방향키로 움직이기").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button(action: putBack) {
                    Label("펫 넣기", systemImage: "tray.and.arrow.down").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            content()
        }
    }

    private func modeCard(_ item: DesktopPet.Mode) -> some View {
        let on = model.mode == item
        return Button { mode(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? GameKit.gold : .white.opacity(0.7)).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 4)
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
                    .foregroundStyle(on ? GameKit.gold : .white.opacity(0.25))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(on ? 0.1 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(on ? GameKit.gold.opacity(0.7) : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tile(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
