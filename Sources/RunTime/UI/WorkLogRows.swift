import AppKit
import SwiftUI
import WorkLogCore

/// 하루 보기의 한 줄: 상태 · 내용 · 출처 · 일감 · 상태 글자 · 댓글 단추.
/// 상태 표시를 누르면 상태 고르기, 말풍선을 누르면 일감·댓글·작업 시간을 고치는 창이 뜬다.
struct EntryRow: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    let entry: WorkEntry
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(spacing: 10) {
            Button { page.statusPicking = entry.id } label: { StatusGlyph(status: entry.status) }
                .buttonStyle(.plain)
                .help("상태 바꾸기")
                .popover(isPresented: flag(\.statusPicking), arrowEdge: .bottom) {
                    StatusPicker(current: entry.status) { status in
                        store.update(entry.id) { $0.status = status }
                        page.statusPicking = nil
                    }
                }
            TextField("내용", text: Binding(
                get: { store.entry(entry.id)?.title ?? entry.title },
                set: { value in store.update(entry.id) { $0.title = value } }
            ), onCommit: { store.commitTitle(entry.id) })
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            Spacer(minLength: 6)
            if let source = entry.source { SourceMark(source: source) }
            if let hours = entry.hours, hours > 0 {
                Text(WorkTime.label(hours)).font(WL.number).foregroundStyle(.tertiary)
            }
            if let issue = entry.issue { IssueLabel(issue: issue, posted: !entry.needsRedmine) }
            StatusText(status: entry.status)
            Button { page.editing = entry.id } label: {
                Image(systemName: entry.note.isEmpty ? "text.bubble" : "text.bubble.fill")
            }
            .buttonStyle(GhostIconButtonStyle())
            // 댓글이 있으면 늘 보이고, 없으면 올렸을 때만 (노션처럼 손잡이는 숨겨 둔다)
            .opacity(hover.on || page.editing == entry.id || !entry.note.isEmpty ? 1 : 0)
            .help("일감 번호·레드마인 댓글·작업 시간")
            .popover(isPresented: flag(\.editing), arrowEdge: .trailing) {
                EntryEditor(store: store, page: page, id: entry.id)
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hover.on ? WL.hover : .clear))
        .onHover { hover.on = $0 }
        .contextMenu {
            ForEach(WorkLogFormat.quickStatuses, id: \.self) { status in
                Button(status.label) { store.update(entry.id) { $0.status = status } }
            }
            Divider()
            Button("위로") { store.move(entry.id, by: -1) }
            Button("아래로") { store.move(entry.id, by: 1) }
            Button("한 줄 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("- " + WorkReport.line(entry), forType: .string)
                page.flash("한 줄을 복사했습니다")
            }
            Divider()
            Button("지우기", role: .destructive) { store.delete(entry.id) }
        }
    }

    private func flag(_ key: ReferenceWritableKeyPath<WorkLogPage, UUID?>) -> Binding<Bool> {
        Binding(get: { page[keyPath: key] == entry.id },
                set: { if !$0, page[keyPath: key] == entry.id { page[keyPath: key] = nil } })
    }
}

/// 자동으로 들어온 줄의 출처 표시 (머지한 MR, 머지 전 커밋, 고정 업무).
struct SourceMark: View {
    let source: String

