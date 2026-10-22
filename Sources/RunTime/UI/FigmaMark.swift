import SwiftUI

/// 피그마 로고. "피그마에서 열기" 자리에 써서 어디로 가는 단추인지 한눈에 보이게 한다.
/// 공식 로고 비율(38×57)의 다섯 조각을 그대로 그린다.
struct FigmaMark: View {
    var height: CGFloat = 14

    private static let red = Color(red: 0xF2 / 255, green: 0x4E / 255, blue: 0x1E / 255)
    private static let coral = Color(red: 0xFF / 255, green: 0x72 / 255, blue: 0x62 / 255)
    private static let purple = Color(red: 0xA2 / 255, green: 0x59 / 255, blue: 0xFF / 255)
    private static let blue = Color(red: 0x1A / 255, green: 0xBC / 255, blue: 0xFE / 255)
    private static let green = Color(red: 0x0A / 255, green: 0xCF / 255, blue: 0x83 / 255)

    var body: some View {
        Canvas { context, size in
            let u = size.height / 57
            // 조각마다 지름 19짜리 원과 각진 쪽을 채우는 네모를 겹쳐 그린다 (모서리마다 둥글기를 다르게 주는 API가 macOS 14부터라)
            func circle(_ x: CGFloat, _ y: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x * u, y: y * u, width: 19 * u, height: 19 * u)) }
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path { Path(CGRect(x: x * u, y: y * u, width: w * u, height: h * u)) }
            let pieces: [(Color, [Path])] = [
                (Self.red, [circle(0, 0), box(9.5, 0, 9.5, 19)]),          // 왼쪽 위: 왼쪽만 둥글다
                (Self.coral, [circle(19, 0), box(19, 0, 9.5, 19)]),        // 오른쪽 위: 오른쪽만 둥글다
                (Self.purple, [circle(0, 19), box(9.5, 19, 9.5, 19)]),     // 왼쪽 가운데
                (Self.blue, [circle(19, 19)]),                             // 오른쪽 가운데: 원
                (Self.green, [circle(0, 38), box(9.5, 38, 9.5, 9.5)]),     // 왼쪽 아래: 오른쪽 위만 각진 물방울
            ]
            for (color, paths) in pieces {
                for path in paths { context.fill(path, with: .color(color)) }
            }
        }
        .frame(width: height * 38 / 57, height: height)
        .accessibilityLabel("피그마")
    }
}
