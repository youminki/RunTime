import AppKit

/// 사용률 고리. 설계 좌표(36×22)에 그리며 메뉴바 프레임과 팝오버 무대가 함께 쓴다.
/// 나머지 러너 주변 효과는 도트 그림(GameFX, Emote)이다.
enum SpriteEffects {

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
}
