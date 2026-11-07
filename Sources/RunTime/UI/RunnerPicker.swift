import SwiftUI
import UniformTypeIdentifiers
import UsageCore

/// 펫 고르기. 맨 위에 Claude로 만들기와 Petdex에서 찾기를 두고, 아래에 내 펫을 늘어놓는다.
/// 고른 펫과 마우스를 올린 펫은 실시간으로 달리고, 칸마다 호감도 하트와 같이 달리는 동료 표시가 붙는다.
/// 오른쪽 클릭으로 동료로 데려가기, 이름 바꾸기, 삭제를 한다.
struct RunnerPicker: View {
    @ObservedObject var settings: AppSettings
    /// 팝오버처럼 파일 창을 띄우면 닫혀 버리는 곳에서는 그림 불러오기를 이 동작(팝오버를 닫고 파일 창 열기)으로 넘긴다.
    var importInPlace: (() -> Void)?
    /// 팝오버처럼 늘 어두운 곳에서는 꾸미기와 같은 칸 틀을 쓴다. 설정 창은 시스템 밝기를 따른다.
    var gameStyle = false
    /// 앱 창처럼 넓은 곳에서는 칸을 키운다.
    var large = false
    @ObservedObject private var store = CustomRunnerStore.shared
    @ObservedObject private var petdex = PetdexStore.shared
    @ObservedObject private var decor = GameDecor.shared
    @ObservedObject private var factory = PetFactory.shared
    @StateObject private var hover = HoveredRunner()
    @StateObject private var importState = ImportState()
    @StateObject private var filter = RunnerFilter()
    @StateObject private var rename = RenameState()
    @StateObject private var maker = PetMakerText()

