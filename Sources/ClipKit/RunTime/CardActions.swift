import AppKit
import SwiftUI

/// 카드에서 바로 하는 일(고정, 복사, 서식 없이 붙이기, 계정으로 저장, 삭제).
/// 오른쪽 클릭 메뉴까지 가지 않게 마우스를 올린 카드 위에 단추로 꺼내 둔다.
@MainActor
final class CardActions {
    static let shared = CardActions()

    private var lastAction = Date.distantPast
    /// 포인터가 단추 줄 위에 있으면 카드 클릭(선택 바꾸기, 두 번 눌러 붙이기)을 받지 않는다.
    /// 단추와 카드 클릭이 함께 잡혀 여러 장 고른 것이 한 장으로 풀리지 않게 한다.
    var pointerOnControls = false

    private init() {}

    /// 카드 단추를 빠르게 두 번 누르면 카드의 두 번 누르기(붙이기)로도 잡힌다. 그동안은 붙이지 않는다.
    var blocksPaste: Bool {
        pointerOnControls || Date().timeIntervalSince(lastAction) < 0.5
    }

    func acted() { lastAction = Date() }

    /// 카드를 눌렀을 때. 카드 클릭과 카드 안 단추가 함께 잡히면 어느 쪽이 먼저 올지 모른다.
    /// 다음 차례로 미뤄 단추가 먼저 acted()를 남기게 하고, 단추를 누른 것이면 선택을 바꾸지 않는다.
    func cardClicked(_ select: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let actions = CardActions.shared
                guard !actions.pointerOnControls, Date().timeIntervalSince(actions.lastAction) > 0.2 else { return }
                select()
            }
        }
    }

    /// 띠를 닫을 때. 포인터가 단추 위에 있던 채 닫혀 hover가 풀리지 않은 경우를 되돌린다.
    func barClosed() { pointerOnControls = false }

    /// 띠의 ··· 메뉴에서 기록 전체를 지울 때. 되돌릴 수 없어 먼저 묻는다.
    static func confirmClearHistory() {
        let store = ClipboardStore.shared
        guard !store.history.isEmpty else { return }
        AppController.shared.suppressAutoHide = true
        defer { AppController.shared.suppressAutoHide = false }
        let alert = NSAlert()
        alert.messageText = "클립 \(store.history.count)개를 모두 지울까요?"
        alert.informativeText = "고정한 클립과 계정은 남습니다. 되돌릴 수 없습니다."
        alert.addButton(withTitle: "지우기").hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn { store.clearHistory() }
    }

    /// 비밀번호처럼 보여 카드에서 가리는 클립.
    static func looksSecret(_ item: ClipItem) -> Bool {
        item.type == .text && item.customTitle == nil && CredentialParser.looksLikePassword(item.text ?? "")
    }
}

/// 마우스를 올린 카드 아래쪽에 뜨는 단추 줄.
struct CardActionBar: View {
    let item: ClipItem
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        let selection = AppController.shared.selection(containing: item)
        let many = selection.count > 1
        HStack(spacing: 2) {
            action(isPinned ? "pin.slash" : "pin", isPinned ? (many ? "\(selection.count)개 고정 풀기 (⌘P)" : "고정 풀기 (⌘P)")
                                                           : (many ? "\(selection.count)개 고정 (⌘P)" : "고정 (⌘P)")) {
                Pinned.toggle(selection)
            }
            if selection.contains(where: { $0.type == .richText }) {
                action("text.alignleft", "서식 없이 붙이기 (⇧↩)") {
                    AppController.shared.pasteSelection(containing: item, format: .plainText)
                }
            }
            action("doc.on.doc", many ? "\(selection.count)개 복사 (⌘C)" : "복사 (⌘C)") {
                AppController.shared.copySelection(containing: item)
            }
            if !many, item.type == .text || item.type == .richText,
               CardActions.looksSecret(item) || CredentialParser.parse(item.text ?? "") != nil {
                action("key", "계정으로 저장") { AccountActions.save(from: item) }
            }
            action("trash", many ? "\(selection.count)개 삭제 (⌫)" : "삭제 (⌫)", destructive: true) {
                AppController.shared.deleteSelection(containing: item)
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .onHover { CardActions.shared.pointerOnControls = $0 }
        .onDisappear { CardActions.shared.pointerOnControls = false }
    }

    /// 고른 카드가 모두 고정돼 있는지.
    private var isPinned: Bool {
        _ = store.pinboards
        return AppController.shared.selection(containing: item).allSatisfy(Pinned.contains)
    }

    private func action(_ symbol: String, _ help: String, destructive: Bool = false,
                        run: @escaping () -> Void) -> some View {
        CardActionButton(symbol: symbol, destructive: destructive) {
            CardActions.shared.acted()
            run()
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 띠 카드 위 단추. 마우스를 올리면 밝게 칠한다. 계정 카드도 같은 단추를 쓴다.
struct CardActionButton: View {
    let symbol: String
    let destructive: Bool
    let run: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering && destructive ? Color(red: 1, green: 0.42, blue: 0.4) : .white)
                .frame(width: 28, height: 26)
                .background(Color.white.opacity(hovering ? 0.16 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
