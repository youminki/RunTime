import AppKit

/// 무대와 게임의 배경: 하늘, 먼 풍경, 땅, 날씨. 하늘은 시간대(`Sky`)를 따르고,
/// 상점에서 산 트랙이 풍경 모양과 땅 색을, 날씨가 하늘에 떠도는 입자를 정한다.
enum Backdrop {

    /// 달리는 곳. 색은 낮 기준이고, 밤이면 그 시간대 하늘의 풍경 색으로 섞어 어둡게 한다.
    struct Track {
        enum Horizon { case hills, dunes, sea, peaks, city, pines }
        enum Ground { case grass, pebbles, petals, plain }

        var far: NSColor
        var near: NSColor
        var ground: NSColor
        var edge: NSColor
        var horizon: Horizon
        /// 가까운 줄. nil이면 먼 풍경 바로 앞이 땅이다 (바다, 도시).
        var nearRow: Horizon?
        var deco: Ground
    }

    static func track(_ item: Cosmetic?) -> Track? {
        switch item {
        case .beachTrack:
            Track(far: NSColor(hex: 0x3E8FB8), near: NSColor(hex: 0xE9D3A2), ground: NSColor(hex: 0xE2C894),
                  edge: NSColor(hex: 0xF6E7C1), horizon: .sea, nearRow: nil, deco: .pebbles)
        case .desertTrack:
            Track(far: NSColor(hex: 0xD9A066), near: NSColor(hex: 0xC98A4E), ground: NSColor(hex: 0xB8763C),
                  edge: NSColor(hex: 0xEBC08A), horizon: .dunes, nearRow: .dunes, deco: .pebbles)
        case .snowTrack:
            Track(far: NSColor(hex: 0xB9CDE0), near: NSColor(hex: 0xDCE8F2), ground: NSColor(hex: 0xEEF4FA),
                  edge: NSColor(hex: 0xFFFFFF), horizon: .hills, nearRow: .hills, deco: .plain)
        case .pineTrack:
            Track(far: NSColor(hex: 0x557F6B), near: NSColor(hex: 0x2F5A45), ground: NSColor(hex: 0x3D5E3A),
                  edge: NSColor(hex: 0x7FA06A), horizon: .hills, nearRow: .pines, deco: .grass)
        case .autumnTrack:
            Track(far: NSColor(hex: 0xB7894F), near: NSColor(hex: 0xA4632F), ground: NSColor(hex: 0x7A5230),
                  edge: NSColor(hex: 0xE0A55A), horizon: .hills, nearRow: .hills, deco: .grass)
        case .blossomTrack:
            Track(far: NSColor(hex: 0xB79BC0), near: NSColor(hex: 0xE9AFC8), ground: NSColor(hex: 0x8C6E7E),
                  edge: NSColor(hex: 0xF7CFE0), horizon: .hills, nearRow: .hills, deco: .petals)
        case .peakTrack:
            Track(far: NSColor(hex: 0x8C9DB8), near: NSColor(hex: 0x5E7088), ground: NSColor(hex: 0x4C5B6E),
                  edge: NSColor(hex: 0xC9D4E3), horizon: .peaks, nearRow: .hills, deco: .pebbles)
        case .cityTrack:
            Track(far: NSColor(hex: 0x56607E), near: NSColor(hex: 0x3A4260), ground: NSColor(hex: 0x2A2F40),
                  edge: NSColor(hex: 0x8A93B0), horizon: .city, nearRow: nil, deco: .plain)
        default:
            nil
        }
    }

    /// 밤인 정도 (0 낮 ~ 1 깊은 밤). 트랙 색을 시간대 색으로 섞는 데 쓴다.
    static func nightness(_ sky: Sky) -> CGFloat { min(1, max(sky.stars, sky.orbLow ? 0.45 : 0)) }

