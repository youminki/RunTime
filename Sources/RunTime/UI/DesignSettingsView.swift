import DesignSyncCore
import SwiftUI

/// 설정 칸의 입력 상태. 이 툴체인은 SwiftUI 매크로(@State)를 못 써서 모델에 둔다.
@MainActor
final class DesignSettingsForm: ObservableObject {
    @Published var tokenDraft = ""
    @Published var tokenStatus: String?
    /// 마지막 연결 확인이 실패했는지. 실패면 설명을 주황으로 보인다.
    @Published var tokenFailed = false
    @Published var urlDraft = ""
    @Published var adding = false
    /// 마지막으로 링크를 더한 결과. 실패면 주황으로 보인다.
    @Published var addMessage: String?
    @Published var addFailed = false
    @Published var alertPicker: String?
}

/// 설정 > 디자인. 연결(토큰·화면설계서·주기)과 알림(메뉴·규칙)을 두 칸으로 나눈다.
/// 업무 일지 연동과 같은 "이름·설명 | 조작" 줄로 두고, 칸 안은 작은 소제목으로 묶는다.
struct DesignSettingsView: View {
    enum Section { case figma, alerts }

    @ObservedObject var sync: DesignSync
    @ObservedObject var settings: DesignSyncSettings
    let section: Section
    @StateObject private var form = DesignSettingsForm()

