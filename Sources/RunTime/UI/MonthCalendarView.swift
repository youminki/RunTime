import SwiftUI
import WorkLogCore

/// 업무 일지 월간의 달력 보기: 한 달을 macOS 캘린더처럼 큰 칸으로 본다.
/// 칸마다 레드마인 마감 일감과 그날 적은 일을 늘어놓고, 칸을 누르면 그날 일지로, 왼쪽 주 칸을 누르면 그 주간으로 간다.
struct MonthCalendarView: View {
    @ObservedObject var store: WorkLogStore
    @ObservedObject var page: WorkLogPage
    var openOverdue: (() -> Void)?
    @StateObject private var hover = HoveredKey()

    /// 칸 높이. 가운데 칸은 스크롤되어 창 높이에 맞추지 않고, 여섯 줄이 들어가게 둔다.
    private let cellHeight: CGFloat = 126
    private let gutter: CGFloat = 34

    /// 한 번 그릴 때 쓰는 값을 모아 칸마다 다시 거르지 않는다.
    private struct Month {
        let range: ClosedRange<String>
        let days: [String]
        let entries: [String: [WorkEntry]]
        let due: [String: [IssueInfo]]
        /// 마감이 지났는데 아직 열린 내 일감 (오래된 마감 먼저).
        let overdue: [IssueInfo]
    }

