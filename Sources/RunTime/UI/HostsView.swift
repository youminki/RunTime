import HostsCore
import SwiftUI

/// 호스트 화면 상태. 이 툴체인은 SwiftUI 매크로(@State)를 못 써서 모델에 둔다.
@MainActor
final class HostsPage: ObservableObject {
    static let shared = HostsPage()

    enum Sheet: Identifiable {
        /// 묶음 메뉴에서 열면 그 묶음을 미리 골라 둔다.
        case add(group: String?)
        case edit(HostsFile.Item)
        /// 저장하기 전에 바뀌는 줄을 보여 준다. `text`가 저장할 글 전체, `base`는 그때 디스크 판.
        case preview(title: String, text: String, base: String)
        case backups
        /// 묶음의 주소를 한 번에 바꾼다.
        case switchIP(HostsFile.Section)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let item): return "edit-\(item.id)"
            case .preview(let title, _, _): return "preview-\(title)"
            case .backups: return "backups"
            case .switchIP(let section): return "switch-\(section.id)"
            }
        }
    }

    @Published var search = ""
    @Published var collapsed: Set<String> = []
    @Published var sheet: Sheet?
    @Published var toast: String?
    /// 이름 → 맥이 실제로 푸는 주소. 확인을 누른 이름만.
    @Published var resolved: [String: [String]] = [:]
    /// 살펴볼 곳이 많으면 3개만 보이고 접어 둔다. 목록이 화면 아래로 밀리지 않게.
    @Published var showAllIssues = false
    private var toastWork: DispatchWorkItem?

    func flash(_ message: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }
}

