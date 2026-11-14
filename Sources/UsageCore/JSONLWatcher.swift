import Foundation

/// `~/.claude/projects` 재귀 스캔 + 증분 파싱.
/// 파일별 마지막 오프셋을 기억해 새로 추가된 줄만 읽는다. 폴링 방식(기본 3초).
public final class JSONLWatcher {

    public let rootDirectory: URL
    /// 시작 풀스캔 지연 방지: 최근 N일 내 수정된 파일만 읽는다 (§8 리스크 대응).
    /// UsageStore 보관 기간과 맞춘다. 짧으면 다시 켠 직후 주간 요약이 지난주 첫날을 덜 센다.
    public var maxFileAge: TimeInterval = 10 * 24 * 60 * 60

    private var offsets: [String: UInt64] = [:]   // 파일 경로 → 읽은 바이트 수
    /// 한 번에 읽는 양. 기록 파일은 100MB를 넘기도 해, 통째로 읽으면 켤 때 그만큼 메모리를 잡았다 놓는다.
    var chunkSize = 8 * 1024 * 1024
    /// 마지막 scan에서 새로 읽은 줄 가운데 한도에 막힌 기록. 켠 직후 첫 scan에는 지난 기록도 들어 있다.
    public private(set) var limitHits: [LimitHit] = []
    private let fileManager = FileManager.default

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? ClaudePaths.configDirectory.appendingPathComponent("projects")
    }

    /// 1회 스캔: 새로 추가된 줄에서 파싱된 이벤트를 반환. (중복 제거는 UsageStore 담당)
    public func scan(now: Date = Date()) -> [UsageEvent] {
        var events: [UsageEvent] = []
        limitHits = []
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
                // 조각 끝에 걸친 줄은 다음 조각과 이어 읽는다. 조각마다 읽은 자리를 적어, 중간에 실패해도 같은 줄을 다시 세지 않는다
                // 읽은 조각은 오토릴리스 풀에 남아 다 읽을 때까지 풀리지 않아, 조각마다 풀을 비운다
                var pending = Data()
                while try autoreleasepool(invoking: {
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                    pending.append(chunk)
                    let consumed = parse(chunk: pending, into: &events)
                    offset += consumed
                    offsets[path] = offset
                    if consumed > 0 { pending = pending.subdata(in: pending.startIndex + Int(consumed)..<pending.endIndex) }
                    return true
                }) {}
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
                // 사용량이나 한도 표시가 없는 줄(대화 글·이미지·도구 결과)은 JSON으로 풀지 않는다
                if !line.isEmpty, JSONLParser.mayMatter(line) {
                    let data = Data(line)
                    if let event = JSONLParser.parse(line: data) {
                        events.append(event)
                    } else if let hit = JSONLParser.parseLimitHit(line: data) {
                        limitHits.append(hit)
                    }
                }
                lineStart = chunk.index(after: index)
                consumed = chunk.distance(from: chunk.startIndex, to: lineStart)
            }
            index = chunk.index(after: index)
        }
        return UInt64(consumed)
    }
}
