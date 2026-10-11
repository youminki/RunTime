import CoreGraphics

/// 그림 러너(Petdex, 내 그림)의 눈 자리. 먼저 흰자에 닿은 검은 눈동자 무리를 찾고, 흰자가 없는 그림은
/// 밝은 얼굴에 둘러싸인 작은 어두운 덩어리를 눈으로 본다. 외곽선과 머리카락은 둘레가 어둡거나 투명해서 걸러진다.
/// 못 찾으면 nil이라 얼굴 꾸미기를 씌우지 않는다. 메인 스레드에서만 쓴다.
enum ImageEyes {
    struct Found {
        /// 두 눈 가운데 (또는 한 눈). 그림 크기에 대한 비율, 위가 0.
        let center: CGPoint
        /// 두 눈 사이 거리 (그림 폭에 대한 비율). 한 눈만 보이면 어림값.
        let span: CGFloat
    }

    private final class Entry {
        weak var image: CGImage?
        let found: Found?
        /// 알파가 있는 영역 (그림 크기에 대한 비율, 위가 0).
        let box: CGRect
        init(image: CGImage, found: Found?, box: CGRect) {
            self.image = image
            self.found = found
            self.box = box
        }
    }

    /// 한 동작 줄의 프레임들. 프레임마다 찾은 눈을 그림 영역에 대한 자리로 바꿔 가운데값을 쓴다.
    /// 한두 프레임에서 잘못 찾아도 안경이 튀지 않고, 영역을 따라 같이 움직인다.
    private final class Group {
        let images: [CGImage]
        lazy var consensus: Found? = ImageEyes.consensus(images)
        init(_ images: [CGImage]) { self.images = images }
    }

    private static var cache: [ObjectIdentifier: Entry] = [:]
    private static var groups: [ObjectIdentifier: Group] = [:]

    /// 같은 동작의 프레임을 한 무리로 알려 둔다 (시트 러너가 줄을 읽을 때).
    static func register(_ images: [CGImage]) {
        let group = Group(images)
        for image in images { groups[ObjectIdentifier(image)] = group }
    }

    static func forget(_ images: [CGImage]) {
        for image in images {
            groups[ObjectIdentifier(image)] = nil
            cache[ObjectIdentifier(image)] = nil
        }
    }

    static func find(in image: CGImage) -> Found? {
        let key = ObjectIdentifier(image)
        if let group = groups[key], group.images.contains(where: { $0 === image }) {
            guard let rel = group.consensus else { return nil }
            let box = entry(image).box
            return Found(center: CGPoint(x: box.minX + rel.center.x * box.width, y: box.minY + rel.center.y * box.height),
                         span: rel.span * box.width)
        }
        return entry(image).found
    }

    private static func entry(_ image: CGImage) -> Entry {
        let key = ObjectIdentifier(image)
        if let entry = cache[key], entry.image === image { return entry }
        let entry = Entry(image: image, found: detect(image), box: SheetFrames.content(of: image))
        // 지운 내 러너의 그림처럼 이미 풀린 그림 자리는 가끔 비운다
        if cache.count > 256 { cache = cache.filter { $0.value.image != nil } }
        cache[key] = entry
        return entry
    }

    /// 프레임 절반 넘게에서 찾았을 때만, 그림 영역에 대한 자리의 가운데값.
    private static func consensus(_ images: [CGImage]) -> Found? {
        let rel = images.compactMap { image -> (CGFloat, CGFloat, CGFloat)? in
            let e = entry(image)
            guard let f = e.found, e.box.width > 0, e.box.height > 0 else { return nil }
            return ((f.center.x - e.box.minX) / e.box.width, (f.center.y - e.box.minY) / e.box.height, f.span / e.box.width)
        }
        guard rel.count * 2 > images.count else { return nil }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        return Found(center: CGPoint(x: median(rel.map(\.0)), y: median(rel.map(\.1))), span: median(rel.map(\.2)))
    }

    private struct Blob {
        let x, y: CGFloat
        let area: Int
        let score: Int
    }

