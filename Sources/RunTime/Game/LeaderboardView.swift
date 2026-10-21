import SwiftUI

/// 미니게임 순위표. 게임 화면 오른쪽에 한 칸으로 두고, 순위 참여와 닉네임도 여기서 정한다.
struct LeaderboardView: View {
    @ObservedObject private var board = Leaderboard.shared
    @StateObject private var state = LeaderboardState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("기간", selection: $state.period) {
                ForEach(Leaderboard.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ranking
            participation
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { state.start() }
        .onDisappear { state.stop() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("순위").font(.system(size: 15, weight: .bold))
                Text("장애물 피하기 최고 점수").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { state.load(keepVisible: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Palette.groupedRow))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("새로고침")
            .tip("새로고침 (열려 있는 동안 30초마다 새로 받습니다)")
        }
    }

    @ViewBuilder
    private var ranking: some View {
        if let message = state.message {
            placeholder("exclamationmark.triangle", message)
        } else if let result = state.board {
            if result.entries.isEmpty {
                placeholder("flag.checkered", state.period == .week ? "이번 주 기록이 아직 없습니다." : "아직 기록이 없습니다.")
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        podium(Array(result.entries.prefix(3)))
                        let rest = Array(result.entries.dropFirst(3))
                        if rest.isEmpty {
                            Text(footerText(result)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
                        } else {
                            GroupedSection(footer: footerText(result)) {
                                ForEach(rest) { row($0) }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func footerText(_ result: Leaderboard.Board) -> String {
        var parts: [String] = []
        if let you = result.you {
            parts.append("내 순위 \(you.rank)위 · 최고 \(you.score)점")
        }
        parts.append("\(result.total)명 참여")
        if let updated = state.updated {
            parts.append("\(updated.formatted(date: .omitted, time: .shortened)) 갱신")
        }
        return parts.joined(separator: " · ")
    }

    private func placeholder(_ systemImage: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.groupedRow))
    }

    /// 1~3위 시상대. 가운데가 1위, 왼쪽 2위, 오른쪽 3위. 빈 자리는 점선으로 남긴다.
    private func podium(_ top: [Leaderboard.Board.Entry]) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach([1, 0, 2], id: \.self) { index in
                podiumColumn(index < top.count ? top[index] : nil, place: index + 1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    private func podiumColumn(_ entry: Leaderboard.Board.Entry?, place: Int) -> some View {
        let medal = Self.medal(place) ?? Palette.gray
        let first = place == 1
        let block: CGFloat = [64, 46, 34][place - 1]
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(entry == nil ? Color.primary.opacity(0.06) : medal)
                if first, entry != nil {
                    Image(systemName: "crown.fill").font(.system(size: 13)).foregroundStyle(Self.gold)
                        .offset(y: -26)
                }
                Text(entry.map { String($0.nickname.prefix(1)).uppercased() } ?? "")
                    .font(.system(size: first ? 18 : 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.72))
            }
            .frame(width: first ? 44 : 36, height: first ? 44 : 36)
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(entry?.nickname ?? "비어 있음")
                        .font(.system(size: 12, weight: entry?.you == true ? .bold : .semibold)).lineLimit(1)
                        .foregroundStyle(entry == nil ? .tertiary : .primary)
                    if entry?.you == true {
                        Text("나").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Palette.blue)
                    }
                }
                Text(entry.map { $0.score.formatted() } ?? "-")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(entry == nil ? .tertiary : .secondary)
            }
            ZStack(alignment: .top) {
                UnevenTop(radius: 8)
                    .fill(entry == nil ? Color.primary.opacity(0.04) : Palette.groupedRow)
                Rectangle().fill(entry == nil ? Color.clear : medal).frame(height: 3)
                    .clipShape(UnevenTop(radius: 8))
                Text("\(place)").font(.system(size: first ? 22 : 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(entry == nil ? Color.primary.opacity(0.15) : medal)
                    .padding(.top, first ? 12 : 8)
            }
            .frame(height: block)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.map { "\(place)위 \($0.nickname), \($0.score)점" } ?? "\(place)위 비어 있음")
    }

    /// 위 모서리만 둥근 시상대 칸.
    private struct UnevenTop: Shape {
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            p.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }

    /// 1~3위는 메달 색. 같은 점수 1위가 여럿이어도 먼저 세운 맨 위 한 명에게만 왕관 (요약의 1위와 같은 기준)
    private func row(_ entry: Leaderboard.Board.Entry) -> some View {
        let medal = Self.medal(entry.rank)
        return HStack(spacing: 10) {
            Text("\(entry.rank)")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(medal == nil ? Color.secondary : Color.black.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(Circle().fill(medal ?? Color.primary.opacity(0.06)))
            Text(entry.nickname).font(.system(size: 13, weight: entry.you ? .semibold : .regular)).lineLimit(1)
            if entry.id == state.board?.entries.first?.id {
                Image(systemName: "crown.fill").font(.system(size: 10)).foregroundStyle(Self.gold)
            }
            if entry.you {
                Text("나").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.blue)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.blue.opacity(0.15)))
            }
            Spacer()
            Text("\(entry.score)").font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(entry.you ? Palette.blue.opacity(0.08) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, 46)
        }
    }

    private static let gold = Color(nsColor: NSColor(hex: 0xE0A82E))

    private static func medal(_ rank: Int) -> Color? {
        switch rank {
        case 1: return gold
        case 2: return Color(nsColor: NSColor(hex: 0xB9C0C9))
        case 3: return Color(nsColor: NSColor(hex: 0xCD8C55))
        default: return nil
        }
    }

    private var participation: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupedSection(footer: "무작위 ID, 닉네임, 점수와 플레이 기록을 순위 서버로 보냅니다. 사용량과 Claude 계정 정보는 보내지 않습니다.") {
                ToggleRow(title: "순위에 참여", icon: "person.crop.circle.fill", tint: Palette.blue, isOn: $board.isOn)
                    .tip("참여하면 최근 7일 동안 보낸 점수보다 높을 때 무작위 ID, 닉네임, 점수, 코인 수, 플레이 시간, 앱 버전을 보내고, 순위 소식을 받으려고 10분마다 ID와 함께 순위 요약을 받습니다. 참여하지 않으면 ID 없이 공개 순위만 받습니다.")
                if board.isOn {
                    GroupedRow("닉네임", icon: "character.cursor.ibeam", tint: Palette.indigo) {
                        TextField("닉네임", text: $board.nickname, prompt: Text("2~12자"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                            .onSubmit { if Leaderboard.isValid(nickname: board.nickname) { state.rename() } }
                        Button("바꾸기") { state.rename() }
                            .controlSize(.small)
                            .disabled(!Leaderboard.isValid(nickname: board.nickname))
                            .tip("이미 올린 기록의 닉네임도 바꿉니다")
                    }
                }
                Button { state.confirmingForget = true } label: {
                    GroupedRow("내 기록 지우기") { EmptyView() }
                        .foregroundStyle(Palette.red)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip("서버에서 내 점수와 닉네임을 지우고 참여를 끕니다")
                .confirmationDialog("서버에서 내 기록을 지울까요?", isPresented: $state.confirmingForget) {
                    Button("지우기", role: .destructive) { state.forget() }
                } message: {
                    Text("내 점수, 닉네임, 고스트를 지우고 순위 참여를 끕니다. 되돌릴 수 없습니다.")
                }
            }
            if board.isOn, !Leaderboard.isValid(nickname: board.nickname) {
                Text("한글·영문·숫자로 2~12자를 넣어야 점수를 보냅니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.orange).padding(.horizontal, 14)
            }
            if let notice = state.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
        }
    }
}

/// 순위표 창 상태. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class LeaderboardState: ObservableObject {
    @Published var period: Leaderboard.Period = .all { didSet { if period != oldValue { load() } } }
    @Published private(set) var board: Leaderboard.Board?
    @Published private(set) var message: String?
    @Published private(set) var notice: String?
    @Published private(set) var updated: Date?
    @Published var confirmingForget = false
    private var timer: Timer?

    /// 창이 열려 있는 동안 30초마다 새로 받는다. 이미 보이는 표는 받는 동안에도 그대로 둔다.
    func start() {
        load()
        timer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.load(keepVisible: true) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func load(keepVisible: Bool = false) {
        if !keepVisible {
            board = nil
            message = nil
        }
        let period = period
        Leaderboard.shared.fetch(period) { [weak self] result in
            guard let self, self.period == period else { return }
            switch result {
            case .success(let board):
                self.board = board
                self.message = nil
                self.updated = Date()
            case .failure(let error):
                if self.board == nil { self.message = error.localizedDescription }
            }
        }
    }

    func rename() {
        Leaderboard.shared.rename { [weak self] result in
            if case .failure(let error) = result { self?.notice = error.localizedDescription; return }
            self?.notice = "이름을 바꿨습니다."
            self?.load()
        }
    }

    func forget() {
        Leaderboard.shared.forgetMe { [weak self] result in
            if case .failure(let error) = result { self?.notice = error.localizedDescription; return }
            self?.notice = "서버에서 내 기록을 지웠습니다."
            self?.load()
        }
    }
}
