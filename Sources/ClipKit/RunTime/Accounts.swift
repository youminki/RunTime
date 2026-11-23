import AppKit
import Combine

/// 띠의 계정 탭에 두는 로그인 정보. 비밀번호는 기록 파일에 두지 않고 키체인(ClipSecrets)에만 둔다.
struct Account: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var username: String
    /// 사이트 주소나 이름. 창 제목과 맞춰 이 창에 맞는 계정을 앞에 둔다.
    var site: String
    /// 앱에서 쓰는 계정이면 그 앱. 브라우저는 사이트가 여럿이라 창 제목으로만 맞춘다.
    var appBundleID: String?
    /// 넣은 뒤 ↩까지 눌러 로그인한다.
    var submit: Bool
    var createdAt: Date
    var lastUsed: Date?

    init(id: UUID = UUID(), title: String, username: String, site: String = "", appBundleID: String? = nil,
         submit: Bool = false, createdAt: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.title = title
        self.username = username
        self.site = site
        self.appBundleID = appBundleID
        self.submit = submit
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }

    var searchableText: String { [title, username, site].joined(separator: " ").lowercased() }
}

/// 비밀번호를 두는 곳. RunTime이 키체인으로 바꿔 끼운다. 점검·화면 찍기·테스트는 메모리에만 둔다.
public struct ClipSecrets {
    public var read: (String) -> String?
    public var write: (String, String) -> Bool
    public var delete: (String) -> Void

    public init(read: @escaping (String) -> String?, write: @escaping (String, String) -> Bool, delete: @escaping (String) -> Void) {
        self.read = read
        self.write = write
        self.delete = delete
    }

    public static func memory() -> ClipSecrets {
        // 자동 저장은 뒤 큐에서 쓴다. 메모리 저장소도 여러 스레드에서 읽고 쓸 수 있게 잠근다
        final class Box: @unchecked Sendable {
            private var values: [String: String] = [:]
            private let lock = NSLock()
            func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
            func set(_ key: String, _ value: String?) { lock.lock(); values[key] = value; lock.unlock() }
        }
        let box = Box()
        return ClipSecrets(read: { box.get($0) }, write: { box.set($1, $0); return true }, delete: { box.set($0, nil) })
    }
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore(folder: ClipboardStore.localBase)

    @Published private(set) var accounts: [Account] = []
    private let url: URL

    init(folder: URL) {
        url = folder.appendingPathComponent("accounts.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = list
        }
    }

    private var secrets: ClipSecrets { ClipRuntime.secrets }

