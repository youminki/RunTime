import AppKit
import DesignSyncCore
import Foundation

/// 변경 전·후 프레임 이미지. 가져올 때는 받지 않고 상세에서 볼 때만 피그마에 그 버전 그대로 그려 달라고 해서 받는다.
/// 같은 프레임·버전은 다시 받지 않게 이 Mac에 둔다.
@MainActor
final class DesignImages: ObservableObject {
    static let shared = DesignImages()

    enum State: Equatable {
        case loading
        case ready(URL)
        case missing(String)
    }

    @Published private(set) var states: [String: State] = [:]
    /// 화면을 다시 그릴 때마다 파일을 읽지 않게 한 번 읽은 그림을 둔다.
    private var decoded: [URL: NSImage] = [:]

    func image(_ url: URL) -> NSImage? {
        if let image = decoded[url] { return image }
        let image = NSImage(contentsOf: url)
        decoded[url] = image
        return image
    }
    /// 이보다 많으면 오래된 것부터 지운다 (반으로 줄인 PNG라 장당 수백 KB).
    static let keepCount = 400

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunTime/design-images", isDirectory: true)
    }

    private init() {
        Task.detached(priority: .background) { Self.prune() }
    }

    static func key(fileKey: String, nodeID: String, version: String) -> String {
        "\(fileKey)-\(nodeID)-\(version)".replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: ";", with: "_")
    }

    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }

    func state(fileKey: String, nodeID: String, version: String) -> State? {
        let key = Self.key(fileKey: fileKey, nodeID: nodeID, version: version)
        if let state = states[key] { return state }
        let url = Self.file(key)
        return FileManager.default.fileExists(atPath: url.path) ? .ready(url) : nil
    }

    func load(fileKey: String, nodeID: String, version: String) {
        let key = Self.key(fileKey: fileKey, nodeID: nodeID, version: version)
        let url = Self.file(key)
        if FileManager.default.fileExists(atPath: url.path) {
            if states[key] != .ready(url) { states[key] = .ready(url) }
            return
        }
        guard states[key] != .loading else { return }
        guard let token = DesignSyncSettings.shared.token else {
            states[key] = .missing("피그마 토큰이 없어 이미지를 받지 못했습니다")
            return
        }
        states[key] = .loading
        Task {
            do {
                let data = try await FigmaClient.shared.send(FigmaAPI.imagesRequest(fileKey: fileKey, ids: [nodeID], version: version, token: token))
                guard let remote = try FigmaAPI.parseImages(data)[nodeID] else {
                    states[key] = .missing("그 버전에는 이 프레임이 없습니다")
                    return
                }
                // 피그마가 준 주소는 잠깐만 쓸 수 있는 저장소 주소라 토큰 없이 바로 받는다
                let (temporary, _) = try await URLSession.shared.download(from: remote)
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: temporary, to: url)
                states[key] = .ready(url)
            } catch let failure as FigmaAPI.Failure {
                states[key] = .missing(failure.message)
            } catch {
                states[key] = .missing("이미지를 받지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    /// 오래 안 본 이미지부터 지워 개수를 지킨다.
    nonisolated static func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentAccessDateKey]),
              files.count > keepCount else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - keepCount) {
            try? manager.removeItem(at: url)
        }
    }
}