/// /etc/hosts를 묶음별로 보고 켜고 끈다. 고친 것은 모았다가 아래 막대의 저장으로 한 번에 쓴다.
struct HostsView: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage
    @FocusState private var searching: Bool

    var body: some View {
        SlimScrollView {
            // 수천 줄 hosts에서도 보이는 줄만 그리게 지연 목록으로 둔다 (묶음 머리와 줄을 한 단계로 펼쳐 넣는다)
            LazyVStack(alignment: .leading, spacing: 0) {
                heading
                notices
                if !issues.isEmpty { issueList }
                searchField
                if sections.isEmpty {
                    Callout {
                        Text(page.search.isEmpty ? "등록한 호스트가 없습니다. 추가를 눌러 넣으세요." : "‘\(page.search)’에 맞는 호스트가 없습니다.")
                            .font(.system(size: 12.5)).foregroundStyle(WL.muted)
                    }
                    .padding(.top, 12)
                }
                let keys = collapseKeys
                ForEach(sections) { section in sectionView(section, key: keys[section.id] ?? section.id) }
                    .disabled(!store.canEdit)
            }
            .id(store.generation)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, store.dirty ? 80 : 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .bottom) { saveBar }
        .overlay(alignment: .bottom) {
            if let toast = page.toast { Toast(message: toast).padding(.bottom, store.dirty ? 70 : 18).transition(.opacity) }
        }
        .sheet(item: $page.sheet) { sheet in
            switch sheet {
            case .add(let group): HostsAddSheet(store: store, page: page, group: group)
            case .edit(let item): HostsEditSheet(store: store, page: page, item: item)
            case .preview(let title, let text, let base): HostsPreviewSheet(store: store, page: page, title: title, text: text, base: base)
            case .backups: HostsBackupSheet(store: store, page: page)
            case .switchIP(let section): HostsSwitchSheet(store: store, page: page, section: section)
            }
        }
        // 파일이 바뀌면 맥의 이름 풀이도 바뀌었을 수 있어 지난 확인 결과를 지운다
        .onChange(of: store.saved.text) { _ in page.resolved = [:] }
        .onAppear { store.setWatching(true) }
        .onDisappear { store.setWatching(false) }
    }

    /// 직접 볼 경고, 정리하면 고쳐지는 것, 참고 순. 접어 둘 때 중요한 것이 먼저 보이게.
    private var issues: [HostsIssue] {
        let rank: (HostsIssue) -> Int = { $0.isNotice ? 2 : $0.fixable ? 1 : 0 }
        return store.issues.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private var sections: [HostsFile.Section] {
        let query = page.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.sections }
        return store.sections.compactMap { section in
            var section = section
            let titleMatches = section.title?.lowercased().contains(query) == true
            if !titleMatches {
                section.items = section.items.filter {
                    $0.name.lowercased().contains(query) || $0.ip.contains(query) || $0.note?.lowercased().contains(query) == true
                }
            }
            return section.items.isEmpty ? nil : section
        }
    }

    // MARK: 머리

    private var heading: some View {
        let items = store.sections.flatMap(\.items)
        return PageHeading("호스트") {
            Tally(title: "켜짐", value: items.filter(\.enabled).count, tint: WL.done)
            Tally(title: "꺼짐", value: items.filter { !$0.enabled }.count, tint: WL.quiet)
            Text("묶음 \(store.sections.count)개").monospacedDigit()
        } accessory: {
            HStack(spacing: 8) {
                let fixable = issues.filter(\.fixable).count
                if store.canEdit, store.organizedText != store.draft.text {
                    HeadingAction(title: fixable > 0 ? "정리 · 문제 \(fixable)개 고침" : "정리", icon: "wand.and.stars",
                                  tint: fixable > 0 ? WL.waiting : WL.accent) {
                        page.sheet = .preview(title: "정리", text: store.organizedText, base: store.saved.text)
                    }
                    .tip("겹친 줄을 지우고 묶음별로 한 이름에 한 줄씩 다시 씁니다. 저장하기 전에 바뀌는 줄을 보여 줍니다")
                }
                Button { page.sheet = .backups } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("백업에서 되돌리기")
                    .buttonStyle(SquareIconButtonStyle(size: 28))
                    .tip("백업에서 되돌리기 · 저장할 때마다 이전 판을 20개까지 남깁니다")
                Button { page.sheet = .add(group: nil) } label: { Label("추가", systemImage: "plus") }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .disabled(!store.canEdit)
                    .keyboardShortcut("n", modifiers: .command)
                    .tip("호스트 추가 (⌘N) · 메신저·위키에서 받은 여러 줄을 그대로 붙여 넣어도 됩니다")
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let problem = store.problem {
            Callout { Text(problem).font(.system(size: 12.5)).foregroundStyle(WL.waiting) }.padding(.bottom, 12)
        }
        if store.canEdit, !store.expired.isEmpty {
            Callout {
                HStack {
                    Text("기한이 지난 항목 \(store.expired.count)개가 켜져 있습니다: \(store.expired.prefix(3).map(\.name).joined(separator: ", "))\(store.expired.count > 3 ? " 외" : "")")
                        .font(.system(size: 12.5)).foregroundStyle(WL.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("모두 끄기") { store.draft.setEnabled(store.expired, false) }.buttonStyle(NotionButtonStyle())
                        .tip("끈 뒤 아래에서 저장하면 파일에 씁니다")
                }
            }
            .padding(.bottom, 12)
        }
        if store.changedOutside {
            Callout {
                HStack {
                    Text("고치는 동안 다른 곳에서 파일이 바뀌었습니다. 지금 고친 것을 저장하면 그 변경을 덮어씁니다.")
                        .font(.system(size: 12.5)).foregroundStyle(WL.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("바뀐 파일 보기") { store.discard() }.buttonStyle(NotionButtonStyle())
                        .tip("고친 것을 버리고 지금 파일을 다시 보입니다")
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var issueList: some View {
        Callout {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("살펴볼 곳 \(issues.count)개").font(WL.heading)
                    let fixable = issues.filter(\.fixable).count
                    if fixable > 0 { Text("\(fixable)개는 정리하면 고쳐집니다").font(WL.caption).foregroundStyle(WL.muted) }
                    Spacer()
                    if issues.count > 3 {
                        Button(page.showAllIssues ? "접기" : "\(issues.count - 3)개 더 보기") { page.showAllIssues.toggle() }
                            .buttonStyle(TextLinkButtonStyle())
                    }
                }
                ForEach(page.showAllIssues ? issues : Array(issues.prefix(3))) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: issue.isNotice ? "info.circle" : issue.fixable ? "wand.and.stars" : "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(issue.isNotice ? WL.muted : WL.waiting)
                            .frame(width: 14)
                        Text("\(issue.line + 1)번째 줄").font(WL.number).foregroundStyle(WL.muted)
                        Text(issue.message).font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)

                    }
                }
            }
        }
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WL.quiet)
            TextField("이름, 주소, 묶음, 메모로 찾기 (⌘F)", text: $page.search).textFieldStyle(.plain).font(WL.body)
                .focused($searching)
                .onExitCommand { page.search = ""; searching = false }
            if !page.search.isEmpty {
                Button { page.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(WL.quiet)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .wlSurface(radius: 6)
        .background {
            // 어느 칸에 있든 ⌘F로 찾기 칸에 들어간다
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .padding(.bottom, 8)
    }

    // MARK: 묶음

    /// 접힘을 기억할 키. 같은 이름 묶음이 여럿이면 순번을 붙여 하나만 접히게 한다.
    private var collapseKeys: [String: String] {
        var seen: [String: Int] = [:]
        var keys: [String: String] = [:]
        for section in store.sections {
            let base = section.title ?? "묶음 없음"
            let count = seen[base, default: 0] + 1
            seen[base] = count
            keys[section.id] = count == 1 ? base : "\(base) #\(count)"
        }
        return keys
    }

    /// 묶음 머리와 줄들. Group으로 감싸 지연 목록에 줄 하나하나가 따로 들어가게 한다.
    @ViewBuilder
    private func sectionView(_ section: HostsFile.Section, key: String) -> some View {
        let collapsed = page.collapsed.contains(key) && page.search.isEmpty
        let allOn = section.items.allSatisfy(\.enabled)
        Group {
            ToggleHeading(collapsed: collapsed, toggle: {
                if page.collapsed.contains(key) { page.collapsed.remove(key) } else { page.collapsed.insert(key) }
            }) {
                HStack(spacing: 8) {
                    Text(section.title ?? "묶음 없음").font(WL.section).foregroundStyle(section.title == nil ? WL.muted : WL.text)
                    Text("\(section.items.filter(\.enabled).count)/\(section.items.count)").font(WL.number).foregroundStyle(WL.quiet)
                    // 묶음이 어느 서버를 보는지 한눈에 (환경 전환 뒤 바로 확인하게)
                    let addresses = Array(NSOrderedSet(array: section.items.filter(\.enabled).map(\.ip))) as? [String] ?? []
                    if !addresses.isEmpty {
                        Text(addresses.prefix(2).joined(separator: ", ") + (addresses.count > 2 ? " 외 \(addresses.count - 2)" : ""))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(WL.muted)
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(Capsule().fill(WL.hover))
                    }
                }
            } trailing: {
                HStack(spacing: 10) {
                    Button(allOn ? "모두 끄기" : "모두 켜기") { store.draft.setEnabled(section.items, !allOn) }
                        .buttonStyle(TextLinkButtonStyle())
                    Menu {
                        sectionActions(section, allOn: allOn)
                    } label: {
                        Image(systemName: "ellipsis").accessibilityLabel("묶음 메뉴")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .tip("이 묶음에 추가, 주소 바꾸기, 글로 복사")
                }
            }
            // 올렸을 때만 보이는 단추는 키보드·손쉬운 사용으로 닿지 않아, 오른쪽 클릭과 손쉬운 사용 동작으로도 둔다
            .contextMenu { sectionActions(section, allOn: allOn) }
            .accessibilityAction(named: allOn ? "모두 끄기" : "모두 켜기") { store.draft.setEnabled(section.items, !allOn) }
            .accessibilityAction(named: "이 묶음에 추가") { page.sheet = .add(group: section.title) }
            .accessibilityAction(named: "주소 한 번에 바꾸기") { page.sheet = .switchIP(section) }
            .accessibilityAction(named: "글로 복사") { copy(section) }
            .padding(.top, 10)
            if !collapsed {
                // 줄 번호만으로 구분하면 다른 파일을 읽은 뒤 같은 번호의 옛 줄 화면이 남아, 주소·이름까지 넣어 구분한다
                ForEach(section.items, id: \.rowKey) { item in
                    VStack(spacing: 0) {
                        HostRow(store: store, page: page, item: item)
                        if item.id != section.items.last?.id { RowDivider(inset: 50) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionActions(_ section: HostsFile.Section, allOn: Bool) -> some View {
        Button(allOn ? "모두 끄기" : "모두 켜기") { store.draft.setEnabled(section.items, !allOn) }
        Button("이 묶음에 추가…") { page.sheet = .add(group: section.title) }
        Button("주소 한 번에 바꾸기…") { page.sheet = .switchIP(section) }
        Button("글로 복사 (팀원에게 보내기)") { copy(section) }
    }

    private func copy(_ section: HostsFile.Section) {
        guard section.items.contains(where: \.enabled) else { return page.flash("켜 둔 줄이 없어 복사하지 않았습니다") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HostsFile.exportText(title: section.title, items: section.items), forType: .string)
        page.flash("켜 둔 \(section.items.filter(\.enabled).count)줄을 복사했습니다. 받는 사람은 추가에 그대로 붙여 넣으면 됩니다")
    }

    // MARK: 저장 막대

    @ViewBuilder
    private var saveBar: some View {
        if store.dirty {
            let count = store.changedLines
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(WL.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("저장하지 않은 변경 \(count)줄").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    Text(HostsStore.url.path == "/etc/hosts" ? "저장하면 관리자 암호를 묻고 이전 판은 백업합니다" : "시험용 파일에 씁니다")
                        .font(WL.caption).foregroundStyle(WL.muted)
                }
                Spacer()
                Button("되돌리기") { store.discard() }.buttonStyle(NotionButtonStyle())
                Button("저장…") { page.sheet = .preview(title: "저장", text: store.draft.text, base: store.saved.text) }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(store.saving)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WL.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            .frame(maxWidth: 760)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - 줄

private extension HostsFile.Item {
    var rowKey: String { "\(line)-\(slot)-\(ip)-\(name)" }
}

private struct HostRow: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage
    let item: HostsFile.Item
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { item.enabled }, set: { store.draft.setEnabled(item, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .tip(item.enabled ? "끄기 (주석으로 남깁니다)" : "켜기")
                .accessibilityLabel("\(item.name) \(item.enabled ? "켜짐" : "꺼짐")")
            Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(item.enabled ? WL.text : WL.faint)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            // 기한은 오른쪽 표시로 보이니 메모에서는 뺀다
            if let note = HostsFile.note(item.note, until: nil) { Text(note).font(WL.caption).foregroundStyle(WL.quiet).lineLimit(1) }
            if let expiry = item.expiry {
                // 꺼 둔 줄은 할 일이 없어 지났어도 날짜만 옅게 보인다
                let past = item.enabled && expiry < HostsStore.today()
                DayBadge(text: past ? "기한 지남" : "~\(expiry.dropFirst(5))", tint: past ? WL.waiting : WL.muted)
                    .tip("\(expiry)까지만 켜 둡니다. 지나면 알려 드립니다")
            }
            Spacer(minLength: 8)
            if let addresses = page.resolved[item.name] { resolution(addresses) }
            Text(item.ip).font(.system(size: 12, design: .monospaced)).foregroundStyle(item.enabled ? WL.muted : WL.faint)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            HStack(spacing: 2) {
                Button { check() } label: { Image(systemName: "checkmark.shield") }
                    .tip("맥이 이 이름을 실제로 어디로 푸는지 확인 (VPN·DNS 포함)")
                    .accessibilityLabel("\(item.name) 이름 풀이 확인")
                Button { open() } label: { Image(systemName: "safari") }
                    .tip("브라우저로 열기 (http://\(item.name))")
                    .accessibilityLabel("\(item.name) 브라우저로 열기")
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .tip("‘\(item.ip) \(item.name)’ 복사")
                    .accessibilityLabel("\(item.name) 복사")
                Button { page.sheet = .edit(item) } label: { Image(systemName: "pencil") }
                    .tip("고치기·지우기")
                    .accessibilityLabel("\(item.name) 고치기·지우기")
            }
            .buttonStyle(GhostIconButtonStyle())
            .opacity(hover.on ? 1 : 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 34)
        .contentShape(Rectangle())
        .hoverRow()
        .onHover { hover.on = $0 }
        // 고치기 단추는 올려야 보여서, 줄을 두 번 눌러도 열리게 한다
        .onTapGesture(count: 2) { page.sheet = .edit(item) }
        // 올렸을 때만 보이는 단추를 오른쪽 클릭과 손쉬운 사용 동작으로도 쓸 수 있게
        .contextMenu {
            Button("이름 풀이 확인") { check() }
            Button("브라우저로 열기") { open() }
            Button("복사") { copy() }
            Divider()
            Button("고치기·지우기…") { page.sheet = .edit(item) }
        }
        .accessibilityAction(named: "이름 풀이 확인") { check() }
        .accessibilityAction(named: "브라우저로 열기") { open() }
        .accessibilityAction(named: "복사") { copy() }
        .accessibilityAction(named: "고치기·지우기") { page.sheet = .edit(item) }
    }

    private func resolution(_ addresses: [String]) -> some View {
        let matches = addresses.contains(item.ip)
        let text = addresses.isEmpty ? "풀리지 않음" : matches ? "맥도 \(item.ip)로 풂" : "맥은 \(addresses.joined(separator: ", "))로 풂"
        return Text(text).font(WL.caption).foregroundStyle(matches ? WL.done : WL.waiting).lineLimit(1)
    }

    private func check() {
        let name = item.name
        HostsStore.resolve(name) { addresses in
            MainActor.assumeIsolated { page.resolved[name] = addresses }
        }
    }

    private func open() {
        if let url = URL(string: "http://\(item.name)") { NSWorkspace.shared.open(url) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(item.ip) \(item.name)", forType: .string)
        page.flash("복사했습니다")
    }
}

// MARK: - 추가

/// 화면 점검(--ui-shots)용. 창은 시트로만 떠서 따로 꺼내 찍는다.
@MainActor
enum HostsSheetShots {
    static func add(_ text: String, group: String?) -> some View {
        HostsAddSheet(store: .shared, page: HostsPage(), group: group, text: text).background(WL.canvas)
    }

    static func edit() -> some View {
        let item = HostsStore.shared.sections.flatMap(\.items).first { $0.expiry != nil } ?? HostsStore.shared.sections.flatMap(\.items).first
        return Group { if let item { HostsEditSheet(store: .shared, page: HostsPage(), item: item).background(WL.canvas) } }
    }
}


@MainActor
private final class HostsAddForm: ObservableObject {
    @Published var text = ""
    @Published var group: String
    @Published var stamp = true
    @Published var limited = false
    @Published var until = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    /// 같은 이름을 다른 주소로 켜 둔 줄을 끈다. 끄지 않으면 어느 쪽으로 풀릴지 모른다.
    @Published var turnOffOld = true

    init(group: String, text: String) {
        self.group = group
        self.text = text
    }
}

private struct HostsAddSheet: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage
    @StateObject private var form: HostsAddForm
    @FocusState private var typing: Bool

    init(store: HostsStore, page: HostsPage, group: String?, text: String = "") {
        self.store = store
        self.page = page
        _form = StateObject(wrappedValue: HostsAddForm(group: group ?? "", text: text))
    }

    var body: some View {
        let parsed = HostsFile.records(fromPasted: form.text)
        let plan = store.draft.additionPlan(parsed.records)
        let groups = Array(Set(store.sections.compactMap(\.title))).sorted()
        let group = form.group.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("호스트 추가").font(WL.title)
                Spacer()
                if form.text.isEmpty, let lines = clipboardLines {
                    Button { form.text = lines.text } label: { Label("클립보드의 \(lines.count)줄 넣기", systemImage: "doc.on.clipboard") }
                        .buttonStyle(TextLinkButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $form.text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .focused($typing)
                    if form.text.isEmpty {
                        Text("10.0.1.20  api.dev.example.com\n10.0.1.20  admin.dev.example.com web.dev.example.com")
                            .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(WL.quiet)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 110)
                .padding(4)
                .wlSurface(radius: 6)
                Text("한 줄에 주소와 이름. 이름은 여럿 적어도 되고, 받은 hosts 줄을 그대로 붙여 넣어도 됩니다.")
                    .font(WL.caption).foregroundStyle(WL.muted)
                if !parsed.skipped.isEmpty {
                    Text("읽지 못한 줄 \(parsed.skipped.count)개: \(parsed.skipped.prefix(3).joined(separator: ", "))")
                        .font(WL.caption).foregroundStyle(WL.waiting).lineLimit(2)
                }
            }
            if !plan.entries.isEmpty { planList(plan) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("묶음").font(WL.label).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                    TextField("비우면 묶음 없이", text: $form.group).textFieldStyle(.roundedBorder).frame(width: 220)
                    if !group.isEmpty, !groups.contains(group) {
                        Text("새 묶음을 파일 끝에 만듭니다").font(WL.caption).foregroundStyle(WL.quiet)
                    }
                }
                if !groups.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(groups, id: \.self) { name in
                            Button(name) { form.group = group == name ? "" : name }
                                .buttonStyle(ChipButtonStyle(selected: group == name)).fixedSize()
                        }
                    }
                    .padding(.leading, 44)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("메모에 추가한 날짜 남기기", isOn: $form.stamp).font(WL.meta)
                HStack(spacing: 8) {
                    Toggle("이날까지만 쓰기", isOn: $form.limited).font(WL.meta)
                    DatePicker("", selection: $form.until, in: Date()..., displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field).fixedSize()
                        .disabled(!form.limited)
                    Text("지나면 알리고 한 번에 끌 수 있게 합니다").font(WL.caption).foregroundStyle(WL.quiet)
                }
            }
            HStack {
                Spacer()
                Button("취소") { page.sheet = nil }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
                Button(plan.count > 0 ? "\(plan.count)개 추가" : "추가") { add(plan) }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.count == 0)
            }
        }
        .padding(22)
        .frame(width: 560)
        .foregroundStyle(WL.text)
        .onAppear { DispatchQueue.main.async { typing = true } }
    }

    /// 읽은 이름마다 무엇을 할지. 이미 있는 이름이나 다른 주소로 켜 둔 이름을 넣기 전에 보여 준다.
    private func planList(_ plan: HostsFile.AddPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.ip).font(.system(size: 12, design: .monospaced)).foregroundStyle(WL.muted)
                                .frame(width: 130, alignment: .leading)
                            Text(entry.name).font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(entry.status == .exists ? WL.faint : WL.text)
                                .lineLimit(1).truncationMode(.middle)
                            if !entry.enabled { Text("꺼 둔 채").font(WL.caption).foregroundStyle(WL.quiet) }
                            Spacer(minLength: 8)
                            status(entry.status)
                        }
                        .frame(height: 24)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(plan.entries.count) * 24 + 8, 128))
            .wlSurface(radius: 6)
            if !plan.conflicting.isEmpty {
                Toggle("같은 이름을 다른 주소로 켜 둔 줄 \(plan.conflicting.count)개 끄기", isOn: $form.turnOffOld).font(WL.meta)
                    .tip("hosts는 같은 이름이 둘 켜져 있으면 어느 쪽으로 풀릴지 장담할 수 없습니다")
            }
        }
    }

    private func status(_ status: HostsFile.AddPlan.Status) -> some View {
        let (text, tint): (String, Color) = switch status {
        case .new: ("새로", WL.done)
        case .exists: ("이미 있음", WL.faint)
        case .reenable: ("꺼진 줄 켜기", WL.accent)
        case .conflict(let ip): ("\(ip)로 켜져 있음", WL.waiting)
        }
        return Text(text).font(WL.caption).foregroundStyle(tint).lineLimit(1)
    }

    /// 클립보드에 hosts 줄이 있으면 그 글. 메신저에서 복사하고 창을 열었을 때 바로 넣게.
    private var clipboardLines: (text: String, count: Int)? {
        guard let text = NSPasteboard.general.string(forType: .string), text.count < 100_000 else { return nil }
        let count = HostsFile.records(fromPasted: text).records.count
        return count > 0 ? (text, count) : nil
    }

    private func add(_ plan: HostsFile.AddPlan) {
        let day = HostsStore.today()
        let until = HostsStore.day(form.until)
        let stamped = plan.records.map { record -> HostsFile.Record in
            var record = record
            if record.note == nil, form.stamp { record.note = "\(day) 추가" }
            if form.limited { record.note = HostsFile.note(record.note, until: until) }
            return record
        }
        if form.turnOffOld { store.draft.setEnabled(plan.conflicting, false) }
        store.draft.setEnabled(plan.reenable, true)
        store.draft.add(stamped, to: form.group)
        page.sheet = nil
        page.flash("\(plan.count)개를 추가했습니다. 아래에서 저장하면 파일에 씁니다")
    }
}

// MARK: - 고치기

@MainActor
private final class HostsEditForm: ObservableObject {
    @Published var ip: String
    @Published var name: String
    /// 기한을 뺀 메모. 기한은 따로 고른다.
    @Published var note: String
    @Published var group: String
    @Published var limited: Bool
    @Published var until: Date
    @Published var turnOffOthers = true

    init(_ item: HostsFile.Item, group: String) {
        ip = item.ip
        name = item.name
        note = HostsFile.note(item.note, until: nil) ?? ""
        self.group = group
        limited = item.expiry != nil
        until = item.expiry.flatMap(HostsStore.date) ?? Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    }
}

private struct HostsEditSheet: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage
    let item: HostsFile.Item
    /// 연 때의 묶음 이름. 비어 있으면 묶음 없음.
    private let group: String
    @StateObject private var form: HostsEditForm

    init(store: HostsStore, page: HostsPage, item: HostsFile.Item) {
        self.store = store
        self.page = page
        self.item = item
        let id = item.id
        let group = store.sections.first { $0.items.contains { $0.id == id } }?.title ?? ""
        self.group = group
        _form = StateObject(wrappedValue: HostsEditForm(item, group: group))
    }

    var body: some View {
        let ip = form.ip.trimmingCharacters(in: .whitespaces)
        let name = form.name.trimmingCharacters(in: .whitespaces)
        let note = newNote
        let problem = !HostsFile.isIP(ip) ? "주소가 올바르지 않습니다 (예: 192.168.0.10)"
            : !HostsFile.isHostname(name) ? "이름에는 영문, 숫자, 점(.), 붙임표(-)만 씁니다" : nil
        let others = item.enabled && problem == nil ? store.draft.conflicts(name: name, ip: ip, except: item) : []
        let unchanged = ip == item.ip && name == item.name && note == item.note && form.group == group
        let groups = Array(Set(store.sections.compactMap(\.title) + [group].filter { !$0.isEmpty })).sorted()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("호스트 고치기").font(WL.title)
                if !item.enabled { DayBadge(text: "꺼짐", tint: WL.muted) }
            }
            field("주소", text: $form.ip, placeholder: "192.168.0.10")
            field("이름", text: $form.name, placeholder: "api.example.com")
            HStack(spacing: 10) {
                label("묶음")
                Picker("", selection: $form.group) {
                    Text("묶음 없음").tag("")
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                if form.group != group { Text("옮기면 그 묶음 끝에 넣습니다").font(WL.caption).foregroundStyle(WL.quiet) }
            }
            field("메모", text: $form.note, placeholder: "없음")
            HStack(spacing: 10) {
                label("기한")
                Toggle("이날까지만 쓰기", isOn: $form.limited).font(WL.meta)
                DatePicker("", selection: $form.until, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).fixedSize()
                    .disabled(!form.limited)
            }
            if let problem { Text(problem).font(WL.caption).foregroundStyle(WL.waiting) }
            if let other = others.first {
                Toggle("같은 이름을 \(other.ip)로 켜 둔 \(other.line + 1)번째 줄\(others.count > 1 ? " 외 \(others.count - 1)개" : "") 끄기",
                       isOn: $form.turnOffOthers)
                    .font(WL.meta)
                    .tip("hosts는 같은 이름이 둘 켜져 있으면 어느 쪽으로 풀릴지 장담할 수 없습니다")
            }
            HStack {
                Button("지우기", role: .destructive) {
                    store.draft.remove(item)
                    page.sheet = nil
                    page.flash("‘\(item.name)’을 지웠습니다. 저장하기 전에는 되돌리기로 살릴 수 있습니다")
                }
                .buttonStyle(NotionButtonStyle())
                Spacer()
                Button("취소") { page.sheet = nil }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
                Button("바꾸기") { apply(ip: ip, name: name, note: note, others: others) }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || (unchanged && (others.isEmpty || !form.turnOffOthers)))
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 460)
        .foregroundStyle(WL.text)
    }

    private var newNote: String? {
        let text = form.note.trimmingCharacters(in: .whitespaces)
        return HostsFile.note(text.isEmpty ? nil : text, until: form.limited ? HostsStore.day(form.until) : nil)
    }

    private func apply(ip: String, name: String, note: String?, others: [HostsFile.Item]) {
        if form.turnOffOthers { store.draft.setEnabled(others, false) }
        if form.group == group {
            store.draft.update(item, ip: ip, name: name, note: note)
        } else {
            store.draft.remove(item)
            store.draft.add([.init(ip: ip, names: [name], enabled: item.enabled, note: note)], to: form.group)
        }
        page.sheet = nil
    }

    private func label(_ title: String) -> some View {
        Text(title).font(WL.label).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            label(title)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
        }
    }
}

// MARK: - 미리 보기

private struct HostsPreviewSheet: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage
    let title: String
    let text: String
    let base: String

    /// 바뀐 줄 앞뒤 2줄만 보이고 나머지 같은 줄은 접는다.
    private enum Row: Identifiable {
        case change(LineDiff.Change)
        case folded(id: Int, count: Int)

        var id: Int {
            switch self {
            case .change(let change): return change.id
            case .folded(let id, _): return -1 - id
            }
        }
    }

    var body: some View {
        let changes = LineDiff.changes(from: base, to: text)
        let added = changes.filter { $0.kind == .added }.count
        let removed = changes.filter { $0.kind == .removed }.count
        VStack(alignment: .leading, spacing: 12) {
            Text(title == "정리" ? "정리한 내용 확인" : title == "백업" ? "백업으로 되돌리기" : "저장할 내용 확인").font(WL.title)
            HStack(spacing: 14) {
                Tally(title: "더함", value: added, tint: WL.done)
                Tally(title: "뺌", value: removed, tint: WL.waiting)
                Text("저장하기 전 판은 백업에 남습니다").foregroundStyle(WL.quiet)
            }
            .font(.system(size: 12.5))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(changes)) { row in
                        switch row {
                        case .change(let change): line(change)
                        case .folded(_, let count):
                            Text("⋯ 같은 줄 \(count)개").font(WL.caption).foregroundStyle(WL.quiet).padding(.vertical, 3).padding(.leading, 26)
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 380)
            .wlSurface(radius: 6)
            HStack {
                // macOS는 앱이 준 안내 대신 "스크립트에 대해 관리자 접근 권한을 허용하겠습니까?"라고 묻는다. 놀라지 않게 미리 알린다
                Text(HostsStore.url.path == "/etc/hosts"
                     ? "저장하면 macOS가 ‘RunTime이 시작한 스크립트에 관리자 접근 권한을 허용할지’ 묻습니다. /etc/hosts만 바꾸고 DNS 캐시를 비우는 명령입니다."
                     : "시험용 파일 \(HostsStore.url.path)에 씁니다.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(WL.caption).foregroundStyle(WL.muted)
                Spacer()
                Button("취소") { page.sheet = nil }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
                Button(store.saving ? "저장하는 중…" : "저장") { save() }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.saving || added + removed == 0)
            }
        }
        .padding(22)
        .frame(width: 640)
        .foregroundStyle(WL.text)
    }

    private func rows(_ changes: [LineDiff.Change]) -> [Row] {
        let near = Set(changes.indices.filter { changes[$0].kind != .same }.flatMap { ($0 - 2)...($0 + 2) })
        var rows: [Row] = []
        var folded = 0
        for (index, change) in changes.enumerated() {
            if change.kind == .same, !near.contains(index) {
                folded += 1
                continue
            }
            if folded > 0 { rows.append(.folded(id: index, count: folded)); folded = 0 }
            rows.append(.change(change))
        }
        if folded > 0 { rows.append(.folded(id: changes.count, count: folded)) }
        return rows
    }

    private func line(_ change: LineDiff.Change) -> some View {
        let mark = change.kind == .added ? "+" : change.kind == .removed ? "−" : " "
        let tint = change.kind == .added ? WL.done : change.kind == .removed ? WL.waiting : Color.clear
        return HStack(spacing: 8) {
            Text(mark).frame(width: 12).foregroundStyle(change.kind == .same ? WL.faint : tint)
            Text(change.text.isEmpty ? " " : change.text).foregroundStyle(change.kind == .same ? WL.muted : WL.text)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.12))
    }

    private func save() {
        // 이 창을 연 뒤 파일이 바뀌었으면 옛 판으로 만든 글을 쓰지 않는다
        guard store.saved.text == base else {
            page.sheet = nil
            return page.flash("이 창을 연 뒤 파일이 바뀌었습니다. 다시 확인하고 저장하세요")
        }
        store.save(text) { failure in
            if let failure {
                if store.saved.text != base { page.sheet = nil }
                page.flash(failure)
            } else {
                page.sheet = nil
                page.flash(title == "정리" ? "정리해 저장했습니다" : "저장했습니다")
            }
        }
    }
}

// MARK: - 백업

private struct HostsBackupSheet: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage

    var body: some View {
        let backups = store.backupList
        VStack(alignment: .leading, spacing: 12) {
            Text("백업에서 되돌리기").font(WL.title)
            Text("저장할 때마다 저장하기 전 판을 남깁니다. 고르면 지금 파일과 다른 줄을 보여 주고, 저장해야 되돌립니다.")
                .font(WL.meta).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
            if backups.isEmpty {
                Callout { Text("아직 백업이 없습니다.").font(.system(size: 12.5)).foregroundStyle(WL.muted) }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(backups) { backup in
                            Button { open(backup) } label: {
                                HStack {
                                    Text(backup.date.formatted(date: .abbreviated, time: .standard)).font(WL.body).monospacedDigit()
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WL.quiet)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverRow()
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            HStack {
                Button("백업 폴더 열기") {
                    try? FileManager.default.createDirectory(at: HostsStore.backups, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(HostsStore.backups)
                }
                .buttonStyle(NotionButtonStyle())
                Spacer()
                Button("닫기") { page.sheet = nil }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .foregroundStyle(WL.text)
    }

    private func open(_ backup: HostsStore.Backup) {
        guard let text = try? String(contentsOf: backup.url, encoding: .utf8) else { return page.flash("백업을 읽지 못했습니다") }
        page.sheet = .preview(title: "백업", text: text, base: store.saved.text)
    }
}

// MARK: - 주소 바꾸기

@MainActor
private final class HostsSwitchForm: ObservableObject {
    /// 지금 주소 → 바꿀 주소.
    @Published var targets: [String: String] = [:]
}

/// 묶음 안 주소마다 새 주소를 넣어 한 번에 바꾼다. 묶음마다 최근에 쓴 주소를 눌러 넣을 수 있다.
private struct HostsSwitchSheet: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage
    let section: HostsFile.Section
    @StateObject private var form = HostsSwitchForm()

    var body: some View {
        let addresses = Array(NSOrderedSet(array: section.items.map(\.ip))) as? [String] ?? []
        let recent = store.recentIPs(for: section.title)
        let changes = addresses.compactMap { old -> (String, String)? in
            let new = (form.targets[old] ?? "").trimmingCharacters(in: .whitespaces)
            return new.isEmpty || new == old ? nil : (old, new)
        }
        let invalid = changes.contains { !HostsFile.isIP($0.1) }
        VStack(alignment: .leading, spacing: 14) {
            Text("‘\(section.title ?? "묶음 없음")’ 주소 바꾸기").font(WL.title)
            Text("개발·스테이징 서버를 오갈 때처럼, 이 묶음에서 같은 주소를 쓰는 이름을 한 번에 옮깁니다.")
                .font(WL.meta).foregroundStyle(WL.muted)
            ForEach(addresses, id: \.self) { old in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(old).font(.system(size: 12.5, design: .monospaced)).frame(width: 130, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WL.quiet)
                        TextField("새 주소", text: Binding(get: { form.targets[old] ?? "" }, set: { form.targets[old] = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                        Text("\(section.items.filter { $0.ip == old }.count)개").font(WL.number).foregroundStyle(WL.quiet)
                    }
                    let picks = recent.filter { $0 != old }
                    if !picks.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Text("최근").font(WL.caption).foregroundStyle(WL.quiet).frame(width: 130, height: 24, alignment: .trailing)
                            // 칩이 많아도 주소가 잘리지 않게 넘치면 다음 줄로 꺾는다
                            FlowLayout(spacing: 6) {
                                ForEach(picks, id: \.self) { ip in
                                    Button(ip) { form.targets[old] = ip }.buttonStyle(ChipButtonStyle(selected: form.targets[old] == ip))
                                        .fixedSize()
                                }
                            }
                        }
                    }
                }
            }
            if invalid { Text("주소가 올바르지 않습니다").font(WL.caption).foregroundStyle(WL.waiting) }
            HStack {
                Spacer()
                Button("취소") { page.sheet = nil }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
                Button("바꾸기") { apply(changes) }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(changes.isEmpty || invalid)
            }
        }
        .padding(22)
        .frame(width: 520)
        .foregroundStyle(WL.text)
    }

    private func apply(_ changes: [(String, String)]) {
        // 창을 연 뒤 파일이 바뀌었으면 지금 판에서 같은 묶음을 다시 찾는다
        guard let current = store.draft.section(matching: section) else {
            page.sheet = nil
            return page.flash("창을 연 뒤 묶음이 바뀌었습니다. 다시 열어 바꾸세요")
        }
        // 같은 묶음 안에서 A→B, B→A를 한 번에 바꿔도 섞이지 않게 바꾸기 전 항목으로 고른다
        let before = current.items
        for (old, new) in changes {
            store.draft.replaceIP(in: before.filter { $0.ip == old }, from: old, to: new)
        }
        store.remember(changes.flatMap { [$0.1, $0.0] }, for: section.title)
        page.sheet = nil
        page.flash("주소를 바꿨습니다. 아래에서 저장하면 파일에 씁니다")
    }
}
