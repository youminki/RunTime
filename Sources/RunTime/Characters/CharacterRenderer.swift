import AppKit

/// 자세와 상관없이 캐릭터 전체에 거는 변형 (점프, 뒤돌기, 찌그러짐, 흔들림).
struct CharacterTransform {
    var offset = CGPoint.zero
    /// -1이면 좌우 반전. 0을 지나며 바뀌면 빙글 도는 것처럼 보인다.
    var scaleX: CGFloat = 1
    /// 1보다 작으면 납작, 크면 길쭉 (부피는 유지).
    var squash: CGFloat = 1
    /// 회전 (라디안). 기본은 바닥 중심, 공중제비처럼 몸 중심으로 돌 때는 `pivotAtCenter`.
    var rotation: CGFloat = 0
    var pivotAtCenter = false
}

/// 장면 하나를 미리 쌓아 둔 것. 그리기 전에 크기(그림자·효과 위치)를 알 수 있다.
struct CharacterScene {
    let parts: [Part]
    let bounds: CGRect
    let pose: CharacterPose
    let transform: CharacterTransform
    /// 변형 뒤에 거는 맞춤. 메뉴바 칸을 벗어나는 장면을 줄이고 옮겨 안에 넣는다 (`fit(verticallyIn:)`).
    private(set) var fit = CGAffineTransform.identity

    init(rig: CharacterRig, pose: CharacterPose, transform: CharacterTransform = .init()) {
        let sketch = Sketch(pose: pose)
        rig.draw(sketch)
        parts = sketch.parts
        self.pose = pose
        self.transform = transform
        bounds = parts.filter { $0.layer == .base }.reduce(CGRect.null) { rect, part in
            rect.union(part.path.boundingBoxOfPath.insetBy(dx: -part.stroke / 2, dy: -part.stroke / 2))
        }
    }

    /// 변형까지 적용한 화면상 영역 (효과 위치 계산용).
    var placedBounds: CGRect {
        guard !bounds.isNull else { return .zero }
        return bounds.applying(affine)
    }

    /// 모자·안경을 얹을 자리 (설계 좌표, 변형까지 적용). 앞쪽 눈과 그 눈을 품은 가장 작은 몸 부품을 머리로 본다.
    /// 그림 러너(내 그림, Petdex)는 그림에서 눈을 찾고(`ImageEyes`), 못 찾으면 그림 윗부분 앞쪽을 머리로 어림한다.
    struct HeadAnchor {
        let eye: CGPoint
        let top: CGPoint
        let width: CGFloat
        /// 머리 기울기 (라디안).
        let tilt: CGFloat
        /// 눈 자리를 알고 있는지. 그림에서 눈을 못 찾은 그림 러너는 얼굴 꾸미기를 씌우지 않는다.
        var hasEyes = true
        /// 그림 러너에서 찾은 두 눈 사이 거리. 있으면 `eye`는 두 눈 가운데다.
        var eyeSpan: CGFloat?
    }

