import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 사용자가 직접 문제를 적어 보내는 창. 오류 없이 틀리게 도는 것은 앱이 알 수 없어서 사람이 알려 준다.
/// 그림은 사용자가 찍어 붙인 것만 보낸다. 팝오버·메뉴바·화면 위 펫은 앱이 스스로 찍을 수 없고,
/// 직접 찍으면 문제 있는 곳만 잘라 회사 일감 같은 것이 덜 나간다.
final class ProblemReportWindow {
    static let shared = ProblemReportWindow()

    private var window: NSWindow?
    private let model = ProblemReportModel()

    func show(usage: String) {
        model.prepare(usage: usage)
        let window = self.window ?? make()
        self.window = window
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func make() -> NSWindow {
        // 그림을 붙이면 창이 내용에 맞춰 늘어난다
        let host = NSHostingController(rootView: ProblemReportView(model: model) { [weak self] in self?.window?.close() })
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "문제 보내기"
        window.isReleasedWhenClosed = false
        return window
    }
}

final class ProblemReportModel: ObservableObject {
    struct Shot: Identifiable {
        let id = UUID()
        /// 보낼 JPEG. 썸네일도 이것으로 그려 원본 그림은 들고 있지 않는다.
        let jpeg: Data
        let thumbnail: NSImage
    }

    /// 서버가 받는 장 수와 같다.
    static let maxShots = 3

    @Published var draft = ""
    @Published private(set) var shots: [Shot] = []
    /// JPEG로 줄이는 중인 장 수. 큰 화면 그림은 메인 스레드를 잠깐 막을 만큼 걸려 따로 줄인다.
    @Published private(set) var converting = 0
    @Published private(set) var sending = false
    @Published private(set) var result: String?
    /// 그림을 창 위로 끌고 있는지. 이 툴체인은 `@State`를 못 써서 모델에 둔다 (HoverFlag 참고).
    @Published var dropTargeted = false
    private var usage = ""

    /// 다시 열면 쓰던 글과 붙인 그림은 그대로 둔다.
    func prepare(usage: String) {
        self.usage = usage
        result = nil
    }

    var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSend: Bool { !sending && converting == 0 && !trimmed.isEmpty && draft.count <= ProblemReporter.userTextLimit }
    var canAdd: Bool { shots.count + converting < Self.maxShots }

    /// 그림 하나를 읽는 일. 파일은 백그라운드에서 바로 읽고, 이미 메모리에 있는 그림은 CGImage로 넘긴다
    /// (NSImage는 스레드를 건너 쓰면 안전하다고 보장되지 않는다).
    typealias Source = @Sendable () -> CGImage?

    static func source(_ url: URL) -> Source {
        { CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
    }

    static func source(_ image: NSImage) -> Source {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return { cg }
    }

    func add(_ sources: [Source]) {
        for load in sources {
            guard canAdd else { result = "그림은 \(Self.maxShots)장까지 붙일 수 있습니다"; return }
            converting += 1
            DispatchQueue.global(qos: .userInitiated).async {
                let jpeg = load().flatMap(Self.jpeg(from:))
                DispatchQueue.main.async {
                    self.converting -= 1
                    guard let jpeg, let thumbnail = NSImage(data: jpeg) else { self.result = "그림을 읽지 못했습니다"; return }
                    self.shots.append(Shot(jpeg: jpeg, thumbnail: thumbnail))
                    self.result = nil
                }
            }
        }
    }

    func remove(_ shot: Shot) { shots.removeAll { $0.id == shot.id } }

    /// 화면 찍기를 클립보드로 받은 그림, 또는 Finder에서 복사한 그림 파일.
    func paste() {
        let board = NSPasteboard.general
        let files = board.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL] ?? []
        let sources = files.isEmpty ? (board.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).map(Self.source)
                                    : files.map(Self.source)
        if sources.isEmpty { result = "클립보드에 그림이 없습니다. ⌃⌘⇧4로 찍으면 클립보드에 담깁니다" } else { add(sources) }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls.map(Self.source))
    }

