#!/usr/bin/env python3
"""Rectangle(MIT) 소스를 Sources/WindowKit으로 옮겨 온다.

사용법: python3 scripts/sync-rectangle.py <Rectangle 클론 경로>
화면(설정 창, 환영 창, 스토리보드)과 업데이트(Sparkle)는 RunTime 것을 쓰므로 빼고,
나머지 코드는 고치지 않고 가져온 뒤 아래 기계적인 변환만 한다. RunTime 쪽 코드는 Sources/WindowKit/RunTime에 둔다.
"""
import os, re, shutil, sys, glob

SKIP_DIRS = {"SettingsWindow", "WelcomeWindow", "Popover", "AccessibilityAuthorization", "Logging",
             "Assets.xcassets", "Base.lproj", "mul.lproj", "AppIcon.icon", "Config"}
SKIP_FILES = {"AppDelegate.swift", "General/RectangleStatusItem.swift", "General/LaunchOnLogin.swift"}
# Config는 Defaults·실행 모드와 설정 파일 가져오기·내보내기(Config.swift)만 쓴다
KEEP_CONFIG = {"Defaults.swift", "SubsequentExecutionMode.swift", "Config.swift"}

def main(src):
    src = os.path.join(src, "Rectangle")
    dst = os.path.join(os.path.dirname(__file__), "..", "Sources", "WindowKit")
    dst = os.path.normpath(dst)
    for name in os.listdir(dst):
        if name in ("RunTime", "Support.swift", "LICENSE", "Icons", "Strings.swift"):
            continue
        path = os.path.join(dst, name)
        shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        top = rel.split(os.sep)[0]
        if top in SKIP_DIRS and not (top == "Config"):
            continue
        for f in files:
            if not f.endswith(".swift"):
                continue
            relf = os.path.normpath(os.path.join(rel, f))
            if relf in SKIP_FILES or (top == "Config" and f not in KEEP_CONFIG):
                continue
            out = os.path.join(dst, relf)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "w").write(transform(open(os.path.join(root, f)).read()))
    shutil.copy(os.path.join(src, "..", "LICENSE"), os.path.join(dst, "LICENSE"))
    icons = os.path.join(dst, "Icons")
    # Rectangle에서 없어진 아이콘이 남지 않게 비우고 다시 담는다
    shutil.rmtree(icons, ignore_errors=True)
    os.makedirs(icons)
    for png in glob.glob(os.path.join(src, "Assets.xcassets", "WindowPositions", "*.imageset", "*.png")):
        shutil.copy(png, icons)
    # 메뉴바 아이콘 (1배·2배)
    status = os.path.join(src, "Assets.xcassets", "StatusTemplate.imageset")
    shutil.copy(os.path.join(status, "RectangleStatusTemplate22.png"), os.path.join(icons, "StatusTemplate.png"))
    shutil.copy(os.path.join(status, "RectangleStatusTemplate44.png"), os.path.join(icons, "StatusTemplate@2x.png"))

def transform(s):
    s = s.replace("import MASShortcut\n", "")
    s = s.replace("import Sparkle\n", "")
    # Xcode 프로젝트는 브리징 헤더로 AppKit을 모든 파일에 열어 둔다
    if not re.search(r"^import (Cocoa|AppKit)$", s, re.M):
        if re.search(r"^import Foundation$", s, re.M):
            s = re.sub(r"^import Foundation$", "import Cocoa", s, count=1, flags=re.M)
        else:
            s = re.sub(r"^(/// .*\n)?", lambda m: (m.group(0) or "") + "\nimport Cocoa\n", s, count=1)
    # MASShortcut 헤더가 Carbon을 열어 두던 파일
    if "kVK_" in s and "import Carbon" not in s:
        s = re.sub(r"^import Cocoa$", "import Cocoa\nimport Carbon.HIToolbox", s, count=1, flags=re.M)
    # 설정은 RunTime 설정과 섞이지 않게 따로 둔 저장소에
    s = s.replace("UserDefaults.standard", "WindowDefaults.store")
    s = re.sub(r"(userDefaults|defaults): UserDefaults = \.standard", r"\1: UserDefaults = WindowDefaults.store", s)
    s = s.replace("AppDelegate.windowHistory", "WindowHistory.shared")
    # 알림 이름이 RunTime 것과 겹치지 않게
    s = s.replace('Notification.Name("', 'Notification.Name("RunTime.window.')
    s = s.replace("return Notification.Name(name)", 'return Notification.Name("RunTime.window." + name)')
    # 문구는 한국어 표(Strings.swift)에서 찾는다
    s = s.replace("String(localized: ", "L(")
    s = s.replace("NSLocalizedString(", "LS(")
    s = s.replace("NSImage(imageLiteralResourceName: ", "NSImage.windowKit(")
    for old, new in PATCHES:
        if old in s:
            s = s.replace(old, new)
            APPLIED.add(old)
    return s

APPLIED = set()

