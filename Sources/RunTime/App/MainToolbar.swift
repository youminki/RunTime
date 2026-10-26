import AppKit
import Combine

/// 앱 창의 도구 막대. Finder·시스템 설정처럼 신호등 단추 옆에 뒤로·앞으로를 두고, 그 옆에 지금 화면 이름을 창 제목으로 보인다.
/// SwiftUI로 제목 막대 아래에 막대를 그리면 신호등과 줄이 맞지 않고 그 자리를 끌어 창을 옮길 수 없어 AppKit 도구 막대를 쓴다.
final class MainToolbar: NSObject, NSToolbarDelegate {
    private static let back = NSToolbarItem.Identifier("main.back")
    private static let forward = NSToolbarItem.Identifier("main.forward")

    private let navigator: MainNavigator
    private weak var window: NSWindow?
    private let backButton = MainToolbar.button("chevron.left", label: "뒤로")
    private let forwardButton = MainToolbar.button("chevron.right", label: "앞으로")
    private var cancellables: Set<AnyCancellable> = []

    init(navigator: MainNavigator, window: NSWindow) {
        self.navigator = navigator
        self.window = window
        super.init()
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        let toolbar = NSToolbar(identifier: "RunTime.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        navigator.$page.combineLatest(navigator.$back, navigator.$forward)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] page, back, forward in self?.update(page: page, back: back, forward: forward) }
            .store(in: &cancellables)
    }

    private func update(page: MainPage, back: [MainPage], forward: [MainPage]) {
        window?.title = page.title
        backButton.isEnabled = !back.isEmpty
        forwardButton.isEnabled = !forward.isEmpty
        backButton.toolTip = back.last.map { "뒤로: \($0.title)" } ?? "뒤로"
        forwardButton.toolTip = forward.last.map { "앞으로: \($0.title)" } ?? "앞으로"
        // 무대가 있는 화면은 팝오버처럼 어둡게 그려, 막대와 아이콘 줄도 함께 어둡게 맞춘다
        window?.appearance = page.isDark ? NSAppearance(named: .darkAqua) : nil
    }

    @objc private func goBack() { navigator.goBack() }
    @objc private func goForward() { navigator.goForward() }

    private static func button(_ symbol: String, label: String) -> NSButton {
        // 심볼이 없는 macOS에서도 꺼지지 않게 빈 그림으로 둔다
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.setAccessibilityLabel(label)
        return button
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.back, Self.forward] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.back, Self.forward] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let isBack = identifier == Self.back
        item.view = isBack ? backButton : forwardButton
        item.label = isBack ? "뒤로" : "앞으로"
        // 제목 앞(왼쪽)에 붙는 이동 단추로 둔다
        item.isNavigational = true
        return item
    }
}
