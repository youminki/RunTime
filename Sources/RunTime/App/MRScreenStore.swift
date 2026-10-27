import AppKit
import WorkLogCore

/// MR 본문·댓글의 수정 전·후 화면을 GitLab에서 받아 둔다. 레드마인 카드 미리보기와 보내기가 함께 쓴다.
/// GitLab 15에는 업로드 파일 API가 없어 웹 주소(`/<프로젝트>/uploads/…`)를 glab 토큰으로 받는다.
final class MRScreenStore: ObservableObject {
    static let shared = MRScreenStore()

    struct Ref: Hashable {
        let path: String
        let iid: Int
        var key: String { "\(path)!\(iid)" }
    }

    /// 일지 줄이 온 곳. 머지된 MR 줄은 MR 번호를 알고, 머지 전 브랜치 커밋 줄은 그 브랜치로 연 MR을 찾아야 한다.
    enum Origin: Hashable {
        case mr(Ref)
        case branch(path: String, branch: String)
    }

    /// MR별 화면. 받는 중이거나 실패하면 없다.
    @Published private(set) var screens: [Ref: [MRScreens.Screen]] = [:]
    /// 업로드 경로별 그림 (미리보기 썸네일). 원본 데이터는 `data`에 둔다.
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var loading: Set<Origin> = []
    /// 브랜치 → 그 브랜치로 연 MR. MR이 없으면 `noMR`에 둔다.
    @Published private(set) var branchMRs: [Origin: Ref] = [:]

    private var noMR: Set<Origin> = []
    private var data: [String: Data] = [:]
    /// 받지 못한 MR·브랜치는 이 시각까지 다시 받지 않는다. 망이 끊긴 동안 화면을 그릴 때마다 glab을 부르지 않게.
    private var failed: [Ref: Date] = [:]
    private var retryAt: [Origin: Date] = [:]
    private let queue = DispatchQueue(label: "dev.runtime.worklog.screens", qos: .utility)
    private let lock = NSLock()

    /// 일지 줄의 출처들에서 MR·브랜치를 모은다. 한 MR이 여러 일감에 걸치면 일감마다 `#번호`가 붙은 줄이 따로 생기는데,
    /// 화면은 어느 일감 것인지 모르니 MR 대표 줄(번호가 붙지 않은 줄)의 일감에만 붙인다.
    static func origins(_ sources: [String?]) -> [Origin] {
        var seen = Set<Origin>()
        return sources.compactMap { $0 }.compactMap { source -> Origin? in
            if source.hasPrefix("mr:") {
                guard !source.contains("#"), let ref = WorkCapture.mrRef(source) else { return nil }
                return .mr(Ref(path: ref.path, iid: ref.iid))
            }
            // branch:<프로젝트 경로>:<브랜치> (브랜치 이름에는 :가 들어갈 수 없다)
            guard source.hasPrefix("branch:") else { return nil }
            let rest = source.dropFirst("branch:".count)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let path = String(rest[..<colon]), branch = String(rest[rest.index(after: colon)...])
            return path.isEmpty || branch.isEmpty ? nil : .branch(path: path, branch: branch)
        }.filter { seen.insert($0).inserted }
    }

    /// 화면을 찾을 MR. 브랜치는 찾은 뒤에만 안다. 메인 스레드.
    func ref(_ origin: Origin) -> Ref? {
        switch origin {
        case .mr(let ref): return ref
        case .branch: return branchMRs[origin]
        }
    }

    /// 화면을 붙일 MR들. 머지 전 브랜치 줄과 머지된 MR 줄이 한 일감에 함께 있으면 브랜치가 같은 MR로 풀리므로 한 번만 둔다. 메인 스레드.
    func refs(_ origins: [Origin]) -> [Ref] {
        Self.unique(origins.compactMap(ref))
    }

    /// 보내는 큐에서 부른다. `refs`와 같지만 아직 모르는 브랜치는 지금 찾는다.
    func refsForSending(_ origins: [Origin], host: String) -> [Ref] {
        Self.unique(origins.compactMap { refForSending($0, host: host) })
    }

