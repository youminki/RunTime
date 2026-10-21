import AppKit
import SwiftUI
import WorkLogCore

/// 업무 일지: 왼쪽에서 날과 프로젝트를 고르고, 가운데 페이지에서 적고 고치면, 오른쪽에 보낼 글이 그대로 만들어진다.
/// 가운데는 노션 페이지처럼 큰 제목, 속성 줄, 접을 수 있는 프로젝트 묶음으로 둔다. 상자 대신 여백과 글자 크기로 나눈다.
struct WorkLogView: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var sync: WorkLogSync = .shared
    @ObservedObject var settings: WorkLogSettings = .shared
    /// 할 일 추가 칸 가운데 글을 쓰고 있는 프로젝트 (⌘N으로 옮긴다).
    @FocusState private var focusedDraft: String?

    var body: some View {
        GeometryReader { geo in columns(WorkLogColumns(width: geo.size.width)) }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .bottom) {
            if let message = page.toast {
                Toast(message: message).padding(.bottom, 18).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .sheet(isPresented: $page.importing) { WorkLogImportSheet(store: store, page: page) }
        .onAppear {
            store.applyRecurringToday()
            // 앱 창 안에서 다른 화면을 오갈 때마다 GitLab·레드마인을 다시 부르지 않게 5분에 한 번만 받는다
            if let last = page.lastAutoSync, Date().timeIntervalSince(last) < 300 { return }
            page.lastAutoSync = Date()
            if settings.captureEnabled { sync.capture() }
            if settings.redmineReady {
                sync.loadMyIssues()
                sync.loadStatuses()
            }
        }
    }

    private func columns(_ layout: WorkLogColumns) -> some View {
        HStack(spacing: 0) {
            WorkLogSidebar(store: store, page: page, sync: sync, settings: settings)
                .frame(width: layout.sidebar)
            Rectangle().fill(WL.border).frame(width: 1)
            VStack(spacing: 0) {
                topBar(gutter: layout.gutter)
                Rectangle().fill(WL.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let error = store.loadError ?? store.saveError { notice(error).padding(.bottom, 16) }
                        if !page.search.trimmingCharacters(in: .whitespaces).isEmpty {
                            searchPage
                        } else {
                            switch page.mode {
                            case .day: dayPage
                            case .week: periodPage(weekEntries, span: "이 주")
                            case .month: periodPage(monthEntries, span: "이 달")
                            case .project: projectPage
                            case .issues: IssueBoard(store: store, page: page, sync: sync, settings: settings)
                            }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, layout.gutter)
                    .padding(.top, 32)
                    .padding(.bottom, 60)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(store.loadError != nil)
                }
                .background(WL.canvas)
            }
            Rectangle().fill(WL.border).frame(width: 1)
            WorkLogPreview(store: store, page: page, sync: sync, settings: settings)
                .frame(width: layout.preview)
        }
    }

    // MARK: 위 막대

    /// 보기 탭, 하루 보기 도구, 새로고침. 노션 페이지 위 막대처럼 얇게.
    /// 날 이동은 왼쪽 달력에서 고르고, 단추 대신 ⌘[ ⌘] ⌘T 단축키만 둔다 (좁은 창에서 새로고침이 밀려 잘리지 않게).
    private func topBar(gutter: CGFloat) -> some View {
        HStack(spacing: 4) {
            PageTabs(items: WorkLogPage.Mode.allCases.map { ($0, $0.rawValue) }, selection: Binding(
                get: { page.mode },
                set: { page.search = ""; page.mode = $0 }
            ))
            .layoutPriority(1)
            Spacer(minLength: 8)
            if page.mode == .day {
                Button { carryOver() } label: { Image(systemName: "arrow.turn.down.right") }
                    .buttonStyle(GhostIconButtonStyle())
                    .disabled(carryable == 0)
                    .opacity(carryable == 0 ? 0.4 : 1)
                    .tip(carryHelp)
                Button { page.importText = ""; page.importing = true } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(GhostIconButtonStyle())
                    .tip("보고서 붙여넣기: 써 둔 일일보고를 한 번에 넣기")
            }
            refreshButton
                .layoutPriority(2)
        }
        // 탭 글자 안쪽 여백만큼 덜 띄워 탭 글자가 아래 페이지 제목과 같은 줄에서 시작하게 한다
        .padding(.leading, gutter - 8)
        .padding(.trailing, 14)
        .frame(height: 46)
        .background(WL.canvas)
        .background { keyboardNavigation }
    }

    /// 보이지 않는 단축키: 앞뒤 날(주·달), 오늘, 할 일 추가.
    private var keyboardNavigation: some View {
        ZStack {
            Button("") { page.search = ""; page.step(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("") { page.search = ""; page.step(1) }.keyboardShortcut("]", modifiers: .command)
            Button("") { page.search = ""; page.day = WorkDay.today() }.keyboardShortcut("t", modifiers: .command)
        }
        .disabled(page.mode == .project)
        .overlay { Button("") { newEntry() }.keyboardShortcut("n", modifiers: .command) }
        .hidden()
    }

    private var carryable: Int {
        guard let source = store.log.previousDay(before: page.day) else { return 0 }
        return store.log.carryCandidates(from: source, to: page.day).count
    }

    private var carryHelp: String {
        guard let source = store.log.previousDay(before: page.day) else { return "이어 쓰기: 앞선 기록이 없습니다" }
        return "이어 쓰기: \(WorkLogFormat.dayTitle(source))에 끝나지 않은 일 \(carryable)개를 가져옵니다"
    }

    /// ⌘N: 하루 보기로 가서 첫 프로젝트의 할 일 추가 칸에 들어간다. 프로젝트가 없으면 새 프로젝트 칸을 연다.
    private func newEntry() {
        page.search = ""
        page.mode = .day
        guard let project = shownProjects(dayProjects).first ?? store.log.visibleProjects.first else {
            page.newProject = ""
            page.addingProject = true
            return
        }
        page.openProjects.insert(project)
        page.collapsed.remove("day:" + project)
        // 묶음이 그려진 다음에 칸에 들어가야 한다
        DispatchQueue.main.async { focusedDraft = project }
    }

    private func carryOver() {
        let count = store.carryOver(to: page.day)
        page.flash(count > 0 ? "진행 중이던 일 \(count)개를 가져왔습니다" : "가져올 일이 없습니다")
    }

    /// 새로고침: GitLab MR·커밋과 레드마인 내 일감을 한 번에 다시 받는다. 아이콘만 두면 잘 보이지 않아 글자와 받은 때를 함께 둔다.
    private var refreshButton: some View {
        let busy = sync.capturing || sync.loadingIssues
        let failed = sync.captureError != nil || sync.issuesError != nil
        return Button { refreshNow() } label: {
            // 좁으면 받은 때, 그다음 글자를 빼고 아이콘만 남긴다
            ViewThatFits(in: .horizontal) {
                refreshLabel(busy: busy, failed: failed, title: true, time: true)
                refreshLabel(busy: busy, failed: failed, title: true, time: false)
                refreshLabel(busy: busy, failed: failed, title: false, time: false)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .keyboardShortcut("r", modifiers: .command)
        .tip(refreshHelp)
        .padding(.leading, 4)
    }

    private func refreshLabel(busy: Bool, failed: Bool, title: Bool, time: Bool) -> some View {
            HStack(spacing: 6) {
                Group {
                    if busy {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    } else {
                        Image(systemName: failed ? "exclamationmark.triangle.fill" : "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(failed ? WL.waiting : WL.accent)
                    }
                }
                .frame(width: 14, height: 14)
                if title { Text(busy ? "받는 중" : "새로고침").font(.system(size: 12.5, weight: .semibold)) }
                if time, !busy, let last = lastRefresh {
                    Text(WorkLogFormat.when(last)).font(.system(size: 11.5)).foregroundStyle(WL.faint).monospacedDigit()
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, title ? 10 : 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            .contentShape(Rectangle())
    }

    /// GitLab·레드마인 가운데 늦게 받은 쪽이 아니라 마지막으로 받은 때.
    private var lastRefresh: Date? {
        [settings.captureEnabled ? sync.lastCapture : nil, settings.redmineReady ? sync.issuesLoadedAt : nil]
            .compactMap { $0 }.max()
    }

    private func refreshNow() {
        guard settings.captureEnabled || settings.redmineReady else {
            page.settingsSection = .gitlab
            page.showsSettings = true
            return
        }
        if settings.redmineReady { sync.loadMyIssues() }
        if settings.captureEnabled {
            sync.capture { page.flash(sync.lastAdded > 0 ? "\(sync.lastAdded)줄을 가져왔습니다" : "새로 가져온 줄이 없습니다") }
        } else {
            page.flash("레드마인 내 일감을 다시 받습니다")
        }
    }

    private var refreshHelp: String {
        guard settings.captureEnabled || settings.redmineReady else { return "GitLab·레드마인을 연결하려면 누르세요" }
        var lines = ["GitLab MR·커밋과 레드마인 내 일감 다시 받기 (⌘R) · 10분마다 자동"]
        if let error = sync.captureError { lines.append("GitLab 가져오지 못함: \(error)") }
        if let error = sync.issuesError { lines.append("레드마인 받지 못함: \(error)") }
        return lines.joined(separator: "\n")
    }

    // MARK: 페이지 머리

    // MARK: 하루

    private var dayEntries: [WorkEntry] { store.log.entries(on: page.day) }

    @ViewBuilder
    private var dayPage: some View {
        let entries = dayEntries
        let today = WorkDay.today()
        let pending = Set(entries.filter(\.needsRedmine).compactMap(\.issue)).count
        PageHeading(WorkLogFormat.longDay(page.day)) {
            if page.day == today { DayBadge(text: "오늘") }
            else if page.day == WorkDay.adding(-1, to: today) { DayBadge(text: "어제", tint: WL.muted) }
            if entries.isEmpty {
                Text("기록 없음")
            } else {
                Tally(title: "완료", value: entries.filter(\.status.isFinished).count, tint: WL.done)
                Tally(title: "진행", value: entries.filter { !$0.status.isFinished && $0.status != .ongoing }.count, tint: WL.accent)
                Tally(title: "상시", value: entries.filter { $0.status == .ongoing }.count, tint: WL.quiet)
            }
        } accessory: {
            if pending > 0 {
                HeadingAction(title: "레드마인 \(pending)건 보내기", icon: "paperplane", tint: WL.waiting) { page.preview = .redmine }
                    .tip("오른쪽 레드마인 탭에서 보낼 내용을 확인합니다")
            } else if entries.contains(where: { $0.issue != nil }) {
                Label("레드마인 모두 보냄", systemImage: "checkmark").font(.system(size: 12.5)).foregroundStyle(WL.muted)
            }
        }
        let projects = shownProjects(dayProjects)
        ForEach(projects, id: \.self) { project in
            projectSection(project, entries: entries.filter { $0.project == project })
        }
        // 숨긴 프로젝트 줄만 있는 날도 빈 날 안내를 보인다 (아래에 숨긴 줄 보기가 함께 나온다)
        if projects.isEmpty { emptyDay }
        hiddenToggle(entries)
        otherProjects(excluding: projects)
    }

    /// 숨긴 프로젝트는 펼쳐 보기 전까지 빼고 보인다. 보고서에는 그대로 들어간다.
    private func shownProjects(_ projects: [String]) -> [String] {
        page.showsHidden ? projects : projects.filter { !store.log.hiddenProjects.contains($0) }
    }

    @ViewBuilder
    private func hiddenToggle(_ entries: [WorkEntry]) -> some View {
        let hidden = entries.filter { store.log.hiddenProjects.contains($0.project) }
        if !hidden.isEmpty {
            Button { page.showsHidden.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: page.showsHidden ? "eye.slash" : "eye").font(.system(size: 10.5))
                    Text(page.showsHidden ? "숨긴 프로젝트 가리기"
                         : "숨긴 프로젝트 \(Set(hidden.map(\.project)).count)개 · \(hidden.count)줄 보기")
                    Text("보고서에는 들어갑니다").foregroundStyle(WL.faint)
                }
                .foregroundStyle(WL.muted)
            }
            .buttonStyle(GhostTextButtonStyle())
            .padding(.bottom, 12)
        }
    }

    /// 이 날 기록이 있는 프로젝트와, 방금 열어 둔 빈 프로젝트.
    private var dayProjects: [String] {
        var projects = store.log.orderedProjects(of: dayEntries)
        for name in store.log.allProjects where page.openProjects.contains(name) && !projects.contains(name) { projects.append(name) }
        return projects
    }

    private var emptyDay: some View {
        Callout {
            VStack(alignment: .leading, spacing: 10) {
                Text(page.day == WorkDay.today() ? "오늘 적은 일이 아직 없습니다" : "이 날은 기록이 없습니다")
                    .font(.system(size: 13, weight: .semibold))
                Text(settings.captureEnabled
                     ? "머지한 MR과 머지 전 커밋은 10분마다 자동으로 들어옵니다. 회의처럼 git에 남지 않는 일만 아래에서 프로젝트를 골라 적으세요.\(quickAddHint)"
                     : "GitLab을 연결하면 머지한 MR과 커밋이 자동으로 들어옵니다. 지금은 프로젝트를 골라 직접 적거나 써 둔 보고서를 붙여 넣을 수 있습니다.")
                    .font(.system(size: 12.5)).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if settings.captureEnabled {
                        Button("지금 가져오기") { sync.capture() }.buttonStyle(NotionButtonStyle())
                    } else {
                        Button("GitLab 연결") { page.settingsSection = .gitlab; page.showsSettings = true }
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                    }
                    Button("보고서 붙여넣기") { page.importText = ""; page.importing = true }.buttonStyle(NotionButtonStyle())
                }
            }
        }
        .padding(.bottom, 20)
    }

    /// 한 줄 적기 단축키는 설정에서 끌 수 있어 켜져 있을 때만 알린다.
    private var quickAddHint: String {
        settings.quickAddEnabled ? " 다른 앱에서는 \(GlobalHotKey.quickCombo.label)로 바로 적을 수 있습니다." : ""
    }

    private func projectSection(_ project: String, entries: [WorkEntry]) -> some View {
        let key = "day:" + project
        let collapsed = page.collapsed.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            if page.renaming == project {
                // 이름 칸은 접기 단추 밖에 둔다 (칸을 누를 때 묶음이 접히지 않게)
                HStack(spacing: 8) {
                    Color.clear.frame(width: 16, height: 16)
                    ProjectSwatch(name: project, size: 10)
                    TextField("프로젝트 이름", text: $page.renameText, onCommit: {
                        page.renamed(project, to: page.renameText)
                        store.renameProject(project, to: page.renameText)
                        page.renaming = nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onExitCommand { page.renaming = nil }
                    Text("Enter 저장 · Esc 취소").font(.system(size: 12)).foregroundStyle(WL.faint)
                }
                .frame(height: 34)
            } else {
                ToggleHeading(collapsed: collapsed, toggle: { page.toggle(key) }) {
                    HStack(spacing: 8) {
                        ProjectSwatch(name: project, size: 10)
                        Text(project).font(WL.section)
                        Text("\(entries.count)").font(.system(size: 13)).foregroundStyle(WL.faint).monospacedDigit()
                    }
                } trailing: {
                    projectMenu(project, isEmpty: entries.isEmpty)
                }
            }
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    let reserve = entries.contains { $0.issue != nil }
                    PathGroupedRows(entries: entries, pinned: page.pinnedPaths) { entry, path in
                        EntryRow(store: store, page: page, entry: entry, reservesIssue: reserve, path: path)
                    }
                    addField(project)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.bottom, 18)
    }

    private func projectMenu(_ project: String, isEmpty: Bool) -> some View {
        Menu {
            Button("이름 바꾸기") { page.renameText = project; page.renaming = project }
            Button("보고서에서 위로") { store.moveProject(project, by: -1) }
            Button("보고서에서 아래로") { store.moveProject(project, by: 1) }
            Divider()
            Button("이 프로젝트 기록 모두 보기") { page.project = project; page.mode = .project }
            Button("목록에서 숨기기") {
                page.openProjects.remove(project)
                store.setHidden(project, true)
                page.flash("‘\(project)’를 숨겼습니다. 왼쪽 아래 숨긴 프로젝트에서 다시 보입니다")
            }
            if isEmpty {
                Divider()
                Button("닫기") { page.openProjects.remove(project) }
                Button("프로젝트 목록에서 빼기") {
                    page.openProjects.remove(project)
                    store.removeProjectIfEmpty(project)
                }
            }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(WL.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("이름 바꾸기·보고서 순서·숨기기")
    }

    private func addField(_ project: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WL.faint)
                .frame(width: 16)
            TextField("할 일 추가", text: Binding(
                get: { page.drafts[project] ?? "" },
                set: { page.drafts[project] = $0 }
            ), onCommit: {
                let text = (page.drafts[project] ?? "").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                let parsed = WorkLogFormat.splitStatus(text)
                store.add(day: page.day, project: project, title: parsed.title, status: parsed.status)
                page.drafts[project] = ""
            })
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($focusedDraft, equals: project)
            .tip("끝에 (60%)·(상시)를 붙이면 상태로, #1234를 붙이면 일감 번호로 저장합니다 (⌘N)")
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .hoverRow()
    }

    @ViewBuilder
    private func otherProjects(excluding shown: [String]) -> some View {
        let others = store.log.visibleProjects.filter { !shown.contains($0) }
        if !others.isEmpty || shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(shown.isEmpty ? "프로젝트를 골라 적기" : "다른 프로젝트에도 적기")
                    .font(.system(size: 12)).foregroundStyle(WL.faint)
                FlowLayout(spacing: 2) {
                    ForEach(others, id: \.self) { name in
                        Button { page.openProjects.insert(name) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .medium)).foregroundStyle(WL.faint)
                                ProjectSwatch(name: name, size: 8)
                                Text(name).foregroundStyle(WL.muted)
                            }
                        }
                        .buttonStyle(GhostTextButtonStyle())
                    }
                    Button { page.newProject = ""; page.addingProject = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .medium))
                            Text("새 프로젝트")
                        }
                        .foregroundStyle(WL.muted)
                    }
                    .buttonStyle(GhostTextButtonStyle())
                    .tip("왼쪽 프로젝트 목록에 이름 칸이 열립니다")
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: 주간·월간

    private var weekEntries: [WorkEntry] { store.log.entries(in: WorkDay.week(of: page.day)) }
    private var monthEntries: [WorkEntry] { store.log.entries(in: WorkDay.month(of: page.day)) }

    @ViewBuilder
    private func periodPage(_ entries: [WorkEntry], span: String) -> some View {
        let merged = WorkReport.merged(entries)
        PageHeading(page.mode == .week ? WorkLogFormat.weekTitle(page.day) : WorkLogFormat.monthTitle(page.day)) {
            Tally(title: "한 일", value: merged.count)
            Tally(title: "완료", value: merged.filter(\.status.isFinished).count, tint: WL.done)
            Tally(title: "진행", value: merged.filter { !$0.status.isFinished && $0.status != .ongoing }.count, tint: WL.accent)
            Text("\(Set(entries.map(\.day)).count)일 기록").monospacedDigit()
        } accessory: {
            let pending = Set(entries.filter(\.needsRedmine).compactMap(\.issue)).count
            if pending > 0 {
                HeadingAction(title: "레드마인 \(pending)건 보내기", icon: "paperplane", tint: WL.waiting) { page.preview = .redmine }
                    .tip("\(span) 아직 보내지 않은 일감을 오른쪽 레드마인 탭에서 확인합니다")
            }
        }
        if merged.isEmpty {
            Callout {
                Text("\(span)는 기록이 없습니다. 왼쪽 달력에서 점이 찍힌 날을 고르세요.")
                    .font(.system(size: 12.5)).foregroundStyle(WL.muted)
            }
        } else {
            ForEach(shownProjects(store.log.orderedProjects(of: merged)), id: \.self) { project in
                mergedSection(project, merged: merged.filter { $0.project == project }, entries: entries)
            }
            hiddenToggle(merged)
            Text("같은 프로젝트의 같은 일은 한 줄로 모으고 \(span) 마지막 상태를 씁니다. 줄을 누르면 그날로 갑니다.")
                .font(.system(size: 12)).foregroundStyle(WL.faint)
        }
    }

    private func mergedSection(_ project: String, merged: [WorkEntry], entries: [WorkEntry]) -> some View {
        let key = "period:" + project
        let collapsed = page.collapsed.contains(key)
        let done = merged.filter(\.status.isFinished).count
        return VStack(alignment: .leading, spacing: 0) {
            ToggleHeading(collapsed: collapsed, toggle: { page.toggle(key) }) {
                HStack(spacing: 8) {
                    ProjectSwatch(name: project, size: 10)
                    Text(project).font(WL.section)
                    Text("\(done)/\(merged.count) 완료").font(.system(size: 12.5)).foregroundStyle(WL.faint).monospacedDigit()
                }
            } trailing: { EmptyView() }
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    let reserve = merged.contains { $0.issue != nil }
                    PathGroupedRows(entries: merged) { entry, path in
                        MergedRow(page: page, entry: entry, entries: entries, reservesIssue: reserve, path: path)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.bottom, 18)
    }

    // MARK: 프로젝트

    private var selectedProject: String? {
        page.selectedProject(in: store.log)
    }

    private var projectEntries: [WorkEntry] {
        guard let project = selectedProject else { return [] }
        return store.log.entries.filter { $0.project == project }
    }

    @ViewBuilder
    private var projectPage: some View {
        let entries = projectEntries
        if let project = selectedProject, !entries.isEmpty {
            let merged = WorkReport.merged(entries)
            let open = merged.filter { !$0.status.isFinished && $0.status != .ongoing }
            let days = Array(Set(entries.map(\.day))).sorted(by: >)
            PageHeading(project) {
                Text("\(WorkLogFormat.shortDay(days.last ?? "")) ~ \(WorkLogFormat.shortDay(days.first ?? ""))").monospacedDigit()
                Text("\(days.count)일 · \(entries.count)줄").monospacedDigit()
                Tally(title: "진행 중", value: open.count, tint: WL.accent)
                Tally(title: "일감", value: Set(entries.compactMap(\.issue)).count)
            } accessory: {
                EmptyView()
            }
            if !open.isEmpty {
                section(key: "project-open", title: "진행 중인 일") {
                    PathGroupedRows(entries: open) { entry, path in
                        MergedRow(page: page, entry: entry, entries: entries, reservesIssue: open.contains { $0.issue != nil },
                                  path: path)
                    }
                }
            }
            ForEach(days, id: \.self) { day in
                section(key: "project:" + day, title: WorkLogFormat.dayTitle(day), jump: day) {
                    let dayRows = entries.filter { $0.day == day }
                    PathGroupedRows(entries: dayRows) { entry, path in
                        MergedRow(page: page, entry: entry, entries: dayRows,
                                  reservesIssue: entries.contains { $0.issue != nil }, path: path, showsDays: false)
                    }
                }
            }
            .id(project)
        } else {
            PageHeading("프로젝트") { EmptyView() } accessory: { EmptyView() }
            Callout {
                Text("하루 보기에서 일을 적거나 GitLab을 연결하면 프로젝트별로 모입니다.").font(.system(size: 12.5)).foregroundStyle(WL.muted)
            }
        }
    }

    private func section<Content: View>(key: String, title: String, jump: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        let collapsed = page.collapsed.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            ToggleHeading(collapsed: collapsed, toggle: { page.toggle(key) }) {
                Text(title).font(WL.section)
            } trailing: {
                if let jump {
                    Button("이 날 열기") { page.day = jump; page.mode = .day }.buttonStyle(TextLinkButtonStyle(tint: WL.muted))
                }
            }
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) { content() }.padding(.leading, 16)
            }
        }
        .padding(.bottom, 18)
    }

    // MARK: 찾기

    @ViewBuilder
    private var searchPage: some View {
        let results = store.log.search(page.search)
        PageHeading("‘\(page.search)’ 찾기") {
            Text("\(results.count)줄 · \(Set(results.map(\.day)).count)일").monospacedDigit()
        } accessory: {
            Button("지우기") { page.search = "" }.buttonStyle(NotionButtonStyle())
        }
        if results.isEmpty {
            Callout {
                Text("맞는 기록이 없습니다. 내용, 댓글, 프로젝트, #일감번호에서 찾고 초성(ㄷㅇㅌ)으로도 찾습니다.")
                    .font(.system(size: 12.5)).foregroundStyle(WL.muted)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(results.prefix(200)), id: \.id) { entry in SearchResultRow(page: page, entry: entry) }
            }
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.red)
            Text(text).font(.system(size: 12.5))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.red.opacity(0.08)))
    }
}