    /// 배경 한 장. `scroll`은 지금까지 달린 거리, `speed`는 땅 점선을 늘이는 데 쓴다 (pt/초).
    static func draw(_ cg: CGContext, size: CGSize, sky: Sky, time: CGFloat, groundY: CGFloat, scroll: CGFloat,
                     speed: CGFloat, track item: Cosmetic?, weather: Cosmetic?) {
        drawSky(cg, size: size, sky: sky, time: time, groundY: groundY, scroll: scroll)
        let track = track(item)
        let night = nightness(sky) * 0.7
        func mix(_ own: NSColor?, _ base: NSColor) -> NSColor {
            guard let own else { return base }
            return own.blended(withFraction: night, of: base) ?? own
        }
        let far = mix(track?.far, sky.far), near = mix(track?.near, sky.near)
        let ground = mix(track?.ground, sky.ground), edge = mix(track?.edge, sky.edge)

        horizon(cg, track?.horizon ?? .hills, size: size, base: groundY - 20, scroll: scroll, parallax: 0.12, color: far,
                edge: edge, night: nightness(sky), time: time, far: true)
        if let row = track == nil ? .hills : track?.nearRow {
            horizon(cg, row, size: size, base: groundY - 7, scroll: scroll, parallax: 0.35, color: near, edge: edge,
                    night: nightness(sky), time: time, far: false)
        }
        drawGround(cg, size: size, groundY: groundY, scroll: scroll, speed: speed, ground: ground, edge: edge,
                   deco: track?.deco ?? .grass)
        drawWeather(cg, weather, size: size, groundY: groundY, time: time, scroll: scroll, night: nightness(sky))
    }

    // MARK: 하늘