    private static func unique(_ refs: [Ref]) -> [Ref] {
        var seen = Set<Ref>()
        return refs.filter { seen.insert($0).inserted }
    }

    /// 아직 받지 않은 MR의 화면을 받는다. 메인 스레드에서 부른다.
    func load(_ origins: [Origin], host: String) {
        let todo = origins.filter { origin in
            guard !loading.contains(origin), !noMR.contains(origin), (retryAt[origin] ?? .distantPast) < Date() else { return false }
            guard let ref = ref(origin) else { return true }
            return screens[ref] == nil && (failed[ref] ?? .distantPast) < Date()
        }
        guard !todo.isEmpty, !host.isEmpty else { return }
        loading.formUnion(todo)
        queue.async { [weak self] in
            guard let self else { return }
            // MR마다 glab 호출과 그림 받기가 1~2초씩 걸려, 한 장씩 차례로 받으면 아래 카드가 오래 기다린다
            DispatchQueue.concurrentPerform(iterations: todo.count) { index in
                let origin = todo[index]
                let resolved = Result { try Self.resolve(origin, host: host) }
                let ref = try? resolved.get()
                let found = ref.flatMap { try? Self.fetchScreens($0, host: host) }
                var images: [String: Data] = [:]
                if let ref {
                    for path in (found ?? []).flatMap(\.images).map(\.path) {
                        if let bytes = self.image(path, ref: ref, host: host) { images[path] = bytes }
                    }
                }
                DispatchQueue.main.async {
                    self.loading.remove(origin)
                    // GitLab에 닿지 못한 것과 MR이 정말 없는 것을 나눠, 앞의 것은 5분 뒤 다시 찾는다
                    guard case .success(let resolvedRef) = resolved else { self.retryAt[origin] = Date().addingTimeInterval(300); return }
                    guard let ref = resolvedRef else { self.noMR.insert(origin); return }
                    if case .branch = origin { self.branchMRs[origin] = ref }
                    guard let found else { self.failed[ref] = Date().addingTimeInterval(300); return }
                    self.screens[ref] = found
                    for (path, bytes) in images { self.thumbnails[path] = NSImage(data: bytes) }
                }
            }
        }
    }

    /// 보내는 큐에서 부른다. 브랜치면 MR을 찾아 둔 것을 쓰고, 없으면 지금 찾는다.
    func refForSending(_ origin: Origin, host: String) -> Ref? {
        if let known = DispatchQueue.main.sync(execute: { ref(origin) }) { return known }
        return (try? Self.resolve(origin, host: host)) ?? nil
    }

    /// 보내는 큐에서 부른다. 미리 받아 둔 것이 있으면 쓰고, 없으면 지금 받는다.
    func screensForSending(_ ref: Ref, host: String) -> [MRScreens.Screen]? {
        if let cached = DispatchQueue.main.sync(execute: { screens[ref] }) { return cached }
        return try? Self.fetchScreens(ref, host: host)
    }

