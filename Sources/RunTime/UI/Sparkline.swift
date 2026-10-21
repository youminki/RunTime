import SwiftUI

/// 최근 30분 tokens/min 선 그래프. 막대보다 흐름(오르내림)이 잘 읽힌다. 마우스를 올린 분을 `hoverIndex`로 알린다.
struct Sparkline: View {
    let values: [Int]
    @Binding var hoverIndex: Int?
    /// 팝오버는 44, 창은 남는 높이를 채우려고 더 크게 그린다.
    var height: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 0, 1)
            let stepX = geo.size.width / CGFloat(max(values.count - 1, 1))
            let inset: CGFloat = 1.5
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX,
                        y: inset + (geo.size.height - inset * 2) * (1 - CGFloat(v) / CGFloat(maxValue)))
            }
            ZStack(alignment: .topLeading) {
                Self.curve(points, closedTo: geo.size.height)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                Self.curve(points, closedTo: nil)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                if let i = hoverIndex, points.indices.contains(i) {
                    Rectangle()
                        .fill(Theme.tertiary)
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: points[i].x)
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5)).position(points[i])
                } else if let last = points.last {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5)).position(last)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard !values.isEmpty else { return }
                    let index = min(max(Int((location.x / stepX).rounded()), 0), values.count - 1)
                    if hoverIndex != index { hoverIndex = index }   // 같은 분이면 팝오버를 다시 그리지 않는다
                case .ended:
                    if hoverIndex != nil { hoverIndex = nil }
                }
            }
        }
        .frame(height: height)
    }

    /// Catmull-Rom 곡선. 제어점은 그래프 높이 안으로 묶어 0 아래로 출렁이지 않게 한다.
    private static func curve(_ points: [CGPoint], closedTo bottom: CGFloat?) -> Path {
        Path { p in
            guard let first = points.first else { return }
            let lowY = points.map(\.y).max() ?? 0
            let highY = points.map(\.y).min() ?? 0
            func clamp(_ y: CGFloat) -> CGFloat { min(max(y, highY), lowY) }
            if let bottom {
                p.move(to: CGPoint(x: first.x, y: bottom))
                p.addLine(to: first)
            } else {
                p.move(to: first)
            }
            for i in 0..<max(points.count - 1, 0) {
                let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1]
                let p3 = points[min(i + 2, points.count - 1)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clamp(p1.y + (p2.y - p0.y) / 6))
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clamp(p2.y - (p3.y - p1.y) / 6))
                p.addCurve(to: p2, control1: c1, control2: c2)
            }
            if let bottom, let last = points.last {
                p.addLine(to: CGPoint(x: last.x, y: bottom))
                p.closeSubpath()
            }
        }
    }
}
