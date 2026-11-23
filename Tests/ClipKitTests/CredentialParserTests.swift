import Testing
@testable import ClipKit

/// 복사한 글을 로그인 정보로 알아보는 규칙. 잘못 알아보면 평범한 글이 기록에서 빠지므로 아닌 것도 함께 본다.
@Suite struct CredentialParserTests {
    @Test func labeledKorean() {
        let found = CredentialParser.parse("사이트: https://www.naver.com\n아이디: runtime.dev\n비밀번호: Abc!2345")
        #expect(found == Credential(username: "runtime.dev", password: "Abc!2345", site: "https://www.naver.com"))
    }

    @Test func labeledOneLine() {
        #expect(CredentialParser.parse("id: admin / pw: qwer1234")?.username == "admin")
        #expect(CredentialParser.parse("id: admin / pw: qwer1234")?.password == "qwer1234")
        #expect(CredentialParser.parse("ID=dev01, PASSWORD=Dev#2026") == Credential(username: "dev01", password: "Dev#2026", site: ""))
    }

    @Test func passwordOnlyWithLabel() {
        let found = CredentialParser.parse("와이파이 비밀번호: Guest!0420")
        #expect(found?.password == "Guest!0420")
        #expect(found?.username == "")
    }

    @Test func unlabeledTwoLines() {
        let found = CredentialParser.parse("me@company.co.kr\nPw#77889900")
        #expect(found == Credential(username: "me@company.co.kr", password: "Pw#77889900", site: ""))
        // 주소 한 줄이 더 있어도 된다
        #expect(CredentialParser.parse("https://git.example.com\nkim\nG!t2026lab")?.site == "git.example.com")
    }

    @Test func ordinaryTextIsNotACredential() {
        #expect(CredentialParser.parse("Password must be at least 8 characters long") == nil)
        #expect(CredentialParser.parse("비밀번호 바꾸기 화면을 고쳤습니다") == nil)
        #expect(CredentialParser.parse("hello\nworld") == nil)
        #expect(CredentialParser.parse("let password = field.stringValue") == nil)
        #expect(CredentialParser.parse("    var password: String") == nil)
        #expect(CredentialParser.parse("password: required") == nil)
        // 코드 조각은 값이 비밀번호다워도 받지 않는다 (복사한 코드가 기록에서 빠지면 안 된다)
        #expect(CredentialParser.parse("{\"user\": \"kim\", \"password\": \"Abc!2345xyz\"}") == nil)
        #expect(CredentialParser.parse("db.connect(host=\"localhost\", user=\"root\", password=\"hunter2\")") == nil)
        #expect(CredentialParser.parse("conn = psycopg2.connect(user='app', password='Secr3t')") == nil)
        #expect(CredentialParser.parse("#expect(CredentialParser.parse(\"id: admin / pw: qwer1234\")?.username == \"admin\")") == nil)
        #expect(CredentialParser.parse("kubectl create secret generic db --from-literal=password=S3cr3t!x") == nil)
        #expect(CredentialParser.parse("release\n2026-11-23T10:00Z") == nil)
        #expect(CredentialParser.parse(String(repeating: "id: a pw: b ", count: 60)) == nil)
    }

    @Test func passwordLikeTokens() {
        #expect(CredentialParser.looksLikePassword("Xk9#mP2v!Lq7"))
        #expect(CredentialParser.looksLikePassword("Summer2026!"))
        #expect(!CredentialParser.looksLikePassword("f4be3c0a9d2e1b7c"))
        #expect(!CredentialParser.looksLikePassword("123e4567-e89b-12d3-a456-426614174000"))
        #expect(!CredentialParser.looksLikePassword("getUserName2"))
        #expect(!CredentialParser.looksLikePassword("ClipboardStore"))
        #expect(!CredentialParser.looksLikePassword("my_var.name2"))
        #expect(!CredentialParser.looksLikePassword("https://a.com/X1!"))
        #expect(!CredentialParser.looksLikePassword("me@company.com"))
        #expect(!CredentialParser.looksLikePassword("짧은글"))
        #expect(!CredentialParser.looksLikePassword("print(x1)Ab"))
        #expect(!CredentialParser.looksLikePassword("items[0].Name"))
        #expect(!CredentialParser.looksLikePassword("#FF00aa12"))
    }

    @Test func siteKeywords() {
        #expect(CredentialParser.keyword("https://www.naver.com/login") == "naver")
        #expect(CredentialParser.keyword("accounts.google.com") == "google")
        #expect(CredentialParser.keyword("mail.company.co.kr") == "company")
        #expect(CredentialParser.keyword("사내 메일") == "사내 메일")
    }
}
