import Foundation
import Combine
import UsageCore

/// Claude Code 설정 파일에 승인 대기 알림 훅을 넣고 뺀다. 켜고 끈 상태는 앱이 따로 저장하지 않고 설정 파일에서 읽는다
/// (사용자가 직접 지웠어도 그대로 보이게).
final class PermissionHookFile: ObservableObject {
    static let shared = PermissionHookFile()

    static let markDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(PermissionHook.folder, isDirectory: true)

    @Published private(set) var installed = false
    @Published private(set) var error: String?

    /// 설정 파일을 다른 곳(dotfiles 등)에 두고 링크해 쓰면 링크가 아니라 원본을 고친다.
    private var settingsURL: URL { ClaudePaths.configDirectory.appendingPathComponent("settings.json").resolvingSymlinksInPath() }

    private init() { refresh() }

    func refresh() {
        installed = (try? read()).map(PermissionHook.isInstalled(in:)) ?? false
    }

    func set(_ on: Bool) {
        do {
            let settings = try read()
            let changed = on
                ? PermissionHook.installing(into: settings, command: PermissionHook.command(directory: Self.markDirectory.path))
                : PermissionHook.removing(from: settings)
            if changed != settings {
                guard PermissionHook.isInstalled(in: changed) == on else { throw HookError.unexpectedShape }
                try write(changed)
            }
            if !on { try? FileManager.default.removeItem(at: Self.markDirectory) }
            error = nil
        } catch HookError.unexpectedShape {
            error = "settings.json의 hooks 모양이 달라 바꾸지 않았습니다"
        } catch is OrderedJSON.ParseError {
            error = "settings.json을 읽지 못해 바꾸지 않았습니다"
        } catch {
            self.error = "settings.json을 쓰지 못했습니다: \(error.localizedDescription)"
        }
        refresh()
    }

    private enum HookError: Error { case unexpectedShape }

    /// 파일이 없으면 빈 설정으로 본다.
    private func read() throws -> OrderedJSON {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .object([]) }
        return try OrderedJSON.parse(Data(contentsOf: settingsURL))
    }

    /// 바꾸기 전 파일을 옆에 남겨, 잘못되면 되돌릴 수 있게 한다.
    private func write(_ settings: OrderedJSON) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("runtime-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        } else {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data((settings.serialized() + "\n").utf8).write(to: settingsURL, options: .atomic)
    }
}
