import SwiftUI

/// 업데이트 진행 막대. 채워진 쪽에 빛이 지나가 멈추지 않고 일하는 중인 것이 보인다.
struct UpdateGauge: View {
    let fraction: Double
    var track: Color = Color.white.opacity(0.16)

    private static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.height, geo.size.width * min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(LinearGradient(colors: [Palette.blue, Palette.teal], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        if !Self.reduceMotion {
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                                LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 36)
                                    .offset(x: -36 + (width + 36) * t)
                            }
                        }
                    }
                    .clipShape(Capsule())
                    .animation(.easeOut(duration: 0.45), value: fraction)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("업데이트 진행")
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

/// 무대 아래에 뜨는 설치 진행 판. 단계, 진행률, 남은 시간을 한 줄로 보인다.
struct UpdateProgressPanel: View {
    let progress: AppUpdater.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Palette.teal)
                Text(progress.step).lineLimit(1)
                Spacer(minLength: 4)
                if let remaining = progress.remaining {
                    Text(Self.remainingText(remaining)).foregroundStyle(.white.opacity(0.65))
                }
                Text("\(Int(progress.fraction * 100))%").fontWeight(.bold).monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            UpdateGauge(fraction: progress.fraction).frame(height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.58)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .padding(8)
        // 무대 쓰다듬기 입력을 가리지 않는다
        .allowsHitTesting(false)
    }

    /// 5초 단위로 반올림해 숫자가 매번 흔들리지 않게 한다.
    static func remainingText(_ seconds: TimeInterval) -> String {
        guard seconds >= 8 else { return "곧 끝나요" }
        let rounded = Int((seconds / 5).rounded()) * 5
        let minutes = rounded / 60, rest = rounded % 60
        if minutes == 0 { return "약 \(rest)초 남음" }
        return rest == 0 ? "약 \(minutes)분 남음" : "약 \(minutes)분 \(rest)초 남음"
    }
}

/// 러너가 받을 새 버전을 알리는 말풍선. 누르면 바로 업데이트한다.
struct UpdateBubble: View {
    let text: String
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.blue)
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: NSColor(hex: 0x1F1C26)))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: hover.on ? 1 : 0.97)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.blue.opacity(hover.on ? 0.9 : 0.5), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                BubbleTail().fill(Color(white: hover.on ? 1 : 0.97)).frame(width: 7, height: 5).offset(x: 9, y: 4.5)
            }
            .scaleEffect(hover.on ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: hover.on)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .accessibilityLabel(text)
    }

    private struct BubbleTail: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}
