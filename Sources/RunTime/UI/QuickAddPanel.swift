import AppKit
import SwiftUI
import WorkLogCore

/// ⌃⌥L로 어디서든 띄우는 한 줄 적기. 쓰던 앱을 앞에서 내리지 않게 활성화하지 않는 패널로 띄운다.
final class QuickAddPanel {
    static let shared = QuickAddPanel()

    private var panel: NSPanel?
    private let model = QuickAddModel()
    private var resignObserver: NSObjectProtocol?

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        model.text = ""
        model.prepare()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.28))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 96),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: QuickAddView(model: model, store: .shared) { [weak self] in self?.close() })
        // 다른 곳을 누르면 닫는다 (Spotlight처럼)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in self?.close() }
        return panel
    }

    /// 활성화하지 않는 패널도 글자를 받게 한다.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }

        /// 앱이 앞에 없으면 편집 메뉴 단축키가 이 패널에 닿지 않아 직접 넘긴다.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased()
            else { return super.performKeyEquivalent(with: event) }
            let action: Selector? = {
                switch (key, flags.contains(.shift)) {
                case ("v", false): return #selector(NSText.paste(_:))
                case ("c", false): return #selector(NSText.copy(_:))
                case ("x", false): return #selector(NSText.cut(_:))
                case ("a", false): return #selector(NSText.selectAll(_:))
                case ("z", false): return Selector(("undo:"))
                case ("z", true): return Selector(("redo:"))
                default: return nil
                }
            }()
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}

final class QuickAddModel: ObservableObject {
    @Published var project = ""
    @Published var text = ""
    @Published var added: String?
    @Published var problem: String?
    /// 띄울 때마다 늘려 글 칸에 다시 초점을 준다.
    @Published var shown = 0

    /// 지난번에 쓴 프로젝트를 다시 고른다. 없으면 오늘 가장 많이 적은 프로젝트.
    func prepare() {
        added = nil
        problem = nil
        shown += 1
        let projects = WorkLogStore.shared.log.allProjects
        let last = UserDefaults.standard.string(forKey: "workLog.quickProject") ?? ""
        if projects.contains(last) { project = last; return }
        let today = WorkLogStore.shared.log.entries(on: WorkDay.today())
        project = WorkLogStore.shared.log.orderedProjects(of: today).first ?? projects.first ?? ""
    }
}

private struct QuickAddView: View {
    @ObservedObject var model: QuickAddModel
    @ObservedObject var store: WorkLogStore
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(store.log.allProjects, id: \.self) { name in
                        Button(name) { model.project = name }
                    }
                } label: {
                    HStack(spacing: 6) {
                        ProjectSwatch(name: model.project)
                        Text(model.project.isEmpty ? "프로젝트" : model.project)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Rectangle().fill(WL.border).frame(width: 0.5, height: 20)
                TextField(store.log.allProjects.isEmpty ? "새 프로젝트 이름: 오늘 한 일" : "오늘 한 일  ·  끝에 (60%)·(상시)·#일감번호",
                          text: $model.text, onCommit: save)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
            }
            HStack(spacing: 6) {
                Text(model.problem ?? model.added.map { "넣음: \($0)" }
                     ?? "\(WorkLogFormat.dayTitle(WorkDay.today()))에 넣습니다 · Enter 넣기 · Esc 닫기")
                    .font(WL.caption)
                    .foregroundStyle(model.problem != nil ? WL.waiting : model.added == nil ? Color.secondary : WL.done)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 560)
        .background(.regularMaterial)
        .onExitCommand(perform: close)
        // 패널을 띄울 때마다 바로 칠 수 있게
        .onReceive(model.$shown) { _ in DispatchQueue.main.async { focused = true } }
    }

    private func save() {
        var text = model.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let error = store.loadError {
            model.problem = error
            return
        }
        // 프로젝트가 아직 없으면 `프로젝트: 내용`으로 만들며 적는다
        if let colon = text.firstIndex(of: ":"), store.log.allProjects.isEmpty || model.project.isEmpty {
            model.project = text[..<colon].trimmingCharacters(in: .whitespaces)
            text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard !model.project.isEmpty, !text.isEmpty else {
            model.problem = "프로젝트를 고르거나 `프로젝트: 내용`으로 쓰세요"
            return
        }
        model.problem = nil
        let parsed = WorkLogFormat.splitStatus(text)
        if let entry = store.add(day: WorkDay.today(), project: model.project, title: parsed.title, status: parsed.status) {
            UserDefaults.standard.set(model.project, forKey: "workLog.quickProject")
            model.added = "\(model.project) · \(WorkReport.line(entry))"
            model.text = ""
        }
    }
}