    var body: some View {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(section == .figma
                     ? "피그마 화면설계서를 필요할 때나 정한 주기마다 가져와 메뉴·화면별로 바뀐 것을 디자인 화면에 날짜별로 남깁니다."
                     : "맡은 메뉴를 고르면 디자인 화면은 그 메뉴의 변경만 모아 보이고, 알림도 그 메뉴에서만 옵니다. 작업 중 표시가 붙은 시안의 변경은 알리지 않습니다.")
                    .font(.system(size: 12.5)).foregroundStyle(WL.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                switch section {
                case .figma:
                    group("연결") { token }
                    group("지켜보는 화면설계서") { files; schedule }
                    Text("피그마에는 토큰으로 파일 정보와 화면 노드를 묻기만 하고 보내는 것은 없습니다. 가져온 화면 내용은 이 Mac의 Application Support/RunTime/design-history.json에만 둡니다.")
                        .font(WL.caption).foregroundStyle(WL.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                case .alerts:
                    group("알림 받을 메뉴") { alertMenus }
                    group("알림 규칙") { rules }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(WL.text)
        .sheet(item: Binding(get: { form.alertPicker.map(PickerTarget.init) }, set: { form.alertPicker = $0?.id })) { target in
            DesignAlertPicker(sync: sync, fileKey: target.id)
        }
    }

    private struct PickerTarget: Identifiable {
        let id: String
    }

    /// 소제목과 그 아래 줄들. 첫 줄 위에 선을 그어 묶음이 보이게 한다.
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(WL.label).foregroundStyle(.secondary)
                .padding(.top, 22).padding(.bottom, 6)
            Rectangle().fill(WL.border).frame(height: 1)
            content()
        }
    }

    // MARK: 연결

    private var token: some View {
        // 연결 확인 결과는 토큰 줄 설명에 바로 보여 줄을 하나로 둔다. 토큰을 저장하면 저절로 확인한다
        SettingRow("피그마 토큰", form.tokenStatus ?? "피그마 설정 > Security > Personal access tokens에서 file_content:read 범위로 만듭니다. 날짜 비교까지 쓰려면 file_versions:read도 더합니다. 키체인에 둡니다.",
                   detailTint: form.tokenFailed ? WL.waiting : form.tokenStatus == nil ? nil : WL.done) {
            HStack(alignment: .top, spacing: 6) {
                if !settings.hasToken {
                    // 토큰을 만드는 곳(피그마 설정의 Security 탭)으로 바로 보낸다
                    Button("토큰 만들기") { NSWorkspace.shared.open(URL(string: "https://www.figma.com/settings")!) }
                        .buttonStyle(NotionButtonStyle())
                        .tip("피그마 설정을 엽니다. Security > Personal access tokens에서 만들고 복사해 오세요")
                }
                SecretInput(saved: settings.hasToken, hint: settings.tokenHint, placeholder: "figd_…", draft: $form.tokenDraft,
                            save: { value in
                                guard settings.saveToken(value) else { return "키체인에 저장하지 못했습니다" }
                                Task { await check() }
                                return nil
                            },
                            clear: {
                                settings.clearToken()
                                form.tokenStatus = nil
                                form.tokenFailed = false
                            })
            }
        }
    }

    private func check() async {
        form.tokenStatus = "확인하는 중…"
        form.tokenFailed = false
        switch await sync.checkToken() {
        case .success(let text): form.tokenStatus = text
        case .failure(let failure):
            form.tokenStatus = failure.message
            form.tokenFailed = true
        }
    }

    // MARK: 화면설계서

    private var files: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(settings.sources) { source in fileRow(source) }
            SettingRow("링크 더하기", form.addMessage ?? (settings.hasToken
                        ? "피그마에서 화면을 고르고 ‘링크 복사’한 주소를 넣으면 그 화면만, 파일 주소를 넣으면 프로젝트 전체를 지켜봅니다. 같은 파일의 다른 화면 링크는 그 프로젝트에 더해집니다."
                        : "토큰을 넣은 뒤에 더할 수 있습니다."),
                       detailTint: form.addMessage == nil ? nil : form.addFailed ? WL.waiting : WL.done) {
                HStack(spacing: 6) {
                    TextField("https://www.figma.com/design/…", text: $form.urlDraft).textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit(add)
                    if form.urlDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        // 피그마에서 복사해 온 링크를 한 번에 넣고 더한다
                        Button(form.adding ? "확인하는 중…" : "붙여넣기") { pasteAndAdd() }
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                            .disabled(form.adding || !settings.hasToken)
                            .tip("복사해 둔 피그마 링크를 넣고 바로 더합니다")
                    } else {
                        Button(form.adding ? "확인하는 중…" : "더하기", action: add)
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                            .disabled(form.adding || !settings.hasToken)
                    }
                }
            }
        }
    }

    /// 파일 한 줄: 이름과 상태, 가져오기와 나머지는 ⋯ 메뉴에 둔다.
    private func fileRow(_ source: DesignSource) -> some View {
        let record = sync.history.files[source.fileKey]
        let names = source.scope.map { $0.name.isEmpty ? $0.nodeID : $0.name }
        let scope = names.isEmpty ? "전체" : "링크한 화면 " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " 외 \(names.count - 3)개" : "")
        let detail = [scope,
                      record.map { "화면 \($0.screens.count)개" } ?? (sync.isBusy(source.fileKey) ? "처음 가져오는 중" : "아직 가져오지 않음"),
                      record.map { "\(DesignFormat.stamp($0.syncedAt)) 확인" },
                      sync.intervalLabel(source.intervalMinutes ?? settings.intervalMinutes),
                      source.menus.isEmpty ? nil : "일부 메뉴만 받는 중",
                      source.isHidden ? "숨김" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return SettingRow(source.name.isEmpty ? source.fileKey : source.name, sync.errors[source.fileKey] ?? detail,
                          detailTint: sync.errors[source.fileKey] == nil ? nil : WL.waiting) {
            HStack(spacing: 6) {
                Button(sync.fetching == source.fileKey ? "가져오는 중…" : sync.isBusy(source.fileKey) ? "대기 중" : "가져오기") {
                    sync.sync(only: source.fileKey)
                }
                .buttonStyle(NotionButtonStyle())
                .disabled(sync.isBusy(source.fileKey) || !settings.hasToken)
                .tip("이 프로젝트만 지금 받습니다")
                fileMenu(source)
            }
        }
    }

    private func fileMenu(_ source: DesignSource) -> some View {
        Menu {
            Menu("가져오기 주기") {
                ForEach(DesignSync.projectIntervals.indices, id: \.self) { index in
                    let minutes = DesignSync.projectIntervals[index]
                    Button((source.intervalMinutes == minutes ? "✓ " : "") + sync.intervalLabel(minutes)) { sync.setInterval(minutes, for: source.fileKey) }
                }
            }
            if !source.scope.isEmpty {
                Button("프로젝트 전체 지켜보기") {
                    sync.widen(source.fileKey)
                    sync.sync(only: source.fileKey)
                }
                Menu("링크한 화면 빼기") {
                    ForEach(source.scope, id: \.nodeID) { scope in
                        Button(scope.name.isEmpty ? scope.nodeID : scope.name) { sync.removeScope(scope.nodeID, from: source.fileKey) }
                    }
                }
                .disabled(sync.syncing)
            }
            // 예전에 받는 범위를 메뉴로 좁혀 둔 파일만. 지금은 모든 화면을 기록하고 알림만 고른다
            if !source.menus.isEmpty {
                Button("모든 메뉴 받기") { sync.setMenus([], for: source.fileKey) }.disabled(sync.syncing)
            }
            if let url = URL(string: "https://www.figma.com/design/\(source.fileKey)") {
                Button("피그마에서 열기") { NSWorkspace.shared.open(url) }
            }
            Button(source.isHidden ? "다시 보이고 가져오기" : "숨기기 (가져오지 않음)") { sync.setProjectHidden(source.fileKey, hidden: !source.isHidden) }
            Divider()
            Button("지켜보지 않기 (기록도 지움)") { sync.removeSource(source.fileKey) }.disabled(sync.syncing)
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(WL.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .tip("가져오기 주기·범위·숨기기·지우기")
    }

    private func pasteAndAdd() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.contains("figma.com/") else {
            form.addMessage = text.isEmpty ? "클립보드가 비어 있습니다. 피그마에서 링크를 복사해 오세요." : "클립보드에 피그마 링크가 없습니다."
            form.addFailed = true
            return
        }
        form.urlDraft = text
        add()
    }

    private func add() {
        form.adding = true
        form.addMessage = nil
        Task {
            let result = await sync.addLink(form.urlDraft)
            form.adding = false
            switch result {
            case .success(let link):
                form.addMessage = link.message
                form.addFailed = false
                form.urlDraft = ""
                if link.needsFetch { sync.sync(only: link.fileKey) }
            case .failure(let problem):
                form.addMessage = problem.message
                form.addFailed = true
            }
        }
    }

    private var schedule: some View {
        SettingRow("기본 가져오기 주기", "프로젝트마다 ⋯에서 따로 정하지 않았으면 이 주기로 가져옵니다. 누를 때만으로 두면 디자인 화면에서 가져오기를 누를 때만 받습니다. 파일이 그대로면 파일 정보만 한 번 묻고 끝냅니다.") {
            Picker("", selection: $settings.intervalMinutes) {
                ForEach(DesignSyncSettings.intervals, id: \.self) { minutes in
                    Text(minutes == 0 ? "누를 때만" : minutes < 60 ? "\(minutes)분마다" : "\(minutes / 60)시간마다").tag(minutes)
                }
            }
            .labelsHidden().frame(width: 120)
            .onChange(of: settings.intervalMinutes) { _ in sync.reschedule() }
        }
    }

    // MARK: 알림

    private var alertMenus: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.sources.isEmpty {
                Text("피그마 칸에서 화면설계서를 먼저 더하세요.").font(.system(size: 12)).foregroundStyle(WL.muted).padding(.vertical, 14)
            }
            ForEach(settings.sources) { source in
                let record = sync.history.files[source.fileKey]
                SettingRow(source.name.isEmpty ? source.fileKey : source.name,
                           source.alerts.isEmpty ? "고른 메뉴가 없어 알리지 않습니다." : source.alerts.map(DesignFormat.path).joined(separator: ", "),
                           detailTint: source.alerts.isEmpty ? WL.waiting : nil) {
                    Button(source.alerts.isEmpty ? "메뉴 고르기" : "바꾸기") { form.alertPicker = source.fileKey }
                        .buttonStyle(NotionButtonStyle(kind: source.alerts.isEmpty ? .primary : .secondary))
                        .disabled(record == nil)
                        .tip(record == nil ? "한 번 가져온 뒤에 고를 수 있습니다" : "디자인 화면 왼쪽 메뉴의 종(🔔)과 같습니다")
                }
            }
        }
    }

    private var rules: some View {
        VStack(spacing: 0) {
            SettingRow("macOS 알림", "고른 메뉴에서 완료된 화면이 다시 바뀌거나, 화면이 완료되거나, 상태 표시가 없는 화면이 바뀌거나, 디자이너가 이력에 적으면 알립니다.") {
                Toggle("", isOn: $settings.notify).toggleStyle(.switch).labelsHidden()
            }
            SettingRow("작업 중 변경도 알림", "[수정중]처럼 작업 중 표시가 붙은 시안은 계속 바뀌어서 기본은 기록만 합니다.") {
                Toggle("", isOn: $settings.notifyWorking).toggleStyle(.switch).labelsHidden()
                    .disabled(!settings.notify)
            }
            SettingRow("상태 표시가 없는 화면", "섹션에 [완료]·[수정중]이나 _v0.4 같은 버전이 없는 화면입니다. 판단하지 않으면 ‘상태 모름’으로 두고, 알림 받는 메뉴에서 바뀔 때마다 알립니다. 표시를 쓰지 않는 디자이너의 화면설계서를 모두 완료로 보면 변경이 전부 완료 후 변경으로 쏟아집니다. 프로젝트마다 오른쪽 클릭으로 따로 정합니다.") {
                Picker("", selection: Binding(get: { settings.untaggedIsDone.map { $0 ? 1 : 2 } ?? 0 },
                                              set: { settings.untaggedIsDone = [1: true, 2: false][$0] })) {
                    Text("판단하지 않음").tag(0)
                    Text("완료로 보기").tag(1)
                    Text("작업 중으로 보기").tag(2)
                }
                .labelsHidden().frame(width: 140)
            }
        }
    }
}

