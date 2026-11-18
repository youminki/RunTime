import AppKit
import Carbon.HIToolbox
import SwiftUI
import WindowKit

/// 창 배치 명령 찾기 (기본 ⌃⌥P). 이름이나 초성(ㅇㅉ → 왼쪽 절반)으로 찾아 Enter로 앞에 있던 창에 한다.
/// 단축키를 다 외우지 않아도 140가지 명령과 저장한 배치를 쓸 수 있게 하려는 것이다. Rectangle에는 없다.
final class WindowPalette {
    static let shared = WindowPalette()
    static let slot = WindowShortcutSlot(defaultsKey: "commandPalette", title: "명령 찾기 열기")
    static let defaultKey = WindowKey(carbonKeyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey))

    private var panel: NSPanel?
    private let model = WindowPaletteModel()
    private var resignObserver: NSObjectProtocol?

    func bindKey() {
        WindowControl.shared.bindExtra(Self.slot, default: Self.defaultKey) { [weak self] in self?.toggle() }
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        guard WindowControl.shared.running else { return }
        model.prepare()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.22 - panel.frame.height))
        }
        // 활성화하지 않는 패널이라 앞에 있던 앱의 창이 그대로 '앞 창'으로 남는다
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                                 styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.contentView = NSHostingView(rootView: WindowPaletteView(model: model) { [weak self] item in
            self?.close()
            // 패널이 내려간 뒤 실행해야 앞 창이 다시 그 앱 창으로 잡힌다
            DispatchQueue.main.async { item.run() }
        } close: { [weak self] in self?.close() })
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in self?.close() }
        return panel
    }

    private final class PalettePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

struct WindowPaletteItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let image: NSImage?
    let keys: String
    let run: () -> Void
}

final class WindowPaletteModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var shown = 0
    private var items: [WindowPaletteItem] = []
    private static let recentKey = "windowPalette.recent"

    var results: [WindowPaletteItem] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            let recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let front = recent.compactMap { byID[$0] }
            return front + items.filter { !recent.contains($0.id) }
        }
        return items.filter { item in
            let hay = (item.title + " " + item.detail).lowercased()
            let initials = Self.initials(item.title)
            return words.allSatisfy { hay.contains($0) || initials.contains($0) }
        }
    }

    func prepare() {
        query = ""
        shown += 1
        let control = WindowControl.shared
        var list = WindowCommand.groups.flatMap { group in
            group.commands.map { command in
                WindowPaletteItem(id: "command." + command.name, title: command.title, detail: group.title + " " + command.urlName,
                                  image: command.image, keys: control.key(for: command)?.label ?? "") {
                    control.run(command)
                }
            }
        }
        list += WindowExtraCommand.allCases.map { command in
            WindowPaletteItem(id: "extra." + command.rawValue, title: command.title, detail: "포커스 조금 옮기기 " + command.rawValue,
                              image: nil, keys: control.key(for: command.slot)?.label ?? "") { command.perform() }
        }
        let layouts = WindowLayouts.shared
        list += layouts.saved.map { layout in
            WindowPaletteItem(id: "layout." + layout.id.uuidString, title: "배치 불러오기: \(layout.name)",
                              detail: layout.appNames.joined(separator: ", "), image: nil,
                              keys: control.key(for: layout.slot)?.label ?? "") { layouts.restore(layout) }
        }
        list.append(WindowPaletteItem(id: "layout.save", title: "지금 배치 저장…", detail: "배치 저장", image: nil, keys: "") {
            layouts.saveInteractively()
        })
        if let name = control.frontAppName, name != "RunTime" {
            list.append(WindowPaletteItem(id: "ignore.front", title: control.frontAppIgnored ? "‘\(name)’에서 다시 쓰기" : "‘\(name)’에서 쓰지 않기",
                                          detail: "쓰지 않을 앱", image: nil, keys: "") { control.toggleFrontApp() })
        }
        items = list
    }

    func run(_ item: WindowPaletteItem, then perform: (WindowPaletteItem) -> Void) {
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        recent.removeAll { $0 == item.id }
        recent.insert(item.id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(8)), forKey: Self.recentKey)
        perform(item)
    }

    /// 한글 초성 (왼쪽 절반 → ㅇㅉㅈㅂ). 띄어쓰기는 뺀다.
    static func initials(_ text: String) -> String {
        let choseong = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
        return String(text.unicodeScalars.compactMap { scalar -> Character? in
            let value = scalar.value
            if (0xAC00...0xD7A3).contains(value) { return choseong[Int((value - 0xAC00) / 588)] }
            if scalar.properties.isWhitespace { return nil }
            return Character(scalar)
        }).lowercased()
    }
}

struct WindowPaletteView: View {
    @ObservedObject var model: WindowPaletteModel
    let perform: (WindowPaletteItem) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            TextField("창 배치 명령 찾기 (예: 왼쪽, ㅊㄷㅎ, 배치)", text: $model.query, onCommit: { runSelected(results) })
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .focused($focused)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.prefix(60).enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == model.selection)
                                .id(index)
                                .onTapGesture { model.run(item, then: perform) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { proxy.scrollTo($0, anchor: .center) }
            }
            if results.isEmpty {
                Text("맞는 명령이 없습니다").font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 12)
            }
        }
        .frame(width: 520, height: 400)
        .background(.regularMaterial)
        .onExitCommand(perform: close)
        .onReceive(model.$shown) { _ in DispatchQueue.main.async { focused = true } }
        .background(KeyCatcher { key in
            switch key {
            case .down: model.selection = min(model.selection + 1, max(0, min(results.count, 60) - 1))
            case .up: model.selection = max(model.selection - 1, 0)
            }
        })
    }

    private func runSelected(_ results: [WindowPaletteItem]) {
        guard results.indices.contains(model.selection) else { return }
        model.run(results[model.selection], then: perform)
    }

    private func row(_ item: WindowPaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let image = item.image {
                    Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "rectangle.3.group")
                }
            }
            .frame(width: 18, height: 13)
            .foregroundStyle(selected ? Color.white : .secondary)
            Text(item.title).font(.system(size: 13))
            Spacer()
            if !item.keys.isEmpty {
                Text(item.keys).font(.system(size: 12)).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .foregroundStyle(selected ? Color.white : .primary)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }
}

/// 글 칸에 초점이 있어도 위아래 화살표를 받는다.
private struct KeyCatcher: NSViewRepresentable {
    enum Key { case up, down }
    let onKey: (Key) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === view.window else { return event }
            switch event.keyCode {
            case UInt16(kVK_DownArrow): context.coordinator.onKey(.down); return nil
            case UInt16(kVK_UpArrow): context.coordinator.onKey(.up); return nil
            default: return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onKey = onKey }

    func makeCoordinator() -> Coordinator { Coordinator(onKey: onKey) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var onKey: (Key) -> Void
        var monitor: Any?
        init(onKey: @escaping (Key) -> Void) { self.onKey = onKey }
    }
}
