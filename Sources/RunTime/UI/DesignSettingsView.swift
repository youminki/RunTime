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
    @Published var addProblem: String?
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
                     : "작업 중인 시안은 계속 바뀌어서, 고른 메뉴에서 완료된 화면이 다시 바뀔 때만 알립니다.")
                    .font(.system(size: 12.5)).foregroundStyle(WL.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                switch section {
                case .figma:
                    group("연결") { token }
                    group("화면설계서") { files }
                    group("가져오기") { schedule }
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
        VStack(spacing: 0) {
            SettingRow("피그마 토큰", "피그마 설정 > Security > Personal access tokens에서 file_content:read 범위로 만듭니다. 날짜 비교까지 쓰려면 file_versions:read도 더합니다. 키체인에 둡니다.") {
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
            if settings.hasToken {
                SettingRow("연결 상태", form.tokenStatus ?? "토큰으로 화면설계서를 읽을 수 있는지 피그마에 물어봅니다.",
                           detailTint: form.tokenFailed ? WL.waiting : nil) {
                    Button("연결 확인") { Task { await check() } }.buttonStyle(NotionButtonStyle())
                }
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
            SettingRow("화면설계서 더하기", form.addProblem ?? (settings.hasToken ? "피그마 주소창의 figma.com/design/… 주소를 붙여 넣습니다." : "토큰을 넣은 뒤에 더할 수 있습니다."),
                       detailTint: form.addProblem == nil ? nil : WL.waiting) {
                HStack(spacing: 6) {
                    TextField("https://www.figma.com/design/…", text: $form.urlDraft).textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit(add)
                    Button(form.adding ? "확인하는 중…" : "더하기", action: add)
                        .buttonStyle(NotionButtonStyle(kind: .primary))
                        .disabled(form.adding || form.urlDraft.trimmingCharacters(in: .whitespaces).isEmpty || !settings.hasToken)
                }
            }
        }
    }

    private func fileRow(_ source: DesignSource) -> some View {
        let record = sync.history.files[source.fileKey]
        let detail = [record.map { "화면 \($0.screens.count)개" } ?? (sync.isBusy(source.fileKey) ? "처음 가져오는 중" : "아직 가져오지 않음"),
                      record.map { "\(DesignFormat.stamp($0.syncedAt)) 확인" },
                      source.menus.isEmpty ? nil : "일부 메뉴만 받는 중",
                      source.isHidden ? "숨김 · 가져오지 않음" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return SettingRow(source.name.isEmpty ? source.fileKey : source.name, sync.errors[source.fileKey] ?? detail,
                          detailTint: sync.errors[source.fileKey] == nil ? nil : WL.waiting) {
            HStack(spacing: 6) {
                // 예전에 받는 범위를 좁혀 둔 파일만. 지금은 모든 화면을 기록하고 알림만 고른다
                if !source.menus.isEmpty {
                    Button("모든 메뉴 받기") { sync.setMenus([], for: source.fileKey) }
                        .buttonStyle(NotionButtonStyle())
                        .disabled(sync.syncing)
                }
                Button(sync.fetching == source.fileKey ? "가져오는 중…" : sync.isBusy(source.fileKey) ? "대기 중" : "가져오기") {
                    sync.sync(only: source.fileKey)
                }
                .buttonStyle(NotionButtonStyle())
                .disabled(sync.isBusy(source.fileKey) || !settings.hasToken)
                .tip("이 프로젝트만 지금 받습니다")
                // 프로젝트마다 가져오기 주기: 지금 작업 중인 것은 짧게, 끝난 것은 길게
                Picker("", selection: Binding(get: { source.intervalMinutes ?? -1 },
                                              set: { sync.setInterval($0 < 0 ? nil : $0, for: source.fileKey) })) {
                    ForEach(DesignSync.projectIntervals.indices, id: \.self) { index in
                        let minutes = DesignSync.projectIntervals[index]
                        Text(sync.intervalLabel(minutes)).tag(minutes ?? -1)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(source.isHidden)
                .tip("이 프로젝트를 가져오는 주기")
                Button { sync.setProjectHidden(source.fileKey, hidden: !source.isHidden) } label: {
                    Image(systemName: source.isHidden ? "eye.slash" : "eye")
                }
                .buttonStyle(GhostIconButtonStyle())
                .tip(source.isHidden ? "다시 보이고 가져오기" : "디자인 화면에서 숨기고 가져오지 않기")
                if let url = URL(string: "https://www.figma.com/design/\(source.fileKey)") {
                    Button { NSWorkspace.shared.open(url) } label: { FigmaMark(height: 13) }
                        .buttonStyle(GhostIconButtonStyle())
                        .tip("피그마에서 열기")
                }
                Button { sync.removeSource(source.fileKey) } label: { Image(systemName: "trash") }
                    .buttonStyle(GhostIconButtonStyle())
                    .disabled(sync.syncing)
                    .tip("지켜보지 않고 기록도 지웁니다")
            }
        }
    }

    private func add() {
        form.adding = true
        form.addProblem = nil
        Task {
            let problem = await sync.addSource(form.urlDraft)
            form.adding = false
            form.addProblem = problem
            if problem == nil {
                form.urlDraft = ""
                sync.sync(only: settings.sources.last?.fileKey)
            }
        }
    }

    // MARK: 가져오기

    private var schedule: some View {
        SettingRow("기본 가져오기 주기", "프로젝트마다 따로 정하지 않았으면 이 주기로 가져옵니다. 누를 때만으로 두면 디자인 화면에서 프로젝트에 올려 ↓를 누를 때만 받습니다. 파일이 그대로면 파일 정보만 한 번 묻고 끝냅니다.") {
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
            SettingRow("macOS 알림", "고른 메뉴에서 완료된 화면이 다시 바뀌거나, 화면이 완료되거나, 디자이너가 이력에 적으면 알립니다.") {
                Toggle("", isOn: $settings.notify).toggleStyle(.switch).labelsHidden()
            }
            SettingRow("작업 중 변경도 알림", "작업 중인 시안은 계속 바뀌어서 기본은 기록만 합니다.") {
                Toggle("", isOn: $settings.notifyWorking).toggleStyle(.switch).labelsHidden()
                    .disabled(!settings.notify)
            }
            SettingRow("상태 표시가 없는 화면", "섹션에 [완료]·[수정중]이나 _v0.4 같은 버전을 쓰는 화면설계서에서 표시가 빠진 화면을 어떻게 볼지 정합니다. 버전을 단 섹션은 완료로, 표시를 전혀 쓰지 않는 화면설계서는 완료로 봅니다. 프로젝트·메뉴마다 오른쪽 클릭으로 따로 정할 수 있습니다.") {
                Picker("", selection: $settings.untaggedIsDone) {
                    Text("완료로 보기").tag(true)
                    Text("작업 중으로 보기").tag(false)
                }
                .labelsHidden().frame(width: 140)
            }
        }
    }
}

@MainActor
final class DesignAlertChoice: ObservableObject {
    @Published var alerts: Set<String> = []
}

/// 알림 받을 메뉴를 고른다. 묶음에 켜면 그 아래 화면(앞으로 생길 것까지)이 모두 들어간다.
struct DesignAlertPicker: View {
    @ObservedObject var sync: DesignSync
    let fileKey: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var choice = DesignAlertChoice()

    /// 디자인 화면 사이드바와 같은 트리. 여기서는 모두 펼쳐 한눈에 고른다.
    private var rows: [DesignMenuTree.Row] {
        let menus = sync.history.menus().filter { $0.fileKey == fileKey && $0.screenCount > 0 }
        return DesignMenuTree.rows(DesignMenuTree.build(menus)) { _, _ in false }.filter { $0.kind == .node }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("알림 받을 메뉴").font(WL.section)
                    Text(choice.alerts.isEmpty ? "고른 메뉴가 없으면 알리지 않습니다." : "\(choice.alerts.count)곳에서 완료된 화면이 바뀌면 알립니다.")
                        .font(WL.meta).foregroundStyle(WL.muted)
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
            .padding(18)
            Rectangle().fill(WL.border).frame(height: 1)
            SlimScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { item in
                        let node = item.node
                        let parent = !node.children.isEmpty
                        row(parent ? node.path : (node.own?.path ?? node.path), title: node.name,
                            detail: parent ? "화면 \(node.screens)개 전체" : "화면 \(node.screens)", heading: parent, depth: item.depth)
                            .padding(.top, item.depth == 0 && item.id != rows.first?.id ? 10 : 0)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 480, height: 540)
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .onAppear {
            choice.alerts = Set(DesignSyncSettings.shared.sources.first { $0.fileKey == fileKey }?.alerts ?? [])
        }
    }

    /// 묶음에 켜져 있으면 아래 줄은 함께 켜진 것으로 옅게 두고 따로 끄지 않는다.
    private func row(_ path: String, title: String, detail: String, heading: Bool, depth: Int) -> some View {
        let inherited = choice.alerts.contains { $0 != path && DesignStatus.covers($0, path) }
        let on = inherited || choice.alerts.contains(path)
        return Button {
            if choice.alerts.contains(path) {
                choice.alerts.remove(path)
            } else if !inherited {
                choice.alerts = choice.alerts.filter { !DesignStatus.covers(path, $0) }
                choice.alerts.insert(path)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "bell.fill" : "bell")
                    .font(.system(size: 12)).foregroundStyle(on ? WL.accent.opacity(inherited ? 0.5 : 1) : WL.faint)
                    .frame(width: 18)
                Text(title).font(heading ? WL.heading : WL.body).lineLimit(1).truncationMode(.tail)
                Spacer()
                Text(inherited ? "묶음에 포함" : detail).font(WL.meta).foregroundStyle(inherited ? WL.accent.opacity(0.8) : WL.muted)
            }
            .padding(.leading, 8 + CGFloat(depth) * 20)
            .padding(.trailing, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 비활성으로 두면 글자가 흐려져 꺼진 것처럼 보여, 누를 수만 없게 하고 이유를 알린다
        .tip(DesignFormat.path(path) + "\n" + (inherited ? "묶음에 켠 알림에 들어 있습니다. 따로 끄려면 묶음 알림을 끄세요"
                                                 : heading ? "켜면 이 아래 화면 모두, 앞으로 새로 생기는 화면까지 알립니다" : detail))
    }
}