    /// 흰자(무채색에 가까운 아주 밝은 색) 옆에 붙은 어두운 픽셀을 모아, 많이 모인 두 무리(또는 한 무리)를 눈으로 본다.
    private static func scleraEyes(w: Int, h: Int, minX: Int, maxX: Int, minY: Int, boxW: Int, boxH: Int,
                                   alpha: (Int, Int) -> Int, luma: (Int, Int) -> Int,
                                   rgb: (Int) -> (Int, Int, Int)) -> Found? {
        func white(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < w, y < h, alpha(x, y) > 200 else { return false }
            let (r, g, b) = rgb((y * w + x) * 4)
            return luma(x, y) > 215 && max(r, g, b) - min(r, g, b) < 35
        }
        // 몸이 흰 그림(흰 고양이 등)은 흰자를 가려낼 수 없다
        var opaque = 0, whites = 0
        for y in minY...(minY + boxH * 65 / 100) { for x in minX...maxX where alpha(x, y) > 200 {
            opaque += 1
            if white(x, y) { whites += 1 }
        } }
        guard whites * 3 < opaque else { return nil }
        var points: [(x: Int, y: Int)] = []
        for y in minY...(minY + boxH * 65 / 100) { for x in minX...maxX where alpha(x, y) > 200 && luma(x, y) < 90 {
            var touches = false
            for dy in -2...2 where !touches { for dx in -2...2 where white(x + dx, y + dy) { touches = true; break } }
            if touches { points.append((x, y)) }
        } }
        // 선이 빽빽한 그림은 흰자를 가려낼 수 없고, 무리 짓기가 점 수의 제곱이라 그리는 중에 멈칫한다
        guard points.count >= 4, points.count <= 1500 else { return nil }
        // 가까운 점끼리 한 무리로 묶는다
        let reach = max(3, boxW / 20)
        var group = [Int](repeating: -1, count: points.count)
        var groups: [[Int]] = []
        for start in points.indices where group[start] < 0 {
            var stack = [start], members: [Int] = []
            group[start] = groups.count
            while let i = stack.popLast() {
                members.append(i)
                for j in points.indices where group[j] < 0
                    && abs(points[j].x - points[i].x) <= reach && abs(points[j].y - points[i].y) <= reach {
                    group[j] = groups.count
                    stack.append(j)
                }
            }
            groups.append(members)
        }
        let clusters = groups.filter { $0.count >= 4 }.map { members -> (x: CGFloat, y: CGFloat, n: Int) in
            (CGFloat(members.reduce(0) { $0 + points[$1].x }) / CGFloat(members.count),
             CGFloat(members.reduce(0) { $0 + points[$1].y }) / CGFloat(members.count), members.count)
        }.filter { $0.n * 4 >= clusters(maxOf: groups) }
        guard let strongest = clusters.max(by: { $0.n < $1.n }) else { return nil }
        var pair: (CGFloat, CGFloat, CGFloat)?
        var pairScore = 0
        for (i, a) in clusters.enumerated() { for b in clusters[(i + 1)...] {
            let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
            guard dy < CGFloat(boxH) * 0.1, dx > CGFloat(boxW) * 0.06, dx < CGFloat(boxW) * 0.5,
                  min(a.n, b.n) > pairScore else { continue }
            pair = ((a.x + b.x) / 2, (a.y + b.y) / 2, dx)
            pairScore = min(a.n, b.n)
        } }
        if let (x, y, dx) = pair, pairScore * 3 >= strongest.n {
            return Found(center: CGPoint(x: x / CGFloat(w), y: y / CGFloat(h)), span: dx / CGFloat(w))
        }
        return Found(center: CGPoint(x: strongest.x / CGFloat(w), y: strongest.y / CGFloat(h)),
                     span: CGFloat(boxW) * 0.16 / CGFloat(w))
    }

    private static func clusters(maxOf groups: [[Int]]) -> Int { groups.map(\.count).max() ?? 0 }