    private static func drawSky(_ cg: CGContext, size: CGSize, sky: Sky, time: CGFloat, groundY: CGFloat, scroll: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        if let gradient = CGGradient(colorsSpace: space, colors: [sky.top.cgColor, sky.bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(0, groundY), options: [.drawsAfterEndLocation])
        }
        if sky.stars > 0 {
            for i in 0..<34 {
                let x = hash(i, 1) * size.width
                let y = hash(i, 2) * (groundY - 30) + 4
                let twinkle = 0.35 + 0.65 * abs(sin(time * (0.8 + hash(i, 3) * 1.6) + CGFloat(i)))
                let r = 0.5 + hash(i, 4) * 0.9
                cg.setFillColor(NSColor.white.withAlphaComponent(sky.stars * twinkle).cgColor)
                cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
        // 오른쪽 위는 단추 자리, 러너 머리 위는 사용률 고리 자리라 그 사이 아래쪽에 둔다
        let orb = CGPoint(size.width * 0.8, sky.orbLow ? groundY - 24 : min(50, groundY * 0.4))
        let r = min(8, groundY * 0.07)
        cg.setFillColor(sky.orb.withAlphaComponent(0.16).cgColor)
        cg.fillEllipse(in: CGRect(x: orb.x - r * 1.75, y: orb.y - r * 1.75, width: r * 3.5, height: r * 3.5))
        cg.setFillColor(sky.orb.cgColor)
        cg.fillEllipse(in: CGRect(x: orb.x - r, y: orb.y - r, width: r * 2, height: r * 2))
        if sky.moon {
            cg.setFillColor(sky.top.blended(withFraction: 0.25, of: sky.bottom)?.cgColor ?? sky.top.cgColor)
            cg.fillEllipse(in: CGRect(x: orb.x - r * 0.45, y: orb.y - r * 1.4, width: r * 2, height: r * 2))
        }
        if sky.clouds > 0 {
            for i in 0..<4 {
                let span = size.width + 90
                let raw = hash(i, 7) * span - scroll * 0.22 - time * 4
                let x = raw - floor(raw / span) * span - 45
                let y = 12 + hash(i, 8) * 14   // 러너 머리보다 위로 지나가게
                let s = 0.7 + hash(i, 9) * 0.6
                cg.setFillColor(NSColor.white.withAlphaComponent(0.6 * sky.clouds).cgColor)
                for (dx, dy, r) in [(0.0, 0.0, 7.0), (8.0, -3.0, 8.5), (17.0, 0.0, 6.5), (8.0, 2.5, 7.0)] as [(CGFloat, CGFloat, CGFloat)] {
                    cg.fillEllipse(in: CGRect(x: x + dx * s - r * s, y: y + dy * s - r * s, width: r * 2 * s, height: r * 2 * s))
                }
            }
        }
    }

    // MARK: 풍경

    /// 풍경 한 줄. 시차를 둬서 멀수록 느리게 흐른다.
    private static func horizon(_ cg: CGContext, _ kind: Track.Horizon, size: CGSize, base: CGFloat, scroll: CGFloat,
                                parallax: CGFloat, color: NSColor, edge: NSColor, night: CGFloat, time: CGFloat, far: Bool) {
        let shift = scroll * parallax
        cg.setFillColor(color.cgColor)
        switch kind {
        case .hills, .dunes:
            let dunes = kind == .dunes
            let amplitude: CGFloat = (far ? 13 : 7) * (dunes ? 0.8 : 1)
            let frequency: CGFloat = (far ? 0.022 : 0.045) * (dunes ? 0.55 : 1)
            let seed: CGFloat = far ? 1 : 2
            let path = CGMutablePath()
            path.move(to: CGPoint(0, size.height))
            var x: CGFloat = 0
            while x <= size.width + 4 {
                let w = x + shift
                // 모래 언덕은 잔물결 없이 길고 둥글게
                let wave = dunes ? 0.8 * sin(w * frequency + seed) + 0.2 * sin(w * frequency * 2.1 + seed)
                    : 0.55 * sin(w * frequency + seed) + 0.3 * sin(w * frequency * 2.3 + seed * 2) + 0.15 * sin(w * frequency * 5.1)
                path.addLine(to: CGPoint(x, base - amplitude * wave))
                x += 4
            }
            path.addLine(to: CGPoint(size.width, size.height))
            path.closeSubpath()
            cg.addPath(path)
            cg.fillPath()
        case .sea:
            let top = base + 4
            cg.fill(CGRect(x: 0, y: top, width: size.width, height: size.height - top))
            // 수평선 위 반짝이는 물결
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.22 + 0.1 * night).cgColor)
            cg.setLineWidth(1)
            cg.setLineCap(.round)
            for i in 0..<9 {
                let span = size.width + 40
                let raw = hash(i, 51) * span - shift * 0.6 + sin(time * 0.8 + CGFloat(i)) * 3
                let x = raw - floor(raw / span) * span - 20
                let y = top + 3 + hash(i, 52) * 9
                cg.move(to: CGPoint(x, y))
                cg.addLine(to: CGPoint(x + 6 + hash(i, 53) * 8, y))
            }
            cg.strokePath()
        case .peaks:
            let spacing: CGFloat = 46
            let first = Int(floor(shift / spacing)) - 1
            for k in first...(first + Int(size.width / spacing) + 3) {
                let x = CGFloat(k) * spacing - shift + hash(k & 1023, 61) * 14
                let height = 22 + hash(k & 1023, 62) * 20
                let half = 26 + hash(k & 1023, 63) * 10
                let peak = CGPoint(x, base + 6 - height)
                let path = CGMutablePath()
                path.move(to: CGPoint(x - half, base + 8))
                path.addLine(to: peak)
                path.addLine(to: CGPoint(x + half, base + 8))
                path.closeSubpath()
                cg.setFillColor(color.cgColor)
                cg.addPath(path)
                cg.fillPath()
                // 눈 덮인 봉우리
                let cap = 0.3
                let snow = CGMutablePath()
                snow.move(to: peak)
                snow.addLine(to: CGPoint(peak.x + half * cap, peak.y + height * cap))
                snow.addLine(to: CGPoint(peak.x, peak.y + height * cap * 0.75))
                snow.addLine(to: CGPoint(peak.x - half * cap, peak.y + height * cap))
                snow.closeSubpath()
                cg.setFillColor(NSColor.white.withAlphaComponent(0.85 - 0.35 * night).cgColor)
                cg.addPath(snow)
                cg.fillPath()
            }
            cg.fill(CGRect(x: 0, y: base + 8, width: size.width, height: size.height - base - 8))
        case .city:
            let spacing: CGFloat = 19
            let first = Int(floor(shift / spacing)) - 1
            var windows: [CGRect] = []
            for k in first...(first + Int(size.width / spacing) + 2) {
                let i = k & 1023
                let x = CGFloat(k) * spacing - shift
                let width = spacing - 2 + hash(i, 71) * 4
                let height = 16 + hash(i, 72) * 30
                let rect = CGRect(x: x, y: base + 8 - height, width: width, height: height + size.height)
                cg.setFillColor(color.cgColor)
                cg.fill(rect)
                for row in 0..<Int(height / 6) {
                    for column in 0..<Int(width / 5) where hash(i * 31 + row * 7 + column, 73) > 0.55 {
                        windows.append(CGRect(x: x + 2 + CGFloat(column) * 5, y: rect.minY + 3 + CGFloat(row) * 6,
                                              width: 2, height: 2.4))
                    }
                }
            }
            // 창문은 밤에 켜진다 (낮에도 몇 개는 희미하게). 한 번에 칠한다
            cg.setFillColor(NSColor(hex: 0xFFD27A).withAlphaComponent(0.12 + 0.75 * night).cgColor)
            cg.fill(windows)
        case .pines:
            let spacing: CGFloat = 23
            let first = Int(floor(shift / spacing)) - 1
            for k in first...(first + Int(size.width / spacing) + 3) {
                let i = k & 1023
                let x = CGFloat(k) * spacing - shift + hash(i, 81) * 10
                let height = 14 + hash(i, 82) * 12
                let foot = base + 9
                let path = CGMutablePath()
                // 두 겹 삼각형 침엽수
                for (top, bottom, half) in [(foot - height, foot - height * 0.35, height * 0.3),
                                            (foot - height * 0.65, foot, height * 0.38)] {
                    path.move(to: CGPoint(x, top))
                    path.addLine(to: CGPoint(x + half, bottom))
                    path.addLine(to: CGPoint(x - half, bottom))
                    path.closeSubpath()
                }
                cg.addPath(path)
                cg.fillPath()
            }
            cg.fill(CGRect(x: 0, y: base + 8, width: size.width, height: size.height - base - 8))
        }
    }

