import Foundation

/// `~/.claude/projects` 재귀 스캔 + 증분 파싱.
/// 파일별 마지막 오프셋을 기억해 새로 추가된 줄만 읽는다. 폴링 방식(기본 3초).
public final class JSONLWatcher {

    public let rootDirectory: URL
    /// 시작 풀스캔 지연 방지: 최근 N일 내 수정된 파일만 읽는다 (§8 리스크 대응).
    public var maxFileAge: TimeInterval = 8 * 24 * 60 * 60

    private var offsets: [String: UInt64] = [:]   // 파일 경로 → 읽은 바이트 수
    private let fileManager = FileManager.default

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? ClaudePaths.configDirectory.appendingPathComponent("projects")
    }

    /// 1회 스캔: 새로 추가된 줄에서 파싱된 이벤트를 반환. (중복 제거는 UsageStore 담당)
    public func scan(now: Date = Date()) -> [UsageEvent] {
        var events: [UsageEvent] = []
        // 폴더 자체가 심볼릭 링크면 enumerator가 아무것도 돌려주지 않는다 (기록을 다른 디스크로 옮긴 경우)
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate,
                  let size = values.fileSize
            else { continue }
            guard now.timeIntervalSince(mtime) < maxFileAge else { continue }

            let path = url.path
            var offset = offsets[path] ?? 0
            if UInt64(size) < offset { offset = 0 }   // 파일이 줄었으면(교체됨) 처음부터
            guard UInt64(size) > offset else { continue }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.readToEnd(), !data.isEmpty else { continue }
                let consumed = parse(chunk: data, into: &events)
                offsets[path] = offset + consumed
            } catch { continue }
        }
        return events
    }

    /// 청크를 개행 단위로 파싱. 마지막 불완전한 줄(쓰기 도중)은 남겨두고,
    /// 소비한 바이트 수를 반환해 다음 스캔에서 이어 읽는다.
    private func parse(chunk: Data, into events: inout [UsageEvent]) -> UInt64 {
        let newline = UInt8(ascii: "\n")
        var lineStart = chunk.startIndex
        var consumed = 0
        var index = chunk.startIndex
        while index < chunk.endIndex {
            if chunk[index] == newline {
                let line = chunk[lineStart..<index]
                if !line.isEmpty, let event = JSONLParser.parse(line: Data(line)) {
                    events.append(event)
                }
                lineStart = chunk.index(after: index)
                consumed = chunk.distance(from: chunk.startIndex, to: lineStart)
            }
            index = chunk.index(after: index)
        }
        return UInt64(consumed)
    }
}
