import AppKit
import ImageIO
import SearchCore

/// Petdex(petdex.dev)에 올라온 Codex 펫을 찾아 러너로 내려받는다.
/// 펫은 사용자가 올린 팬아트라 앱에 싣지 않고, 사용자가 고른 것만 이 Mac의 Application Support에 받는다.
/// 목록을 볼 때와 펫을 고를 때만 petdex.dev에 접속하고, 사용자 정보는 보내지 않는다. 메인 스레드에서만 쓴다.
final class PetdexStore: ObservableObject {
    static let shared = PetdexStore()

    /// 목록의 펫 하나 (https://petdex.dev/api/manifest).
    struct Entry: Codable, Identifiable, Hashable {
        let slug: String
        let displayName: String
        let kind: String
        let submittedBy: String?
        let spritesheetUrl: String

        var id: String { slug }
        var thumbnailURL: URL? { URL(string: "https://assets.petdex.dev/pets/\(slug)/thumb.webp") }
        var pageURL: URL? { URL(string: "https://petdex.dev/pets/\(slug)") }
    }

    /// 내려받은 펫.
    struct Pet: Codable, Identifiable, Equatable {
        let slug: String
        var name: String
        let submittedBy: String?
        let added: Date

        var id: String { slug }
    }

    enum Kind: String, CaseIterable {
        case all, character, creature, object

        var displayName: String {
            switch self {
            case .all: return "전체"
            case .character: return "캐릭터"
            case .creature: return "동물·생물"
            case .object: return "물건"
            }
        }
    }

    enum CatalogState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    enum InstallError: LocalizedError {
        case badSource
        case download(String)
        case inProgress

        var errorDescription: String? {
            switch self {
            case .badSource: return "Petdex 주소가 아닌 그림이라 받지 않았습니다."
            case .download(let reason): return "내려받지 못했습니다 (\(reason))."
            case .inProgress: return "이미 받는 중입니다."
            }
        }
    }

