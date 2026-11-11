import AppKit

// 캐릭터는 36×22 설계 좌표(y 아래로, 바닥 y = 21)에 벡터로 그린다.
// 메뉴바는 그대로, 팝오버 무대와 설정 타일은 배율만 키워 같은 그림을 쓴다.

let tau = CGFloat.pi * 2

enum Stage {
    static let size = CGSize(width: 36, height: 22)
    static let ground: CGFloat = 21
}

// MARK: - 자세

/// 한 장면의 자세. 같은 자세라도 `phase`(0~1 주기)에 따라 다리·꼬리·숨이 움직인다.
struct CharacterPose {
    enum Activity: Equatable {
        case stand   // 제자리 (숨쉬기)
        case walk
        case run     // speed로 보폭과 몸 기울기를 키운다
        case sit     // 지쳐 앉음
        case sleep
    }

    enum Eyes { case open, closed, happy }

    var activity: Activity
    var phase: CGFloat = 0
    /// 달리기 세기 (1 = 달리기, 1.3 = 전력 질주).
    var speed: CGFloat = 1
    var eyes: Eyes = .open
    /// 헐떡이거나 하품할 때 입을 벌린다.
    var mouthOpen = false
    /// 손 흔들기 진행(주기 단위). 그림 러너는 시트의 손 흔들기 줄로 그리고, 벡터 러너는 쓰지 않는다.
    var wave: CGFloat?
    /// 뛰는 진행 (0 도약 ~ 1 착지). 그림 러너는 시트의 점프 줄로 그리고, 벡터 러너는 쓰지 않는다.
    var jump: CGFloat?
    /// 생각하는 진행(주기 단위). 그림 러너는 시트의 검토 줄로 그리고, 벡터 러너는 쓰지 않는다.
    var review: CGFloat?
    /// 앉은 자세에서 고개를 떨군다 (한도 경고). 그림 러너는 시트의 슬픔 줄로 그린다.
    var sad = false
    /// 왼쪽을 보고 있다. 장면이 좌우를 뒤집기 전에 정한다. 그림 러너는 시트에 왼쪽 달리기 줄이 있으면 그 줄로 그린다
    /// (뒤집은 그림은 든 물건·무늬가 거울처럼 바뀐다).
    var leftward = false

    var cycle: CGFloat { phase - floor(phase) }
}

// MARK: - 색

/// 캐릭터 고유색. 팝오버 무대와 '본래 색' 테마에서 쓴다.
struct CharacterPalette {
    var body: NSColor
    var belly: NSColor
    var dark: NSColor
    var accent: NSColor = NSColor(hex: 0xFF9F2E)
    var horn: NSColor = NSColor(hex: 0xFFD45E)
    var pink: NSColor = NSColor(hex: 0xFF8FA8)
    var extra: NSColor = NSColor(hex: 0xB48CFF)
    /// 그림 러너(Petdex, 내 그림)에 덧입힐 색. 그림의 명암은 두고 색만 바꾼다.
    var imageTint: NSColor?
}

enum Role {
    case body, belly, dark, accent, horn, pink, extra
    case white   // 눈 하이라이트·이빨처럼 항상 흰색
    case ink     // 코·입처럼 항상 진한 색
    case glass   // UFO 유리처럼 반투명
}

/// 그리는 방식. 메뉴바 기본은 단색 실루엣, 팝오버는 외곽선·명암을 넣은 컬러.
struct CharacterLook {
    var rich: Bool
    var palette: CharacterPalette
    /// 단색일 때 몸 색.
    var tint: NSColor
    /// 외곽선 두께(설계 좌표). 화면 배율이 크면 얇게 준다.
    var outline: CGFloat = 0.55
    /// 한도 경고: 빨갛게 덮는다.
    var alarm = false

    static func mono(_ color: NSColor) -> CharacterLook {
        CharacterLook(rich: false, palette: .init(body: color, belly: color, dark: color), tint: color)
    }

    func color(_ role: Role, far: Bool) -> NSColor? {
        let base: NSColor?
        if rich {
            switch role {
            case .body: base = palette.body
            case .belly: base = palette.belly
            case .dark: base = palette.dark
            case .accent: base = palette.accent
            case .horn: base = palette.horn
            case .pink: base = palette.pink
            case .extra: base = palette.extra
            case .white: base = .white
            case .ink: base = NSColor(hex: 0x231F2E)
            case .glass: base = NSColor(hex: 0xA8ECFF).withAlphaComponent(0.75)
            }
            return far ? base?.shaded(by: 0.22) : base
        }
        switch role {
        case .body, .belly, .dark, .extra: base = tint
        case .accent: base = .systemOrange
        case .horn: base = .systemYellow
        case .glass: base = tint.withAlphaComponent(0.45)
        case .pink, .white, .ink: base = nil   // 단색에선 세부 장식을 생략
        }
        return far ? base?.withAlphaComponent(0.5) : base
    }
}

