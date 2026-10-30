import AppKit
import SwiftUI
import WorkLogCore

/// 하루 보기의 한 줄: 상태 · 내용 · 출처 · 일감 · 상태 글자 · 댓글 단추.
/// 상태 표시를 누르면 상태 고르기, 말풍선을 누르면 일감·댓글을 고치는 창이 뜬다.
struct EntryRow: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    let entry: WorkEntry
    var reservesIssue = true
    /// 같은 경로 묶음 안이면 그 경로. 글 칸에는 끝 이름만 두고, 고친 이름 앞에 경로를 다시 붙여 저장한다.
    var path: String? = nil
    @StateObject private var hover = HoverFlag()
    @StateObject private var drop = HoverFlag()
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { page.statusPicking = entry.id } label: { StatusGlyph(status: entry.status) }
                .buttonStyle(.plain)
                .tip("상태·진척률 바꾸기")
                .popover(isPresented: flag(\.statusPicking), arrowEdge: .bottom) {
                    StatusPicker(current: entry.status) { status in
                        store.update(entry.id) { $0.status = status }
                        page.statusPicking = nil
                    }
                }
            // 다른 일지 보기처럼 한 줄로 두고 넘치면 …로 줄인다. 고치지 않을 때는 글 칸 글자를 감추고 같은 자리에
            // 잘린 글을 덮어 보이며, 누르면 아래 글 칸이 초점을 받아 전체 글을 고친다
            TextField("내용", text: Binding(
                get: { leaf(store.entry(entry.id)?.title ?? entry.title) },
                set: { value in
                    let text = value.replacingOccurrences(of: "\n", with: " ")
                    // 글 칸이 끝 이름만 보이고 있었을 때만 경로를 다시 붙인다 (보이던 그대로 저장해 경로가 두 번 붙지 않게).
                    // 끝 이름을 다 지우면 경로만 남기지 않고 빈 줄로 둔다 (Return이면 줄이 지워진다)
                    let current = store.entry(entry.id)?.title ?? entry.title
                    store.update(entry.id) {
                        $0.title = text.isEmpty ? "" : showsLeaf(current) ? path! + " > " + text : text
                    }
                }
            ))
            .focused($editing)
            // 고치는 동안은 지금 묶음에 붙잡아 둔다. 치다가 다른 경로와 같아져도 줄이 옮겨 가지 않는다
            .onChange(of: editing) { on in page.pinnedPaths[entry.id] = on ? (path ?? "") : nil }
            .onSubmit { store.commitTitle(entry.id) }
            .lineLimit(1)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(editing ? WL.text : .clear)
            .overlay(alignment: .leading) {
                if !editing {
                    let shown = leaf(store.entry(entry.id)?.title ?? entry.title)
                    // 글 칸 글자를 감추면 비어 있을 때의 자리표시자도 함께 사라져 여기서 대신 쓴다
                    Text(shown.isEmpty ? "내용" : shown)
                        .font(.system(size: 14))
                        .foregroundStyle(shown.isEmpty ? WL.faint : WL.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                }
            }
            .padding(.vertical, 6)
            // 빈칸을 두면 글 칸과 너비를 반씩 나눠 제목이 잘려, 글 칸이 남은 너비를 다 쓰게 한다
            .frame(maxWidth: .infinity)
            .tip(editing ? "" : entry.title)
            IssueSlot(issue: entry.issue, posted: entry.issue == nil ? nil : !entry.needsRedmine, reserve: reservesIssue,
                      showsSource: true, source: entry.source)
            StatusText(status: entry.status)
            Button { page.editing = entry.id } label: {
                // 댓글이 있는 줄이 많아 늘 진하면 줄마다 눈에 걸려, 올렸을 때만 진하게 한다
                Image(systemName: entry.note.isEmpty ? "text.bubble" : "text.bubble.fill")
                    .foregroundStyle(hover.on || page.editing == entry.id ? WL.muted : WL.faint)
            }
            .buttonStyle(GhostIconButtonStyle())
            // 댓글이 있으면 늘 보이고, 없으면 올렸을 때만 (노션처럼 손잡이는 숨겨 둔다)
            .opacity(hover.on || page.editing == entry.id || !entry.note.isEmpty ? 1 : 0)
            .tip("일감 번호·레드마인 댓글 고치기")
            .popover(isPresented: flag(\.editing), arrowEdge: .trailing) {
                EntryEditor(store: store, page: page, id: entry.id)
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hover.on ? WL.hover : .clear))
        // 노션처럼 줄 왼쪽 바깥에 손잡이를 두어, 글 칸을 끌어 고르는 것과 줄을 옮기는 것이 섞이지 않게 한다
        .overlay(alignment: .leading) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(WL.quiet)
                .frame(width: 14, height: 24)
                .contentShape(Rectangle())
                .opacity(hover.on ? 1 : 0)
                .offset(x: -16)
                .draggable(entry.id.uuidString) {
                    Text(entry.title).font(.system(size: 13.5)).padding(6).background(WL.surface)
                }
                .tip("끌어서 순서 바꾸기")
        }
        .overlay(alignment: .top) {
            if drop.on { Rectangle().fill(WL.accent).frame(height: 2).offset(y: -1) }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            store.move(id, before: entry.id)
            return true
        } isTargeted: { drop.on = $0 }
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

    /// 묶음 안이면 경로를 뗀 끝 이름. 경로 앞뒤 빈칸이 달라도 같은 경로면 뗀다.
    private func leaf(_ title: String) -> String {
        guard let path, showsLeaf(title) else { return title }
        if title.hasPrefix(path + " > ") { return String(title.dropFirst(path.count + 3)) }
        return WorkLogFormat.breadcrumb(title).leaf
    }

    private func showsLeaf(_ title: String) -> Bool {
        guard let path else { return false }
        return title.hasPrefix(path + " > ") || WorkLogFormat.breadcrumb(title).path == path
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
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(WL.muted)
            .tip(help)
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
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 5), spacing: 6) {
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
                Text(status.label).font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .lineLimit(1).fixedSize()
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

/// 일감 번호, 레드마인 댓글, 보냄 표시를 고친다.
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
                            Menu {
                                ForEach(sortedIssues(for: entry), id: \.id) { issue in
                                    Button("#\(String(issue.id))  \(issue.reportTitle) · \(issue.doneRatio)%") {
                                        store.update(id) { $0.issue = issue.id }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("내 일감에서 고르기")
                                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(WL.accent)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                        Spacer()
                        if entry.issue != nil {
                            Text(postedText(entry)).font(WL.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if entry.issue == nil {
                    let suggestions = IssueMatch.suggest(entry.title, in: Array(store.log.issues.values))
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel("맞을 만한 일감")
                            ForEach(suggestions) { info in
                                Button { store.update(id) { $0.issue = info.id } } label: {
                                    HStack(spacing: 6) {
                                        Text("#" + String(info.id)).font(WL.number).foregroundStyle(WL.muted)
                                        Text(info.reportTitle).font(.system(size: 13)).foregroundStyle(WL.text).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .hoverRow()
                            }
                        }
                    }
                }
                if let issue = entry.issue, let info = sync.info(issue) {
                    Text("\(info.reportTitle) · 레드마인 \(info.doneRatio)%")
                        .font(WL.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                field("댓글") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: Binding(
                            get: { store.entry(id)?.note ?? "" },
                            set: { value in store.update(id) { $0.note = value } }
                        ))
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: WL.inner).fill(WL.canvas))
                        .overlay(RoundedRectangle(cornerRadius: WL.inner).strokeBorder(WL.border.opacity(0.7), lineWidth: 0.5))
                        .frame(height: 150)
                        HStack(spacing: 10) {
                            Button("양식 넣기") { store.update(id) { $0.note = WorkLogFormat.template(for: $0) } }
                                .buttonStyle(TextLinkButtonStyle())
                                .disabled(!entry.note.isEmpty)
                                .tip("[작업 내용]·[연동 API]·[비고] 머리를 넣습니다")
                            Spacer()
                            if entry.note.isEmpty {
                                Text("비우면 내용 한 줄로 [작업 내용]을 만듭니다").font(WL.caption).foregroundStyle(WL.muted)
                            }
                        }
                    }
                }
                Rectangle().fill(WL.border.opacity(0.7)).frame(height: 0.5)
                HStack(spacing: 6) {
                    Button { store.move(id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(GhostIconButtonStyle()).tip("위로 옮기기")
                    Button { store.move(id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(GhostIconButtonStyle()).tip("아래로 옮기기")
                    Spacer()
                    if entry.issue != nil {
                        Button(entry.needsRedmine ? "보낸 것으로 표시" : "다시 보내기") {
                            if entry.needsRedmine { store.markPosted([id]) } else { store.update(id) { $0.postedAt = nil } }
                        }
                        .buttonStyle(TextLinkButtonStyle(tint: WL.muted))
                    }
                    Button("지우기") {
                        page.editing = nil
                        store.delete(id)
                    }
                    .buttonStyle(TextLinkButtonStyle(tint: Palette.red))
                    .padding(.leading, 8)
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
    private func sortedIssues(for entry: WorkEntry) -> [IssueInfo] {
        let project = entry.project.lowercased()
        let related = { (issue: IssueInfo) in
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
/// 한 줄에 이름, 상태 흐름, 적은 날, 일감 번호, 상태를 두고 오른쪽 칸 너비를 맞춰 아래위로 읽히게 한다.
struct MergedRow: View {
    @ObservedObject var page: WorkLogPage
    let entry: WorkEntry
    let entries: [WorkEntry]
    var reservesIssue = true
    /// 같은 경로 묶음 안이면 그 경로 (이름만 보인다). 혼자인 줄은 경로를 옅게 앞에 붙인다.
    var path: String? = nil
    /// 적은 날 칸을 보일지. 하루씩 나눈 묶음 안에서는 같은 날이라 뺀다.
    var showsDays = true
    @StateObject private var hover = HoverFlag()

    var body: some View {
        let steps = WorkReport.progression(of: entry, in: entries)
        let days = Array(Set(entries.filter { $0.project == entry.project && WorkLogFormat.same($0.title, entry.title) }.map(\.day))).sorted()
        let crumb = WorkLogFormat.breadcrumb(entry.title)
        Button {
            page.search = ""
            page.day = entry.day
            page.mode = .day
        } label: {
            HStack(spacing: 10) {
                StatusGlyph(status: entry.status)
                title(crumb)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tip(tip(days: days, steps: steps))
                if steps.count > 1 {
                    Text(steps.map(\.label).joined(separator: " → "))
                        .font(WL.caption).foregroundStyle(WL.muted).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
                if showsDays {
                    Text(days.count > 1 ? "\(WorkReport.shortDate(days[0])) 외 \(days.count - 1)일" : WorkLogFormat.shortDay(entry.day))
                        .font(WL.caption).foregroundStyle(WL.quiet).monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 64, alignment: .trailing)
                }
                IssueSlot(issue: entry.issue, posted: entry.issue == nil ? nil : !entry.needsRedmine, reserve: reservesIssue)
                StatusText(status: entry.status)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hover.on ? WL.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }

    private func title(_ crumb: (path: String?, leaf: String)) -> Text {
        guard path == nil, let prefix = crumb.path else { return Text(crumb.leaf).foregroundColor(WL.text) }
        return Text(prefix + " > ").foregroundColor(WL.faint) + Text(crumb.leaf).foregroundColor(WL.text)
    }

    private func tip(days: [String], steps: [WorkStatus]) -> String {
        var lines = [entry.title]
        if !days.isEmpty { lines.append(days.map(WorkLogFormat.shortDay).joined(separator: ", ")) }
        if steps.count > 1 { lines.append(steps.map(\.label).joined(separator: " → ")) }
        return lines.joined(separator: "\n")
    }
}