    var headAnchor: HeadAnchor? {
        guard !bounds.isNull else { return nil }
        let t = affine
        let scale = sqrt(t.a * t.a + t.b * t.b)
        // 좌우로 뒤집힌 변형이면 기울기도 뒤집힌 쪽에서 잰다 (그대로 재면 π가 되어 모자가 거꾸로 선다)
        let mirrored = t.a * t.d - t.b * t.c < 0
        let tilt = mirrored ? atan2(-t.b, -t.a) : atan2(t.b, t.a)
        let eyes = parts.filter { $0.layer == .eye }
        if let eye = eyes.max(by: { $0.eyeCenter.x < $1.eyeCenter.x })?.eyeCenter {
            let head = parts.filter { $0.layer == .base && $0.fill && $0.path.boundingBoxOfPath.contains(eye) }
                .min { $0.path.boundingBoxOfPath.width * $0.path.boundingBoxOfPath.height
                    < $1.path.boundingBoxOfPath.width * $1.path.boundingBoxOfPath.height }?
                .path.boundingBoxOfPath
                ?? CGRect(x: eye.x - 3, y: eye.y - 3, width: 6, height: 6)
            // 눈 높이를 지나는 부품 가운데 가장 높은 곳이 정수리다 (고래처럼 눈이 몸 가운데 있으면 몸 위쪽)
            let crown = parts.filter { part in
                let box = part.path.boundingBoxOfPath
                return part.layer == .base && part.fill && box.minX <= eye.x && box.maxX >= eye.x
                    && box.minY <= eye.y && box.maxY >= eye.y
            }.map { $0.path.boundingBoxOfPath.minY }.min() ?? head.minY
            return HeadAnchor(eye: eye.applying(t), top: CGPoint(x: (head.midX + eye.x) / 2, y: crown).applying(t),
                              width: head.width * scale, tilt: tilt)
        }
        // 그림 러너의 맨 위는 귀·머리카락 끝이라 모자를 조금 내려 머리에 얹는다
        if let part = parts.first(where: { $0.image != nil }), let image = part.image, let found = ImageEyes.find(in: image) {
            let r = part.imageRect
            let eye = CGPoint(x: r.minX + found.center.x * r.width, y: r.minY + found.center.y * r.height)
            let top = CGPoint(x: eye.x, y: bounds.minY + bounds.height * 0.1)
            return HeadAnchor(eye: eye.applying(t), top: top.applying(t), width: bounds.width * 0.45 * scale, tilt: tilt,
                              eyeSpan: found.span * r.width * scale)
        }
        let top = CGPoint(x: bounds.midX + bounds.width * 0.08, y: bounds.minY + bounds.height * 0.1)
        let eye = CGPoint(x: top.x + bounds.width * 0.1, y: bounds.minY + bounds.height * 0.28)
        return HeadAnchor(eye: eye.applying(t), top: top.applying(t), width: bounds.width * 0.45 * scale, tilt: tilt,
                          hasEyes: false)
    }

    /// 변형한 몸이 `range`(설계 y) 위아래로 나가면 줄이고 옮겨 안에 넣는다.
    mutating func fit(verticallyIn range: ClosedRange<CGFloat>) {
        fit = .identity
        fit = Self.fitTransform(for: placedBounds, in: range)
    }

    /// 미리 구한 맞춤을 그대로 건다 (반복 동작은 클립 전체에 같은 맞춤을 써야 크기가 출렁이지 않는다).
    mutating func apply(fit transform: CGAffineTransform) {
        fit = transform
    }

