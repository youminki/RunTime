import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 자세별 프레임 PNG가 든 폴더로 그리는 러너 (Petdex 펫).
/// 폴더에는 `frames.json`과 `idle_0.png`, `run_0.png`, `sad_0.png`, `wait_0.png`, `wave_0.png` … 가 있다.
/// 서 있기·달리기 칸(`w`×`h`)이 기준 크기이고, 그보다 넓은 줄(누운 자세 등)은 `rects`의 자리에 같은 배율로 그린다.
struct SheetRig: CharacterRig {
    let folder: URL
    let palette = CharacterPalette(body: .white, belly: .white, dark: .black)
    private let meta: SheetFrames.Meta

    init?(folder: URL) {
        guard let meta = SheetFrames.meta(folder) else { return nil }
        self.folder = folder
        self.meta = meta
    }

    func draw(_ s: Sketch) {
        let pose = s.pose
        // 원하는 줄이 비었으면 뒤의 줄을 쓴다
        let order: [String]
        switch pose.activity {
        case .walk, .run: order = ["run", "idle"]
        case .stand: order = pose.wave == nil ? ["idle", "run"] : ["wave", "idle", "run"]
        case .sit: order = ["sad", "run", "idle"]     // 한도 80% 이상 지침
        case .sleep: order = ["wait", "run", "idle"]
        }
        guard let (row, frames) = SheetFrames.frames(folder, rows: order) else { return }
        let cycle = row == "wave" ? (pose.wave ?? 0) - floor(pose.wave ?? 0) : pose.cycle
        let image = frames.images[min(Int(cycle * CGFloat(frames.images.count)), frames.images.count - 1)]
        // 출력 1px이 차지할 설계 단위. 기준 칸의 키를 목표 키에 맞춘다.
        let unit = FittedRig.targetHeight / CGFloat(max(meta.h, 1))
        let base = CGRect(x: FittedRig.targetCenterX - CGFloat(meta.w) * unit / 2, y: Stage.ground - FittedRig.targetHeight,
                          width: CGFloat(meta.w) * unit, height: FittedRig.targetHeight)
        let rect = meta.rects?[row].flatMap { r in
            r.count == 4 ? CGRect(x: base.minX + CGFloat(r[0]) * unit, y: base.minY + CGFloat(r[1]) * unit,
                                  width: CGFloat(r[2]) * unit, height: CGFloat(r[3]) * unit) : nil
        } ?? base
        // 크기 맞춤과 효과 위치는 투명한 여백을 뺀 그림 영역으로 잰다. 줄마다 하나라 프레임끼리 흔들리지 않는다.
        let c = frames.content
        let content = CGRect(x: rect.minX + c.minX * rect.width, y: rect.minY + c.minY * rect.height,
                             width: c.width * rect.width, height: c.height * rect.height)
        s.add(Part(path: CGPath(rect: content, transform: nil), fill: false, stroke: 0, role: .body,
                   image: image, imageRect: rect))
    }
}

/// 시트 러너 프레임 캐시. 메인 스레드에서만 쓴다.
/// 줄을 처음 쓸 때 프레임마다 그림 영역을 재어 합친다. 잴 때 푼 픽셀은 버리고, 그린 프레임만 풀린 채 남는다.
enum SheetFrames {
    struct Meta: Codable {
        let w: Int
        let h: Int
        let counts: [String: Int]
        /// 기준 칸과 자리가 다른 줄의 [x, y, w, h]. 기준 칸의 왼쪽 위에서 잰 출력 픽셀이다.
        var rects: [String: [Int]]?
    }

    /// 한 줄의 프레임과, 모든 프레임에서 그림이 있는 영역을 합친 것 (이미지 크기에 대한 비율, 위가 0).
    struct Row {
        let images: [CGImage]
        let content: CGRect
    }

    static let rows = ["idle", "run", "sad", "wait", "wave"]

    private static var metas: [URL: Meta] = [:]
    private static var cache: [String: Row] = [:]

