import AppKit

/// 러너 머리 옆에 띄우는 도트 말풍선 (Kenney Emotes, Game Dev Alliance 말풍선. 출처는 Assets/FX/CREDITS.txt).
/// 좌표는 36×22 설계 좌표다. 메뉴바 칸 위·오른쪽 안에 들어가게 둔다.
enum Emote {
    static let height: CGFloat = 6.5

    /// 메뉴바에서는 읽히도록 크게, 크게 키운 무대에서는 머리보다 작게 그린다. 그리는 배율을 보고 고른다.
    private static func size(_ cg: CGContext) -> CGFloat {
        abs(cg.ctm.a) > 4 ? 4.6 : height
    }

    /// 위끝을 머리 꼭대기에 맞춘다. 메뉴바는 장면을 칸 안에 맞춰 넣으므로 머리보다 위로 나가면 칸 밖에서 잘린다.
    static func spot(_ bounds: CGRect) -> CGPoint {
        CGPoint(min(bounds.maxX + 2.4, 36 - height / 2 - 0.2), max(bounds.minY + height / 2, height / 2 + 0.2))
    }

    /// 정지 말풍선 (Assets/FX/emote). `pop`(0~1)이 1에 닿을 때까지 톡 튀어나오며 커진다.
    static func draw(_ name: String, in cg: CGContext, around bounds: CGRect, pop: CGFloat, alpha: CGFloat = 1,
                     bob: CGFloat = 0) {
        guard alpha > 0.01, pop > 0, let image = GameFX.image(name, folder: "FX/emote") else { return }
        // 살짝 넘쳤다가 제 크기로 돌아온다
        let p = min(pop, 1)
        let scale = p < 1 ? 1 + 0.25 * sin(.pi * p) - 0.25 * (1 - p) : 1
        let c = spot(bounds) + CGPoint(0, bob)
        let h = size(cg) * scale
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.interpolationQuality = .none
        cg.translateBy(x: c.x, y: c.y)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: -h / 2, y: -h / 2, width: h, height: h))
        cg.restoreGState()
    }

    /// 움직이는 말풍선 (balloonHeart, balloonDots, balloonExclaim, balloonQuestion). `progress`로 프레임을 고른다.
    static func animate(_ sheet: String, in cg: CGContext, around bounds: CGRect, progress: CGFloat, alpha: CGFloat = 1) {
        GameFX.drawSprite(sheet, at: spot(bounds), height: size(cg) * 1.15, progress: progress, time: 0, alpha: alpha, cg)
    }
}
