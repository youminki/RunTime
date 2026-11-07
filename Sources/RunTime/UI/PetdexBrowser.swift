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
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("이름으로 찾기 (짱구, 피카츄, 고양이)", text: $form.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                    if !form.query.isEmpty {
                        Button { form.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("검색어 지우기")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
                Picker("", selection: $form.kind) {
                    ForEach(PetdexStore.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("닫기", action: close).keyboardShortcut(.cancelAction)
            }
            // 자주 찾는 낱말. 누르면 검색칸에 넣는다
            HStack(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { word in
                    Button(word) { form.query = form.query == word ? "" : word }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: form.query == word ? .bold : .medium))
                        .foregroundStyle(form.query == word ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.primary.opacity(form.query == word ? 0.14 : 0.05)))
                        .contentShape(Capsule())
                }
                Spacer(minLength: 8)
                status(results.count)
            }
            SlimScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
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
            if results.isEmpty, store.catalogState == .loaded {
                Text("찾는 펫이 없어요. 다른 이름으로 찾거나, 펫 탭의 '펫 만들기'로 직접 만들어 보세요")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(width: 780, height: 680)
        .onAppear { store.loadCatalog() }
    }

    @ViewBuilder
    private func status(_ count: Int) -> some View {
        switch store.catalogState {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("목록을 받는 중…")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let reason):
            HStack(spacing: 6) {
                Text("목록을 받지 못했어요 (\(reason))").foregroundStyle(.orange)
                Button("다시 시도") { store.loadCatalog(force: true) }.controlSize(.small)
            }
            .font(.system(size: 12))
        case .loaded:
            HStack(spacing: 6) {
                Text(form.message ?? "\(count.formatted())개 / 전체 \(store.entries.count.formatted())개")
                    .foregroundStyle(form.isError ? .orange : .secondary)
                    .lineLimit(1)
                Button { store.loadCatalog(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .tip("새로 올라온 펫 받기")
                    .accessibilityLabel("목록 새로 받기")
            }
            .font(.system(size: 12))
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
    // 종류를 고르면 찾던 이름이 다른 갈래에 있을 때 안 보여서 늘 전체로 시작한다
    @Published var kind: PetdexStore.Kind = .all { didSet { message = nil } }
    @Published var message: String?
    @Published var isError = false
    /// 마지막으로 누른 펫.
    var pending: String?

    func show(_ message: String, error: Bool) {
        self.message = message
        isError = error
    }
}
