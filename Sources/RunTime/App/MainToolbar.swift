import AppKit
import Combine

/// 앱 창의 도구 막대. Finder·시스템 설정처럼 신호등 단추 옆에 뒤로·앞으로를 두고, 그 옆에 지금 화면 이름을 창 제목으로 보인다.
/// 오른쪽 끝에는 지금 러너 얼굴과 함께 펫 꺼내기·넣기를 두어 어느 화면에서든 한 번에 누른다.
/// SwiftUI로 제목 막대 아래에 막대를 그리면 신호등과 줄이 맞지 않고 그 자리를 끌어 창을 옮길 수 없어 AppKit 도구 막대를 쓴다.
final class MainToolbar: NSObject, NSToolbarDelegate {
    private static let back = NSToolbarItem.Identifier("main.back")
    private static let forward = NSToolbarItem.Identifier("main.forward")
    private static let pet = NSToolbarItem.Identifier("main.pet")

    private let navigator: MainNavigator
    private weak var window: NSWindow?
    private let backButton = MainToolbar.button("chevron.left", label: "뒤로")
    private let forwardButton = MainToolbar.button("chevron.right", label: "앞으로")
    private let petButton = NSButton(title: "펫 꺼내기", target: nil, action: nil)
    /// 아이콘을 다시 그릴지 보려고 마지막으로 그린 러너를 기억한다.
    private var iconRunner: String?
    private var cancellables: Set<AnyCancellable> = []

    init(navigator: MainNavigator, window: NSWindow) {
        self.navigator = navigator
        self.window = window
        super.init()
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        petButton.target = self
        petButton.action = #selector(togglePet)
        petButton.bezelStyle = .texturedRounded
        petButton.imagePosition = .imageLeading
        petButton.imageHugsTitle = true
        petButton.font = .systemFont(ofSize: 12, weight: .semibold)
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
        // 펫을 꺼내고 넣거나 러너를 바꾸면 단추 글자와 얼굴을 맞춘다
        updatePet()
        AppSettings.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePet() }
            .store(in: &cancellables)
    }

    private func updatePet() {
        let settings = AppSettings.shared
        let shown = settings.desktopPet
        petButton.title = shown ? "펫 넣기" : "펫 꺼내기"
        petButton.toolTip = shown ? "화면에 꺼내 둔 펫을 넣어요"
            : "펫을 화면에 꺼내요. 끌어다 놓으면 그 자리에 머물고, 오른쪽 클릭하면 옵션이 나와요"
        petButton.setAccessibilityLabel(petButton.title)
        guard iconRunner != settings.runnerID else { return }
        iconRunner = settings.runnerID
        petButton.image = Self.runnerIcon(settings.character)
    }

    /// 지금 러너가 서 있는 모습을 작은 정사각형 아이콘으로. 그림 영역에 맞춰 가운데에 둔다.
    static func runnerIcon(_ character: RunnerCharacter, size: CGFloat = 20) -> NSImage {
        let scene = CharacterScene(rig: character.rig, pose: CharacterPose(activity: .stand))
        let bounds = scene.placedBounds
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else { return false }
            let k = size / max(bounds.width, bounds.height)
            cg.translateBy(x: (size - bounds.width * k) / 2 - bounds.minX * k, y: (size - bounds.height * k) / 2 - bounds.minY * k)
            cg.scaleBy(x: k, y: k)
            let theme = character.theme(.natural)
            scene.draw(in: cg, look: CharacterLook(rich: true, palette: theme.richPalette(character.rig.palette, phase: 0),
                                                   tint: .white, outline: max(0.32, 1.1 / k)))
            return true
        }
    }

    @objc private func togglePet() { DesktopPet.shared.toggle() }

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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.back, Self.forward, .flexibleSpace, Self.pet]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.back, Self.forward, .flexibleSpace, Self.pet]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Self.pet {
            item.view = petButton
            item.label = "펫 꺼내기"
            return item
        }
        let isBack = identifier == Self.back
        item.view = isBack ? backButton : forwardButton
        item.label = isBack ? "뒤로" : "앞으로"
        // 제목 앞(왼쪽)에 붙는 이동 단추로 둔다
        item.isNavigational = true
        return item
    }
}