    private static func detect(_ image: CGImage) -> Found? {
        let w = image.width, h = image.height
        guard w > 8, h > 8, w * h <= 1_000_000,
              let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = cg.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 비트맵 메모리는 첫 줄이 그림의 맨 위다
        func alpha(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4 + 3]) }
        func luma(_ x: Int, _ y: Int) -> Int {
            let i = (y * w + x) * 4
            return (299 * Int(px[i]) + 587 * Int(px[i + 1]) + 114 * Int(px[i + 2])) / 1000
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where alpha(x, y) > 40 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX > minX + 6, maxY > minY + 6 else { return nil }
        let boxW = maxX - minX + 1, boxH = maxY - minY + 1
        let headBottom = minY + boxH * 6 / 10
        func interior(_ x: Int, _ y: Int) -> Bool {
            guard x >= 2, y >= 2, x < w - 2, y < h - 2 else { return false }
            for dy in -2...2 { for dx in -2...2 where alpha(x + dx, y + dy) < 180 { return false } }
            return true
        }
        if let found = scleraEyes(w: w, h: h, minX: minX, maxX: maxX, minY: minY, boxW: boxW, boxH: boxH,
                                  alpha: alpha, luma: luma, rgb: { i in (Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }) {
            return found
        }
        var dark = [Bool](repeating: false, count: w * h)
        for y in minY...headBottom { for x in minX...maxX where luma(x, y) < 80 && interior(x, y) { dark[y * w + x] = true } }

        var seen = [Bool](repeating: false, count: w * h)
        var blobs: [Blob] = []
        let maxArea = max(4, boxW * boxH / 80)
        for start in 0..<(w * h) where dark[start] && !seen[start] {
            var stack = [start], members: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if dark[j] && !seen[j] { seen[j] = true; stack.append(j) }
                } }
            }
            guard members.count >= 2, members.count <= maxArea else { continue }
            let xs = members.map { $0 % w }, ys = members.map { $0 / w }
            let bx0 = xs.min()!, bx1 = xs.max()!, by0 = ys.min()!, by1 = ys.max()!
            guard bx1 - bx0 < boxW / 4, by1 - by0 < boxH / 5 else { continue }
            // 둘레 3px의 밝기. 눈은 밝은 얼굴(흰자·살색)에 둘러싸여 있다
            let inside = Set(members)
            var ring = 0, ringCount = 0
            for y in max(0, by0 - 3)...min(h - 1, by1 + 3) { for x in max(0, bx0 - 3)...min(w - 1, bx1 + 3)
                where !inside.contains(y * w + x) && alpha(x, y) > 180 {
                ring += luma(x, y); ringCount += 1
            } }
            guard ringCount > 0 else { continue }
            let inner = members.reduce(0) { $0 + luma($1 % w, $1 / w) } / members.count
            let score = ring / ringCount - inner
            guard ring / ringCount > 130, score > 70 else { continue }
            blobs.append(Blob(x: CGFloat(xs.reduce(0, +)) / CGFloat(members.count),
                              y: CGFloat(ys.reduce(0, +)) / CGFloat(members.count), area: members.count, score: score))
        }
        guard !blobs.isEmpty else { return nil }
        var best: (Blob, Blob)?
        var bestScore = 0
        for (i, a) in blobs.enumerated() { for b in blobs[(i + 1)...] {
            let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
            guard dy < CGFloat(boxH) * 0.08, dx > CGFloat(boxW) * 0.06, dx < CGFloat(boxW) * 0.45,
                  max(a.area, b.area) <= min(a.area, b.area) * 3, a.score + b.score > bestScore else { continue }
            best = (a, b)
            bestScore = a.score + b.score
        } }
        if let (a, b) = best {
            return Found(center: CGPoint(x: (a.x + b.x) / 2 / CGFloat(w), y: (a.y + b.y) / 2 / CGFloat(h)),
                         span: abs(a.x - b.x) / CGFloat(w))
        }
        let one = blobs.max { $0.score < $1.score }!
        return Found(center: CGPoint(x: one.x / CGFloat(w), y: one.y / CGFloat(h)), span: CGFloat(boxW) * 0.16 / CGFloat(w))
    }
}