    /// 창이 넓어지면 칸 수가 늘어난다 (팝오버 폭에서는 4칸).
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: large ? 104 : 72), spacing: 8)] }

    var body: some View {
        let pets = petdex.pets.filter { filter.matches($0.name, $0.slug) }
        let made = pets.filter(\.isLocal)
        let downloaded = pets.filter { !$0.isLocal }
        let builtIns = Runner.allCases.filter { filter.matches($0.displayName, $0.rawValue) }
        let customs = store.runners.filter { filter.matches($0.name, "") }
        VStack(alignment: .leading, spacing: 10) {
            actions
            factoryStatus
            found
            if petdex.pets.count + store.runners.count > 6 { myPetSearch }
            if !made.isEmpty || !customs.isEmpty {
                groupTitle("내가 만든 펫")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(made) { petTile($0) }
                    // 내 그림 id는 UUID라 이름으로만 찾는다
                    ForEach(customs) { custom in
                        let selected = settings.customRunnerID == custom.id
                        selectable(custom.id, action: { settings.select(custom) }) {
                            tile(custom.character, key: custom.id, selected: selected)
                        }
                        .onHover { hover.update(custom.id, $0) }
                        .contextMenu {
                            companionButton(custom.id, name: custom.name)
                            customMenu(custom)
                        }
                        .tip("오른쪽 클릭: 동료로 데려가기, 이름 바꾸기, 실루엣, 삭제")
                    }
                }
            }
            if !downloaded.isEmpty {
                groupTitle("Petdex 펫")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(downloaded) { petTile($0) }
                }
            }
            if !builtIns.isEmpty {
                groupTitle("기본 펫")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(builtIns, id: \.self) { runner in
                        let selected = settings.customRunnerID == nil && settings.runner == runner
                        Button { settings.select(runner) } label: {
                            tile(runner.character, key: runner.rawValue, selected: selected)
                        }
                        .buttonStyle(.plain)
                        .onHover { hover.update(runner.rawValue, $0) }
                        .contextMenu { companionButton(runner.rawValue, name: runner.displayName) }
                        .accessibilityLabel(runner.displayName)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            if let message = importState.message {
                Text(message).font(.system(size: 12)).foregroundStyle(importState.isError ? .orange : Theme.secondary)
            }
            // 만들기·찾기 말고 드물게 쓰는 길은 맨 아래에 글자로만 둔다
            HStack(spacing: 14) {
                textLink("내 그림(GIF·PNG)으로 만들기") {
                    if let importInPlace { importInPlace() } else { RunnerImport.choose(settings: settings, report: importState.show) }
                }
                textLink("펫 폴더·zip 가져오기") { chooseFolder() }
            }
            .padding(.top, 2)
        }
    }

    /// 펫을 늘리는 두 가지 길. 칸에 설명을 쓰고 Claude로 만들거나, Petdex 창을 열어 직접 찾는다.
    @ViewBuilder
    private var actions: some View {
        if large {
            HStack(spacing: 8) {
                describeField
                makeButton
                findButton
            }
        } else {
            VStack(spacing: 6) {
                describeField
                HStack(spacing: 6) {
                    makeButton
                    findButton
                }
            }
        }
    }

    private var describeField: some View {
        HStack(spacing: 7) {
            Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold)).foregroundStyle(GameKit.gold)
            TextField(large ? "어떤 캐릭터를 만들까요? (맹구, 분홍 리본 고양이)" : "어떤 캐릭터를 만들까요?", text: $maker.text)
                .textFieldStyle(.plain).font(.system(size: 13.5))
                .onSubmit(make)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .slotFrame(radius: 9)
    }

    private var makeButton: some View {
        Button(action: make) {
            HStack(spacing: 5) {
                if factory.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 12, weight: .bold))
                }
                Text("Claude로 만들기")
            }
            .frame(maxWidth: large ? nil : .infinity)
        }
        .buttonStyle(PrimaryGameButtonStyle(height: 36))
        .disabled(maker.text.trimmingCharacters(in: .whitespaces).isEmpty || factory.isWorking)
        .tip("설명대로 Claude가 도트를 찍어 바로 러너로 골라요. 1~3분 걸려요")
    }

    private var findButton: some View {
        Button { PetdexWindow.shared.show(settings: settings) } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold))
                Text("Petdex에서 찾기")
            }
            .frame(maxWidth: large ? nil : .infinity)
        }
        .buttonStyle(GameButtonStyle(height: 36))
        .fixedSize(horizontal: large, vertical: false)
        .tip("petdex.dev에 올라온 펫 수천 개 중에서 골라 받기")
    }

    private func textLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
    }

    private func make() { factory.make(maker.text, settings: settings) }

    /// 내 펫이 많을 때만 나오는 이름 찾기.
    private var myPetSearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
            TextField("내 펫 이름으로 거르기", text: $filter.query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
            if !filter.query.isEmpty {
                Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.tertiary).accessibilityLabel("지우기")
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
    }

    @ViewBuilder
    private var factoryStatus: some View {
        switch factory.state {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.primary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .slotFrame(radius: 9)
        case .failed(let text):
            statusLine(text, color: .orange, redraw: false)
        case .done(let text):
            statusLine(text, color: Theme.primary, redraw: factory.lastMade != nil)
        }
    }

    private func statusLine(_ text: String, color: Color, redraw: Bool) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            if redraw {
                Button("다시 그리기") { factory.redraw(settings: settings) }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .bold)).foregroundStyle(GameKit.gold)
            }
            Spacer(minLength: 4)
            Button { factory.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.tertiary).accessibilityLabel("닫기")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .slotFrame(radius: 9)
    }

    /// 이 Mac에 이미 있던 펫 (다른 도구로 만든 것). 새로 생기는 펫은 저절로 등록된다.
    @ViewBuilder
    private var found: some View {
        let list = petdex.scanLocalPets()
        if !list.isEmpty {
            FlowLayout(spacing: 6) {
                Text("이 Mac에서 찾은 펫").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                ForEach(list) { pet in
                    Button(pet.name) { bring(pet.folder) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
        }
    }

    private func bring(_ url: URL) {
        petdex.importLocal(from: url) { [settings, factory, importState] result in
            switch result {
            case .success(let pet):
                settings.customRunnerID = PetdexStore.storageID(pet.slug)
                factory.announce("'\(pet.name)'을(를) 데려왔어요")
            case .failure(let error):
                importState.show(error.localizedDescription, error: true)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "pet.json과 스프라이트 시트가 든 폴더나 zip을 고르세요"
        panel.prompt = "가져오기"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bring(url)
    }

    /// 받은 펫·직접 만든 펫 칸.
    @ViewBuilder
    private func petTile(_ pet: PetdexStore.Pet) -> some View {
        if let character = petdex.character(for: pet) {
            let id = PetdexStore.storageID(pet.slug)
            let selected = settings.customRunnerID == id
            selectable(id, action: { settings.customRunnerID = id }) {
                tile(character, key: id, selected: selected)
            }
            .onHover { hover.update(id, $0) }
            .accessibilityLabel(pet.name)
            .contextMenu {
                companionButton(id, name: pet.name)
                Button("이름 바꾸기") { rename.start(id, name: pet.name) { petdex.rename(pet, to: $0) } }
                if !pet.isLocal {
                    Button("Petdex에서 보기") {
                        if let url = URL(string: "https://petdex.dev/pets/\(pet.slug)") { NSWorkspace.shared.open(url) }
                    }
                }
                Divider()
                Button("삭제") {
                    if selected { settings.customRunnerID = nil }
                    if decor.companionID == id { decor.companionID = nil }
                    petdex.delete(pet)
                }
            }
            .tip("오른쪽 클릭: 동료로 데려가기, 이름 바꾸기, 삭제")
        }
    }

    /// 같이 달리는 동료로 데려가거나 혼자 달리게 한다.
    @ViewBuilder
    private func companionButton(_ id: String, name: String) -> some View {
        if decor.companionID == id {
            Button("혼자 달리기") { decor.companionID = nil }
        } else {
            Button("\(name) 동료로 데려가기") { decor.companionID = id }
        }
        Divider()
    }

    @ViewBuilder
    private func groupTitle(_ text: String) -> some View {
        if gameStyle {
            GameSectionHeader(title: text).padding(.top, 4)
        } else {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func tile(_ character: RunnerCharacter, key: String, selected: Bool) -> some View {
        let live = selected || hover.key == key
        return VStack(spacing: 3) {
            Group {
                if live {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        CharacterCanvas(character: character, theme: settings.spriteTheme, date: context.date,
                                        activity: selected ? .run : .walk)
                    }
                } else {
                    CharacterCanvas(character: character, theme: settings.spriteTheme, date: nil, activity: .stand)
                }
            }
            .frame(height: large ? 76 : 56)
            TileName(name: character.name, key: key, selected: selected, rename: rename)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .overlay(alignment: .topLeading) {
            if decor.companionID == key {
                Image(systemName: "pawprint.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(Circle().fill(Theme.accent)).padding(4)
                    .tip("같이 달리는 동료")
            }
        }
        .modifier(TileFrame(gameStyle: gameStyle, selected: selected, live: live))
        .contentShape(Rectangle())
    }

    /// 칸 바탕. 팝오버는 꾸미기와 같은 칸 틀, 설정 창은 밝기에 맞춘 캐릭터 바탕.
    private struct TileFrame: ViewModifier {
        let gameStyle: Bool
        let selected: Bool
        let live: Bool

        func body(content: Content) -> some View {
            if gameStyle {
                content.slotFrame(highlight: selected ? Theme.accent : nil, radius: 8)
            } else {
                content
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.characterBackdrop.opacity(selected ? 1 : (live ? 0.85 : 0.6))))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }

    /// 고를 수 있는 칸. 이름을 고치는 동안은 단추로 감싸지 않아야 입력 칸이 클릭을 받는다.
    @ViewBuilder
    private func selectable<Label: View>(_ key: String, action: @escaping () -> Void,
                                         @ViewBuilder label: () -> Label) -> some View {
        if rename.id == key {
            label()
        } else {
            Button(action: action, label: label).buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func customMenu(_ custom: CustomRunner) -> some View {
        Button("이름 바꾸기") { startRenaming(custom) }
        Button(custom.silhouette ? "원본 색으로 보기" : "메뉴바 색에 맞춰 실루엣으로 보기") {
            var updated = custom
            updated.silhouette.toggle()
            store.update(updated)
        }
        Divider()
        Button("삭제") {
            if settings.customRunnerID == custom.id { settings.customRunnerID = nil }
            store.delete(custom)
        }
    }

    private func startRenaming(_ custom: CustomRunner) {
        rename.start(custom.id, name: custom.name) { name in
            var updated = custom
            updated.name = name
            store.update(updated)
        }
    }
}

/// 러너 한 마리를 컬러로 그리는 캔버스. `date`가 있으면 그 시각의 동작을, 없으면 정지 자세를 그린다.
struct CharacterCanvas: View {
    let character: RunnerCharacter
    let theme: SpriteTheme
    let date: Date?
    var activity: CharacterPose.Activity = .run

    var body: some View {
        Canvas { context, size in
            let seconds = date?.timeIntervalSinceReferenceDate ?? 0
            let cycle: Double = activity == .run ? 0.72 : (activity == .walk ? 1.25 : 2.4)
            let phase = CGFloat(seconds.truncatingRemainder(dividingBy: cycle * 100) / cycle)
            let frame = MotionFrame(pose: CharacterPose(activity: activity, phase: phase))
            context.withCGContext { cg in
                CharacterCanvas.draw(cg, size: size, rig: character.rig, frame: frame,
                                     theme: character.theme(theme), themePhase: CGFloat(seconds / 6))
            }
        }
    }

    /// 설계 좌표를 `size`에 맞게 키워 컬러로 그린다.
    static func draw(_ cg: CGContext, size: CGSize, rig: CharacterRig, frame: MotionFrame, theme: SpriteTheme,
                     themePhase: CGFloat, alarm: Bool = false) {
        let scale = min(size.width / Stage.size.width, size.height / Stage.size.height)
        cg.translateBy(x: (size.width - Stage.size.width * scale) / 2,
                       y: (size.height - Stage.size.height * scale) / 2)
        cg.scaleBy(x: scale, y: scale)
        var look = CharacterLook(rich: true, palette: theme.richPalette(rig.palette, phase: themePhase),
                                 tint: .white, outline: max(0.32, 1.1 / scale))
        look.alarm = alarm
        let scene = CharacterScene(rig: rig, pose: frame.pose, transform: frame.transform)
        scene.draw(in: cg, look: look)
        for effect in frame.effects {
            effect.draw(in: cg, around: scene.placedBounds, tint: .white)
        }
    }
}

/// 러너 검색어. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class RunnerFilter: ObservableObject {
    @Published var query = ""

    /// 이름이나 id에 검색어가 모두 들어 있는지. 비어 있으면 모두 보인다.
    func matches(_ name: String, _ id: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        let haystack = "\(name) \(id)".lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// 마우스가 올라간 러너. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class HoveredRunner: ObservableObject {
    @Published var key: String?

    func update(_ key: String, _ inside: Bool) {
        if inside { self.key = key } else if self.key == key { self.key = nil }
    }
}

/// 펫 설명 입력. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class PetMakerText: ObservableObject {
    @Published var text = ""
}

final class ImportState: ObservableObject {
    @Published var message: String?
    @Published var isError = false

    func show(_ message: String, error: Bool) {
        self.message = message
        isError = error
    }
}

/// 그림 파일을 골라 내 러너를 만든다. 만든 러너는 바로 고른다.
enum RunnerImport {
    @MainActor
    static func choose(settings: AppSettings, report: @escaping (String, Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .heic, .webP, .image]
        panel.allowsMultipleSelection = true
        panel.message = "움직이는 GIF 하나, 또는 프레임 PNG 여러 장을 고르세요"
        panel.prompt = "불러오기"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        report("그림을 불러오는 중…", false)
        CustomRunnerStore.shared.importImages(from: panel.urls) { result in
            switch result {
            case .success(let custom):
                settings.select(custom)
                report("'\(custom.name)' 러너를 만들었습니다 (\(custom.frameCount)프레임).", false)
            case .failure(let error):
                report(error.localizedDescription, true)
            }
        }
    }
}

/// 칸 안에서 이름을 바로 고치는 중인지. 팝오버에서 알림 창을 띄우면 팝오버가 닫혀서 칸 이름표 자리에서 고친다.
final class RenameState: ObservableObject {
    @Published private(set) var id: String?
    private(set) var original = ""
    private var commit: ((String) -> Void)?

    func start(_ id: String, name: String, commit: @escaping (String) -> Void) {
        original = name
        self.commit = commit
        self.id = id
    }

    /// 빈 이름이나 그대로인 이름은 바꾸지 않는다. 이름표가 좁아 12자까지만 둔다.
    func finish(_ text: String?) {
        let name = String((text ?? "").trimmingCharacters(in: .whitespaces).prefix(12))
        if !name.isEmpty, name != original { commit?(name) }
        commit = nil
        id = nil
    }
}

/// 나타나자마자 글자를 받는 이름 칸. return이면 저장, esc면 취소, 다른 곳을 누르면 저장한다.
struct InlineNameField: NSViewRepresentable {
    let text: String
    let finish: (String?) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .labelColor
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            // 오른쪽 클릭 메뉴가 닫힌 직후라 팝오버 창이 키 창이 아닐 수 있다
            field.window?.makeKey()
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.finish = finish
    }

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var finish: (String?) -> Void
        private var done = false

        init(finish: @escaping (String?) -> Void) { self.finish = finish }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                end(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                end(nil)
                return true
            default:
                return false
            }
        }

        /// 다른 곳을 눌러 입력이 끝나면 저장한다. 창이 키를 잃어서 끝난 것(메뉴가 닫히는 순간 등)은 무시하고 칸을 남긴다.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field.window?.isKeyWindow == true else { return }
            end(field.stringValue)
        }

        private func end(_ value: String?) {
            guard !done else { return }
            done = true
            DispatchQueue.main.async { [finish] in finish(value) }
        }
    }
}

/// 칸 아래 이름표. 이름을 고치는 중이면 그 자리가 입력 칸이 된다.
struct TileName: View {
    let name: String
    let key: String
    let selected: Bool
    @ObservedObject var rename: RenameState

    var body: some View {
        if rename.id == key {
            InlineNameField(text: name) { rename.finish($0) }
                .frame(height: 17)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.accent.opacity(0.8)))
                .padding(.horizontal, 6)
        } else {
            Text(name)
                .font(.system(size: 12, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
        }
    }
}
