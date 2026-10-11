import AppKit
import GameCore

/// 게임 그림 (Kenney Pixel Platformer, CC0. 출처는 Assets/Game/CREDITS.txt).
/// 원본 1px을 2pt로, 이웃 픽셀 그대로 키워 그린다.
enum GameSprite: String, CaseIterable {
    case spikes, mushroom, cactus, tree, crab, drill, bat, spikeball, crusher, coin

    static let pixelScale: CGFloat = 2

    /// 원본 1px을 몇 pt로 그릴지. 24px 타일을 꽉 채운 그림은 다른 장애물과 키를 맞추려고 덜 키운다.
    var scale: CGFloat {
        switch self {
        case .spikeball, .crusher: 1.5
        default: Self.pixelScale
        }
    }

    var frameNames: [String] {
        switch self {
        case .crab: return ["crab_0", "crab_1"]
        case .drill: return ["drill_0", "drill_1", "drill_2"]
        case .bat: return ["bat_0", "bat_1", "bat_2", "bat_1"]
        case .crusher: return ["crusher_0", "crusher_1"]
        case .coin: return ["coin_0", "coin_1"]
        default: return [rawValue]
        }
    }

    /// 초당 넘기는 장수.
    var framesPerSecond: Double {
        switch self {
        case .bat: return 10
        case .coin: return 5
        default: return 7
        }
    }

    var frames: [CGImage] { GameAssets.frames(self) }

    /// 그림이 있는 영역 (원본 픽셀, 위가 0). 판정 상자를 그림에 딱 맞춘다.
    var content: CGRect { GameAssets.content(self) }

    /// 판정 크기 (pt).
    var size: CGSize {
        CGSize(width: content.width * scale, height: content.height * scale)
    }

    func frame(at time: Double) -> CGImage? {
        let frames = frames
        guard !frames.isEmpty else { return nil }
        return frames[Int(time * framesPerSecond) % frames.count]
    }
}

enum GameAssets {
    private static var frameCache: [GameSprite: [CGImage]] = [:]
    private static var contentCache: [GameSprite: CGRect] = [:]

    static func frames(_ sprite: GameSprite) -> [CGImage] {
        if let cached = frameCache[sprite] { return cached }
        let images = sprite.frameNames.compactMap(image)
        frameCache[sprite] = images
        return images
    }

    private static var imageCache: [String: CGImage] = [:]

    /// Assets/Game의 PNG 한 장.
    static func image(_ name: String) -> CGImage? {
        if let cached = imageCache[name] { return cached }
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("Assets/Game/\(name).png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        imageCache[name] = image
        return image
    }

    /// 모든 프레임의 그림 영역을 합친 것. 날갯짓처럼 프레임마다 달라도 판정은 하나로 둔다.
    static func content(_ sprite: GameSprite) -> CGRect {
        if let cached = contentCache[sprite] { return cached }
        let rect = frames(sprite).reduce(CGRect.null) { union, image in
            let unit = SheetFrames.content(of: image)
            return union.union(CGRect(x: unit.minX * CGFloat(image.width), y: unit.minY * CGFloat(image.height),
                                      width: unit.width * CGFloat(image.width), height: unit.height * CGFloat(image.height)))
        }
        let result = rect.isNull ? CGRect(x: 0, y: 0, width: 18, height: 18) : rect.integral
        contentCache[sprite] = result
        return result
    }

    /// 장애물 목록. 나오는 속도와 간격은 T-Rex Runner의 선인장·익룡 설정을 이 게임 속도(220~540pt/초)에 맞춘 것.
    static func catalog(runnerHeight: Double) -> [RunnerGame.ObstacleKind] {
        func kind(_ sprite: GameSprite, elevations: [Double] = [], minSpeed: Double = 0, groupSpeed: Double? = nil,
                  minGap: Double = 120, approach: Double = 0, dropFrom: Double? = nil) -> RunnerGame.ObstacleKind {
            RunnerGame.ObstacleKind(id: sprite.rawValue, width: Double(sprite.size.width), height: Double(sprite.size.height),
                                    elevations: elevations, minSpeed: minSpeed, groupSpeed: groupSpeed, minGap: minGap,
                                    approachSpeed: approach, dropFrom: dropFrom)
        }
        return [
            kind(.spikes, groupSpeed: 300),
            kind(.mushroom),
            kind(.cactus, groupSpeed: 420),
            kind(.tree, minSpeed: 300, minGap: 130),
            kind(.crab, minSpeed: 260, minGap: 140, approach: 40),
            kind(.drill, minSpeed: 380, minGap: 160, approach: 70),
            // 낮게 나는 박쥐는 숙이고(빠를 때는 뛰어넘어도 되고), 높게 나는 박쥐는 서서 지나간다
            kind(.bat, elevations: [22, runnerHeight + 10], minSpeed: 330, minGap: 150),
            // 굴러오는 가시공은 게보다 훨씬 빨리 다가온다
            kind(.spikeball, minSpeed: 340, minGap: 150, approach: 110),
            // 머리 위에 떠 있다가 다가가면 내리찍는 로봇 상자
            kind(.crusher, minSpeed: 300, minGap: 150, dropFrom: runnerHeight + 32),
        ]
    }

    /// 좌표계가 위아래로 뒤집힌 무대에 도트 그림을 그대로 그린다.
    static func draw(_ image: CGImage, in rect: CGRect, _ cg: CGContext, flipX: Bool = false) {
        cg.saveGState()
        cg.interpolationQuality = .none
        cg.translateBy(x: flipX ? rect.maxX : rect.minX, y: rect.maxY)
        cg.scaleBy(x: flipX ? -1 : 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }
}
