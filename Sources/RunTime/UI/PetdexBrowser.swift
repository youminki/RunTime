import SwiftUI

/// Petdex 펫 찾기. 썸네일을 누르면 내려받아 바로 러너로 고른다.
struct PetdexBrowser: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var form: PetdexSearch
    var close: () -> Void
    @ObservedObject private var store = PetdexStore.shared

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]
    private static let suggestions = ["고양이", "강아지", "토끼", "곰", "펭귄", "여우", "판다", "슬라임", "포켓몬"]

    var body: some View {
        let results = store.search(form.query, kind: form.kind)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("이름으로 찾기 (예: 짱구, 피카츄, 고양이)", text: $form.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13.5))
                Picker("", selection: $form.kind) {
                    ForEach(PetdexStore.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // 자주 찾는 낱말. 누르면 검색칸에 넣는다
            HStack(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { word in
                    Button(word) { form.query = form.query == word ? "" : word }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: form.query == word ? .bold : .medium))
                        .foregroundStyle(form.query == word ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(Capsule().fill(Color.primary.opacity(form.query == word ? 0.14 : 0.05)))
                        .contentShape(Capsule())
                }
            }
            status(results.count)
            SlimScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results) { entry in
                        Button { install(entry) } label: { tile(entry) }
                            .buttonStyle(.plain)
                            .tip("원래 이름 \(entry.displayName) · 올린 사람 \(entry.submittedBy ?? "알 수 없음")")
                            .contextMenu {
                                if let page = entry.pageURL { Button("Petdex에서 보기") { NSWorkspace.shared.open(page) } }
                            }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack(alignment: .top) {
                Text("Petdex 펫은 사용자가 올린 팬아트입니다. 원작 권리는 원작자에게 있으니 개인적으로만 쓰세요. 고른 펫만 이 Mac에 내려받습니다.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 720, height: 640)
        .onAppear { store.loadCatalog() }
    }

    @ViewBuilder
    private func status(_ count: Int) -> some View {
        switch store.catalogState {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Petdex 목록을 받는 중…")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let reason):
            HStack(spacing: 6) {
                Text("목록을 받지 못했습니다 (\(reason))").foregroundStyle(.orange)
                Button("다시 시도") { store.loadCatalog(force: true) }.controlSize(.small)
            }
            .font(.system(size: 12))
        case .loaded:
            Text(form.message ?? "펫 \(store.entries.count.formatted())개 중 \(count.formatted())개")
                .font(.system(size: 12))
                .foregroundStyle(form.isError ? .orange : .secondary)
        }
    }

    private func tile(_ entry: PetdexStore.Entry) -> some View {
        let installed = store.isInstalled(entry.slug)
        let selected = settings.customRunnerID == PetdexStore.storageID(entry.slug)
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: entry.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.none).scaledToFit()
                    } else {
                        Color.primary.opacity(0.04)
                    }
                }
                // Petdex 썸네일은 양 끝 1px에 어두운 선이 있어 가장자리를 잘라 낸다
                .frame(width: 84, height: 84)
                .frame(width: 76, height: 76)
                .clipped()
                if store.installing.contains(entry.slug) {
                    ProgressView().controlSize(.small)
                } else if installed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            Text(store.koreanNames[entry.slug] ?? entry.displayName)
                .font(.system(size: 12, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(selected ? 0.08 : 0.025)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.06), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func install(_ entry: PetdexStore.Entry) {
        form.pending = entry.slug
        form.show("\(store.koreanNames[entry.slug] ?? entry.displayName) 받는 중…", error: false)
        store.install(entry) { [settings, form] result in
            switch result {
            case .success(let pet):
                // 받는 사이 다른 펫을 눌렀으면 마지막으로 누른 펫을 고른다
                guard form.pending == pet.slug else { return }
                settings.customRunnerID = PetdexStore.storageID(pet.slug)
                form.show("'\(pet.name)'을(를) 러너로 골랐습니다.", error: false)
            case .failure(PetdexStore.InstallError.inProgress):
                break
            case .failure(let error):
                form.show(error.localizedDescription, error: true)
            }
        }
    }
}

/// 검색 입력. `@State`를 못 쓰는 이유는 HoverFlag 참고.
final class PetdexSearch: ObservableObject {
    @Published var query = "" { didSet { message = nil } }
    // 물건(서류함 등)보다 동물·캐릭터를 찾는 사람이 많아 동물부터 보인다
    @Published var kind: PetdexStore.Kind = .creature { didSet { message = nil } }
    @Published var message: String?
    @Published var isError = false
    /// 마지막으로 누른 펫.
    var pending: String?

    func show(_ message: String, error: Bool) {
        self.message = message
        isError = error
    }
}
