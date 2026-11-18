import Cocoa
import Carbon.HIToolbox

/// 창 배치 명령 하나 (Rectangle의 WindowAction). 설정 화면·메뉴·명령 찾기가 쓴다.
public struct WindowCommand: Hashable, Identifiable {
    let action: WindowAction
    public var id: Int { action.rawValue }
    /// 설정 키이자 URL 이름의 바탕 (leftHalf 등).
    public var name: String { action.name }
    public var title: String { action.koreanTitle }
    /// 메뉴 아이콘 (Rectangle의 템플릿 그림). 없는 명령은 nil.
    public var image: NSImage? {
        let image = action.image
        return image.size == .zero ? nil : image
    }
    /// URL로 부를 때의 이름 (runtime-window://execute-action?name=left-half).
    public var urlName: String { action.name.map { $0.isUppercase ? "-" + $0.lowercased() : String($0) }.joined() }

    public static func named(_ name: String) -> WindowCommand? {
        WindowAction.active.first { $0.name == name }.map(WindowCommand.init)
    }

    /// 설정 화면 묶음. Rectangle에 새 명령이 생기면 '기타'로 모인다.
    public static let groups: [WindowCommandGroup] = {
        let listed: [(String, [WindowAction])] = [
            ("반쪽", [.leftHalf, .rightHalf, .centerHalf, .topHalf, .bottomHalf]),
            ("네 귀퉁이", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
            ("3분할", [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds]),
            ("세로 3분할", [.topVerticalThird, .middleVerticalThird, .bottomVerticalThird, .topVerticalTwoThirds, .bottomVerticalTwoThirds]),
            ("크기", [.maximize, .almostMaximize, .maximizeHeight, .larger, .smaller, .largerWidth, .smallerWidth,
                    .largerHeight, .smallerHeight, .specified]),
            ("가운데·되돌리기", [.center, .centerProminently, .restore]),
            ("가장자리로", [.moveLeft, .moveRight, .moveUp, .moveDown]),
            ("모니터", [.nextDisplay, .previousDisplay, .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
                     .displaySix, .displaySeven, .displayEight, .displayNine]),
            ("4분할", [.firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .centerThreeFourths, .lastThreeFourths]),
            ("6분할", [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
                     .firstVerticalSixth, .secondVerticalSixth, .thirdVerticalSixth, .fourthVerticalSixth, .fifthVerticalSixth, .lastVerticalSixth]),
            ("귀퉁이 1/3", [.topLeftThird, .topRightThird, .bottomLeftThird, .bottomRightThird]),
            ("8분할", [.topLeftEighth, .topCenterLeftEighth, .topCenterRightEighth, .topRightEighth,
                     .bottomLeftEighth, .bottomCenterLeftEighth, .bottomCenterRightEighth, .bottomRightEighth,
                     .firstVerticalEighth, .secondVerticalEighth, .thirdVerticalEighth, .fourthVerticalEighth,
                     .fifthVerticalEighth, .sixthVerticalEighth, .seventhVerticalEighth, .lastVerticalEighth]),
            ("9분할", [.topLeftNinth, .topCenterNinth, .topRightNinth, .middleLeftNinth, .middleCenterNinth, .middleRightNinth,
                     .bottomLeftNinth, .bottomCenterNinth, .bottomRightNinth]),
            ("12분할", [.topLeftTwelfth, .topCenterLeftTwelfth, .topCenterRightTwelfth, .topRightTwelfth,
                      .middleLeftTwelfth, .middleCenterLeftTwelfth, .middleCenterRightTwelfth, .middleRightTwelfth,
                      .bottomLeftTwelfth, .bottomCenterLeftTwelfth, .bottomCenterRightTwelfth, .bottomRightTwelfth]),
            ("16분할", [.topLeftSixteenth, .topCenterLeftSixteenth, .topCenterRightSixteenth, .topRightSixteenth,
                      .upperMiddleLeftSixteenth, .upperMiddleCenterLeftSixteenth, .upperMiddleCenterRightSixteenth, .upperMiddleRightSixteenth,
                      .lowerMiddleLeftSixteenth, .lowerMiddleCenterLeftSixteenth, .lowerMiddleCenterRightSixteenth, .lowerMiddleRightSixteenth,
                      .bottomLeftSixteenth, .bottomCenterLeftSixteenth, .bottomCenterRightSixteenth, .bottomRightSixteenth]),
            ("두 배·절반", [.doubleWidthLeft, .doubleWidthRight, .doubleHeightUp, .doubleHeightDown,
                        .halveWidthLeft, .halveWidthRight, .halveHeightUp, .halveHeightDown]),
            ("여러 창 한꺼번에", [.tileAll, .tileRows, .tileColumns, .cascadeAll, .tileActiveApp, .cascadeActiveApp, .reverseAll,
                           .cycleStackedWindows, .cycleStackedWindowsBackward]),
            ("할 일 모드", [.leftTodo, .rightTodo]),
        ]
        let active = Set(WindowAction.active)
        var seen = Set<WindowAction>()
        var groups = listed.map { title, actions -> WindowCommandGroup in
            let present = actions.filter { active.contains($0) && seen.insert($0).inserted }
            return WindowCommandGroup(title: title, commands: present.map(WindowCommand.init))
        }
        let rest = WindowAction.active.filter { !seen.contains($0) }
        if !rest.isEmpty { groups.append(WindowCommandGroup(title: "기타", commands: rest.map(WindowCommand.init))) }
        return groups.filter { !$0.commands.isEmpty }
    }()

    public static var all: [WindowCommand] { groups.flatMap(\.commands) }

    /// 설정 화면과 메뉴에 바로 보이는 자주 쓰는 명령. 나머지는 '모두 보기'와 명령 찾기로 쓴다.
    public static let essentials: [WindowCommand] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds,
        .maximize, .almostMaximize, .center, .restore, .larger, .smaller,
        .nextDisplay, .previousDisplay,
    ].map(WindowCommand.init)
}

