import AppKit
import DesignSyncCore
import HostsCore
import SwiftUI
import WorkLogCore

/// 사용법 영상 프레임 만들기 (`--guide-clips <폴더> [장면,...]`).
///
/// 1. 실제 화면을 예시 데이터로 2~3배 해상도로 찍는다 (키 입력이 필요한 곳은 상태를 바꿔 가며).
/// 2. 찍어 둔 화면 위에 확대 카메라, 강조 테두리, 커서, 누르는 고리, 자막 띠를 30fps로 합성해 PNG로 저장한다.
///    화면이 움직이는 장면(러너 무대)만 실시간으로 여러 장을 찍고, 나머지는 한 장을 확대해 쓴다.
/// 3. 단계마다 시작 시각을 `meta.json`에 적는다. 앱의 사용법 창이 영상과 단계 카드를 맞추는 데 쓴다.
/// mp4와 GIF로 묶는 일은 `scripts/make-guide-gifs.sh`가 한다.
@MainActor
final class StillHolder: ObservableObject {
    @Published var image: NSImage?
}

struct ClipStillView: View {
    @ObservedObject var holder: StillHolder
    var body: some View {
        if let image = holder.image { Image(nsImage: image).resizable().interpolation(.high) } else { Color.black }
    }
}

/// 목록이 질문마다 다시 그려지게 id를 붙인다 (꺼 둔 창에서는 목록 표가 바뀐 줄을 늦게 그려서).
struct ClipPalette: View {
    @ObservedObject var model: WindowPaletteModel
    var body: some View {
        WindowPaletteView(model: model, perform: { _ in }, close: {}).id(model.query)
    }
}

struct ClipStep {
    /// GuideTopic.steps의 몇 번째 단계인지 (자막과 번호를 거기서 가져온다)
    var step: Int
    /// 이 동안 보여 줄 화면 영역 (원본 화면 좌표)
    var camera: CGRect
    /// 강조할 곳
    var target: CGRect?
    /// 커서가 가서 멈출 곳. nil이면 커서를 숨김
    var cursor: CGPoint?
    var click = false
    var action: (@MainActor () -> Void)?
    var hold = 1.8
}

@MainActor
enum GuideClips {
    static let fps = 30.0
    static let pad: CGFloat = 28
    static let captionHeight: CGFloat = 64

    struct Clip {
        let id: String
        let size: CGSize
        /// 원본을 몇 배로 찍을지. 확대해도 글자가 선명하게 3배(움직이는 장면은 2배)
        let scale: CGFloat
        let appearance: NSAppearance.Name
        let frame: CGSize
        let animated: Bool
        let content: AnyView
        let steps: [ClipStep]
    }

    static func run(to folder: URL, only: [String]) {
        setenv("RUNTIME_NO_GUIDE_HINT", "1", 1)
        useDemoDefaults()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let engine = UsageEngine()
        Task { @MainActor in
            for clip in clips(engine: engine) where only.isEmpty || only.contains(clip.id) {
                await play(clip, to: folder)
            }
            exit(0)
        }
        app.run()
    }

    /// 내 설정(피그마 화면설계서 이름, 레드마인 주소, 펫)이 그림에 남지 않게, 읽을 값만 예시로 덮는다. 저장하지 않는다.
    private static func useDemoDefaults() {
        let sources = [DesignSource(fileKey: "demo-shop", name: "[쇼핑몰 앱] 화면설계서"),
                       DesignSource(fileKey: "demo-admin", name: "[관리자 웹] 화면설계서")]
        UserDefaults.standard.setVolatileDomain([
            "design.sources": (try? JSONEncoder().encode(sources)) ?? Data(),
            "design.favorites": [String](),
            "workLog.redmineURL": "",
            "runner": "cat", "customRunner": "", "spriteTheme": "natural", "gameCompanion": "",
        ], forName: UserDefaults.argumentDomain)
    }

