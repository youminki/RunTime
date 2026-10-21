import SwiftUI
import WorkLogCore

/// 레드마인 일감의 상태·시작일·완료 기한·담당자 고르기.
/// 고르지 않은 칸은 "그대로"(또는 일지로 정한 자동 값)이고, 고른 칸만 `edit`에 들어간다.
struct IssueFieldEditor<Footer: View>: View {
    let current: IssueInfo?
    /// 일지로 정한 값 (카드에서만). 고르지 않으면 이 값이 나간다.
    var auto = WorkReport.IssueFields()
    @Binding var edit: WorkReport.IssueEdit
    @ObservedObject var sync: WorkLogSync
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        let fields = WorkReport.IssueFields.merged(auto: auto, edit: edit, current: current, statuses: sync.statuses)
        VStack(alignment: .leading, spacing: 12) {
            if let current {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.isQA ? IssueInfo.cleanSubject(current.subject) : current.reportTitle).font(WL.heading).lineLimit(2)
                    Text("#\(String(current.id)) · \(current.project)").font(WL.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            row("상태", now: current?.status) {
                Picker("", selection: Binding(
                    get: { edit.statusID ?? 0 },
                    set: { edit.statusID = $0 == 0 ? nil : $0 }
                )) {
                    Text(auto.status.map { "자동 · \($0.name)" } ?? "그대로").tag(0)
                    ForEach(sync.statuses) { Text($0.name).tag($0.id) }
                }
                .disabled(sync.statuses.isEmpty)
            }
            DateRow(title: "시작일", now: current?.startDate, auto: auto.startDate, value: $edit.startDate)
            DateRow(title: "완료 기한", now: current?.dueDate, auto: auto.dueDate, value: $edit.dueDate)
            row("담당자", now: current?.assignee?.name) {
                Picker("", selection: Binding(
                    get: { edit.assignee?.id ?? 0 },
                    set: { id in edit.assignee = members.first { $0.id == id } }
                )) {
                    Text("그대로").tag(0)
                    ForEach(members) { Text($0.name).tag($0.id) }
                }
                .disabled(members.isEmpty)
            }
            if let problem = fields.problem(current: current) {
                Text(problem).font(WL.caption).foregroundStyle(WL.waiting)
            }
            Rectangle().fill(WL.border.opacity(0.7)).frame(height: 0.5)
            HStack(spacing: 10) {
                Button("고른 것 지우기") { edit = .init() }
                    .buttonStyle(TextLinkButtonStyle(tint: WL.muted))
                    .disabled(edit.isEmpty)
                Spacer()
                footer()
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { sync.loadMembers(project: current?.projectID) }
    }

    /// 담당자 후보: 프로젝트 구성원. 아직 못 받았으면 지금 담당자만이라도 보인다.
    private var members: [RedmineAPI.Member] {
        let list = current?.projectID.flatMap { sync.members[$0] } ?? []
        guard let now = current?.assignee, !list.contains(now) else { return list }
        return [now] + list
    }

    private func row<Control: View>(_ title: String, now: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text("지금 " + (now?.isEmpty == false ? now! : "없음")).font(WL.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
            control().labelsHidden().frame(maxWidth: .infinity)
        }
    }
}

/// 날짜 칸: 그대로(자동) · 날짜 정하기 · 비우기.
private struct DateRow: View {
    let title: String
    let now: String?
    let auto: String?
    @Binding var value: String?

    private enum Mode: Int { case keep, set, clear }

    var body: some View {
        let mode: Mode = value == nil ? .keep : value == "" ? .clear : .set
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text("지금 " + (now.map(WorkLogFormat.shortDay) ?? "없음")).font(WL.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
            Picker("", selection: Binding(
                get: { mode },
                set: { next in
                    switch next {
                    case .keep: value = nil
                    case .clear: value = ""
                    case .set: value = auto?.isEmpty == false ? auto : now ?? WorkDay.today()
                    }
                }
            )) {
                Text(auto.map { $0.isEmpty ? "자동 · 비우기" : "자동 · \(WorkReport.shortDate($0))" } ?? "그대로").tag(Mode.keep)
                Text("날짜 정하기").tag(Mode.set)
                Text("비우기").tag(Mode.clear)
            }
            .labelsHidden()
            .frame(width: mode == .set ? 116 : nil)
            .frame(maxWidth: mode == .set ? nil : .infinity)
            if mode == .set {
                DatePicker("", selection: Binding(
                    get: { value.flatMap(WorkDay.date) ?? Date() },
                    set: { value = WorkDay.key($0) }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
                .environment(\.locale, Locale(identifier: "ko_KR"))
            }
        }
    }
}
