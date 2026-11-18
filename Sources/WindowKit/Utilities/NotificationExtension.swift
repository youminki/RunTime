/// NotificationExtension.swift

import Cocoa

extension Notification.Name {
    static let windowActionWillExecute = Notification.Name("RunTime.window.windowActionWillExecute")
  
    static let configImported = Notification.Name("RunTime.window.configImported")
    static let windowAnimationPreferencesChanged = Notification.Name("RunTime.window.windowAnimationPreferencesChanged")
    static let windowActionCompleted = Notification.Name("RunTime.window.windowActionCompleted")
    static let windowSnapping = Notification.Name("RunTime.window.windowSnapping")
    static let frontAppChanged = Notification.Name("RunTime.window.frontAppChanged")
    static let allowAnyShortcut = Notification.Name("RunTime.window.allowAnyShortcutToggle")
    static let changeDefaults = Notification.Name("RunTime.window.changeDefaults")
    static let todoMenuToggled = Notification.Name("RunTime.window.todoMenuToggled")
    static let appWillBecomeActive = Notification.Name("RunTime.window.appWillBecomeActive")
    static let missionControlDragging = Notification.Name("RunTime.window.missionControlDragging")
    static let menuBarIconHidden = Notification.Name("RunTime.window.menuBarIconHidden")
    static let windowTitleBar = Notification.Name("RunTime.window.windowTitleBar")
    static let greenButtonOverride = Notification.Name("RunTime.window.greenButtonOverride")
    static let defaultSnapAreas = Notification.Name("RunTime.window.defaultSnapAreas")
    static let updateAvailability = Notification.Name("RunTime.window.updateAvailability")
    static let showAdditionalSizesInMenuChanged = Notification.Name("RunTime.window.showAdditionalSizesInMenuChanged")
    static let shortcutRecording = Notification.Name("RunTime.window.shortcutRecording")
    static let stackBadgeChanged = Notification.Name("RunTime.window.stackBadgeChanged")
    static let snapAreaSettingsNeedsResize = Notification.Name("RunTime.window.snapAreaSettingsNeedsResize")

    func post(
        center: NotificationCenter = NotificationCenter.default,
        object: Any? = nil,
        userInfo: [AnyHashable : Any]? = nil) {
        
        center.post(name: self, object: object, userInfo: userInfo)
    }
    
    @discardableResult
    func onPost(
        center: NotificationCenter = NotificationCenter.default,
        object: Any? = nil,
        queue: OperationQueue? = nil,
        using: @escaping (Notification) -> Void)
    -> NSObjectProtocol {
        
        return center.addObserver(
            forName: self,
            object: object,
            queue: queue,
            using: using)
    }

}
