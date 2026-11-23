import AppKit
import SwiftUI

/// 계정 추가·수정 창. 띠 위에 뜨는 작은 창이라 띠보다 한 단 위에 둔다.
/// 시스템 색을 그대로 써서 밝은 화면·어두운 화면 모두 macOS 기본 창처럼 보이게 한다.
@MainActor
final class AccountDraft: ObservableObject {
    @Published var title: String
    @Published var username: String
    @Published var password: String
    @Published var site: String
    @Published var submit: Bool
    @Published var reveal = false
    @Published var error: String?

    let heading: String
    let existing: Bool
    /// 머리 타일 색. 이름을 칠 때마다 바뀌지 않게 창을 열 때 한 번 정한다.
    let tint: Color
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}
    var onDelete: (() -> Void)?
    /// 단추가 그려진 자리 (창 기준, 위가 0). 점검(--clip-check)이 그 자리를 눌러 본다. 화면을 다시 그리지 않게 @Published가 아니다.
    var buttonFrames: [String: CGRect] = [:]

    init(account: Account, password: String, heading: String, existing: Bool) {
        title = account.title
        username = account.username
        self.password = password
        site = account.site
        submit = account.submit
        self.heading = heading
        self.existing = existing
        tint = existing ? Account.color(for: account) : Color(nsColor: .systemGray)
    }

    /// 이름을 비워 두면 사이트 주소로 채운다.
    var resolvedTitle: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        return CredentialParser.host(of: site) ?? site
    }

}

/// 계정 추가·수정 창.
/// 띠처럼 앱을 앞으로 올리지 않는 창이다. 앱을 올리는 창이면 RunTime이 뒤에 있는 동안 누르기 한 번이 앱 올리기에 먼저 쓰이고,
/// SwiftUI 단추는 그 첫 누르기를 받지 않아 저장·취소·닫기가 듣지 않았다 (글자 칸은 첫 누르기를 받아 입력은 됐다).
/// 크기는 처음 한 번만 정한다. 안내·오류 줄이 생길 때마다 창이 커졌다 줄면 단추를 누르는 자리가 어긋난다.
final class AccountEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    private(set) var draft: AccountDraft?

    static func make(_ draft: AccountDraft) -> AccountEditorPanel {
        let host = FirstClickHostingView(rootView: AccountEditorView(draft: draft))
        // 크기를 재고 나서 끈다. 먼저 끄면 잴 수 없어 0이 나온다
        let size = host.fittingSize
        host.sizingOptions = []
        let panel = AccountEditorPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 바탕을 끌어 창을 옮기게 하면 단추 누르기가 창 끌기로 잡힐 수 있다
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // 띠(.modalPanel)보다 위
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.draft = draft
        return panel
    }
}

