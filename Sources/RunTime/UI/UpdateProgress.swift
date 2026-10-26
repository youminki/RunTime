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

/// 업데이트 뒤 러너 아래에 띄우는 패치노트 말풍선. 꼬리가 위의 러너를 가리킨다. 닫을 때까지 남는다.
struct PatchNotesBubble: View {
    let notes: PatchNotes
    /// 꼬리를 둘 가로 위치 (말풍선 폭에 대한 비율). 무대의 러너 자리와 맞춘다.
    var tailAnchor: CGFloat = StageModel.runnerAnchor
    let dismiss: () -> Void

    private static let fill = Color(white: 0.97)
    private static let ink = Color(nsColor: NSColor(hex: 0x1F1C26))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("업데이트했어요").font(.system(size: 12, weight: .bold))
                Text("이번에 바뀐 것").font(.system(size: 10.5)).foregroundStyle(Self.ink.opacity(0.5))
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Self.ink.opacity(0.45))
                .accessibilityLabel("패치노트 닫기")
            }
            ForEach(notes.sections, id: \.kind) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Label(section.kind.title, systemImage: section.kind.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint(section.kind))
                    ForEach(section.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Circle().fill(Self.ink.opacity(0.35)).frame(width: 3, height: 3).offset(y: -2)
                            Text(item).font(.system(size: 11.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if notes.hiddenCount > 0 {
                Text("외 \(notes.hiddenCount)개 더 바뀌었어요").font(.system(size: 10.5)).foregroundStyle(Self.ink.opacity(0.5))
            }
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.fill))
        .overlay(alignment: .topLeading) {
            GeometryReader { geo in
                UpTail().fill(Self.fill).frame(width: 12, height: 6)
                    .position(x: geo.size.width * tailAnchor, y: -3)
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
    }

    /// 말풍선은 어느 모드에서나 밝아서, 밝은 바탕에서 읽히는 진한 색을 고정으로 쓴다.
    private func tint(_ kind: PatchNotes.Kind) -> Color {
        switch kind {
        case .added: return Color(nsColor: NSColor(hex: 0x0063CC))
        case .fixed: return Color(nsColor: NSColor(hex: 0x1B7F3B))
        case .polished: return Color(nsColor: NSColor(hex: 0xB35500))
        }
    }

    private struct UpTail: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}