// MARK: - 도형 모음

/// 캐릭터 한 장면을 이루는 도형. 채우기(fill)와 둥근 선(stroke)을 함께 쓸 수 있다.
struct Part {
    enum Layer { case base, detail, eye }

    var path: CGPath
    var fill: Bool
    var stroke: CGFloat
    var role: Role
    var far = false
    var layer: Layer = .base
    /// 앞쪽 다리처럼 몸 위에 겹쳐도 경계가 보여야 하는 도형.
    var ownOutline = false
    var eyeCenter = CGPoint.zero
    var eyeRadius: CGFloat = 0
    /// 내 러너: 도형 대신 그림을 그린다 (`imageRect`에, 아래끝 중심 기준 `imageRotation`만큼 기울여).
    var image: CGImage?
    var imageRect = CGRect.zero
    var imageRotation: CGFloat = 0
    /// 그림을 좌우로 뒤집어 그린다. 장면이 왼쪽을 보며 뒤집을 때, 이미 왼쪽을 보는 그림을 원래대로 보이게 한다.
    var imageMirrored = false
}

final class Sketch {
    private(set) var parts: [Part] = []
    let pose: CharacterPose

    init(pose: CharacterPose) { self.pose = pose }

    func add(_ part: Part) { parts.append(part) }

    func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, rotation: CGFloat = 0,
                 _ role: Role = .body, far: Bool = false, own: Bool = false) {
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotation)
        let path = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &t)
        add(Part(path: path, fill: true, stroke: 0, role: role, far: far, ownOutline: own))
    }

    func circle(_ c: CGPoint, _ r: CGFloat, _ role: Role = .body, far: Bool = false, own: Bool = false) {
        ellipse(c, r, r, role, far: far, own: own)
    }

    /// 둥근 끝 막대 (다리·팔·목).
    func capsule(_ points: [CGPoint], width: CGFloat, _ role: Role = .body, far: Bool = false, own: Bool = false) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        add(Part(path: path, fill: false, stroke: width, role: role, far: far, ownOutline: own))
    }

    /// 다각형. `round`만큼 모서리를 둥글린다.
    func polygon(_ points: [CGPoint], round: CGFloat = 0.3, _ role: Role = .body, far: Bool = false,
                 own: Bool = false, layer: Part.Layer = .base) {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        add(Part(path: path, fill: true, stroke: round * 2, role: role, far: far, layer: layer, ownOutline: own))
    }

    func shape(_ path: CGPath, round: CGFloat = 0, _ role: Role = .body, far: Bool = false,
               own: Bool = false, layer: Part.Layer = .base) {
        add(Part(path: path, fill: true, stroke: round * 2, role: role, far: far, layer: layer, ownOutline: own))
    }

    /// 굵기가 줄어드는 곡선 (꼬리·갈기·촉수).
    func tapered(_ points: [CGPoint], from w0: CGFloat, to w1: CGFloat, _ role: Role = .body, far: Bool = false,
                 layer: Part.Layer = .base) {
        guard points.count >= 2 else { return }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for (i, p) in points.enumerated() {
            let prev = points[max(i - 1, 0)]
            let next = points[min(i + 1, points.count - 1)]
            let d = (next - prev).normalized
            let n = CGPoint(x: -d.y, y: d.x)
            let w = lerp(w0, w1, CGFloat(i) / CGFloat(points.count - 1)) / 2
            left.append(p + n * w)
            right.append(p - n * w)
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        // 끝을 둥글게: 굵은 쪽 끝에 원을 덧댄다
        add(Part(path: path, fill: true, stroke: 0.25, role: role, far: far, layer: layer))
        if layer == .base {
            circle(points[0], w0 / 2, role, far: far)
        }
    }

    /// 2관절 다리. 엉덩이에서 발까지, 무릎은 `kneeForward` 방향으로 굽힌다. 무릎 위치를 돌려준다.
    @discardableResult
    func limb(hip: CGPoint, foot: CGPoint, length: CGFloat, width: CGFloat, kneeForward: Bool,
              _ role: Role = .body, far: Bool = false, own: Bool = false, taper: CGFloat = 0.85) -> CGPoint {
        let knee = Self.knee(hip: hip, foot: foot, length: length, forward: kneeForward)
        let path = CGMutablePath()
        path.move(to: hip)
        path.addLine(to: knee)
        path.addLine(to: foot)
        add(Part(path: path, fill: false, stroke: width, role: role, far: far, ownOutline: own))
        return knee
    }

    static func knee(hip: CGPoint, foot: CGPoint, length: CGFloat, forward: Bool) -> CGPoint {
        let half = length / 2
        let d = foot - hip
        let dist = min(d.length, length * 0.999)
        let mid = hip + d.normalized * (dist / 2)
        let bend = sqrt(max(half * half - (dist / 2) * (dist / 2), 0))
        var n = CGPoint(x: -d.normalized.y, y: d.normalized.x)   // 진행 방향 기준 왼쪽
        if (n.x > 0) != forward { n = n * -1 }
        return mid + n * bend
    }

    // MARK: 세부 (컬러에서만)

    func eye(_ c: CGPoint, _ r: CGFloat) {
        add(Part(path: CGPath(rect: .zero, transform: nil), fill: false, stroke: 0, role: .ink,
                 layer: .eye, eyeCenter: c, eyeRadius: r))
    }

    func detail(_ path: CGPath, _ role: Role) {
        add(Part(path: path, fill: true, stroke: 0, role: role, layer: .detail))
    }

    func detailEllipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, rotation: CGFloat = 0, _ role: Role) {
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotation)
        detail(CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &t), role)
    }

    func detailLine(_ points: [CGPoint], width: CGFloat, _ role: Role) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        add(Part(path: path, fill: false, stroke: width, role: role, layer: .detail))
    }

    func detailCurve(_ a: CGPoint, control: CGPoint, _ b: CGPoint, width: CGFloat, _ role: Role) {
        let path = CGMutablePath()
        path.move(to: a)
        path.addQuadCurve(to: b, control: control)
        add(Part(path: path, fill: false, stroke: width, role: role, layer: .detail))
    }
}