# 기계적으로 바꿀 수 없는 몇 군데. 원본이 바뀌어 맞는 줄이 없으면 그냥 지나간다
PATCHES = [
    # RunTime은 macOS 13부터 돈다. 이 SF Symbol은 macOS 15부터라 같은 뜻의 오래된 그림으로 바꾼다
    ('NSImage(systemSymbolName: "arrow.down.forward.and.arrow.up.backward.rectangle"',
     'NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left"'),
    # RunTime은 사용자 Mac의 Swift로 빌드하고 CI가 Xcode 16도 본다. Xcode 26 SDK에만 있는 API는 그 컴파일러에서만 쓴다
    ("        if #available(macOS 26, *) { decoration.preferredDynamicRange = .standard }",
     "        #if compiler(>=6.2)\n        if #available(macOS 26, *) { decoration.preferredDynamicRange = .standard }\n        #endif"),
    # Xcode 16 컴파일러가 제때 타입을 정하지 못하는 식에 타입을 적는다 (뜻은 같다)
    ("        let candidates = (0..<stages.count).map { step in",
     "        let candidates: [Int] = (0..<stages.count).map { (step: Int) -> Int in"),
    ("""        return [CGFloat(1), 0.5].contains { pixel in
            zip(values, targets).allSatisfy { value, target in
                abs(value - target) <= 0.001
                    || (abs(value - target) <= pixel / 2 + 0.001
                        && abs(value / pixel - (value / pixel).rounded()) <= 0.001)
            }
        }""",
     """        let pixels: [CGFloat] = [1, 0.5]
        return pixels.contains { (pixel: CGFloat) -> Bool in
            zip(values, targets).allSatisfy { (pair: (CGFloat, CGFloat)) -> Bool in
                let difference: CGFloat = abs(pair.0 - pair.1)
                if difference <= 0.001 { return true }
                let steps: CGFloat = pair.0 / pixel
                return difference <= pixel / 2 + 0.001 && abs(steps - steps.rounded()) <= 0.001
            }
        }"""),
    # RunTime은 백그라운드 큐에서도 UserDefaults에 쓴다. 단축키 다시 잡기(Carbon)는 메인 스레드에서만 한다
    ("    @objc private func userDefaultsChanged(_ notification: Notification) {\n        reloadShortcutBindingsIfNeeded()",
     "    @objc private func userDefaultsChanged(_ notification: Notification) {\n        // RunTime의 다른 설정이 바뀔 때마다 140여 개 단축키를 다시 견주지 않는다\n        guard (notification.object as AnyObject?) === WindowDefaults.store else { return }\n        guard Thread.isMainThread else {\n            DispatchQueue.main.async { [weak self] in self?.reloadShortcutBindingsIfNeeded() }\n            return\n        }\n        reloadShortcutBindingsIfNeeded()"),
    # 꺼져 있으면 다른 앱의 향상된 UI도 건드리지 않는다
    ("    @objc func receiveFrontAppChangeNote(_ notification: Notification) {\n        if let application",
     "    @objc func receiveFrontAppChangeNote(_ notification: Notification) {\n        guard !WindowRuntime.paused else { return }\n        if let application"),
    ("    @objc func windowActionTriggered(notification: NSNotification) {\n        guard let parameters",
     "    @objc func windowActionTriggered(notification: NSNotification) {\n        guard !WindowRuntime.paused, let parameters"),
    ('public private(set) static var frontAppName: String? = "Rectangle"',
     'public private(set) static var frontAppName: String? = "RunTime"'),
    # 창 배치를 끄면(WindowRuntime.paused) 마우스·창 감시를 켜지 않는다. 단축키는 MASShortcut 대체 코드가 멈춘다
    ("        guard sessionIsActive,\n              !sessionRebindPending,",
     "        guard !WindowRuntime.paused,\n              sessionIsActive,\n              !sessionRebindPending,"),
    ("        if allowListening, !fullScreenGate.suspendsListening",
     "        if !WindowRuntime.paused, allowListening, !fullScreenGate.suspendsListening"),
    ("        if WindowAction(rawValue: Defaults.doubleClickTitleBar.value - 1) != nil {\n            tabButtonPress.start()",
     "        if !WindowRuntime.paused, WindowAction(rawValue: Defaults.doubleClickTitleBar.value - 1) != nil {\n            tabButtonPress.start()"),
    ("        if Defaults.greenButtonOverride.enabled {\n            if !eventMonitor.running {",
     "        if !WindowRuntime.paused, Defaults.greenButtonOverride.enabled {\n            if !eventMonitor.running {"),
    ("        action = actionProvider()\n        guard action != nil else { return }",
     "        action = actionProvider()\n        guard action != nil, !WindowRuntime.paused else { return }"),
    ("        if Defaults.stackBadge.userEnabled {\n            guard timer == nil",
     "        if !WindowRuntime.paused, Defaults.stackBadge.userEnabled {\n            guard timer == nil"),
    ("        guard Defaults.todo.userEnabled && Defaults.todoMode.enabled else { return }\n        moveAll(bringToFront)",
     "        guard !WindowRuntime.paused, Defaults.todo.userEnabled && Defaults.todoMode.enabled else { return }\n        moveAll(bringToFront)"),
    # 화면 표시 주기에 맞춘 애니메이션은 macOS 14부터 있다. RunTime은 13도 지원해 13에서는 타이머로 돈다
    ("if let screen {\n            let target = WindowAnimationDisplayLinkTarget",
     "if #available(macOS 14.0, *), let screen {\n            let target = WindowAnimationDisplayLinkTarget"),
]

if __name__ == "__main__":
    main(sys.argv[1])
    missed = [old for old, _ in PATCHES if old not in APPLIED]
    if missed:
        sys.exit("Rectangle 원본이 바뀌어 맞는 자리를 찾지 못한 수정:\n" + "\n".join(missed))
