import AppKit

/// 메뉴바 앱은 메뉴 막대를 보이지 않지만, ⌘C·⌘V·⌘X·⌘A·⌘Z는 편집 메뉴 항목의 단축키로만 글 칸에 닿는다.
/// 메뉴가 없으면 설정 창의 키·주소 칸에 붙여 넣을 수 없어 보이지 않는 편집 메뉴를 단다.
enum EditMenu {
    static func install() {
        let main = NSMenu()

        // 첫 항목은 앱 메뉴 자리. 종료(⌘Q)는 일지를 쓰다 잘못 눌러 꺼지지 않게 넣지 않는다
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "RunTime")
        main.addItem(appItem)

        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "서식 없이 붙여넣기", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "윈도우")
        window.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