    /// 사이트 주소와 아이디가 똑같은 계정이 있으면 replacing일 때만 비밀번호를 바꾸고, 아니면 따로 만든다.
    /// 복사해서 저절로 저장할 때는 바꾸지 않는다. 비슷한 사이트(dev·prod)의 비밀번호를 말없이 덮어쓰면 되찾을 수 없다.
    /// 키체인에 쓰지 못하면 nil.
    @discardableResult
    func save(title: String, username: String, password: String, site: String = "", appBundleID: String? = nil,
              submit: Bool = false, replacing: Bool = true) -> Account? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { return nil }
        if let existing = duplicate(username: username, site: site) {
            if secrets.read(existing.id.uuidString) == password { return existing }
            if replacing {
                guard secrets.write(password, existing.id.uuidString) else { return nil }
                return existing
            }
        }
        let account = Account(title: title.isEmpty ? (CredentialParser.host(of: site) ?? site) : title,
                              username: username, site: site, appBundleID: appBundleID, submit: submit)
        guard secrets.write(password, account.id.uuidString) else { return nil }
        accounts.insert(account, at: 0)
        persist()
        return account
    }

    private static let keychainQueue = DispatchQueue(label: "RunTime.clip.accounts", qos: .userInitiated)

    /// 복사해서 저절로 저장할 때. 키체인 쓰기(security 실행 두 번)는 0.1~0.2초 걸려 클립보드 감시를 멈추지 않게 뒤 큐에서 한다.
    /// 같은 사이트·아이디가 있으면 비밀번호가 같을 때만 그 계정을 넘기고, 다르면 덮어쓰지 않고 새로 만든다.
    func saveInBackground(title: String, username: String, password: String, site: String,
                          completion: @escaping @MainActor (Account?) -> Void) {
        guard !password.isEmpty else { completion(nil); return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = duplicate(username: username, site: site)
        let candidate = Account(title: trimmedTitle.isEmpty ? (CredentialParser.host(of: site) ?? site) : trimmedTitle,
                                username: username, site: site)
        let secrets = UncheckedSendable(value: self.secrets)
        Self.keychainQueue.async {
            let same = existing.map { secrets.value.read($0.id.uuidString) == password } ?? false
            let written = same || secrets.value.write(password, candidate.id.uuidString)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if same { completion(existing); return }
                    guard written else { completion(nil); return }
                    self.accounts.insert(candidate, at: 0)
                    self.persist()
                    completion(candidate)
                }
            }
        }
    }

    /// 비밀번호를 nil로 넘기면 그대로 둔다.
    @discardableResult
    func update(_ account: Account, password: String?) -> Bool {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return false }
        if let password, !password.isEmpty, !secrets.write(password, account.id.uuidString) { return false }
        accounts[i] = account
        persist()
        return true
    }

    func delete(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        secrets.delete(id.uuidString)
        persist()
    }

    func password(for account: Account) -> String? { secrets.read(account.id.uuidString) }

    func markUsed(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].lastUsed = Date()
        persist()
    }

    /// 사이트 주소(www. 뗀 것)와 아이디가 똑같은 계정. 사이트가 비면 같은 것으로 보지 않는다.
    private func duplicate(username: String, site: String) -> Account? {
        guard let key = Self.siteKey(site) else { return nil }
        let user = username.lowercased()
        return accounts.first { $0.username.lowercased() == user && Self.siteKey($0.site) == key }
    }

    private static func siteKey(_ site: String) -> String? {
        let trimmed = site.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let host = CredentialParser.host(of: trimmed) ?? trimmed
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 지금 창에 맞는 계정, 최근에 쓴 계정, 새로 만든 계정 순서. 검색어가 있으면 거른다.
    func ordered(query: String, context: AccountContext?) -> [Account] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = query.isEmpty ? accounts : accounts.filter { ClipSearch.matches($0.searchableText, query: query) }
        return list.sorted { a, b in
            let ma = context?.matches(a) ?? false, mb = context?.matches(b) ?? false
            if ma != mb { return ma }
            let ua = a.lastUsed ?? .distantPast, ub = b.lastUsed ?? .distantPast
            if ua != ub { return ua > ub }
            return a.createdAt > b.createdAt
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 띠를 연 곳(붙여 넣을 앱과 그 창 제목). 이 창에 맞는 계정을 앞에 두고 표시한다.
struct AccountContext: Equatable {
    var bundleID: String?
    var windowTitle: String
    /// 브라우저면 보고 있는 페이지 주소의 host (www. 뗀 것). 읽지 못하면 nil.
    var pageHost: String? = nil

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.naver.Whale", "com.google.Chrome.canary",
    ]

    /// 페이지 주소를 읽었으면 주소로만 맞춘다. 창 제목은 페이지가 마음대로 정해 "Naver 로그인" 같은 가짜 페이지도 맞게 된다.
    func matches(_ account: Account) -> Bool {
        if let app = account.appBundleID, app == bundleID, !Self.browsers.contains(app) { return true }
        if let pageHost {
            guard let site = Self.host(account.site) else { return false }
            return pageHost == site || pageHost.hasSuffix("." + site)
        }
        let title = windowTitle.lowercased()
        guard !title.isEmpty else { return false }
        let words = [CredentialParser.keyword(account.site), CredentialParser.keyword(account.title)].compactMap { $0 }
        return words.contains { title.contains($0) }
    }

    /// "https://www.naver.com/login", "naver.com" → "naver.com". 주소 꼴이 아니면 nil.
    static func host(_ site: String) -> String? {
        let trimmed = site.trimmingCharacters(in: .whitespaces).lowercased()
        if let host = CredentialParser.host(of: trimmed) { return host }
        guard trimmed.contains("."), !trimmed.contains(" "), !trimmed.contains("/") else { return nil }
        return trimmed.hasPrefix("www.") ? String(trimmed.dropFirst(4)) : trimmed
    }
}

/// 계정 설정. 클립보드 설정과 같은 저장소에 둔다.
@MainActor
enum AccountPrefs {
    private static let autoSaveKey = "accountsAutoSave"
    private static let requireAuthKey = "accountsRequireAuth"

    /// 로그인 정보로 보이는 복사는 기록에 두지 않고 계정으로 옮긴다.
    static var autoSave: Bool {
        get { ClipDefaults.store.object(forKey: autoSaveKey) as? Bool ?? true }
        set { ClipDefaults.store.set(newValue, forKey: autoSaveKey) }
    }

    /// 입력·복사·보기 전에 Touch ID(또는 Mac 암호)로 확인한다. 한 번 확인하면 5분 동안은 묻지 않는다.
    static var requireAuth: Bool {
        get { ClipDefaults.store.bool(forKey: requireAuthKey) }
        set { ClipDefaults.store.set(newValue, forKey: requireAuthKey) }
    }
}

/// 뒤 큐로 넘길 때 Sendable이 아닌 값을 감싼다. 키체인 함수는 security를 실행할 뿐 상태를 나누지 않는다.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// 복사한 것이 로그인 정보면 계정으로 옮긴다. 비밀번호를 기록 파일에 평문으로 남기지 않는다.
@MainActor
enum AccountCapture {
    private static let toast = CopyToastController()
    /// 비밀번호로 보이는 클립(이름표 없이 비밀번호 한 줄)을 기록에 두는 시간.
    static let secretLifetime: TimeInterval = 600

    /// 계정으로 옮겼으면 true. 그러면 기록에는 남기지 않는다. 키체인에 쓰지 못하면 기록에 되돌려 놓는다.
    static func absorb(_ item: ClipItem) -> Bool {
        if CardActions.looksSecret(item) {
            // 기록에는 두되 오래 두지 않는다
            DispatchQueue.main.asyncAfter(deadline: .now() + secretLifetime + 1) { sweepSecrets() }
            return false
        }
        guard AccountPrefs.autoSave, item.type == .text || item.type == .richText,
              let text = item.text, let found = CredentialParser.parse(text) else { return false }
        let title = CredentialParser.host(of: found.site) ?? (found.site.isEmpty ? (item.sourceAppName ?? "") : found.site)
        // 복사한 앱(메신저, 메모)은 그 계정을 쓰는 앱이 아니다. 앱으로 맞추지 않는다
        AccountStore.shared.saveInBackground(title: title, username: found.username, password: found.password, site: found.site) { account in
            guard let account else {
                ClipboardStore.shared.addCaptured(item)
                notify("키체인에 저장하지 못해 기록에 남겼습니다", symbol: "exclamationmark.triangle.fill")
                return
            }
            CaptureUndoToast.shared.show(account: account, item: item)
        }
        return true
    }

    /// 비밀번호로 보이는 클립 가운데 오래된 것을 기록에서 지운다. 고정한 것은 남긴다.
    static func sweepSecrets() {
        let cutoff = Date().addingTimeInterval(-secretLifetime)
        ClipboardStore.shared.removeFromHistory { $0.createdAt < cutoff && CardActions.looksSecret($0) && !Pinned.contains($0) }
    }

    static func notify(_ message: String, symbol: String = "key.fill") {
        toast.show(message: message, symbol: symbol, linger: 2.4)
    }
}