    static func meta(_ folder: URL) -> Meta? {
        dispatchPrecondition(condition: .onQueue(.main))
        if let meta = metas[folder] { return meta }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("frames.json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        metas[folder] = meta
        return meta
    }

    /// `rows` 순서대로 보며 프레임이 있는 첫 줄. 손 흔들기 줄이 생기기 전에 받은 펫은 그 줄이 없다.
    static func frames(_ folder: URL, rows: [String]) -> (row: String, frames: Row)? {
        guard let meta = meta(folder) else { return nil }
        for row in rows where (meta.counts[row] ?? 0) > 0 {
            let key = "\(folder.path)/\(row)"
            if let cached = cache[key] {
                if cached.images.isEmpty { continue }   // PNG를 못 읽은 줄
                return (row, cached)
            }
            var images: [CGImage] = []
            var content = CGRect.null
            for i in 0..<(meta.counts[row] ?? 0) {
                guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent("\(row)_\(i).png") as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { continue }
                images.append(image)
                // 재기만 할 그림은 풀린 픽셀을 붙들지 않게 따로 만든다
                let probe = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                content = content.union(Self.content(of: probe ?? image))
            }
            let loaded = Row(images: images, content: content.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : content)
            cache[key] = loaded
            if !images.isEmpty { return (row, loaded) }
        }
        return nil
    }

    /// 알파가 있는 픽셀을 감싸는 사각형. 비어 있으면 그림 전체.
    static func content(of image: CGImage) -> CGRect {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = cg.data?.bindMemory(to: UInt8.self, capacity: w * h * 4)
        else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        // 비트맵 메모리는 첫 줄이 그림의 맨 위다
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                      width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
    }

    /// 폴더를 지우거나 다시 받을 때 캐시도 비운다.
    static func forget(_ folder: URL) {
        metas[folder] = nil
        for row in rows { cache["\(folder.path)/\(row)"] = nil }
    }
}

/// Petdex 스프라이트 시트(192×208 칸, 8열, 9줄 또는 11줄)에서 서 있기(0줄)·달리기(1줄)·손 흔들기(3줄)·슬픔(5줄)·기다리기(6줄)를
/// 뽑아 SheetRig 폴더로 쓴다. 줄 구성은 Petdex 저장소의 src/lib/pet-states.ts, 규격 검사는 src/lib/sprite-atlas.ts를 따른다.
enum PetdexAtlas {
    enum ExtractError: LocalizedError {
        case unsupportedSize
        case empty
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedSize: return "Petdex 시트 규격이 아닙니다."
            case .empty: return "달리는 프레임을 찾지 못했습니다."
            case .saveFailed: return "프레임을 저장하지 못했습니다."
            }
        }
    }

    private static let columns = 8
    private static let cell = (w: 192, h: 208)
    private static let alphaThreshold: UInt8 = 40

    private struct Box {
        var minX: Int, minY: Int, maxX: Int, maxY: Int

        func union(_ other: Box?) -> Box {
            guard let other else { return self }
            return Box(minX: min(minX, other.minX), minY: min(minY, other.minY),
                       maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
        }

        var height: Int { maxY - minY + 1 }
    }

    /// 풀기 전에 크기만 읽어 Petdex 규격(8열, 9줄 또는 11줄, 칸 비율 192:208)인지 본다. 받은 파일이라 크기를 믿지 않는다.
    static func isSupported(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, w % columns == 0, w <= columns * cell.w * 2 else { return false }
        return [9, 11].contains { rows in h % rows == 0 && w * rows * cell.h == h * columns * cell.w }
    }

    static func extract(from source: CGImageSource, to folder: URL) throws {
        guard isSupported(source), let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExtractError.unsupportedSize
        }
        let W = sheet.width, H = sheet.height
        let cellW = W / columns, cellH = cellW * cell.h / cell.w
        guard let context = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: W * H * 4)
        else { throw ExtractError.saveFailed }
        context.draw(sheet, in: CGRect(x: 0, y: 0, width: W, height: H))

        // 비트맵 메모리는 첫 줄이 그림의 맨 위다
        func box(row: Int, column: Int) -> Box? {
            var found: Box?
            for y in row * cellH ..< min((row + 1) * cellH, H) {
                for x in column * cellW ..< min((column + 1) * cellW, W) where pixels[(y * W + x) * 4 + 3] > alphaThreshold {
                    found = Box(minX: x - column * cellW, minY: y - row * cellH,
                                maxX: x - column * cellW, maxY: y - row * cellH).union(found)
                }
            }
            return found
        }
        func scan(_ row: Int) -> (columns: [Int], box: Box?) {
            guard (row + 1) * cellH <= H else { return ([], nil) }
            var used: [Int] = []
            var total: Box?
            for column in 0..<columns {
                guard let b = box(row: row, column: column) else { continue }
                used.append(column)
                total = b.union(total)
            }
            return (used, total)
        }

        // 달리기 줄이 비었으면 제자리 달리기(7줄), 그것도 없으면 왼쪽 달리기(2줄)를 뒤집어 쓴다
        var sources: [String: (row: Int, mirrored: Bool)] = ["idle": (0, false), "sad": (5, false), "wait": (6, false),
                                                             "wave": (3, false)]
        var scanned: [String: (columns: [Int], box: Box?)] = [:]
        for name in ["idle", "sad", "wait", "wave"] { scanned[name] = scan(sources[name]!.row) }
        for (row, mirrored) in [(1, false), (7, false), (2, true)] {
            let result = scan(row)
            if result.box != nil {
                sources["run"] = (row, mirrored)
                scanned["run"] = result
                break
            }
        }
        guard var runBox = scanned["run"]?.box else { throw ExtractError.empty }
        if sources["run"]!.mirrored {
            runBox = Box(minX: cellW - 1 - runBox.maxX, minY: runBox.minY, maxX: cellW - 1 - runBox.minX, maxY: runBox.maxY)
        }
        let idleBox = scanned["idle"]?.box
        let shared = runBox.union(idleBox)
        // 줄마다 그린 크기가 다른 시트(달리기만 작게 그린 것 등)는 줄마다 따로 잘라 같은 키로 맞춘다
        let perRow = idleBox.map { Double(runBox.height) < Double($0.height) * 0.8 } ?? false

        func padded(_ b: Box) -> CGRect {
            let x0 = max(b.minX - 2, 0), y0 = max(b.minY - 2, 0)
            let x1 = min(b.maxX + 2, cellW - 1), y1 = min(b.maxY + 2, cellH - 1)
            return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
        }
        let base = padded(shared)
        // 프레임 높이는 내 러너와 같은 기준으로 줄여 메모리를 아낀다
        let frameH = min(CustomRunnerStore.maxFrameHeight, Int(base.height))
        let s = CGFloat(frameH) / base.height
        var frameW = Int((base.width * s).rounded(.up))
        // 줄별로 자를 영역(칸 좌표)과 출력 크기
        var crops: [String: (source: CGRect, size: CGSize)] = [:]
        var rects: [String: [Int]] = [:]
        for name in SheetFrames.rows {
            let rowBox = name == "run" ? runBox : scanned[name]?.box
            if perRow, let rowBox {
                let r = padded(rowBox)
                let k = CGFloat(frameH) / r.height
                crops[name] = (r, CGSize(width: r.width * k, height: CGFloat(frameH)))
                frameW = max(frameW, Int((r.width * k).rounded(.up)))
            } else if !perRow, ["sad", "wait", "wave"].contains(name), let rowBox {
                // 서 있기·달리기보다 넓게 그린 줄(누운 자세, 머리 위 표시, 든 손)은 칸을 넓히되 배율은 그대로 둔다
                let r = padded(shared.union(rowBox))
                crops[name] = (r, CGSize(width: (r.width * s).rounded(.up), height: (r.height * s).rounded(.up)))
                if r != base {
                    rects[name] = [Int(((r.minX - base.minX) * s).rounded()), Int(((r.minY - base.minY) * s).rounded()),
                                   Int((r.width * s).rounded(.up)), Int((r.height * s).rounded(.up))]
                }
            } else {
                crops[name] = (base, CGSize(width: base.width * s, height: CGFloat(frameH)))
            }
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var counts: [String: Int] = [:]
        for name in SheetFrames.rows {
            guard let source = sources[name], let crop = crops[name] else { continue }
            let canvas = rects[name] == nil ? CGSize(width: frameW, height: frameH) : crop.size
            for (i, column) in (scanned[name]?.columns ?? []).enumerated() {
                // 뒤집어 쓰는 줄은 칸 안의 영역도 좌우로 뒤집어 잘라야 같은 자리가 나온다
                var area = crop.source
                if source.mirrored { area.origin.x = CGFloat(cellW) - area.maxX }
                guard let cell = sheet.cropping(to: area.offsetBy(dx: CGFloat(column * cellW), dy: CGFloat(source.row * cellH))),
                      let out = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { continue }
                out.interpolationQuality = .high
                // 아래끝 가운데에 맞춘다
                let target = CGRect(x: (canvas.width - crop.size.width) / 2, y: 0, width: crop.size.width, height: crop.size.height)
                if source.mirrored {
                    out.translateBy(x: canvas.width, y: 0)
                    out.scaleBy(x: -1, y: 1)
                }
                out.draw(cell, in: target)
                guard let image = out.makeImage(),
                      let destination = CGImageDestinationCreateWithURL(
                          folder.appendingPathComponent("\(name)_\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { throw ExtractError.saveFailed }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ExtractError.saveFailed }
                counts[name] = i + 1
            }
        }
        let meta = SheetFrames.Meta(w: frameW, h: frameH, counts: counts, rects: rects.isEmpty ? nil : rects)
        try JSONEncoder().encode(meta).write(to: folder.appendingPathComponent("frames.json"))
    }
}
