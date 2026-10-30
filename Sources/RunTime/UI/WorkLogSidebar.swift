import SwiftUI
import WorkLogCore

/// 업무 일지 왼쪽: 찾기, 한 달 달력, 프로젝트 목록, 연동 상태.
struct WorkLogSidebar: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var sync: WorkLogSync
    @ObservedObject var settings: WorkLogSettings
    @StateObject private var hover = HoveredKey()
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            searchField
            calendar
            projects
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WL.sidebar)
    }

    // MARK: 찾기

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            TextField("찾기", text: $page.search)
                .textFieldStyle(.plain)
                .font(WL.meta)
                .focused($searching)
                .onExitCommand { page.search = ""; searching = false }
            if !page.search.isEmpty {
                Button { page.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(WL.muted) }
                    .buttonStyle(.plain)
                    .tip("찾는 말 지우기 (esc)")
            } else if !searching {
                Text("⌘F").font(WL.caption).foregroundStyle(WL.muted)
            }
        }
        .background {
            // 어느 칸에 있든 ⌘F로 찾기 칸에 들어간다
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        .tip("내용·댓글·프로젝트·#일감번호, 초성(ㄷㅇㅌ)으로도")
    }

    // MARK: 달력

    private var calendar: some View {
        let month = page.calendarMonth
        let days = WorkDay.calendarDays(of: month)
        let inMonth = WorkDay.month(of: month)
        let byDay = Dictionary(grouping: store.log.entries(in: days.first!...days.last!), by: \.day)
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(String(month.prefix(4)) + "년").font(WL.heading).foregroundStyle(.secondary).monospacedDigit()
                Text(monthName(month)).font(WL.heading).monospacedDigit()
                Spacer()
                Button { page.calendarMonth = WorkDay.addingMonths(-1, to: month) } label: { Image(systemName: "chevron.left") }
                    .tip("지난달")
                Button { page.search = ""; page.day = WorkDay.today() } label: { Image(systemName: "circle.fill").font(.system(size: 5)) }
                    .tip("오늘로 가기")
                Button { page.calendarMonth = WorkDay.addingMonths(1, to: month) } label: { Image(systemName: "chevron.right") }
                    .tip("다음 달")
            }
            .buttonStyle(GhostIconButtonStyle())
            SevenColumns {
                ForEach(WorkLogFormat.weekdays, id: \.number) { day in
                    Text(day.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(WorkLogFormat.weekdayTint(day.number)?.opacity(0.8) ?? Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 2) {
                ForEach(weeks, id: \.first) { week in
                    weekRow(week, byDay: byDay, inMonth: inMonth)
                }
            }
        }
    }

    private func monthName(_ key: String) -> String {
        let parts = key.split(separator: "-")
        return parts.count == 3 ? "\(Int(parts[1]) ?? 0)월" : key
    }

    /// 주간·월간에서 고른 범위는 줄 뒤에 옅은 띠로 깐다 (macOS 달력처럼).
    private func weekRow(_ week: [String], byDay: [String: [WorkEntry]], inMonth: ClosedRange<String>) -> some View {
        let range = selectedRange
        let selected = week.filter { range.contains($0) }
        return SevenColumns {
            ForEach(week, id: \.self) { day in
                dayCell(day, entries: byDay[day] ?? [], inMonth: inMonth.contains(day))
            }
        }
        .background(alignment: .leading) {
            // 월간은 달력 전체가 고른 범위라 띠를 깔면 달력이 통째로 파래져, 주간에만 깐다
            if page.mode == .week, let first = selected.first, let index = week.firstIndex(of: first) {
                GeometryReader { geo in
                    // 칸과 같은 정수 너비로 띠를 놓는다 (SevenColumns 참고)
                    let cell = (geo.size.width / 7).rounded(.down)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WL.selected)
                        .frame(width: cell * CGFloat(selected.count))
                        .offset(x: ((geo.size.width - cell * 7) / 2).rounded(.down) + cell * CGFloat(index))
                }
            }
        }
    }

    private var selectedRange: ClosedRange<String> {
        switch page.mode {
        case .week: return WorkDay.week(of: page.day)
        case .month: return WorkDay.month(of: page.day)
        default: return page.day...page.day
        }
    }

    private func dayCell(_ day: String, entries: [WorkEntry], inMonth: Bool) -> some View {
        let isToday = day == WorkDay.today()
        let isSelected = day == page.day && (page.mode == .day || page.mode == .project)
        let projects = Array(store.log.orderedProjects(of: entries).filter { !store.log.hiddenProjects.contains($0) }.prefix(3))
        let holiday = KoreanHolidays.name(on: day)
        let tint = WorkLogFormat.dayTint(day)
        return Button {
            page.search = ""
            page.day = day
            if page.mode == .project { page.mode = .day }
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    if isSelected {
                        Circle().fill(WL.accent)
                    } else if hover.key == day {
                        Circle().fill(WL.hover)
                    }
                    Text(WorkLogFormat.dayNumber(day))
                        .font(.system(size: 12.5, weight: isToday || isSelected ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white
                                         : isToday ? WL.accent
                                         : (tint ?? WL.text).opacity(inMonth ? 1 : 0.4))
                }
                .frame(width: 24, height: 24)
                HStack(spacing: 2) {
                    ForEach(projects, id: \.self) { name in
                        Circle().fill(WL.projectColor(name)).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update(day, $0) }
        .tip([WorkLogFormat.dayTitle(day), holiday, entries.isEmpty ? nil : "\(entries.count)줄 · " + projects.joined(separator: ", ")]
              .compactMap { $0 }.joined(separator: " · "))
    }

    // MARK: 프로젝트

    private var projects: some View {
        let monthEntries = store.log.entries(in: WorkDay.month(of: page.calendarMonth))
        let names = store.log.visibleProjects
        let hidden = store.log.allProjects.filter(store.log.hiddenProjects.contains)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("프로젝트").font(WL.label).foregroundStyle(.secondary)
                Spacer()
                Text(monthName(page.calendarMonth)).font(WL.label).foregroundStyle(WL.muted)
                Button {
                    page.newProject = ""
                    page.addingProject = true
                } label: { Image(systemName: "plus") }
                .buttonStyle(GhostIconButtonStyle())
                .tip("새 프로젝트 만들기")
            }
            .padding(.leading, 6)
            if page.addingProject {
                HStack(spacing: 8) {
                    ProjectSwatch(name: page.newProject)
                    TextField("이름 입력 후 Enter", text: $page.newProject, onCommit: commitNewProject)
                        .textFieldStyle(.plain)
                        .font(WL.meta)
                    Button { page.addingProject = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(GhostIconButtonStyle())
                        .tip("만들지 않고 닫기")
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.surface))
                .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.accent.opacity(0.6), lineWidth: 1))
            }
            if names.isEmpty && !page.addingProject {
                Text("+로 만들거나 GitLab을 연결하면 자동으로 생깁니다")
                    .font(WL.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            SlimScrollView {
                VStack(spacing: 1) {
                    ForEach(names, id: \.self) { name in
                        projectRow(name, count: monthEntries.filter { $0.project == name }.count)
                    }
                    if !hidden.isEmpty { hiddenProjects(hidden) }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private func projectRow(_ name: String, count: Int) -> some View {
        let selected = page.mode == .project && page.project == name && page.search.isEmpty
        return Button {
            page.search = ""
            page.project = name
            page.mode = .project
        } label: {
            HStack(spacing: 8) {
                ProjectSwatch(name: name)
                Text(name).font(.system(size: 13.5, weight: selected ? .semibold : .regular)).foregroundStyle(WL.text).lineLimit(1)
                Spacer(minLength: 4)
                if let period = store.log.projectPeriods[name] {
                    // 기간이 끝난 프로젝트는 흐리게 둔다 (진행 예정에서 빠졌다는 뜻)
                    Image(systemName: "calendar")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(period.contains(WorkDay.today()) ? WL.accent : WL.faint)
                } else if let auto = store.autoPeriods[name] {
                    // 레드마인 일감으로 잡은 기간은 직접 정한 것과 구별해 회색으로 둔다
                    Image(systemName: "calendar")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(auto.isActive(on: WorkDay.today()) ? WL.muted : WL.faint)
                }
                if count > 0 { Text("\(count)").font(WL.number).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(selected ? WL.hover.opacity(1.8) : hover.key == "p:" + name ? WL.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update("p:" + name, $0) }
        .tip("이 달 \(count)줄" + periodTip(name)
             + " · 누르면 프로젝트 기록 · 끌어서 순서 바꾸기")
        .popover(isPresented: Binding(
            get: { page.periodEditing == name },
            set: { if !$0 { page.periodEditing = nil } }
        ), arrowEdge: .trailing) {
            ProjectPeriodEditor(name: name, period: store.log.projectPeriods[name], auto: store.autoPeriods[name]) { period in
                store.setPeriod(name, period)
                page.periodEditing = nil
            }
        }
        // 끌어다 놓아 순서를 바꾸면 보고서 번호 순서도 같이 바뀐다
        .reorderable(name, dragging: $page.draggingProject) { from, to in store.moveProject(from, to: to) }
        .opacity(page.draggingProject == name ? 0.4 : 1)
        .contextMenu {
            Button("고른 날에 적기") {
                page.openProjects.insert(name)
                page.mode = .day
            }
            Button("이름 바꾸기") {
                page.openProjects.insert(name)
                page.search = ""
                page.mode = .day
                page.renameText = name
                page.renaming = name
            }
            Button(store.log.projectPeriods[name] == nil ? "기간 직접 정하기…" : "기간 고치기…") { page.periodEditing = name }
            Button("보고서에서 위로") { store.moveProject(name, by: -1) }
            Button("보고서에서 아래로") { store.moveProject(name, by: 1) }
            Divider()
            Button("목록에서 숨기기") { hide(name) }
            if !store.log.entries.contains(where: { $0.project == name }) {
                Divider()
                Button("목록에서 빼기") {
                    page.openProjects.remove(name)
                    store.removeProjectIfEmpty(name)
                }
            }
        }
    }

    private func periodTip(_ name: String) -> String {
        if let period = store.log.projectPeriods[name] { return " · 기간 " + Self.periodText(period) + " (직접 정함)" }
        guard let auto = store.autoPeriods[name] else { return "" }
        return " · 레드마인 일감 \(auto.issues)개 기준 " + Self.periodText(auto.period)
    }

    /// `10.1 ~ 12.31`, 끝이 없으면 `10.1 ~`.
    static func periodText(_ period: ProjectPeriod) -> String {
        (period.start.map(WorkReport.shortDate) ?? "") + " ~ " + (period.end.map(WorkReport.shortDate) ?? "")
    }

    /// 숨긴 프로젝트는 접힌 묶음 하나로 모은다. 펼쳐서 눈 단추로 다시 보인다.
    private func hiddenProjects(_ names: [String]) -> some View {
        VStack(spacing: 1) {
            Button { page.showsHidden.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(page.showsHidden ? 90 : 0))
                        .frame(width: 10)
                    Text("숨긴 프로젝트 \(names.count)").font(WL.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if page.showsHidden {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 8) {
                        ProjectSwatch(name: name).opacity(0.5)
                        Text(name).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button { store.setHidden(name, false) } label: { Image(systemName: "eye") }
                            .buttonStyle(GhostIconButtonStyle())
                            .tip("다시 보이기")
                    }
                    .padding(.leading, 8)
                    .frame(height: 28)
                    .contextMenu {
                        Button("다시 보이기") { store.setHidden(name, false) }
                        Button("기록 보기") { page.search = ""; page.project = name; page.mode = .project }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func hide(_ name: String) {
        page.openProjects.remove(name)
        store.setHidden(name, true)
        if page.project == name && page.mode == .project { page.project = nil }
        page.flash("‘\(name)’를 숨겼습니다. 기록과 보고서에는 그대로 남습니다")
    }

    /// 만들면 고른 날에 그 프로젝트를 열어 바로 적게 한다.
    private func commitNewProject() {
        let name = page.newProject.trimmingCharacters(in: .whitespaces)
        page.addingProject = false
        page.newProject = ""
        guard !name.isEmpty else { return }
        store.addProject(name)
        page.openProjects.insert(name)
        page.search = ""
        page.mode = .day
        page.flash("‘\(name)’ 프로젝트를 만들었습니다")
    }

    // MARK: 연동 상태

    private var footer: some View {
        Button { page.showsSettings = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                // 오류 글은 길어 한 줄에서 잘리니 "확인 필요"로 줄이고 전체 글은 올렸을 때 보인다
                status("GitLab", on: settings.captureEnabled, error: sync.captureError != nil,
                       detail: sync.captureError != nil ? "확인 필요"
                           : sync.lastCapture.map { "\(WorkLogFormat.when($0)) 가져옴" } ?? (settings.captureEnabled ? "대기" : "꺼짐"))
                    .tip(sync.captureError ?? "")
                status("레드마인", on: settings.redmineReady, error: sync.issuesError != nil,
                       detail: sync.issuesError != nil ? "확인 필요" : settings.redmineReady ? "연결됨" : "꺼짐")
                    .tip(sync.issuesError ?? "")
                status("팀즈", on: settings.hasTeams(.chat), error: false,
                       detail: settings.teamsDirect(.chat) ? "웹훅 연결" : settings.hasTeams(.chat) ? "채팅 연결" : "나에게만")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(hover.key == "footer" ? WL.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update("footer", $0) }
        .tip("연동 설정")
    }

    private func status(_ name: String, on: Bool, error: Bool, detail: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(error ? WL.waiting : on ? WL.done : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            Text(name).font(WL.caption)
            Spacer(minLength: 4)
            Text(detail).font(WL.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// 마우스를 올린 칸. `@State` 대신 쓴다 (HoverFlag 참고).
final class HoveredKey: ObservableObject {
    @Published var key: String?

    func update(_ key: String, _ inside: Bool) {
        if inside { self.key = key } else if self.key == key { self.key = nil }
    }
}

/// 기간 창에서 고치는 값. 이 저장소는 `@State` 대신 ObservableObject를 쓴다 (WorkLogPage 참고).
private final class PeriodDraft: ObservableObject {
    @Published var hasStart: Bool
    @Published var hasEnd: Bool
    @Published var start: Date
    @Published var end: Date

    init(_ period: ProjectPeriod?) {
        // 새로 정할 때는 오늘부터, 끝은 비워 둔다 (끝나는 날을 모르는 프로젝트가 많다)
        hasStart = period?.start != nil || period?.end == nil
        hasEnd = period?.end != nil
        start = period?.start.flatMap(WorkDay.date) ?? Date()
        end = period?.end.flatMap(WorkDay.date) ?? Date().addingTimeInterval(90 * 86_400)
    }

    var reversed: Bool { hasStart && hasEnd && WorkDay.key(end) < WorkDay.key(start) }
    /// 시작·끝을 다 비우면 날마다 진행 예정에 들어가 기간이 아니다.
    var invalid: Bool { reversed || (!hasStart && !hasEnd) }
    var period: ProjectPeriod { ProjectPeriod(start: hasStart ? WorkDay.key(start) : nil, end: hasEnd ? WorkDay.key(end) : nil) }
}

/// 프로젝트 기간 정하기. 기간 안의 날에는 그날 줄이 없어도 진행 예정에 `마크업 및 API 연동`으로 들어간다.
struct ProjectPeriodEditor: View {
    let name: String
    let existing: Bool
    let auto: WorkLog.AutoPeriod?
    let save: (ProjectPeriod?) -> Void
    @StateObject private var draft: PeriodDraft

    init(name: String, period: ProjectPeriod?, auto: WorkLog.AutoPeriod? = nil, save: @escaping (ProjectPeriod?) -> Void) {
        self.name = name
        self.save = save
        self.auto = auto
        existing = period != nil
        // 처음 정할 때는 레드마인 일감 기간에서 시작한다
        _draft = StateObject(wrappedValue: PeriodDraft(period ?? auto?.period))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(name) 기간").font(WL.heading)
                Text("기간 안의 날에는 줄이 없어도 진행 예정에 ‘\(WorkReport.planLine)’으로 들어갑니다.")
                    .font(WL.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Label(autoText, systemImage: auto == nil ? "calendar.badge.exclamationmark" : "checkmark.circle")
                .font(WL.caption).foregroundStyle(existing ? WL.faint : WL.muted)
                .fixedSize(horizontal: false, vertical: true)
            row("시작", empty: "처음부터", on: $draft.hasStart, date: $draft.start)
            row("끝", empty: "끝 없음", on: $draft.hasEnd, date: $draft.end)
            if draft.invalid {
                Text(draft.reversed ? "끝나는 날이 시작보다 앞섭니다" : "시작이나 끝 가운데 하나는 정하세요")
                    .font(WL.caption).foregroundStyle(WL.waiting)
            }
            HStack(spacing: 8) {
                if existing {
                    Button(auto == nil ? "기간 지우기" : "레드마인 기준으로") { save(nil) }
                        .buttonStyle(TextLinkButtonStyle(tint: auto == nil ? WL.waiting : WL.accent))
                        .tip(auto == nil ? "기간을 지우면 그날 적은 일이 있을 때만 진행 예정에 들어갑니다" : "직접 정한 기간을 지우고 레드마인 내 일감으로 정합니다")
                }
                Spacer()
                Button("저장") { save(draft.period) }
                    .buttonStyle(NotionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.invalid)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var autoText: String {
        guard let auto else { return existing ? "이 프로젝트에 열린 레드마인 내 일감이 없습니다" : "레드마인 내 일감이 없어 직접 정해야 합니다" }
        let span = (auto.period.start.map(WorkReport.shortDate) ?? "처음") + " ~ " + (auto.period.end.map(WorkReport.shortDate) ?? "기한 없음")
        return "레드마인 내 일감 \(auto.issues)개 기준 \(span)" + (existing ? " · 지금은 직접 정한 기간을 씁니다" : "")
    }

    private func row(_ label: String, empty: String, on: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: on).toggleStyle(.checkbox).frame(width: 60, alignment: .leading)
            if on.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
            } else {
                Text(empty).font(WL.caption).foregroundStyle(.secondary)
            }
        }
    }
}