    private static func mainWindow(_ page: MainPage, engine: UsageEngine, workLog: WorkLogPage = WorkLogPage(),
                                   tab: SettingsView.Tab = .general) -> AnyView {
        let navigator = MainNavigator()
        navigator.start(at: page)
        return AnyView(MainWindowView(engine: engine, settings: engine.settings, navigator: navigator, workLogPage: workLog,
                                      settingsTab: SettingsTabState(tab))
            .frame(width: AppWindow.size.width, height: AppWindow.size.height))
    }

    // MARK: 장면

    private static func cam(_ x: CGFloat, _ y: CGFloat, width: CGFloat = 600) -> CGRect {
        CGRect(x: x, y: y, width: width, height: width * 450 / 720)
    }

    private static func clips(engine: UsageEngine) -> [Clip] {
        let window = AppWindow.size
        let stills = ProcessInfo.processInfo.environment["RUNTIME_CLIP_STILLS"] ?? ""

        // 업무 일지
        let page = WorkLogPage()
        page.mode = .day
        if let last = WorkLogStore.shared.log.days.first { page.day = last }
        page.dayReport = .plan
        var newEntry: WorkEntry?
        let workLog = Clip(
            id: "workLog", size: window, scale: 3, appearance: .aqua, frame: CGSize(width: 720, height: 450), animated: false,
            content: mainWindow(.workLog, engine: engine, workLog: page),
            steps: [
                ClipStep(step: 0, camera: cam(294, 120), target: CGRect(x: 330, y: 306, width: 170, height: 32), cursor: CGPoint(x: 394, y: 322), click: true,
                         action: { newEntry = WorkLogStore.shared.add(day: page.day, project: "쇼핑몰 앱", title: "상품 상세 이미지 교체", status: .percent(30)) }),
                ClipStep(step: 1, camera: cam(294, 120), target: CGRect(x: 334, y: 308, width: 28, height: 28), cursor: CGPoint(x: 347, y: 322), click: true,
                         action: { if let id = newEntry?.id { WorkLogStore.shared.update(id) { $0.status = .done } } }),
                ClipStep(step: 2, camera: cam(840, 510, width: 400), target: CGRect(x: 936, y: 648, width: 288, height: 32), cursor: CGPoint(x: 1080, y: 663), click: true, hold: 2.2),
            ])

        // 호스트
        let hosts = Clip(
            id: "hosts", size: window, scale: 3, appearance: .aqua, frame: CGSize(width: 720, height: 450), animated: false,
            content: mainWindow(.hosts, engine: engine),
            steps: [
                ClipStep(step: 0, camera: cam(150, 110), target: CGRect(x: 180, y: 306, width: 58, height: 30), cursor: CGPoint(x: 196, y: 321), click: true,
                         action: {
                             if let item = HostsStore.shared.draft.items.first(where: { !$0.enabled }) { HostsStore.shared.draft.setEnabled(item, true) }
                         }),
                ClipStep(step: 1, camera: cam(240, 260, width: 800), target: CGRect(x: 940, y: 700, width: 90, height: 34), cursor: CGPoint(x: 985, y: 717), hold: 2.2),
                ClipStep(step: 2, camera: cam(220, 30, width: 900), target: CGRect(x: 1027, y: 63, width: 32, height: 32), cursor: CGPoint(x: 1043, y: 79), hold: 2.2),
            ])

        // 창 배치
        let palette = WindowPaletteModel()
        let windows = Clip(
            id: "windows", size: CGSize(width: 520, height: 400), scale: 3, appearance: .darkAqua,
            frame: CGSize(width: 720, height: 450), animated: false,
            content: { palette.prepare(); return AnyView(ClipPalette(model: palette)) }(),
            steps: [
                ClipStep(step: 0, camera: CGRect(x: 0, y: 0, width: 520, height: 325), target: CGRect(x: 4, y: 4, width: 512, height: 34),
                         action: { palette.query = "ㅇ" }, hold: 0.9),
                ClipStep(step: 0, camera: CGRect(x: 0, y: 0, width: 520, height: 325), target: CGRect(x: 4, y: 4, width: 512, height: 34),
                         action: { palette.query = "ㅇㅉ" }, hold: 1.6),
                ClipStep(step: 1, camera: CGRect(x: 0, y: 0, width: 520, height: 325), target: CGRect(x: 4, y: 50, width: 495, height: 34), hold: 2.0),
                ClipStep(step: 2, camera: CGRect(x: 0, y: 0, width: 520, height: 325), target: CGRect(x: 4, y: 50, width: 495, height: 34),
                         cursor: CGPoint(x: 250, y: 66), click: true, hold: 1.8),
            ])

        // 클립보드 띠 (별도 창이라 찍어 둔 정지 화면을 쓴다)
        let holder = StillHolder()
        func still(_ name: String) -> @MainActor () -> Void {
            { holder.image = NSImage(contentsOfFile: "\(stills)/\(name).png") }
        }
        holder.image = NSImage(contentsOfFile: "\(stills)/clip-1-default.png")
        let band = CGRect(x: 0, y: 0, width: 800, height: 411)
        let clipboard = Clip(
            id: "clipboard", size: CGSize(width: 1080, height: 446), scale: 3, appearance: .darkAqua,
            frame: CGSize(width: 720, height: 370), animated: false,
            content: AnyView(ClipStillView(holder: holder)),
            steps: [
                ClipStep(step: 0, camera: band, target: CGRect(x: 40, y: 90, width: 230, height: 320), hold: 2.0),
                ClipStep(step: 1, camera: band, target: CGRect(x: 40, y: 90, width: 230, height: 320), cursor: CGPoint(x: 160, y: 250), click: true, hold: 1.8),
                ClipStep(step: 2, camera: band, target: CGRect(x: 14, y: 56, width: 580, height: 34), action: still("clip-5-filter-link"), hold: 2.0),
                ClipStep(step: 3, camera: band, target: CGRect(x: 14, y: 8, width: 330, height: 40), action: still("clip-3-choseong-search"), hold: 2.4),
                ClipStep(step: 4, camera: band, target: CGRect(x: 40, y: 90, width: 230, height: 320), action: still("clip-6-pinboard"), hold: 2.0),
            ])

        // 사용량 창: 어두운 바탕 가운데에 놓는다
        let usageEngine = UsageEngine()
        ReadmeShots.fill(usageEngine)
        let usageCanvas = CGSize(width: 760, height: 640)
        let usage = Clip(
            id: "usage", size: usageCanvas, scale: 2, appearance: .darkAqua, frame: CGSize(width: 720, height: 450), animated: true,
            content: AnyView(PopoverView(engine: usageEngine, settings: usageEngine.settings)
                .frame(width: 376, height: 564)
                .frame(width: usageCanvas.width, height: usageCanvas.height, alignment: .top)
                .background(Color(white: 0.1))),
            steps: [
                ClipStep(step: 0, camera: cam(144, 180, width: 480), target: CGRect(x: 206, y: 206, width: 350, height: 152), cursor: CGPoint(x: 282, y: 262), hold: 2.6),
                ClipStep(step: 1, camera: cam(144, 180, width: 480), target: CGRect(x: 290, y: 276, width: 20, height: 22), cursor: CGPoint(x: 299, y: 286), hold: 2.8),
                ClipStep(step: 2, camera: cam(144, 335, width: 480), target: CGRect(x: 206, y: 350, width: 350, height: 108), cursor: CGPoint(x: 420, y: 408), hold: 2.6),
                ClipStep(step: 3, camera: cam(144, 335, width: 480), target: CGRect(x: 418, y: 524, width: 140, height: 30), cursor: CGPoint(x: 444, y: 538), hold: 2.6),
            ])

        // 러너 화면
        let runnerEngine = UsageEngine()
        ReadmeShots.fill(runnerEngine)
        let runnerNavigator = MainNavigator()
        runnerNavigator.start(at: .runners)
        let runners = Clip(
            id: "runners", size: window, scale: 2, appearance: .darkAqua, frame: CGSize(width: 720, height: 450), animated: true,
            content: AnyView(MainWindowView(engine: runnerEngine, settings: runnerEngine.settings, navigator: runnerNavigator,
                                            workLogPage: WorkLogPage(), settingsTab: SettingsTabState(.general))
                .frame(width: window.width, height: window.height)),
            steps: [
                ClipStep(step: 0, camera: cam(230, 18, width: 900), target: CGRect(x: 704, y: 466, width: 118, height: 108), cursor: CGPoint(x: 763, y: 520), click: true,
                         action: { runnerEngine.settings.customRunnerID = nil; runnerEngine.settings.select(.dino) }),
                ClipStep(step: 1, camera: cam(97, 385), target: CGRect(x: 108, y: 455, width: 296, height: 60), cursor: CGPoint(x: 255, y: 485), hold: 2.4),
                ClipStep(step: 2, camera: cam(640, 250), target: CGRect(x: 920, y: 345, width: 156, height: 32), cursor: CGPoint(x: 997, y: 360), hold: 2.4),
                ClipStep(step: 3, camera: cam(97, 250), target: CGRect(x: 268, y: 344, width: 168, height: 34), cursor: CGPoint(x: 352, y: 360), hold: 2.4),
            ])

        // 레드마인 연결
        let redmineEngine = UsageEngine()
        let redmineNavigator = MainNavigator()
        redmineNavigator.start(at: .settings)
        let redmineLog = WorkLogPage()
        redmineLog.settingsSection = .redmine
        let redmine = Clip(
            id: "redmine", size: window, scale: 3, appearance: .aqua, frame: CGSize(width: 720, height: 450), animated: false,
            content: AnyView(MainWindowView(engine: redmineEngine, settings: redmineEngine.settings, navigator: redmineNavigator, workLogPage: redmineLog,
                                            settingsTab: SettingsTabState(.workLog))
                .frame(width: window.width, height: window.height)),
            steps: [
                ClipStep(step: 0, camera: cam(73, 120, width: 900), target: CGRect(x: 85, y: 382, width: 196, height: 34), cursor: CGPoint(x: 170, y: 399), hold: 2.2),
                ClipStep(step: 1, camera: cam(310, 20, width: 720), target: CGRect(x: 760, y: 172, width: 250, height: 38), cursor: CGPoint(x: 885, y: 191), hold: 2.4),
                ClipStep(step: 2, camera: cam(310, 20, width: 720), target: CGRect(x: 756, y: 244, width: 255, height: 38), cursor: CGPoint(x: 970, y: 262), hold: 2.6),
                ClipStep(step: 3, camera: cam(310, 20, width: 720), target: CGRect(x: 832, y: 104, width: 176, height: 36), cursor: CGPoint(x: 920, y: 121), hold: 2.4),
            ])

        // 피그마 연결
        let figmaEngine = UsageEngine()
        let figmaNavigator = MainNavigator()
        figmaNavigator.start(at: .settings)
        let figma = Clip(
            id: "figma", size: window, scale: 3, appearance: .aqua, frame: CGSize(width: 720, height: 450), animated: false,
            content: AnyView(MainWindowView(engine: figmaEngine, settings: figmaEngine.settings, navigator: figmaNavigator, workLogPage: WorkLogPage(),
                                            settingsTab: SettingsTabState(.figma))
                .frame(width: window.width, height: window.height)),
            steps: [
                ClipStep(step: 0, camera: cam(73, 198, width: 900), target: CGRect(x: 85, y: 453, width: 196, height: 34), cursor: CGPoint(x: 170, y: 470), hold: 2.2),
                ClipStep(step: 1, camera: cam(310, 60, width: 720), target: CGRect(x: 820, y: 148, width: 190, height: 34), cursor: CGPoint(x: 910, y: 165), hold: 2.6),
                ClipStep(step: 2, camera: cam(310, 230, width: 720), target: CGRect(x: 706, y: 386, width: 302, height: 34), cursor: CGPoint(x: 970, y: 403), hold: 2.6),
                ClipStep(step: 3, camera: cam(310, 170, width: 720), target: CGRect(x: 898, y: 268, width: 76, height: 36), cursor: CGPoint(x: 936, y: 287), hold: 2.6),
            ])
        return [workLog, hosts, windows, clipboard, usage, runners, redmine, figma]
    }

