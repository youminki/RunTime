import Cocoa

/// Rectangle에 없지만 Rectangle 이슈에서 많이 요청된 명령. 단축키 자리·명령 찾기·설정 화면에 Rectangle 명령과 함께 나온다.
/// - 포커스 옮기기: 앞 창에서 그 방향에 있는 가장 가까운 창으로 (rxhanson/Rectangle#91)
/// - 조금씩 옮기기: 앞 창을 20pt씩, 화면 밖으로는 나가지 않게 (#143). 누르고 있으면 계속 옮긴다 (#123)
public enum WindowExtraCommand: String, CaseIterable, Identifiable {
    case focusLeft, focusRight, focusUp, focusDown
    case nudgeLeft, nudgeRight, nudgeUp, nudgeDown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focusLeft: return "왼쪽 창으로 포커스"
        case .focusRight: return "오른쪽 창으로 포커스"
        case .focusUp: return "위쪽 창으로 포커스"
        case .focusDown: return "아래쪽 창으로 포커스"
        case .nudgeLeft: return "왼쪽으로 조금"
        case .nudgeRight: return "오른쪽으로 조금"
        case .nudgeUp: return "위로 조금"
        case .nudgeDown: return "아래로 조금"
        }
    }

    public var slot: WindowShortcutSlot { WindowShortcutSlot(defaultsKey: "extra." + rawValue, title: title) }

    public static var groups: [(title: String, commands: [WindowExtraCommand])] {
        [("포커스 옮기기", [.focusLeft, .focusRight, .focusUp, .focusDown]),
         ("조금씩 옮기기", [.nudgeLeft, .nudgeRight, .nudgeUp, .nudgeDown])]
    }

    /// 누르고 있는 동안 되풀이하는지.
    var repeats: Bool { rawValue.hasPrefix("nudge") }

    /// 화면 왼쪽 위 기준(손쉬운 사용 좌표)의 방향.
    private var direction: CGVector {
        switch self {
        case .focusLeft, .nudgeLeft: return CGVector(dx: -1, dy: 0)
        case .focusRight, .nudgeRight: return CGVector(dx: 1, dy: 0)
        case .focusUp, .nudgeUp: return CGVector(dx: 0, dy: -1)
        case .focusDown, .nudgeDown: return CGVector(dx: 0, dy: 1)
        }
    }

    @discardableResult
    public func perform() -> Bool {
        guard !WindowRuntime.paused, let window = AccessibilityElement.getFrontWindowElement() else { return false }
        return perform(on: window)
    }

    /// - Parameter onlyPID: 포커스를 옮길 후보를 이 프로세스의 창으로 좁힌다 (점검 도구가 사용자 창을 건드리지 않게)
    func perform(on window: AccessibilityElement, onlyPID: pid_t? = nil) -> Bool {
        repeats ? nudge(window) : focus(from: window, onlyPID: onlyPID)
    }

    static let nudgeStep: CGFloat = 20

    private func nudge(_ window: AccessibilityElement) -> Bool {
        let frame = window.frame
        guard !frame.isNull else { return false }
        var moved = frame.offsetBy(dx: direction.dx * Self.nudgeStep, dy: direction.dy * Self.nudgeStep)
        // 창이 걸친 화면 안에 머물게 한다 (화면 끝에서 더 누르면 그대로)
        if let screen = NSScreen.screens.map({ $0.visibleFrame.screenFlipped }).max(by: {
            $0.intersection(frame).area < $1.intersection(frame).area
        }) {
            moved.origin.x = min(max(moved.minX, screen.minX), max(screen.minX, screen.maxX - moved.width))
            moved.origin.y = min(max(moved.minY, screen.minY), max(screen.minY, screen.maxY - moved.height))
        }
        guard moved.origin != frame.origin else { return false }
        window.setFrame(moved, adjustSizeFirst: false)
        return true
    }

    /// 그 방향에 중심이 있는 보이는 창 가운데, 앞으로 간 거리 + 옆으로 벗어난 거리×2가 가장 작은 창.
    private func focus(from window: AccessibilityElement, onlyPID: pid_t?) -> Bool {
        let frame = window.frame
        guard !frame.isNull else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        let current = window.getWindowId()
        let center = frame.centerPoint
        let candidates = WindowUtil.getWindowList(forceRefresh: true).filter {
            $0.level == 0 && $0.alpha > 0 && $0.pid != own && $0.id != current && (onlyPID == nil || $0.pid == onlyPID)
                && $0.frame.width > 60 && $0.frame.height > 60
                && !["Dock", "WindowManager", "Notification Center", "Window Server"].contains($0.processName ?? "")
        }
        let target = candidates.compactMap { info -> (WindowInfo, CGFloat)? in
            let other = info.frame.centerPoint
            let forward = (other.x - center.x) * direction.dx + (other.y - center.y) * direction.dy
            let side = abs((other.x - center.x) * direction.dy) + abs((other.y - center.y) * direction.dx)
            guard forward > 1 else { return nil }
            return (info, forward + side * 2)
        }.min { $0.1 < $1.1 }?.0
        guard let target, let element = AccessibilityElement.getWindowElement(target.id) else { return false }
        element.raise()
        element.bringToFront(force: true)
        return true
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
