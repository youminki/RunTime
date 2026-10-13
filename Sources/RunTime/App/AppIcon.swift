import AppKit

/// 앱 아이콘 (`--app-icon <파일.png>`): 무대와 같은 배경·러너 그림으로 1024px 아이콘을 그린다.
/// scripts/make-icon.sh가 크기별로 줄여 assets/AppIcon.icns를 만든다.
@MainActor
enum AppIcon {
    static func write(to url: URL) throws {
        let side = 1024
        guard let cg = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 무대 그림은 y가 아래로 자라는 좌표라 뒤집는다
        cg.translateBy(x: 0, y: CGFloat(side))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { draw(cg) }
        guard let image = cg.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }

    /// macOS 아이콘 격자: 1024 안에 824 둥근 사각형, 아래로 옅은 그림자.
    private static func draw(_ cg: CGContext) {
        let tile = CGRect(x: 100, y: 92, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        cg.addPath(shape)
        cg.setFillColor(NSColor(hex: 0x131A33).cgColor)
        cg.fillPath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        // 무대 한 장면을 4배로 키워 그린다 (206pt 칸)
        let unit: CGFloat = 4
        cg.translateBy(x: tile.minX, y: tile.minY)
        cg.scaleBy(x: unit, y: unit)
        let size = CGSize(width: tile.width / unit, height: tile.height / unit)
        let groundY = size.height - 30
        var sky = Sky.at(hour: 22, space: false)
        sky.stars = 1
        Backdrop.draw(cg, size: size, sky: sky, time: 3.2, groundY: groundY, scroll: 60, speed: 0,
                      track: nil, weather: nil)
        // 공기 줄 셋: 빠르게 달리는 느낌만
        cg.setLineCap(.round)
        for (y, x, length) in [(84.0, 12.0, 30.0), (108.0, 4.0, 24.0), (132.0, 16.0, 18.0)] as [(CGFloat, CGFloat, CGFloat)] {
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            cg.setLineWidth(2.2)
            cg.move(to: CGPoint(x: x, y: y))
            cg.addLine(to: CGPoint(x: x + length, y: y))
            cg.strokePath()
        }
        drawRunner(cg, centerX: size.width * 0.47, ground: groundY + 1, height: 124)
        cg.restoreGState()

        // 가장자리에 아주 옅은 빛 테두리
        cg.addPath(shape)
        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        cg.setLineWidth(3)
        cg.strokePath()
    }

    private static func drawRunner(_ cg: CGContext, centerX: CGFloat, ground: CGFloat, height: CGFloat) {
        let character = Runner.cat.character
        // 두 발이 벌어져 달리는 순간
        let scene = CharacterScene(rig: character.rig, pose: CharacterPose(activity: .run, phase: 0.3))
        let scale = height / Stage.size.height
        cg.saveGState()
        cg.translateBy(x: centerX - Stage.size.width * scale / 2, y: ground - Stage.ground * scale)
        cg.scaleBy(x: scale, y: scale)
        let rich = character.theme(.auto)
        let look = CharacterLook(rich: true, palette: rich.richPalette(character.rig.palette, phase: 0),
                                 tint: .white, outline: 0.36)
        scene.draw(in: cg, look: look)
        cg.restoreGState()
    }
}
