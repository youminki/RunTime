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
        /// 묶음의 주소를 한 번에 바꾼다.
        case switchIP(HostsFile.Section)
        /// 파일 전체를 터미널처럼 그대로 본다.
        case raw

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let item): return "edit-\(item.id)"
            case .preview(let title, _, _): return "preview-\(title)"
            case .switchIP(let section): return "switch-\(section.id)"
            case .raw: return "raw"
            }
        }
    }

    enum Filter: String, CaseIterable {
        case all = "전체", on = "켜짐", off = "꺼짐", limited = "기한 있음"

        func matches(_ item: HostsFile.Item) -> Bool {
            switch self {
            case .all: return true
            case .on: return item.enabled
            case .off: return !item.enabled
            case .limited: return item.expiry != nil
            }
        }
    }

    @Published var search = ""
    @Published var filter = Filter.all
    /// 왼쪽 목록에서 고른 묶음의 열쇠. nil이면 전체.
    @Published var selected: String?
    @Published var sheet: Sheet?
    @Published var toast: String?
    /// 이름 → 맥이 실제로 푸는 주소. 확인을 누른 이름만.
    @Published var resolved: [String: [String]] = [:]
    /// 접속 확인 결과. 열쇠는 `probeKey`.
    @Published var probes: [String: HostProbe] = [:]
    /// 접속 확인 중이면 끝난 수와 전체 수.
    @Published var probing: (done: Int, total: Int)?
    private var probeRun = 0
    /// 살펴볼 곳이 많으면 3개만 보이고 접어 둔다. 목록이 화면 아래로 밀리지 않게.
    @Published var showAllIssues = false
    private var toastWork: DispatchWorkItem?

    static func probeKey(_ name: String, _ ip: String) -> String { name + "|" + ip }

    /// 켜진 줄을 모두 찔러 본다. 파일이 바뀌면 `clearProbes`가 이어지던 결과를 버린다.
    func probe(_ items: [HostsFile.Item]) {
        guard probing == nil else { return }
        var seen = Set<String>()
        let targets = items.filter { $0.enabled && seen.insert(Self.probeKey($0.name, $0.ip)).inserted }.map { (name: $0.name, ip: $0.ip) }
        guard !targets.isEmpty else { return }
        probes = [:]
        probeRun += 1
        let run = probeRun
        probing = (0, targets.count)
        Task {
            await HostsProber.probeAll(targets) { result in
                await MainActor.run {
                    guard self.probeRun == run else { return }
                    self.probes[Self.probeKey(result.name, result.ip)] = result
                    self.probing = (self.probes.count, targets.count)
                }
            }
            if probeRun == run { probing = nil }
        }
    }

    func clearProbes() {
        probeRun += 1
        probes = [:]
        probing = nil
    }

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
    /// 127.0.0.1 줄을 개발 서버 포트로 바로 열 때 쓴다.
    @ObservedObject var ports = PortsStore.shared
    @FocusState private var searching: Bool

    var body: some View {
        let keys = collapseKeys
        let current = selectedSection(keys)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                heading
                notices
                attention
                probeSummary
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            Divider().overlay(WL.border)
            HStack(spacing: 0) {
                sidebar(keys: keys, current: current)
                    .frame(width: 236)
                Divider().overlay(WL.border)
                detail(keys: keys, current: current)
            }
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .bottom) { saveBar }
        .overlay(alignment: .bottom) {
            if let toast = page.toast { Toast(message: toast).padding(.bottom, store.dirty ? 70 : 18).transition(.opacity) }
        }
        .background {
            // 목록 안에 두면 화면에서 벗어날 때 함께 사라져 단축키가 먹지 않는다
            Button("") { page.sheet = .add(group: page.search.isEmpty ? current?.title : nil) }.keyboardShortcut("n", modifiers: .command).disabled(!store.canEdit).hidden()
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .sheet(item: $page.sheet) { sheet in
            switch sheet {
            case .add(let group): HostsAddSheet(store: store, page: page, group: group)
            case .edit(let item): HostsEditSheet(store: store, page: page, item: item)
            case .preview(let title, let text, let base): HostsPreviewSheet(store: store, page: page, title: title, text: text, base: base)
            case .switchIP(let section): HostsSwitchSheet(store: store, page: page, section: section)
            case .raw: HostsRawSheet(store: store, page: page)
            }
        }
        // 파일이 바뀌면 맥의 이름 풀이도 바뀌었을 수 있어 지난 확인 결과를 지운다
        .onChange(of: store.saved.text) { _ in
            page.resolved = [:]
            page.clearProbes()
        }
        .onAppear {
            store.setWatching(true)
            // 127.0.0.1 줄의 열기 메뉴에 띄울 개발 서버를 한 번 읽어 둔다
            ports.refresh()
        }
        .onDisappear { store.setWatching(false) }
    }

    /// 경고. 직접 볼 것, 정리로 고쳐지는 것, 참고 순.
    private var issues: [HostsIssue] {
        let rank: (HostsIssue) -> Int = { $0.isNotice ? 2 : $0.fixable ? 1 : 0 }
        return store.issues.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// 줄마다 붙일 경고. 열쇠는 `rowKey`.
    private var issuesByItem: [String: [HostsIssue]] {
        let list = issues
        guard !list.isEmpty else { return [:] }
        var result: [String: [HostsIssue]] = [:]
        for item in store.sections.flatMap(\.items) {
            let found = list.filter { $0.concerns(line: item.line, name: item.name) }
            if !found.isEmpty { result[item.rowKey] = found }
        }
        return result
    }

    /// 지금 오른쪽에 보일 묶음들. 찾는 중에는 모든 묶음에서, 아니면 고른 묶음에서 거른다.
    private func visibleSections(current: HostsFile.Section?) -> [HostsFile.Section] {
        let query = page.search.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = query.isEmpty ? (current.map { [$0] } ?? store.sections) : store.sections
        guard !query.isEmpty || page.filter != .all else { return pool }
        return pool.compactMap { section in
            var section = section
            section.items = section.items.filter(page.filter.matches)
            let titleMatches = section.title?.lowercased().contains(query) == true
            if !query.isEmpty, !titleMatches {
                section.items = section.items.filter {
                    $0.name.lowercased().contains(query) || $0.ip.contains(query) || $0.note?.lowercased().contains(query) == true
                }
            }
            return section.items.isEmpty ? nil : section
        }
    }

    private func emptyMessage(searching: Bool) -> String {
        if store.sections.isEmpty { return "등록한 호스트가 없습니다. 오른쪽 위 ‘추가’를 누르거나 메신저에서 받은 hosts 줄을 붙여 넣으세요." }
        let filter = page.filter == .all ? "" : "‘\(page.filter.rawValue)’ 중에 "
        return searching ? "\(filter)‘\(page.search)’에 맞는 호스트가 없습니다." : "\(filter)보일 호스트가 없습니다."
    }

    // MARK: 머리

    private var heading: some View {
        let items = store.sections.flatMap(\.items)
        return PageHeading("호스트") {
            Tally(title: "켜짐", value: items.filter(\.enabled).count, tint: WL.done)
            Tally(title: "꺼짐", value: items.filter { !$0.enabled }.count, tint: WL.quiet)
        } accessory: {
            HStack(spacing: 8) {
                Button { page.probe(items) } label: {
                    Label(page.probing.map { "확인 중 \($0.done)/\($0.total)" } ?? "접속 확인", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(NotionButtonStyle())
                .disabled(page.probing != nil || !items.contains(where: \.enabled))
                .tip("켜 둔 이름이 실제로 열리는지 한 번에 봅니다. 주소 풀이, 80·443 포트, 웹 응답, 인증서를 확인하고 파일은 고치지 않습니다")
                Button { page.sheet = .add(group: nil) } label: { Label("추가", systemImage: "plus") }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .disabled(!store.canEdit)
                    .tip("호스트 추가 (⌘N). 메신저·위키에서 받은 여러 줄을 그대로 붙여 넣어도 됩니다")
            }
        }
    }

    /// 파일을 못 읽었거나 밖에서 바뀐 것. 고치기 전에 꼭 알아야 해 맨 위에 둔다.
    @ViewBuilder
    private var notices: some View {
        if let problem = store.problem {
            Callout { Text(problem).font(WL.meta).foregroundStyle(WL.waiting) }.padding(.bottom, 12)
        }
        if store.changedOutside {
            Callout {
                HStack {
                    Text("고치는 동안 다른 곳에서 파일이 바뀌었습니다. 지금 저장하면 그 변경을 덮어씁니다.")
                        .font(WL.meta).foregroundStyle(WL.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("고친 것 버리고 다시 읽기") { confirmDiscard("고친 것을 버리고 바뀐 파일을 다시 읽을까요?") }.buttonStyle(NotionButtonStyle())
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// 기한 지난 항목과 살펴볼 줄을 한 상자에 한 줄씩 요약한다. 자세한 이유는 줄 옆 꼬리표나 ‘보기’로 본다.
    @ViewBuilder private var attention: some View {
        // .local 안내는 틀린 것이 아니라 줄 옆 흐린 꼬리표로만 둔다
        let issues = issues.filter { !$0.isNotice }
        let expired = store.canEdit ? store.expired : []
        if !issues.isEmpty || !expired.isEmpty {
            Callout {
                VStack(alignment: .leading, spacing: 8) {
                    if !expired.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(WL.waiting).frame(width: 16)
                            Text("기한 지난 \(expired.count)개가 켜져 있습니다: \(expired.prefix(2).map(\.name).joined(separator: ", "))\(expired.count > 2 ? " 외" : "")")
                                .font(WL.meta).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("모두 끄기") { store.draft.setEnabled(expired, false) }.buttonStyle(TextLinkButtonStyle())
                        }
                    }
                    if !issues.isEmpty {
                        let fixable = issues.filter(\.fixable).count
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(WL.waiting).frame(width: 16)
                            Text("살펴볼 곳 \(issues.count)개").font(WL.meta)
                            Text(Set(issues.map(\.label)).sorted().joined(separator: " · ")).font(WL.caption).foregroundStyle(WL.muted).lineLimit(1)
                            Spacer(minLength: 8)
                            if fixable > 0, store.canEdit {
                                Button("정리로 \(fixable)개 고치기") {
                                    page.sheet = .preview(title: "정리", text: store.organizedText, base: store.saved.text)
                                }
                                .buttonStyle(TextLinkButtonStyle())
                                .tip("겹친 줄을 지우고 깨진 묶음 표시를 고칩니다. 저장하기 전에 바뀌는 줄을 보여 줍니다")
                            }
                            Button(page.showAllIssues ? "접기" : "보기") { page.showAllIssues.toggle() }.buttonStyle(TextLinkButtonStyle())
                        }
                        if page.showAllIssues { issueList(issues) }
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func issueList(_ issues: [HostsIssue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(issues) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(issue.line + 1)번째 줄").font(WL.number).foregroundStyle(WL.muted).frame(width: 64, alignment: .trailing)
                    Text(issue.message).font(WL.meta).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.leading, 16)
    }

    /// 접속 확인을 마친 뒤 몇 개가 어떤지와, 서버마다가 아니라 연결 문제인지를 위에 모은다.
    @ViewBuilder private var probeSummary: some View {
        if page.probing == nil, !page.probes.isEmpty {
            let probes = Array(page.probes.values)
            let levels = probes.map { $0.verdict().level }
            let bad = probes.filter { $0.verdict().level == .problem }.map(\.name).sorted()
            Callout {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Text("접속 확인").font(WL.heading)
                        Tally(title: "정상", value: levels.filter { $0 == .ok }.count, tint: WL.done)
                        Tally(title: "살펴볼 곳", value: levels.filter { $0 == .warning }.count, tint: WL.waiting)
                        Tally(title: "문제", value: bad.count, tint: Color.red)
                        Spacer()
                        Button("지우기") { page.clearProbes() }.buttonStyle(TextLinkButtonStyle())
                    }
                    if let overview = HostProbe.overview(probes) {
                        Text(overview).font(WL.meta).foregroundStyle(WL.waiting)
                    } else if !bad.isEmpty {
                        Text(bad.prefix(3).joined(separator: ", ") + (bad.count > 3 ? " 외 \(bad.count - 3)개" : ""))
                            .font(WL.meta).foregroundStyle(WL.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    /// 찾기 칸과 켜짐·꺼짐 골라 보기를 한 줄에 둔다.
    private var toolbar: some View {
        let items = store.sections.flatMap(\.items)
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WL.quiet)
                TextField("이름, 주소, 메모로 찾기 (⌘F)", text: $page.search).textFieldStyle(.plain).font(WL.body)
                    .focused($searching)
                    .onExitCommand { page.search = ""; searching = false }
                if !page.search.isEmpty {
                    Button { page.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(WL.quiet)
                        .accessibilityLabel("찾기 지우기")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .wlSurface(radius: 6)
            HStack(spacing: 4) {
                ForEach(HostsPage.Filter.allCases, id: \.self) { filter in
                    let count = items.filter(filter.matches).count
                    Button { page.filter = filter } label: {
                        HStack(spacing: 5) {
                            Text(filter.rawValue)
                            Text("\(count)").monospacedDigit()
                                .foregroundStyle(page.filter == filter ? Color.white.opacity(0.8) : WL.quiet)
                        }
                    }
                    .buttonStyle(ChipButtonStyle(selected: page.filter == filter))
                    .fixedSize()
                    .disabled(count == 0 && filter != .all && page.filter != filter)
                }
            }
            .fixedSize()
        }
    }

    // MARK: 묶음

    /// 같은 이름 묶음이 여럿이면 순번을 붙여 서로 구분하는 열쇠.
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

    /// 왼쪽에서 고른 묶음. 지워졌거나 이름이 바뀌어 못 찾으면 nil(전체).
    private func selectedSection(_ keys: [String: String]) -> HostsFile.Section? {
        guard let selected = page.selected else { return nil }
        return store.sections.first { keys[$0.id] == selected }
    }

    /// 찾는 중이면 `section`은 걸러진 묶음이라, 묶음 전체에 할 일은 지금 판의 원래 묶음에 한다.
    private func fullSection(_ section: HostsFile.Section) -> HostsFile.Section {
        store.sections.first { $0.id == section.id } ?? section
    }

    // MARK: 왼쪽 묶음 목록

    /// SwitchHosts·Gas Mask처럼 묶음을 왼쪽에 두고 스위치로 바로 켜고 끈다. 어느 묶음이 켜져 있는지 한눈에 보인다.
    private func sidebar(keys: [String: String], current: HostsFile.Section?) -> some View {
        let all = store.sections.flatMap(\.items)
        // 찾는 동안은 모든 묶음에서 찾아서 왼쪽 강조를 풀어 둔다
        let finding = !page.search.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 0) {
            SlimScrollView {
                VStack(spacing: 2) {
                    sidebarRow(selected: current == nil && !finding, action: { page.selected = nil }) {
                        Image(systemName: "tray.full").font(.system(size: 12.5)).foregroundStyle(WL.muted).frame(width: 30)
                        Text("전체").font(.system(size: 13.5, weight: .medium))
                        Spacer(minLength: 4)
                        Text("\(all.filter(\.enabled).count)/\(all.count)").font(WL.caption).foregroundStyle(WL.quiet).monospacedDigit()
                    }
                    ForEach(store.sections) { section in
                        let key = keys[section.id] ?? section.id
                        let on = section.items.filter(\.enabled).count
                        sidebarRow(selected: current?.id == section.id && !finding, action: { page.selected = key }) {
                            // 하나라도 켜져 있으면 켜짐으로 보이고, 누르면 묶음 전체를 끈다. 모두 꺼져 있으면 모두 켠다
                            Toggle("", isOn: Binding(get: { on > 0 }, set: { store.draft.setEnabled(fullSection(section).items, $0) }))
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .disabled(!store.canEdit)
                                .frame(width: 30)
                                .tip(on > 0 ? "이 묶음을 모두 끕니다" : "이 묶음을 모두 켭니다")
                                .accessibilityLabel("\(section.title ?? "묶음 없음") 모두 \(on > 0 ? "끄기" : "켜기")")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.title ?? "묶음 없음").font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(on > 0 ? WL.text : WL.muted).lineLimit(1)
                                if let address = serverSummary(section) {
                                    Text(address).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(WL.quiet).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Text("\(on)/\(section.items.count)").font(WL.caption).foregroundStyle(WL.quiet).monospacedDigit()
                        }
                        .contextMenu { sectionActions(section) }
                    }
                }
                .padding(10)
            }
            Divider().overlay(WL.border)
            fileTools
        }
        .background(WL.sidebar.opacity(0.5))
    }

    /// 파일 전체에 하는 일. 자주 쓰지는 않지만 숨기지 않고 왼쪽 아래에 늘 보이게 둔다.
    private var fileTools: some View {
        let fixable = issues.filter(\.fixable).count
        let organizable = store.canEdit && store.organizedText != store.draft.text
        let canRestore = store.canEdit && (store.previousText.map { $0 != store.saved.text } ?? false)
        return VStack(spacing: 0) {
            toolRow("새 묶음 만들기", icon: "plus", tip: "추가 창의 ‘묶음’에서 ‘새 묶음 만들기’를 고르고 이름을 적습니다") {
                page.sheet = .add(group: nil)
            }
            .disabled(!store.canEdit)
            toolRow("정리", icon: "wrench.and.screwdriver", badge: fixable > 0 ? fixable : nil,
                    tip: "겹친 줄을 지우고 묶음별로 한 이름에 한 줄씩 다시 씁니다. 저장하기 전에 바뀌는 줄을 보여 줍니다") {
                page.sheet = .preview(title: "정리", text: store.organizedText, base: store.saved.text)
            }
            .disabled(!organizable)
            toolRow("원본 파일 보기", icon: "doc.text", tip: "/etc/hosts 전체를 줄 번호와 함께 봅니다") { page.sheet = .raw }
            toolRow("마지막 저장 전으로", icon: "clock.arrow.circlepath",
                    tip: canRestore ? "저장하기 직전 판으로 되돌립니다. 달라지는 줄을 먼저 보여 줍니다" : "아직 저장한 적이 없어 되돌릴 판이 없습니다") {
                if let text = store.previousText { page.sheet = .preview(title: "백업", text: text, base: store.saved.text) }
            }
            .disabled(!canRestore)
            if HostsStore.url.path == "/etc/hosts" {
                HStack(spacing: 8) {
                    Image(systemName: store.passwordless ? "lock.open" : "lock").font(.system(size: 12)).foregroundStyle(WL.muted).frame(width: 16)
                    Text("암호 없이 저장").font(WL.meta)
                    Spacer(minLength: 4)
                    // 취소하면 실제 상태로 되돌아가 스위치가 제자리로 돌아온다
                    Toggle("", isOn: Binding(get: { store.passwordless }, set: { _ in togglePasswordless() }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .disabled(store.saving)
                        .accessibilityLabel("암호 없이 저장")
                }
                .padding(.horizontal, 16).frame(height: 34)
                .tip(store.passwordless ? "저장할 때 관리자 암호를 묻지 않습니다. 끄면 다시 묻습니다" : "켜면 한 번만 암호를 묻고, 이후 저장은 암호 없이 바로 됩니다")
            }
        }
        .padding(.vertical, 6)
    }

    private func toolRow(_ title: String, icon: String, badge: Int? = nil, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                Text(title).font(WL.meta)
                Spacer(minLength: 4)
                if let badge { Text("\(badge)").font(WL.label).foregroundStyle(WL.waiting).monospacedDigit() }
            }
            .padding(.horizontal, 16).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRow()
        .tip(tip)
    }

    private func sidebarRow<Content: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? WL.selected : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    /// 사이드바 줄에 보일 서버 주소. 켜진 줄의 주소를 보이고 둘 이상이면 `외 N`.
    private func serverSummary(_ section: HostsFile.Section) -> String? {
        let shown = section.items.contains(where: \.enabled) ? section.items.filter(\.enabled) : section.items
        let addresses = Array(NSOrderedSet(array: shown.map(\.ip))) as? [String] ?? []
        guard let first = addresses.first else { return nil }
        return addresses.count > 1 ? "\(first) 외 \(addresses.count - 1)" : first
    }

    // MARK: 오른쪽 상세

    private func detail(keys: [String: String], current: HostsFile.Section?) -> some View {
        let sections = visibleSections(current: current)
        let searching = !page.search.trimmingCharacters(in: .whitespaces).isEmpty
        let rowIssues = issuesByItem
        return VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 24).padding(.vertical, 12)
            Divider().overlay(WL.border)
            SlimScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let current, !searching { detailHeader(current) }
                    if sections.isEmpty {
                        Callout {
                            HStack {
                                Text(emptyMessage(searching: searching)).font(WL.meta).foregroundStyle(WL.muted)
                                Spacer(minLength: 8)
                                if searching || page.filter != .all {
                                    Button("조건 지우기") { page.search = ""; page.filter = .all }.buttonStyle(NotionButtonStyle())
                                }
                            }
                        }
                        .padding(.top, 12)
                    }
                    ForEach(sections) { section in
                        // 전체나 찾기 결과에서는 묶음 이름을 줄 위에 작게 붙인다
                        if current == nil || searching {
                            HStack(spacing: 8) {
                                Text(section.title ?? "묶음 없음").font(WL.heading)
                                    .foregroundStyle(section.title == nil ? WL.muted : WL.text)
                                Text("\(section.items.count)").font(WL.caption).foregroundStyle(WL.quiet).monospacedDigit()
                            }
                            .padding(.top, 16).padding(.bottom, 2)
                        }
                        // 줄 번호만으로 구분하면 다른 파일을 읽은 뒤 같은 번호의 옛 줄 화면이 남아, 주소·이름까지 넣어 구분한다
                        ForEach(section.items, id: \.rowKey) { item in
                            VStack(spacing: 0) {
                                HostRow(store: store, page: page, item: item, issues: rowIssues[item.rowKey] ?? [], devPorts: devPorts)
                                if item.id != section.items.last?.id { RowDivider(inset: 50) }
                            }
                        }
                    }
                }
                // 묶음을 옮기거나 찾아 보일 줄 수가 크게 줄어도 빈 화면이 남지 않게 지연 목록을 새로 만든다
                .id("\(store.generation)|\(page.selected ?? "")|\(page.search)|\(page.filter.rawValue)")
                .padding(.horizontal, 24)
                .padding(.bottom, store.dirty ? 80 : 24)
                .disabled(!store.canEdit)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 고른 묶음의 머리: 이름, 이 묶음이 가리키는 서버, 이 묶음에 추가, 메뉴.
    private func detailHeader(_ section: HostsFile.Section) -> some View {
        HStack(spacing: 10) {
            Text(section.title ?? "묶음 없음").font(WL.title).lineLimit(1)
            addressMenu(section)
            Spacer(minLength: 8)
            Button { copy(fullSection(section)) } label: { Label("묶음 복사", systemImage: "doc.on.doc") }
                .buttonStyle(TextLinkButtonStyle())
                .tip("켜 둔 줄만 묶음 이름과 함께 복사합니다. 팀원은 추가 창에 그대로 붙여 넣으면 됩니다")
            Button { page.sheet = .add(group: section.title) } label: { Label("이 묶음에 추가", systemImage: "plus") }
                .buttonStyle(TextLinkButtonStyle())
        }
        .padding(.top, 16).padding(.bottom, 8)
    }

    /// 묶음이 지금 보는 서버 주소. 누르면 이 맥(127.0.0.1)이나 최근에 쓴 주소로 묶음 전체를 옮긴다.
    @ViewBuilder
    private func addressMenu(_ section: HostsFile.Section) -> some View {
        let full = fullSection(section)
        let shown = full.items.contains(where: \.enabled) ? full.items.filter(\.enabled) : full.items
        let addresses = Array(NSOrderedSet(array: shown.map(\.ip))) as? [String] ?? []
        if !addresses.isEmpty {
            // 스테이징 줄을 주석으로 둔 묶음이 흔해, 켜진 줄의 주소가 하나면 빠른 전환을 보인다
            let single = addresses.count == 1 ? addresses.first : nil
            let targets = single.map { current in
                Array((["127.0.0.1"] + store.recentIPs(for: full.title)).filter { $0 != current }.reduce(into: [String]()) { list, ip in
                    if !list.contains(ip) { list.append(ip) }
                }.prefix(5))
            } ?? []
            Menu {
                if let current = single, !targets.isEmpty {
                    Section("묶음 전체를 이 주소로") {
                        ForEach(targets, id: \.self) { ip in
                            Button(ip == "127.0.0.1" ? "127.0.0.1  이 맥" : ip) { switchAll(full, from: current, to: ip) }
                        }
                    }
                    Divider()
                }
                Button("주소 바꾸기…") { page.sheet = .switchIP(full) }
            } label: {
                HStack(spacing: 4) {
                    Text(addresses.prefix(2).joined(separator: ", ") + (addresses.count > 2 ? " 외 \(addresses.count - 2)" : ""))
                        .font(.system(size: 12, design: .monospaced))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(WL.muted)
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(WL.hover))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip("이 묶음이 가리키는 서버 주소. 눌러서 로컬·개발·스테이징 서버로 한 번에 옮깁니다")
        }
    }

    private func switchAll(_ section: HostsFile.Section, from old: String, to new: String) {
        guard let current = store.draft.section(matching: section) else { return page.flash("묶음이 바뀌었습니다. 다시 고르세요") }
        store.draft.replaceIP(in: current.items.filter { $0.ip == old }, from: old, to: new)
        store.remember([new, old], for: section.title)
        page.flash("‘\(section.title ?? "묶음 없음")’ 주소: \(old) → \(new). 아래에서 저장하면 반영됩니다")
    }

    @ViewBuilder
    private func sectionActions(_ section: HostsFile.Section) -> some View {
        let full = fullSection(section)
        let anyOn = full.items.contains(where: \.enabled)
        Button(anyOn ? "모두 끄기" : "모두 켜기") { store.draft.setEnabled(full.items, !anyOn) }
        Button("이 묶음에 추가…") { page.sheet = .add(group: section.title) }
        Button("주소 바꾸기…") { page.sheet = .switchIP(full) }
        Button("글로 복사 (팀원에게 보내기)") { copy(full) }
    }

    /// 127.0.0.1 줄을 열 때 고를 개발 서버 (포트, 이름).
    private var devPorts: [(port: Int, title: String)] {
        var seen = Set<Int>()
        return ports.devServers.filter(\.isWeb).filter { seen.insert($0.primaryPort).inserted }.map { ($0.primaryPort, $0.title) }
    }

    private func copy(_ section: HostsFile.Section) {
        guard section.items.contains(where: \.enabled) else { return page.flash("켜 둔 줄이 없어 복사하지 않았습니다") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HostsFile.exportText(title: section.title, items: section.items), forType: .string)
        page.flash("켜 둔 \(section.items.filter(\.enabled).count)줄을 복사했습니다. 받는 사람은 ‘추가’에 그대로 붙여 넣으면 됩니다")
    }

    // MARK: 저장 막대

    private func confirmDiscard(_ question: String) {
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "버리기")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn { store.discard() }
    }

    /// 파일 소유자를 이 계정으로 바꿔 저장할 때 암호를 묻지 않게 한다. 켜기 전에 위험을 알린다.
    private func togglePasswordless() {
        if !store.passwordless {
            let alert = NSAlert()
            alert.messageText = "암호 없이 저장할까요?"
            alert.informativeText = "/etc/hosts의 소유자를 이 계정으로 바꿉니다. 지금 한 번만 관리자 암호를 묻고, 이후 저장은 바로 됩니다.\n\n이 계정으로 실행되는 모든 프로그램(npm 패키지의 스크립트 포함)이 hosts를 고칠 수 있게 됩니다. 언제든 같은 스위치로 끌 수 있습니다."
            alert.addButton(withTitle: "켜기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.setPasswordless(!store.passwordless) { page.flash($0) }
    }

    /// 바뀐 줄 확인 창을 거치지 않고 바로 쓴다. 바뀐 줄은 ‘바뀐 줄 보기’로 따로 본다.
    private func save() {
        guard store.dirty, !store.saving else { return }
        guard store.canEdit else { return page.flash(store.problem ?? "파일을 읽지 못해 저장하지 않았습니다") }
        // 고치는 동안 밖에서 파일이 바뀌었으면 바로 쓰지 않고, 되돌려질 줄을 보여 준 뒤 저장하게 한다
        if store.changedOutside {
            page.sheet = .preview(title: "저장", text: store.draft.text, base: store.saved.text)
            return
        }
        store.save(store.draft.text) { failure in
            page.flash(failure ?? "저장했습니다")
        }
    }

    @ViewBuilder
    private var saveBar: some View {
        if store.dirty {
            let count = store.changedLines
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(WL.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("저장하지 않은 변경 \(count)줄").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    // macOS는 앱 이름 대신 ‘스크립트에 관리자 권한을 허용할지’ 묻는다. 놀라지 않게 미리 알린다
                    Text(store.needsPassword ? "저장하면 macOS가 관리자 암호를 묻습니다" : HostsStore.url.path == "/etc/hosts" ? "암호 없이 바로 저장합니다" : "시험용 파일에 씁니다")
                        .font(WL.caption).foregroundStyle(WL.muted)
                }
                Spacer()
                Button("되돌리기") { confirmDiscard("저장하지 않은 변경 \(count)줄을 버릴까요?") }.buttonStyle(TextLinkButtonStyle())
                Button("바뀐 줄 보기") { page.sheet = .preview(title: "저장", text: store.draft.text, base: store.saved.text) }
                    .buttonStyle(NotionButtonStyle())
                Button(store.saving ? "저장하는 중…" : "저장") { save() }
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

/// hosts 파일처럼 주소 → 이름 순서로 붙여 둔다. 올리면 열기·복사·고치기가 나온다.
private struct HostRow: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage
    let item: HostsFile.Item
    let issues: [HostsIssue]
    let devPorts: [(port: Int, title: String)]
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { item.enabled }, set: { store.draft.setEnabled(item, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .tip(item.enabled ? "끄기 (줄 앞에 #을 붙여 남깁니다)" : "켜기")
                .accessibilityLabel("\(item.name) \(item.enabled ? "켜짐" : "꺼짐")")
            Text(item.ip).font(.system(size: 12, design: .monospaced)).foregroundStyle(item.enabled ? WL.muted : WL.faint)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
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
            ForEach(issues) { issue in
                DayBadge(text: issue.label, tint: issue.isNotice ? WL.muted : WL.waiting).tip(issue.message)
            }
            Spacer(minLength: 8)
            if let probe = page.probes[HostsPage.probeKey(item.name, item.ip)] {
                let verdict = probe.verdict()
                DayBadge(text: verdict.label, tint: verdict.level == .ok ? WL.done : verdict.level == .warning ? WL.waiting : Color.red)
                    .tip(verdict.detail)
            } else if let addresses = page.resolved[item.name] { resolution(addresses) }
            HStack(spacing: 2) {
                openButton
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .tip("‘\(item.ip) \(item.name)’ 복사")
                    .accessibilityLabel("\(item.name) 복사")
                Button { page.sheet = .edit(item) } label: { Image(systemName: "pencil") }
                    .tip("고치기·지우기 (줄을 두 번 눌러도 됩니다)")
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
        .onHover { inside in
            hover.on = inside
            // 화면에 들어온 뒤 켜거나 끈 개발 서버도 열기 메뉴에 맞게 보이도록 올릴 때 다시 읽는다
            if inside, isLoopback { PortsStore.shared.refresh() }
        }
        // 고치기 단추는 올려야 보여서, 줄을 두 번 눌러도 열리게 한다
        .onTapGesture(count: 2) { page.sheet = .edit(item) }
        // 올렸을 때만 보이는 단추를 오른쪽 클릭과 손쉬운 사용 동작으로도 쓸 수 있게
        .contextMenu {
            Button("브라우저로 열기") { open(nil) }
            if isLoopback { ForEach(devPorts, id: \.port) { dev in Button("http://\(item.name):\(String(dev.port)) 열기 (\(dev.title))") { open(dev.port) } } }
            Button("맥이 실제로 푸는 주소 확인") { check() }
            Button("복사") { copy() }
            Divider()
            Button("고치기·지우기…") { page.sheet = .edit(item) }
        }
        .accessibilityAction(named: "브라우저로 열기") { open(nil) }
        .accessibilityAction(named: "맥이 실제로 푸는 주소 확인") { check() }
        .accessibilityAction(named: "복사") { copy() }
        .accessibilityAction(named: "고치기·지우기") { page.sheet = .edit(item) }
    }

    private var isLoopback: Bool { item.ip.hasPrefix("127.") || item.ip == "::1" || item.ip == "0.0.0.0" }

    /// 이 맥을 가리키는 이름은 실행 중인 개발 서버 포트로도 열 수 있게 고르게 한다.
    @ViewBuilder private var openButton: some View {
        if isLoopback, !devPorts.isEmpty {
            Menu {
                Button("http://\(item.name)") { open(nil) }
                Section("실행 중인 개발 서버") {
                    ForEach(devPorts, id: \.port) { dev in
                        Button("http://\(item.name):\(String(dev.port))  \(dev.title)") { open(dev.port) }
                    }
                }
            } label: { Image(systemName: "safari") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip("브라우저로 열기. 실행 중인 개발 서버 포트로도 엽니다")
            .accessibilityLabel("\(item.name) 브라우저로 열기")
        } else {
            Button { open(nil) } label: { Image(systemName: "safari") }
                .tip("브라우저로 열기 (http://\(item.name))")
                .accessibilityLabel("\(item.name) 브라우저로 열기")
        }
    }

    private func resolution(_ addresses: [String]) -> some View {
        let matches = addresses.contains(item.ip)
        let text = addresses.isEmpty ? "풀리지 않음" : matches ? "맥도 같은 주소로 엶" : "맥은 다른 주소로 엶: \(addresses.joined(separator: ", "))"
        return Text(text).font(WL.caption).foregroundStyle(matches ? WL.done : WL.waiting).lineLimit(1)
            .tip(matches ? "hosts대로 열립니다" : "hosts와 다른 주소로 열립니다. 같은 이름의 다른 줄, VPN의 DNS, 저장하지 않은 변경을 확인하세요")
    }

    private func check() {
        let name = item.name
        HostsStore.resolve(name) { addresses in
            MainActor.assumeIsolated { page.resolved[name] = addresses }
        }
    }

    private func open(_ port: Int?) {
        if let url = URL(string: "http://\(item.name)" + (port.map { ":\(String($0))" } ?? "")) { NSWorkspace.shared.open(url) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(item.ip) \(item.name)", forType: .string)
        page.flash("‘\(item.ip) \(item.name)’ 줄을 복사했습니다")
    }
}

// MARK: - 원본

/// 파일 전체를 터미널처럼 본다. 읽기만 하고, 고치는 것은 목록이나 실제 터미널에서 한다.
private struct HostsRawSheet: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage

    private static let ink = Color(red: 0.86, green: 0.87, blue: 0.84)
    private static let dim = Color(red: 0.47, green: 0.49, blue: 0.47)
    private static let font = Font.system(size: 12.5, design: .monospaced)

    private var lines: [String] {
        var lines = store.saved.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// 주석은 흐리게 두어 살아 있는 줄이 먼저 보이게 한다.
    private var content: AttributedString {
        var text = AttributedString()
        for (index, line) in lines.enumerated() {
            var part = AttributedString(line + (index + 1 < lines.count ? "\n" : ""))
            part.foregroundColor = line.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? Self.dim : Self.ink
            text += part
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("원본 파일").font(WL.heading)
                Text("\(lines.count)줄").font(WL.caption).foregroundStyle(WL.muted)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("$ cat \(HostsStore.url.path)").font(Self.font).foregroundStyle(Color(red: 0.45, green: 0.8, blue: 0.55))
                ScrollView([.vertical, .horizontal]) {
                    HStack(alignment: .top, spacing: 14) {
                        Text(lines.indices.map { String($0 + 1) }.joined(separator: "\n"))
                            .font(Self.font).foregroundStyle(Self.dim).multilineTextAlignment(.trailing)
                        Text(content).font(Self.font).textSelection(.enabled)
                    }
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.07, green: 0.07, blue: 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Button("전체 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.saved.text, forType: .string)
                    page.flash("복사했습니다")
                }
                .buttonStyle(NotionButtonStyle())
                Button("터미널에서 열기") { HostsRawSheet.openInTerminal() }
                    .buttonStyle(NotionButtonStyle())
                    .tip("터미널 앱을 열어 파일 내용을 보여 줍니다. 이어서 그 창에서 sudo로 고칠 수 있습니다")
                Spacer()
                Button("닫기") { page.sheet = nil }.buttonStyle(NotionButtonStyle(kind: .primary)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
    }

    /// `.command` 파일은 자동화 권한을 묻지 않고 터미널로 열린다.
    private static func openInTerminal() {
        let path = "'" + HostsStore.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-hosts.command")
        let text = "#!/bin/zsh\ncat -n \(path)\nexec \"$SHELL\" -l\n"
        guard (try? text.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
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


// MARK: - 추가·고치기 창이 함께 쓰는 부품

/// 호스트를 며칠만 쓸 때 고르는 기한.
private enum HostsLimit: CaseIterable {
    case none, today, week, custom

    var title: String {
        switch self {
        case .none: return "없음"
        case .today: return "오늘까지"
        case .week: return "1주일"
        case .custom: return "날짜 지정"
        }
    }

    /// 메모에 남길 기한 날(yyyy-MM-dd). 기한이 없으면 nil.
    func day(until: Date) -> String? {
        switch self {
        case .none: return nil
        case .today: return HostsStore.today()
        case .week: return HostsStore.day(Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date())
        case .custom: return HostsStore.day(until)
        }
    }
}

/// `묶음  Dev ⌄`처럼 이름표와 지금 값을 한 단추에 담은 작은 메뉴.
private struct PillMenu<Content: View>: View {
    let label: String
    let value: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(WL.muted)
                Text(value).foregroundStyle(WL.text).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(WL.quiet)
            }
            .font(WL.meta)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 고른 항목에는 체크를 붙인 메뉴 줄.
private func pickRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

private struct HostsLimitMenu: View {
    @Binding var limit: HostsLimit
    @Binding var until: Date
    /// 새로 넣을 때는 지난 날짜를 고르지 못하게 하고, 고칠 때는 이미 지난 기한도 그대로 보인다.
    var futureOnly = true

    var body: some View {
        HStack(spacing: 8) {
            PillMenu(label: "기한", value: limit.title) {
                ForEach(HostsLimit.allCases, id: \.self) { option in pickRow(option.title, selected: limit == option) { limit = option } }
            }
            .tip("기한이 지나도 켜져 있으면 하루 한 번 알리고, 화면 위쪽에서 한 번에 끌 수 있습니다")
            if limit == .custom {
                if futureOnly {
                    DatePicker("", selection: $until, in: Date()..., displayedComponents: .date).labelsHidden().datePickerStyle(.field).fixedSize()
                } else {
                    DatePicker("", selection: $until, displayedComponents: .date).labelsHidden().datePickerStyle(.field).fixedSize()
                }
            }
        }
    }
}

/// 입력칸 위에 작은 이름표를 붙인 칸.
private struct LabeledField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var monospaced = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WL.label).foregroundStyle(WL.muted)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 12.5, design: .monospaced) : WL.meta)
        }
    }
}

// MARK: - 추가

@MainActor
private final class HostsAddForm: ObservableObject {
    @Published var text = ""
    /// 고른 기존 묶음. 비어 있으면 묶음 없음.
    @Published var group: String
    /// 새 묶음을 만드는 중인지. 켜면 이름 칸이 나온다.
    @Published var creating = false
    @Published var newGroup = ""
    @Published var limit = HostsLimit.none
    @Published var until = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    /// 같은 이름을 다른 주소로 켜 둔 줄을 끈다. 끄지 않으면 어느 쪽으로 열릴지 모른다.
    @Published var turnOffOld = true

    init(group: String, text: String) {
        self.group = group
        self.text = text
    }

    /// 넣을 묶음. 새 묶음 이름을 적었으면 그 이름, 아니면 고른 묶음.
    var targetGroup: String {
        let typed = newGroup.trimmingCharacters(in: .whitespaces)
        return creating && !typed.isEmpty ? typed : (creating ? "" : group)
    }

    var groupTitle: String {
        if creating { return newGroup.trimmingCharacters(in: .whitespaces).isEmpty ? "새 묶음" : newGroup.trimmingCharacters(in: .whitespaces) }
        return group.isEmpty ? "묶음 없음" : group
    }
}

/// 받은 줄을 붙여 넣으면 무엇이 들어갈지 바로 보여 주고, 묶음과 기한만 골라 넣는다.
private struct HostsAddSheet: View {
    @ObservedObject var store: HostsStore
    @ObservedObject var page: HostsPage
    @StateObject private var form: HostsAddForm
    @FocusState private var typing: Bool
    @FocusState private var naming: Bool

    init(store: HostsStore, page: HostsPage, group: String?, text: String = "") {
        self.store = store
        self.page = page
        _form = StateObject(wrappedValue: HostsAddForm(group: group ?? "", text: text))
    }

    var body: some View {
        let parsed = HostsFile.records(fromPasted: form.text)
        let plan = store.draft.additionPlan(parsed.records)
        let groups = Array(Set(store.sections.compactMap(\.title))).sorted()
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("호스트 추가").font(WL.title)
                Spacer()
                if form.text.isEmpty, let lines = clipboardLines {
                    Button { form.text = lines.text } label: { Label("클립보드의 \(lines.count)줄 붙여 넣기", systemImage: "doc.on.clipboard") }
                        .buttonStyle(TextLinkButtonStyle())
                }
            }
            editor(parsed)
            if !plan.entries.isEmpty { planList(plan) }
            HStack(spacing: 8) {
                PillMenu(label: "묶음", value: form.groupTitle) {
                    ForEach(groups, id: \.self) { name in
                        pickRow(name, selected: !form.creating && form.group == name) { form.group = name; form.creating = false; form.newGroup = "" }
                    }
                    if !groups.isEmpty { Divider() }
                    pickRow("묶음 없음", selected: !form.creating && form.group.isEmpty) { form.group = ""; form.creating = false; form.newGroup = "" }
                    Button {
                        form.creating = true
                        DispatchQueue.main.async { naming = true }
                    } label: { Label("새 묶음 만들기…", systemImage: "plus") }
                }
                if form.creating {
                    TextField("새 묶음 이름", text: $form.newGroup).textFieldStyle(.roundedBorder).font(WL.meta)
                        .frame(width: 150).focused($naming)
                }
                HostsLimitMenu(limit: $form.limit, until: $form.until)
                Spacer(minLength: 0)
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

    private func editor(_ parsed: (records: [HostsFile.Record], skipped: [String])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $form.text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($typing)
                if form.text.isEmpty {
                    Text("10.0.1.20  api.dev.example.com\nshop.local.test\nhttp://admin.local.test:5173")
                        .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(WL.faint)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 84)
            .padding(6)
            .wlSurface(radius: 6)
            if !parsed.skipped.isEmpty {
                Text("읽지 못한 줄 \(parsed.skipped.count)개: \(parsed.skipped.prefix(3).joined(separator: ", "))")
                    .font(WL.caption).foregroundStyle(WL.waiting).lineLimit(2)
            } else if form.text.isEmpty {
                Text("주소와 이름을 한 줄에 적습니다. 이름이나 브라우저 주소만 적으면 이 맥(127.0.0.1)으로 넣습니다.")
                    .font(WL.caption).foregroundStyle(WL.muted)
            }
        }
    }

    /// 읽은 이름마다 무엇을 할지. 이미 있는 이름이나 다른 주소로 켜 둔 이름을 넣기 전에 보여 준다.
    private func planList(_ plan: HostsFile.AddPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.entries) { entry in
                        HStack(spacing: 8) {
                            statusIcon(entry.status).frame(width: 16)
                            Text(entry.ip).font(.system(size: 12, design: .monospaced)).foregroundStyle(WL.muted)
                                .frame(width: 112, alignment: .leading)
                            Text(entry.name).font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(entry.status == .exists ? WL.faint : WL.text)
                                .lineLimit(1).truncationMode(.middle)
                            if !entry.enabled { Text("꺼진 채로").font(WL.caption).foregroundStyle(WL.quiet) }
                            Spacer(minLength: 8)
                            statusText(entry.status)
                        }
                        .frame(height: 26)
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(plan.entries.count) * 26 + 8, 132))
            .wlSurface(radius: 6)
            if !plan.conflicting.isEmpty {
                Toggle("같은 이름이 다른 주소에 켜져 있는 줄 \(plan.conflicting.count)개 끄기", isOn: $form.turnOffOld).font(WL.meta)
                    .tip("같은 이름이 두 주소에 켜져 있으면 어느 쪽으로 열릴지 알 수 없습니다")
            }
        }
    }

    @ViewBuilder private func statusIcon(_ status: HostsFile.AddPlan.Status) -> some View {
        switch status {
        case .new: Image(systemName: "plus.circle.fill").foregroundStyle(WL.done)
        case .exists: Image(systemName: "checkmark.circle").foregroundStyle(WL.faint)
        case .reenable: Image(systemName: "arrow.uturn.up.circle.fill").foregroundStyle(WL.accent)
        case .conflict: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WL.waiting)
        }
    }

    private func statusText(_ status: HostsFile.AddPlan.Status) -> some View {
        let (text, tint): (String, Color) = switch status {
        case .new: ("새로 추가", WL.done)
        case .exists: ("이미 있음", WL.faint)
        case .reenable: ("꺼진 줄 켜기", WL.accent)
        case .conflict(let ip): ("\(ip)에 켜져 있음", WL.waiting)
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
        let expiry = form.limit.day(until: form.until)
        let records = plan.records.map { record -> HostsFile.Record in
            var record = record
            if let expiry { record.note = HostsFile.note(record.note, until: expiry) }
            return record
        }
        if form.turnOffOld { store.draft.setEnabled(plan.conflicting, false) }
        store.draft.setEnabled(plan.reenable, true)
        store.draft.add(records, to: form.targetGroup)
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
    @Published var limit: HostsLimit
    @Published var until: Date
    @Published var turnOffOthers = true

    init(_ item: HostsFile.Item, group: String) {
        ip = item.ip
        name = item.name
        note = HostsFile.note(item.note, until: nil) ?? ""
        self.group = group
        limit = item.expiry != nil ? .custom : .none
        until = item.expiry.flatMap(HostsStore.date) ?? Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("호스트 고치기").font(WL.title)
                if !item.enabled { DayBadge(text: "꺼짐", tint: WL.muted) }
                Spacer()
            }
            HStack(alignment: .top, spacing: 10) {
                LabeledField(title: "주소", text: $form.ip, placeholder: "192.168.0.10").frame(width: 150)
                LabeledField(title: "이름", text: $form.name, placeholder: "api.example.com")
            }
            LabeledField(title: "메모", text: $form.note, placeholder: "없음", monospaced: false)
            HStack(spacing: 8) {
                PillMenu(label: "묶음", value: form.group.isEmpty ? "묶음 없음" : form.group) {
                    ForEach(groups, id: \.self) { name in pickRow(name, selected: form.group == name) { form.group = name } }
                    if !groups.isEmpty { Divider() }
                    pickRow("묶음 없음", selected: form.group.isEmpty) { form.group = "" }
                }
                HostsLimitMenu(limit: $form.limit, until: $form.until, futureOnly: false)
                if form.group != group { Text("옮기면 그 묶음 끝에 들어갑니다").font(WL.caption).foregroundStyle(WL.quiet) }
                Spacer(minLength: 0)
            }
            if let problem { Text(problem).font(WL.caption).foregroundStyle(WL.waiting) }
            if let other = others.first {
                Toggle("같은 이름이 \(other.ip)에 켜져 있는 \(other.line + 1)번째 줄\(others.count > 1 ? " 외 \(others.count - 1)개" : "") 끄기",
                       isOn: $form.turnOffOthers)
                    .font(WL.meta)
                    .tip("같은 이름이 두 주소에 켜져 있으면 어느 쪽으로 열릴지 알 수 없습니다")
            }
            HStack {
                Button("삭제", role: .destructive) {
                    store.draft.remove(item)
                    page.sheet = nil
                    page.flash("\(item.name) 줄을 지웠습니다. 저장하기 전에는 ‘되돌리기’로 살릴 수 있습니다")
                }
                .buttonStyle(NotionButtonStyle())
                Spacer()
                Button("취소") { page.sheet = nil }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
                Button("바꾸기") { apply(ip: ip, name: name, note: note, others: others) }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || (unchanged && (others.isEmpty || !form.turnOffOthers)))
            }
        }
        .padding(22)
        .frame(width: 500)
        .foregroundStyle(WL.text)
    }

    private var newNote: String? {
        let text = form.note.trimmingCharacters(in: .whitespaces)
        return HostsFile.note(text.isEmpty ? nil : text, until: form.limit.day(until: form.until))
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
            Text(title == "정리" ? "정리한 내용 확인" : title == "백업" ? "마지막 저장 전으로 되돌리기" : "저장할 내용 확인").font(WL.title)
            HStack(spacing: 14) {
                Tally(title: "추가", value: added, tint: WL.done)
                Tally(title: "삭제", value: removed, tint: WL.waiting)
                Text("저장 직전 판은 하나 남겨 둡니다").foregroundStyle(WL.quiet)
            }
            .font(.system(size: 12.5))
            if title == "백업" && store.dirty {
                Text("저장하지 않은 변경은 이 판으로 덮여 사라집니다").font(WL.meta).foregroundStyle(WL.waiting)
            }
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
                     ? (store.needsPassword ? "저장하면 macOS가 관리자 암호를 묻습니다. /etc/hosts를 바꾸고 DNS 캐시를 비우는 데만 씁니다."
                        : "암호 없이 /etc/hosts에 바로 씁니다.")
                     : "시험용 파일 \(HostsStore.url.path)에 씁니다.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(WL.caption).foregroundStyle(WL.muted)
                Spacer()
                Button("취소") { page.sheet = nil }.buttonStyle(NotionButtonStyle()).keyboardShortcut(.cancelAction)
                    .disabled(store.saving)
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
                .tip(change.text)
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
                if store.saved.text != base {
                    page.sheet = nil
                    return page.flash(failure)
                }
                // 뒤 화면 안내는 이 창에 가려 창 위에 알린다
                let alert = NSAlert()
                alert.messageText = "저장하지 못했습니다"
                alert.informativeText = failure
                alert.runModal()
            } else {
                page.sheet = nil
                page.flash(title == "정리" ? "정리해 저장했습니다" : "저장했습니다")
            }
        }
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
            Text("이 묶음에서 같은 주소를 쓰는 이름을 한 번에 다른 서버로 옮깁니다.")
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
