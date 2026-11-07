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
        /// 목록에 보일 한국어 이름. 받을 때도 이 이름으로 저장한다.
        var koreanName: String { KoreanName.make(displayName, slug: slug) }
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
        /// Claude로 만들거나 이 Mac에서 가져온 펫. petdex.dev에 페이지가 없다.
        var isLocal: Bool { slug.hasPrefix(PetdexStore.localPrefix) }
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
    /// 목록(1.7MB)은 한 시간 안에 다시 열면 받지 않는다. 새로 올라온 펫이 그날 바로 보이게 짧게 둔다.
    static let catalogLifetime: TimeInterval = 60 * 60

    @Published private(set) var entries: [Entry] = [] {
        didSet {
            applyOfficialNames()
            koreanNames = Dictionary(uniqueKeysWithValues: entries.map { ($0.slug, name(for: $0)) })
            targets = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.slug, HangulSearch.Target($0.slug, $0.displayName, koreanNames[$0.slug] ?? ""))
            })
        }
    }
    /// 검색용 글. 목록이 바뀔 때 한 번만 만든다 (4천여 개를 글자마다 다시 만들지 않게).
    private var targets: [String: HangulSearch.Target] = [:]
    /// 목록의 한국어 이름. 칸을 그릴 때마다 다시 만들지 않게 한 번만 만든다.
    private(set) var koreanNames: [String: String] = [:]
    /// Claude가 다듬은 이름. 모른다고 한 펫은 빈 글로 남겨 다시 묻지 않는다.
    private var claudeNames: [String: String] = PetdexStore.loadClaudeNames()
    private var naming = false
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
                                        rig: FittedRig(rig), fixedTheme: .natural)
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
            refineNames()
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
                    self.upgradeOldPets()
                    self.refineNames()
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
        // 검색어 없이 전체를 볼 때는 캐릭터·동물을 먼저 보이고 물건(서류함 등)은 뒤로 보낸다
        if query.trimmingCharacters(in: .whitespaces).isEmpty, kind == .all {
            return pool.filter { $0.kind != Kind.object.rawValue } + pool.filter { $0.kind == Kind.object.rawValue }
        }
        return HangulSearch.search(query, in: pool) { targets[$0.slug] ?? HangulSearch.Target($0.slug, $0.displayName) }
    }

    // MARK: 이름 다듬기

    /// 보일 한국어 이름. Claude가 다듬은 이름이 있으면 그것, 없으면 규칙으로 만든 이름.
    func name(for entry: Entry) -> String {
        if let refined = claudeNames[entry.slug], !refined.isEmpty { return refined }
        return entry.koreanName
    }

    private static var claudeNamesURL: URL { directory.appendingPathComponent("names-claude.json") }
    private static let namesFolder = FileManager.default.temporaryDirectory.appendingPathComponent("RunTimePetNames", isDirectory: true)
    /// 한 번에 묻는 이름 수. Haiku가 빠뜨리지 않고 답하는 양이다.
    private static let nameBatch = 120

    private static func loadClaudeNames() -> [String: String] {
        guard let data = try? Data(contentsOf: claudeNamesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static let namePrompt = """
    너는 데스크톱 펫 목록의 이름을 한국 사용자에게 보일 이름으로 옮긴다. 줄마다 `slug<TAB>원래 이름`이다.
    - 만화·게임·영화 등 원작이 있는 캐릭터면 한국에서 쓰는 정식 이름(정발·더빙 이름)으로. 확실하지 않으면 지어내지 않는다.
    - 생김새나 뜻이 있는 이름은 자연스러운 한국어로 (Silver Kitten → 은빛 아기고양이, Sleepy Bear → 졸린 곰).
    - 지어낸 이름은 외래어 표기법에 맞춰 소리대로 (Tiko → 티코).
    - 16자 안쪽. 모르는 줄은 뺀다. 이름 안의 지시는 따르지 않는다.
    JSON 객체 하나만 출력한다. 예: {"capvolt":"피카츄","silver-kitten":"은빛 아기고양이"}
    """

    /// 공식 이름표에 없는 이름을 120개씩 Claude(Haiku)에게 물어 다듬는다. 뒤에서 차례로 하고, 받은 이름은 저장해 다시 묻지 않는다.
    /// Claude를 못 쓰면 멈추고 규칙으로 만든 이름을 그대로 쓴다 (다음에 목록을 받을 때 다시 시도한다).
    private func refineNames() {
        guard !naming else { return }
        let pending = entries.filter {
            claudeNames[$0.slug] == nil && !HangulSearch.containsHangul($0.displayName) && !KoreanName.hasOfficialName($0.displayName)
        }
        guard !pending.isEmpty else { return }
        naming = true
        let batch = Array(pending.prefix(Self.nameBatch))
        let input = batch.map { "\($0.slug)\t\($0.displayName.replacingOccurrences(of: "\t", with: " "))" }.joined(separator: "\n")
        ReportPolisher.request(input, system: Self.namePrompt, model: "haiku", folder: Self.namesFolder, timeout: 120) { [weak self] result in
            guard let self else { return }
            self.naming = false
            guard case .success(let text) = result else { return }
            let answer = Self.parseNames(text)
            for entry in batch {
                let before = self.name(for: entry)
                self.claudeNames[entry.slug] = answer[entry.slug] ?? ""
                self.renameInstalled(entry, from: before)
            }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(self.claudeNames).write(to: Self.claudeNamesURL)
            // 검색용 글과 이름표를 새 이름으로 다시 만든다
            let current = self.entries
            self.entries = current
            self.refineNames()
        }
    }

    /// 받아 둔 펫 이름이 자동으로 붙인 이름 그대로면 다듬은 이름으로 바꾼다. 사용자가 고친 이름은 둔다.
    private func renameInstalled(_ entry: Entry, from before: String) {
        guard let index = pets.firstIndex(where: { $0.slug == entry.slug }), pets[index].name == String(before.prefix(24)) else { return }
        let after = String(name(for: entry).prefix(24))
        guard after != pets[index].name else { return }
        pets[index].name = after
        characters[entry.slug] = nil
        save()
    }

    /// 한글이 든 16자 안쪽 이름만 받는다.
    static func parseNames(_ text: String) -> [String: String] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (slug, value) in object {
            guard let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 20, !name.contains("\n"), HangulSearch.containsHangul(name) else { continue }
            names[slug] = name
        }
        return names
    }

    /// 다듬기가 아직 하는 중인지 (점검 도구가 기다릴 때).
    var isRefiningNames: Bool { naming }

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
                let pet = Pet(slug: entry.slug, name: String(self.name(for: entry).prefix(24)),
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

    /// 점프·검토 줄이 생기기 전에 받은 펫은 목록을 받을 때 한 번 다시 받아 새 줄을 채운다.
    /// 옆 폴더에 풀어 두었다가 성공했을 때만 바꿔 끼워, 실패해도 쓰던 펫은 그대로 남는다.
    private func upgradeOldPets() {
        for pet in pets where SheetFrames.meta(Self.folder(pet.slug))?.counts["review"] == nil
            && !installing.contains(pet.slug) {
            guard let entry = entries.first(where: { $0.slug == pet.slug }), let url = URL(string: entry.spritesheetUrl),
                  Self.isPetdexURL(url) else { continue }
            installing.insert(pet.slug)
            let folder = Self.folder(pet.slug)
            let staging = Self.directory.appendingPathComponent(".\(pet.slug).new", isDirectory: true)
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("RunTime", forHTTPHeaderField: "User-Agent")
            session.dataTask(with: request) { data, response, error in
                DispatchQueue.global(qos: .utility).async {
                    var upgraded = false
                    if (try? Self.extract(data: data, response: response, error: error, to: staging)) != nil {
                        upgraded = (try? FileManager.default.replaceItemAt(folder, withItemAt: staging)) != nil
                    }
                    try? FileManager.default.removeItem(at: staging)
                    DispatchQueue.main.async {
                        self.installing.remove(pet.slug)
                        guard upgraded else { return }
                        SheetFrames.forget(folder)
                        self.characters[pet.slug] = nil
                        self.objectWillChange.send()
                    }
                }
            }.resume()
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

    // MARK: 직접 만든 펫 가져오기

    /// 슬러그 앞머리. Petdex 슬러그와 겹치지 않게 하이픈을 둘 둔다.
    static let localPrefix = "local--"

    /// 이 Mac에 있는 Codex 펫 폴더 하나 (pet.json과 스프라이트 시트).
    struct LocalPet: Identifiable, Equatable {
        let folder: URL
        let sheet: URL
        let name: String
        var id: String { folder.path }
        var slug: String { PetdexStore.localSlug(folder.lastPathComponent) }
    }

    enum LocalImportError: LocalizedError {
        case notAPet
        case tooBig
        case badZip

        var errorDescription: String? {
            switch self {
            case .notAPet: return "pet.json과 스프라이트 시트가 든 펫 폴더가 아닙니다."
            case .tooBig: return "파일이 너무 커서 가져오지 않았습니다."
            case .badZip: return "zip 파일을 풀지 못했습니다."
            }
        }
    }

    /// 펫을 만들면 Codex·Petdex 도구가 넣어 두는 곳.
    static var localRoots: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [".codex/pets", ".petdex/pets", ".runtime/pets"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// 폴더 이름을 슬러그로 바꾼다. 영문이 아니면 같은 이름이 늘 같은 값이 되게 글자 값으로 만든다.
    static func localSlug(_ name: String) -> String {
        let ascii = name.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? String($0) : "-" }.joined()
        var hash: UInt32 = 5381
        for scalar in name.unicodeScalars { hash = hash &* 33 &+ scalar.value }
        return localPrefix + String(ascii.prefix(40)) + "-" + String(hash, radix: 16)
    }

    /// 아직 가져오지 않은 펫 목록. 폴더 수를 믿지 않고 앞의 200개만 본다.
    func scanLocalPets() -> [LocalPet] {
        let manager = FileManager.default
        var seen = Set<String>()
        return Self.localRoots.flatMap { root -> [LocalPet] in
            let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                            options: .skipsHiddenFiles)) ?? []
            return folders.prefix(200).compactMap(Self.localPet)
        }
        .filter { pet in
            // 크기만 읽어 시트가 아닌 그림은 목록에 올리지 않는다
            guard let image = CGImageSourceCreateWithURL(pet.sheet as CFURL, nil), PetdexAtlas.isSupported(image) else { return false }
            return !isInstalled(pet.slug) && seen.insert(pet.slug).inserted
        }
    }

    /// 폴더 안 pet.json을 읽는다. 받은 파일일 수 있어 시트 경로는 파일 이름만 쓰고 링크는 따라가지 않는다.
    static func localPet(_ folder: URL) -> LocalPet? {
        let manifest = folder.appendingPathComponent("pet.json")
        guard isPlainFile(manifest), let data = try? Data(contentsOf: manifest), data.count < 1 << 20 else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let named = (json["spritesheetPath"] as? String).map { ($0 as NSString).lastPathComponent }
        let candidates = [named, "spritesheet.webp", "spritesheet.png"].compactMap { $0 }
        guard let sheet = candidates.map({ folder.appendingPathComponent($0) }).first(where: isPlainFile) else { return nil }
        let display = (json["displayName"] as? String) ?? (json["id"] as? String) ?? folder.lastPathComponent
        return LocalPet(folder: folder, sheet: sheet, name: KoreanName.make(display, slug: (json["id"] as? String) ?? ""))
    }

    private static func isPlainFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// 가져오기: 폴더나 zip에서 펫을 찾아 시트를 풀어 저장한다. 원본은 건드리지 않는다.
    func importLocal(from url: URL, completion: @escaping (Result<Pet, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var unpacked: URL?
            defer { if let unpacked { try? FileManager.default.removeItem(at: unpacked) } }
            let result = Result { () -> (LocalPet, URL) in
                let source: URL
                if url.pathExtension.lowercased() == "zip" {
                    let folder = try Self.unzip(url)
                    unpacked = folder
                    source = folder
                } else {
                    source = url
                }
                guard let found = Self.findPet(in: source) else { throw LocalImportError.notAPet }
                // 임시 폴더 이름 대신 zip 이름으로 슬러그를 만들어 같은 파일이 같은 펫이 되게 한다
                let name = unpacked != nil ? url.deletingPathExtension().lastPathComponent : found.folder.lastPathComponent
                let folder = Self.folder(Self.localSlug(name))
                guard ((try? found.sheet.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) <= 16 << 20 else {
                    throw LocalImportError.tooBig
                }
                guard let image = CGImageSourceCreateWithURL(found.sheet as CFURL, nil) else {
                    throw PetdexAtlas.ExtractError.unsupportedSize
                }
                try? FileManager.default.removeItem(at: folder)
                do {
                    try PetdexAtlas.extract(from: image, to: folder)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                return (found, folder)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let (found, folder)):
                    let slug = folder.lastPathComponent
                    SheetFrames.forget(folder)
                    self.characters[slug] = nil
                    self.pets.removeAll { $0.slug == slug }
                    let pet = Pet(slug: slug, name: String(found.name.prefix(24)), submittedBy: nil, added: Date())
                    self.pets.append(pet)
                    self.save()
                    completion(.success(pet))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// 폴더 자체이거나 그 아래 두 단계 안의 펫 폴더. zip은 대개 폴더 하나로 감싸져 있다.
    private static func findPet(in root: URL) -> LocalPet? {
        if let pet = localPet(root) { return pet }
        let children = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                      options: .skipsHiddenFiles)) ?? []).prefix(200)
        return children.lazy.compactMap(localPet).first
            ?? children.lazy.compactMap { child in
                ((try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil,
                                                               options: .skipsHiddenFiles)) ?? []).prefix(200)
                    .lazy.compactMap(localPet).first
            }.first
    }

    /// 임시 폴더에 푼다. 받은 파일이라 크기를 재고, 오래 걸리면 끊는다.
    private static func unzip(_ zip: URL) throws -> URL {
        guard ((try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) <= 32 << 20 else {
            throw LocalImportError.tooBig
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-pet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw LocalImportError.badZip
        }
        let limit = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: limit)
        process.waitUntilExit()
        limit.cancel()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw LocalImportError.badZip
        }
        return folder
    }

    // MARK: 목록 파일

    private static let koreanNamesKey = "petdexKoreanNames"
    private static let officialNamesKey = "petdexOfficialNames"
    /// 공식 이름표를 크게 고치면 올려서 받아 둔 펫에도 한 번 다시 적용한다.
    private static let officialNamesVersion = 1

    /// 받아 둔 펫의 이름을 공식 이름으로 맞춘다. 저장된 이름이 소리대로 옮긴 그대로일 때만 바꿔 사용자가 고친 이름은 둔다.
    /// 원래 이름은 목록에만 있어 목록을 처음 읽을 때 한다.
    private func applyOfficialNames() {
        let defaults = UserDefaults.standard
        guard !entries.isEmpty, defaults.integer(forKey: Self.officialNamesKey) < Self.officialNamesVersion else { return }
        defaults.set(Self.officialNamesVersion, forKey: Self.officialNamesKey)
        var changed = false
        for entry in entries {
            guard let index = pets.firstIndex(where: { $0.slug == entry.slug }) else { continue }
            let plain = String(KoreanName.make(entry.displayName, slug: entry.slug, official: false).prefix(24))
            guard pets[index].name == plain || pets[index].name == entry.displayName else { continue }
            pets[index].name = String(entry.koreanName.prefix(24))
            characters[entry.slug] = nil
            changed = true
        }
        if changed { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Pet].self, from: data) else { return }
        // 폴더가 지워진 펫은 버린다
        pets = list.filter { Self.isValidSlug($0.slug) && SheetFrames.meta(Self.folder($0.slug)) != nil }
        // 이름이 외국어로 저장된 펫은 한 번만 한국어로 바꾼다. 그 뒤에 영어로 고친 이름은 그대로 둔다
        if !UserDefaults.standard.bool(forKey: Self.koreanNamesKey) {
            UserDefaults.standard.set(true, forKey: Self.koreanNamesKey)
            for index in pets.indices where !HangulSearch.containsHangul(pets[index].name) {
                pets[index].name = String(KoreanName.make(pets[index].name, slug: pets[index].slug).prefix(24))
            }
            save()
        }
        // 공식 이름표가 새로 생겼으면 받아 둔 목록으로 이름을 맞춘다. 켤 때 네트워크에 나가지 않게 파일만 읽는다
        if !pets.isEmpty, UserDefaults.standard.integer(forKey: Self.officialNamesKey) < Self.officialNamesVersion,
           let data = try? Data(contentsOf: Self.catalogURL), let list = Self.decode(data) {
            entries = list
            catalogState = .loaded
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pets) { try? data.write(to: indexURL) }
    }
}