    /// `placed`를 `range` 안에 넣는 변환. 위로 넘치면 바닥을 기준으로 줄여 뜬 높이도 함께 줄이고
    /// (깡충·공중제비가 제자리에 붙어 버리지 않게), 아래로 넘치면(꾸벅·뒤척) 위로 옮긴다.
    /// 좌우는 달려 나갔다 오는 장난이 있어 두지 않는다.
    static func fitTransform(for placed: CGRect, in range: ClosedRange<CGFloat>) -> CGAffineTransform {
        let tolerance: CGFloat = 0.02
        guard placed.height > 0,
              placed.minY < range.lowerBound - tolerance || placed.maxY > range.upperBound + tolerance
        else { return .identity }
        var s = min(1, (range.upperBound - range.lowerBound) / placed.height)
        if placed.minY < range.lowerBound {
            s = min(s, (Stage.ground - range.lowerBound) / max(Stage.ground - placed.minY, 0.01))
        }
        let t = CGAffineTransform(translationX: placed.midX, y: Stage.ground)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -placed.midX, y: -Stage.ground)
        let scaled = placed.applying(t)
        let dy = scaled.maxY > range.upperBound ? range.upperBound - scaled.maxY
            : (scaled.minY < range.lowerBound ? range.lowerBound - scaled.minY : 0)
        return t.concatenating(CGAffineTransform(translationX: 0, y: dy))
    }

    /// 바닥 중심을 기준으로 회전·반전·찌그러짐을 건다.
    var affine: CGAffineTransform {
        let pivot = CGPoint(bounds.isNull ? Stage.size.width / 2 : bounds.midX,
                            transform.pivotAtCenter && !bounds.isNull ? bounds.midY : Stage.ground)
        let stretch = 1 / sqrt(max(transform.squash, 0.01))
        return CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(scaleX: transform.scaleX * stretch, y: transform.squash))
            .concatenating(CGAffineTransform(rotationAngle: transform.rotation))
            .concatenating(CGAffineTransform(translationX: pivot.x + transform.offset.x,
                                             y: pivot.y + transform.offset.y))
            .concatenating(fit)
    }

    func draw(in cg: CGContext, look baseLook: CharacterLook) {
        guard !parts.isEmpty else { return }
        var look = baseLook
        cg.saveGState()
        if !look.rich {
            // labelColor는 반투명이라 부품이 겹친 곳만 진해진다. 불투명하게 그리고 레이어 전체에 투명도를 한 번 준다.
            let resolved = look.tint.usingColorSpace(.sRGB) ?? look.tint
            cg.setAlpha(resolved.alphaComponent)
            look.tint = resolved.withAlphaComponent(1)
        }
        cg.concatenate(affine)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        // 눈 구멍(단색)과 명암이 배경까지 지우거나 덮지 않도록 레이어 안에서 그린다.
        cg.beginTransparencyLayer(auxiliaryInfo: nil)

        let base = parts.filter { $0.layer == .base }
        let hasImage = base.contains { $0.image != nil }
        if look.rich {
            for part in base where !part.ownOutline && part.image == nil { outline(part, cg, look) }
        }
        for part in base {
            if let image = part.image {
                drawImage(image, part: part, cg, look)
                continue
            }
            if look.rich && part.ownOutline { outline(part, cg, look) }
            paint(part, cg, look)
        }
        if look.rich {
            for part in parts where part.layer == .detail { paint(part, cg, look) }
        }
        for part in parts where part.layer == .eye { eye(part, cg, look) }

        if look.rich && !hasImage { shade(cg) }
        if look.alarm && look.rich {
            cg.setBlendMode(.sourceAtop)
            // 그림 러너는 많이 덮으면 누군지 알아볼 수 없다
            cg.setFillColor(NSColor.systemRed.withAlphaComponent(hasImage ? 0.38 : 0.55).cgColor)
            cg.fill(bounds.insetBy(dx: -2, dy: -2))
        }
        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    private static let outlineColor = NSColor(hex: 0x2A2438).cgColor

    /// 내 러너 그림. 단색 테마(실루엣)면 그림의 투명도만 살려 테마색으로 칠한다.
    private func drawImage(_ image: CGImage, part: Part, _ cg: CGContext, _ look: CharacterLook) {
        let rect = part.imageRect
        cg.saveGState()
        cg.translateBy(x: rect.midX, y: rect.maxY)
        cg.rotate(by: part.imageRotation)
        cg.translateBy(x: -rect.width / 2, y: 0)
        cg.scaleBy(x: 1, y: -1)   // y 아래 좌표라 그림을 뒤집어 그린다
        // 작은 원본(도트 그림)은 부드럽게 키우면 뭉개진다
        cg.interpolationQuality = image.height < 80 ? .none : .high
        let box = CGRect(origin: .zero, size: rect.size)
        if look.rich, let tint = look.palette.imageTint {
            // 명암은 그림 그대로 두고 색상만 바꾼다. 그림 밖으로 색이 번지지 않게 그림 모양으로 자른다
            // 그림의 알파로 자른다. 칠한 뒤 destinationIn으로 다시 잘라 내면 상자 가장자리에 옅은 테두리가 남는다
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.draw(image, in: box)
            cg.clip(to: box, mask: image)
            cg.setBlendMode(.color)
            cg.setFillColor(tint.withAlphaComponent(0.85).cgColor)
            cg.fill(box)
            cg.endTransparencyLayer()
        } else if look.rich {
            cg.draw(image, in: box)
        } else {
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.draw(image, in: box)
            cg.setBlendMode(.sourceIn)
            cg.setFillColor(look.tint.cgColor)
            cg.fill(box)
            cg.endTransparencyLayer()
        }
        cg.restoreGState()
    }

    private func outline(_ part: Part, _ cg: CGContext, _ look: CharacterLook) {
        guard look.color(part.role, far: part.far) != nil else { return }
        cg.setFillColor(Self.outlineColor)
        cg.setStrokeColor(Self.outlineColor)
        if part.fill {
            cg.addPath(part.path)
            cg.fillPath()
        }
        cg.setLineWidth(part.stroke + look.outline * 2)
        cg.addPath(part.path)
        cg.strokePath()
    }

    private func paint(_ part: Part, _ cg: CGContext, _ look: CharacterLook) {
        guard let color = look.color(part.role, far: part.far)?.cgColor else { return }
        if part.fill {
            cg.setFillColor(color)
            cg.addPath(part.path)
            cg.fillPath()
        }
        if part.stroke > 0 {
            cg.setStrokeColor(color)
            cg.setLineWidth(part.stroke)
            cg.addPath(part.path)
            cg.strokePath()
        }
    }

    private func eye(_ part: Part, _ cg: CGContext, _ look: CharacterLook) {
        let c = part.eyeCenter
        let r = part.eyeRadius
        let eyes = pose.eyes
        cg.saveGState()
        if !look.rich { cg.setBlendMode(.destinationOut) }   // 단색: 몸에 구멍을 내 눈을 표현
        let ink = look.rich ? NSColor(hex: 0x231F2E).cgColor : NSColor.black.cgColor
        switch eyes {
        case .open:
            cg.setFillColor(ink)
            let ry = r * (look.rich ? 1.18 : 1.0)
            let rx = look.rich ? r : r * 0.9
            cg.fillEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
            if look.rich {
                cg.setFillColor(NSColor.white.cgColor)
                let h = r * 0.46
                cg.fillEllipse(in: CGRect(x: c.x + r * 0.32 - h, y: c.y - r * 0.42 - h, width: h * 2, height: h * 2))
                let s = r * 0.2
                cg.fillEllipse(in: CGRect(x: c.x - r * 0.35 - s, y: c.y + r * 0.42 - s, width: s * 2, height: s * 2))
            }
        case .closed, .happy:
            cg.setStrokeColor(ink)
            cg.setLineWidth(max(r * 0.55, 0.45))
            cg.setLineCap(.round)
            let dip: CGFloat = eyes == .closed ? r * 0.8 : -r * 1.1
            let baseY = eyes == .closed ? c.y : c.y + r * 0.45
            cg.move(to: CGPoint(c.x - r, baseY))
            cg.addQuadCurve(to: CGPoint(c.x + r, baseY), control: CGPoint(c.x, baseY + dip))
            cg.strokePath()
        }
        cg.restoreGState()
    }

    /// 위는 밝게, 아래는 어둡게. 이미 그린 픽셀 위에만 얹는다.
    private func shade(_ cg: CGContext) {
        guard !bounds.isNull,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                NSColor.white.withAlphaComponent(0.30).cgColor,
                NSColor.white.withAlphaComponent(0.0).cgColor,
                NSColor.black.withAlphaComponent(0.0).cgColor,
                NSColor.black.withAlphaComponent(0.20).cgColor,
              ] as CFArray, locations: [0, 0.42, 0.6, 1])
        else { return }
        cg.saveGState()
        cg.setBlendMode(.sourceAtop)
        cg.drawLinearGradient(gradient, start: CGPoint(bounds.midX, bounds.minY),
                              end: CGPoint(bounds.midX, bounds.maxY), options: [])
        cg.restoreGState()
    }
}
