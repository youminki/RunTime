import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WindowKit

/// 설정 > 창 배치. 켜기, 자주 쓰는 단축키, 끌어다 붙이기, 움직임, 저장한 배치, 쓰지 않을 앱만 한 화면에 둔다.
/// 나머지 명령은 '모두 보기'와 명령 찾기로, 드물게 바꾸는 것은 접어 둔 '고급'에 둔다.
struct WindowLayoutSettingsView: View {
    @ObservedObject var layout: WindowLayout
    /// 화면 찍기(--ui-shots)에서 켜지 않고도 모든 묶음을 보인다.
    var showsAll = false
    @StateObject private var page = WindowSettingsPage()
    @StateObject private var recorder = WindowKeyRecorder()
    private let control = WindowControl.shared

    var body: some View {
        // revision을 읽어 설정·단축키가 바뀔 때마다 다시 그린다. 단축키는 한 번 그릴 때 한 번만 읽는다
        let _ = layout.revision
        GroupedList {
            header
            if layout.enabled || showsAll {
                shortcuts
                snapping
                movement
                layouts
                ignored
                advanced
            }
        }
        .onDisappear { recorder.stop() }
    }

    // MARK: 켜기

    @ViewBuilder private var header: some View {
        GroupedSection(footer: "어느 앱에서든 앞에 있는 창을 단축키나 메뉴로 절반·모서리·3분할에 놓습니다.") {
            ToggleRow(title: "창 배치 켜기", icon: "rectangle.split.2x1", isOn: $layout.enabled)
            if layout.enabled && !layout.trusted {
                GroupedRow("창을 옮기려면 손쉬운 사용 권한이 필요합니다", icon: "lock") {
                    Button("권한 허용") { layout.requestAccess() }.controlSize(.small)
                }
                .foregroundStyle(Palette.orange)
            }
            let others = control.conflictingApps
            if layout.running && !others.isEmpty {
                GroupedRow("\(others.joined(separator: ", "))도 켜져 있어 단축키가 겹칩니다", icon: "exclamationmark.triangle")
                    .foregroundStyle(Palette.orange)
            }
        }
    }

    // MARK: 단축키

