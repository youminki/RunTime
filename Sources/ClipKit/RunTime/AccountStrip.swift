import AppKit
import SwiftUI

/// 계정 탭의 띠. 클립 카드와 같은 크기의 계정 카드를 늘어놓는다. ↩나 두 번 누르기로 쓰던 앱에 넣는다.
struct AccountStrip: View {
    @ObservedObject private var mode = BarMode.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        let list = mode.visibleAccounts
        let selected = mode.selectedAccount?.id
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.cardSpacing) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, account in
                        AccountCard(account: account, index: index, selected: account.id == selected,
                                    matched: mode.context?.matches(account) == true)
                            .id(account.id)
                    }
                    if store.searchText.isEmpty { AddAccountCard() }
                }
                .padding(.horizontal, Theme.cardStripHorizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 26)
            }
            .onChange(of: mode.accountID) { id in
                guard let id else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay { if accounts.accounts.isEmpty || list.isEmpty { emptyState(searching: !accounts.accounts.isEmpty) } }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func emptyState(searching: Bool) -> some View {
        if searching {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light))
                Text(verbatim: "“\(store.searchText)”에 맞는 계정이 없습니다").font(.system(size: 13))
            }
            .foregroundStyle(Theme.chromeTextSecondary)
        }
    }
}

private struct AccountCard: View {
    let account: Account
    let index: Int
    let selected: Bool
    let matched: Bool
    @ObservedObject private var settings = Settings.shared
    @ViewState private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                row("person.fill", account.username.isEmpty ? "아이디 없음" : account.username, dim: account.username.isEmpty)
                row("key.fill", "••••••••••", dim: false)
                if !account.site.isEmpty, account.site != account.title {
                    row("globe", account.site, dim: true)
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.cardBody)
            .overlay(alignment: .bottom) {
                if hovering {
                    AccountActionBar(account: account).padding(.bottom, 8).transition(.opacity)
                }
            }
        }
        .frame(width: Theme.cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Theme.cardCorner + Theme.selectedCardRing, style: .continuous)
                    .fill(Theme.selection)
                    .padding(-Theme.selectedCardRing)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
            .strokeBorder(selected ? Theme.selection : Theme.cardBorder, lineWidth: selected ? 1.5 : 1))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !CardActions.shared.blocksPaste { AccountFill.fill(account) } }
        .simultaneousGesture(TapGesture().onEnded {
            CardActions.shared.cardClicked { BarMode.shared.accountID = account.id }
        })
        .contextMenu { AccountMenu(account: account) }
    }

    private var header: some View {
        ZStack {
            Account.color(for: account)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: account.title.isEmpty ? "이름 없음" : account.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.headerText)
                    Text(verbatim: matched ? "지금 창에 맞는 계정" : lastUsedText)
                        .font(.system(size: 12, weight: matched ? .semibold : .regular))
                        .foregroundStyle(Theme.headerSubText)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: initial)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
        }
        .frame(height: Theme.headerHeight)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(verbatim: account.submit ? "↩ 넣고 로그인" : "↩ 넣기")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Theme.selection : Theme.cardTextTertiary)
            Spacer(minLength: 4)
            if index < 9 {
                Text(verbatim: "\(settings.quickPasteModifierDisplay)\(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.cardTextTertiary)
            }
        }
    }

    private func row(_ symbol: String, _ text: String, dim: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.cardTextTertiary)
                .frame(width: 14)
            Text(verbatim: text)
                .font(.system(size: 13, weight: dim ? .regular : .medium, design: symbol == "key.fill" ? .monospaced : .default))
                .foregroundStyle(dim ? Theme.cardTextTertiary : Theme.cardTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var initial: String {
        let source = account.title.isEmpty ? account.username : account.title
        return source.first.map { String($0).uppercased() } ?? "?"
    }

    private var lastUsedText: String {
        account.lastUsed.map { "\($0.clipRelativeLong) 사용" } ?? "아직 쓰지 않음"
    }
}

/// 마우스를 올린 계정 카드의 단추 줄.
private struct AccountActionBar: View {
    let account: Account