public struct WindowCommandGroup: Identifiable {
    public let title: String
    public let commands: [WindowCommand]
    public var id: String { title }
}

extension WindowAction {
    var koreanTitle: String {
        switch self {
        case .center: return "가운데로"
        case .specified: return "지정한 크기로 가운데"
        case .reverseAll: return "모든 창 좌우 뒤집기"
        case .tileAll: return "모든 창 바둑판 배열"
        case .cascadeAll: return "모든 창 계단식 배열"
        case .tileActiveApp: return "이 앱 창 바둑판 배열"
        case .cascadeActiveApp: return "이 앱 창 계단식 배열"
        case .leftTodo: return "할 일 창 왼쪽에"
        case .rightTodo: return "할 일 창 오른쪽에"
        case .centerProminently: return "가운데 조금 위로"
        case .largerHeight: return "높이 늘리기"
        case .smallerHeight: return "높이 줄이기"
        case .doubleHeightUp: return "높이 두 배 (위로)"
        case .doubleHeightDown: return "높이 두 배 (아래로)"
        case .doubleWidthLeft: return "너비 두 배 (왼쪽으로)"
        case .doubleWidthRight: return "너비 두 배 (오른쪽으로)"
        case .halveHeightUp: return "높이 절반 (위쪽 남기기)"
        case .halveHeightDown: return "높이 절반 (아래쪽 남기기)"
        case .halveWidthLeft: return "너비 절반 (왼쪽 남기기)"
        case .halveWidthRight: return "너비 절반 (오른쪽 남기기)"
        case .topLeftThird: return "왼쪽 위 1/3"
        case .topRightThird: return "오른쪽 위 1/3"
        case .bottomLeftThird: return "왼쪽 아래 1/3"
        case .bottomRightThird: return "오른쪽 아래 1/3"
        case .topVerticalThird: return "위 1/3"
        case .middleVerticalThird: return "가운데 1/3 (가로줄)"
        case .bottomVerticalThird: return "아래 1/3"
        case .topVerticalTwoThirds: return "위 2/3"
        case .bottomVerticalTwoThirds: return "아래 2/3"
        default:
            if let index = displayIndex { return "\(index + 1)번 모니터로" }
            return displayName ?? name
        }
    }
}

