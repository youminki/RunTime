import AppKit
import SwiftUI

/// Petdex 펫 찾기 창. 팝오버·설정·상점 어디서 열든 같은 창 하나를 쓴다.
/// 팝오버 안에서 시트를 띄우면 팝오버가 닫히며 시트도 사라져서 따로 창을 연다.
@MainActor
final class PetdexWindow {
    static let shared = PetdexWindow()
    private var window: NSWindow?
    private var purpose: PetdexBrowser.Purpose?

    /// `purpose`: 받은 펫을 러너로 고를지, 게임 동료로 데려갈지.
    func show(settings: AppSettings, purpose: PetdexBrowser.Purpose = .runner) {
        let browser = PetdexBrowser(settings: settings, purpose: purpose) { [weak self] in self?.window?.performClose(nil) }
        let window = window ?? {
            let window = NSWindow(contentViewController: NSHostingController(rootView: browser))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        // 쓰임새가 바뀌면 받는 중인 펫과 안내 글이 앞 쓰임새로 남지 않게 화면을 새로 만든다
        if self.purpose != purpose {
            window.contentViewController = NSHostingController(rootView: browser)
            self.purpose = purpose
        }
        window.title = purpose == .companion ? "동료로 데려갈 Petdex 펫 찾기" : "Petdex에서 러너 찾기"
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
