import Foundation

/// 화면 레이어 자리(`ScreenSnapshot.places`)를 화면마다 따로 둔 파일. 기록 파일에 함께 두면 32MB 가운데 21MB를 차지하고
/// 앱 메모리에 150MB 넘게 올라가는데, 자리는 화면 상세를 열거나 변경에 상자를 붙일 때만 쓴다.
/// 기록 파일 옆 `<기록 이름>-places/<파일 키>/<프레임>.json`에 둔다.
public enum DesignPlaceFile {
    public typealias Places = [String: SpecPlace]

    /// 기록 파일 옆 폴더 (`RUNTIME_DESIGN_HISTORY`로 바꾼 기록이면 그 옆).
    public static func folder(for history: URL = DesignHistoryFile.defaultURL) -> URL {
        history.deletingLastPathComponent()
            .appendingPathComponent(history.deletingPathExtension().lastPathComponent + "-places", isDirectory: true)
    }

    /// 파일 키와 프레임 ID는 피그마가 정한 글이라 경로에 쓸 수 없는 글자를 바꾼다 (`12:34` → `12_34`).
    static func safe(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    static func url(_ fileKey: String, _ frameID: String, in folder: URL) -> URL {
        folder.appendingPathComponent(safe(fileKey), isDirectory: true).appendingPathComponent(safe(frameID) + ".json")
    }

    public static func read(_ fileKey: String, _ frameID: String, in folder: URL) -> Places? {
        guard let data = try? Data(contentsOf: url(fileKey, frameID, in: folder)) else { return nil }
        return try? JSONDecoder().decode(Places.self, from: data)
    }

    public static func write(_ places: Places, _ fileKey: String, _ frameID: String, in folder: URL) throws {
        let target = url(fileKey, frameID, in: folder)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(places).write(to: target, options: .atomic)
    }

    /// 기록에 없는 화면·파일의 자리 파일을 지운다. 기록에서 빠진 화면이 쌓이지 않게 저장할 때 부른다.
    public static func prune(keeping history: DesignHistory, in folder: URL) {
        let manager = FileManager.default
        let kept = Dictionary(history.files.map { key, file in (safe(key), Set(file.screens.keys.map { safe($0) + ".json" })) },
                              uniquingKeysWith: { $0.union($1) })
        guard let fileFolders = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for fileFolder in fileFolders {
            guard let frames = kept[fileFolder.lastPathComponent] else {
                try? manager.removeItem(at: fileFolder)
                continue
            }
            for item in (try? manager.contentsOfDirectory(at: fileFolder, includingPropertiesForKeys: nil)) ?? []
            where !frames.contains(item.lastPathComponent) {
                try? manager.removeItem(at: item)
            }
        }
    }

    /// 기록의 화면에서 자리를 떼어 낸다 (변경의 비교 기준인 `mergeBase`는 작아서 그대로 둔다). 뗀 자리를 돌려준다.
    public static func detach(_ history: inout DesignHistory) -> [(fileKey: String, frameID: String, places: Places)] {
        var moved: [(String, String, Places)] = []
        for key in history.files.keys {
            moved += detach(&history, fileKey: key)
        }
        return moved
    }

    public static func detach(_ history: inout DesignHistory, fileKey: String) -> [(fileKey: String, frameID: String, places: Places)] {
        guard var file = history.files[fileKey] else { return [] }
        var moved: [(String, String, Places)] = []
        for (frame, screen) in file.screens {
            guard let places = screen.places else { continue }
            moved.append((fileKey, frame, places))
            file.screens[frame]?.places = nil
        }
        if !moved.isEmpty { history.files[fileKey] = file }
        return moved
    }

    /// 떼어 둔 자리를 그 파일의 화면에 다시 채운다. 가져온 화면과 견줘 지운 문구의 자리를 변경에 붙이려고 쓴다.
    public static func attach(_ places: [String: Places], to history: inout DesignHistory, fileKey: String) {
        guard var file = history.files[fileKey], !places.isEmpty else { return }
        for (frame, value) in places where file.screens[frame] != nil && file.screens[frame]?.places == nil {
            file.screens[frame]?.places = value
        }
        history.files[fileKey] = file
    }

    /// 그 파일 화면들의 자리를 모두 읽는다 (뒤 스레드에서 부른다).
    public static func readAll(_ fileKey: String, frames: [String], in folder: URL) -> [String: Places] {
        Dictionary(uniqueKeysWithValues: frames.compactMap { frame in read(fileKey, frame, in: folder).map { (frame, $0) } })
    }
}

extension DesignHistoryFile {
    /// 기록을 읽고 화면의 자리를 떼어 자리 파일로 옮긴다. 옛 기록이면 자리 파일을 먼저 다 쓴 뒤 가벼워진 기록을 저장해,
    /// 중간에 끊겨도 다음에 켤 때 같은 일을 다시 할 뿐 자리를 잃지 않는다. 자리 파일을 쓰지 못하면 자리를 기록에 남긴다.
    public static func loadDetachingPlaces(_ url: URL = defaultURL) throws -> DesignHistory {
        var history = try load(url)
        let folder = DesignPlaceFile.folder(for: url)
        var light = history
        let moved = DesignPlaceFile.detach(&light)
        guard !moved.isEmpty else { return history }
        do {
            for item in moved { try DesignPlaceFile.write(item.places, item.fileKey, item.frameID, in: folder) }
            try save(light, to: url)
            history = light
        } catch {
            // 옮기지 못했으면 이번에는 자리를 메모리에 둔 채 쓴다 (다음에 다시 옮긴다)
        }
        return history
    }
}
