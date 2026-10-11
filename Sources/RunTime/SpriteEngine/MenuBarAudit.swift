import AppKit

/// 메뉴바 러너 점검 (`--menubar-audit <폴더> [화면 배율] [메뉴바 높이] [크기 배율]`).
/// 모든 러너의 반복 동작과 장난을 메뉴바와 같은 칸·래스터로 그려 잘림(칸 가장자리에 닿은 픽셀), 서 있는 키,
/// 어두운 메뉴바에 묻히는 정도를 재고, 실제 크기 그대로의 모습을 확대한 시트를 남긴다.
enum MenuBarAudit {
    struct Entry {
        let id: String
        let character: RunnerCharacter
    }

    struct Result {
        let id: String
        let name: String
        /// 칸 가장자리(위·아래·왼쪽·오른쪽)에 닿은 픽셀 수의 최댓값과 그 동작.
        var edges = [0, 0, 0, 0]
        var edgeClips = ["", "", "", ""]
        var standHeight = 0
        var standWidth = 0
        /// 서 있는 모습의 테두리 픽셀 중 어두운 비율 (어두운 메뉴바에서 묻힌다).
        var darkOutline: Double = 0
    }

    static func entries() -> [Entry] {
        Runner.allCases.map { Entry(id: $0.rawValue, character: $0.character) }
            + PetdexStore.shared.pets.compactMap { pet in
                PetdexStore.shared.character(for: pet).map { Entry(id: PetdexStore.storageID(pet.slug), character: $0) }
            }
            + CustomRunnerStore.shared.runners.map { Entry(id: $0.id, character: $0.character) }
    }

    static func run(to directory: URL, canvas: MenuBarCanvas) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dark = NSAppearance(named: .darkAqua)
        var results: [Result] = []
        var rows: [(String, [CGImage])] = []
        for entry in entries() {
            let character = entry.character
            let theme = character.theme(.auto)
            var result = Result(id: entry.id, name: character.name)
            // 잘림은 효과를 빼고 캐릭터만 그려 잰다
            func measure(_ frame: MotionFrame, _ label: String,
                         fit: SpriteFrames.SceneFit = .each(canvas.visibleY)) -> CGImage? {
                var bare = frame
                bare.effects = []
                let image = SpriteFrames.image { cg in
                    SpriteFrames.render(cg, rig: character.rig, frame: bare, theme: theme, themePhase: 0,
                                        alarm: false, fit: fit) { _, _, _, _ in }
                }
                guard let raster = SpriteRasterizer.cgImage(image, canvas: canvas, appearance: dark),
                      let stats = Stats(raster) else { return nil }
                for (i, count) in stats.edges.enumerated() where count > result.edges[i] {
                    result.edges[i] = count
                    result.edgeClips[i] = label
                }
                return raster
            }
            let displays: [SpriteDisplay] = [.normal(.sleeping), .normal(.walking), .normal(.running), .normal(.dashing),
                                             .normal(.rainbow), .tired, .alert]
            for display in displays {
                let fit = SpriteFrames.loopFit(display, rig: character.rig, range: canvas.visibleY, count: 12)
                for i in 0..<12 { _ = measure(display.motion(at: CGFloat(i) / 12), display.key, fit: .fixed(fit)) }
            }
            for trick in Trick.allCases {
                for i in 0...16 { _ = measure(trick.frame(at: CGFloat(i) / 16), trick.rawValue) }
            }
            if let stand = measure(MotionFrame(pose: CharacterPose(activity: .stand)), "stand"),
               let stats = Stats(stand) {
                result.standHeight = stats.height
                result.standWidth = stats.width
                result.darkOutline = stats.darkOutline
            }
            results.append(result)

            // 시트: 실제로 보이는 모습 (효과와 테두리 포함)
            let halo = SpriteAnimator.halo(theme: theme, appearance: dark)
            var wave = CharacterPose(activity: .stand)
            wave.wave = 0.4
            let frames: [(SpriteDisplay?, MotionFrame)] = [
                (nil, MotionFrame(pose: CharacterPose(activity: .stand))),
                (.normal(.running), SpriteDisplay.normal(.running).motion(at: 0.25)),
                (.normal(.rainbow), SpriteDisplay.normal(.rainbow).motion(at: 0.6)),
                (.tired, SpriteDisplay.tired.motion(at: 0.3)),
                (.normal(.sleeping), SpriteDisplay.normal(.sleeping).motion(at: 0.3)),
                (.alert, SpriteDisplay.alert.motion(at: 0.1)),
                (nil, MotionFrame(pose: wave)),
                (nil, Trick.dance.frame(at: 0.42)),
                (nil, Trick.flip.frame(at: 0.5)),
            ]
            let cells = frames.compactMap { display, frame -> CGImage? in
                let image = SpriteFrames.image { cg in
                    let fit = display.map {
                        SpriteFrames.SceneFit.fixed(SpriteFrames.loopFit($0, rig: character.rig, range: canvas.visibleY,
                                                                         count: 12))
                    } ?? .each(canvas.visibleY)
                    SpriteFrames.render(cg, rig: character.rig, frame: frame, theme: theme, themePhase: 0,
                                        alarm: display == .alert, fit: fit) { cg, scene, tint, front in
                        display?.drawLoopEffects(in: cg, scene: scene, phase: 0.3, tint: tint, front: front)
                    }
                }
                return SpriteRasterizer.cgImage(image, canvas: canvas, appearance: dark, halo: halo)
            }
            rows.append((character.name, cells))
        }

