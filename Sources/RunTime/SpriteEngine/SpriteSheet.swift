import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 모든 러너의 대표 장면을 크게 한 장에 그린다 (디자인 점검용, `--sprite-sheet <폴더>`).
enum SpriteSheet {

    static func write(to directory: URL, runners: [Runner] = Runner.allCases) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rigs = runners.map(\.rig)
        try render(theme: .auto, rigs: rigs, background: NSColor(hex: 0x2B2A30))
            .write(to: directory.appendingPathComponent("sheet-mono.png"))
        try render(theme: .natural, rigs: rigs, background: NSColor(hex: 0x8FA3B8))
            .write(to: directory.appendingPathComponent("sheet-natural.png"))
        try renderTricks(runner: runners.first ?? .cat, background: NSColor(hex: 0x2B2A30))
            .write(to: directory.appendingPathComponent("sheet-tricks.png"))
        // 메뉴바 실제 크기 (레티나 2배 픽셀)
        try renderActual(runners: runners, dark: true).write(to: directory.appendingPathComponent("actual-dark.png"))
        try renderActual(runners: runners, dark: false).write(to: directory.appendingPathComponent("actual-light.png"))
    }

    private static func renderActual(runners: [Runner], dark: Bool) -> Data {
        let scale: CGFloat = 2
        let cell = CGSize(width: (Stage.size.width + 6) * scale, height: (Stage.size.height + 4) * scale)
        let themes: [(SpriteTheme, CGFloat)] = [(.auto, 0.25), (.auto, 0.75), (.natural, 0.25), (.orange, 0.5)]
        let size = CGSize(width: cell.width * CGFloat(themes.count + 1), height: cell.height * CGFloat(runners.count))
        return png(size: size, background: NSColor(hex: dark ? 0x2E2D33 : 0xE9E9EC),
                   appearance: NSAppearance(named: dark ? .darkAqua : .aqua)) { cg in
            for (row, runner) in runners.enumerated() {
                let frames = themes.map { ($0.0, SpriteDisplay.normal(.running).motion(at: $0.1)) }
                    + [(SpriteTheme.auto, SpriteDisplay.normal(.sleeping).motion(at: 0.3))]
                for (column, item) in frames.enumerated() {
                    cg.saveGState()
                    cg.translateBy(x: CGFloat(column) * cell.width + 3 * scale, y: CGFloat(row) * cell.height + 2 * scale)
                    cg.scaleBy(x: scale, y: scale)
                    SpriteFrames.render(cg, rig: runner.rig, frame: item.1, theme: item.0, themePhase: 0,
                                        alarm: false) { _, _, _, _ in }
                    cg.restoreGState()
                }
            }
        }
    }

    private static let columns: [(String, MotionFrame)] = {
        var list: [(String, MotionFrame)] = []
        for i in 0..<6 {
            let phase = CGFloat(i) / 6
            list.append(("run \(i)", SpriteDisplay.normal(.running).motion(at: phase)))
        }
        list.append(("walk", SpriteDisplay.normal(.walking).motion(at: 0.2)))
        list.append(("walk", SpriteDisplay.normal(.walking).motion(at: 0.45)))
        list.append(("stand", MotionFrame(pose: CharacterPose(activity: .stand))))
        var wave = CharacterPose(activity: .stand)
        wave.wave = 0.4
        list.append(("wave", MotionFrame(pose: wave)))
        list.append(("sit", SpriteDisplay.tired.motion(at: 0.2)))
        list.append(("sleep", SpriteDisplay.normal(.sleeping).motion(at: 0.2)))
        return list
    }()

    private static func render(theme: SpriteTheme, rigs: [CharacterRig], background: NSColor) -> Data {
        let scale: CGFloat = 5
        let cell = CGSize(width: Stage.size.width * scale, height: Stage.size.height * scale)
        let size = CGSize(width: cell.width * CGFloat(columns.count), height: cell.height * CGFloat(rigs.count))
        return png(size: size, background: background) { cg in
            for (row, rig) in rigs.enumerated() {
                for (column, item) in columns.enumerated() {
                    cg.saveGState()
                    cg.translateBy(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height)
                    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
                    cg.stroke(CGRect(origin: .zero, size: cell))
                    cg.scaleBy(x: scale, y: scale)
                    SpriteFrames.render(cg, rig: rig, frame: item.1, theme: theme, themePhase: 0,
                                        alarm: false) { _, _, _, _ in }
                    cg.restoreGState()
                }
            }
        }
    }

    private static func renderTricks(runner: Runner, background: NSColor) -> Data {
        let scale: CGFloat = 4
        let steps = 8
        let cell = CGSize(width: Stage.size.width * scale, height: Stage.size.height * scale)
        let tricks = Trick.allCases
        let size = CGSize(width: cell.width * CGFloat(steps), height: cell.height * CGFloat(tricks.count))
        return png(size: size, background: background) { cg in
            for (row, trick) in tricks.enumerated() {
                for column in 0..<steps {
                    cg.saveGState()
                    cg.translateBy(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height)
                    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
                    cg.stroke(CGRect(origin: .zero, size: cell))
                    cg.scaleBy(x: scale, y: scale)
                    let t = CGFloat(column) / CGFloat(steps - 1)
                    SpriteFrames.render(cg, rig: runner.rig, frame: trick.frame(at: t), theme: .auto, themePhase: t,
                                        alarm: false) { _, _, _, _ in }
                    cg.restoreGState()
                }
            }
        }
    }

    private static func png(size: CGSize, background: NSColor,
                            appearance: NSAppearance? = NSAppearance(named: .darkAqua),
                            draw: (CGContext) -> Void) -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.setFillColor(background.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)   // y 아래 좌표
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { draw(cg) }
        } else {
            draw(cg)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// README 첫 화면 GIF: 러너 몇 마리가 차례로 달린다 (`--hero-gif <파일>`).
    static func writeHeroGIF(to url: URL) throws {
        let cast: [(Runner, SpriteDisplay)] = [(.cat, .normal(.rainbow)), (.fox, .normal(.dashing)),
                                               (.unicorn, .normal(.rainbow)), (.penguin, .normal(.running)),
                                               (.dino, .normal(.dashing)), (.ghost, .normal(.running))]
        let scale: CGFloat = 6
        let pad: CGFloat = 14
        let size = CGSize(width: Stage.size.width * scale + pad * 2, height: Stage.size.height * scale + pad * 2)
        let delay = 0.04
        var frames: [CGImage] = []
        for (runner, display) in cast {
            let count = Int((display.cycle * 2 / delay).rounded())
            for i in 0..<count {
                let phase = CGFloat(i) / CGFloat(count) * 2
                let data = png(size: size, background: NSColor(hex: 0x1C1B20)) { cg in
                    cg.translateBy(x: pad, y: pad)
                    cg.scaleBy(x: scale, y: scale)
                    let local = phase - floor(phase)
                    SpriteFrames.render(cg, rig: runner.rig, frame: display.motion(at: local), theme: .natural,
                                        themePhase: 0, alarm: false) { cg, scene, _, front in
                        display.drawLoopEffects(in: cg, scene: scene, phase: local, tint: .white, front: front)
                    }
                }
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    frames.append(image)
                }
            }
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                                frames.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, frameProperties) }
        CGImageDestinationFinalize(destination)
    }
}