    // MARK: 땅

    private static func drawGround(_ cg: CGContext, size: CGSize, groundY: CGFloat, scroll: CGFloat, speed: CGFloat,
                                   ground: NSColor, edge: NSColor, deco: Track.Ground) {
        cg.setFillColor(ground.cgColor)
        cg.fill(CGRect(x: 0, y: groundY, width: size.width, height: size.height - groundY))
        cg.setFillColor(edge.withAlphaComponent(0.9).cgColor)
        cg.fill(CGRect(x: 0, y: groundY - 1, width: size.width, height: 2))
        // 빠를수록 땅 점선이 늘어져 흐릿하게 번진다 (모션 블러)
        let dash: CGFloat = 26
        let blur = min(speed / 140, 1)
        let offset = scroll.truncatingRemainder(dividingBy: dash)
        cg.setFillColor(edge.withAlphaComponent(0.35 - 0.12 * blur).cgColor)
        var x = -offset
        while x < size.width {
            cg.addPath(CGPath(roundedRect: CGRect(x: x, y: groundY + 5, width: 10 + 12 * blur, height: 2), cornerWidth: 1,
                              cornerHeight: 1, transform: nil))
            x += dash
        }
        cg.fillPath()
        switch deco {
        case .grass:
            let gap: CGFloat = 47
            cg.setStrokeColor(edge.withAlphaComponent(0.7).cgColor)
            cg.setLineWidth(1.2)
            cg.setLineCap(.round)
            x = -scroll.truncatingRemainder(dividingBy: gap) + 12
            while x < size.width + 10 {
                for dx in [-2.5, 0, 2.5] as [CGFloat] {
                    cg.move(to: CGPoint(x + dx * 0.4, groundY - 0.5))
                    cg.addLine(to: CGPoint(x + dx, groundY - 4 + abs(dx) * 0.4))
                }
                x += gap
            }
            cg.strokePath()
        case .pebbles, .petals:
            let gap: CGFloat = 31
            let first = Int(floor(scroll / gap)) - 1
            let petal = NSColor(hex: 0xF7B6CF)
            for k in first...(first + Int(size.width / gap) + 2) {
                let i = k & 1023
                let px = CGFloat(k) * gap - scroll + hash(i, 91) * 20
                let py = groundY + 2 + hash(i, 92) * (size.height - groundY - 4)
                let r = 0.8 + hash(i, 93) * 1.1
                cg.setFillColor((deco == .petals ? petal.withAlphaComponent(0.8) : edge.withAlphaComponent(0.45)).cgColor)
                cg.fillEllipse(in: CGRect(x: px - r * 1.3, y: py - r * 0.7, width: r * 2.6, height: r * 1.4))
            }
        case .plain:
            break
        }
    }

    // MARK: 날씨