    // MARK: 재생과 합성

    private struct Segment {
        var start: Double
        var duration: Double
        var bases: [(time: Double, data: Data)]
        var step: Int
        var cam0: CGRect, cam1: CGRect
        var cur0: CGPoint?, cur1: CGPoint?
        var target: CGRect?
        var moving: Bool
        var ripple: Bool
    }

    private static func play(_ clip: Clip, to root: URL) async {
        let folder = root.appendingPathComponent(clip.id, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let host = ShotWindow(contentViewController: NSHostingController(rootView: clip.content))
        host.styleMask = [.titled]
        host.appearance = NSAppearance(named: clip.appearance)
        host.setContentSize(NSSize(width: clip.size.width, height: clip.size.height))
        host.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.orderBack(nil)

        func capture() -> Data? {
            guard let view = host.contentView else { return nil }
            let w = Int(clip.size.width * clip.scale), h = Int(clip.size.height * clip.scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = clip.size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.96])
        }
        func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        /// 움직이는 장면은 지나가는 시간 동안 계속 찍고, 나머지는 지금 화면 한 장을 쓴다
        func record(_ seconds: Double, current: Data) async -> [(time: Double, data: Data)] {
            guard clip.animated else { return [(0, current)] }
            var out: [(time: Double, data: Data)] = []
            let begin = Date()
            while Date().timeIntervalSince(begin) < seconds {
                if let data = capture() { out.append((Date().timeIntervalSince(begin), data)) }
                await sleep(0.04)
            }
            return out.isEmpty ? [(0, current)] : out
        }

        await sleep(2.6)
        guard var current = capture() else { return }
        var segments: [Segment] = []
        var clock = 0.0
        var prevCam = clip.steps[0].camera
        var prevCursor: CGPoint?
        var firstTimeOfStep: [Int: Double] = [:]

        for step in clip.steps {
            firstTimeOfStep[step.step] = firstTimeOfStep[step.step] ?? clock
            // 1) 카메라와 커서가 옮겨 간다
            let travel = step.cursor != nil ? 0.9 : 0.5
            let from = prevCursor ?? step.cursor.map { CGPoint(x: $0.x + 90, y: $0.y + 70) }
            segments.append(Segment(start: clock, duration: travel, bases: await record(travel, current: current), step: step.step,
                                    cam0: prevCam, cam1: step.camera, cur0: from, cur1: step.cursor, target: step.target, moving: true, ripple: false))
            clock += travel
            // 2) 누르기
            if step.click {
                segments.append(Segment(start: clock, duration: 0.4, bases: await record(0.4, current: current), step: step.step,
                                        cam0: step.camera, cam1: step.camera, cur0: step.cursor, cur1: step.cursor, target: step.target, moving: false, ripple: true))
                clock += 0.4
            }
            // 3) 화면이 바뀐다
            if let action = step.action {
                action()
                await sleep(0.55)
                if let data = capture() { current = data }
            }
            segments.append(Segment(start: clock, duration: step.hold, bases: await record(step.hold, current: current), step: step.step,
                                    cam0: step.camera, cam1: step.camera, cur0: step.cursor, cur1: step.cursor, target: step.target, moving: false, ripple: false))
            clock += step.hold
            prevCam = step.camera
            prevCursor = step.cursor
        }

        // 합성
        let topic = GuideTopic.all.first { $0.id == clip.id }
        let titles = topic?.steps.map(\.title) ?? []
        let frames = Int(clock * fps)
        var decoded: CGImage?
        var lastKey = -1
        var segmentIndex = 0
        for i in 0..<frames {
            let t = Double(i) / fps
            while segmentIndex + 1 < segments.count, segments[segmentIndex + 1].start <= t { segmentIndex += 1 }
            let seg = segments[segmentIndex]
            let u = t - seg.start
            let base = seg.bases.last { $0.time <= u } ?? seg.bases[0]
            let key = segmentIndex * 100_000 + Int(base.time * 1000)
            if key != lastKey {
                decoded = NSBitmapImageRep(data: base.data)?.cgImage
                lastKey = key
            }
            guard let image = decoded else { continue }
            let title = seg.step < titles.count ? titles[seg.step] : ""
            let png = composeFrame(clip: clip, image: image, seg: seg, u: u, t: t, title: title, steps: titles.count)
            try? png?.write(to: folder.appendingPathComponent(String(format: "%05d.png", i + 1)))
        }

        let times = (0..<(topic?.steps.count ?? 0)).map { firstTimeOfStep[$0] ?? 0 }
        let meta: [String: Any] = ["duration": clock, "steps": times]
        if let json = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? json.write(to: folder.appendingPathComponent("meta.json"))
        }
        print("saved: \(folder.path) \(frames)장 \(String(format: "%.1f", clock))초")
        host.orderOut(nil)
    }

    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    private static func composeFrame(clip: Clip, image: CGImage, seg: Segment, u: Double, t: Double, title: String, steps: Int) -> Data? {
        let ui = clip.frame
        let width = ui.width + pad * 2
        let height = pad + ui.height + 20 + captionHeight + 24
        let ratio: CGFloat = 2
        guard let cg = CGContext(data: nil, width: Int(width * ratio), height: Int(height * ratio), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        cg.translateBy(x: 0, y: height * ratio)
        cg.scaleBy(x: ratio, y: -ratio)
        let ctx = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }
        cg.interpolationQuality = .high

        // 바탕
        let colors = [NSColor(red: 0.93, green: 0.94, blue: 0.97, alpha: 1).cgColor, NSColor(red: 0.85, green: 0.87, blue: 0.93, alpha: 1).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        }

        // 화면
        let uiRect = CGRect(x: pad, y: pad, width: ui.width, height: ui.height)
        let rounded = NSBezierPath(roundedRect: uiRect, xRadius: 12, yRadius: 12)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        NSColor.black.setFill()
        rounded.fill()
        cg.restoreGState()
        cg.saveGState()
        rounded.addClip()
        let moveEase = seg.moving ? ease(u / seg.duration) : 1
        let camera = CGRect(x: lerp(seg.cam0.minX, seg.cam1.minX, moveEase), y: lerp(seg.cam0.minY, seg.cam1.minY, moveEase),
                            width: lerp(seg.cam0.width, seg.cam1.width, moveEase), height: lerp(seg.cam0.height, seg.cam1.height, moveEase))
        let zoom = ui.width / camera.width
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: uiRect.minX + (p.x - camera.minX) * zoom, y: uiRect.minY + (p.y - camera.minY) * zoom) }
        let imageRect = CGRect(x: uiRect.minX - camera.minX * zoom, y: uiRect.minY - camera.minY * zoom,
                               width: clip.size.width * zoom, height: clip.size.height * zoom)
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            .draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                  hints: [.interpolation: NSImageInterpolation.high.rawValue])

        // 강조 테두리
        let accent = NSColor(red: 1.0, green: 0.62, blue: 0.1, alpha: 1)
        if let target = seg.target {
            let appear = seg.moving ? ease((u - 0.3) / 0.4) : 1
            let origin = place(target.origin)
            let rect = CGRect(x: origin.x - 4, y: origin.y - 4, width: target.width * zoom + 8, height: target.height * zoom + 8)
            let pulse = 1 + 0.012 * sin(t * 6)
            let box = rect.insetBy(dx: -rect.width * (pulse - 1) / 2, dy: -rect.height * (pulse - 1) / 2)
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: 10, color: accent.withAlphaComponent(0.7 * appear).cgColor)
            accent.withAlphaComponent(appear).setStroke()
            let path = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
            path.lineWidth = 3
            path.stroke()
            cg.restoreGState()
            accent.withAlphaComponent(0.05 * appear).setFill()
            NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        }

        // 누르는 고리
        if seg.ripple, let point = seg.cur1 {
            let p = u / seg.duration
            let c = place(point)
            let radius = 8 + 30 * p
            accent.withAlphaComponent(1 - p).setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 3
            ring.stroke()
        }

        // 커서
        if let to = seg.cur1 {
            let from = seg.cur0 ?? to
            let point = place(CGPoint(x: lerp(from.x, to.x, moveEase), y: lerp(from.y, to.y, moveEase)))
            drawCursor(at: point, alpha: seg.moving && seg.cur0 == nil ? moveEase : 1)
        }
        cg.restoreGState()

        // 화면 테두리
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let border = NSBezierPath(roundedRect: uiRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()

        // 자막 띠 (화면을 가리지 않게 화면 아래에 둔다)
        drawCaption(title: title, step: seg.step + 1, of: steps, in: CGRect(x: pad, y: uiRect.maxY + 20, width: ui.width, height: captionHeight))

        guard let output = cg.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }

    private static func drawCursor(at point: CGPoint, alpha: Double) {
        let path = NSBezierPath()
        let s: CGFloat = 1.5
        path.move(to: CGPoint(x: point.x, y: point.y))
        path.line(to: CGPoint(x: point.x, y: point.y + 15 * s))
        path.line(to: CGPoint(x: point.x + 4.2 * s, y: point.y + 11.6 * s))
        path.line(to: CGPoint(x: point.x + 7.2 * s, y: point.y + 18 * s))
        path.line(to: CGPoint(x: point.x + 10 * s, y: point.y + 16.6 * s))
        path.line(to: CGPoint(x: point.x + 7 * s, y: point.y + 10.4 * s))
        path.line(to: CGPoint(x: point.x + 12 * s, y: point.y + 10.4 * s))
        path.close()
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.lineWidth = 1.6
        path.stroke()
    }

    private static func drawCaption(title: String, step: Int, of total: Int, in rect: CGRect) {
        let blue = NSColor(red: 0.36, green: 0.42, blue: 1.0, alpha: 1)
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white])
        let textSize = text.size()
        let badge: CGFloat = 36
        let contentWidth = badge + 14 + textSize.width
        let pillWidth = min(contentWidth + 44, rect.width)
        let pill = CGRect(x: rect.midX - pillWidth / 2, y: rect.minY, width: pillWidth, height: rect.height)
        NSColor(white: 0.1, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: pill, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let left = pill.midX - contentWidth / 2
        let badgeRect = CGRect(x: left, y: pill.midY - badge / 2, width: badge, height: badge)
        blue.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        let number = NSAttributedString(string: "\(step)", attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .heavy), .foregroundColor: NSColor.white])
        let numberSize = number.size()
        number.draw(at: CGPoint(x: badgeRect.midX - numberSize.width / 2, y: badgeRect.midY - numberSize.height / 2))
        text.draw(at: CGPoint(x: badgeRect.maxX + 14, y: pill.midY - textSize.height / 2))
        // 진행 점
        if total > 1 {
            let dot: CGFloat = 7, gap: CGFloat = 7
            let rowWidth = CGFloat(total) * dot + CGFloat(total - 1) * gap
            var x = rect.midX - rowWidth / 2
            for index in 0..<total {
                (index + 1 == step ? blue : NSColor.black.withAlphaComponent(0.2)).setFill()
                NSBezierPath(ovalIn: CGRect(x: x, y: rect.maxY + 6, width: dot, height: dot)).fill()
                x += dot + gap
            }
        }
    }
}
