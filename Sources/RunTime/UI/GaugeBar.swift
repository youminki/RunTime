import SwiftUI

/// 사용률 막대. 80% 전 파랑, 80% 주황, 95% 빨강. 링보다 길이로 읽는 막대가 두 값을 빨리 견준다.
struct GaugeBar: View {
    /// 공식 값이 없으면 nil. 막대를 비우고 접근성 값도 "값 없음"으로 둔다.
    let percent: Double?
    /// 창이 지난 비율(0~1). 눈금으로 그려 사용량이 시간보다 앞서는지 보이게 한다.
    var elapsed: Double? = nil

    private func width(_ percent: Double, in total: CGFloat) -> CGFloat {
        total * min(max(percent, 0), 100) / 100
    }

    var body: some View {
        let percent = self.percent ?? 0
        let color = Theme.ring(percent)
        GeometryReader { geo in
            let total = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: width(percent, in: total))
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                if let elapsed {
                    // 막대 색과 겹쳐도 보이게 밝은 눈금
                    Capsule()
                        .fill(Theme.primary.opacity(0.75))
                        .frame(width: 2, height: 12)
                        .offset(x: min(max(width(elapsed * 100, in: total), 0), total - 1))
                }
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.25), value: percent)
        .tip(helpText)
        .accessibilityElement()
        .accessibilityValue(accessibilityText)
    }

    private var helpText: String {
        var lines: [String] = []
        if let elapsed { lines.append("눈금: 이번 창 시간의 \(Int((elapsed * 100).rounded()))% 경과") }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        let value = percent.map { "\(Int($0.rounded(.down)))%" } ?? "값 없음"
        guard let elapsed else { return value }
        return "\(value), 시간 \(Int((elapsed * 100).rounded()))% 경과"
    }
}
