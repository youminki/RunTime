import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 띠 위쪽의 세 탭. 보드를 여럿 만들고 이름 붙이는 대신, 자주 쓰는 클립은 '고정' 하나에 모은다.
enum BarTab: Int, CaseIterable {
    case recent, pinned, accounts

    var title: String {
        switch self {
        case .recent: return "최근"
        case .pinned: return "고정"
        case .accounts: return "계정"
        }
    }

    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .pinned: return "pin.fill"
        case .accounts: return "key.fill"
        }
    }
}

@MainActor
final class BarMode: ObservableObject {
    static let shared = BarMode()

    @Published private(set) var tab: BarTab = .recent
    /// 계정 탭에서 고른 계정.
    @Published var accountID: UUID?
    /// 띠를 연 곳. 계정 탭을 처음 열 때 읽는다.
    @Published private(set) var context: AccountContext?
    private var contextToken = -1

    private init() {}

    /// 띠를 열 때마다 최근 탭에서 시작한다.
    func reset() {
        AccountCapture.sweepSecrets()
        tab = .recent
        accountID = nil
        context = nil
    }

    func select(_ tab: BarTab) {
        let store = ClipboardStore.shared
        self.tab = tab
        switch tab {
        case .recent:
            store.source = .history
            store.selectFirst()
        case .pinned:
            store.source = .pinboard(Pinned.boardID())
            store.selectFirst()
        case .accounts:
            store.source = .history
            // 최근 탭에서 여러 장 고른 것이 보이지 않는 채 남아 일괄 삭제·esc에 걸리지 않게 푼다
            store.clearMultiSelection()
            if contextToken != store.barPresentationToken {
                contextToken = store.barPresentationToken
                context = AccountFill.context()
            }
            accountID = visibleAccounts.first?.id
        }
    }

    var visibleAccounts: [Account] {
        AccountStore.shared.ordered(query: ClipboardStore.shared.searchText, context: context)
    }

    var selectedAccount: Account? {
        let list = visibleAccounts
        return list.first { $0.id == accountID } ?? list.first
    }

    func moveAccount(by delta: Int) {
        let list = visibleAccounts
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedAccount?.id } ?? 0
        accountID = list[max(0, min(list.count - 1, index + delta))].id
    }
}

/// 고정한 클립. 저장은 Pesty 보드 하나를 그대로 쓴다.
@MainActor
enum Pinned {
    static let name = "고정"

    static func boardID() -> UUID {
        let store = ClipboardStore.shared
        if let board = store.pinboards.first { return board.id }
        return store.addPinboard(name: name).id
    }

    static func contains(_ item: ClipItem) -> Bool {
        ClipboardStore.shared.pinboards.first?.items.contains { $0.sameContent(as: item) } ?? false
    }

    /// 모두 고정돼 있으면 풀고, 아니면 고정한다.
    static func toggle(_ items: [ClipItem]) {
        guard !items.isEmpty else { return }
        let store = ClipboardStore.shared
        let id = boardID()
        if items.allSatisfy(contains) {
            if store.source == .pinboard(id) {
                // 고정 탭에서 푸는 것은 그 탭에서 지우는 것과 같다. 기록에 없을 수 있어 ⌘Z로 되살릴 수 있게 지운다
                store.delete(items: items)
            } else {
                for item in items { store.removeFromPinboard(item, boardID: id) }
            }
        } else {
            // 띠에서 보던 순서 그대로 고정 탭에 놓이게 뒤에서부터 넣는다 (saveToPinboard는 맨 앞에 넣는다)
            for item in items.reversed() { store.saveToPinboard(item, boardID: id) }
        }
    }
}

/// 띠 위쪽의 최근·고정·계정 탭.
struct BarTabs: View {
    @ObservedObject private var mode = BarMode.shared
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var accounts = AccountStore.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BarTab.allCases, id: \.self) { tab in
                Button { mode.select(tab) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(verbatim: tab.title).font(.system(size: 12.5, weight: .medium))
                        if let count = count(tab), count > 0 {
                            Text(verbatim: "\(count)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.chromeTextTertiary)
                        }
                    }
                    .foregroundStyle(mode.tab == tab ? Theme.chromeTextPrimary : Theme.chromeTextSecondary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(mode.tab == tab ? Theme.pillSelected : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(tab.title) (⌘← ⌘→로 옮기기)")
            }
        }
        .padding(2)
        .background(Theme.pillBG, in: Capsule())
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: mode.tab)
    }

    private func count(_ tab: BarTab) -> Int? {
        switch tab {
        case .recent: return nil
        case .pinned: return store.pinboards.first?.items.count
        case .accounts: return accounts.accounts.count
        }
    }
}