/// 창이 키를 갖기 전의 첫 누르기도 단추로 보낸다.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct AccountEditorView: View {
    @ObservedObject var draft: AccountDraft
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, username, password, site }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                field("이름", .title, text: $draft.title, placeholder: draft.resolvedTitle.isEmpty ? "예: 네이버, 사내 메일" : draft.resolvedTitle)
                field("아이디", .username, text: $draft.username, placeholder: "아이디 또는 이메일")
                passwordField
                VStack(alignment: .leading, spacing: 5) {
                    field("사이트", .site, text: $draft.site, placeholder: "naver.com")
                    Text(verbatim: "창 제목에 이 이름이 있으면 계정 탭 맨 앞에 둡니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 2)
                Toggle(isOn: $draft.submit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "넣은 뒤 로그인까지").font(.system(size: 13))
                        Text(verbatim: "비밀번호 칸을 확인했을 때만 ↩를 누릅니다.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            Divider()
            footer
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .onAppear {
            DispatchQueue.main.async {
                focus = draft.title.isEmpty && draft.site.isEmpty ? .title : (draft.username.isEmpty ? .username : .password)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(verbatim: initial)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(draft.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: draft.heading)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: draft.resolvedTitle.isEmpty ? "새 계정" : draft.resolvedTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { draft.onCancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("닫기 (esc)")
            .accessibilityLabel("닫기")
            .modifier(Checkpoint(name: "닫기", draft: draft))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var initial: String {
        let source = draft.resolvedTitle.isEmpty ? draft.username : draft.resolvedTitle
        return source.first.map { String($0).uppercased() } ?? "+"
    }

    private func field(_ label: String, _ id: Field, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focus, equals: id)
                .modifier(InputBox(focused: focus == id))
                .modifier(Checkpoint(name: label, draft: draft))
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: "비밀번호").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    draft.password = AccountEditor.makePassword()
                    draft.reveal = true
                    focus = .password
                } label: {
                    Label { Text(verbatim: "새로 만들기") } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .font(.system(size: 11.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.link)
                .help("헷갈리는 글자를 뺀 16자 비밀번호")
                .modifier(Checkpoint(name: "새로 만들기", draft: draft))
            }
            HStack(spacing: 6) {
                Group {
                    if draft.reveal {
                        TextField("", text: $draft.password)
                    } else {
                        SecureField("", text: $draft.password)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: draft.reveal ? .monospaced : .default))
                .focused($focus, equals: .password)
                Button {
                    draft.reveal.toggle()
                    focus = .password
                } label: {
                    Image(systemName: draft.reveal ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(draft.reveal ? "가리기" : "보기")
                .accessibilityLabel(draft.reveal ? "비밀번호 가리기" : "비밀번호 보기")
                .modifier(Checkpoint(name: "비밀번호 보기", draft: draft))
            }
            .modifier(InputBox(focused: focus == .password))
            // 비밀번호가 비어도 자리를 남겨 둔다. 줄이 생겼다 사라지면 창 높이가 바뀐다
            Text(verbatim: draft.password.isEmpty ? " " : strength)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 몇 자이고 어떤 글자가 섞였는지. 점수 대신 사실만 보인다.
    private var strength: String {
        let p = draft.password
        var kinds: [String] = []
        if p.contains(where: \.isLowercase) { kinds.append("소문자") }
        if p.contains(where: \.isUppercase) { kinds.append("대문자") }
        if p.contains(where: \.isNumber) { kinds.append("숫자") }
        if p.contains(where: { !$0.isLetter && !$0.isNumber }) { kinds.append("기호") }
        return "\(p.count)자" + (kinds.isEmpty ? "" : " · " + kinds.joined(separator: ", "))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = draft.error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else if let delete = draft.onDelete {
                Button { delete() } label: {
                    // 글자 사이 빈 곳도 눌리게 단추 전체를 누를 자리로 둔다
                    Text(verbatim: "계정 삭제").foregroundStyle(Color(nsColor: .systemRed))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .modifier(Checkpoint(name: "계정 삭제", draft: draft))
            } else {
                Label { Text(verbatim: "비밀번호는 이 Mac 키체인에만 둡니다") } icon: { Image(systemName: "lock.fill") }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("취소") { draft.onCancel() }
                .keyboardShortcut(.cancelAction)
                .modifier(Checkpoint(name: "취소", draft: draft))
            Button("저장") { draft.onSave() }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.password.isEmpty)
                .modifier(Checkpoint(name: "저장", draft: draft))
        }
        .controlSize(.regular)
        .frame(height: 28)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// 단추 자리를 draft에 적어 둔다.
private struct Checkpoint: ViewModifier {
    let name: String
    let draft: AccountDraft

    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear
                .onAppear { draft.buttonFrames[name] = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { draft.buttonFrames[name] = $0 }
        })
    }
}

/// 입력칸 테두리. 초점이 오면 강조색 테두리.
private struct InputBox: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

extension Account {
    /// 계정마다 색을 정해 두어 카드와 수정 창에서 같은 계정을 빨리 알아보게 한다.
    /// 이름이나 사이트를 고쳐도 색이 바뀌지 않게 계정 id로 정한다.
    static func color(for account: Account) -> Color {
        let palette: [Color] = [
            Color(red: 0.24, green: 0.45, blue: 0.86), Color(red: 0.13, green: 0.6, blue: 0.48), Color(red: 0.84, green: 0.45, blue: 0.18),
            Color(red: 0.55, green: 0.36, blue: 0.85), Color(red: 0.8, green: 0.3, blue: 0.4), Color(red: 0.2, green: 0.55, blue: 0.7),
        ]
        let key = account.id.uuidString
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}
