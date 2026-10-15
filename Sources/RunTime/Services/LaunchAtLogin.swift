import Foundation
import ServiceManagement

/// 로그인 시 자동 시작 (SMAppService, macOS 13+). 번들 앱에서만 동작.
enum LaunchAtLogin {

    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        available && SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        guard available else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// 처음 설치한 사람은 로그인할 때 바로 뜨도록 한 번 켠다. 그 뒤에 끄면 다시 켜지 않는다.
    /// 이미 쓰던 사람(옛 TokenCat 포함)은 그때 고른 값을 따른다.
    static func enableOnFirstInstall() {
        let key = "launchAtLoginDefaulted"
        let defaults = UserDefaults.standard
        guard available, !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        guard LegacyMigration.isFreshInstall else { return }
        try? set(true)
    }

    /// 자동 시작 기록은 번들 ID와 앱 경로에 묶여 있어서 옛 TokenCat 앱의 기록은 이어지지 않는다.
    /// install.sh가 옛 앱에서 켜져 있던 것을 남겨 두면 이 앱으로 다시 등록한다.
    static func restoreAfterRename() {
        let key = "restoreLaunchAtLogin"
        guard available, UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        try? set(true)
    }
}
