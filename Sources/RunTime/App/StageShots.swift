import AppKit

/// 효과 점검 (`--stage-shots <폴더> [러너] [트랙·날씨,...]`): 상태와 사용량 반응마다 무대 장면 몇 장과 메뉴바 프레임을
/// 이어 붙여 PNG로 남긴다. 트랙·날씨를 주면 그것을 써 본 무대로 찍는다.
@MainActor
enum StageShots {
    static func run(to directory: URL, character: RunnerCharacter, wearing: [Cosmetic] = []) throws {
        GameWallet.shared.preview = wearing.isEmpty ? nil : Set(wearing)
        defer { GameWallet.shared.preview = nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let displays: [(String, SpriteDisplay)] = [
            ("sleeping", .normal(.sleeping)), ("walking", .normal(.walking)), ("running", .normal(.running)),
            ("dashing", .normal(.dashing)), ("top", .normal(.rainbow)), ("tired", .tired), ("alert", .alert),
            ("running-tired", .straining(.running, critical: false)), ("top-critical", .straining(.rainbow, critical: true)),
        ]
        for (name, display) in displays {
            let stage = stageStrip(display: display, trick: nil, character: character, at: [1.4, 1.55, 1.7, 1.85])
            let frames = SpriteFrames.clip(for: display, character: character, theme: .auto, fps: 30).frames
            try write(stack([stage, menuBarStrip(frames), menuBarStrip(frames, dark: false)]),
                      to: directory.appendingPathComponent("\(name).png"))
        }
        let tricks: [Trick] = [.celebrate, .sparkle, .zoom, .milestone50, .milestone75]
        for trick in tricks {
            let times = (1...4).map { 0.6 + trick.duration * Double($0) / 5 }
            let stage = stageStrip(display: .normal(.running), trick: trick, character: character, at: times)
            let frames = SpriteFrames.clip(for: trick, character: character, theme: .auto, fps: 12)?.frames ?? []
            try write(stack([stage, menuBarStrip(frames)]), to: directory.appendingPathComponent("trick-\(trick.rawValue).png"))
        }
    }

    /// 무대를 1초 60장으로 돌리며 `times`(초)마다 한 장씩 찍는다. 앞의 0.6초는 속도가 붙는 시간이다.
    private static func stageStrip(display: SpriteDisplay, trick: Trick?, character: RunnerCharacter,
                                   at times: [Double]) -> CGImage? {
        let size = CGSize(width: 348, height: RunnerStage.height)
        let scale: CGFloat = 2
        guard let cg = context(size: size, scale: scale) else { return nil }
        let model = StageModel()
        let start = Date()
        var shots: [CGImage] = []
        var played = false
        var frame = 0
        while let last = times.last, Double(frame) / 60 <= last {
            let seconds = Double(frame) / 60
            if let trick, !played, seconds >= 0.6 {
                model.play(trick, at: start.addingTimeInterval(seconds))
                played = true
            }
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                model.draw(cg, size: size, date: start.addingTimeInterval(seconds), display: display,
                           character: character, theme: character.theme(.auto))
            }
            if times.contains(where: { abs($0 - seconds) <= 0.5 / 60 }), let image = cg.makeImage() { shots.append(image) }
            frame += 1
        }
        return row(shots, gap: 8)
    }

    /// 메뉴바 프레임을 메뉴바 색 위에 6배로 늘어놓는다.
    private static func menuBarStrip(_ frames: [NSImage], dark: Bool = true) -> CGImage? {
        let scale: CGFloat = 6
        let picks = stride(from: 0, to: frames.count, by: max(1, frames.count / 8)).prefix(8).map { frames[$0] }
        let cell = CGSize(width: Stage.size.width * scale, height: Stage.size.height * scale)
        guard !picks.isEmpty,
              let cg = context(size: CGSize(width: cell.width * CGFloat(picks.count), height: cell.height), scale: 1)
        else { return nil }
        cg.setFillColor(NSColor(hex: dark ? 0x2E2D33 : 0xE9E9EC).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: cell.width * CGFloat(picks.count), height: cell.height))
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            for (i, image) in picks.enumerated() {
                image.draw(in: CGRect(x: CGFloat(i) * cell.width, y: 0, width: cell.width, height: cell.height))
            }
        }
        return cg.makeImage()
    }

    /// y 아래 좌표 그림판. NSImage·NSColor가 그릴 수 있게 현재 그래픽 문맥으로 둔다.
    private static func context(size: CGSize, scale: CGFloat) -> CGContext? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        return cg
    }

    private static func row(_ images: [CGImage], gap: Int) -> CGImage? {
        guard let first = images.first else { return nil }
        let width = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
        guard let cg = CGContext(data: nil, width: width, height: first.height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var x = 0
        for image in images {
            cg.draw(image, in: CGRect(x: x, y: 0, width: image.width, height: image.height))
            x += image.width + gap
        }
        return cg.makeImage()
    }

    private static func stack(_ images: [CGImage?]) -> CGImage? {
        let images = images.compactMap { $0 }
        let width = images.map(\.width).max() ?? 0
        let height = images.reduce(0) { $0 + $1.height } + 8 * max(images.count - 1, 0)
        guard width > 0,
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.setFillColor(NSColor(hex: 0x1C1B20).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = height
        for image in images {
            y -= image.height
            cg.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
            y -= 8
        }
        return cg.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) throws {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        print("saved: \(url.path)")
    }
}
