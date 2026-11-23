import AppKit
import ClipKit
import UsageCore
import WindowKit

/// 클립보드 기록(Pesty에서 옮긴 기능)을 켜고 끈다. 복사한 내용을 이 Mac에 남기므로 기본은 꺼 둔다.
/// 바로 붙여넣기는 창 배치와 같은 손쉬운 사용 권한을 쓰고, 권한이 없으면 복사만 해서 ⌘V는 사람이 누른다.
/// 메뉴와 앱 위임자가 부르기 쉽게 WindowLayout처럼 MainActor로 두지 않고, ClipKit을 부를 때만 메인 스레드임을 밝힌다.
final class Clipboard: ObservableObject {
    static let shared = Clipboard()

    private static let enabledKey = "clipboardEnabled"

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            MainActor.assumeIsolated { enabled ? ClipRuntime.start() : ClipRuntime.stop() }
            WindowControl.shared.reservedKeysChanged()
        }
    }

    var openSettings: () -> Void = {} {
        didSet {
            let open = openSettings
            MainActor.assumeIsolated { ClipRuntime.openSettings = open }
        }
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// 앱이 뜰 때 한 번 (메인 스레드). shared는 창 배치가 다른 스레드에서 먼저 만들 수 있어 init에서 하지 않는다.
    @MainActor private static func installSecrets() {
        if !WorkLogSettings.keychainOff { ClipRuntime.secrets = keychainSecrets }
    }

    /// 계정 비밀번호는 업무 일지 키처럼 `security`로 만든 키체인 항목에 둔다. 다시 빌드해도 허용을 또 묻지 않는다.
    /// 한글·기호가 섞인 값도 `security -w`가 그대로 돌려주게 base64로 감싸 둔다.
    private static let keychainService = "RunTime clipboard accounts"
    private static let keychainSecrets = ClipSecrets(
        read: { account in
            guard let data = ClaudeLogin.readKeychain(service: keychainService, account: account),
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let raw = Data(base64Encoded: text) else { return nil }
            return String(data: raw, encoding: .utf8)
        },
        write: { value, account in
            ClaudeLogin.writeKeychain(Data(Data(value.utf8).base64EncodedString().utf8), service: keychainService, account: account)
        },
        delete: { account in ClaudeLogin.deleteKeychain(service: keychainService, account: account) })

    func launch() {
        MainActor.assumeIsolated {
            Self.installSecrets()
            if enabled { ClipRuntime.start() }
        }
    }

    func toggleBar() { MainActor.assumeIsolated { ClipRuntime.toggleBar() } }

    var hotKey: WindowKey {
        let stored = ClipPreferences.storedHotKey
        return WindowKey(carbonKeyCode: UInt32(stored.code), carbonModifiers: UInt32(stored.modifiers))
    }

    var hotKeyLabel: String { MainActor.assumeIsolated { ClipPreferences.shared.hotKeyLabel } }

    /// 창 배치가 기본 단축키에서 비워 둘 조합. 켜 두었을 때만.
    static var reservedKeys: [WindowKey] {
        shared.enabled ? [shared.hotKey] : []
    }

    /// 새 조합을 쓸 수 있으면 nil, 아니면 까닭.
    @MainActor func setHotKey(_ combo: KeyCombo) -> String? {
        let key = WindowKey(carbonKeyCode: combo.keyCode, carbonModifiers: combo.modifiers)
        if PetKeys.fallbackKeys.contains(key) { return "RunTime의 다른 단축키가 쓰는 조합입니다." }
        ClipPreferences.shared.setHotKey(code: Int(combo.keyCode), modifiers: Int(combo.modifiers))
        WindowControl.shared.reservedKeysChanged()
        return enabled && !ClipRuntime.hotKeyRegistered ? "다른 앱이 이 조합을 쓰고 있어 등록하지 못했습니다." : nil
    }
}
