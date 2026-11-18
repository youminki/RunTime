import Foundation
import Testing
@testable import UsageCore

struct OrderedJSONTests {
    static let settings = """
    {
      "env": {
        "A": "1"
      },
      "permissions": {
        "allow": [
          "Read(**)",
          "Bash(git *)"
        ],
        "deny": []
      },
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "node \\"$HOME/x.mjs\\"",
                "timeout": 30
              }
            ]
          }
        ],
        "Notification": []
      },
      "model": "opus",
      "ratio": 1.50,
      "flag": false,
      "none": null,
      "emoji": "한글 \\u00e9"
    }
    """

    @Test func roundTripKeepsOrderAndText() throws {
        let json = try OrderedJSON.parse(Data(Self.settings.utf8))
        #expect(json.serialized() == Self.settings)
        #expect(json["hooks"]?["Stop"] != nil)
        #expect(json["emoji"]?.stringValue == "한글 é")
    }

    @Test func rejectsBrokenFiles() {
        for text in ["", "{", "{\"a\": }", "{\"a\": 1,}", "[1 2]", "{\"a\": \"\\q\"}", "{} x"] {
            #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(text.utf8)) }
        }
    }

    @Test func newStringsAreEscapedLikeJavaScript() {
        #expect(OrderedJSON.string("a \"b\" /c\\").serialized() == #""a \"b\" /c\\""#)
    }
}

struct PermissionHookTests {
    private let command = PermissionHook.command(directory: "/Users/me/Library/Application Support/RunTime/permission-waits")

    @Test func installsOnceAndRemovesOnlyOurs() throws {
        let original = try OrderedJSON.parse(Data(OrderedJSONTests.settings.utf8))
        #expect(!PermissionHook.isInstalled(in: original))
        let installed = PermissionHook.installing(into: original, command: command)
        #expect(PermissionHook.isInstalled(in: installed))
        #expect(PermissionHook.installing(into: installed, command: command) == installed)
        // 다른 훅과 키 순서는 그대로
        #expect(installed["hooks"]?["Stop"] == original["hooks"]?["Stop"])
        let removed = PermissionHook.removing(from: installed)
        #expect(removed.serialized() == OrderedJSONTests.settings)
    }

    @Test func keepsOtherNotificationHooks() throws {
        let other = OrderedJSON.object([.init("hooks", .object([.init("Notification", .array([
            .object([.init("hooks", .array([.object([.init("type", .string("command")), .init("command", .string("say hi"))])]))]),
        ]))]))])
        let installed = PermissionHook.installing(into: other, command: command)
        guard case .array(let groups) = installed["hooks"]?["Notification"] else { Issue.record("배열 아님"); return }
        #expect(groups.count == 2)
        #expect(PermissionHook.removing(from: installed) == other)
    }

    @Test func worksWithoutSettingsOrHooks() {
        let installed = PermissionHook.installing(into: .object([]), command: command)
        #expect(PermissionHook.isInstalled(in: installed))
        #expect(installed["hooks"]?["Notification"]?.serialized(indent: "") .contains("permission_prompt") == true)
    }

    @Test func commandWritesIntoTheMarkFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-hook-\(UUID().uuidString)/RunTime/permission-waits")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", PermissionHook.command(directory: folder.path)]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"notification_type":"permission_prompt","transcript_path":"/tmp/x.jsonl"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(PermissionWait.mark(from: try Data(contentsOf: files[0]), at: Date())?.transcript.path == "/tmp/x.jsonl")
    }
}

struct PermissionWaitTests {
    private static let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    private static func line(_ type: String, _ offset: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"type":"\#(type)","timestamp":"\#(f.string(from: stamp.addingTimeInterval(offset)))"}"#
    }

    @Test func readsOnlyPermissionPrompts() {
        let at = Date()
        #expect(PermissionWait.mark(from: Data(#"{"notification_type":"permission_prompt","transcript_path":"/a.jsonl"}"#.utf8), at: at)
                == .init(transcript: URL(fileURLWithPath: "/a.jsonl"), at: at))
        #expect(PermissionWait.mark(from: Data(#"{"notification_type":"idle_prompt","transcript_path":"/a.jsonl"}"#.utf8), at: at) == nil)
        #expect(PermissionWait.mark(from: Data("".utf8), at: at) == nil)
    }

    @Test func answeredWhenConversationMovesOn() {
        let before = [Self.line("assistant", -10), Self.line("attachment", 2)].joined(separator: "\n")
        #expect(!PermissionWait.answered(transcriptTail: Data(before.utf8), after: Self.stamp, truncated: false))
        // 훅·첨부 기록은 대답이 아니다. 승인·거절 뒤에는 도구 결과(user)나 Claude 줄이 붙는다
        let after = before + "\n" + Self.line("user", 4) + "\n"
        #expect(PermissionWait.answered(transcriptTail: Data(after.utf8), after: Self.stamp, truncated: false))
        // 잘린 첫 줄은 읽지 않는다
        #expect(!PermissionWait.answered(transcriptTail: Data(Self.line("user", 4).utf8), after: Self.stamp, truncated: true))
    }

    @Test func watcherClearsAnsweredAndOldMarks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("runtime-wait-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let marks = root.appendingPathComponent("marks")
        try fm.createDirectory(at: marks, withIntermediateDirectories: true)
        let transcript = root.appendingPathComponent("t.jsonl")
        try Data((Self.line("assistant", -10) + "\n").utf8).write(to: transcript)
        let mark = marks.appendingPathComponent("1.json")
        try Data(#"{"notification_type":"permission_prompt","transcript_path":"\#(transcript.path)"}"#.utf8).write(to: mark)
        try fm.setAttributes([.modificationDate: Self.stamp], ofItemAtPath: mark.path)
        let watcher = PermissionWaitWatcher(directory: marks)

        #expect(watcher.isWaiting(now: Self.stamp.addingTimeInterval(30)))
        #expect(!watcher.isWaiting(now: Self.stamp.addingTimeInterval(PermissionWait.maxAge + 1)))
        #expect(!fm.fileExists(atPath: mark.path))

        try Data(#"{"notification_type":"permission_prompt","transcript_path":"\#(transcript.path)"}"#.utf8).write(to: mark)
        try fm.setAttributes([.modificationDate: Self.stamp], ofItemAtPath: mark.path)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.line("user", 5) + "\n").utf8))
        try handle.close()
        #expect(!watcher.isWaiting(now: Self.stamp.addingTimeInterval(30)))
        #expect(!fm.fileExists(atPath: mark.path))
        // 폴더가 없으면 기다리지 않는다
        #expect(!PermissionWaitWatcher(directory: root.appendingPathComponent("none")).isWaiting(now: Self.stamp))
    }

    @Test func waitingComesFirst() {
        let state = Pace.decide(.init(claudeRate: 50_000, claudeWorking: true, typingRate: 500, keyIdle: 0, away: 0, waiting: true),
                                claude: Thresholds(), keys: .typing(sensitivity: .normal)).state
        #expect(state == .waiting)
        #expect(!CatState.waiting.isMoving)
    }
}