    /// 끌어다 놓은 것. 그림 자체로 오기도 하고(다른 앱), 파일 주소로 오기도 한다(Finder).
    func drop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.canLoadObject(ofClass: NSImage.self) || $0.canLoadObject(ofClass: URL.self) }
        for provider in accepted {
            let deliver = { (source: Source?) in DispatchQueue.main.async { source.map { self.add([$0]) } } }
            // 파일은 주소로 받아 백그라운드에서 읽는다. 다른 앱에서 끌어 온 그림만 NSImage로 받는다
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in deliver(url.map(Self.source)) }
            } else {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in deliver((image as? NSImage).map(Self.source)) }
            }
        }
        return !accepted.isEmpty
    }

    func send(close: @escaping () -> Void) {
        sending = true
        result = nil
        let images = shots.map(\.jpeg)
        ProblemReporter.userReport(trimmed, usage: usage, shots: images) { [weak self] status in
            guard let self else { return }
            self.sending = false
            switch status {
            case 200:
                self.clear()
                close()
            case -1:
                self.result = "설치한 앱에서만 보낼 수 있습니다"
            case _ where ProblemReporter.retryable(status):
                // 글은 다시 보낼 줄에 남겼다. 그림은 크기 때문에 남기지 않는다
                self.clear()
                self.result = images.isEmpty ? "지금 못 보내 나중에 다시 보냅니다" : "지금 못 보내 글만 나중에 다시 보냅니다"
            default:
                self.result = "보내지 못했습니다 (HTTP \(status))"
            }
        }
    }

    /// 화면 점검용: 글과 그림이 들어간 모습.
    static func rehearsal(draft: String, images: [NSImage]) -> ProblemReportModel {
        let model = ProblemReportModel()
        model.draft = draft
        model.shots = images.compactMap { image in
            image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(jpeg(from:)).flatMap { data in NSImage(data: data).map { Shot(jpeg: data, thumbnail: $0) } }
        }
        return model
    }

    private func clear() {
        draft = ""
        shots = []
    }

    /// 메일 첨부 한 장이 서버 한도(세 장 1.5MB, base64)를 넘지 않게 줄여 가며 JPEG로 만든다.
    static func jpeg(from cg: CGImage) -> Data? {
        for (side, quality) in [(1600.0, 0.7), (1200.0, 0.5), (900.0, 0.4)] {
            if let data = scaled(cg, longest: side)?.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               data.count <= 360_000 { return data }
        }
        return nil
    }

    private static func scaled(_ image: CGImage, longest side: CGFloat) -> NSBitmapImageRep? {
        let ratio = min(1, side / CGFloat(max(image.width, image.height)))
        let width = Int(CGFloat(image.width) * ratio), height = Int(CGFloat(image.height) * ratio)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // 투명한 곳은 JPEG에서 검게 나와 흰 바탕을 깐다
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map(NSBitmapImageRep.init(cgImage:))
    }
}

struct ProblemReportView: View {
    @ObservedObject var model: ProblemReportModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("무엇이 이상한가요?").font(.system(size: 13, weight: .semibold))
            TextEditor(text: $model.draft)
                .font(.system(size: 12))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("첫 줄이 메일 제목이 됩니다").foregroundStyle(.secondary)
                Spacer()
                Text("\(model.draft.count) / \(ProblemReporter.userTextLimit)")
                    .foregroundStyle(model.draft.count > ProblemReporter.userTextLimit ? Palette.red : .secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 11))

            Text("문제 있는 곳을 ⌃⌘⇧4로 찍고 [붙여넣기]를 누르거나, 그림 파일을 이 창에 끌어다 놓으세요")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(model.shots) { shot in thumbnail(shot) }
                ForEach(0..<model.converting, id: \.self) { _ in
                    ProgressView().controlSize(.small).frame(width: 120, height: 84)
                }
                if model.canAdd {
                    VStack(spacing: 6) {
                        Button("붙여넣기") { model.paste() }.controlSize(.small)
                        Button("그림 고르기…") { model.choose() }.controlSize(.small)
                    }
                    .frame(width: 120, height: 84)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(model.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
            }

            Text("빌드, macOS, 화면 구성, 최근 기록이 함께 갑니다. 키·토큰은 보내지 않고, 그림은 메일에만 붙어 갑니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let result = model.result {
                    Text(result).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if model.sending { ProgressView().controlSize(.small) }
                Button("닫기", action: close).keyboardShortcut(.cancelAction)
                Button("보내기") { model.send(close: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend)
            }
        }
        .padding(16)
        .frame(width: 460)
        // 창 어디에 놓아도 받는다
        .onDrop(of: [.image, .fileURL], isTargeted: $model.dropTargeted) { model.drop($0) }
    }

    private func thumbnail(_ shot: ProblemReportModel.Shot) -> some View {
        Image(nsImage: shot.thumbnail).resizable().aspectRatio(contentMode: .fit)
            .frame(width: 120, height: 84)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .overlay(alignment: .topTrailing) {
                Button { model.remove(shot) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(3)
                .accessibilityLabel("이 그림 빼기")
            }
    }
}
