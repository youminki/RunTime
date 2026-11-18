import Foundation

/// Claude Code가 도구 승인을 기다리는지. 사용량 기록에는 승인 창이 남지 않아 오래 걸리는 명령과 구분할 수 없으므로,
/// Claude Code 설정에 넣은 알림 훅(`PermissionHook`)이 승인 창이 6초쯤 떠 있을 때 표시 파일을 남긴다.
/// 그 대화 기록에 표시 뒤의 대화 줄이 생기면(승인·거절·중단 뒤 Claude가 이어 감) 기다림이 끝난 것으로 본다.
public enum PermissionWait {
    public struct Mark: Equatable, Sendable {
        public let transcript: URL
        public let at: Date
    }

    /// 표시가 이보다 오래되면 버린다. 승인 창을 닫지 않고 Claude Code를 끈 경우 등.
    public static let maxAge: TimeInterval = 10 * 60

    /// 훅이 넘긴 알림 JSON에서 승인 대기 표시를 꺼낸다.
    public static func mark(from data: Data, at: Date) -> Mark? {
        guard let json = try? OrderedJSON.parse(data),
              json["notification_type"]?.stringValue == "permission_prompt",
              let path = json["transcript_path"]?.stringValue, !path.isEmpty else { return nil }
        return Mark(transcript: URL(fileURLWithPath: path), at: at)
    }

    /// 기록 끝부분에 `after` 뒤의 사용자·Claude 줄이 있는지. 첫 줄은 잘렸을 수 있어 건너뛴다.
    public static func answered(transcriptTail: Data, after: Date, truncated: Bool) -> Bool {
        var lines = transcriptTail.split(separator: UInt8(ascii: "\n"))
        if truncated, !lines.isEmpty { lines.removeFirst() }
        return lines.contains { line in
            guard let record = try? decoder.decode(Line.self, from: Data(line)),
                  record.type == "user" || record.type == "assistant",
                  let stamp = record.timestamp.flatMap(ISODate.parse) else { return false }
            return stamp > after
        }
    }

    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
    }

    private static let decoder = JSONDecoder()
}

/// 훅이 남긴 표시 파일을 보고 승인을 기다리는 대화가 있는지 판단한다. 끝난 표시는 지운다.
public final class PermissionWaitWatcher {
    public let directory: URL
    /// 기록 끝에서 읽는 양. 도구 결과 한 줄이 이보다 길면 다음 Claude 줄을 기다린다.
    private let tailBytes = 256 * 1024

    public init(directory: URL) {
        self.directory = directory
    }

    public func isWaiting(now: Date) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return false }
        var waiting = false
        for file in files where file.pathExtension == "json" {
            let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(at) < PermissionWait.maxAge,
                  let data = try? Data(contentsOf: file),
                  let mark = PermissionWait.mark(from: data, at: at),
                  !answered(mark) else {
                // 파일을 쓰는 중이면 아직 비어 있을 수 있어 막 생긴 것은 남긴다
                if now.timeIntervalSince(at) > 5 { try? fm.removeItem(at: file) }
                continue
            }
            waiting = true
        }
        return waiting
    }

    private func answered(_ mark: PermissionWait.Mark) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: mark.transcript) else { return true }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return true }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return true }
        return PermissionWait.answered(transcriptTail: tail, after: mark.at, truncated: start > 0)
    }
}

/// Claude Code 설정(`settings.json`)에 승인 대기 알림 훅을 넣고 뺀다. 다른 훅과 설정은 건드리지 않는다.
public enum PermissionHook {
    /// 훅이 표시를 남기는 폴더 이름. 이 글자가 든 명령을 우리 훅으로 알아본다.
    public static let folder = "RunTime/permission-waits"

    public static func command(directory: String) -> String {
        "d=\"\(directory)\"; mkdir -p \"$d\" && cat > \"$d/$(date +%s)-$$.json\""
    }

    public static func isInstalled(in settings: OrderedJSON) -> Bool {
        notificationGroups(settings).contains(where: isOurs)
    }

    /// 이미 있으면 그대로 돌려준다.
    public static func installing(into settings: OrderedJSON, command: String) -> OrderedJSON {
        guard !isInstalled(in: settings) else { return settings }
        let entry = OrderedJSON.object([
            .init("matcher", .string("permission_prompt")),
            .init("hooks", .array([.object([
                .init("type", .string("command")),
                .init("command", .string(command)),
                .init("timeout", .number("5")),
            ])])),
        ])
        let hooks = settings["hooks"] ?? .object([])
        return settings.setting("hooks", hooks.setting("Notification", .array(notificationGroups(settings) + [entry])))
    }

    public static func removing(from settings: OrderedJSON) -> OrderedJSON {
        guard isInstalled(in: settings), let hooks = settings["hooks"] else { return settings }
        // 원래 빈 배열이었으면 빈 배열로 남긴다 (있던 키를 지우지 않는다)
        return settings.setting("hooks", hooks.setting("Notification", .array(notificationGroups(settings).filter { !isOurs($0) })))
    }

    private static func notificationGroups(_ settings: OrderedJSON) -> [OrderedJSON] {
        if case .array(let groups) = settings["hooks"]?["Notification"] { return groups }
        return []
    }

    private static func isOurs(_ group: OrderedJSON) -> Bool {
        guard case .array(let hooks) = group["hooks"] else { return false }
        return hooks.contains { $0["command"]?.stringValue?.contains(folder) == true }
    }
}
