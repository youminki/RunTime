import Foundation
import Testing
@testable import ClipKit

/// 계정은 파일에 이름·아이디만 두고 비밀번호는 ClipSecrets에만 둔다.
@MainActor
@Suite struct AccountStoreTests {
    @Test func passwordNeverReachesTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clip-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        ClipRuntime.secrets = .memory()
        let store = AccountStore(folder: folder)
        let saved = try #require(store.save(title: "네이버", username: "runtime.dev", password: "Abc!2345xyz", site: "naver.com"))
        #expect(store.password(for: saved) == "Abc!2345xyz")

        let file = try String(contentsOf: folder.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(file.contains("runtime.dev"))
        #expect(!file.contains("Abc!2345xyz"))

        // 다시 읽어도 남아 있다
        let reloaded = AccountStore(folder: folder)
        #expect(reloaded.accounts.map(\.username) == ["runtime.dev"])
    }

    @Test func sameSiteAndUserUpdatesPassword() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clip-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        ClipRuntime.secrets = .memory()
        let store = AccountStore(folder: folder)
        let first = try #require(store.save(title: "", username: "kim", password: "Old!pass1", site: "https://www.naver.com"))
        let second = try #require(store.save(title: "네이버", username: "KIM", password: "New!pass2", site: "naver.com"))
        #expect(first.id == second.id)
        #expect(store.accounts.count == 1)
        #expect(store.password(for: first) == "New!pass2")
        #expect(first.title == "naver.com")

        // 저절로 저장할 때는 덮어쓰지 않고, 비슷한 사이트는 다른 계정이다
        let auto = try #require(store.save(title: "", username: "kim", password: "Third!pw3", site: "naver.com", replacing: false))
        #expect(auto.id != first.id && store.password(for: first) == "New!pass2")
        let dev = try #require(store.save(title: "", username: "admin", password: "Dev!2026a", site: "dev.company.com"))
        let prod = try #require(store.save(title: "", username: "admin", password: "Prod!2026b", site: "prod.company.com"))
        #expect(dev.id != prod.id && store.password(for: dev) == "Dev!2026a")
        for account in [auto, dev, prod] { store.delete(account.id) }

        store.delete(first.id)
        #expect(store.accounts.isEmpty)
        #expect(store.password(for: first) == nil)
    }

    @Test func matchingWindowComesFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clip-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        ClipRuntime.secrets = .memory()
        let store = AccountStore(folder: folder)
        store.save(title: "GitHub", username: "a", password: "Gh!secret99", site: "github.com")
        store.save(title: "네이버", username: "b", password: "Nv!secret99", site: "naver.com")
        let context = AccountContext(bundleID: "com.google.Chrome", windowTitle: "GitHub - Sign in")
        #expect(store.ordered(query: "", context: context).first?.title == "GitHub")
        #expect(store.ordered(query: "네이", context: context).map(\.title) == ["네이버"])
        // 브라우저는 앱만 같아서는 맞는 것으로 보지 않는다
        let browserOnly = Account(title: "x", username: "x", appBundleID: "com.google.Chrome")
        #expect(!AccountContext(bundleID: "com.google.Chrome", windowTitle: "").matches(browserOnly))
    }

    @Test func colorStaysWhenRenamed() {
        var account = Account(title: "네이버", username: "kim", site: "naver.com")
        let before = Account.color(for: account)
        account.title = "N"
        account.site = "github.com"
        #expect(Account.color(for: account) == before)
    }

    @Test func browserMatchesByPageAddressNotTitle() {
        let naver = Account(title: "네이버", username: "kim", site: "naver.com")
        // 주소를 읽었으면 주소로만 본다. 제목을 흉내 낸 가짜 페이지는 맞지 않는다
        let phishing = AccountContext(bundleID: "com.google.Chrome", windowTitle: "NAVER 로그인", pageHost: "naver-login.example.com")
        #expect(!phishing.matches(naver))
        #expect(AccountContext(bundleID: "com.google.Chrome", windowTitle: "", pageHost: "nid.naver.com").matches(naver))
        #expect(AccountContext(bundleID: "com.google.Chrome", windowTitle: "", pageHost: "naver.com").matches(naver))
        #expect(!AccountContext(bundleID: "com.google.Chrome", windowTitle: "", pageHost: "notnaver.com").matches(naver))
        // 주소를 못 읽으면 창 제목으로 본다
        #expect(AccountContext(bundleID: "com.google.Chrome", windowTitle: "NAVER 로그인").matches(naver))
        #expect(AccountContext.host("https://www.naver.com/login") == "naver.com")
        #expect(AccountContext.host("사내 메일") == nil)
    }

    @Test func removeFromHistoryLeavesPinned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clip-secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(baseDirectory: directory)
        let secret = ClipItem(type: .text, text: "Xk9#mP2v!Lq7")
        let note = ClipItem(type: .text, text: "회의 3시")
        store.addCaptured(note)
        store.addCaptured(secret)
        let board = store.addPinboard(name: "고정")
        store.saveToPinboard(secret, boardID: board.id)
        store.removeFromHistory { CredentialParser.looksLikePassword($0.text ?? "") }
        #expect(store.history.compactMap(\.text) == ["회의 3시"])
        #expect(store.pinboards.first?.items.count == 1)
    }
}

