import AppKit
import SwiftUI

/// 앱 곳곳의 새 소식(업데이트, 레드마인 새 일감, 디자인 변경)을 메뉴바 말풍선으로 보낸다. 앱이 띄울 자리를 정한다.
enum MenuBarNews {
    static var post: (MenuBarBubble.Content) -> Void = { _ in }
    /// 말풍선 단추가 여는 앱 창 화면.
    static var open: (MainPage) -> Void = { _ in }
}

/// 메뉴바 러너 아래, 또는 화면에 꺼낸 펫 위에 뜨는 말풍선. 사용량 창을 열지 않아도 소식을 핵심 몇 줄로 보인다.
/// 사람이 닫기 전에는 닫히지 않고, 앱을 다시 켜도 닫지 않은 소식은 다시 뜬다. 여러 소식이 오면 한 말풍선에 모아
/// 앞뒤로 넘겨 보고, 하나를 닫으면 다음 것을 보인다. 앱을 앞으로 가져오지 않는다.
final class MenuBarBubble {
    static let shared = MenuBarBubble()
    /// 다시 켠 뒤 되살린 소식의 `link`를 단추 동작으로 바꾼다. 앱이 정한다.
    static var resolve: (String) -> (() -> Void)? = { _ in nil }
    private var panel: NSPanel?
    private var host: NSHostingView<BubbleView>?
    private var follow: Timer?
    private var queue: [Content] = []
    /// 지금 보이는 소식의 자리.
    private var index = 0
    /// 말풍선이 붙을 자리와 그 위에 뜨고 싶은지. 자리가 모자라면 반대쪽에 뜬다.
    private var anchor: () -> (rect: NSRect, above: Bool)? = { nil }
    /// 지금 말풍선이 대상 위에 떠 있는지 (꼬리가 아래).
    private var above = false
    /// 꼬리의 가로 자리 (말풍선 왼쪽에서). 화면 끝에서 말풍선이 밀려도 대상을 가리키게 옮긴다.
    private var tail = BubbleView.tail
    private static let savedKey = "menuBarBubbleQueue"
    private static let savedLimit = 20
    /// 단추를 누른 뒤 말풍선 안에 보이는 결과, 한 번 더 눌러야 하는 단추, 하는 중인 단추. 다른 소식으로 넘기면 지운다.
    private var flash: String?
    private var armed: String?
    private var busy: String?
    private var flashTimer: Timer?
    private var draft: Draft?
    /// 저절로 닫힐 소식의 타이머. 앞에 보이기 시작할 때 건다 (줄 서 있는 동안은 시간이 가지 않는다).
    private var expiry: [UUID: Timer] = [:]
    /// 따라가는 대상의 마지막 자리.
    private var followed: NSRect?

    struct Content {
        let title: String
        let items: [String]
        var actionTitle: String?
        var action: (() -> Void)?
        /// 다시 켠 뒤에도 단추를 살릴 열쇠 (예: "page:redmine", "notify:workLog"). 없으면 단추 없이 되살린다.
        var link: String?
        /// 다시 켠 뒤에 되살릴지. 곧 낡는 소식(새 버전 안내)은 false.
        var keeps = true
        /// 줄 대신 그대로 보일 글 (일일보고). 길면 말풍선 안에서 넘겨 본다.
        var report: String?
        /// 눌러도 닫히지 않는 단추 (복사, 팀즈로 보내기). 끝나면 말풍선 안에 결과를 보인다.
        var buttons: [Choice] = []
        /// 보이기 시작하고 이만큼 지나면 저절로 닫힌다. nil이면 사람이 닫을 때까지 둔다.
        var closesAfter: TimeInterval?
        /// 있으면 보고서 글을 말풍선에서 바로 고쳐 쓴다.
        var editing: Editing?
        let id = UUID()
    }

    /// 말풍선에서 고쳐 쓸 글. 머리줄은 날짜에서 만들어 고치지 않는다. `save`는 저장하고 새로 보일 글을 돌려준다.
    struct Editing {
        let header: String
        let body: () -> String
        let save: (String) -> String?
    }