@MainActor
final class DesignAlertChoice: ObservableObject {
    @Published var alerts: Set<String> = []
    /// 접은 묶음
    @Published var folded: Set<String> = []
}

/// 알림 받을 메뉴를 고른다. 모든 단계를 펼친 트리에서 줄마다 스위치로 켜고 끈다.
/// 묶음에 켜면 그 아래 화면(앞으로 생길 것까지)이 모두 들어가고, 그 안의 하나를 끄면 나머지만 켜진 채로 풀린다.
struct DesignAlertPicker: View {
    @ObservedObject var sync: DesignSync
    let fileKey: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var choice = DesignAlertChoice()

    private var nodes: [DesignMenuTree.Node] {
        let menus = sync.history.menus().filter { $0.fileKey == fileKey && $0.screenCount > 0 }
        return DesignMenuTree.build(menus, compact: false)
    }

    /// 화면이 있는 경로 전부. 묶음을 풀 때 나머지 메뉴를 하나씩 켜는 데 쓴다.
    private var screenPaths: [String] {
        Array(Set(sync.history.files[fileKey]?.screens.values.map(\.menuPath) ?? [])).sorted()
    }

    var body: some View {
        let nodes = nodes
        let rows = DesignMenuTree.rows(nodes) { node, _ in choice.folded.contains(node.path) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("알림 받을 메뉴").font(WL.section)
                    Text(summary).font(WL.meta).foregroundStyle(WL.muted)
                }
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(NotionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("저장") {
                    if let index = DesignSyncSettings.shared.sources.firstIndex(where: { $0.fileKey == fileKey }) {
                        DesignSyncSettings.shared.sources[index].alerts = choice.alerts.sorted()
                    }
                    dismiss()
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
            HStack(spacing: 4) {
                let parents = allParents(nodes)
                Button(choice.folded.isEmpty ? "모두 접기" : "모두 펼치기") {
                    choice.folded = choice.folded.isEmpty ? Set(parents) : []
                }
                .buttonStyle(TextLinkButtonStyle())
                .disabled(parents.isEmpty)
                Spacer()
                Button("모두 끄기") { choice.alerts = [] }
                    .buttonStyle(TextLinkButtonStyle())
                    .disabled(choice.alerts.isEmpty)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
            Rectangle().fill(WL.border).frame(height: 1)
            SlimScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { item in
                        row(item.node, depth: item.depth)
                        if item.depth == 0 && item.id != rows.last?.id && (item.node.children.isEmpty || choice.folded.contains(item.node.path)) {
                            RowDivider(inset: 0)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 520, height: 600)
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .onAppear {
            choice.alerts = Set(DesignSyncSettings.shared.sources.first { $0.fileKey == fileKey }?.alerts ?? [])
        }
    }

    private var summary: String {
        guard !choice.alerts.isEmpty else { return "고른 메뉴가 없으면 이 프로젝트의 모든 변경을 보고 알림은 보내지 않습니다." }
        let screens = screenPaths.filter { path in choice.alerts.contains { DesignStatus.covers($0, path) } }.count
        return "메뉴 \(screens)개에서 완료된 화면이 바뀌면 알립니다. 묶음을 켜면 앞으로 생길 화면도 들어갑니다."
    }

    private func allParents(_ nodes: [DesignMenuTree.Node]) -> [String] {
        nodes.flatMap { $0.children.isEmpty ? [] : [$0.path] + allParents($0.children) }
    }

    private func isOn(_ path: String) -> Bool { choice.alerts.contains { DesignStatus.covers($0, path) } }

    /// 아래 메뉴 가운데 켜진 수와 전체 수. 묶음이 일부만 켜졌는지 보인다.
    private func coverage(_ path: String) -> (on: Int, total: Int) {
        let under = screenPaths.filter { DesignStatus.covers(path, $0) }
        return (under.filter(isOn).count, under.count)
    }

    /// 사이드바 종 단추와 같은 규칙 (`DesignStatus.setAlert`).
    private func set(_ path: String, on: Bool) {
        choice.alerts = Set(DesignStatus.setAlert(path, on: on, in: Array(choice.alerts), screenPaths: screenPaths))
    }

    private func row(_ node: DesignMenuTree.Node, depth: Int) -> some View {
        let parent = !node.children.isEmpty
        let on = isOn(node.path)
        let count = coverage(node.path)
        let folded = choice.folded.contains(node.path)
        return HStack(spacing: 8) {
            if parent {
                Button {
                    if folded { choice.folded.remove(node.path) } else { choice.folded.insert(node.path) }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .frame(width: 18, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(WL.muted)
                .tip(folded ? "펼치기" : "접기")
            } else {
                Color.clear.frame(width: 18, height: 30)
            }
            Text(node.name).font(parent ? WL.heading : WL.body).lineLimit(1).truncationMode(.tail)
                .tip(DesignFormat.path(node.path))
            Spacer(minLength: 8)
            // 묶음이 일부만 켜졌으면 몇 개인지, 아니면 화면 수
            Text(!on && count.on > 0 ? "일부 \(count.on)/\(count.total)" : parent ? "메뉴 \(count.total)" : "화면 \(node.screens)")
                .font(WL.meta).foregroundStyle(!on && count.on > 0 ? WL.accent : WL.muted).monospacedDigit()
            Toggle("", isOn: Binding(get: { on }, set: { set(node.path, on: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .tip(parent ? "켜면 이 아래 메뉴 모두, 앞으로 새로 생기는 화면까지 알립니다" : "완료된 화면이 바뀌면 알립니다")
        }
        .padding(.leading, CGFloat(depth) * 20)
        .padding(.trailing, 4)
        .frame(minHeight: 34)
    }
}