    var body: some View {
        let month = load()
        VStack(alignment: .leading, spacing: 12) {
            projectFilter(visible(store.log.entries(in: month.range), filtered: false))
            if !month.overdue.isEmpty { overdueNotice(month.overdue) }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutter, height: 1)
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
                }
                HStack(alignment: .top, spacing: 0) {
                    weekColumn(month)
                    grid(month)
                }
            }
            legend(month)
        }
        .padding(.bottom, 18)
    }

    private func load() -> Month {
        let range = WorkDay.month(of: page.day)
        let days = WorkDay.calendarDays(of: range.lowerBound)
        let shown = days.first!...days.last!
        let entries = Dictionary(grouping: visible(store.log.entries(in: shown)), by: \.day)
        // 프로젝트로 걸렀으면 그 프로젝트 일지가 가리키는 일감의 마감만 남긴다 (레드마인 프로젝트 이름은 일지 프로젝트와 다르다)
        let referenced = page.calendarProject.map { project in
            Set(store.log.entries.filter { $0.project == project }.compactMap(\.issue))
        }
        let mine = store.log.issues.values.filter { issue in
            issue.assigned && issue.dueDate != nil && (referenced?.contains(issue.id) ?? true)
        }
        let due = mine.filter { shown.contains($0.dueDate!) }
        // 지난달에 넘긴 마감은 이번 달 칸에 보이지 않아, 오늘이 든 달을 볼 때 위에 모은다.
        // 눌러 여는 레드마인 "기한 지남"과 건수가 같게, 끝냈거나 닫힌 일감은 뺀다
        let today = WorkDay.today()
        let closed = WorkLogSync.shared.closedStatusIDs
        let overdue = range.contains(today) ? mine.filter { $0.dueDate! < today && $0.isOpen(closed: closed) } : []
        return Month(range: range, days: days, entries: entries,
                     due: Dictionary(grouping: due.sorted { $0.id < $1.id }, by: { $0.dueDate ?? "" }),
                     overdue: overdue.sorted { ($0.dueDate!, $0.id) < ($1.dueDate!, $1.id) })
    }

    // MARK: 프로젝트

    /// 이 달의 프로젝트를 색과 함께 늘어놓는다. 누르면 그 프로젝트만 달력에 남긴다.
    @ViewBuilder
    private func projectFilter(_ entries: [WorkEntry]) -> some View {
        // 고른 프로젝트가 이 달에 없거나 숨겨졌어도 칩을 남겨, 무엇으로 걸렀는지 보이고 다시 눌러 풀 수 있게 한다
        let listed = store.log.orderedProjects(of: entries)
        let projects = listed + [page.calendarProject].compactMap { $0 }.filter { !listed.contains($0) }
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

    /// 마감이 지난 내 일감을 한 줄로 알린다. 전부는 마우스를 올리면 나온다.
    private func overdueNotice(_ issues: [IssueInfo]) -> some View {
        Button { openOverdue?() } label: { overdueLabel(issues) }
            .buttonStyle(.plain)
            .disabled(openOverdue == nil)
            .tip((["마감이 지난 내 일감" + (openOverdue == nil ? "" : " · 누르면 레드마인 화면에서 기한 지남으로 거릅니다")]
                  + issues.map { "\(WorkReport.shortDate($0.dueDate!)) · #\($0.id) " + ($0.path + [$0.subject]).joined(separator: " > ") })
                .joined(separator: "\n"))
            .padding(.leading, gutter)
    }

    private func overdueLabel(_ issues: [IssueInfo]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(Palette.red)
            Text("마감이 지난 내 일감 \(issues.count)건").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.red)
                .monospacedDigit()
                .fixedSize()
            Text(issues.prefix(3).map { "\($0.subject) (\(WorkReport.shortDate($0.dueDate!)))" }.joined(separator: ", ")
                 + (issues.count > 3 ? " 외 \(issues.count - 3)건" : ""))
                .font(.system(size: 12.5))
                .foregroundStyle(WL.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if openOverdue != nil {
                HStack(spacing: 4) {
                    Text("레드마인에서 보기")
                    Image(systemName: "arrow.right").font(.system(size: 10.5, weight: .bold))
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hover.key == "overdue" ? Palette.red : WL.muted)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
            .fill(Palette.red.opacity(hover.key == "overdue" && openOverdue != nil ? 0.14 : 0.08)))
        .contentShape(Rectangle())
        .onHover { hover.update("overdue", $0) }
    }

    // MARK: 주

    /// 달력 왼쪽의 주 칸. 누르면 그 주를 주간 보기로 연다.
    private func weekColumn(_ month: Month) -> some View {
        let weeks = stride(from: 0, to: month.days.count, by: 7).map { month.days[$0] }
        // 목요일이 이 달에 든 주만 `1주`, `2주`로 센다 (달력의 주 번호 관례)
        let counted = weeks.filter { month.range.contains(WorkDay.adding(3, to: $0)) }
        return VStack(spacing: 0) {
            ForEach(weeks, id: \.self) { monday in
                let key = "week:" + monday
                let number = counted.firstIndex(of: monday).map { "\($0 + 1)주" }
                Button { openWeek(monday) } label: {
                    VStack(spacing: 4) {
                        Text(number ?? "")
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(hover.key == key ? WL.text : WL.quiet)
                        if hover.key == key {
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(WL.accent)
                        }
                    }
                    .padding(.top, 8)
                    .frame(width: gutter - 4, height: cellHeight - 4, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover.key == key ? WL.hover : .clear))
                    .frame(width: gutter, height: cellHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover.update(key, $0) }
                .tip("\(WorkLogFormat.weekTitle(monday)) 주간 보기")
                .accessibilityLabel("\(WorkLogFormat.weekTitle(monday)) 주간 보기")
            }
        }
    }

    // MARK: 달력 칸

    private func grid(_ month: Month) -> some View {
        GeometryReader { geo in
            SevenColumns {
                ForEach(month.days, id: \.self) { day in
                    cell(day, entries: month.entries[day] ?? [], due: month.due[day] ?? [], inMonth: month.range.contains(day))
                }
            }
            // 칸이 정수 너비라 남는 몇 pt만큼 테두리를 좁혀 마지막 칸과 겹치게 한다 (요일 머리와 같은 자리)
            .frame(width: (geo.size.width / 7).rounded(.down) * 7)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity)
        }
        .frame(height: cellHeight * CGFloat(month.days.count / 7))
    }

    private func cell(_ day: String, entries: [WorkEntry], due: [IssueInfo], inMonth: Bool) -> some View {
        let today = WorkDay.today()
        let isToday = day == today
        let holiday = KoreanHolidays.name(on: day)
        let tint = WorkLogFormat.dayTint(day)
        // 날짜 줄(약 26pt)을 뺀 높이에 한 줄 16pt씩 들어간다. 넘치면 마지막 줄을 "N개 더"로 쓴다.
        // 마감은 놓치면 안 되어 적은 일보다 먼저 둔다
        let total = due.count + entries.count
        let capacity = max(0, Int((cellHeight - 30) / 16))
        let room = total > capacity ? max(0, capacity - 1) : total
        let shownDue = min(due.count, room)
        let shownEntries = room - shownDue
        let unsent = entries.filter(\.needsRedmine).count
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let holiday {
                    Text(holiday).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.red).lineLimit(1)
                }
                Spacer(minLength: 0)
                // 줄마다 붙이면 좁은 칸에서 제목이 묻혀, 보내지 않은 줄은 날짜 옆에 한 번만 센다
                if unsent > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "paperplane.fill").font(.system(size: 8.5))
                        Text("\(unsent)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(WL.waiting)
                    .fixedSize()
                }
                Text(WorkLogFormat.dayNumber(day))
                    .font(.system(size: 13, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : tint ?? WL.text)
                    .frame(minWidth: 22, minHeight: 22)
                    .background { if isToday { Circle().fill(Palette.red) } }
            }
            .frame(height: 24)
            ForEach(due.prefix(shownDue)) { issue in
                HStack(spacing: 4) {
                    Image(systemName: "flag.fill").font(.system(size: 8.5)).foregroundStyle(Palette.red)
                        .frame(width: 6)
                    // 일감 제목만으로는 어느 화면 일인지 모를 때가 많아 (`마크업`) 상위 일감 이름을 옅게 붙인다
                    (Text(issue.subject).fontWeight(.medium).foregroundColor(day <= today ? Palette.red : WL.text)
                        + Text(issue.path.last.map { " · " + $0 } ?? "").foregroundColor(WL.quiet))
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .frame(height: 15)
            }
            ForEach(entries.prefix(shownEntries)) { entry in
                HStack(spacing: 4) {
                    Circle().fill(WL.projectColor(entry.project)).frame(width: 6, height: 6)
                    // 줄 높이 15에 12pt: 12.5pt는 한글 아래가 다음 줄에 닿는다
                    Text(WorkLogFormat.breadcrumb(entry.title).leaf)
                        .font(.system(size: 12))
                        .foregroundStyle(entry.status.isFinished ? WL.text : WL.accent)
                        .lineLimit(1)
                }
                .frame(height: 15)
            }
            if total > room {
                Text("+\(total - room)개 더").font(.system(size: 11.5, weight: .medium)).foregroundStyle(WL.muted)
                    .frame(height: 15)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .opacity(inMonth ? 1 : 0.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: cellHeight)
        .background(hover.key == day ? WL.hover : inMonth ? Color.clear : WL.sidebar)
        // 칸마다 오른쪽·아래 선만 그어 겹친 선이 두꺼워지지 않게 한다
        .overlay(alignment: .trailing) { Rectangle().fill(WL.border).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(WL.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover.update(day, $0) }
        .onTapGesture { openDay(day) }
        .tip(tip(day, holiday: holiday, entries: entries, due: due))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openDay(day) }
    }

    private func tip(_ day: String, holiday: String?, entries: [WorkEntry], due: [IssueInfo]) -> String {
        let head = [WorkLogFormat.dayTitle(day), holiday].compactMap { $0 }.joined(separator: " · ")
        guard !entries.isEmpty || !due.isEmpty else { return head + " · 누르면 이날 일지를 엽니다" }
        let lines = due.map { "마감 · #\($0.id) " + ($0.path + [$0.subject]).joined(separator: " > ") }
            + entries.map { "\($0.project) · \(WorkReport.line($0))" + ($0.needsRedmine ? " · 레드마인에 아직 안 보냄" : "") }
        return ([head] + lines.prefix(12) + (lines.count > 12 ? ["… \(lines.count - 12)줄 더"] : []))
            .joined(separator: "\n")
    }

    /// 칸에 쓰인 표시만 풀어 적는다.
    @ViewBuilder
    private func legend(_ month: Month) -> some View {
        let inMonth = month.days.filter(month.range.contains)
        let hasDue = inMonth.contains { month.due[$0] != nil }
        let hasUnsent = inMonth.contains { month.entries[$0]?.contains(where: \.needsRedmine) ?? false }
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Text("파란 글씨").foregroundStyle(WL.accent)
                Text("끝나지 않은 일")
            }
            if hasUnsent {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill").font(.system(size: 9)).foregroundStyle(WL.waiting)
                    Text("레드마인에 아직 안 보낸 줄")
                }
            }
            if hasDue {
                HStack(spacing: 5) {
                    Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Palette.red)
                    Text("내 레드마인 일감 마감")
                }
            }
            Spacer(minLength: 0)
            Text("칸을 누르면 그날 일지, 왼쪽 주를 누르면 주간으로 갑니다")
        }
        .font(WL.caption)
        .foregroundStyle(WL.quiet)
        .lineLimit(1)
        .padding(.leading, gutter)
    }

    // MARK: 도움

    /// 숨긴 프로젝트와 막 지운 빈 줄은 달력에 올리지 않는다. `filtered`면 고른 프로젝트만 남긴다.
    private func visible(_ entries: [WorkEntry], filtered: Bool = true) -> [WorkEntry] {
        entries.filter {
            !store.log.hiddenProjects.contains($0.project) && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                && (!filtered || page.calendarProject == nil || $0.project == page.calendarProject)
        }
    }

    private func openDay(_ day: String) {
        page.search = ""
        page.day = day
        page.mode = .day
    }

    private func openWeek(_ monday: String) {
        page.search = ""
        page.day = monday
        page.mode = .week
    }
}