/// 키 하나와 보조키. 마우스 버튼 단축키(3번 이상 버튼)도 담는다. modifiers는 NSEvent.ModifierFlags 값이다.
public struct WindowKey: Equatable, Hashable {
    public let keyCode: Int
    public let modifiers: UInt

    init(_ shortcut: MASShortcut) {
        keyCode = shortcut.keyCode
        modifiers = shortcut.modifierFlags.rawValue
    }

    /// Carbon 단축키 값(RegisterEventHotKey에 넘기는 보조키)으로 만든다.
    public init(carbonKeyCode: UInt32, carbonModifiers: UInt32) {
        var flags: NSEvent.ModifierFlags = []
        let carbon = Int(carbonModifiers)
        if carbon & cmdKey != 0 { flags.insert(.command) }
        if carbon & optionKey != 0 { flags.insert(.option) }
        if carbon & controlKey != 0 { flags.insert(.control) }
        if carbon & shiftKey != 0 { flags.insert(.shift) }
        keyCode = Int(carbonKeyCode)
        modifiers = flags.rawValue
    }

    /// 키 누름이면 ⌘·⌥·⌃ 가운데 하나가 있어야 한다 (글자만으로는 글을 쓸 때마다 창이 움직인다).
    /// 마우스는 가운데·옆 버튼만 받는다 (왼쪽·오른쪽 버튼은 늘 쓰는 클릭이라).
    public init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        switch event.type {
        case .keyDown:
            guard !flags.intersection([.control, .option, .command]).isEmpty, KeyName.name(Int(event.keyCode)) != nil else { return nil }
            keyCode = Int(event.keyCode)
        case .otherMouseDown:
            guard let shortcut = MouseButtonShortcut(buttonPress: event) else { return nil }
            keyCode = shortcut.keyCode
        default:
            return nil
        }
        modifiers = flags.rawValue
    }

    var shortcut: MASShortcut { MASShortcut(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers)) }

    public var label: String { MouseButtonShortcut.displayable(shortcut).description }
    public var isMouseButton: Bool { MouseButtonShortcut.isMouseButton(shortcut) }
}

/// 단축키를 다는 자리 하나: 명령, 또는 할 일 모드·겹친 창 표시·명령 찾기·배치 불러오기 같은 따로 된 동작.
public struct WindowShortcutSlot: Hashable, Identifiable {
    public let defaultsKey: String
    public let title: String
    /// 명령 자리인지. 마우스 버튼 단축키와 같은 조합으로 차례 돌기는 명령 자리에서만 된다 (Rectangle ShortcutManager가 맡는다).
    public let isCommand: Bool
    public var id: String { defaultsKey }

    public init(defaultsKey: String, title: String) {
        self.defaultsKey = defaultsKey
        self.title = title
        isCommand = false
    }

    public init(_ command: WindowCommand) {
        defaultsKey = command.name
        title = command.title
        isCommand = true
    }

    /// Rectangle이 따로 다는 단축키 (할 일 모드 켜고 끄기·다시 놓기, 겹친 창 표시 켜고 끄기).
    public static var extras: [WindowShortcutSlot] {
        [WindowShortcutSlot(defaultsKey: TodoManager.toggleDefaultsKey, title: "할 일 모드 켜고 끄기"),
         WindowShortcutSlot(defaultsKey: TodoManager.reflowDefaultsKey, title: "할 일 창 다시 놓기"),
         WindowShortcutSlot(defaultsKey: StackBadgeManager.toggleDefaultsKey, title: "겹친 창 표시 켜고 끄기")]
    }
}
