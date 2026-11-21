import AppKit
import CoreImage.CIFilterBuiltins
import PortsCore
import SwiftUI

/// 포트 화면 상태. 이 툴체인은 SwiftUI 매크로(@State)를 못 써서 모델에 둔다.
@MainActor
final class PortsPage: ObservableObject {
    static let shared = PortsPage()

    @Published var search = ""
    /// 편집기·메신저·시스템이 연 포트. 개발에 쓰는 것만 보이게 기본으로 접어 둔다.
    @Published var showOthers = false
    @Published var toast: String?
    private var toastWork: DispatchWorkItem?

    func flash(_ message: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }
}

/// 열린 포트를 보고, 명령어 없이 끄거나 다른 포트로 다시 시작한다.
struct PortsView: View {
    @ObservedObject var store: PortsStore
    @ObservedObject var page: PortsPage
    @FocusState private var searching: Bool

    var body: some View {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading
                if let problem = store.problem {
                    Callout { Text(problem).font(WL.meta).foregroundStyle(WL.waiting) }.padding(.bottom, 12)
                }
                searchField
                portLookup
                devSection
                otherSection
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(WL.canvas)
        .foregroundStyle(WL.text)
        .overlay(alignment: .bottom) {
            if let toast = page.toast { Toast(message: toast).padding(.bottom, 18).transition(.opacity) }
        }
        .background {
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
            Button("") { store.refresh() }.keyboardShortcut("r", modifiers: .command).hidden()
        }
        .onAppear { store.setWatching(true) }
        .onDisappear { store.setWatching(false) }
    }

    private var query: String { page.search.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ server: PortsStore.Server) -> Bool {
        guard !query.isEmpty else { return true }
        if let number = Int(query) { return server.ports.contains(number) || server.ports.contains { String($0).hasPrefix(query) } }
        return [server.title, server.detail, server.group.root.command, server.listenerName].contains { $0.lowercased().contains(query) }
    }

    // MARK: 머리

