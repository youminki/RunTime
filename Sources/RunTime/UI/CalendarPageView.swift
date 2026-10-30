import SwiftUI
import WorkLogCore

/// 앱 창의 캘린더: 업무 일지를 macOS 캘린더처럼 한 달 칸으로 크게 본다.
/// 칸마다 그날 적은 일을 프로젝트 색 점과 함께 늘어놓고, 오른쪽에 고른 날의 일을 모두 보인다.
/// 날을 한 번 누르면 고르고, 두 번 누르거나 "업무 일지에서 열기"를 누르면 그날 일지로 간다.
struct CalendarPageView: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    var openDay: (String) -> Void = { _ in }
    @StateObject private var hover = HoveredKey()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                SevenColumns {
                    ForEach(WorkLogFormat.weekdays, id: \.number) { day in
                        Text(day.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(WorkLogFormat.weekdayTint(day.number) ?? WL.muted)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 10)
                            .padding(.bottom, 6)
                    }
                }
                .padding(.horizontal, 16)
                grid
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 고른 날 칸은 끌어서 넓히고, 두 번 누르면 기본 340으로 돌아간다
            ColumnDivider(width: Binding(get: { page.calendarDetailWidth ?? 340 }, set: { page.calendarDetailWidth = $0 }),
                          range: 240...720, standard: 340, trailing: true, reset: { page.calendarDetailWidth = nil })
            detail
                .frame(width: page.calendarDetailWidth ?? 340)
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
    }

    // MARK: 머리

    private var header: some View {
        let month = page.calendarMonth
        let all = visible(store.log.entries(in: WorkDay.month(of: month)), filtered: false)
        let entries = all.filter { page.calendarProject == nil || $0.project == page.calendarProject }
        let parts = month.split(separator: "-")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.count == 3 ? "\(Int(parts[1]) ?? 0)월" : month).font(WL.pageTitle)
                    Text(String(month.prefix(4)) + "년").font(.system(size: 20, weight: .medium)).foregroundStyle(WL.muted)
                }
                .monospacedDigit()
                Spacer()
                HStack(spacing: 4) {
                    Button { page.calendarMonth = WorkDay.addingMonths(-1, to: month) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(GhostIconButtonStyle())
                        .keyboardShortcut("[", modifiers: .command)
                        .tip("지난달 (⌘[)")
                        .accessibilityLabel("지난달")
                    Button("오늘") { select(WorkDay.today()) }
                        .buttonStyle(NotionButtonStyle())
                        .keyboardShortcut("t", modifiers: .command)
                        .tip("오늘로 가기 (⌘T)")
                    Button { page.calendarMonth = WorkDay.addingMonths(1, to: month) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(GhostIconButtonStyle())
                        .keyboardShortcut("]", modifiers: .command)
                        .tip("다음 달 (⌘])")
                        .accessibilityLabel("다음 달")
                }
            }
            HStack(spacing: 14) {
                if entries.isEmpty {
                    Text(page.calendarProject == nil ? "이 달에 적은 업무가 없습니다" : "이 달에 ‘\(page.calendarProject!)’ 업무가 없습니다")
                } else {
                    Tally(title: "일한 날", value: Set(entries.map(\.day)).count)
                    Tally(title: "업무", value: entries.count)
                    Tally(title: "완료", value: entries.filter(\.status.isFinished).count, tint: WL.done)
                    Tally(title: "진행 중", value: entries.filter(isOpen).count, tint: WL.accent)
                }
            }
            .font(WL.meta)
            .monospacedDigit()
            projectFilter(all)
        }
    }

    /// 이 달의 프로젝트를 색과 함께 늘어놓는다. 누르면 그 프로젝트만 달력에 남긴다.
    @ViewBuilder
    private func projectFilter(_ entries: [WorkEntry]) -> some View {
        let projects = store.log.orderedProjects(of: entries)
        if projects.count > 1 || page.calendarProject != nil {
            FlowLayout(spacing: 6) {
                filterChip(nil, title: "모든 프로젝트", count: entries.count)
                ForEach(projects, id: \.self) { project in
                    filterChip(project, title: project, count: entries.filter { $0.project == project }.count)
                }
            }
        }
    }

    private func filterChip(_ project: String?, title: String, count: Int) -> some View {
        let on = page.calendarProject == project
        return Button { page.calendarProject = on ? nil : project } label: {
            HStack(spacing: 6) {
                if let project { ProjectSwatch(name: project, size: 8) }
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(on ? Color.white.opacity(0.8) : WL.quiet)
            }
        }
        .buttonStyle(ChipButtonStyle(selected: on))
        .fixedSize()
        .tip(project == nil ? "모든 프로젝트 보기" : "‘\(title)’ 업무만 보기 · 다시 누르면 모두 봅니다")
    }

    // MARK: 달력 칸

    private var grid: some View {
        let days = WorkDay.calendarDays(of: page.calendarMonth)
        let inMonth = WorkDay.month(of: page.calendarMonth)
        let byDay = Dictionary(grouping: visible(store.log.entries(in: days.first!...days.last!)), by: \.day)
        let weeks = max(1, days.count / 7)
        return GeometryReader { geo in
            let height = (geo.size.height / CGFloat(weeks)).rounded(.down)
            SevenColumns {
                ForEach(days, id: \.self) { day in
                    cell(day, entries: byDay[day] ?? [], inMonth: inMonth.contains(day), height: height)
                }
            }
            // 칸이 정수 너비라 남는 몇 pt만큼 테두리를 좁혀 마지막 칸과 겹치게 한다 (요일 머리와 같은 자리)
            .frame(width: (geo.size.width / 7).rounded(.down) * 7)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity)
        }
    }

    private func cell(_ day: String, entries: [WorkEntry], inMonth: Bool, height: CGFloat) -> some View {
        let isToday = day == WorkDay.today()
        let isSelected = day == page.day
        let holiday = KoreanHolidays.name(on: day)
        let tint = WorkLogFormat.dayTint(day)
        // 날짜 줄(약 26pt)을 뺀 높이에 한 줄 16pt씩 들어간다. 넘치면 마지막 줄을 "N개 더"로 쓴다
        let capacity = max(0, Int((height - 30) / 16))
        let shown = entries.count > capacity ? max(0, capacity - 1) : entries.count
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let holiday {
                    Text(holiday).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.red).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(WorkLogFormat.dayNumber(day))
                    .font(.system(size: 13, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : tint ?? WL.text)
                    .frame(minWidth: 22, minHeight: 22)
                    .background { if isToday { Circle().fill(Palette.red) } }
            }
            .frame(height: 24)
            ForEach(entries.prefix(shown)) { entry in
                HStack(spacing: 5) {
                    Circle().fill(WL.projectColor(entry.project)).frame(width: 6, height: 6)
                    Text(WorkLogFormat.breadcrumb(entry.title).leaf)
                        .font(.system(size: 12.5))
                        .foregroundStyle(entry.status.isFinished ? WL.text : WL.accent)
                        .lineLimit(1)
                }
                .frame(height: 14)
            }
            if entries.count > shown {
                Text("+\(entries.count - shown)개 더").font(.system(size: 11.5, weight: .medium)).foregroundStyle(WL.muted)
                    .frame(height: 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .opacity(inMonth ? 1 : 0.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(isSelected ? WL.selected : hover.key == day ? WL.hover : inMonth ? Color.clear : WL.sidebar)
        // 칸마다 오른쪽·아래 선만 그어 겹친 선이 두꺼워지지 않게 한다
        .overlay(alignment: .trailing) { Rectangle().fill(WL.border).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(WL.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover.update(day, $0) }
        .onTapGesture(count: 2) { openDay(day) }
        .onTapGesture { select(day) }
        .tip(tip(day, holiday: holiday, entries: entries))
    }

    private func tip(_ day: String, holiday: String?, entries: [WorkEntry]) -> String {
        let head = [WorkLogFormat.dayTitle(day), holiday].compactMap { $0 }.joined(separator: " · ")
        guard !entries.isEmpty else { return head }
        return ([head] + entries.prefix(12).map { "\($0.project) · \(WorkReport.line($0))" }
                + (entries.count > 12 ? ["… \(entries.count - 12)줄 더"] : []))
            .joined(separator: "\n")
    }

    // MARK: 고른 날

    private var detail: some View {
        let day = page.day
        let entries = visible(store.log.entries(on: day))
        let holiday = KoreanHolidays.name(on: day)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(WorkLogFormat.longDay(day)).font(WL.title).lineLimit(1).minimumScaleFactor(0.8)
                    if let relative = relative(day) { DayBadge(text: relative) }
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        Button { select(WorkDay.adding(-1, to: day)) } label: { Image(systemName: "chevron.left") }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                            .tip("전날 (←)")
                            .accessibilityLabel("전날")
                        Button { select(WorkDay.adding(1, to: day)) } label: { Image(systemName: "chevron.right") }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                            .tip("다음 날 (→)")
                            .accessibilityLabel("다음 날")
                    }
                    .buttonStyle(GhostIconButtonStyle())
                }
                HStack(spacing: 12) {
                    if let holiday { Text(holiday).foregroundStyle(Palette.red) }
                    if !entries.isEmpty {
                        Tally(title: "완료", value: entries.filter(\.status.isFinished).count, tint: WL.done)
                        Tally(title: "진행 중", value: entries.filter(isOpen).count, tint: WL.accent)
                        let ongoing = entries.filter { $0.status == .ongoing }.count
                        if ongoing > 0 { Tally(title: "상시", value: ongoing, tint: WL.quiet) }
                    }
                }
                .font(WL.meta)
                if let project = page.calendarProject {
                    HStack(spacing: 6) {
                        ProjectSwatch(name: project, size: 8)
                        Text("‘\(project)’만 보는 중").foregroundStyle(WL.muted)
                        Button("모두 보기") { page.calendarProject = nil }.buttonStyle(TextLinkButtonStyle())
                    }
                    .font(WL.caption)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)
            if entries.isEmpty {
                empty(day, holiday: holiday)
            } else {
                SlimScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.log.orderedProjects(of: entries), id: \.self) { project in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    ProjectSwatch(name: project, size: 8)
                                    Text(project).font(WL.heading)
                                    Text("\(entries.filter { $0.project == project }.count)").font(WL.number).foregroundStyle(WL.quiet)
                                }
                                PathGroupedRows(entries: entries.filter { $0.project == project }) { entry, path in
                                    // 제목이 여러 줄이면 상태 표시를 첫 줄에 맞춘다
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        StatusGlyph(status: entry.status)
                                        Text(path == nil ? entry.title : WorkLogFormat.breadcrumb(entry.title).leaf)
                                            .font(.system(size: 13.5))
                                            // 오른쪽 칸은 자리가 넉넉해 한 줄로 자르지 않고 세 줄까지 보인다
                                            .lineLimit(3)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .tip(entry.title)
                                        StatusText(status: entry.status)
                                    }
                                    .frame(minHeight: 26)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
            Rectangle().fill(WL.border).frame(height: 1)
            Button { openDay(day) } label: {
                Label(entries.isEmpty ? "이날 업무 일지 쓰기" : "이날 업무 일지 열기", systemImage: entries.isEmpty ? "square.and.pencil" : "checklist")
            }
            .buttonStyle(NotionButtonStyle(kind: .primary, fill: true))
            .keyboardShortcut(.defaultAction)
            .tip("업무 일지 화면에서 이날을 엽니다 (↩, 달력 칸을 두 번 눌러도 됩니다)")
            .padding(16)
        }
        .background(WL.sidebar)
    }

    private func empty(_ day: String, holiday: String?) -> some View {
        let weekend = WorkLogFormat.dayTint(day) != nil
        let message = page.calendarProject.map { "이날은 ‘\($0)’ 업무가 없습니다" }
            ?? (holiday != nil || weekend ? "쉬는 날입니다" : day > WorkDay.today() ? "아직 오지 않은 날입니다" : "이날 적은 업무가 없습니다")
        return VStack(spacing: 8) {
            Image(systemName: "calendar.badge.plus").font(.system(size: 26)).foregroundStyle(WL.faint)
            Text(message).font(WL.body).foregroundStyle(WL.muted)
            Text("아래 단추로 이날 업무 일지를 열어 적을 수 있습니다").font(WL.caption).foregroundStyle(WL.quiet)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 도움

    /// 숨긴 프로젝트와 막 지운 빈 줄은 달력에 올리지 않는다. `filtered`면 고른 프로젝트만 남긴다.
    private func visible(_ entries: [WorkEntry], filtered: Bool = true) -> [WorkEntry] {
        entries.filter {
            !store.log.hiddenProjects.contains($0.project) && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                && (!filtered || page.calendarProject == nil || $0.project == page.calendarProject)
        }
    }

    private func isOpen(_ entry: WorkEntry) -> Bool {
        !entry.status.isFinished && entry.status != .ongoing
    }

    private func relative(_ day: String) -> String? {
        let today = WorkDay.today()
        switch day {
        case today: return "오늘"
        case WorkDay.adding(-1, to: today): return "어제"
        case WorkDay.adding(1, to: today): return "내일"
        default: return nil
        }
    }

    private func select(_ day: String) {
        page.day = day
        // 앞뒤 달의 날을 누르면 그 달로 넘긴다
        if !WorkDay.month(of: page.calendarMonth).contains(day) { page.calendarMonth = day }
    }
}
