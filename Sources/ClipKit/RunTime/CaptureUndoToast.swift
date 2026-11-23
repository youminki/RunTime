import AppKit
import SwiftUI

/// 복사한 로그인 정보를 계정으로 옮긴 뒤 잠깐 뜨는 알림. 잘못 알아봤으면 "기록으로 되돌리기"로 계정을 지우고 클립을 기록에 되살린다.
/// 앱을 앞으로 올리지 않는 창이라 다른 앱에서 일하는 중에도 한 번 눌러 바로 듣는다.
@MainActor
final class CaptureUndoToast {
    static let shared = CaptureUndoToast()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private static let linger: TimeInterval = 6

    private init() {}

    func show(account: Account, item: ClipItem) {
        dismiss()
        let view = CaptureUndoView(title: account.title.isEmpty ? "이름 없음" : account.title) { [weak self] in
            AccountStore.shared.delete(account.id)
            ClipboardStore.shared.addCaptured(item)
            self?.dismiss()
            AccountCapture.notify("계정에서 빼고 기록에 되돌렸습니다", symbol: "arrow.uturn.backward.circle.fill")
        } close: { [weak self] in
            self?.dismiss()
        }
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 34))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    /// 점검(--clip-check)이 되돌리기 단추를 누를 때 쓴다.
    var isShown: Bool { panel?.isVisible == true }
    var undoFrame: CGRect? { (panel?.contentView as? FirstClickHostingView<CaptureUndoView>)?.rootView.frames.undo }
    var window: NSPanel? { panel }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct CaptureUndoView: View {
    let title: String
    let undo: () -> Void
    let close: () -> Void
    /// 단추 자리 (점검이 누를 때 쓴다).
    final class Frames { var undo: CGRect? }
    let frames = Frames()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "계정에 저장했습니다").font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: "\(title) · 기록에는 남기지 않았습니다")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(action: undo) {
                Text(verbatim: "기록으로 되돌리기")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { frames.undo = proxy.frame(in: .global) }
            })
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("닫기")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: 400, height: 50)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