/// 캐릭터 하나. 자세를 받아 도형을 쌓는다.
protocol CharacterRig {
    var palette: CharacterPalette { get }
    /// 그림(Petdex·내 그림) 러너인지. 그림은 돌리거나 찌그러뜨리면 도트가 깨져 어색하다.
    var isPicture: Bool { get }
    func draw(_ s: Sketch)
}

extension CharacterRig {
    var isPicture: Bool { false }
}

// MARK: - 걸음 계산

enum Gait {
    /// 발 하나의 위치: 앞으로 내딛는 동안 들리고(swing) 땅을 짚는 동안 뒤로 민다(stance).
    /// - Returns: 엉덩이 기준 x 이동과 들린 높이
    static func foot(_ u: CGFloat, stride: CGFloat, lift: CGFloat, duty: CGFloat = 0.5) -> (dx: CGFloat, lift: CGFloat) {
        let t = u - floor(u)
        if t < duty {
            let k = t / duty
            return (stride * cos(.pi * k), 0)
        }
        let k = (t - duty) / (1 - duty)
        return (-stride * cos(.pi * k), lift * sin(.pi * k))
    }
}

// MARK: - 수학

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func smoothstep(_ t: CGFloat) -> CGFloat {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

extension CGPoint {
    init(_ x: CGFloat, _ y: CGFloat) { self.init(x: x, y: y) }

    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }

    var length: CGFloat { sqrt(x * x + y * y) }
    var normalized: CGPoint { length > 0 ? self * (1 / length) : CGPoint(x: 1, y: 0) }

    /// 원점 기준 회전 (y 아래 좌표라 양수 = 시계 방향).
    func rotated(_ angle: CGFloat) -> CGPoint {
        CGPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }

    static func polar(_ angle: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: cos(angle) * r, y: sin(angle) * r)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// 어둡게 (0~1).
    func shaded(by amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: NSColor(hex: 0x1E1A2E)) ?? self
    }

    func tinted(by amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: .white) ?? self
    }
}

/// 몸통 기준 좌표계: 중심과 기울기를 정해 두고 몸에 붙은 점을 구한다.
struct BodyFrame {
    var center: CGPoint
    var pitch: CGFloat

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        center + CGPoint(x, y).rotated(pitch)
    }
}
