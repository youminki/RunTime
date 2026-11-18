import Cocoa

/// 창 배치 설정은 따로 둔 저장소에 쓴다. 읽을 때는 앱 기본 저장소(dev.runtime.RunTime)도 함께 보므로,
/// 앱 설정에 Rectangle 설정과 같은 이름(gapSize 등)을 쓰지 않는다. 테스트는 scripts/test.sh가 정한 빈 저장소를 쓴다.
enum WindowDefaults {
    static let store: UserDefaults = {
        let name = ProcessInfo.processInfo.environment["RUNTIME_WINDOW_DEFAULTS"] ?? "dev.runtime.RunTime.window"
        return UserDefaults(suiteName: name) ?? .standard
    }()
}

extension WindowHistory {
    /// Rectangle은 AppDelegate.windowHistory로 둔다.
    static let shared = WindowHistory()
}

/// Rectangle의 로그 창 대신 시스템 로그에 남긴다. 설정의 '자세한 기록 남기기'로 켠다.
enum Logger {
    static var logging = false

    static func log(_ string: String) {
        guard logging else { return }
        NSLog("[RunTime 창 배치] %@", string)
    }

    static func showLogging(sender: Any?) {}
}

/// 앱에 넣은 창 배치 리소스 번들. 앱 번들 안에서는 Contents/Resources에서 찾는다 (RunTime의 Bundle.assets와 같은 이유).
enum WindowKitBundle {
    static let bundle: Bundle = Bundle.main.resourceURL
        .flatMap { Bundle(url: $0.appendingPathComponent("RunTime_WindowKit.bundle")) } ?? .module
}

extension NSImage {
    /// Rectangle 메뉴 아이콘 (Assets.xcassets/WindowPositions의 템플릿 그림).
    private static var windowKitCache: [String: NSImage] = [:]

    /// 메뉴와 설정 화면이 그릴 때마다 부르므로 한 번 읽은 그림은 들고 있는다 (100여 장, 모두 작다).
    static func windowKit(_ name: String) -> NSImage {
        if let cached = windowKitCache[name] { return cached }
        let image = loadWindowKit(name)
        windowKitCache[name] = image
        return image
    }

    private static func loadWindowKit(_ name: String) -> NSImage {
        guard let url = WindowKitBundle.bundle.url(forResource: name, withExtension: "png", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        image.isTemplate = true
        return image
    }
}

/// 창 번호를 얻는 비공개 API. Rectangle은 브리징 헤더로 부른다.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
