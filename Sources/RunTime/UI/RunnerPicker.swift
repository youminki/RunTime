import SwiftUI
import UniformTypeIdentifiers
import UsageCore

/// 러너 고르기. 각 러너를 컬러로 보여 주고, 고른 러너와 마우스를 올린 러너는 실시간으로 달린다.
/// 'Petdex'는 petdex.dev에서 골라 받은 펫, 맨 아래 '내 러너'는 사용자가 불러온 GIF·PNG로 만든 러너다.
struct RunnerPicker: View {
    @ObservedObject var settings: AppSettings
    /// 팝오버처럼 파일 창을 띄우면 닫혀 버리는 곳에서는 그림 불러오기를 이 동작(팝오버를 닫고 파일 창 열기)으로 넘긴다.
    var importInPlace: (() -> Void)?
    @ObservedObject private var store = CustomRunnerStore.shared
    @ObservedObject private var petdex = PetdexStore.shared
    @StateObject private var hover = HoveredRunner()
    @StateObject private var importState = ImportState()
    @StateObject private var filter = RunnerFilter()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    /// 이름표 없이 돋보기와 안내 글만 둔 검색칸. Form 안에서 이름표가 왼쪽 절반을 차지하지 않게 한다.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("이름으로 찾기", text: $filter.query, prompt: Text("이름으로 찾기"))
                .textFieldStyle(.plain)
                .labelsHidden()
            if !filter.query.isEmpty {
                Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    var body: some View {
        let pets = petdex.pets.filter { filter.matches($0.name, $0.slug) }
        VStack(alignment: .leading, spacing: 8) {
            searchField
            ForEach(Runner.Group.allCases, id: \.self) { group in
                let runners = Runner.runners(in: group).filter { filter.matches($0.displayName, $0.rawValue) }
                if !runners.isEmpty {
                    groupTitle(group.rawValue)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(runners, id: \.self) { runner in
                            let selected = settings.customRunnerID == nil && settings.runner == runner
                            Button { settings.select(runner) } label: {
                                tile(runner.character, key: runner.rawValue, selected: selected)
                            }
                            .buttonStyle(.plain)
                            .onHover { hover.update(runner.rawValue, $0) }
                            .accessibilityLabel(runner.displayName)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            }
            groupTitle("Petdex")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(pets) { pet in
                    if let character = petdex.character(for: pet) {
                        let id = PetdexStore.storageID(pet.slug)
                        let selected = settings.customRunnerID == id
                        Button { settings.customRunnerID = id } label: {
                            tile(character, key: id, selected: selected)
                        }
                        .buttonStyle(.plain)
                        .onHover { hover.update(id, $0) }
                        .accessibilityLabel(pet.name)
                        .contextMenu {
                            Button("Petdex에서 보기") {
                                if let url = URL(string: "https://petdex.dev/pets/\(pet.slug)") { NSWorkspace.shared.open(url) }
                            }
                            Divider()
                            Button("삭제") {
                                if selected { settings.customRunnerID = nil }
                                petdex.delete(pet)
                            }
                        }
                        .help("오른쪽 클릭: Petdex에서 보기, 삭제")
                    }
                }
                Button { PetdexWindow.shared.show(settings: settings) } label: {
                    actionTile(icon: "magnifyingglass", title: "Petdex에서 찾기")
                }
                .buttonStyle(.plain)
                .help("petdex.dev에 올라온 펫 수천 개 중에서 골라 러너로 받기")
            }
            groupTitle("내 러너")
            LazyVGrid(columns: columns, spacing: 8) {
                // 내 러너 id는 UUID라 이름으로만 찾는다
                ForEach(store.runners.filter { filter.matches($0.name, "") }) { custom in
                    let selected = settings.customRunnerID == custom.id
                    Button { settings.select(custom) } label: {
                        tile(custom.character, key: custom.id, selected: selected)
                    }
                    .buttonStyle(.plain)
                    .onHover { hover.update(custom.id, $0) }
                    .contextMenu { customMenu(custom) }
                    .help("오른쪽 클릭: 이름 바꾸기, 실루엣, 삭제")
                }
                Button {
                    if let importInPlace { importInPlace() } else { RunnerImport.choose(settings: settings, report: importState.show) }
                } label: {
                    actionTile(icon: "plus", title: "그림 불러오기")
                }
                    .buttonStyle(.plain)
                    .help("GIF나 PNG(여러 장이면 파일 이름 순서가 프레임 순서)로 러너 만들기")
            }
            if let message = importState.message {
                Text(message).font(.caption).foregroundStyle(importState.isError ? .orange : .secondary)
            }
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func tile(_ character: RunnerCharacter, key: String, selected: Bool) -> some View {
        let live = selected || hover.key == key
        return VStack(spacing: 3) {
            Group {
                if live {
                    TimelineView(.animation) { context in
                        CharacterCanvas(character: character, theme: settings.spriteTheme, date: context.date,
                                        activity: selected ? .run : .walk)
                    }
                } else {
                    CharacterCanvas(character: character, theme: settings.spriteTheme, date: nil, activity: .stand)
                }
            }
            .frame(height: 56)
            Text(character.name)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Palette.characterBackdrop.opacity(selected ? 1 : (live ? 0.85 : 0.6))))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.06), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func actionTile(icon: String, title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(height: 56)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func customMenu(_ custom: CustomRunner) -> some View {
        Button("이름 바꾸기…") { rename(custom) }
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

    private func rename(_ custom: CustomRunner) {
        let alert = NSAlert()
        alert.messageText = "러너 이름"
        let field = NSTextField(string: custom.name)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "바꾸기")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var updated = custom
        updated.name = String(name.prefix(12))
        store.update(updated)
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
