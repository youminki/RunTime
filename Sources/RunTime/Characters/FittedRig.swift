import AppKit

/// 러너마다 원래 그린 크기가 달라 메뉴바에서 병아리·펭귄처럼 작은 것은 잘 안 보였다.
/// 선 자세의 키와 달리는 동안의 폭을 재서 모든 러너가 같은 칸을 비슷하게 채우도록 키우거나 줄인다.
struct FittedRig: CharacterRig {
    let base: CharacterRig
    let scale: CGFloat
    let centerX: CGFloat
    /// 선 자세의 아래끝과, 맞춘 뒤 그 아래끝이 놓일 높이. 떠 있는 러너는 뜬 간격을 줄여 몸을 키운다.
    let bottom: CGFloat
    let placedBottom: CGFloat

    var palette: CharacterPalette { base.palette }
    var isPicture: Bool { base.isPicture }

    /// 목표 키와 폭 (36×22 칸, 바닥 y = 21). 위쪽은 Z·하트 같은 효과가 들어갈 자리를 조금 남긴다.
    static let targetHeight: CGFloat = 18.5
    static let targetWidth: CGFloat = 33
    static let targetCenterX: CGFloat = 17.5
    /// 떠 있는 러너(유령·UFO·고래)의 바닥과의 간격 상한.
    static let maxHover: CGFloat = 2

    init(_ base: CharacterRig) {
        self.base = base
        let standing = Self.bounds(base, poses: [CharacterPose(activity: .stand),
                                                 CharacterPose(activity: .walk, phase: 0.25)])
        let moving = Self.bounds(base, poses: (0..<8).map {
            CharacterPose(activity: .run, phase: CGFloat($0) / 8, speed: 1.35)
        })
        let hover = min(max(Stage.ground - standing.maxY, 0), Self.maxHover)
        let height = max(standing.height + hover, 1)
        let width = max(moving.union(standing).width, 1)
        scale = min(Self.targetHeight / height, Self.targetWidth / width, 1.7)
        centerX = moving.union(standing).midX
        bottom = standing.maxY
        placedBottom = Stage.ground - hover
    }

    func draw(_ s: Sketch) {
        let inner = Sketch(pose: s.pose)
        base.draw(inner)
        // 선 자세의 아래끝을 기준으로 키워 바닥(떠 있으면 바닥 조금 위)에 놓는다.
        var t = CGAffineTransform(translationX: Self.targetCenterX, y: placedBottom)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -centerX, y: -bottom)
        for var part in inner.parts {
            part.path = part.path.copy(using: &t) ?? part.path
            part.imageRect = part.imageRect.applying(t)
            part.stroke *= scale
            part.eyeCenter = part.eyeCenter.applying(t)
            part.eyeRadius *= scale
            s.add(part)
        }
    }

    private static func bounds(_ rig: CharacterRig, poses: [CharacterPose]) -> CGRect {
        poses.reduce(CGRect.null) { rect, pose in
            rect.union(CharacterScene(rig: rig, pose: pose).bounds)
        }
    }
}
