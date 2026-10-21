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
        HStack(spacing: 0) {
            WorkLogSidebar(store: store, page: page, sync: sync, settings: settings)
                .frame(width: 240)
            Rectangle().fill(WL.border).frame(width: 1)
            VStack(spacing: 0) {
                topBar
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
                    .padding(.horizontal, 44)
                    .padding(.top, 32)
                    .padding(.bottom, 60)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(store.loadError != nil)
                }
                .background(WL.canvas)
            }
            .frame(minWidth: 540)
            Rectangle().fill(WL.border).frame(width: 1)
            WorkLogPreview(store: store, page: page, sync: sync, settings: settings)
                .frame(width: 340)
        }
        .frame(minWidth: 1140, minHeight: 700)
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .bottom) {
            if let message = page.toast {
                Toast(message: message).padding(.bottom, 18).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .sheet(isPresented: $page.importing) { WorkLogImportSheet(store: store, page: page) }
        .sheet(isPresented: $page.showsSettings) { WorkLogSettingsView(settings: settings, sync: sync, page: page, store: store) }
        .onAppear {
            store.applyRecurringToday()
            if settings.captureEnabled { sync.capture() }
            if settings.redmineReady {
                sync.loadMyIssues()
                sync.loadStatuses()
            }
        }
    }

    // MARK: 위 막대

    /// 보기 탭과 날짜 이동, 할 일 단추. 노션 페이지 위 막대처럼 얇게.
    /// 탭을 바꿔도 단추 자리가 그대로이게, 그 보기에서 못 쓰는 단추는 빼지 않고 숨긴다.
    private var topBar: some View {
        let navigable = page.mode != .project
        let dayTools = page.mode == .day
        return HStack(spacing: 4) {
            PageTabs(items: WorkLogPage.Mode.allCases.map { ($0, $0.rawValue) }, selection: Binding(
                get: { page.mode },
                set: { page.search = ""; page.mode = $0 }
            ))
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Button { page.search = ""; page.step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(GhostIconButtonStyle())
                    .keyboardShortcut("[", modifiers: .command)
                    .help("이전 (⌘[)")
                Button(todayTitle) { page.search = ""; page.day = WorkDay.today() }
                    .buttonStyle(TopBarTextStyle())
                    .frame(width: 58)
                    .keyboardShortcut("t", modifiers: .command)
                    .help("⌘T")
                Button { page.search = ""; page.step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(GhostIconButtonStyle())
                    .keyboardShortcut("]", modifiers: .command)
                    .help("다음 (⌘])")
            }
            .opacity(navigable ? 1 : 0)
            .disabled(!navigable)
            .allowsHitTesting(navigable)
            Rectangle().fill(WL.border).frame(width: 1, height: 16).padding(.horizontal, 6)
            HStack(spacing: 4) {
                Button { carryOver() } label: { Image(systemName: "arrow.turn.down.right") }
                    .buttonStyle(GhostIconButtonStyle())
                    .disabled(carryable == 0)
                    .opacity(carryable == 0 ? 0.4 : 1)
                    .help(carryHelp)
                Button { page.importText = ""; page.importing = true } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(GhostIconButtonStyle())
                    .help("보고서 붙여넣기: 써 둔 일일보고를 한 번에 넣습니다")
            }
            .opacity(dayTools ? 1 : 0)
            .disabled(!dayTools)
            .allowsHitTesting(dayTools)
            .background {
                Button("") { newEntry() }.keyboardShortcut("n", modifiers: .command).hidden()
            }
            Button { captureNow() } label: {
                if sync.capturing {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: sync.captureError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                        .foregroundStyle(sync.captureError == nil ? WL.muted : WL.waiting)
                }
            }
            .buttonStyle(GhostIconButtonStyle())
            .disabled(sync.capturing)
            .keyboardShortcut("r", modifiers: .command)
            .help(captureHelp)
            Button { page.showsSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(GhostIconButtonStyle())
                .keyboardShortcut(",", modifiers: .command)
                .help("연동 설정 (⌘,)")
        }
        .padding(.leading, 28)
        .padding(.trailing, 14)
        .frame(height: 46)
        .background(WL.canvas)
    }

    private var todayTitle: String {
        page.mode == .week ? "이번 주" : page.mode == .month ? "이번 달" : "오늘"
    }

    private var carryable: Int {
        guard let source = store.log.previousDay(before: page.day) else { return 0 }
        let existing = Set(dayEntries.map { $0.project + "\u{1F}" + $0.title })
        return store.log.entries(on: source).filter { !$0.status.isFinished && !existing.contains($0.project + "\u{1F}" + $0.title) }.count
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

    private func captureNow() {
        guard settings.captureEnabled else {
            page.settingsSection = .gitlab
            page.showsSettings = true
            return
        }
        sync.capture { page.flash(sync.lastAdded > 0 ? "\(sync.lastAdded)줄을 가져왔습니다" : "새로 가져온 줄이 없습니다") }
    }

    private var captureHelp: String {
        guard settings.captureEnabled else { return "GitLab 가져오기를 켜려면 누르세요" }
        if let error = sync.captureError { return "가져오지 못함: \(error)" }
        guard let last = sync.lastCapture else { return "GitLab MR과 커밋 가져오기 (⌘R)" }
        return "지금 가져오기 (⌘R) · 마지막 \(WorkLogFormat.when(last)) · 10분마다 저절로"
    }

    // MARK: 페이지 머리

    private func pageHeader(_ title: String, @ViewBuilder properties: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(WL.pageTitle).monospacedDigit().foregroundStyle(WL.text)
            VStack(alignment: .leading, spacing: 0) { properties() }
            Rectangle().fill(WL.border).frame(height: 1).padding(.top, 6)
        }
        .padding(.bottom, 20)
    }

    // MARK: 하루

    private var dayEntries: [WorkEntry] { store.log.entries(on: page.day) }

    @ViewBuilder
    private var dayPage: some View {
        let entries = dayEntries
        let today = WorkDay.today()
        let pending = Set(entries.filter(\.needsRedmine).compactMap(\.issue)).count
        pageHeader(WorkLogFormat.longDay(page.day)) {
            PropertyRow("날짜", icon: "calendar") {
                Text(page.day == today ? "오늘" : page.day == WorkDay.adding(-1, to: today) ? "어제" : WorkLogFormat.shortDay(page.day))
            }
            PropertyRow("진행", icon: "circle.dashed") {
                if entries.isEmpty {
                    Text("기록 없음").foregroundStyle(WL.muted)
                } else {
                    HStack(spacing: 14) {
                        Tally(title: "완료", value: entries.filter(\.status.isFinished).count, tint: WL.done)
                        Tally(title: "진행", value: entries.filter { !$0.status.isFinished && $0.status != .ongoing }.count, tint: WL.accent)
                        Tally(title: "상시", value: entries.filter { $0.status == .ongoing }.count, tint: WL.quiet)
                    }
                }
            }
            PropertyRow("레드마인", icon: "paperplane") {
                if pending > 0 {
                    HStack(spacing: 8) {
                        Text("보낼 일감 \(pending)개").foregroundStyle(WL.waiting)
                        Button("보내기 →") { page.preview = .redmine }.buttonStyle(TextLinkButtonStyle())
                    }
                } else {
                    Text(entries.contains { $0.issue != nil } ? "모두 보냄" : "일감 없음").foregroundStyle(WL.muted)
                }
            }
            PropertyRow("GitLab", icon: "arrow.triangle.merge") {
                Text(gitlabState).foregroundStyle(sync.captureError == nil ? WL.muted : WL.waiting).lineLimit(1)
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

    private var gitlabState: String {
        guard settings.captureEnabled else { return "꺼짐 · 설정에서 켜면 MR과 커밋이 저절로 들어옵니다" }
        if let error = sync.captureError { return error }
        return sync.lastCapture.map { "10분마다 · \(WorkLogFormat.when($0)) 가져옴" } ?? "10분마다"
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
                     ? "머지한 MR과 머지 전 커밋은 10분마다 저절로 들어옵니다. 회의처럼 git에 남지 않는 일만 아래에서 프로젝트를 골라 적거나 ⌃⌥L로 적으세요."
                     : "GitLab을 이으면 머지한 MR과 커밋이 저절로 들어옵니다. 지금은 프로젝트를 골라 직접 적거나 써 둔 보고서를 붙여 넣을 수 있습니다.")
                    .font(.system(size: 12.5)).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if settings.captureEnabled {
                        Button("지금 가져오기") { sync.capture() }.buttonStyle(NotionButtonStyle())
                    } else {
                        Button("GitLab 잇기") { page.settingsSection = .gitlab; page.showsSettings = true }
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                    }
                    Button("보고서 붙여넣기") { page.importText = ""; page.importing = true }.buttonStyle(NotionButtonStyle())
                }
            }
        }
        .padding(.bottom, 20)
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
                    ForEach(entries) { entry in EntryRow(store: store, page: page, entry: entry) }
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
            .help("끝에 (60%)·(상시)를 붙이면 상태로, #1234를 붙이면 일감 번호로 저장합니다 (⌘N)")
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
                    .help("왼쪽 프로젝트 목록에 이름 칸이 열립니다")
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
        pageHeader(page.mode == .week ? WorkLogFormat.weekTitle(page.day) : WorkLogFormat.monthTitle(page.day)) {
            PropertyRow("기간", icon: "calendar") {
                let range = page.mode == .week ? WorkDay.week(of: page.day) : WorkDay.month(of: page.day)
                Text("\(WorkLogFormat.shortDay(range.lowerBound)) ~ \(WorkLogFormat.shortDay(range.upperBound))").monospacedDigit()
            }
            PropertyRow("한 일", icon: "list.bullet") {
                HStack(spacing: 14) {
                    Tally(title: "전체", value: merged.count)
                    Tally(title: "완료", value: merged.filter(\.status.isFinished).count, tint: WL.done)
                    Tally(title: "진행", value: merged.filter { !$0.status.isFinished && $0.status != .ongoing }.count, tint: WL.accent)
                }
            }
            PropertyRow("기록한 날", icon: "checkmark.circle") {
                Text("\(Set(entries.map(\.day)).count)일").monospacedDigit()
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
                    ForEach(merged) { entry in MergedRow(page: page, entry: entry, entries: entries) }
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
            pageHeader(project) {
                PropertyRow("기록", icon: "list.bullet") {
                    Text("\(entries.count)줄 · \(days.count)일").monospacedDigit()
                }
                PropertyRow("기간", icon: "calendar") {
                    Text("\(WorkLogFormat.shortDay(days.last ?? "")) ~ \(WorkLogFormat.shortDay(days.first ?? ""))").monospacedDigit()
                }
                PropertyRow("진행 중", icon: "circle.dashed") {
                    Text(open.isEmpty ? "없음" : "\(open.count)개").foregroundStyle(open.isEmpty ? WL.muted : WL.text)
                }
                PropertyRow("일감", icon: "number") {
                    Text("\(Set(entries.compactMap(\.issue)).count)개").monospacedDigit()
                }
            }
            if !open.isEmpty {
                section(key: "project-open", title: "진행 중인 일") {
                    ForEach(open) { entry in MergedRow(page: page, entry: entry, entries: entries) }
                }
            }
            ForEach(days, id: \.self) { day in
                section(key: "project:" + day, title: WorkLogFormat.dayTitle(day), jump: day) {
                    ForEach(entries.filter { $0.day == day }) { entry in
                        HStack(spacing: 10) {
                            StatusGlyph(status: entry.status)
                            Text(entry.title).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                            IssueSlot(issue: entry.issue, posted: entry.issue == nil ? nil : !entry.needsRedmine)
                            StatusText(status: entry.status)
                        }
                        .padding(.horizontal, 6)
                        .frame(minHeight: WL.rowHeight)
                        .hoverRow()
                    }
                }
            }
            .id(project)
        } else {
            pageHeader("프로젝트") { EmptyView() }
            Callout {
                Text("하루 보기에서 일을 적거나 GitLab을 이으면 프로젝트별로 모입니다.").font(.system(size: 12.5)).foregroundStyle(WL.muted)
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
        pageHeader("찾기") {
            PropertyRow("찾는 말", icon: "magnifyingglass") { Text(page.search) }
            PropertyRow("결과", icon: "list.bullet") {
                HStack(spacing: 10) {
                    Text("\(results.count)줄 · \(Set(results.map(\.day)).count)일").monospacedDigit()
                    Button("지우기") { page.search = "" }.buttonStyle(TextLinkButtonStyle(tint: WL.muted))
                }
            }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 14)).foregroundStyle(WL.text).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        ProjectSwatch(name: entry.project, size: 7)
                        Text(entry.project).font(.system(size: 12)).foregroundStyle(WL.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
