import AppKit

/// 러너 주변 효과. 설계 좌표(36×22)에 그리며 메뉴바 프레임과 팝오버 무대가 함께 쓴다.
/// `phase`는 0~1 주기라 프레임을 몇 장으로 나누든 끊김 없이 이어진다.
enum SpriteEffects {

    static let rainbow: [NSColor] = [
        NSColor(hex: 0xFF4D4D), NSColor(hex: 0xFF9E3D), NSColor(hex: 0xFFE14D),
        NSColor(hex: 0x5BD86B), NSColor(hex: 0x4DA3FF), NSColor(hex: 0xA77BFF),
    ]

    /// 전력 질주 때 등 뒤로 끌리는 빛 꼬리. 러너 쪽이 굵고 밝으며 멀어질수록 가늘어지고 사라진다.
    static func lightTrail(_ cg: CGContext, from x0: CGFloat, to x1: CGFloat, centerY: CGFloat, width: CGFloat,
                           phase: CGFloat, color: NSColor) {
        let length = x1 - x0
        guard length > 0 else { return }
        func edge(_ x: CGFloat, _ side: CGFloat, _ thickness: CGFloat) -> CGPoint {
            let distance = x1 - x
            let taper = pow(max(0, 1 - distance / length), 0.7)
            let wave = sin(tau * phase - distance * 0.32) * 0.45 * min(distance / 5, 1)
            return CGPoint(x, centerY + wave + side * thickness / 2 * taper)
        }
        func ribbon(_ thickness: CGFloat, alpha: CGFloat) {
            let xs = stride(from: x1, through: x0, by: -0.5).map { $0 }
            let path = CGMutablePath()
            path.addLines(between: xs.map { edge($0, -1, thickness) } + xs.reversed().map { edge($0, 1, thickness) })
            path.closeSubpath()
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [color.withAlphaComponent(0).cgColor,
                                                  color.withAlphaComponent(alpha).cgColor] as CFArray,
                                         locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: CGPoint(x0, 0), end: CGPoint(x1, 0), options: [])
            }
            cg.restoreGState()
        }
        ribbon(width, alpha: 0.4)
        ribbon(width * 0.32, alpha: 0.85)
    }

    /// 몸 높이 언저리를 뒤로 스치는 공기 줄. 앞머리가 굵고 꼬리 쪽으로 가늘어진다.
    static func airStreaks(_ cg: CGContext, phase: CGFloat, maxX: CGFloat, band: ClosedRange<CGFloat>,
                           color: NSColor, count: Int = 3, length: CGFloat = 7) {
        let seeds: [(y: CGFloat, length: CGFloat, offset: CGFloat)] = [
            (0.2, 1, 0), (0.75, 0.8, 0.45), (0.45, 1.25, 0.7), (0.95, 0.7, 0.2),
        ]
        for seed in seeds.prefix(count) {
            let t = (phase + seed.offset).truncatingRemainder(dividingBy: 1)
            let len = length * seed.length
            let head = maxX - t * (maxX + len + 2)
            let y = band.lowerBound + (band.upperBound - band.lowerBound) * seed.y
            let alpha = 0.6 * sin(.pi * t)
            let half: CGFloat = 0.36
            let path = CGMutablePath()
            path.move(to: CGPoint(head + half, y - half))
            path.addLine(to: CGPoint(head + len, y))
            path.addLine(to: CGPoint(head + half, y + half))
            path.addArc(center: CGPoint(head + half, y), radius: half, startAngle: .pi / 2, endAngle: -.pi / 2,
                        clockwise: false)
            path.closeSubpath()
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [color.withAlphaComponent(alpha).cgColor,
                                                  color.withAlphaComponent(0).cgColor] as CFArray,
                                         locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: CGPoint(head, 0), end: CGPoint(head + len, 0), options: [])
            }
            cg.restoreGState()
        }
    }

    /// 발이 땅을 찰 때(한 주기에 두 번) 일어나는 흙먼지. 뒤로 밀리며 퍼지고 옅어진다.
    static func footDust(_ cg: CGContext, at origin: CGPoint, phase: CGFloat, color: NSColor) {
        for contact in [0, 0.5] as [CGFloat] {
            let age = (phase - contact + 1).truncatingRemainder(dividingBy: 1)
            guard age < 0.45 else { continue }
            let k = age / 0.45
            for i in 0..<2 {
                let lag = CGFloat(i)
                let c = origin + CGPoint(-k * 5 - lag * 1.3, -k * 1.5 - lag * 0.3)
                let r = max(0.1, 0.45 + k * 1.05 - lag * 0.18)
                cg.setFillColor(color.withAlphaComponent(0.36 * pow(1 - k, 1.5)).cgColor)
                cg.fillEllipse(in: CGRect(x: c.x - r * 1.3, y: c.y - r, width: r * 2.6, height: r * 2))
            }
        }
    }

    /// 헐떡이는 입김. 한 주기에 두 번 내쉰다.
    static func breath(_ cg: CGContext, at mouth: CGPoint, phase: CGFloat, color: NSColor) {
        for exhale in [0, 0.5] as [CGFloat] {
            let age = (phase - exhale + 1).truncatingRemainder(dividingBy: 1)
            guard age < 0.42 else { continue }
            let k = age / 0.42
            let ease = 1 - pow(1 - k, 2)
            for i in 0..<3 {
                let c = mouth + CGPoint(0.5 + ease * 2.4 + CGFloat(i) * 0.55, -ease * 1.1 - CGFloat(i % 2) * 0.35)
                let r = 0.3 + ease * 0.75 - CGFloat(i) * 0.08
                cg.setFillColor(color.withAlphaComponent(0.42 * (1 - k)).cgColor)
                cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        }
    }

    /// 한도 경고 점. 가운데 점은 그대로 두고 둘레만 한 주기에 한 번 퍼진다.
    static func ping(_ cg: CGContext, at c: CGPoint, phase: CGFloat, color: NSColor) {
        let k = phase - floor(phase)
        let ring = 1.1 + k * 1.3
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setStrokeColor(color.withAlphaComponent(0.75 * pow(1 - k, 1.4)).cgColor)
        cg.setLineWidth(0.15 + 0.4 * (1 - k))
        cg.strokeEllipse(in: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2))
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: CGRect(x: c.x - 1.1, y: c.y - 1.1, width: 2.2, height: 2.2))
    }

    /// 퍼지는 고리와 바깥으로 튀는 점. `t`는 0~1.
    static func burst(_ cg: CGContext, at c: CGPoint, radius: CGFloat, t: CGFloat, color: NSColor, accent: NSColor) {
        guard t > 0 && t < 1 else { return }
        let ring = 1 - pow(1 - min(t / 0.55, 1), 3)
        if t < 0.55 {
            let r = radius * (0.25 + 0.75 * ring)
            cg.setStrokeColor(color.withAlphaComponent(0.85 * (1 - ring)).cgColor)
            cg.setLineWidth(max(0.05, 1.1 * (1 - ring)))
            cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        let fly = 1 - pow(1 - min(max((t - 0.08) / 0.8, 0), 1), 3)
        for i in 0..<8 {
            let angle = CGFloat(i) / 8 * tau + 0.2
            let p = c + CGPoint.polar(angle, radius * (0.55 + 0.75 * fly))
            let r = 0.6 * (1 - fly) * (i % 2 == 0 ? 1 : 0.7)
            guard r > 0.04 else { continue }
            cg.setFillColor((i % 2 == 0 ? color : accent).cgColor)
            cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    /// 사용률 고리. 12시부터 시계 방향으로 `from`에서 `to`까지 채운다 (0~1).
    static func progressRing(_ cg: CGContext, at c: CGPoint, radius r: CGFloat, from: CGFloat, to: CGFloat,
                             fill: CGFloat, alpha: CGFloat, color: NSColor) {
        guard alpha > 0.01 else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setLineCap(.round)
        cg.setLineWidth(r * 0.3)
        cg.setStrokeColor(color.withAlphaComponent(0.25 * alpha).cgColor)
        cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let end = from + (to - from) * fill
        guard end > 0.001 else { return }
        let steps = max(2, Int(end * 48))
        let points = (0...steps).map { i -> CGPoint in
            let a = -.pi / 2 + tau * end * CGFloat(i) / CGFloat(steps)
            return c + CGPoint.polar(a, r)
        }
        cg.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        cg.addLines(between: points)
        cg.strokePath()
    }

    /// 네 갈래 반짝이.
    static func sparkle(_ cg: CGContext, at c: CGPoint, radius r: CGFloat, color: NSColor) {
        guard r > 0.05 else { return }
        let path = CGMutablePath()
        let inner = r * 0.28
        for k in 0..<8 {
            let angle = CGFloat(k) * .pi / 4 - .pi / 2
            let p = c + CGPoint.polar(angle, k % 2 == 0 ? r : inner)
            k == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        cg.setFillColor(color.cgColor)
        cg.addPath(path)
        cg.fillPath()
    }

    /// 머리 위로 천천히 떠오르는 z 두 개.
    static func zzz(_ cg: CGContext, from origin: CGPoint, phase: CGFloat, color: NSColor) {
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for k in 0..<2 {
            let t = (phase + CGFloat(k) / 2).truncatingRemainder(dividingBy: 1)
            let rise = 1 - pow(1 - t, 2)
            let size = 1.3 + t * 1.3
            let c = origin + CGPoint(rise * 3 + sin(t * .pi) * 0.7, -rise * 7)
            let alpha = 0.85 * pow(sin(.pi * t), 1.5)
            cg.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
            cg.setLineWidth(0.5)
            cg.move(to: c + CGPoint(-size / 2, -size / 2))
            cg.addLine(to: c + CGPoint(size / 2, -size / 2))
            cg.addLine(to: c + CGPoint(-size / 2, size / 2))
            cg.addLine(to: c + CGPoint(size / 2, size / 2))
            cg.strokePath()
        }
    }

    static func drop(_ cg: CGContext, at c: CGPoint, size: CGFloat, color: NSColor) {
        let path = CGMutablePath()
        path.move(to: c + CGPoint(0, -size * 1.3))
        path.addQuadCurve(to: c + CGPoint(size * 0.75, size * 0.2), control: c + CGPoint(size * 0.7, -size * 0.4))
        path.addArc(center: c + CGPoint(0, size * 0.2), radius: size * 0.75, startAngle: 0, endAngle: .pi,
                    clockwise: false)
        path.addQuadCurve(to: c + CGPoint(0, -size * 1.3), control: c + CGPoint(-size * 0.7, -size * 0.4))
        cg.setFillColor(color.cgColor)
        cg.addPath(path)
        cg.fillPath()
    }

    /// 느낌표.
    static func exclaim(_ cg: CGContext, at c: CGPoint, height h: CGFloat, color: NSColor) {
        cg.setFillColor(color.cgColor)
        let w = h * 0.3
        let bar = CGPath(roundedRect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h * 0.62),
                         cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
        cg.addPath(bar)
        cg.fillPath()
        cg.fillEllipse(in: CGRect(x: c.x - w * 0.55, y: c.y + h * 0.27, width: w * 1.1, height: w * 1.1))
    }

    static func heart(_ cg: CGContext, at c: CGPoint, size s: CGFloat, color: NSColor) {
        let path = CGMutablePath()
        path.move(to: c + CGPoint(0, s * 0.9))
        path.addCurve(to: c + CGPoint(-s, -s * 0.15), control1: c + CGPoint(-s * 0.5, s * 0.55),
                      control2: c + CGPoint(-s, s * 0.25))
        path.addArc(center: c + CGPoint(-s * 0.5, -s * 0.2), radius: s * 0.5, startAngle: .pi, endAngle: 0,
                    clockwise: false)
        path.addArc(center: c + CGPoint(s * 0.5, -s * 0.2), radius: s * 0.5, startAngle: .pi, endAngle: 0,
                    clockwise: false)
        path.addCurve(to: c + CGPoint(0, s * 0.9), control1: c + CGPoint(s, s * 0.25),
                      control2: c + CGPoint(s * 0.5, s * 0.55))
        cg.setFillColor(color.cgColor)
        cg.addPath(path)
        cg.fillPath()
    }

    /// 8분음표.
    static func note(_ cg: CGContext, at c: CGPoint, size s: CGFloat, color: NSColor) {
        cg.setFillColor(color.cgColor)
        cg.setStrokeColor(color.cgColor)
        cg.fillEllipse(in: CGRect(x: c.x - s * 0.55, y: c.y + s * 0.35, width: s * 0.75, height: s * 0.55))
        cg.setLineWidth(s * 0.16)
        cg.move(to: c + CGPoint(s * 0.13, s * 0.6))
        cg.addLine(to: c + CGPoint(s * 0.13, -s * 0.8))
        cg.addQuadCurve(to: c + CGPoint(s * 0.6, -s * 0.1), control: c + CGPoint(s * 0.65, -s * 0.55))
        cg.strokePath()
    }
}
