import AppKit

/// 무대와 게임의 배경. 고른 트랙(없으면 구름 숲)의 도트 그림 층을 겹치고, 그 위에 땅 줄을 그린다.
/// 낮 그림은 시간대(`Sky`)에 따라 어둡게 누르고, 그림 자체가 노을이나 밤인 트랙은 그대로 둔다.
enum Backdrop {

    /// Assets/Scenes/<폴더>의 scene.json. 층 그림은 0.png(가장 먼 층)부터 겹친다.
    struct Scene: Decodable {
        let layers: Int
        let ground: String
        let edge: String
        /// 그림 자체가 저녁이나 밤이라 시간대로 어둡게 하지 않는다.
        var ownTime: Bool?
        /// 서 있어도 흘러가는 구름 층.
        var clouds: Int?
    }

    static let defaultFolder = "cloudWoods"
    private static var scenes: [String: Scene] = [:]
    /// 층을 겹쳐 둘 작은 판. 도트 그림의 원래 해상도로 겹친 뒤 화면에는 한 번만 키워 그린다.
    /// 큰 창 무대에서 층마다 키워 겹치면 한 장면에 10ms 넘게 걸려 60장을 못 그린다.
    /// 크기마다 하나씩 둔다 (무대와 꾸미기 칸이 번갈아 그린다). 메인 스레드에서만 쓴다.
    private static var boards: [Int: CGContext] = [:]

    private static func canvas(width: Int, height: Int) -> CGContext? {
        let key = width << 16 | height
        if let board = boards[key] { return board }
        // 창 크기를 바꾸는 동안 생긴 판이 쌓이지 않게 넘치면 비운다
        if boards.count > 12 { boards.removeAll() }
        let board = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        boards[key] = board
        return board
    }

    /// 트랙 꾸미기의 그림 폴더. 꾸미기 이름에서 "Track"을 뗀 이름이다.
    static func folder(_ item: Cosmetic?) -> String {
        guard let item, item.slot == .track else { return defaultFolder }
        return String(item.rawValue.dropLast("Track".count))
    }

    static func scene(_ folder: String) -> Scene? {
        if let cached = scenes[folder] { return cached }
        guard let url = Bundle.assets.resourceURL?.appendingPathComponent("Assets/Scenes/\(folder)/scene.json"),
              let data = try? Data(contentsOf: url),
              let scene = try? JSONDecoder().decode(Scene.self, from: data) else { return nil }
        scenes[folder] = scene
        return scene
    }

    /// 밤인 정도 (0 낮 ~ 1 깊은 밤). 낮 그림을 시간대 색으로 누르는 데 쓴다.
    static func nightness(_ sky: Sky) -> CGFloat { min(1, max(sky.stars, sky.orbLow ? 0.45 : 0)) }

    /// 배경 한 장. `scroll`은 지금까지 달린 거리, `speed`는 땅 점선을 늘이는 데 쓴다 (pt/초).
    static func draw(_ cg: CGContext, size: CGSize, sky: Sky, time: CGFloat, groundY: CGFloat, scroll: CGFloat,
                     speed: CGFloat, track item: Cosmetic?) {
        // 그림이 빠진 트랙은 기본 그림으로 그린다
        let chosen = folder(item)
        let found = scene(chosen).map { (chosen, $0) } ?? scene(defaultFolder).map { (defaultFolder, $0) }
        if let (folder, scene) = found {
            drawScene(cg, scene, folder: folder, size: size, sky: sky, time: time, groundY: groundY, scroll: scroll,
                      speed: speed)
        }
    }

    // MARK: 도트 그림

    private static func drawScene(_ cg: CGContext, _ scene: Scene, folder: String, size: CGSize, sky: Sky, time: CGFloat,
                                  groundY: CGFloat, scroll: CGFloat, speed: CGFloat) {
        let height = groundY + 2
        let images = (0..<scene.layers).map { GameFX.image("\($0)", folder: "Scenes/\(folder)") }
        // 원래 그림 높이(px)를 판 높이로 쓴다. 층은 판에서 정수 픽셀 자리에 놓여 도트가 흔들리지 않는다
        let native = images.compactMap { $0?.height }.max() ?? Int(height)
        let perPoint = CGFloat(native) / height
        if let board = canvas(width: Int((size.width * perPoint).rounded(.up)) + 1, height: native) {
            board.clear(CGRect(x: 0, y: 0, width: board.width, height: board.height))
            board.interpolationQuality = .none
            for (layer, image) in images.enumerated() {
                guard let image else { continue }
                let width = CGFloat(image.width) * CGFloat(native) / CGFloat(image.height)
                let depth = scene.layers > 1 ? CGFloat(layer) / CGFloat(scene.layers - 1) : 0.25
                let moved = (scroll * (0.04 + 0.36 * depth) + (layer == scene.clouds ? time * 3 : 0)) * perPoint
                var x = (-moved.truncatingRemainder(dividingBy: width)).rounded(.down)
                if x > 0 { x -= width }
                while x < CGFloat(board.width) {
                    board.draw(image, in: CGRect(x: x, y: 0, width: width, height: CGFloat(native)))
                    x += width
                }
            }
            if let composed = board.makeImage() {
                cg.saveGState()
                cg.translateBy(x: 0, y: height)
                cg.scaleBy(x: 1, y: -1)
                // 화면이 판보다 작으면(꾸미기 칸) 점을 건너뛰지 않게 부드럽게 줄인다
                cg.interpolationQuality = abs(cg.ctm.d) * height < CGFloat(native) * 0.9 ? .medium : .none
                cg.draw(composed, in: CGRect(x: 0, y: 0, width: CGFloat(board.width) / perPoint, height: height))
                cg.restoreGState()
            }
        }
        let night = scene.ownTime == true ? 0 : nightness(sky)
        if night > 0 {
            cg.setFillColor(sky.top.withAlphaComponent(night * 0.5).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: height))
        }
        func color(_ hex: String, _ base: NSColor) -> NSColor {
            let own = NSColor(hex: UInt32(hex, radix: 16) ?? 0)
            return own.blended(withFraction: night * 0.5, of: base) ?? own
        }
        drawGround(cg, size: size, groundY: groundY, scroll: scroll, speed: speed, ground: color(scene.ground, sky.ground),
                   edge: color(scene.edge, sky.edge))
    }

    // MARK: 땅

    private static func drawGround(_ cg: CGContext, size: CGSize, groundY: CGFloat, scroll: CGFloat, speed: CGFloat,
                                   ground: NSColor, edge: NSColor) {
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
    }
}
