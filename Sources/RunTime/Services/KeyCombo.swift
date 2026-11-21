import AppKit
import Carbon.HIToolbox
import WindowKit

/// 키 하나와 보조키 조합. modifiers는 Carbon 값(cmdKey 등)이다. 클립보드 기록 단축키를 기록할 때 쓴다.
struct KeyCombo: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
}

extension KeyCombo {
    /// 누른 키로 조합을 만든다. ⌘·⌥·⌃ 가운데 하나는 있어야 한다 (글자만 누르면 글을 쓸 때마다 열린다).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty,
              let name = Self.keyName(event.keyCode) else { return nil }
        var carbon = 0
        var label = ""
        if flags.contains(.control) { carbon |= controlKey; label += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; label += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; label += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; label += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(carbon), label: label + name)
    }

    /// 키 이름은 입력기와 상관없이 자판 자리로 정한다 (한글 입력 중에도 U가 'ㅕ'로 보이지 않게).
    static func keyName(_ code: UInt16) -> String? { KeyName.name(Int(code)) }
}