/// 종류 거르기. 늘 떠 있던 칩 줄 대신 작은 메뉴 하나로 둔다.
struct TypeFilterMenu: View {
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        let counts = store.typeCounts
        Menu {
            Button { store.typeFilter = nil } label: {
                Label("모든 종류", systemImage: store.typeFilter == nil ? "checkmark" : "square.grid.2x2")
            }
            Divider()
            ForEach(ClipType.allCases, id: \.self) { type in
                Button { store.typeFilter = store.typeFilter == type ? nil : type } label: {
                    Label("\(type.label) \(counts[type, default: 0])", systemImage: store.typeFilter == type ? "checkmark" : type.symbol)
                }
                .disabled(counts[type, default: 0] == 0 && store.typeFilter != type)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.typeFilter?.symbol ?? "line.3.horizontal.decrease")
                    .font(.system(size: 12.5, weight: .semibold))
                if let type = store.typeFilter {
                    Text(verbatim: type.label).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(store.typeFilter == nil ? Theme.chromeTextSecondary : Theme.chromeTextPrimary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(store.typeFilter == nil ? Color.clear : Theme.pillSelected, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("종류로 거르기 (⇧⌘F)")
    }
}

/// 띠 키 가운데 RunTime이 더한 것. Pesty 키 처리보다 먼저 본다.
@MainActor
enum BarKeys {
    /// 처리했으면 true.
    static func handle(_ event: NSEvent, searchOwns: Bool) -> Bool {
        let mode = BarMode.shared
        let store = ClipboardStore.shared
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

        if mode.tab == .accounts {
            return handleAccounts(code: code, flags: flags, event: event, searchOwns: searchOwns)
        }
        // ⌘P 고정, ⌘Y 미리보기. 검색창이 키를 갖고 있어도 듣는다
        guard flags == .command, code == kVK_ANSI_P || code == kVK_ANSI_Y else { return false }
        let selection = store.selectedItems
        guard let first = selection.first else { return true }
        if code == kVK_ANSI_P { Pinned.toggle(selection) } else { AppController.shared.showPreview(for: first) }
        return true
    }

    private static func handleAccounts(code: Int, flags: NSEvent.ModifierFlags, event: NSEvent, searchOwns: Bool) -> Bool {
        let mode = BarMode.shared
        if flags == .command, code == kVK_ANSI_N { AccountEditor.add(); return true }
        if let digit = digit(code), includes(Settings.shared.quickPasteModifier, in: event.modifierFlags) {
            let list = mode.visibleAccounts
            if digit <= list.count { AccountFill.fill(list[digit - 1]) }
            return true
        }
        // 검색창이 키를 가지면 ↩와 화살표는 검색창이 돌려보낸다 (pasteSelected, moveSelection)
        if searchOwns { return false }
        let account = mode.selectedAccount
        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let account { AccountFill.fill(account, part: flags.contains(.shift) ? .password : .auto) }
            return true
        case kVK_LeftArrow, kVK_UpArrow:
            // ⌘←는 탭 옮기기 (moveBarSection)
            if flags.contains(.command) { return false }
            mode.moveAccount(by: -1); return true
        case kVK_RightArrow, kVK_DownArrow:
            if flags.contains(.command) { return false }
            mode.moveAccount(by: 1); return true
        case kVK_Delete, kVK_ForwardDelete:
            // 검색어가 있으면 ⌫는 검색어를 지운다 (Pesty 처리로 넘긴다)
            if code == kVK_Delete, !ClipboardStore.shared.searchText.isEmpty { return false }
            // 눌러 둔 ⌫가 반복되어 확인 창을 띄우지 않게 한다
            if event.isARepeat { return true }
            if let account { AccountEditor.confirmDelete(account) }
            return true
        case kVK_ANSI_C where flags == .command:
            if let account { AccountActions.copyPassword(account) }
            return true
        case kVK_ANSI_C where flags == [.command, .shift]:
            if let account { AccountActions.copyUsername(account) }
            return true
        case kVK_ANSI_E where flags == .command:
            if let account { AccountEditor.edit(account) }
            return true
        case kVK_ANSI_P, kVK_ANSI_Y, kVK_ANSI_Z:
            // 클립에만 쓰는 키다. 계정 탭에서는 아무것도 하지 않는다
            return flags == .command
        default:
            return false
        }
    }

    /// 검색창에서 ↩를 눌렀을 때 (AppController.pasteSelected). 계정 탭이면 계정을 넣는다.
    static func submitFromSearch() -> Bool {
        let mode = BarMode.shared
        guard mode.tab == .accounts else { return false }
        if let account = mode.selectedAccount {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            AccountFill.fill(account, part: shift ? .password : .auto)
        }
        return true
    }

    /// 검색창의 화살표.
    static func moveSelection(by delta: Int) {
        if BarMode.shared.tab == .accounts { BarMode.shared.moveAccount(by: delta) } else { ClipboardStore.shared.moveSelection(by: delta) }
    }

    /// ⌘← ⌘→: 최근 → 고정 → 계정.
    static func moveTab(by delta: Int) {
        let all = BarTab.allCases
        let next = (BarMode.shared.tab.rawValue + delta + all.count) % all.count
        BarMode.shared.select(all[next])
    }

    private static func digit(_ code: Int) -> Int? {
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let pad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                   kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        if let i = codes.firstIndex(of: code) { return i + 1 }
        if let i = pad.firstIndex(of: code) { return i + 1 }
        return nil
    }

    private static func includes(_ carbon: Int, in flags: NSEvent.ModifierFlags) -> Bool {
        switch carbon {
        case cmdKey: return flags.contains(.command)
        case optionKey: return flags.contains(.option)
        case controlKey: return flags.contains(.control)
        case shiftKey: return flags.contains(.shift)
        default: return false
        }
    }
}