    @ViewBuilder private var shortcuts: some View {
        GroupedSection("단축키", footer: "칸을 누르고 새 조합을 누르면 바뀝니다. ⌫는 지우기, esc는 취소. 여기 없는 명령은 명령 찾기로 이름을 쳐서 씁니다.") {
            shortcutGrid(WindowCommand.essentials)
            if page.showAll {
                ForEach(WindowCommand.groups) { group in
                    let rest = group.commands.filter { !WindowCommand.essentials.contains($0) }
                    if !rest.isEmpty {
                        Text(group.title).font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.top, 6)
                        shortcutGrid(rest)
                    }
                }
                ForEach(WindowExtraCommand.groups, id: \.title) { group in
                    Text(group.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.top, 6)
                    extraGrid(group.commands)
                }
            }
            GroupedRow(page.showAll ? "자주 쓰는 것만 보기" : "모든 명령 보기 (140여 개)", icon: "list.bullet") {
                Button(page.showAll ? "접기" : "모두 보기") { page.showAll.toggle() }.controlSize(.small)
            }
            GroupedRow(WindowPalette.slot.title, icon: "magnifyingglass") { keyChip(WindowPalette.slot) }
            if let hint = recorder.hint {
                GroupedRow(hint, icon: "exclamationmark.circle").foregroundStyle(Palette.orange)
            }
        }
    }

    /// 두 줄로 나란히 놓은 단축키 칸. 아이콘으로 창이 놓일 자리를 보인다.
    private func shortcutGrid(_ commands: [WindowCommand]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
            ForEach(commands) { command in
                HStack(spacing: 8) {
                    Group {
                        if let image = command.image {
                            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "rectangle").resizable().aspectRatio(contentMode: .fit)
                        }
                    }
                    .foregroundStyle(.secondary.opacity(0.8))
                    .frame(width: 17, height: 12)
                    Text(command.title).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    keyChip(WindowShortcutSlot(command))
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.groupedBackground))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// RunTime이 더한 명령(포커스·조금씩 옮기기) 칸.
    private func extraGrid(_ commands: [WindowExtraCommand]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
            ForEach(commands) { command in
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(command)).foregroundStyle(.secondary.opacity(0.8)).frame(width: 17)
                    Text(command.title).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    keyChip(command.slot)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.groupedBackground))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private static func symbol(_ command: WindowExtraCommand) -> String {
        switch command {
        case .focusLeft: return "arrow.left.square"
        case .focusRight: return "arrow.right.square"
        case .focusUp: return "arrow.up.square"
        case .focusDown: return "arrow.down.square"
        case .nudgeLeft: return "arrow.left"
        case .nudgeRight: return "arrow.right"
        case .nudgeUp: return "arrow.up"
        case .nudgeDown: return "arrow.down"
        }
    }

    /// 지금 단축키를 보이는 칩. 누르면 기록하고, 오른쪽 클릭으로 지운다. 겹치거나 동작하지 않으면 주황색이다.
    private func keyChip(_ slot: WindowShortcutSlot) -> some View {
        let table = page.table(revision: layout.revision) { control.keyTable(extra: Self.extraSlots) }
        let key = table.key(for: slot)
        let recording = recorder.recording == slot
        let problem = table.problem(for: slot)
        let label = recording ? "키를 누르세요" : key?.label ?? "없음"
        return Button { recorder.toggle(slot) } label: {
            Text(label)
                .font(.system(size: 11, weight: key == nil && !recording ? .regular : .medium))
                .foregroundStyle(recording ? Color.white : problem != nil ? Palette.orange : key == nil ? Color.secondary : .primary)
                .padding(.horizontal, 7)
                .frame(minWidth: 44, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(recording ? Color.accentColor : Palette.groupedRow))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(problem != nil ? Palette.orange : Palette.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .tip(problem ?? "눌러서 바꾸기")
        .contextMenu {
            if key != nil { Button("단축키 지우기") { control.setKey(nil, for: slot) } }
        }
    }


    // MARK: 끌어다 붙이기

    @ViewBuilder private var snapping: some View {
        GroupedSection("끌어다 붙이기", footer: "창을 화면 옆 끝으로 끌면 절반, 모서리는 1/4, 위쪽 끝은 최대화로 붙습니다. 다시 끌어내면 원래 크기로 돌아옵니다.") {
            ToggleRow(title: "화면 끝으로 끌어 붙이기", icon: "arrow.up.left.and.arrow.down.right",
                      isOn: Binding(get: { control.snapping }, set: { control.snapping = $0 }))
            if control.macTilingConflicts {
                GroupedRow("macOS 창 정렬도 켜져 있어 겹칩니다", icon: "exclamationmark.triangle") {
                    Button("macOS 쪽 끄기") { control.disableMacTiling() }.controlSize(.small)
                }
                .foregroundStyle(Palette.orange)
            }
        }
    }

    // MARK: 움직임

    @ViewBuilder private var movement: some View {
        GroupedSection("움직임", footer: control.repeatMode.detail) {
            GroupedRow("같은 단축키를 다시 누르면", icon: "repeat") {
                Picker("같은 단축키를 다시 누르면", selection: Binding(get: { control.repeatMode }, set: { control.repeatMode = $0 })) {
                    ForEach(WindowRepeatMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            GroupedRow("창 사이 여백", icon: "square.dashed") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { control.gapSize }, set: { control.gapSize = $0 }), in: 0...30, step: 2)
                        .frame(width: 140).controlSize(.small)
                    Text(control.gapSize == 0 ? "없음" : "\(Int(control.gapSize))pt")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }
            ToggleRow(title: "부드럽게 옮기기", icon: "wind",
                      isOn: Binding(get: { control.animations }, set: { control.animations = $0 }))
        }
    }

    // MARK: 저장한 배치

    @ViewBuilder private var layouts: some View {
        let store = WindowLayouts.shared
        GroupedSection("모니터", footer: "모니터를 꽂거나 빼면 macOS가 창을 한쪽에 몰아 놓습니다. 켜 두면 그 모니터 구성에서 쓰던 자리로 저절로 되돌립니다.") {
            ToggleRow(title: "모니터를 바꾸면 창 자리 되돌리기", icon: "display.2",
                      isOn: Binding(get: { store.remembersPerScreen }, set: { store.remembersPerScreen = $0 }))
        }
        GroupedSection("저장한 배치", footer: "지금 창 자리를 저장했다가 한 번에 되돌립니다. ⋯에서 모니터를 꽂으면 저절로 불러오게 할 수 있습니다.") {
            ForEach(store.saved) { saved in
                GroupedRow(saved.name, icon: "rectangle.3.group") {
                    HStack(spacing: 8) {
                        Text("창 \(saved.windowCount)개").font(.system(size: 11)).foregroundStyle(.secondary)
                            .tip(saved.appNames.joined(separator: ", "))
                        if saved.autoRestore {
                            Image(systemName: "display.2").font(.system(size: 11)).foregroundStyle(.secondary)
                                .tip("모니터를 연결하면 저절로 불러옵니다")
                        }
                        keyChip(saved.slot)
                        Button("불러오기") { store.restore(saved) }.controlSize(.small).disabled(!layout.running)
                        Menu {
                            Button("지금 창 자리로 다시 저장") { store.update(saved) }
                            Button("이름 바꾸기…") { Self.rename(saved) }
                            Toggle("모니터를 연결하면 저절로", isOn: Binding(get: { saved.autoRestore },
                                                                     set: { store.setAutoRestore(saved, $0) }))
                            Divider()
                            Button("지우기") { store.delete(saved) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
            }
            GroupedRow(store.saved.isEmpty ? "지금 창 배치를 저장해 보세요" : "지금 배치 저장", icon: "plus") {
                Button("저장…") { store.saveInteractively() }.controlSize(.small).disabled(!layout.running)
            }
        }
    }

    // MARK: 쓰지 않을 앱

    @ViewBuilder private var ignored: some View {
        GroupedSection("쓰지 않을 앱", footer: "이 앱들이 앞에 있으면 단축키와 끌어다 붙이기가 쉽니다.") {
            ForEach(control.ignoredApps, id: \.self) { id in
                GroupedRow(Self.appName(id), icon: "app") {
                    Button("빼기") { control.ignoredApps = control.ignoredApps.filter { $0 != id } }.controlSize(.small)
                }
            }
            GroupedRow("앱 더하기", icon: "plus") {
                Button("고르기…") { control.ignoredApps = Array(Set(control.ignoredApps + Self.pickApps())) }.controlSize(.small)
            }
        }
    }

    // MARK: 고급

    @ViewBuilder private var advanced: some View {
        GroupedSection(footer: page.showAdvanced ? "아이콘을 꺼도 RunTime 아이콘 오른쪽 클릭 메뉴에 남습니다. 설정 파일은 Rectangle에서 내보낸 것도 가져옵니다." : nil) {
            GroupedRow("고급", icon: "slider.horizontal.3") {
                Button(page.showAdvanced ? "접기" : "펼치기") { page.showAdvanced.toggle() }.controlSize(.small)
            }
            if page.showAdvanced {
                ToggleRow(title: "메뉴바에 창 배치 아이콘 두기", icon: "menubar.rectangle", isOn: $layout.statusIcon)
                GroupedRow("기본 단축키 묶음", icon: "keyboard") {
                    Picker("기본 단축키 묶음", selection: Binding(get: { control.preset }, set: { control.preset = $0 })) {
                        ForEach(WindowKeyPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                GroupedRow("단축키를 모두 처음대로", icon: "arrow.counterclockwise") {
                    Button("되돌리기") { control.resetKeys() }.controlSize(.small)
                }
                GroupedRow("설정 파일", icon: "doc") {
                    HStack(spacing: 6) {
                        Button("내보내기…") { Self.exportConfig() }
                        Button("가져오기…") { Self.importConfig() }
                    }
                    .controlSize(.small)
                }
                if control.rectangleSettingsAvailable {
                    GroupedRow("이 Mac에서 쓰던 Rectangle 설정", icon: "arrow.down.doc") {
                        Button("가져오기") { control.importRectangleSettings() }.controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: 도우미

    /// 명령이 아닌 단축키 자리 (명령 찾기·배치 불러오기). 명령과 같은 조합이면 하나만 동작한다.
    static var extraSlots: [WindowShortcutSlot] {
        [WindowPalette.slot] + WindowShortcutSlot.extras + WindowExtraCommand.allCases.map(\.slot)
            + WindowLayouts.shared.saved.map(\.slot)
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func pickApps() -> [String] {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }

    private static func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "RunTime 창 배치.json"
        guard panel.runModal() == .OK, let url = panel.url, let json = WindowControl.shared.exportConfig() else { return }
        do { try json.write(to: url, atomically: true, encoding: .utf8) }
        catch { Diagnostics.record("창 배치", "설정 파일을 쓰지 못함: \(error.localizedDescription)") }
    }

    private static func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        WindowControl.shared.importConfig(from: url)
    }

    private static func rename(_ saved: SavedWindowLayout) {
        let alert = NSAlert()
        alert.messageText = "배치 이름 바꾸기"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = saved.name
        alert.accessoryView = field
        alert.addButton(withTitle: "바꾸기")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WindowLayouts.shared.rename(saved, to: field.stringValue.trimmingCharacters(in: .whitespaces))
    }
}

/// 설정 화면 상태. macOS 27 SDK의 `@State`는 Command Line Tools로 빌드되지 않아 관찰 객체로 둔다 (HoverFlag 참고).
final class WindowSettingsPage: ObservableObject {
    @Published var showAll = false
    @Published var showAdvanced = false
    /// 단축키 표. 칸 150여 개가 그릴 때마다 저장소를 다시 읽지 않게, 무언가 바뀔 때(revision)만 새로 읽는다.
    private var cachedTable: (revision: Int, table: WindowKeyTable)?

    func table(revision: Int, make: () -> WindowKeyTable) -> WindowKeyTable {
        if let cachedTable, cachedTable.revision == revision { return cachedTable.table }
        let table = make()
        cachedTable = (revision, table)
        return table
    }
}

/// 단축키 하나를 새로 기록한다. 키 조합이나 (명령이면) 가운데·옆 마우스 버튼을 받는다. ⌫는 지우기, esc는 취소.
final class WindowKeyRecorder: ObservableObject {
    @Published private(set) var recording: WindowShortcutSlot?
    @Published var hint: String?
    private var monitor: Any?
    private var observers: [Any] = []
    private var petKeysHeld = false

    func toggle(_ slot: WindowShortcutSlot) {
        let same = recording == slot
        stop()
        if !same { start(slot) }
    }

    private func start(_ slot: WindowShortcutSlot) {
        recording = slot
        hint = nil
        // 펫 단축키도 놓아야 그 조합을 눌렀을 때 기록기에 온다
        WindowControl.shared.suspendKeys()
        petKeysHeld = DesktopPet.shared.isShown
        if petKeysHeld { PetKeys.shared.unregister() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard event.window != nil, event.window === NSApp.keyWindow else { return event }
            self?.handle(event)
            return nil
        }
        let window = NSApp.keyWindow
        let center = NotificationCenter.default
        observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.stop() }
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.stop() })
    }

    func stop() {
        guard recording != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        monitor = nil
        observers = []
        recording = nil
        WindowControl.shared.resumeKeys()
        if petKeysHeld { PetKeys.shared.register() }
        petKeysHeld = false
    }

    private func handle(_ event: NSEvent) {
        guard let slot = recording else { return }
        if event.type == .keyDown {
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if event.keyCode == 53 {   // esc
                stop()
                return
            }
            if plain && (event.keyCode == 51 || event.keyCode == 117) {   // ⌫, ⌦
                stop()
                WindowControl.shared.setKey(nil, for: slot)
                return
            }
        }
        guard let key = WindowKey(event: event) else {
            hint = "⌘·⌥·⌃ 가운데 하나와 함께 눌러 주세요."
            return
        }
        // 마우스 버튼은 창 배치 명령에만 단다 (Rectangle의 마우스 단축키 감시가 명령만 본다)
        guard slot.isCommand || !key.isMouseButton else {
            hint = "마우스 버튼은 창 배치 명령에만 달 수 있습니다."
            return
        }
        // macOS 15부터 ⌥ 하나(또는 ⌥⇧)만 쓴 전역 단축키는 시스템이 막는다 (Rectangle #1592)
        let flags = NSEvent.ModifierFlags(rawValue: key.modifiers)
        guard key.isMouseButton || !flags.intersection([.control, .command]).isEmpty || !flags.contains(.option) else {
            hint = "macOS 15부터 ⌥만(또는 ⌥⇧만) 쓴 단축키는 동작하지 않습니다. ⌃나 ⌘를 함께 눌러 주세요."
            return
        }
        guard !WindowLayout.reservedKeys.contains(key) else {
            hint = "\(key.label)는 RunTime의 펫·클립보드 단축키입니다. 다른 조합을 눌러 주세요."
            return
        }
        hint = nil
        stop()
        WindowControl.shared.setKey(key, for: slot)
        if WindowControl.shared.failedSlots.contains(slot.defaultsKey) {
            hint = "\(key.label)는 다른 앱이 쓰고 있어 동작하지 않습니다. 다른 조합을 골라 주세요."
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        if recording != nil {
            WindowControl.shared.resumeKeys()
            if petKeysHeld { PetKeys.shared.register() }
        }
    }
}
