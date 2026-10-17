import AppKit
import CoreText
import SwiftUI

/// 게임 글자에 쓰는 한글 픽셀 글꼴 (Galmuri11 Bold, SIL OFL 1.1. 라이선스는 Assets/Game/Galmuri-OFL.txt).
/// 한글·영문·기호만 남기고 한자·가나를 뺀 파일을 싣는다. 글꼴 한 칸이 1em의 1/12이라
/// 12·18·24pt처럼 6의 배수에서 레티나 화소에 딱 맞아 흐려지지 않는다.
enum GameFont {
    private static let postScriptName = "Galmuri11-Bold"

    /// 앱 안에서만 쓰게 등록한다. 실패하면(파일이 없으면) 시스템 글꼴로 그린다.
    private static let available: Bool = {
        guard let url = Bundle.assets.resourceURL?.appendingPathComponent("Assets/Game/Galmuri11-Bold.ttf") else { return false }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        // 이미 등록돼 있으면(다시 불렸을 때) 실패로 오지만 쓸 수는 있다
        return registered || NSFont(name: postScriptName, size: 12) != nil
    }()

    static func pixel(_ size: CGFloat) -> Font {
        available ? .custom(postScriptName, fixedSize: size) : .system(size: size * 0.85, weight: .bold, design: .rounded)
    }
}