/// 업무 일지 칸 너비에 따른 세 칸 너비. 좁을수록 양옆을 줄여 가운데 할 일이 한 줄에 들어오게 하고
/// 넓은 창에서는 남는 너비를 보고서 칸에 준다 (가운데는 760에서 더 넓어지지 않는다).
struct WorkLogColumns {
    let sidebar: CGFloat
    let preview: CGFloat
    let gutter: CGFloat

    init(width: CGFloat) {
        switch width {
        case ..<1100: (sidebar, preview, gutter) = (200, 300, 20)
        case ..<1280: (sidebar, preview, gutter) = (220, 320, 24)
        case ..<1480: (sidebar, preview, gutter) = (240, 340, 36)
        default: (sidebar, preview, gutter) = (240, 400, 36)
        }
    }
}

/// 위 막대의 글자 단추 (오늘·이번 주).
struct TopBarTextStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(WL.muted)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(configuration.isPressed ? WL.hover : .clear))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// 테두리 없는 글자 단추. 올렸을 때만 옅은 바탕 (노션의 `+ 새로 만들기`처럼).
struct GhostTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostTextBody(configuration: configuration)
    }

    private struct GhostTextBody: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var hover = HoverFlag()

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? WL.hover.opacity(2) : hover.on ? WL.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hover.on = $0 }
        }
    }
}

