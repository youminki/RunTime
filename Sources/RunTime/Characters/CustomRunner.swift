import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 사용자가 불러온 그림으로 만든 러너. 프레임은 이 Mac의 Application Support에만 저장한다.
/// 저작권이 있는 캐릭터를 앱에 싣지 않고, 사용자가 가진 그림을 자기 Mac에서만 쓰게 하려는 기능이다.
struct CustomRunner: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let frameCount: Int
    /// 단색 테마를 따라 실루엣으로 그릴지. 배경이 투명한 그림에서만 자연스럽다.
    var silhouette: Bool
    let created: Date
}

/// 메뉴바·무대·설정이 그리는 러너 하나 (기본 러너 또는 내 러너).
struct RunnerCharacter {
    let key: String
    let name: String
    let sound: String
    let rig: CharacterRig
    /// 그림 러너는 자동일 때 원본 색을 그대로 쓴다. 실루엣이면 nil이라 설정 색을 따른다.
    let fixedTheme: SpriteTheme?

    /// 색을 고르면 그림 러너에도 그 색을 덧입힌다 (자동이면 원본 색).
    func theme(_ chosen: SpriteTheme) -> SpriteTheme {
        guard let fixedTheme else { return chosen }
        return chosen == .auto ? fixedTheme : chosen
    }

    /// 메뉴바에서 그리는 방식. 그림 러너는 실루엣으로 바꾸지 않고 늘 그림 그대로 그린다.
    func menuBarTheme(_ chosen: SpriteTheme) -> SpriteTheme { fixedTheme ?? chosen }

    /// 메뉴바 그림 러너에 덧입힐 색 테마. 자동·본래 색이면 nil.
    func imageTint(_ chosen: SpriteTheme) -> SpriteTheme? {
        guard fixedTheme != nil, chosen != .auto, chosen != .natural else { return nil }
        return chosen
    }
}

extension Runner {
    var character: RunnerCharacter {
        RunnerCharacter(key: rawValue, name: displayName, sound: sound, rig: rig, fixedTheme: .natural)
    }
}

extension CustomRunner {
    var character: RunnerCharacter {
        RunnerCharacter(key: "custom.\(id).\(silhouette)", name: name, sound: name, rig: CustomRig(runner: self),
                        fixedTheme: silhouette ? nil : .natural)
    }
}

// MARK: - 그리기

/// 불러온 프레임을 자세에 맞게 고르고 칸에 맞춰 놓는다. 점프·빙글 같은 동작은 CharacterScene이 그림 전체에 건다.
struct CustomRig: CharacterRig {
    let runner: CustomRunner
    let palette = CharacterPalette(body: .white, belly: .white, dark: .black)
    var isPicture: Bool { true }

    func draw(_ s: Sketch) {
        let frames = CustomRunnerStore.shared.frames(for: runner)
        guard let first = frames.first else { return }
        let pose = s.pose
        let u = pose.cycle
        var image = first
        var squash: CGFloat = 1
        var lift: CGFloat = 0
        var tilt: CGFloat = 0
        switch pose.activity {
        case .walk, .run:
            image = frames[min(Int(u * CGFloat(frames.count)), frames.count - 1)]
            if frames.count == 1 {
                // 정지 그림은 통통 튀며 달리는 것처럼 보이게 한다
                lift = abs(sin(.pi * u * 2)) * (pose.activity == .run ? 2.2 : 1.0)
                squash = 1 - 0.05 * cos(tau * u * 2)
            }
        case .stand:
            squash = 1 + 0.02 * sin(tau * u)
        case .sit:
            squash = 0.9 + 0.03 * sin(tau * u * 2)
        case .sleep:
            squash = 0.82 + 0.02 * sin(tau * u)
            tilt = -0.12
        }
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        var height: CGFloat = FittedRig.targetHeight
        var width = height * aspect
        if width > FittedRig.targetWidth {
            width = FittedRig.targetWidth
            height = width / aspect
        }
        height *= squash
        let rect = CGRect(x: FittedRig.targetCenterX - width / 2, y: Stage.ground - height - lift,
                          width: width, height: height)
        var t = CGAffineTransform(translationX: rect.midX, y: rect.maxY).rotated(by: tilt)
            .translatedBy(x: -rect.midX, y: -rect.maxY)
        let path = CGPath(rect: rect, transform: &t)
        s.add(Part(path: path, fill: false, stroke: 0, role: .body, image: image, imageRect: rect, imageRotation: tilt))
    }
}