    /// 하늘에 떠도는 입자. 러너 뒤에 그려 러너를 가리지 않는다.
    static func drawWeather(_ cg: CGContext, _ item: Cosmetic?, size: CGSize, groundY: CGFloat, time: CGFloat,
                            scroll: CGFloat, night: CGFloat) {
        guard let item else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        // 화면 폭을 넘어 감기는 x. 달리는 만큼 뒤로 흐른다
        func wrap(_ raw: CGFloat, margin: CGFloat = 20) -> CGFloat {
            let span = size.width + margin * 2
            return raw - floor(raw / span) * span - margin
        }
        switch item {
        case .drizzleWeather:
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.32).cgColor)
            cg.setLineWidth(0.8)
            cg.setLineCap(.round)
            for i in 0..<42 {
                let fall = (hash(i, 101) + time * (1.4 + hash(i, 102) * 0.4)).truncatingRemainder(dividingBy: 1)
                let x = wrap(hash(i, 103) * size.width - scroll * 0.6 - fall * 18)
                let y = fall * (groundY + 6) - 6
                cg.move(to: CGPoint(x, y))
                cg.addLine(to: CGPoint(x - 2.2, y + 6))
            }
            cg.strokePath()
        case .snowWeather:
            for i in 0..<36 {
                let fall = (hash(i, 111) + time * (0.12 + hash(i, 112) * 0.08)).truncatingRemainder(dividingBy: 1)
                let x = wrap(hash(i, 113) * size.width - scroll * 0.3 + sin(time * 0.9 + CGFloat(i)) * 6)
                let y = fall * (groundY + 4) - 4
                let r = 0.8 + hash(i, 114) * 1.1
                cg.setFillColor(NSColor.white.withAlphaComponent(0.55 + 0.35 * hash(i, 115)).cgColor)
                cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        case .petalWeather, .leafWeather:
            let leaves = item == .leafWeather
            let colors = leaves ? [NSColor(hex: 0xE0702F), NSColor(hex: 0xC9472B), NSColor(hex: 0xE8A93A)]
                : [NSColor(hex: 0xF7B6CF), NSColor(hex: 0xFBD3E2)]
            for i in 0..<(leaves ? 14 : 20) {
                let fall = (hash(i, 121) + time * (0.1 + hash(i, 122) * 0.06)).truncatingRemainder(dividingBy: 1)
                let x = wrap(hash(i, 123) * size.width - scroll * 0.45 - fall * 40 + sin(time * 1.3 + CGFloat(i)) * 8)
                let y = fall * (groundY + 4) - 4
                let spin = time * (1 + hash(i, 124)) + CGFloat(i)
                let w: CGFloat = leaves ? 3.4 : 2.6, h: CGFloat = leaves ? 2 : 1.6
                cg.saveGState()
                cg.translateBy(x: x, y: y)
                cg.rotate(by: spin)
                // 뒤집히며 떨어지는 느낌: 폭이 주기적으로 줄었다 는다
                cg.scaleBy(x: max(0.25, abs(cos(spin * 0.7))), y: 1)
                cg.setFillColor(colors[i % colors.count].withAlphaComponent(0.9).cgColor)
                cg.fillEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                cg.restoreGState()
            }
        case .fireflyWeather:
            let glow = NSColor(hex: 0xD8F27A)
            let strength = 0.35 + 0.65 * night
            for i in 0..<14 {
                let x = wrap(hash(i, 131) * size.width - scroll * 0.25 + sin(time * 0.5 + CGFloat(i) * 1.7) * 14)
                let y = groundY * (0.45 + 0.45 * hash(i, 132)) + cos(time * 0.7 + CGFloat(i)) * 6
                let blink = max(0, sin(time * (1.2 + hash(i, 133)) + CGFloat(i) * 2.1))
                let a = strength * blink
                guard a > 0.02 else { continue }
                cg.setFillColor(glow.withAlphaComponent(0.18 * a).cgColor)
                cg.fillEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                cg.setFillColor(glow.withAlphaComponent(a).cgColor)
                cg.fillEllipse(in: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
            }
        case .fogWeather:
            for i in 0..<3 {
                let y = groundY - 10 - CGFloat(i) * 12
                // 띠는 화면 폭에 고정하고 짙기만 천천히 출렁인다 (옆으로 밀면 끝이 드러난다)
                let rect = CGRect(x: 0, y: y - 7, width: size.width, height: 14)
                let alpha = (0.16 - CGFloat(i) * 0.03) * (0.7 + 0.3 * sin(time * 0.3 + CGFloat(i) * 2))
                let colors = [NSColor.white.withAlphaComponent(0).cgColor,
                              NSColor.white.withAlphaComponent(alpha).cgColor,
                              NSColor.white.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                             locations: [0, 0.5, 1]) {
                    cg.saveGState()
                    cg.clip(to: rect)
                    cg.drawLinearGradient(gradient, start: CGPoint(0, rect.minY), end: CGPoint(0, rect.maxY), options: [])
                    cg.restoreGState()
                }
            }
        default:
            break
        }
    }

    static func hash(_ i: Int, _ salt: Int) -> CGFloat { StageModel.hash(i, salt) }
}
