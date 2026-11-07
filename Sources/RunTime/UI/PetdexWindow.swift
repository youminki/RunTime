import AppKit
import SwiftUI

/// Petdex 펫 찾기 창.
/// 팝오버 안에서 시트를 띄우면 팝오버가 닫히며 시트도 사라져서 따로 창을 연다.
@MainActor
final class PetdexWindow {
    static let shared = PetdexWindow()
    private var window: NSWindow?
    private let form = PetdexSearch()

    func show(settings: AppSettings) {
        let window = window ?? {
            let browser = PetdexBrowser(settings: settings, form: form) { [weak self] in self?.window?.performClose(nil) }
            let window = NSWindow(contentViewController: NSHostingController(rootView: browser))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.title = "Petdex에서 펫 찾기"
            window.center()
            return window
        }()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
