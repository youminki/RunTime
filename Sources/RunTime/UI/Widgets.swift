import SwiftUI

/// 카드 아래 수치 한 칸 (Stats·iStat Menus 팝업의 요약 칸처럼): 작은 이름 위에 큰 숫자.
struct StatColumn: View {
    let label: String
    let value: String
    var unit: String = ""

    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