    var body: some View {
        let (icon, help): (String, String) = {
            if source.hasPrefix("mr:") { return ("arrow.triangle.merge", "GitLab에서 머지한 MR " + source.dropFirst(3)) }
            if source.hasPrefix("branch:") { return ("arrow.triangle.branch", "아직 머지 전 브랜치 " + source.dropFirst(7)) }
            return ("repeat", "고정 업무")
        }()
        Image(systemName: icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .help(help)
    }
}

/// 상태 고르기. 끝난 일은 보고서 꼴에 맞춰 완료와 100% 가운데 고르고, 진행은 10% 단위.
struct StatusPicker: View {
    let current: WorkStatus
    let choose: (WorkStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("상태")
            HStack(spacing: 6) {
                option(.done)
                option(.percent(100))
                option(.inProgress)
                option(.ongoing)
            }
            SectionLabel("진행률")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 5), spacing: 6) {
                ForEach(Array(stride(from: 10, through: 90, by: 10)), id: \.self) { option(.percent($0)) }
            }
        }
        .padding(14)
    }

    private func option(_ status: WorkStatus) -> some View {
        let selected = status == current
        return Button { choose(status) } label: {
            HStack(spacing: 5) {
                StatusGlyph(status: status, size: 12)
                Text(status.label).font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 48, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(selected ? WL.accent.opacity(0.14) : Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .strokeBorder(selected ? WL.accent.opacity(0.6) : WL.border.opacity(0.7), lineWidth: selected ? 1 : 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// 일감 번호, 레드마인 댓글, 작업 시간, 보냄 표시를 고친다.
struct EntryEditor: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var sync: WorkLogSync = .shared
    let id: UUID

    var body: some View {
        if let entry = store.entry(id) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    StatusGlyph(status: entry.status).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(WL.heading).lineLimit(2)
                        Text("\(entry.project) · \(WorkLogFormat.dayTitle(entry.day))").font(WL.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                field("레드마인 일감") {
                    HStack(spacing: 6) {
                        TextField("번호", text: Binding(
                            get: { entry.issue.map(String.init) ?? "" },
                            set: { value in store.update(id) { $0.issue = Int(value.filter(\.isNumber)) } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 92)
                        if !sync.myIssues.isEmpty {
                            Menu("내 일감에서") {
                                ForEach(sortedIssues(for: entry), id: \.id) { issue in
                                    Button("#\(String(issue.id))  \(issue.subject) · \(issue.doneRatio)%") {
                                        store.update(id) { $0.issue = issue.id }
                                    }
                                }
                            }
                            .fixedSize()
                        }
                        Spacer()
                        if entry.issue != nil {
                            Text(postedText(entry)).font(WL.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let issue = entry.issue, let info = sync.issueInfo[issue] ?? sync.myIssues.first(where: { $0.id == issue }) {
                    Text("\(info.project) · \(info.subject) · 지금 \(info.doneRatio)%")
                        .font(WL.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                field("작업 시간") {
                    HStack(spacing: 8) {
                        TextField("시간", text: Binding(
                            get: { entry.hours.map { String(format: "%g", $0) } ?? "" },
                            set: { value in store.setEntryHours(id, Double(value.replacingOccurrences(of: ",", with: "."))) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .disabled(entry.timeLogged)
                        Text("시간").font(WL.meta).foregroundStyle(.secondary)
                        if let issue = entry.issue, entry.hours == nil,
                           let guess = sync.suggestedHours(on: entry.day, entries: store.log.entries)[issue] {
                            Button("추정 \(WorkTime.label(guess)) 넣기") { store.setEntryHours(id, guess) }
                                .buttonStyle(TextLinkButtonStyle())
                                .help("이 저장소 폴더에서 Claude Code를 쓴 시간을 그날 일감 수로 나눈 값")
                        }
                        Spacer()
                        if entry.timeLogged { Text("레드마인에 남김").font(WL.caption).foregroundStyle(WL.done) }
                    }
                }
                field("댓글") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: Binding(
                            get: { store.entry(id)?.note ?? "" },
                            set: { value in store.update(id) { $0.note = value } }
                        ))
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: WL.inner).fill(WL.canvas))
                        .overlay(RoundedRectangle(cornerRadius: WL.inner).strokeBorder(WL.border.opacity(0.7), lineWidth: 0.5))
                        .frame(height: 150)
                        HStack(spacing: 10) {
                            Button("양식 넣기") { store.update(id) { $0.note = WorkLogFormat.template(for: $0) } }
                                .buttonStyle(TextLinkButtonStyle())
                                .disabled(!entry.note.isEmpty)
                                .help("[작업 내용]·[연동 API]·[비고] 머리를 넣습니다")
                            Spacer()
                            if entry.note.isEmpty {
                                Text("비우면 내용 한 줄로 [작업 내용]을 만듭니다").font(WL.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Rectangle().fill(WL.border.opacity(0.7)).frame(height: 0.5)
                HStack(spacing: 6) {
                    Button { store.move(id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(GhostIconButtonStyle()).help("위로")
                    Button { store.move(id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(GhostIconButtonStyle()).help("아래로")
                    Spacer()
                    if entry.issue != nil {
                        Button(entry.needsRedmine ? "보낸 것으로 표시" : "다시 보내기") {
                            if entry.needsRedmine { store.markPosted([id]) } else { store.update(id) { $0.postedAt = nil } }
                        }
                        .controlSize(.small)
                    }
                    Button("지우기", role: .destructive) {
                        page.editing = nil
                        store.delete(id)
                    }
                    .controlSize(.small)
                }
            }
            .padding(16)
            .frame(width: 360)
            .onAppear { if let issue = entry.issue { sync.loadInfo([issue]) } }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            content()
        }
    }

    /// 이 줄과 이름이 겹치는 레드마인 프로젝트의 일감을 앞에 둔다.
    private func sortedIssues(for entry: WorkEntry) -> [RedmineAPI.Issue] {
        let project = entry.project.lowercased()
        let related = { (issue: RedmineAPI.Issue) in
            issue.project.lowercased().contains(project) || project.contains(issue.project.lowercased())
        }
        return sync.myIssues.filter(related) + sync.myIssues.filter { !related($0) }
    }

    private func postedText(_ entry: WorkEntry) -> String {
        guard let posted = entry.postedAt else { return "아직 안 보냄" }
        return entry.needsRedmine ? "보낸 뒤 고침" : "보냄 " + WorkLogFormat.when(posted)
    }
}

/// 주간·월간·프로젝트 보기의 모은 줄. 누르면 마지막으로 적은 날로 간다.
struct MergedRow: View {
    @ObservedObject var page: WorkLogPage
    let entry: WorkEntry
    let entries: [WorkEntry]
    @StateObject private var hover = HoverFlag()

    var body: some View {
        let steps = WorkReport.progression(of: entry, in: entries)
        let days = Array(Set(entries.filter { $0.project == entry.project && WorkLogFormat.same($0.title, entry.title) }.map(\.day))).sorted()
        Button {
            page.search = ""
            page.day = entry.day
            page.mode = .day
        } label: {
            HStack(spacing: 10) {
                StatusGlyph(status: entry.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 14)).foregroundStyle(WL.text).multilineTextAlignment(.leading)
                    if steps.count > 1 {
                        Text(steps.map(\.label).joined(separator: " → ")).font(WL.caption).foregroundStyle(WL.muted)
                    }
                }
                Spacer(minLength: 8)
                Text(days.count > 1 ? "\(WorkLogFormat.shortDay(days[0])) 외 \(days.count - 1)일" : WorkLogFormat.shortDay(entry.day))
                    .font(WL.caption).foregroundStyle(.tertiary).monospacedDigit()
                if let issue = entry.issue { IssueLabel(issue: issue) }
                StatusText(status: entry.status)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hover.on ? WL.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}