// MARK: - 저장소

/// 내 러너 목록과 프레임. 메인 스레드에서만 쓴다.
final class CustomRunnerStore: ObservableObject {
    static let shared = CustomRunnerStore()

    @Published private(set) var runners: [CustomRunner] = []

    /// 프레임 한 장의 최대 높이(px). 메뉴바 22pt를 6배로 그려도 충분한 크기.
    static let maxFrameHeight = 144
    static let maxFrames = 48

    private var frameCache: [String: [CGImage]] = [:]

    private init() {
        load()
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RunTime/Runners", isDirectory: true)
    }

    func runner(id: String?) -> CustomRunner? {
        guard let id else { return nil }
        return runners.first { $0.id == id }
    }

    func frames(for runner: CustomRunner) -> [CGImage] {
        if let cached = frameCache[runner.id] { return cached }
        let folder = Self.directory.appendingPathComponent(runner.id)
        let frames = (0..<runner.frameCount).compactMap { i -> CGImage? in
            let url = folder.appendingPathComponent(String(format: "frame_%03d.png", i))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        frameCache[runner.id] = frames
        return frames
    }

    enum ImportError: LocalizedError {
        case noImages
        case unreadable(String)
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .noImages: return "그림을 찾지 못했습니다."
            case .unreadable(let name): return "\(name)을(를) 읽을 수 없습니다."
            case .saveFailed: return "프레임을 저장하지 못했습니다."
            }
        }
    }

    /// 디코드할 때 긴 변의 최대 픽셀. 큰 원본을 그대로 펼치면 프레임당 수십 MB가 된다.
    static let decodeMaxPixel = 512

    /// 움직이는 GIF·APNG 하나, 또는 정지 그림 여러 장(파일 이름 순서가 프레임 순서)을 러너로 만든다.
    /// 디코드와 손질은 백그라운드에서 하고 결과만 메인 스레드로 돌려준다.
    func importImages(from urls: [URL], completion: @escaping (Result<CustomRunner, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.makeRunner(from: urls) }
            DispatchQueue.main.async {
                if case .success(let made) = result {
                    self.frameCache[made.runner.id] = made.frames
                    self.runners.append(made.runner)
                    self.save()
                }
                completion(result.map(\.runner))
            }
        }
    }

    private static func makeRunner(from urls: [URL]) throws -> (runner: CustomRunner, frames: [CGImage]) {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var entries: [(source: CGImageSource, index: Int)] = []
        for url in sorted {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw ImportError.unreadable(url.lastPathComponent)
            }
            entries += (0..<CGImageSourceGetCount(source)).map { (source, $0) }
        }
        if entries.count > maxFrames {
            // 프레임이 너무 많으면 고르게 솎아 남길 것만 디코드한다
            let step = Double(entries.count) / Double(maxFrames)
            entries = (0..<maxFrames).map { entries[Int(Double($0) * step)] }
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: decodeMaxPixel] as CFDictionary
        let frames = prepare(entries.compactMap { CGImageSourceCreateThumbnailAtIndex($0.source, $0.index, options) })
        guard !frames.isEmpty else { throw ImportError.noImages }

        let runner = CustomRunner(id: UUID().uuidString, name: defaultName(urls), frameCount: frames.count,
                                  silhouette: false, created: Date())
        let folder = directory.appendingPathComponent(runner.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, image) in frames.enumerated() {
            let url = folder.appendingPathComponent(String(format: "frame_%03d.png", i))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw ImportError.saveFailed }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: folder)
                throw ImportError.saveFailed
            }
        }
        return (runner, frames)
    }

    func update(_ runner: CustomRunner) {
        guard let index = runners.firstIndex(where: { $0.id == runner.id }) else { return }
        runners[index] = runner
        save()
    }

    func delete(_ runner: CustomRunner) {
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(runner.id))
        frameCache[runner.id] = nil
        runners.removeAll { $0.id == runner.id }
        save()
    }

    // MARK: 목록 파일

    private var indexURL: URL { Self.directory.appendingPathComponent("runners.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([CustomRunner].self, from: data) else { return }
        runners = list
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(runners) { try? data.write(to: indexURL) }
    }

    // MARK: 프레임 손질

    private static func defaultName(_ urls: [URL]) -> String {
        let name = urls.first?.deletingPathExtension().lastPathComponent ?? "내 러너"
        return String(name.prefix(12))
    }

    /// 모든 프레임에 공통인 투명 여백을 잘라 칸을 꽉 채우고, 높이를 줄여 메모리를 아낀다.
    private static func prepare(_ frames: [CGImage]) -> [CGImage] {
        let width = frames.map(\.width).max() ?? 1
        let height = frames.map(\.height).max() ?? 1
        var rendered = frames.compactMap { draw($0, canvas: CGSize(width: width, height: height)) }
        if let key = rendered.first.flatMap(backgroundKey) {
            rendered = rendered.compactMap { removeBackground($0, key: key) }
        }
        let crop = rendered.reduce(CGRect.null) { $0.union(opaqueBounds($1)) }
        let box = crop.isNull ? CGRect(x: 0, y: 0, width: width, height: height) : crop
        let scale = min(1, CGFloat(maxFrameHeight) / box.height)
        let target = CGSize(width: max(1, (box.width * scale).rounded()), height: max(1, (box.height * scale).rounded()))
        return rendered.compactMap { image in
            guard let cropped = image.cropping(to: box) else { return nil }
            return draw(cropped, canvas: target)
        }
    }

    /// RGBA 비트맵으로 다시 그린다 (프레임마다 색 공간·크기가 달라도 같은 규격으로).
    private static func draw(_ image: CGImage, canvas: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let scale = min(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (canvas.width - size.width) / 2, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// 네 모서리가 모두 불투명하고 색이 거의 같으면 그 색을 배경으로 본다 (불투명 배경 GIF).
    private static func backgroundKey(_ image: CGImage) -> (UInt8, UInt8, UInt8)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height, row = image.bytesPerRow
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)].map { x, y -> (UInt8, UInt8, UInt8, UInt8) in
            let p = bytes + y * row + x * 4
            return (p[0], p[1], p[2], p[3])
        }
        guard corners.allSatisfy({ $0.3 == 255 }) else { return nil }
        let first = corners[0]
        guard corners.allSatisfy({ colorDistance(($0.0, $0.1, $0.2), (first.0, first.1, first.2)) < 30 }) else { return nil }
        return (first.0, first.1, first.2)
    }

    private static func colorDistance(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Int {
        abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))
    }

    /// 가장자리에서 이어진 배경색 픽셀만 투명하게 만든다. 그림 안쪽의 같은 색(검은 눈 등)은 남는다.
    private static func removeBackground(_ image: CGImage, key: (UInt8, UInt8, UInt8)) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func push(_ index: Int) {
            guard !visited[index] else { return }
            visited[index] = true
            stack.append(index)
        }
        for x in 0..<w { push(x); push((h - 1) * w + x) }
        for y in 0..<h { push(y * w); push(y * w + w - 1) }
        while let index = stack.popLast() {
            let p = buffer + index * 4
            guard colorDistance((p[0], p[1], p[2]), key) < 36 else { continue }
            p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0
            let x = index % w, y = index / w
            if x > 0 { push(index - 1) }
            if x < w - 1 { push(index + 1) }
            if y > 0 { push(index - w) }
            if y < h - 1 { push(index + w) }
        }
        return context.makeImage()
    }

    /// 알파가 있는 픽셀의 영역 (이미지 좌표, 원점 왼쪽 위).
    private static func opaqueBounds(_ image: CGImage) -> CGRect {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .null }
        let bytesPerRow = image.bytesPerRow
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            let row = bytes + y * bytesPerRow
            for x in 0..<image.width where row[x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