    /// 업로드 경로의 그림 데이터. 받은 적이 있으면 그것을 쓴다.
    func image(_ path: String, ref: Ref, host: String) -> Data? {
        lock.lock()
        let cached = data[path]
        lock.unlock()
        if let cached { return cached }
        guard let url = URL(string: "https://\(host)/\(ref.path)\(path)") else { return nil }
        func fetch(bearer: Bool) -> (Data, URLResponse)? {
            guard let token = Self.token(host: host) else { return nil }
            var request = URLRequest(url: url)
            // 토큰은 주소가 아닌 머리글로 보내 서버 접근 기록에 남지 않게 한다
            if bearer { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            else { request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN") }
            request.timeoutInterval = 30
            return Self.load(request)
        }
        var result = fetch(bearer: false)
        if (result?.1 as? HTTPURLResponse)?.statusCode == 401 {
            // 웹으로 로그인한 glab 토큰은 OAuth라 두 시간쯤 뒤 바뀌고 Bearer로 받아야 한다
            Self.dropToken(host: host)
            result = fetch(bearer: true)
        }
        guard let (bytes, response) = result,
              (response as? HTTPURLResponse)?.statusCode == 200,
              (response.mimeType ?? "").hasPrefix("image/")
        else { return nil }
        lock.lock()
        data[path] = bytes
        lock.unlock()
        return bytes
    }

    /// 받은 그림을 임시 파일로 써서 기본 앱(미리보기)으로 연다.
    func open(_ path: String) {
        lock.lock()
        let bytes = data[path]
        lock.unlock()
        guard let bytes else { return }
        let name = path.split(separator: "/").suffix(2).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RunTime-\(name)")
        guard (try? bytes.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }

    /// 새로 받게 잊는다 (MR에 검증 화면이 새로 달렸을 때). 메인 스레드.
    func forget(_ origins: [Origin]) {
        for origin in origins {
            if let ref = ref(origin) {
                screens[ref] = nil
                failed[ref] = nil
            }
            noMR.remove(origin)
            retryAt[origin] = nil
            if case .branch = origin { branchMRs[origin] = nil }
        }
    }

    // MARK: - GitLab

    /// 브랜치로 연 MR (열린 것과 머지된 것, 가장 최근 것). 닫힌 MR은 화면이 지금 코드와 다를 수 있어 뺀다.
    /// MR이 없으면 nil, GitLab에 묻지 못하면 던진다.
    private static func resolve(_ origin: Origin, host: String) throws -> Ref? {
        switch origin {
        case .mr(let ref):
            return ref
        case .branch(let path, let branch):
            struct MR: Decodable { let iid: Int; let state: String }
            let project = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
            let name = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? branch
            let data = try WorkLogSync.glab(host: host, "projects/\(project)/merge_requests?source_branch=\(name)&state=all")
            guard let mr = try JSONDecoder().decode([MR].self, from: data)
                .filter({ $0.state != "closed" }).max(by: { $0.iid < $1.iid })
            else { return nil }
            return Ref(path: path, iid: mr.iid)
        }
    }

    private static func fetchScreens(_ ref: Ref, host: String) throws -> [MRScreens.Screen] {
        let project = ref.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ref.path
        struct MR: Decodable { let description: String? }
        struct Note: Decodable { let body: String; let system: Bool }
        let mr = try JSONDecoder().decode(MR.self, from: WorkLogSync.glab(host: host, "projects/\(project)/merge_requests/\(ref.iid)"))
        // 댓글이 100개를 넘는 MR도 뒤에 단 검증 화면까지 보게 모든 쪽을 받는다
        let pages = WorkCapture.topLevelJSON(try WorkLogSync.glab(
            host: host, "projects/\(project)/merge_requests/\(ref.iid)/notes?sort=asc&order_by=created_at&per_page=100", paginate: true))
        let notes = try pages.flatMap { try JSONDecoder().decode([Note].self, from: $0) }
        return MRScreens.screens(description: mr.description ?? "", notes: notes.filter { !$0.system }.map(\.body))
    }

    private static var tokens: [String: String] = [:]
    private static let tokenLock = NSLock()

    /// glab에 로그인한 토큰. 앱은 저장하지 않고 필요할 때 glab에서 읽는다.
    private static func token(host: String) -> String? {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        if let cached = tokens[host] { return cached }
        guard let text = try? WorkLogSync.glabText(["config", "get", "token", "--host", host]), !text.isEmpty else { return nil }
        tokens[host] = text
        return text
    }

    private static func dropToken(host: String) {
        tokenLock.lock()
        tokens[host] = nil
        tokenLock.unlock()
    }

    private static func load(_ request: URLRequest) -> (Data, URLResponse)? {
        let semaphore = DispatchSemaphore(value: 0)
        var output: (Data, URLResponse)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response { output = (data, response) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return output
    }
}
