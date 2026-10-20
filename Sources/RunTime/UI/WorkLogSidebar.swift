import SwiftUI
import WorkLogCore

/// 업무 일지 왼쪽: 찾기, 한 달 달력, 프로젝트 목록, 연동 상태.
struct WorkLogSidebar: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    @ObservedObject var sync: WorkLogSync
    @ObservedObject var settings: WorkLogSettings
    @StateObject private var hover = HoveredKey()

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
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("찾기", text: $page.search)
                .textFieldStyle(.plain)
                .font(WL.meta)
            if !page.search.isEmpty {
                Button { page.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        .help("내용·댓글·프로젝트·#일감번호, 초성(ㄷㅇㅌ)으로도")
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
                    .help("지난달")
                Button { page.search = ""; page.day = WorkDay.today() } label: { Image(systemName: "circle.fill").font(.system(size: 5)) }
                    .help("오늘")
                Button { page.calendarMonth = WorkDay.addingMonths(1, to: month) } label: { Image(systemName: "chevron.right") }
                    .help("다음 달")
            }
            .buttonStyle(GhostIconButtonStyle())
            HStack(spacing: 0) {
                ForEach(WorkLogFormat.weekdays, id: \.number) { day in
                    Text(day.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(day.number == 1 || day.number == 7 ? Color.secondary.opacity(0.6) : Color.secondary)
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
        return HStack(spacing: 0) {
            ForEach(week, id: \.self) { day in
                dayCell(day, entries: byDay[day] ?? [], inMonth: inMonth.contains(day))
            }
        }
        .background(alignment: .leading) {
            if page.mode == .week || page.mode == .month, let first = selected.first, let index = week.firstIndex(of: first) {
                GeometryReader { geo in
                    let cell = geo.size.width / 7
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WL.selected)
                        .frame(width: cell * CGFloat(selected.count))
                        .offset(x: cell * CGFloat(index))
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
        let projects = Array(store.log.orderedProjects(of: entries).prefix(3))
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
                        .font(.system(size: 11.5, weight: isToday || isSelected ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white
                                         : isToday ? WL.accent
                                         : inMonth ? WL.text : WL.faint)
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
        .help(entries.isEmpty ? WorkLogFormat.dayTitle(day)
              : "\(WorkLogFormat.dayTitle(day)) · \(entries.count)줄 · " + projects.joined(separator: ", "))
    }

    // MARK: 프로젝트

    private var projects: some View {
        let monthEntries = store.log.entries(in: WorkDay.month(of: page.calendarMonth))
        let names = store.log.allProjects
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("프로젝트").font(WL.label).foregroundStyle(.secondary)
                Spacer()
                Text(monthName(page.calendarMonth)).font(WL.label).foregroundStyle(.tertiary)
                Button {
                    page.newProject = ""
                    page.addingProject = true
                } label: { Image(systemName: "plus") }
                .buttonStyle(GhostIconButtonStyle())
                .help("새 프로젝트")
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
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.surface))
                .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.accent.opacity(0.6), lineWidth: 1))
            }
            if names.isEmpty && !page.addingProject {
                Text("+로 만들거나, GitLab을 이으면 저절로 생깁니다")
                    .font(WL.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(names, id: \.self) { name in
                        projectRow(name, count: monthEntries.filter { $0.project == name }.count)
                    }
                }
            }
            .frame(maxHeight: 240)
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
                Text(name).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(WL.text).lineLimit(1)
                Spacer(minLength: 4)
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
        .help("이 달 \(count)줄 · 누르면 프로젝트 기록")
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
            Button("보고서에서 위로") { store.moveProject(name, by: -1) }
            Button("보고서에서 아래로") { store.moveProject(name, by: 1) }
            if !store.log.entries.contains(where: { $0.project == name }) {
                Divider()
                Button("목록에서 빼기") {
                    page.openProjects.remove(name)
                    store.removeProjectIfEmpty(name)
                }
            }
        }
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
                status("GitLab", on: settings.captureEnabled, error: sync.captureError != nil,
                       detail: sync.captureError ?? sync.lastCapture.map { "\(WorkLogFormat.when($0)) 가져옴" } ?? (settings.captureEnabled ? "대기" : "꺼짐"))
                status("레드마인", on: settings.redmineReady, error: sync.issuesError != nil,
                       detail: sync.issuesError ?? (settings.redmineReady ? "연결됨" : "꺼짐"))
                status("팀즈", on: settings.hasTeamsWebhook, error: false, detail: settings.hasTeamsWebhook ? "연결됨" : "복사로 올림")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(hover.key == "footer" ? WL.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update("footer", $0) }
        .help("연동 설정")
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