    /// 고쳐 쓰는 중인 글. 글자마다 말풍선 전체를 다시 그리지 않게 따로 둔다.
    final class Draft: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }

    /// 말풍선 단추. `run`은 끝나면 `finish(알릴 말, 닫을지)`를 부른다.
    struct Choice {
        let title: String
        let icon: String
        var primary = false
        /// 있으면 처음 누를 때 이 말을 보이고, 한 번 더 눌러야 한다.
        var confirm: String?
        let run: (_ finish: @escaping (_ message: String, _ close: Bool) -> Void) -> Void
    }

    private struct Saved: Codable {
        let title: String
        let items: [String]
        let actionTitle: String?
        let link: String?
    }

    func show(_ content: Content, below anchor: NSRect) {
        show(content) { (anchor, false) }
    }

    /// 자리를 매번 다시 물어, 펫처럼 움직이는 것 위에서도 따라간다. 자리가 없어지면 닫지 않고 그 자리에 둔다.
    func show(_ content: Content, at anchor: @escaping () -> (rect: NSRect, above: Bool)?) {
        self.anchor = anchor
        // 같은 소식이 다시 오면 겹쳐 쌓지 않는다
        if queue.contains(where: { $0.title == content.title && $0.items == content.items && $0.report == content.report }) {
            if panel == nil { present() }
            return
        }
        queue.append(content)
        save()
        present()
    }

    /// 지난번에 닫지 않고 끈 소식을 다시 띄운다.
    func restore(at anchor: @escaping () -> (rect: NSRect, above: Bool)?) {
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey),
              let saved = try? JSONDecoder().decode([Saved].self, from: data), !saved.isEmpty else { return }
        let restored = saved.map { item -> Content in
            let action = item.link.flatMap(Self.resolve)
            return Content(title: item.title, items: item.items, actionTitle: action == nil ? nil : item.actionTitle,
                           action: action, link: item.link)
        }
        queue = restored + queue.filter { new in !restored.contains { $0.title == new.title && $0.items == new.items } }
        index = 0
        self.anchor = anchor
        save()
        present()
    }

    /// 점검 도구가 읽는 지금 말풍선 자리, 펫 위에 떴는지, 줄 선 소식 수.
    var frame: NSRect? { panel?.frame }
    var isAbove: Bool { above }
    var pending: Int { queue.count }

    /// 점검 도구가 지금 말풍선을 PNG로 남긴다.
    func snapshot(to file: URL) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    /// 줄 선 소식을 모두 닫는다.
    func hide() {
        clearFlash()
        expiry.values.forEach { $0.invalidate() }
        expiry.removeAll()
        queue.removeAll()
        index = 0
        save()
        close()
    }

    /// 지금 소식만 닫고 다음 소식을 보인다 (마지막이었으면 앞 소식).
    private func dismissCurrent() {
        clearFlash()
        if queue.indices.contains(index) { queue.remove(at: index) }
        index = min(index, max(queue.count - 1, 0))
        save()
        if queue.isEmpty { close() } else { present() }
    }

    /// 앞뒤 소식으로 넘긴다. 점검 도구도 쓴다.
    func turn(_ step: Int) {
        guard !queue.isEmpty else { return }
        clearFlash()
        index = (index + step + queue.count) % queue.count
        present()
    }

    /// 점검 도구가 읽는 지금 소식 제목.
    var currentTitle: String? { queue.indices.contains(index) ? queue[index].title : nil }

    private func save() {
        let saved = queue.filter(\.keeps).suffix(Self.savedLimit)
            .map { Saved(title: $0.title, items: $0.items, actionTitle: $0.actionTitle, link: $0.link) }
        if saved.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        } else if let data = try? JSONEncoder().encode(Array(saved)) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
    }

    private func close() {
        follow?.invalidate()
        follow = nil
        followed = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }

    private func view(for content: Content) -> BubbleView {
        BubbleView(content: content, position: index + 1, total: queue.count, tailBelow: above, tailX: tail,
                   flash: flash, armed: armed, busy: busy,
                   close: { [weak self] in self?.dismissCurrent() },
                   closeAll: { [weak self] in self?.hide() },
                   turn: { [weak self] in self?.turn($0) },
                   choose: { [weak self] in self?.choose($0, in: content.id) },
                   draft: draft,
                   edit: { [weak self] in self?.startEditing() },
                   finishEdit: { [weak self] in self?.finishEditing(save: $0) })
    }

    /// 말풍선 단추를 눌렀다. 확인이 필요하면 먼저 묻고, 끝나면 결과를 보이거나 닫는다.
    private func choose(_ choice: Choice, in id: UUID) {
        guard busy == nil else { return }
        if let confirm = choice.confirm, armed != choice.title {
            armed = choice.title
            show(flash: confirm, for: 5) { [weak self] in self?.armed = nil }
            return
        }
        armed = nil
        busy = choice.title
        flash = nil
        present()
        choice.run { [weak self] message, close in
            guard let self else { return }
            self.busy = nil
            // 보내는 사이 다른 소식으로 넘겼으면 결과만 보인다
            guard close, self.queue.indices.contains(self.index), self.queue[self.index].id == id else {
                return self.show(flash: message, for: close ? 2 : 4)
            }
            self.show(flash: message, for: 1.2) { [weak self] in
                guard let self, let at = self.queue.firstIndex(where: { $0.id == id }) else { return }
                self.index = at
                self.dismissCurrent()
            }
        }
    }

    /// 때가 된 소식을 닫는다. 커서를 올려 읽고 있거나 단추가 일하는 중이면 조금 더 둔다.
    private func expire(_ id: UUID, after seconds: TimeInterval) {
        expiry[id]?.invalidate()
        expiry[id] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.expiry[id] = nil
            guard let at = self.queue.firstIndex(where: { $0.id == id }) else { return }
            let reading = at == self.index && self.panel?.frame.contains(NSEvent.mouseLocation) == true
            if reading || (at == self.index && (self.busy != nil || self.draft != nil)) { return self.expire(id, after: 3) }
            if at == self.index { self.clearFlash() }
            self.queue.remove(at: at)
            if at < self.index { self.index -= 1 }
            self.save()
            if self.queue.isEmpty { self.close() } else { self.present() }
        }
    }

    private func show(flash message: String, for seconds: TimeInterval, then: (() -> Void)? = nil) {
        flash = message
        flashTimer?.invalidate()
        present()
        flashTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.flash = nil
            self.flashTimer = nil
            if let then { then() }
            if self.panel != nil { self.present() }
        }
    }

    private func startEditing() {
        guard queue.indices.contains(index), let editing = queue[index].editing else { return }
        draft = Draft(editing.body())
        flash = nil
        present()
        // 앱을 앞으로 가져오지 않고 글자만 받는다
        panel?.makeKey()
    }

    private func finishEditing(save: Bool) {
        guard let draft, queue.indices.contains(index) else { return }
        self.draft = nil
        if save, let editing = queue[index].editing, let full = editing.save(draft.text) {
            queue[index].report = full
            show(flash: "고친 글을 저장했습니다. 업무 일지에도 들어갑니다", for: 2.5)
        } else {
            present()
        }
        panel?.resignKey()
    }

    private func clearFlash() {
        draft = nil
        flashTimer?.invalidate()
        flashTimer = nil
        flash = nil
        armed = nil
    }

    private func present() {
        index = min(index, max(queue.count - 1, 0))
        guard queue.indices.contains(index) else { return close() }
        let content = queue[index]
        if let lifetime = content.closesAfter, expiry[content.id] == nil { expire(content.id, after: lifetime) }
        let host = self.host ?? NSHostingView(rootView: view(for: content))
        host.rootView = view(for: content)
        host.layoutSubtreeIfNeeded()
        // 높이는 꼬리 쪽과 상관없어 먼저 재고, 그 크기로 위아래 어디에 뜰지 정한다
        let size = host.fittingSize
        let spot = anchor()
        if let spot {
            let side = Self.side(for: spot, size: size)
            if side != above {
                above = side
                host.rootView = view(for: content)
            }
        }
        let panel = self.panel ?? {
            let panel = BubblePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return panel
        }()
        if panel.contentView !== host { panel.contentView = host }
        panel.setContentSize(size)
        self.panel = panel
        self.host = host
        place(at: spot?.rect)
        panel.orderFrontRegardless()
        if follow == nil {
            follow = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self, let panel = self.panel, let spot = self.anchor() else { return }
                // 대상이 그대로면(메뉴바, 머무는 펫) 할 일이 없다
                guard spot.rect != self.followed else { return }
                self.followed = spot.rect
                if Self.side(for: spot, size: panel.frame.size) != self.above { self.present() } else { self.place(at: spot.rect) }
            }
        }
    }

    private static func screen(around rect: NSRect) -> NSRect {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
    }

    /// 바라는 쪽에 자리가 모자라면(천장을 걷는 펫, 화면 아래 끝 메뉴바) 반대쪽에 띄운다.
    private static func side(for spot: (rect: NSRect, above: Bool), size: NSSize) -> Bool {
        let screen = screen(around: spot.rect)
        let fitsAbove = spot.rect.maxY + 4 + size.height <= screen.maxY
        let fitsBelow = spot.rect.minY - 4 - size.height >= screen.minY
        return spot.above ? (fitsAbove || !fitsBelow) : (!fitsBelow && fitsAbove)
    }

    /// 꼬리가 대상 가운데를 가리키게 두고, 화면 끝을 넘지 않게 민다.
    private func place(at anchor: NSRect?) {
        guard let panel, let anchor else { return }
        let size = panel.frame.size
        let screen = Self.screen(around: anchor)
        let x = min(max(anchor.midX - BubbleView.tail, screen.minX + 8), screen.maxX - size.width - 8)
        let y = above ? min(anchor.maxY + 4, screen.maxY - size.height) : max(anchor.minY - size.height - 4, screen.minY)
        let origin = NSPoint(x: x.rounded(), y: y.rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        let pointing = min(max(anchor.midX - origin.x, 16), size.width - 16).rounded()
        if pointing != tail, queue.indices.contains(index) {
            let content = queue[index]
            tail = pointing
            host?.rootView = view(for: content)
        }
    }

    struct BubbleView: View {
        let content: Content
        /// 지금 소식이 몇 번째인지와 모두 몇 건인지.
        let position: Int
        let total: Int
        /// 펫 위에 뜨면 꼬리를 아래에 둔다.
        let tailBelow: Bool
        /// 꼬리의 가로 자리 (말풍선 왼쪽에서).
        let tailX: CGFloat
        var flash: String?
        var armed: String?
        var busy: String?
        let close: () -> Void
        let closeAll: () -> Void
        let turn: (Int) -> Void
        var choose: (Choice) -> Void = { _ in }
        var draft: Draft?
        var edit: () -> Void = {}
        var finishEdit: (Bool) -> Void = { _ in }
        /// 꼬리의 기본 가로 자리 (말풍선 왼쪽에서).
        static let tail: CGFloat = 26

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(GameKit.gold)
                    Text(content.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Spacer(minLength: 8)
                    if total > 1 {
                        HStack(spacing: 2) {
                            arrow("chevron.left", label: "앞 소식") { turn(-1) }
                            Text("\(position)/\(total)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.6))
                            arrow("chevron.right", label: "다음 소식") { turn(1) }
                        }
                    }
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(total > 1 ? "이 소식 닫기" : "닫기")
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(content.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(GameKit.gold).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            Text(item).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let draft, let editing = content.editing {
                    DraftEditor(draft: draft, header: editing.header)
                    HStack(spacing: 6) {
                        Button { finishEdit(false) } label: { Text("취소").frame(maxWidth: .infinity) }
                            .buttonStyle(GameButtonStyle(height: 28, fontSize: 12))
                            .keyboardShortcut(.cancelAction)
                        Button { finishEdit(true) } label: { Label("저장", systemImage: "checkmark").frame(maxWidth: .infinity) }
                            .buttonStyle(PrimaryGameButtonStyle(height: 28, fontSize: 12))
                            .keyboardShortcut("s", modifiers: .command)
                    }
                } else if let report = content.report {
                    reportBox(report)
                        .overlay(alignment: .topTrailing) {
                            if content.editing != nil {
                                Button(action: edit) {
                                    Label("고치기", systemImage: "pencil").font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .padding(.horizontal, 7).frame(height: 20)
                                        .background(Capsule().fill(Color(white: 0.2)))
                                }
                                .buttonStyle(.plain)
                                .padding(5)
                                .accessibilityLabel("보고서 고치기")
                            }
                        }
                }
                if !content.buttons.isEmpty, draft == nil {
                    HStack(spacing: 6) {
                        ForEach(content.buttons.indices, id: \.self) { index in
                            choiceButton(content.buttons[index])
                        }
                    }
                }
                if let flash {
                    Text(flash).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(GameKit.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if total > 1 {
                    HStack(spacing: 6) {
                        Text("소식 \(total)건 · 닫으면 다음 소식이 나와요").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        Spacer(minLength: 4)
                        Button("모두 닫기", action: closeAll)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if let title = content.actionTitle, let action = content.action {
                    // 복사·보내기 단추가 있으면 여는 단추는 글자 단추로 둔다
                    if content.buttons.isEmpty {
                        Button {
                            action()
                            close()
                        } label: {
                            Text(title).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryGameButtonStyle(height: 28))
                        .padding(.top, 2)
                    } else {
                        Button {
                            action()
                            close()
                        } label: {
                            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                                .underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .frame(width: content.report == nil ? 280 : 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .overlay(alignment: tailBelow ? .bottomLeading : .topLeading) {
                // 러너·펫을 가리키는 꼬리
                Rectangle().fill(Color(white: 0.11)).frame(width: 10, height: 10).rotationEffect(.degrees(45))
                    .offset(x: tailX - 5, y: tailBelow ? 4 : -4)
            }
            .padding(tailBelow ? .bottom : .top, 6)
            .environment(\.colorScheme, .dark)
        }

        /// 보고서 글. 말풍선이 화면을 덮지 않게 높이를 묶고 길면 안에서 넘긴다.
        /// ScrollView는 제 크기를 말하지 않아 줄 수로 높이를 어림한다 (한 줄 약 36자).
        private func reportBox(_ report: String) -> some View {
            let rows = report.components(separatedBy: "\n").reduce(0) { $0 + max(1, ($1.count + 35) / 36) }
            return ScrollView {
                Text(report).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.88)).lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: min(CGFloat(rows) * 17 + 16, 200))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        }

        /// 고쳐 쓰는 칸. 머리줄은 위에 그대로 두고 몸통만 고친다.
        private struct DraftEditor: View {
            @ObservedObject var draft: Draft
            let header: String

            var body: some View {
                VStack(alignment: .leading, spacing: 4) {
                    Text(header).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    TextEditor(text: $draft.text)
                        .font(.system(size: 11.5))
                        .scrollContentBackground(.hidden)
                        .frame(height: 190)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(GameKit.gold.opacity(0.6)))
                    Text("⌘S 저장 · Esc 취소").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }

        private func choiceButton(_ choice: Choice) -> some View {
            let label = HStack(spacing: 5) {
                if busy == choice.title {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: armed == choice.title ? "checkmark" : choice.icon)
                }
                Text(armed == choice.title ? "한 번 더" : choice.title)
            }
            .frame(maxWidth: .infinity)
            return Group {
                if choice.primary {
                    Button { choose(choice) } label: { label }.buttonStyle(PrimaryGameButtonStyle(height: 28, fontSize: 12))
                } else {
                    Button { choose(choice) } label: { label }.buttonStyle(GameButtonStyle(height: 28, fontSize: 12))
                }
            }
            .disabled(busy != nil && busy != choice.title)
        }

        private func arrow(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }
}

/// 고쳐 쓸 때 글자를 받으려고 키 창이 될 수 있는 말풍선 창. 앱을 앞으로 가져오지 않는다.
private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
