import Foundation

/// 옛 이름(TokenCat)으로 쓰던 설정과 파일을 처음 켤 때 한 번 옮긴다.
/// 번들 ID와 폴더 이름이 바뀌어서, 옮기지 않으면 설정·최고 점수·받은 펫이 보이지 않는다.
enum LegacyMigration {
    static let oldBundleID = "dev.tokencat.TokenCat"
    private static let doneKey = "migratedFromTokenCat"

    /// 이 Mac에서 처음 켠 것인지. 아래에서 설정을 쓰기 전에 정해 둬야 새 설치와 기존 사용자를 가를 수 있다.
    private(set) static var isFreshInstall = false

    /// 설정을 읽는 코드보다 먼저 불러야 한다. 옛 설정은 되돌아갈 수 있게 지우지 않는다.
    static func run() {
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier, id != oldBundleID else { return }
        // install.sh가 앱을 켜기 전에 쓰는 키는 사용 기록이 아니다
        let written = (defaults.persistentDomain(forName: id) ?? [:]).keys
            .filter { $0 != "menuBarPlaced" && $0 != "restoreLaunchAtLogin" }
        isFreshInstall = written.isEmpty && defaults.persistentDomain(forName: oldBundleID) == nil
        guard !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: oldBundleID) {
            var current = defaults.persistentDomain(forName: id) ?? [:]
            for (key, value) in old {
                // 메뉴바 자리는 상태 항목 이름이 붙은 키에 남는다 ("NSStatusItem Preferred Position TokenCat")
                let renamed = key.hasPrefix("NSStatusItem") && key.hasSuffix(" TokenCat")
                    ? String(key.dropLast("TokenCat".count)) + "RunTime" : key
                if current[renamed] == nil { current[renamed] = value }
            }
            defaults.setPersistentDomain(current, forName: id)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        move(library.appendingPathComponent("Application Support/TokenCat"),
             to: library.appendingPathComponent("Application Support/RunTime"))
        move(library.appendingPathComponent("Logs/TokenCat"), to: library.appendingPathComponent("Logs/RunTime"))
        defaults.set(true, forKey: doneKey)
    }

    private static func move(_ old: URL, to new: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: old.path), !files.fileExists(atPath: new.path) else { return }
        try? files.moveItem(at: old, to: new)
    }
}
