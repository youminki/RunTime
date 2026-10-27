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
    /// 화면을 다시 그릴 때마다 파일을 읽지 않게 한 번 읽은 그림을 둔다. 세로로 긴 화면은 한 장에 십수 MB라, 몇 주씩 켜 두는 앱이 계속 늘지 않게 최근 것만 둔다.
    private let decoded: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 30
        return cache
    }()

    func image(_ url: URL) -> NSImage? {
        if let image = decoded.object(forKey: url as NSURL) { return image }
        let image = NSImage(contentsOf: url)
        if let image { decoded.setObject(image, forKey: url as NSURL) }
        return image
    }
    /// 이보다 많으면 오래된 것부터 지운다 (반으로 줄인 PNG라 장당 수백 KB).
    nonisolated static let keepCount = 400

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
        load(fileKey: fileKey, nodeIDs: [nodeID], version: version)
    }

    /// 한 번에 그려 달라고 할 프레임 수. 많으면 피그마가 다 그릴 때까지 첫 장도 늦어진다.
    static let batchSize = 6

    /// 같은 버전의 프레임을 한 요청으로 받는다. 맨 앞이 지금 볼 것이고, 뒤는 이어서 누를 것을 미리 받는다.
    func load(fileKey: String, nodeIDs: [String], version: String) {
        var wanted: [String] = []
        for nodeID in nodeIDs where !wanted.contains(nodeID) {
            let key = Self.key(fileKey: fileKey, nodeID: nodeID, version: version)
            let url = Self.file(key)
            if FileManager.default.fileExists(atPath: url.path) {
                if states[key] != .ready(url) { states[key] = .ready(url) }
            } else if states[key] != .loading {
                wanted.append(nodeID)
            }
        }
        guard !wanted.isEmpty else { return }
        guard let token = DesignSyncSettings.shared.token else {
            for nodeID in wanted { states[Self.key(fileKey: fileKey, nodeID: nodeID, version: version)] = .missing("피그마 토큰이 없어 이미지를 받지 못했습니다") }
            return
        }
        for chunk in stride(from: 0, to: wanted.count, by: Self.batchSize).map({ Array(wanted[$0..<min($0 + Self.batchSize, wanted.count)]) }) {
            for nodeID in chunk { states[Self.key(fileKey: fileKey, nodeID: nodeID, version: version)] = .loading }
            Task { await fetch(fileKey: fileKey, nodeIDs: chunk, version: version, token: token) }
        }
    }

    private func fetch(fileKey: String, nodeIDs: [String], version: String, token: String) async {
        let keys = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, Self.key(fileKey: fileKey, nodeID: $0, version: version)) })
        let remote: [String: URL]
        do {
            let data = try await FigmaClient.shared.send(FigmaAPI.imagesRequest(fileKey: fileKey, ids: nodeIDs, version: version, token: token),
                                                         lane: .images)
            remote = try FigmaAPI.parseImages(data)
        } catch {
            let reason = (error as? FigmaAPI.Failure)?.message ?? "이미지를 받지 못했습니다: \(error.localizedDescription)"
            for key in keys.values { states[key] = .missing(reason) }
            return
        }
        // 피그마가 준 주소는 잠깐만 쓸 수 있는 저장소 주소라 토큰 없이 바로, 한꺼번에 받는다
        await withTaskGroup(of: (String, State).self) { group in
            for (nodeID, key) in keys {
                guard let address = remote[nodeID] else {
                    states[key] = .missing("그 버전에는 이 프레임이 없습니다")
                    continue
                }
                let url = Self.file(key)
                group.addTask {
                    do {
                        let (temporary, response) = try await URLSession.shared.download(from: address)
                        // 만료된 주소는 오류 본문을 200이 아닌 상태로 준다. 그대로 두면 깨진 PNG가 남아 다시 받지 않는다
                        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                              NSImage(contentsOf: temporary) != nil else {
                            try? FileManager.default.removeItem(at: temporary)
                            return (key, .missing("이미지를 받지 못했습니다. 잠시 뒤 다시 열어 보세요"))
                        }
                        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                        try? FileManager.default.removeItem(at: url)
                        try FileManager.default.moveItem(at: temporary, to: url)
                        return (key, .ready(url))
                    } catch {
                        return (key, .missing("이미지를 받지 못했습니다: \(error.localizedDescription)"))
                    }
                }
            }
            for await (key, state) in group { states[key] = state }
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
