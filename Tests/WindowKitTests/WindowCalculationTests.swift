import AppKit
import Testing
@testable import WindowKit

// Rectangle의 계산은 화면 아래쪽이 y=0인 좌표를 쓴다. 메뉴바·Dock을 뺀 화면을 1200×800으로 둔다
private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
private let window = Window(id: 1, rect: CGRect(x: 100, y: 100, width: 400, height: 300))

private func rect(_ action: WindowAction, last: RectangleAction? = nil, in frame: CGRect = screen) -> CGRect? {
    let params = RectCalculationParameters(window: window, visibleFrameOfScreen: frame, action: action, lastAction: last)
    return WindowCalculationFactory.calculationsByAction[action]?.calculateRect(params).rect
}

@Test func halvesSplitTheScreen() {
    #expect(rect(.leftHalf) == CGRect(x: 0, y: 0, width: 600, height: 800))
    #expect(rect(.rightHalf) == CGRect(x: 600, y: 0, width: 600, height: 800))
    #expect(rect(.topHalf) == CGRect(x: 0, y: 400, width: 1200, height: 400))
    #expect(rect(.bottomHalf) == CGRect(x: 0, y: 0, width: 1200, height: 400))
}

@Test func cornersAreQuarters() {
    #expect(rect(.topLeft) == CGRect(x: 0, y: 400, width: 600, height: 400))
    #expect(rect(.bottomRight) == CGRect(x: 600, y: 0, width: 600, height: 400))
}

@Test func thirdsSplitTheLongSide() {
    #expect(rect(.firstThird) == CGRect(x: 0, y: 0, width: 400, height: 800))
    #expect(rect(.centerThird) == CGRect(x: 400, y: 0, width: 400, height: 800))
    #expect(rect(.lastTwoThirds) == CGRect(x: 400, y: 0, width: 800, height: 800))
}

@Test func thirdsRunTopToBottomOnPortraitScreens() {
    let portrait = CGRect(x: 0, y: 0, width: 800, height: 1200)
    #expect(rect(.firstThird, in: portrait) == CGRect(x: 0, y: 800, width: 800, height: 400))
}

@Test func gridsSplitIntoEqualCells() {
    #expect(rect(.middleCenterNinth) == CGRect(x: 400, y: 800 / 3, width: 400, height: 800 / 3))
    #expect(rect(.topLeftSixteenth) == CGRect(x: 0, y: 600, width: 300, height: 200))
    #expect(rect(.firstVerticalSixth)?.width == 200)
}

@Test func maximizeFillsAndCenterKeepsSize() {
    #expect(rect(.maximize) == screen)
    #expect(rect(.center) == CGRect(x: 400, y: 250, width: 400, height: 300))
}

@Test func repeatingLeftHalfCyclesThroughSizes() {
    // 기본 순서는 1/2 → 2/3 → 1/3. 이 Mac에 저장된 순환 크기·모서리 설정을 읽지 않게 기본값으로 고정하고 끝나면 되돌린다
    let savedChanged = Defaults.cycleSizesIsChanged.enabled
    let savedCooperative = Defaults.cooperativeCornerResize.enabled
    Defaults.cycleSizesIsChanged.enabled = false
    Defaults.cooperativeCornerResize.enabled = false
    defer {
        Defaults.cycleSizesIsChanged.enabled = savedChanged
        Defaults.cooperativeCornerResize.enabled = savedCooperative
    }
    let half = LeftRightHalfCalculation()
    func repeated(_ count: Int) -> CGRect {
        let last = count == 0 ? nil : RectangleAction(action: .leftHalf, rect: .zero, count: count)
        return half.calculateRepeatedRect(RectCalculationParameters(window: window, visibleFrameOfScreen: screen,
                                                                    action: .leftHalf, lastAction: last)).rect
    }
    #expect(repeated(0).width == 600)
    #expect(repeated(1).width == 800)
    #expect(repeated(2).width == 400)
}

@Test func everyRectangleActionIsListedOnce() {
    let listed = WindowCommand.groups.flatMap(\.commands).map(\.action)
    #expect(Set(listed) == Set(WindowAction.active))
    #expect(listed.count == Set(listed).count)
    #expect(!WindowCommand.groups.contains { $0.title == "기타" }, "묶음에 넣지 않은 새 명령이 있습니다")
}

@Test func everyCommandHasAKoreanTitle() {
    for command in WindowCommand.all {
        #expect(command.title.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }, "\(command.name): \(command.title)")
    }
}

@Test func menuIconsAreBundled() {
    #expect(WindowCommand.named("leftHalf")?.image != nil)
    #expect(WindowMenu.statusIcon.representations.count == 2)
}

@Test func presetsDoNotGiveOneComboToTwoCommands() {
    for alternate in [true, false] {
        var seen = Set<String>()
        for action in WindowAction.active {
            guard let shortcut = alternate ? action.alternateDefault : action.spectacleDefault else { continue }
            #expect(seen.insert("\(shortcut.keyCode)-\(shortcut.modifierFlags)").inserted, "\(action.name)")
        }
    }
}

@Test func shortcutsUseKeyPositionsAndSurviveTheDictionaryForm() {
    let shortcut = MASShortcut(keyCode: 123, modifierFlags: [.control, .option])
    #expect(shortcut.description == "⌃⌥←")
    let dict = MASDictionaryTransformer().reverseTransformedValue(shortcut)
    #expect(MASDictionaryTransformer().transformedValue(dict) as? MASShortcut == shortcut)
    #expect(shortcut.keyCodeStringForKeyEquivalent == String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
    #expect(WindowKey(MouseButtonShortcut(buttonNumber: 3, modifierFlags: [])).label == "버튼 4")
}

@Test func essentialsAreListedCommands() {
    #expect(Set(WindowCommand.essentials).isSubset(of: Set(WindowCommand.all)))
    #expect(WindowCommand.essentials.count == Set(WindowCommand.essentials).count)
}

@Test func repeatModesReadBackWhatTheySet() {
    for mode in WindowRepeatMode.allCases {
        #expect(WindowRepeatMode.allCases.first { $0.mode == mode.mode } == mode)
    }
}

@Test func rectangleStringsAreKorean() {
    #expect(L("Next Display") == "다음 모니터로")
    #expect(L("Button 5") == "버튼 5")
    #expect(L("unknown") == "unknown")
}

@Test func snapshotsKeepWindowsThatAreOnlyHidden() {
    func entry(_ app: String, _ id: CGWindowID?, x: CGFloat) -> SavedWindowLayout.Entry {
        SavedWindowLayout.Entry(bundleID: app, appName: app, title: "", frame: CGRect(x: x, y: 0, width: 100, height: 100), windowID: id)
    }
    let old = [entry("chrome", 1, x: 0), entry("chrome", 2, x: 200), entry("code", 3, x: 400), entry("closed", 4, x: 0), entry("legacy", nil, x: 0)]
    // 전체 화면 동영상만 보이는 동안 찍어도 다른 데스크톱의 창(2, 3)은 열려 있으면 남는다
    let merged = WindowLayouts.merge(old: old, new: [entry("chrome", 1, x: 50)], alive: [1, 2, 3])
    #expect(merged.map(\.windowID) == [1, 2, 3, nil])
    #expect(merged.first?.frame.minX == 50)
    // 창 번호가 없는 예전 기억은 그 앱 창을 새로 보면 버린다
    #expect(WindowLayouts.merge(old: old, new: [entry("legacy", 9, x: 0)], alive: [9]).map(\.windowID) == [9])
}
