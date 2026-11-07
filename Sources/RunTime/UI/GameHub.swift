import GameCore
import SwiftUI

/// 게임 탭: 왼쪽 비행, 오른쪽 달리기. 기록은 이 Mac에만 남는다.
struct GameHub: View {
    /// 게임은 무대가 켠다.
    let start: (StageAction.Kind) -> Void
    @ObservedObject private var decor = GameDecor.shared
    @StateObject private var form = FlightForm()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            flightColumn.frame(maxWidth: .infinity)
            runColumn.frame(maxWidth: .infinity)
        }
    }

    private var flightColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("비행", FlightRecords.best(form.difficulty).formatted(), detail: "누르는 동안 올라가며 끝없이 날아요. 갈수록 빨라져요")
            HStack(spacing: 6) {
                ForEach(FlightDifficulty.allCases, id: \.self) { level in
                    let on = form.difficulty == level
                    Button { form.difficulty = level } label: {
                        VStack(spacing: 1) {
                            Text(level.title).font(.system(size: 13, weight: on ? .bold : .medium))
                                .foregroundStyle(on ? Theme.primary : Theme.secondary)
                            Text("최고 \(FlightRecords.best(level).formatted())").font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(on ? 0.14 : 0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Button { start(.flight) } label: {
                Label("\(form.difficulty.title)으로 날기", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(GameButtonStyle(height: 34))
            keyHints([("스페이스 · ↑ · 클릭", "누르는 동안 상승"), ("→ · 오른쪽 클릭", "가속 (점수 더)"), ("esc", "나가기")])
            Text("기둥, 떠 있는 바위, 박쥐 떼, 움직이는 문, 떨어지는 상자, 튀는 가시공, 드릴, 좁은 굴이 무작위로 나와요. 슬라임이 붙으면 잠깐 무거워져요.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("달리기", GameRecords.best.formatted(), detail: "끝없이 달려 최고 점수에 도전해요")
            Button { start(.game) } label: {
                Label("달리기 시작", systemImage: "figure.run").frame(maxWidth: .infinity)
            }
            .buttonStyle(GameButtonStyle(height: 34))
            Text("능력 · 다음 판부터 적용").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) {
                ForEach(Ability.allCases) { ability in
                    abilityRow(ability)
                    if ability != Ability.allCases.last { Hairline().padding(.leading, 50) }
                }
            }
            .slotFrame(radius: 10)
            GameKeys()
        }
    }

    private func keyHints(_ items: [(String, String)]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.0) { key, action in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
                    Text(action).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                .fixedSize()
                .padding(.trailing, 8)
            }
        }
    }

    private func header(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.primary)
                Spacer()
                Text(value).font(GameFont.pixel(16)).foregroundStyle(GameKit.gold)
            }
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        }
    }

    private func abilityRow(_ ability: Ability) -> some View {
        HStack(spacing: 10) {
            AbilityIcon(ability: ability, active: decor.isOn(ability))
            VStack(alignment: .leading, spacing: 1) {
                Text(ability.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.primary)
                Text(ability.detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { decor.isOn(ability) }, set: { _ in decor.toggle(ability) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("\(ability.name) 쓰기")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

/// 고른 난이도. 게임을 켤 때 이 값을 읽는다. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class FlightForm: ObservableObject {
    @Published var difficulty = FlightRecords.difficulty {
        didSet { FlightRecords.difficulty = difficulty }
    }
}
