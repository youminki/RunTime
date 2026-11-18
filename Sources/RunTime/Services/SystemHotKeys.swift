import AppKit
import Carbon.HIToolbox
import WindowKit

/// macOS 시스템 단축키 (시스템 설정 > 키보드 > 키보드 단축키). 바꾼 것만 com.apple.symbolichotkeys에 남아,
/// 바꾸지 않은 것은 macOS 기본값으로 채운다. 창 배치 단축키와 겹치는지 볼 때 쓴다.
enum SystemHotKeys {
    struct Entry {
        let name: String
        let key: WindowKey
    }

    /// 창 배치와 겹칠 만한 기본 단축키 (id: 이름, 키, 보조키, 기본으로 켜짐).
    private static let defaults: [Int: (String, Int, NSEvent.ModifierFlags, Bool)] = [
        32: ("Mission Control", kVK_UpArrow, .control, true),
        33: ("앱 윈도우", kVK_DownArrow, .control, true),
        79: ("왼쪽 공간으로 이동", kVK_LeftArrow, .control, true),
        81: ("오른쪽 공간으로 이동", kVK_RightArrow, .control, true),
        60: ("이전 입력 소스", kVK_Space, .control, true),
        61: ("다음 입력 소스", kVK_Space, [.control, .option], true),
        64: ("Spotlight", kVK_Space, .command, true),
        65: ("Finder 검색 윈도우", kVK_Space, [.command, .option], true),
        28: ("화면 캡처", kVK_ANSI_3, [.command, .shift], true),
        30: ("선택 영역 캡처", kVK_ANSI_4, [.command, .shift], true),
        184: ("스크린샷 도구", kVK_ANSI_5, [.command, .shift], true),
        36: ("데스크탑 보기", kVK_F11, [], true),
        52: ("Dock 가리기", kVK_ANSI_D, [.command, .option], true),
        98: ("도움말 메뉴", kVK_ANSI_Slash, [.command, .shift], true),
        15: ("확대/축소 켜기", kVK_ANSI_8, [.command, .option], false),
        17: ("확대", kVK_ANSI_Equal, [.command, .option], false),
        19: ("축소", kVK_ANSI_Minus, [.command, .option], false),
        21: ("색상 반전", kVK_ANSI_8, [.command, .option, .control], false),
    ]

    static func enabled() -> [Entry] {
        let stored = (UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") as? [String: [String: Any]]) ?? [:]
        var entries: [Int: Entry] = [:]
        for (id, (name, code, flags, on)) in defaults where on {
            entries[id] = Entry(name: name, key: key(code, flags))
        }
        for (idText, value) in stored {
            guard let id = Int(idText) else { continue }
            let name = defaults[id]?.0 ?? "시스템 단축키 \(id)"
            guard (value["enabled"] as? Bool) == true,
                  let parameters = (value["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3,
                  parameters[1] != 65535 else {
                entries[id] = nil
                continue
            }
            entries[id] = Entry(name: name, key: key(parameters[1], NSEvent.ModifierFlags(rawValue: UInt(parameters[2]))))
        }
        return entries.values.sorted { $0.name < $1.name }
    }

    private static func key(_ code: Int, _ flags: NSEvent.ModifierFlags) -> WindowKey {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        return WindowKey(carbonKeyCode: UInt32(code), carbonModifiers: UInt32(carbon))
    }
}
