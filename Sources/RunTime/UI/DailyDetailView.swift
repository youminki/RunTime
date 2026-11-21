import SwiftUI
import UsageCore

/// 일별 사용량 (iOS 스크린 타임처럼): 왼쪽에 지표 3칸(일평균·오늘 대비·비용)과 날짜별 막대·평균선, 오른쪽에 모델별과 프로젝트별.
/// 최근 8일, 이 Mac의 Claude Code 기록 기준. 앱 창 사용량 화면의 아래쪽 구역으로 들어간다.
struct DailyDetailView: View {
    @ObservedObject var engine: UsageEngine
    @StateObject private var hover = HoveredDay()

    var body: some View {
        let totals = engine.snapshot?.dailyTotals ?? []
        if totals.isEmpty {
            Text("아직 기록이 없습니다.").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.groupedRow))
        } else {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    summary(totals)
                    chart(totals)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    models(totals)
                    projects(totals)
                }
                .frame(width: 360)
            }
        }
    }

    // MARK: 요약

    private func summary(_ totals: [UsageStore.DailyTotal]) -> some View {
        let cost = totals.map(\.costUSD).reduce(0, +)
        let tokens = totals.map(\.tokens).reduce(0, +)
        let output = totals.map(\.outputTokens).reduce(0, +)
        let cacheRead = totals.map(\.cacheReadTokens).reduce(0, +)
        // 오늘은 아직 끝나지 않은 날이라 평소 값은 오늘을 뺀 쓴 날로 낸다
        let past = totals.filter { !isToday($0.dayStart) }
        let usual = past.isEmpty ? nil : past.map(\.costUSD).reduce(0, +) / Double(past.count)
        let today = totals.first { isToday($0.dayStart) }?.costUSD ?? 0
        let input = tokens - output
        return HStack(spacing: 12) {
            kpi("8일 비용", value: Format.usd(cost), unit: nil,
                note: "쓴 날 \(totals.count)일 · 하루 약 \(Format.usd(cost / Double(totals.count)))")
                .tip("API 단가로 환산한 참고값입니다. 토큰 합계는 \(Format.tokens(tokens))이며 대부분 캐시 읽기라 비용으로 봐야 작업량이 보입니다")
            kpi("평소 대비", value: usual.map { versus(today, usual: $0) } ?? "-", unit: nil,
                note: usual.map { "오늘 \(Format.usd(today)) · 평소 \(Format.usd($0))" } ?? "비교할 지난 기록 없음")
                .tip("오늘 쓴 비용을 오늘을 뺀 쓴 날의 하루 평균과 견준 값입니다")
            kpi("캐시 적중", value: input > 0 ? "\(Int((Double(cacheRead) / Double(input) * 100).rounded()))%" : "-", unit: nil,
                note: "출력 \(Format.tokens(output)) 토큰")
                .tip("입력 쪽 토큰 중 캐시에서 읽은 비율입니다. 낮아지면 대화를 새로 열거나 맥락이 자주 바뀌어 같은 내용을 다시 내는 중입니다")
        }
    }

    private func kpi(_ title: String, value: String, unit: String?, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit { Text(unit).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
            }
            Text(note).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.groupedRow))
    }

    /// 오늘을 지난 날들의 하루 평균과 견준 증감률.
    private func versus(_ today: Double, usual: Double) -> String {
        guard usual > 0 else { return "-" }
        let change = Int(((today - usual) / usual * 100).rounded())
        return change == 0 ? "같음" : "\(change > 0 ? "▲" : "▼") \(abs(change))%"
    }

    // MARK: 막대

    /// 막대 한 칸. 쓰지 않은 날도 칸을 두어 날짜 간격이 그대로 보이게 한다.
    private struct ChartDay {
        let dayStart: Date
        let total: UsageStore.DailyTotal?
        var tokens: Int { total?.tokens ?? 0 }
        func value(byCost: Bool) -> Double { total.map { byCost ? $0.costUSD : Double($0.tokens) } ?? 0 }
    }

    /// 오늘부터 거슬러 올라간 8일 (오래된 날부터).
    private func chartDays(_ totals: [UsageStore.DailyTotal]) -> [ChartDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let byDay = Dictionary(totals.map { ($0.dayStart, $0) }, uniquingKeysWith: { first, _ in first })
        return (0..<UsageStore.dailyDays).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { ChartDay(dayStart: $0, total: byDay[$0]) }
        }
    }

    private func chart(_ totals: [UsageStore.DailyTotal]) -> some View {
        let days = chartDays(totals)
        let byCost = hover.byCost
        func label(_ value: Double) -> String { byCost ? Format.usd(value) : Format.tokens(Int(value)) }
        let peak = CGFloat(max(days.map { $0.value(byCost: byCost) }.max() ?? 1, 0.0001))
        // 위 요약과 같게 쓴 날만으로 평균을 낸다
        let average = CGFloat(totals.map { byCost ? $0.costUSD : Double($0.tokens) }.reduce(0, +)) / CGFloat(max(totals.count, 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let index = hover.index, days.indices.contains(index) {
                    let day = days[index]
                    Text(dayTitle(day.dayStart)).font(.system(size: 12, weight: .semibold))
                    Text(day.total.map { "\(Format.tokens($0.tokens)) · \(Format.usd($0.costUSD))" } ?? "쓰지 않음")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(byCost ? "날짜별 비용" : "날짜별 토큰").font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Picker("", selection: $hover.byCost) {
                    Text("토큰").tag(false)
                    Text("비용").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
            .frame(height: 22)
            GeometryReader { geo in
                let height = geo.size.height
                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(Array(days.enumerated()), id: \.element.dayStart) { index, day in
                            Group {
                                if let total = day.total {
                                    let barHeight = max(height * CGFloat(day.value(byCost: byCost)) / peak, 3)
                                    if byCost {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Palette.blue)
                                            .frame(height: barHeight).tip(breakdown(total))
                                    } else {
                                        stackedBar(total, height: barHeight)
                                    }
                                } else {
                                    RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.08)).frame(height: 3)
                                }
                            }
                            .opacity(hover.index == nil || hover.index == index ? 1 : 0.4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .contentShape(Rectangle())   // 낮은 막대도 칸 전체에서 가리킬 수 있게
                            .onHover { hover.update(index, $0) }
                        }
                    }
                    // 눈금선: 맨 위(최고)와 절반
                    ForEach([1.0, 0.5], id: \.self) { fraction in
                        let gy = height * (1 - CGFloat(fraction))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: gy))
                            path.addLine(to: CGPoint(x: geo.size.width, y: gy))
                        }
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        Text(label(Double(peak) * fraction))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .position(x: 22, y: fraction == 1 ? gy + 8 : gy - 8)
                    }
                    .allowsHitTesting(false)
                    // 평균선
                    let y = height * (1 - average / peak)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    // 막대의 모델 색(Haiku 초록 등)과 헷갈리지 않게 무채색으로 긋는다
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .allowsHitTesting(false)
                    Text("평균")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Palette.groupedRow))
                        .position(x: geo.size.width - 12, y: max(y - 8, 6))
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 220)
            HStack(spacing: 8) {
                ForEach(days, id: \.dayStart) { day in
                    Text(weekday(day.dayStart))
                        .font(.system(size: 11.5, weight: isToday(day.dayStart) ? .bold : .regular))
                        .foregroundStyle(isToday(day.dayStart) ? .primary : day.total == nil ? .tertiary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            if byCost {
                Text("비용은 API 단가로 환산한 참고값입니다.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                legend(families(in: totals))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.groupedRow))
    }

    /// 모델 계열별로 아래부터 쌓는다.
    private func stackedBar(_ day: UsageStore.DailyTotal, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(segments(of: day).reversed(), id: \.family) { segment in
                Rectangle()
                    .fill(Self.color(for: segment.family))
                    .frame(height: height * CGFloat(segment.tokens) / CGFloat(max(day.tokens, 1)))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .tip(breakdown(day))
    }

    private func legend(_ families: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(families, id: \.self) { family in
                HStack(spacing: 4) {
                    Circle().fill(Self.color(for: family)).frame(width: 7, height: 7)
                    Text(family)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    // MARK: 모델

    /// 최근 8일 모델 계열별 토큰 비중.
    @ViewBuilder
    private func models(_ totals: [UsageStore.DailyTotal]) -> some View {
        let byFamily = totals.reduce(into: [String: Int]()) { sum, day in
            for (model, tokens) in day.modelTokens { sum[Self.family(of: model), default: 0] += tokens }
        }
        let rows = byFamily.sorted { Self.rank($0.key) < Self.rank($1.key) }
        let total = max(rows.map(\.value).reduce(0, +), 1)
        if !rows.isEmpty {
            GroupedSection("모델별", footer: "최근 8일 토큰 비중입니다. 비용은 API 단가로 환산한 참고값입니다.") {
                ForEach(rows, id: \.key) { family, value in
                    shareRow(family, tokens: value, cost: nil, share: Double(value) / Double(total), color: Self.color(for: family))
                }
            }
        }
    }

    // MARK: 프로젝트

    /// 최근 8일 동안 폴더(프로젝트)별로 쓴 양. 많이 쓴 6개만 보이고 나머지는 묶는다.
    @ViewBuilder
    private func projects(_ totals: [UsageStore.DailyTotal]) -> some View {
        let (tokens, costs) = Self.projectTotals(totals)
        let sorted = tokens.sorted { $0.value > $1.value }
        let total = max(sorted.map(\.value).reduce(0, +), 1)
        let shown = Array(sorted.prefix(Self.shownProjects))
        let rest = sorted.dropFirst(Self.shownProjects)
        if sorted.count > 1 || sorted.first?.key.isEmpty == false {
            GroupedSection("프로젝트별", footer: "Claude Code를 연 폴더 이름으로 나눕니다.") {
                ForEach(shown, id: \.key) { name, value in
                    projectRow(name.isEmpty ? "폴더 모름" : name, tokens: value, cost: costs[name] ?? 0,
                               share: Double(value) / Double(total))
                }
                if !rest.isEmpty {
                    let value = rest.map(\.value).reduce(0, +)
                    projectRow("그 밖 \(rest.count)개", tokens: value, cost: rest.map { costs[$0.key] ?? 0 }.reduce(0, +),
                               share: Double(value) / Double(total))
                }
            }
        }
    }

    private static let shownProjects = 6

    private static func projectTotals(_ totals: [UsageStore.DailyTotal]) -> ([String: Int], [String: Double]) {
        var tokens: [String: Int] = [:], costs: [String: Double] = [:]
        for day in totals {
            for (name, value) in day.projectTokens { tokens[name, default: 0] += value }
            for (name, value) in day.projectCostUSD { costs[name, default: 0] += value }
        }
        return (tokens, costs)
    }

    private func projectRow(_ name: String, tokens: Int, cost: Double, share: Double) -> some View {
        shareRow(name, tokens: tokens, cost: cost, share: share, color: Palette.blue)
    }

    /// 이름, 비중 막대, %, 토큰, 비용(있으면)을 한 줄에 둔다. 열 너비를 고정해 줄마다 같은 자리에 오게 한다.
    private func shareRow(_ name: String, tokens: Int, cost: Double?, share: Double, color: Color) -> some View {
        // 긴 폴더 이름은 두 줄로 꺾이지 않게 줄이고, 마우스를 올리면 전체 이름을 보여 준다
        GroupedRow(name.count > 12 ? name.prefix(11) + "…" : name) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(width: 44, height: 5)
                    // 1%가 안 되는 항목은 막대를 비우고 <1%로 적는다 (0%에 막대가 있으면 어긋나 보인다)
                    if share >= 0.005 {
                        Capsule().fill(color).frame(width: max(3, 44 * share), height: 5)
                    }
                }
                Text(share < 0.005 ? "<1%" : "\(Int((share * 100).rounded()))%").foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .frame(width: 38, alignment: .trailing)
                Text(Format.tokens(tokens))
                    .frame(width: 58, alignment: .trailing)
                if let cost {
                    Text(Format.usd(cost)).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
        }
        .tip(name)
    }

    // MARK: 날짜

    private func isToday(_ date: Date) -> Bool { Calendar.current.isDateInToday(date) }

    private func dayTitle(_ date: Date) -> String {
        isToday(date) ? "오늘" : Self.dayFormatter.string(from: date)
    }

    private func weekday(_ date: Date) -> String {
        isToday(date) ? "오늘" : Self.weekdayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E)"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "E"
        return f
    }()

    // MARK: 모델 계열

    private struct Segment {
        let family: String
        let tokens: Int
    }

    private static let familyOrder = ["Fable", "Opus", "Sonnet", "Haiku"]

    private func segments(of day: UsageStore.DailyTotal) -> [Segment] {
        var byFamily: [String: Int] = [:]
        for (model, tokens) in day.modelTokens { byFamily[Self.family(of: model), default: 0] += tokens }
        return byFamily.map { Segment(family: $0.key, tokens: $0.value) }
            .sorted { Self.rank($0.family) < Self.rank($1.family) }
    }

    private func families(in totals: [UsageStore.DailyTotal]) -> [String] {
        Set(totals.flatMap { $0.modelTokens.keys.map(Self.family(of:)) })
            .sorted { Self.rank($0) < Self.rank($1) }
    }

    private func breakdown(_ day: UsageStore.DailyTotal) -> String {
        let models = segments(of: day)
            .map { "\($0.family) \(Format.tokens($0.tokens))" }
            .joined(separator: " · ")
        let projects = day.projectTokens.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key.isEmpty ? "폴더 모름" : $0.key) \(Format.tokens($0.value))" }
            .joined(separator: " · ")
        return projects.isEmpty ? models : models + "\n" + projects
    }

    /// Opus·Sonnet·Haiku·Fable 밖의 모델은 "기타"로 묶는다.
    private static func family(of model: String) -> String {
        let name = Format.modelName(model)
        return familyOrder.contains(name) ? name : "기타"
    }

    private static func rank(_ family: String) -> Int {
        familyOrder.firstIndex(of: family) ?? familyOrder.count
    }

    private static func color(for family: String) -> Color {
        switch family {
        case "Fable": return Palette.orange
        // 쌓인 막대에서 바로 갈라 보이게 색상환에서 떨어진 색을 쓴다
        case "Opus": return Palette.indigo
        case "Sonnet": return Palette.teal
        case "Haiku": return Palette.green
        default: return Palette.gray
        }
    }
}

/// 마우스를 올린 날. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class HoveredDay: ObservableObject {
    @Published var index: Int?
    /// 막대를 토큰이 아니라 비용으로 그릴지.
    @Published var byCost = false

    func update(_ index: Int, _ inside: Bool) {
        if inside { self.index = index } else if self.index == index { self.index = nil }
    }
}