        var report = "id\tname\ttop\tbottom\tleft\tright\tclips(top/bottom/left/right)\tstandH\tstandW\tdarkOutline\n"
        for r in results {
            report += "\(r.id)\t\(r.name)\t\(r.edges.map(String.init).joined(separator: "\t"))\t"
                + "\(r.edgeClips.joined(separator: "/"))\t\(r.standHeight)\t\(r.standWidth)\t"
                + String(format: "%.2f", r.darkOutline) + "\n"
        }
        try report.write(to: directory.appendingPathComponent("report.tsv"), atomically: true, encoding: .utf8)
        for (page, start) in stride(from: 0, to: rows.count, by: 30).enumerated() {
            let slice = Array(rows[start..<min(start + 30, rows.count)])
            try sheet(slice, canvas: canvas).write(to: directory.appendingPathComponent("sheet-\(page).png"))
        }
    }

    /// 칸을 3배로 키워(이웃 픽셀 그대로) 어두운 메뉴바 색 위에 늘어놓는다.
    private static func sheet(_ rows: [(String, [CGImage])], canvas: MenuBarCanvas) -> Data {
        let zoom = 3, label = 130, gap = 6
        let cellW = canvas.pixelWidth * zoom, cellH = canvas.pixelHeight * zoom
        let columns = rows.map(\.1.count).max() ?? 1
        let width = label + columns * (cellW + gap), height = rows.count * (cellH + gap)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.interpolationQuality = .none
        for (i, row) in rows.enumerated() {
            let y = height - (i + 1) * (cellH + gap)
            (row.0 as NSString).draw(at: NSPoint(x: 6, y: y + cellH / 2 - 8),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white])
            for (j, image) in row.1.enumerated() {
                let rect = CGRect(x: label + j * (cellW + gap), y: y, width: cellW, height: cellH)
                cg.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
                cg.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
                cg.draw(image, in: rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// 래스터 한 장의 알파 통계.
    private struct Stats {
        var edges = [0, 0, 0, 0]
        var width = 0
        var height = 0
        var darkOutline: Double = 0

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let p = cg.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            func alpha(_ x: Int, _ y: Int) -> UInt8 { p[(y * w + x) * 4 + 3] }
            let solid: UInt8 = 64
            var minX = w, minY = h, maxX = -1, maxY = -1
            var outline = 0, darkCount = 0
            for y in 0..<h {
                for x in 0..<w where alpha(x, y) >= solid {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    if y == 0 { edges[0] += 1 }
                    if y == h - 1 { edges[1] += 1 }
                    if x == 0 { edges[2] += 1 }
                    if x == w - 1 { edges[3] += 1 }
                    let border = x == 0 || y == 0 || x == w - 1 || y == h - 1
                        || alpha(x - 1, y) < solid || alpha(x + 1, y) < solid || alpha(x, y - 1) < solid || alpha(x, y + 1) < solid
                    guard border else { continue }
                    outline += 1
                    let i = (y * w + x) * 4
                    let a = Double(p[i + 3]) / 255
                    let luma = (0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])) / 255 / a
                    if luma < 0.22 { darkCount += 1 }
                }
            }
            if maxX >= minX {
                width = maxX - minX + 1
                height = maxY - minY + 1
            }
            darkOutline = outline > 0 ? Double(darkCount) / Double(outline) : 0
        }
    }
}