    private var heading: some View {
        PageHeading("포트") {
            Tally(title: "개발 서버", value: store.devServers.count, tint: WL.done)
            Tally(title: "다른 앱", value: store.otherServers.count, tint: WL.quiet)
            Text("3초마다 새로 읽음").foregroundStyle(WL.faint)
        } accessory: {
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("새로 읽기")
                .buttonStyle(SquareIconButtonStyle(size: 28))
                .tip("지금 새로 읽기 (⌘R)")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WL.quiet)
            TextField("포트 번호나 프로젝트 이름으로 찾기 (⌘F)", text: $page.search).textFieldStyle(.plain).font(WL.body)
                .focused($searching)
                .onExitCommand { page.search = ""; searching = false }
            if !page.search.isEmpty {
                Button { page.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(WL.quiet)
                    .accessibilityLabel("찾기 지우기")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .wlSurface(radius: 6)
        .padding(.bottom, 18)
    }

    /// 포트 번호를 쳤는데 쓰는 곳이 없으면 비어 있다고 바로 알려 준다. "3000번 비었나?"를 확인하려고 찾는 경우가 많다.
    @ViewBuilder private var portLookup: some View {
        if store.loaded, let number = Int(query), (1...65535).contains(number), !store.servers.contains(where: { $0.ports.contains(number) }) {
            let free = PortRestart.isFree(number)
            Callout {
                HStack(spacing: 8) {
                    Image(systemName: free ? "checkmark.circle.fill" : "lock.fill").foregroundStyle(free ? WL.done : WL.waiting)
                    Text(free ? "\(String(number))번 포트는 비어 있어 바로 쓸 수 있습니다."
                         : "\(String(number))번 포트는 다른 계정이나 시스템이 쓰고 있어 여기서는 보이지 않습니다.")
                        .font(WL.meta)
                }
            }
            .padding(.bottom, 18)
        }
    }

    // MARK: 개발 서버

    private var devSection: some View {
        let list = store.devServers.filter(matches)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("개발 서버").font(WL.section)
                Text("\(list.count)").font(WL.caption).foregroundStyle(WL.quiet).monospacedDigit()
            }
            .padding(.bottom, 6)
            if list.isEmpty {
                Callout {
                    Text(devEmptyMessage).font(WL.meta).foregroundStyle(WL.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } else {
                rows(list)
            }
        }
        .padding(.bottom, 26)
    }

    private var devEmptyMessage: String {
        if !store.loaded { return "포트를 읽는 중입니다." }
        if !query.isEmpty { return "‘\(page.search)’에 맞는 개발 서버가 없습니다." }
        return "실행 중인 개발 서버가 없습니다. 터미널에서 npm run dev 같은 명령으로 서버를 켜면 여기에 바로 나타납니다."
    }

    // MARK: 다른 앱

    @ViewBuilder private var otherSection: some View {
        let list = store.otherServers.filter(matches)
        // 찾는 중에는 접혀 있어도 맞는 줄을 보인다
        let open = page.showOthers || !query.isEmpty
        if !list.isEmpty {
            ToggleHeading(collapsed: !open, toggle: { page.showOthers.toggle() }) {
                HStack(spacing: 8) {
                    Text("다른 앱").font(WL.section)
                    Text("\(list.count)").font(WL.caption).foregroundStyle(WL.quiet).monospacedDigit()
                    Text("편집기·메신저 같은 앱과 macOS가 연 포트").font(WL.caption).foregroundStyle(WL.faint)
                        .lineLimit(1)
                }
            } trailing: { EmptyView() }
            .padding(.bottom, 6)
            if open { rows(list) }
        }
    }

    private func rows(_ list: [PortsStore.Server]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { server in
                PortRow(store: store, page: page, server: server)
                if server.id != list.last?.id { RowDivider(inset: 48) }
            }
        }
    }
}

// MARK: - 줄

private struct PortRow: View {
    @ObservedObject var store: PortsStore
    @ObservedObject var page: PortsPage
    let server: PortsStore.Server
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(spacing: 12) {
            PortIcon(kind: server.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.title).font(WL.heading).lineLimit(1).truncationMode(.middle)
                    if server.log != nil {
                        DayBadge(text: "RunTime에서 실행", tint: WL.accent)
                            .tip("이 앱에서 다시 시작한 서버입니다. 출력은 ⋯ 메뉴의 ‘로그 보기’에서 봅니다")
                    }
                    if server.isWeb, !server.isLocalOnly {
                        DayBadge(text: "외부 접속 가능", tint: WL.waiting)
                            .tip("이 맥 밖에서도 접속됩니다. 휴대폰으로 확인할 때는 ⋯ 메뉴의 ‘휴대폰에서 열기’를 쓰세요")
                    }
                }
                Text(server.detail).font(WL.caption).foregroundStyle(WL.muted).lineLimit(1).truncationMode(.middle)
                    .tip(server.group.root.command)
                if let note = server.note {
                    HStack(spacing: 8) {
                        Text(note).font(WL.caption).foregroundStyle(WL.waiting).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        if isAirPlay {
                            Button("AirPlay 수신 끄러 가기") { openAirPlaySettings() }.buttonStyle(TextLinkButtonStyle())
                        } else if server.brewService != nil, server.mine {
                            Button("Homebrew 서비스 멈추기") { stopService() }.buttonStyle(TextLinkButtonStyle())
                                .tip("brew services stop으로 멈춰, 다시 켜지지 않게 합니다")
                        }
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            portChips
            actions
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .hoverRow()
        .onHover { hover.on = $0 }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(server.title), \(server.ports.map { "\($0)번" }.joined(separator: ", ")) 포트")
    }

    /// 포트 번호. 개발 서버는 눌러서 브라우저로 연다.
    private var portChips: some View {
        HStack(spacing: 4) {
            ForEach(server.ports.prefix(3), id: \.self) { port in
                if server.isWeb {
                    Button { open(port) } label: { Text(":" + String(port)) }
                        .buttonStyle(PortChipStyle(link: true))
                        .tip("http://localhost:\(String(port)) 열기")
                } else {
                    Text(":" + String(port)).modifier(PortChipLabel(link: false))
                }
            }
            if server.ports.count > 3 {
                Text("+\(server.ports.count - 3)").font(WL.caption).foregroundStyle(WL.quiet)
                    .tip(server.ports.dropFirst(3).map(String.init).joined(separator: ", "))
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var actions: some View {
        if let state = store.busy[server.id] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state).font(WL.caption).foregroundStyle(WL.muted)
            }
            .frame(width: 100, alignment: .trailing)
        } else {
            HStack(spacing: 6) {
                // 다른 앱 줄은 실수로 누르지 않게 종료를 ⋯ 메뉴에만 둔다.
                // Homebrew 서비스는 종료해도 다시 켜져서, 안내문 옆 ‘Homebrew 서비스 멈추기’만 둔다
                if server.kind.isDevelopment, server.brewService == nil {
                    Button("종료") { terminate(force: false) }
                        .buttonStyle(NotionButtonStyle())
                        .disabled(!server.canTerminate)
                        .tip(server.lockedReason ?? "서버와 하위 프로세스를 종료합니다. 응답이 없으면 ⋯ 메뉴의 ‘강제 종료’를 쓰세요")
                }
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(server.title) 메뉴")
            }
            .frame(width: 100, alignment: .trailing)
        }
    }

    @ViewBuilder private var menuItems: some View {
        if server.isWeb {
            Button("브라우저로 열기") { open(server.primaryPort) }
            Button("주소 복사") { copy("http://localhost:\(String(server.primaryPort))", "주소를 복사했습니다") }
            Button("휴대폰에서 열기…") { showPhone() }
            Divider()
        }
        // Homebrew 서비스는 launchd가 다시 띄우므로 여기서 다시 시작하면 둘이 뜬다
        if server.kind.isDevelopment, server.brewService == nil {
            Button("다시 시작…") { restart(samePort: true) }.disabled(!server.canTerminate)
            // DB는 포트 옵션 이름이 제각각이라 웹 서버만 포트를 바꾼다
            if server.isWeb { Button("다른 포트로 다시 시작…") { restart(samePort: false) }.disabled(!server.canTerminate) }
        }
        if server.brewService != nil {
            Button("Homebrew 서비스 멈추기") { stopService() }.disabled(!server.mine)
        }
        if let log = server.log { Button("로그 보기") { NSWorkspace.shared.open(log) } }
        if let cwd = server.cwd, cwd != "/", server.kind.isDevelopment {
            Button("Finder에서 폴더 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
        }
        if case .app(_, let bundle) = server.kind {
            Button("Finder에서 앱 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle)]) }
        }
        if isAirPlay { Button("AirPlay 수신 설정 열기") { openAirPlaySettings() } }
        Button("포트 번호 복사") { copy(String(server.primaryPort), "포트 번호를 복사했습니다") }
        Divider()
        if !server.kind.isDevelopment { Button("종료…") { terminate(force: false) }.disabled(!server.canTerminate) }
        Button("강제 종료…") { terminate(force: true) }.disabled(!server.canTerminate)
    }

    private var isAirPlay: Bool { server.kind == .system && server.listenerName == "ControlCenter" }

    // MARK: 동작

    private func stopService() {
        store.stopBrewService(server) { _, message in page.flash(message) }
    }

    private func open(_ port: Int) {
        if let url = URL(string: "http://localhost:\(String(port))") { NSWorkspace.shared.open(url) }
    }

    private func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        page.flash(message)
    }

    private func openAirPlaySettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!
        if !NSWorkspace.shared.open(pane) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
    }

    private func terminate(force: Bool) {
        // 개발 서버는 끄고 다시 켜는 일이 잦아 바로 끈다. 앱의 일부이거나 강제 종료면 한 번 묻는다
        let isApp: Bool = { if case .app = server.kind { return true } else { return false } }()
        if force || isApp || server.kind == .other {
            let alert = NSAlert()
            alert.messageText = "\(String(server.primaryPort))번 포트를 쓰는 프로세스를 \(force ? "강제 종료할까요?" : "종료할까요?")"
            var info: [String] = []
            if case .app(let name, _) = server.kind {
                info.append("\(name)의 일부(\(server.listenerName))만 종료합니다. 앱의 일부 기능이 멈출 수 있습니다.")
            }
            if force { info.append("정리할 틈 없이 바로 끊어서, 저장하지 않은 내용이 있으면 사라집니다.") }
            alert.informativeText = info.joined(separator: "\n")
            alert.addButton(withTitle: force ? "강제 종료" : "종료")
            alert.addButton(withTitle: "취소")
            if force { alert.buttons.first?.hasDestructiveAction = true }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.terminate(server, force: force) { _, message in page.flash(message) }
    }

    private func restart(samePort: Bool) {
        let taken = Set(store.servers.flatMap(\.ports))
        let alert = NSAlert()
        alert.messageText = samePort ? "\(String(server.primaryPort))번 포트 서버를 다시 시작할까요?"
            : "\(String(server.primaryPort))번 포트 서버를 다른 포트로 다시 시작할까요?"
        // 묻기 전에 다시 띄울 수 있는지부터 본다. 정확한 판단(함께 도는 프로세스)은 재시작할 때 목록을 다시 읽어 한다
        let preview = PortRestart.plan(chain: server.group.chain, from: server.primaryPort,
                                       to: samePort ? server.primaryPort : server.primaryPort + 1)
        if case .failure(let refusal) = preview { return page.flash(refusal.message) }
        // 터미널에서 띄운 서버라면 그 터미널은 프롬프트로 돌아가고 출력이 로그로 옮겨 간다. 모르고 누르면 당황하는 부분이다
        var info = "서버를 종료한 뒤 같은 폴더에서 다시 실행합니다. 그 뒤 출력은 터미널이 아니라 로그 파일에 쌓이고, ⋯ 메뉴의 ‘로그 보기’에서 볼 수 있습니다. 터미널에서 export한 환경변수는 이어지지 않습니다."
        if samePort, case .success(let plan) = preview { info += "\n\n실행할 명령: " + PortScan.displayCommand(tokens: plan.arguments, limit: 80) }
        let field = NSTextField(string: String(PortsStore.suggestedPort(after: server.primaryPort, avoiding: taken)))
        if !samePort {
            if case .success(let plan) = preview, plan.method == .environment {
                info += "\n\n이 명령은 포트 옵션을 알 수 없어 PORT 환경변수로만 넘깁니다. 서버가 이 값을 읽지 않으면 원래 포트로 뜹니다."
            }
            field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
            field.placeholderString = "새 포트 번호"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        alert.informativeText = info
        alert.addButton(withTitle: "다시 시작")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var port = server.primaryPort
        if !samePort {
            guard let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(number) else {
                return page.flash("포트는 1024부터 65535 사이의 숫자로 넣으세요")
            }
            if number != server.primaryPort {
                guard !taken.contains(number), PortRestart.isFree(number) else {
                    return page.flash("\(String(number))번 포트는 이미 쓰고 있습니다")
                }
            }
            port = number
        }
        store.restart(server, to: port) { ok, message, log in
            guard !ok, let log else { return page.flash(message) }
            // 실패하면 이유가 로그에 있으니 바로 열 수 있게 묻는다
            let alert = NSAlert()
            alert.messageText = "다시 시작하지 못했습니다"
            alert.informativeText = message
            alert.addButton(withTitle: "로그 보기")
            alert.addButton(withTitle: "닫기")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(log) }
        }
    }

    /// 같은 와이파이의 휴대폰으로 열 주소와 QR. 이 맥에서만 열린 서버면 여는 방법을 알려 준다.
    private func showPhone() {
        let alert = NSAlert()
        let port = String(server.primaryPort)
        if server.isLocalOnly {
            alert.messageText = "이 서버는 이 맥에서만 접속됩니다"
            alert.informativeText = "휴대폰에서 열려면 서버를 외부 접속 옵션으로 켜야 합니다.\nvite: npm run dev -- --host\nnext: next dev -H 0.0.0.0\n켠 뒤 다시 이 메뉴를 누르세요."
            alert.addButton(withTitle: "확인")
            alert.runModal()
            return
        }
        guard let address = PortsStore.lanAddress() else {
            alert.messageText = "이 맥의 와이파이 주소를 찾지 못했습니다"
            alert.informativeText = "와이파이나 유선 네트워크에 연결됐는지 확인하세요."
            alert.addButton(withTitle: "확인")
            alert.runModal()
            return
        }
        let url = "http://\(address):\(port)"
        alert.messageText = "휴대폰 카메라로 찍으세요"
        alert.informativeText = "\(url)\n휴대폰이 이 맥과 같은 와이파이에 있어야 열립니다."
        if let image = Self.qr(url) {
            let view = NSImageView(image: image)
            view.frame = NSRect(x: 0, y: 0, width: 180, height: 180)
            alert.accessoryView = view
        }
        alert.addButton(withTitle: "닫기")
        alert.addButton(withTitle: "주소 복사")
        if alert.runModal() == .alertSecondButtonReturn { copy(url, "휴대폰용 주소를 복사했습니다") }
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// 줄 왼쪽 아이콘. 앱은 앱 아이콘, 나머지는 종류를 나타내는 기호.
private struct PortIcon: View {
    let kind: PortKind

    var body: some View {
        Group {
            if case .app(_, let bundle) = kind {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundle)).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.13))
                    .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint))
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .devServer: return "chevron.left.forwardslash.chevron.right"
        case .database: return "cylinder.split.1x2"
        case .docker: return "shippingbox"
        case .system: return "gearshape"
        case .app, .other: return "app"
        }
    }

    private var tint: Color {
        switch kind {
        case .devServer: return WL.accent
        case .database: return WL.done
        case .docker: return WL.accent
        default: return WL.quiet
        }
    }
}

private struct PortChipLabel: ViewModifier {
    let link: Bool
    var pressed = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(link ? WL.accent : WL.muted)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(link ? WL.accent.opacity(pressed ? 0.2 : 0.1) : WL.hover))
    }
}

private struct PortChipStyle: ButtonStyle {
    let link: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PortChipLabel(link: link, pressed: configuration.isPressed)).contentShape(Rectangle())
    }
}