private struct SearchResultRow: View {
    @ObservedObject var page: WorkLogPage
    let entry: WorkEntry

    var body: some View {
        Button {
            page.search = ""
            page.day = entry.day
            page.mode = .day
        } label: {
            HStack(spacing: 10) {
                Text(WorkLogFormat.shortDay(entry.day))
                    .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(WL.muted)
                    .frame(width: 74, alignment: .leading)
                StatusGlyph(status: entry.status)
                let crumb = WorkLogFormat.breadcrumb(entry.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(crumb.leaf).font(.system(size: 14)).foregroundStyle(WL.text).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        ProjectSwatch(name: entry.project, size: 7)
                        Text(entry.project).fixedSize()
                        if let path = crumb.path {
                            Text("·")
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(WL.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tip(entry.title)
                IssueSlot(issue: entry.issue, posted: entry.issue == nil ? nil : !entry.needsRedmine)
                StatusText(status: entry.status)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRow()
    }
}

/// 써 둔 보고서 붙여 넣기.
struct WorkLogImportSheet: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage

    var body: some View {
        let parsed = WorkReport.parse(page.importText, day: page.day)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("보고서 붙여넣기").font(WL.title)
                Text("\(WorkLogFormat.dayTitle(page.day))에 넣습니다. ‘1. 프로젝트’ 아래 ‘- 내용 (완료)’ 꼴을 읽고, #1234는 일감 번호로 저장합니다.")
                    .font(.system(size: 12.5)).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $page.importText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(WL.callout))
                .frame(height: 240)
            HStack(spacing: 8) {
                Text(parsed.isEmpty ? "읽은 줄 없음" : "프로젝트 \(Set(parsed.map(\.project)).count)개 · \(parsed.count)줄")
                    .font(.system(size: 12.5)).monospacedDigit()
                    .foregroundStyle(parsed.isEmpty ? WL.muted : WL.done)
                Spacer()
                Button("클립보드에서") { page.importText = NSPasteboard.general.string(forType: .string) ?? "" }
                    .buttonStyle(NotionButtonStyle())
                Button("취소") { page.importing = false }
                    .buttonStyle(NotionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("넣기") {
                    let count = store.importReport(page.importText, day: page.day)
                    page.importing = false
                    page.flash("\(count)줄을 넣었습니다")
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .disabled(parsed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(WL.canvas)
    }
}
