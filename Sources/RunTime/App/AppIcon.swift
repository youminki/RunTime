import AppKit

/// 앱 아이콘 (`--app-icon <파일.png> [러너 폴더] [동료 폴더]`): 무대와 같은 배경·러너 그림으로 1024px 아이콘을 그린다.
/// 지금 아이콘은 햇살 언덕에서 짱구가 달리고 부리부리 대마왕이 뒤따르는 장면이다 (Petdex에서 받은 두 펫의 폴더를 넘긴다).
/// 폴더를 주지 않으면 기본 펫 고양이로 그린다. scripts/make-icon.sh가 크기별로 줄여 assets/AppIcon.icns를 만든다.
@MainActor
enum AppIcon {
    static func write(to url: URL, runner: URL? = nil, companion: URL? = nil) throws {
        let side = 1024
        guard let cg = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 무대 그림은 y가 아래로 자라는 좌표라 뒤집는다
        cg.translateBy(x: 0, y: CGFloat(side))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let lead = runner.flatMap(character) ?? Runner.cat.character
        let follower = companion.flatMap(character)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { draw(cg, lead: lead, follower: follower) }
        guard let image = cg.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }

    private static func character(_ folder: URL) -> RunnerCharacter? {
        SheetRig(folder: folder).map {
            RunnerCharacter(key: folder.lastPathComponent, name: "", sound: "", rig: FittedRig($0), fixedTheme: .natural)
        }
    }

    /// macOS 아이콘 격자: 1024 안에 824 둥근 사각형, 아래로 옅은 그림자.
    private static func draw(_ cg: CGContext, lead: RunnerCharacter, follower: RunnerCharacter?) {
        let tile = CGRect(x: 100, y: 92, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        cg.addPath(shape)
        cg.setFillColor(NSColor(hex: 0x7CC7F2).cgColor)
        cg.fillPath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        // 무대 한 장면을 4배로 키워 그린다 (206pt 칸). 햇살 언덕, 한낮
        let unit: CGFloat = 4
        cg.translateBy(x: tile.minX, y: tile.minY)
        cg.scaleBy(x: unit, y: unit)
        let size = CGSize(width: tile.width / unit, height: tile.height / unit)
        let groundY = size.height - 26
        Backdrop.draw(cg, size: size, sky: Sky.at(hour: 12, space: false), time: 3.2, groundY: groundY, scroll: 40, speed: 0,
                      track: .sunnyHillsTrack)
        if let follower {
            // 동료는 뒤에서 조금 작게 따라온다
            drawRunner(cg, follower, centerX: size.width * 0.27, ground: groundY + 1, height: 92, phase: 0.75)
            drawRunner(cg, lead, centerX: size.width * 0.64, ground: groundY + 1, height: 118, phase: 0.3)
        } else {
            drawRunner(cg, lead, centerX: size.width * 0.5, ground: groundY + 1, height: 124, phase: 0.3)
        }
        // 발밑 반짝이 (설정한 발먼지)
        let spray = GameFX.dust(.sparkleDust, landing: true)
        for (x, age) in [(0.5, 0.25), (0.42, 0.45)] as [(CGFloat, CGFloat)] {
            GameFX.drawSpray(spray, from: CGPoint(x: size.width * x, y: groundY), age: age, time: 1.4, cg)
        }
        cg.restoreGState()

        // 가장자리에 아주 옅은 빛 테두리
        cg.addPath(shape)
        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        cg.setLineWidth(3)
        cg.strokePath()
    }

    private static func drawRunner(_ cg: CGContext, _ character: RunnerCharacter, centerX: CGFloat, ground: CGFloat,
                                   height: CGFloat, phase: CGFloat) {
        let scene = CharacterScene(rig: character.rig, pose: CharacterPose(activity: .run, phase: phase))
        let scale = height / Stage.size.height
        cg.saveGState()
        // 그림자
        cg.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        cg.fillEllipse(in: CGRect(x: centerX - height * 0.22, y: ground - 3, width: height * 0.44, height: 6))
        cg.translateBy(x: centerX - Stage.size.width * scale / 2, y: ground - Stage.ground * scale)
        cg.scaleBy(x: scale, y: scale)
        let rich = character.theme(.natural)
        let look = CharacterLook(rich: true, palette: rich.richPalette(character.rig.palette, phase: 0),
                                 tint: .white, outline: 0.36)
        scene.draw(in: cg, look: look)
        cg.restoreGState()
    }
}
