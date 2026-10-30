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
            // 고른 날 칸은 끌어서 넓히고, 두 번 누르면 기본 300으로 돌아간다
            ColumnDivider(width: Binding(get: { page.calendarDetailWidth ?? 300 }, set: { page.calendarDetailWidth = $0 }),
                          range: 240...520, standard: 300, trailing: true, reset: { page.calendarDetailWidth = nil })
            detail
                .frame(width: page.calendarDetailWidth ?? 300)
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
    }

    // MARK: 머리

    private var header: some View {
        let month = page.calendarMonth
        let entries = visible(store.log.entries(in: WorkDay.month(of: month)))
        let parts = month.split(separator: "-")
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(parts.count == 3 ? "\(Int(parts[1]) ?? 0)월" : month).font(WL.pageTitle)
                Text(String(month.prefix(4)) + "년").font(.system(size: 20, weight: .medium)).foregroundStyle(WL.muted)
            }
            .monospacedDigit()
            Text(entries.isEmpty ? "기록 없음" : "\(Set(entries.map(\.day)).count)일 · \(entries.count)줄")
                .font(WL.meta).foregroundStyle(WL.muted).monospacedDigit()
            Spacer()
            HStack(spacing: 4) {
                Button { page.calendarMonth = WorkDay.addingMonths(-1, to: month) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(GhostIconButtonStyle())
                    .keyboardShortcut("[", modifiers: .command)
                    .tip("지난달 (⌘[)")
                Button("오늘") { select(WorkDay.today()) }
                    .buttonStyle(NotionButtonStyle())
                    .keyboardShortcut("t", modifiers: .command)
                    .tip("오늘로 가기 (⌘T)")
                Button { page.calendarMonth = WorkDay.addingMonths(1, to: month) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(GhostIconButtonStyle())
                    .keyboardShortcut("]", modifiers: .command)
                    .tip("다음 달 (⌘])")
            }
        }
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
                Text("\(entries.count - shown)개 더").font(.system(size: 11.5, weight: .medium)).foregroundStyle(WL.muted)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(WorkLogFormat.longDay(day)).font(WL.title)
                HStack(spacing: 8) {
                    if let holiday { Text(holiday).foregroundStyle(Palette.red) }
                    if entries.isEmpty {
                        Text("기록 없음").foregroundStyle(WL.muted)
                    } else {
                        Tally(title: "완료", value: entries.filter(\.status.isFinished).count, tint: WL.done)
                        Tally(title: "진행", value: entries.filter { !$0.status.isFinished && $0.status != .ongoing }.count,
                              tint: WL.accent)
                    }
                }
                .font(WL.meta)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)
            SlimScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.log.orderedProjects(of: entries), id: \.self) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ProjectSwatch(name: project, size: 8)
                                Text(project).font(WL.heading)
                            }
                            PathGroupedRows(entries: entries.filter { $0.project == project }) { entry, path in
                                HStack(spacing: 8) {
                                    StatusGlyph(status: entry.status)
                                    Text(path == nil ? entry.title : WorkLogFormat.breadcrumb(entry.title).leaf)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
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
            Rectangle().fill(WL.border).frame(height: 1)
            Button { openDay(day) } label: {
                Label("업무 일지에서 열기", systemImage: "checklist")
            }
            .buttonStyle(NotionButtonStyle(kind: .primary, fill: true))
            .keyboardShortcut(.defaultAction)
            .padding(16)
        }
        .background(WL.sidebar)
    }

    // MARK: 도움

    /// 숨긴 프로젝트와 막 지운 빈 줄은 달력에 올리지 않는다.
    private func visible(_ entries: [WorkEntry]) -> [WorkEntry] {
        entries.filter { !store.log.hiddenProjects.contains($0.project) && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func select(_ day: String) {
        page.day = day
        // 앞뒤 달의 날을 누르면 그 달로 넘긴다
        if !WorkDay.month(of: page.calendarMonth).contains(day) { page.calendarMonth = day }
    }
}
