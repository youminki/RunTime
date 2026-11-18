import Cocoa

/// 창 배치 메뉴. 열 때마다 다시 만들어 앞에 있는 앱·단축키·모니터 수를 따른다.
/// 메뉴바 메뉴는 앱을 앞으로 가져오지 않으므로, 고른 명령은 앞에 있던 앱의 창에 한다.
public final class WindowMenu: NSObject, NSMenuDelegate {
    public let menu = NSMenu(title: "창 배치")
    public var openSettings: () -> Void = {}
    /// 명령 찾기 패널. nil이면 메뉴에 넣지 않는다.
    public var openPalette: (() -> Void)?

    private let control = WindowControl.shared

    public override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        guard control.running else {
            menu.addItem(item("창 배치가 꺼져 있습니다", enabled: false))
            menu.addItem(.separator())
            menu.addItem(item("창 배치 설정…") { [weak self] in self?.openSettings() })
            return
        }
        addActionItems()
        menu.addItem(.separator())
        if let openPalette {
            let find = item("다른 명령 찾기…", run: openPalette)
            find.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            if #available(macOS 27.0, *) { find.preferredImageVisibility = .visible }
            menu.addItem(find)
        }
        addLayoutItems()
        menu.addItem(.separator())
        if let name = control.frontAppName, name != "RunTime" {
            let ignore = item("‘\(name)’에서 쓰지 않기") { [weak self] in self?.control.toggleFrontApp() }
            ignore.state = control.frontAppIgnored ? .on : .off
            menu.addItem(ignore)
        }
        menu.addItem(item("창 배치 설정…") { [weak self] in self?.openSettings() })
    }

    /// 자주 쓰는 명령만 묶음마다 줄을 나눠 보인다. 나머지 명령은 '다른 명령 찾기'로 쓴다.
    private func addActionItems() {
        let hasWindow = AccessibilityElement.getFrontWindowElement() != nil
        let portrait = NSScreen.main?.frame.isLandscape == false
        let breaks: Set<WindowAction> = [.topLeft, .firstThird, .maximize, .nextDisplay]
        for command in WindowCommand.essentials {
            let action = command.action
            if (action == .nextDisplay || action == .previousDisplay) && NSScreen.screens.count == 1 { continue }
            if breaks.contains(action) { menu.addItem(.separator()) }
            menu.addItem(actionItem(action, enabled: hasWindow, portrait: portrait))
        }
    }

    private func actionItem(_ action: WindowAction, enabled: Bool, portrait: Bool) -> NSMenuItem {
        let entry = item(action.koreanTitle, enabled: enabled) { action.postMenu() }
        // macOS 27부터 메뉴 그림은 항목이 보이겠다고 해야 보인다
        if #available(macOS 27.0, *) { entry.preferredImageVisibility = .visible }
        let image = action.image.copy() as? NSImage
        image?.size = NSSize(width: 18, height: 12)
        if portrait && action.classification == .thirds {
            entry.image = image?.rotated(by: 270)
            entry.image?.isTemplate = true
        } else {
            entry.image = image
        }
        if !ApplicationToggle.shortcutsDisabled, let (key, modifiers) = control.keyEquivalent(for: action), let key = key?.lowercased() {
            entry.keyEquivalent = key
            entry.keyEquivalentModifierMask = modifiers
        }
        return entry
    }

    private func addLayoutItems() {
        let layouts = WindowLayouts.shared
        let holder = NSMenuItem(title: "배치", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "배치")
        sub.autoenablesItems = false
        sub.addItem(item("지금 배치 저장…") { layouts.saveInteractively() })
        if !layouts.saved.isEmpty {
            sub.addItem(.separator())
            for layout in layouts.saved {
                let entry = item(layout.name) { layouts.restore(layout) }
                if let key = control.key(for: layout.slot) {
                    entry.toolTip = key.label
                }
                sub.addItem(entry)
            }
        }
        menu.addItem(holder)
        menu.setSubmenu(sub, for: holder)
    }

    private func item(_ title: String, enabled: Bool = true, run: (() -> Void)? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: run == nil ? nil : #selector(MenuAction.perform(_:)), keyEquivalent: "")
        if let run {
            let target = MenuAction(run)
            entry.target = target
            entry.representedObject = target   // 메뉴 항목이 살아 있는 동안 붙잡아 둔다
        }
        entry.isEnabled = enabled && run != nil
        return entry
    }
}

private final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func perform(_ sender: Any?) { run() }
}

extension WindowControl {
    func keyEquivalent(for action: WindowAction) -> (String?, NSEvent.ModifierFlags)? {
        guard let shortcut = ShortcutCycle.shortcut(for: action), !MouseButtonShortcut.isMouseButton(shortcut) else { return nil }
        return (shortcut.keyCodeStringForKeyEquivalent, shortcut.modifierFlags)
    }
}

extension WindowMenu {
    /// Rectangle 메뉴바 아이콘 (1배·2배 그림을 함께 담는다).
    public static var statusIcon: NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22))
        for name in ["StatusTemplate", "StatusTemplate@2x"] {
            if let url = WindowKitBundle.bundle.url(forResource: name, withExtension: "png", subdirectory: "Icons"),
               let rep = NSImageRep(contentsOf: url) {
                rep.size = image.size
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        return image
    }
}
