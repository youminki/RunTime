import AppKit

/// 메뉴바 러너 칸. 상태 버튼은 22pt지만 메뉴바 창은 더 높을 수 있어(macOS 27에서 30pt) 창 높이까지 키우고,
/// 크기 설정만큼 옆으로 넓힌다. 크기를 화면 픽셀에 맞춰야 레이어가 프레임을 늘려 붙이며 흐려지지 않는다.
/// AppDelegate(배치), SpriteAnimator(래스터), MenuBarAudit(점검)가 같은 계산을 쓴다.
struct MenuBarCanvas: Equatable {
    /// 설계 1pt를 화면 몇 pt로 그릴지.
    let scale: CGFloat
    /// 설정의 메뉴바 크기 (RunnerSize.zoom).
    let zoom: CGFloat
    /// 화면 배율 (레티나 2, 일반 1).
    let backing: CGFloat

    init(barHeight: CGFloat, zoom requested: CGFloat, backing: CGFloat) {
        // 노치 화면처럼 메뉴바가 아주 높아도 항목이 너무 넓어져 노치 뒤로 숨지 않게 상한을 둔다
        scale = min(max(1, barHeight.isFinite ? barHeight / Stage.size.height : 1), 1.6)
        self.backing = max(backing.isFinite ? backing : 2, 1)
        // 서 있는 몸과 테두리가 칸 높이에 그대로 들어가는 만큼까지만 키운다. 넘치면 모든 프레임을 줄여 넣게 된다.
        let pixelsPerPoint = (Stage.size.height * scale * self.backing).rounded() / Stage.size.height
        let margin = Self.margin(haloRadius: self.backing >= 2 ? 2 : 1, pixelsPerPoint: pixelsPerPoint)
        let fits = (Stage.size.height - margin * 2) / FittedRig.targetHeight
        // '작게'는 1보다 작게 줄여 메뉴바 칸을 좁힌다
        zoom = min(max(requested.isFinite ? requested : 1, 0.7), max(fits, 1))
    }

    /// 칸 위아래에 남길 설계 pt. 테두리 두께에, 그림을 줄일 때 가장자리가 번지는 몫을 더한다.
    private static func margin(haloRadius: Int, pixelsPerPoint: CGFloat) -> CGFloat {
        (CGFloat(haloRadius) + 0.25) / pixelsPerPoint
    }

    var pixelWidth: Int { Int((Stage.size.width * zoom * scale * backing).rounded()) }
    var pixelHeight: Int { Int((Stage.size.height * scale * backing).rounded()) }

    /// 화면 pt 크기. 픽셀 수를 배율로 나눠 소수점 크기로 늘어나지 않게 한다.
    var size: NSSize { NSSize(width: CGFloat(pixelWidth) / backing, height: CGFloat(pixelHeight) / backing) }

    /// 설계 1pt에 들어가는 픽셀 수.
    var pixelsPerPoint: CGFloat { CGFloat(pixelHeight) / Stage.size.height }

    var cacheKey: String { "\(pixelWidth)x\(pixelHeight)@\(zoom)" }

    /// 컬러 러너에 두르는 테두리 두께(px). 1pt 안팎.
    var haloRadius: Int { backing >= 2 ? 2 : 1 }

    /// 선 자세가 차지하는 높이(설계 y, 아래로): 머리는 FittedRig의 목표 키, 발은 바닥.
    private static let standing = (top: Stage.ground - FittedRig.targetHeight, bottom: Stage.ground)
    /// 선 자세의 가운데를 칸 가운데에 두고 키운다. 아래에서 잰 높이.
    private static var standingCenter: CGFloat { Stage.size.height - (standing.top + standing.bottom) / 2 }

    /// 설계 칸(36×22)을 출력 칸에 놓는 사각형 (y 위, 설계 pt 단위). 가로는 키운 만큼 칸이 넓다.
    /// 아래끝을 화면 픽셀 경계에 맞춘다. 1배율 화면에서 반 픽셀 어긋나면 모든 프레임이 번져 흐려 보였다.
    var designRect: CGRect {
        let y = Stage.size.height / 2 - Self.standingCenter * zoom
        return CGRect(x: 0, y: (y * pixelsPerPoint).rounded() / pixelsPerPoint,
                      width: Stage.size.width * zoom, height: Stage.size.height * zoom)
    }

    /// 출력 칸에 보이는 설계 y 범위 (아래로). 테두리가 칸에 닿지 않게 그 두께만큼 안쪽이다.
    var visibleY: ClosedRange<CGFloat> {
        let margin = Self.margin(haloRadius: haloRadius, pixelsPerPoint: pixelsPerPoint)
        // 출력 높이(아래에서) o를 설계 y로
        func y(_ o: CGFloat) -> CGFloat {
            Stage.size.height - (o - designRect.minY) / zoom
        }
        return y(Stage.size.height - margin)...y(margin)
    }
}