    var body: some View {
        HStack(spacing: 2) {
            if !account.username.isEmpty {
                button("person.fill", "아이디만 넣기") { AccountFill.fill(account, part: .username) }
            }
            button("key.fill", "비밀번호만 넣기 (⇧↩)") { AccountFill.fill(account, part: .password) }
            button("doc.on.doc", "비밀번호 복사 (⌘C, 30초 뒤 지움)") { AccountActions.copyPassword(account) }
            button("pencil", "수정 (⌘E)") { AccountEditor.edit(account) }
            button("trash", "삭제 (⌫)", destructive: true) { AccountEditor.confirmDelete(account) }
        }
        .padding(3)
        .background(Color.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .onHover { CardActions.shared.pointerOnControls = $0 }
        .onDisappear { CardActions.shared.pointerOnControls = false }
    }

    private func button(_ symbol: String, _ help: String, destructive: Bool = false,
                        run: @escaping () -> Void) -> some View {
        CardActionButton(symbol: symbol, destructive: destructive) {
            CardActions.shared.acted()
            run()
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct AccountMenu: View {
    let account: Account

    var body: some View {
        Button { AccountFill.fill(account) } label: { Label("넣기", systemImage: "arrow.down.doc") }
        Button { AccountFill.fill(account, part: .username) } label: { Label("아이디만 넣기", systemImage: "person") }
            .disabled(account.username.isEmpty)
        Button { AccountFill.fill(account, part: .password) } label: { Label("비밀번호만 넣기", systemImage: "key") }
        Divider()
        Button { AccountActions.copyUsername(account) } label: { Label("아이디 복사", systemImage: "doc.on.doc") }
            .disabled(account.username.isEmpty)
        Button { AccountActions.copyPassword(account) } label: { Label("비밀번호 복사 (30초 뒤 지움)", systemImage: "doc.on.doc") }
        Button { AccountActions.reveal(account) } label: { Label("비밀번호 보기", systemImage: "eye") }
        Divider()
        Button { AccountEditor.edit(account) } label: { Label("수정…", systemImage: "pencil") }
        Button(role: .destructive) { AccountEditor.confirmDelete(account) } label: { Label("삭제", systemImage: "trash") }
    }
}

/// 계정 띠 끝의 '계정 추가' 카드. 계정이 없을 때는 쓰는 법도 함께 보인다.
private struct AddAccountCard: View {
    @ObservedObject private var accounts = AccountStore.shared
    @ViewState private var hovering = false

    var body: some View {
        Button { AccountEditor.add() } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 24, weight: .semibold))
                Text(verbatim: "계정 추가 (⌘N)").font(.system(size: 13, weight: .semibold))
                if accounts.accounts.isEmpty {
                    Text(verbatim: "아이디·비밀번호를 저장해 두면 입력칸에서 ↩ 한 번으로 넣습니다.\n“아이디: … 비밀번호: …”를 복사해도 저절로 저장됩니다.")
                        .font(.system(size: 11.5))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.chromeTextSecondary)
                        .padding(.horizontal, 14)
                }
            }
            .foregroundStyle(Theme.chromeTextPrimary)
            .frame(width: Theme.cardWidth)
            .frame(maxHeight: .infinity)
            .background(Color.white.opacity(hovering ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

@MainActor
enum AccountActions {
    static func copyPassword(_ account: Account) {
        AccountLock.unlock(reason: "\(account.title) 비밀번호를 복사합니다") {
            guard let password = AccountStore.shared.password(for: account) else {
                AccountCapture.notify("키체인에서 비밀번호를 읽지 못했습니다", symbol: "exclamationmark.triangle.fill")
                return
            }
            AccountFill.copy(password, clearAfter: 30)
            AccountStore.shared.markUsed(account.id)
            AccountCapture.notify("비밀번호를 복사했습니다. 30초 뒤 지웁니다", symbol: "doc.on.doc.fill")
        }
    }

    static func copyUsername(_ account: Account) {
        guard !account.username.isEmpty else { return }
        AccountFill.copy(account.username, clearAfter: nil)
        AccountCapture.notify("아이디를 복사했습니다", symbol: "doc.on.doc.fill")
    }

    static func reveal(_ account: Account) {
        AccountLock.unlock(reason: "\(account.title) 비밀번호를 봅니다") {
            let password = AccountStore.shared.password(for: account) ?? "(키체인에서 읽지 못함)"
            AppController.shared.suppressAutoHide = true
            defer { AppController.shared.suppressAutoHide = false }
            let alert = NSAlert()
            alert.messageText = account.title
            alert.informativeText = [account.username, password].filter { !$0.isEmpty }.joined(separator: "\n")
            alert.addButton(withTitle: "닫기")
            alert.runModal()
        }
    }

    /// 기록의 클립을 계정으로 옮긴다. 저장하면 평문 클립은 기록에서 지운다.
    static func save(from item: ClipItem) {
        let text = item.text ?? ""
        let found = CredentialParser.parse(text)
            ?? Credential(username: "", password: CredentialParser.looksLikePassword(text) ? text : "", site: "")
        let site = found.site
        let title = CredentialParser.host(of: site) ?? (site.isEmpty ? (item.sourceAppName ?? "") : site)
        let draft = Account(title: title, username: found.username, site: site)
        AccountEditor.present(draft: draft, password: found.password, heading: "계정으로 저장") { saved in
            // 고정 쪽 사본까지 지워 평문 비밀번호를 남기지 않는다
            if saved != nil { ClipboardStore.shared.purge(sameAs: item) }
        }
    }
}

/// 계정 추가·수정 창.
@MainActor
enum AccountEditor {
    static func add() {
        let context = BarMode.shared.context
        let title = context.flatMap { AccountContext.browsers.contains($0.bundleID ?? "") ? nil : appName($0.bundleID) } ?? ""
        let draft = Account(title: title, username: "", appBundleID: context?.bundleID.flatMap { AccountContext.browsers.contains($0) ? nil : $0 })
        AccountEditor.present(draft: draft, password: "", heading: "계정 추가") { saved in
            if let saved { BarMode.shared.accountID = saved.id }
        }
    }

    static func edit(_ account: Account) {
        AccountLock.unlock(reason: "\(account.title) 계정을 수정합니다") {
            let password = AccountStore.shared.password(for: account) ?? ""
            present(draft: account, password: password, heading: "계정 수정", existing: true)
        }
    }

    static func confirmDelete(_ account: Account) {
        AppController.shared.suppressAutoHide = true
        defer { AppController.shared.suppressAutoHide = false }
        let alert = NSAlert()
        alert.messageText = "\(account.title.isEmpty ? "이 계정" : account.title)을 지울까요?"
        alert.informativeText = "키체인에 둔 비밀번호도 지웁니다. 되돌릴 수 없습니다."
        alert.addButton(withTitle: "지우기").hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AccountStore.shared.delete(account.id)
        if BarMode.shared.accountID == account.id { BarMode.shared.accountID = BarMode.shared.visibleAccounts.first?.id }
    }

    /// 지금 떠 있는 추가·수정 창. 하나만 띄운다.
    private(set) static var openPanel: AccountEditorPanel?

    /// 창을 띄우고 바로 돌아온다. 닫힐 때 저장한 계정(취소면 nil)을 넘긴다.
    /// 띠를 쓰는 동안 띠와 함께 쓰게 모달로 띄우지 않는다.
    @discardableResult
    static func present(draft account: Account, password: String, heading: String, existing: Bool = false,
                        completion: @escaping @MainActor (Account?) -> Void = { _ in }) -> AccountEditorPanel {
        if let open = openPanel {
            open.makeKeyAndOrderFront(nil)
            return open
        }
        let draft = AccountDraft(account: account, password: password, heading: heading, existing: existing)
        let panel = AccountEditorPanel.make(draft)
        openPanel = panel
        AppController.shared.suppressAutoHide = true
        // 띠가 걸어 둔 ⌘1~9, 여는 단축키는 이 창에서 글자를 칠 때 계정 넣기나 띠 닫기로 가로챈다. 창이 떠 있는 동안 놓는다
        QuickPasteKeys.shared.stop()
        HotKeyCenter.shared.stop()

        var finished = false
        let close: (Account?) -> Void = { result in
            guard !finished else { return }
            finished = true
            panel.orderOut(nil)
            openPanel = nil
            AppController.shared.suppressAutoHide = false
            HotKeyCenter.shared.reload()
            // 창을 닫으면 띠가 다시 키를 받게 한다
            if let bar = NSApp.windows.first(where: { $0 is BarPanel && $0.isVisible }) {
                QuickPasteKeys.shared.start()
                bar.makeKey()
            }
            completion(result)
        }
        draft.onCancel = { close(nil) }
        draft.onSave = {
            if let saved = save(draft, original: account, existing: existing) { close(saved) }
        }
        if existing {
            draft.onDelete = {
                guard confirm(account, over: panel) else { return }
                AccountStore.shared.delete(account.id)
                if BarMode.shared.accountID == account.id { BarMode.shared.accountID = BarMode.shared.visibleAccounts.first?.id }
                close(nil)
            }
        }

        let screen = NSApp.windows.first { $0 is BarPanel && $0.isVisible }?.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 80))
        }
        // 앱을 앞으로 올리지 않는다. 띠처럼 키만 받는다
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    private static func save(_ draft: AccountDraft, original: Account, existing: Bool) -> Account? {
        guard !draft.password.isEmpty else { draft.error = "비밀번호를 넣어 주세요"; return nil }
        let store = AccountStore.shared
        let title = draft.resolvedTitle
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = draft.site.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing {
            var updated = original
            updated.title = title
            updated.username = username
            updated.site = site
            updated.submit = draft.submit
            if store.update(updated, password: draft.password) { return updated }
        } else if var saved = store.save(title: title, username: username, password: draft.password, site: site,
                                         appBundleID: original.appBundleID, submit: draft.submit) {
            if saved.submit != draft.submit {
                saved.submit = draft.submit
                store.update(saved, password: nil)
            }
            return saved
        }
        draft.error = "키체인에 저장하지 못했습니다. 키체인이 잠겨 있는지 확인해 주세요"
        return nil
    }

    private static func confirm(_ account: Account, over window: NSWindow) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(account.title.isEmpty ? "이 계정" : account.title)을 지울까요?"
        alert.informativeText = "키체인에 둔 비밀번호도 지웁니다. 되돌릴 수 없습니다."
        alert.addButton(withTitle: "지우기").hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        alert.window.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 헷갈리는 글자(0 O l 1 I)를 뺀 16자. 대소문자·숫자·기호가 모두 들어간다.
    static func makePassword(length: Int = 16) -> String {
        let sets = ["abcdefghijkmnpqrstuvwxyz", "ABCDEFGHJKLMNPQRSTUVWXYZ", "23456789", "!@#$%^&*-_=+?"].map(Array.init)
        var chars = sets.map { $0.randomElement()! }
        let all = sets.flatMap { $0 }
        while chars.count < length { chars.append(all.randomElement()!) }
        return String(chars.shuffled())
    }

    private static func appName(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