    /// petdex.dev 밖으로 넘기는 리디렉션은 따라가지 않는다 (목록 주소는 assets.petdex.dev로 넘어간다).
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(PetdexStore.isPetdexURL(request.url) ? request : nil)
        }
    }

    private let session = URLSession(configuration: .default, delegate: RedirectGuard(), delegateQueue: nil)

    static func isPetdexURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host else { return false }
        return host == "petdex.dev" || host.hasSuffix(".petdex.dev")
    }

    static let manifestURL = URL(string: "https://petdex.dev/api/manifest")!
    /// 목록은 하루 동안 다시 받지 않는다 (1.7MB).
    static let catalogLifetime: TimeInterval = 24 * 60 * 60

    @Published private(set) var entries: [Entry] = [] {
        didSet { targets = Dictionary(uniqueKeysWithValues: entries.map { ($0.slug, HangulSearch.Target($0.slug, $0.displayName)) }) }
    }
    /// 검색용 글. 목록이 바뀔 때 한 번만 만든다 (4천여 개를 글자마다 다시 만들지 않게).
    private var targets: [String: HangulSearch.Target] = [:]
    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var pets: [Pet] = []
    @Published private(set) var installing: Set<String> = []

    private var characters: [String: RunnerCharacter] = [:]
    private var catalogRequest: URLSessionTask?

    private init() {
        load()
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RunTime/Petdex", isDirectory: true)
    }

    private static var catalogURL: URL { directory.appendingPathComponent("manifest.json") }
    private var indexURL: URL { Self.directory.appendingPathComponent("pets.json") }

    static func folder(_ slug: String) -> URL { directory.appendingPathComponent(slug, isDirectory: true) }

    /// 폴더 이름으로 쓰므로 영문 소문자·숫자·하이픈만 받는다.
    static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= 80 && slug.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    // MARK: 선택

    static func storageID(_ slug: String) -> String { "petdex:\(slug)" }

    func pet(storageID: String?) -> Pet? {
        guard let storageID, storageID.hasPrefix("petdex:") else { return nil }
        let slug = storageID.dropFirst("petdex:".count)
        return pets.first { $0.slug == slug }
    }

    func character(for pet: Pet) -> RunnerCharacter? {
        if let cached = characters[pet.slug] { return cached }
        guard let rig = SheetRig(folder: Self.folder(pet.slug)) else { return nil }
        let character = RunnerCharacter(key: "petdex.\(pet.slug)", name: pet.name, sound: pet.name,
                                        rig: FittedRig(rig), assetPrefix: nil, fixedTheme: .natural)
        characters[pet.slug] = character
        return character
    }

    func isInstalled(_ slug: String) -> Bool { pets.contains { $0.slug == slug } }

    // MARK: 목록

    func loadCatalog(force: Bool = false) {
        if catalogRequest != nil { return }
        let cached = Self.catalogURL
        let age = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if !force, entries.isEmpty, let data = try? Data(contentsOf: cached), let list = Self.decode(data) {
            entries = list
            catalogState = .loaded
        }
        guard force || age > Self.catalogLifetime || entries.isEmpty else { return }
        catalogState = entries.isEmpty ? .loading : catalogState
        var request = URLRequest(url: Self.manifestURL, timeoutInterval: 30)
        request.setValue("RunTime", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let list = data.flatMap(Self.decode)
            DispatchQueue.main.async {
                self.catalogRequest = nil
                if let list, status == 200 {
                    self.entries = list
                    self.catalogState = .loaded
                    try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                    try? data?.write(to: cached)
                } else if self.entries.isEmpty {
                    let reason = error != nil ? "네트워크 오류" : (status == 200 ? "목록 형식이 바뀜" : "HTTP \(status)")
                    self.catalogState = .failed(reason)
                }
            }
        }
        catalogRequest = task
        task.resume()
    }

    /// 항목마다 따로 읽어 깨진 항목만 버린다.
    private static func decode(_ data: Data) -> [Entry]? {
        struct Lenient: Decodable { let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }
        struct Manifest: Decodable { let pets: [Lenient] }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        // slug가 겹치면 검색 사전을 만들다 죽고, 받은 목록을 캐시해 두어 열 때마다 다시 죽는다
        var seen: Set<String> = []
        let list = manifest.pets.compactMap(\.entry).filter { isValidSlug($0.slug) && seen.insert($0.slug).inserted }
        return list.isEmpty ? nil : list
    }

    /// 이름이나 slug에 검색어가 들어간 펫. 한글은 별칭 사전과 소리로도 찾는다 (짱구 → Shin-chan, 나루토 → Naruto).
    /// 검색어가 비어 있으면 종류만 거른다.
    func search(_ query: String, kind: Kind) -> [Entry] {
        let pool = entries.filter { kind == .all || $0.kind == kind.rawValue }
        return HangulSearch.search(query, in: pool) { targets[$0.slug] ?? HangulSearch.Target($0.slug, $0.displayName) }
    }

    // MARK: 내려받기

    /// 시트를 받아 서 있기·달리기·슬픔·기다리기 프레임을 뽑아 둔다. 받기와 자르기는 백그라운드에서 한다.
    func install(_ entry: Entry, completion: @escaping (Result<Pet, Error>) -> Void) {
        guard Self.isValidSlug(entry.slug), let url = URL(string: entry.spritesheetUrl), Self.isPetdexURL(url) else {
            completion(.failure(InstallError.badSource))
            return
        }
        let folder = Self.folder(entry.slug)
        if let existing = pets.first(where: { $0.slug == entry.slug }) {
            if SheetFrames.meta(folder) != nil {
                completion(.success(existing))
                return
            }
            // 실행 중에 폴더가 지워졌으면 다시 받는다
            pets.removeAll { $0.slug == entry.slug }
            characters[entry.slug] = nil
        }
        guard !installing.contains(entry.slug) else {
            completion(.failure(InstallError.inProgress))
            return
        }
        installing.insert(entry.slug)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("RunTime", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            // 풀기와 PNG 저장은 URLSession 콜백 큐를 막지 않게 따로 돌린다
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try Self.extract(data: data, response: response, error: error, to: folder) }
                self.finishInstall(entry, folder: folder, result: result, completion: completion)
            }
        }.resume()
    }

    private static func extract(data: Data?, response: URLResponse?, error: Error?, to folder: URL) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let data, status == 200 else {
            throw InstallError.download(error.map { _ in "네트워크 오류" } ?? "HTTP \(status)")
        }
        // 시트는 보통 1MB 안팎이다. 지나치게 큰 파일은 풀지 않는다
        guard data.count <= 16 << 20, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PetdexAtlas.ExtractError.unsupportedSize
        }
        try? FileManager.default.removeItem(at: folder)
        do {
            try PetdexAtlas.extract(from: source, to: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func finishInstall(_ entry: Entry, folder: URL, result: Result<Void, Error>,
                               completion: @escaping (Result<Pet, Error>) -> Void) {
        DispatchQueue.main.async {
            self.installing.remove(entry.slug)
            switch result {
            case .success:
                let pet = Pet(slug: entry.slug, name: String(entry.displayName.prefix(24)),
                              submittedBy: entry.submittedBy, added: Date())
                SheetFrames.forget(folder)
                self.pets.append(pet)
                self.save()
                completion(.success(pet))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 받은 펫의 이름을 바꾼다. 러너·동료 이름표와 말풍선 소리에 쓰인다.
    func rename(_ pet: Pet, to name: String) {
        guard let index = pets.firstIndex(where: { $0.slug == pet.slug }) else { return }
        pets[index].name = name
        // 캐릭터가 이름을 품고 있어 다음에 다시 만든다
        characters[pet.slug] = nil
        save()
    }

    func delete(_ pet: Pet) {
        let folder = Self.folder(pet.slug)
        try? FileManager.default.removeItem(at: folder)
        SheetFrames.forget(folder)
        characters[pet.slug] = nil
        pets.removeAll { $0.slug == pet.slug }
        save()
    }

    // MARK: 목록 파일

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Pet].self, from: data) else { return }
        // 폴더가 지워진 펫은 버린다
        pets = list.filter { Self.isValidSlug($0.slug) && SheetFrames.meta(Self.folder($0.slug)) != nil }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pets) { try? data.write(to: indexURL) }
    }
}
