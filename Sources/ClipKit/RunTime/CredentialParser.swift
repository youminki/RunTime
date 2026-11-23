import Foundation

/// 복사한 글에서 찾은 로그인 정보.
struct Credential: Equatable {
    var username: String
    var password: String
    /// 글에 있던 사이트 주소나 이름. 없으면 빈 문자열.
    var site: String
}

/// 복사한 글이 로그인 정보인지, 비밀번호처럼 보이는지 가린다.
/// "아이디: a / 비번: b"처럼 이름표가 붙은 글과, 아이디 줄 아래 비밀번호 줄만 있는 글을 알아본다.
/// 잘못 알아보면 평범한 글이 기록에서 빠지므로 짧은 글만 보고, 이름표가 없으면 비밀번호다운 값만 받는다.
enum CredentialParser {
    static let maxLength = 400

    private static let userLabels = ["아이디", "id", "user id", "userid", "user", "username", "login", "로그인", "계정", "email", "e-mail", "이메일"]
    private static let passwordLabels = ["비밀번호", "비번", "패스워드", "암호", "password", "passwd", "pass", "pw", "pwd"]
    private static let siteLabels = ["사이트", "주소", "url", "site", "host", "서버"]

    static func parse(_ text: String) -> Credential? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count <= 8 else { return nil }
        // 코드 조각은 로그인 정보로 보지 않는다. 잘못 알아보면 복사한 코드가 기록에서 빠진다
        guard !isCode(text) else { return nil }
        if let labeled = labeled(text) { return labeled }
        return unlabeled(lines)
    }

    /// 이름표 뒤의 값과, 이름표 바로 뒤에 : 이나 = 가 있었는지. 이름표 앞은 글 처음이나 글자가 아닌 것이어야 한다 ("compass"의 pass는 아니다).
    private static func value(after labels: [String], in text: String) -> (value: String, separated: Bool)? {
        let names = labels.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}])(?:\(names))[\"']?\\s*([:=：])?(?:은|는|이|가)?\\s*([^\\s,|;(){}\\[\\]<>\"'`]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 2), in: text) else { continue }
            let found = String(text[r])
            // "id: a pw: b"에서 아이디 값으로 다음 이름표를 집지 않는다
            if found.hasSuffix(":") || found.count > 128 { continue }
            return (found, match.range(at: 1).location != NSNotFound)
        }
        return nil
    }

    private static func labeled(_ text: String) -> Credential? {
        guard let (raw, separated) = value(after: passwordLabels, in: text) else { return nil }
        let password = unquoted(raw)
        // "Password must be 8 characters" 같은 문장이나 `let password = field.text` 같은 코드에 걸린 것은 버린다.
        // 이름표 바로 뒤에 : 이 있는 글이 아니면 값이 비밀번호다워야 한다
        let plain = separated && isPlausibleValue(password)
        guard plain || looksLikePassword(password) else { return nil }
        var username = value(after: userLabels, in: text).map { unquoted($0.value) } ?? ""
        if username == password { username = "" }
        let site = value(after: siteLabels, in: text)?.value ?? firstHost(in: text) ?? ""
        return Credential(username: username, password: password, site: site)
    }

    private static func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    }

    /// 코드 조각. 개발자는 `password: String` 같은 줄을 자주 복사한다.
    private static func isCode(_ text: String) -> Bool {
        let markers = ["let ", "var ", "const ", "func ", "def ", "=>", "->", "{", "}", "(", ")", "==", "this.", "self.",
                       "#expect", "assert", "--", "`"]
        return markers.contains { text.contains($0) }
    }

    /// 이름표 뒤 값이 비밀번호로 쓸 만한지. 타입 이름, 멤버 접근, 문장 낱말은 아니다.
    private static func isPlausibleValue(_ value: String) -> Bool {
        guard (4...64).contains(value.count), value.rangeOfCharacter(from: CharacterSet(charactersIn: "(){}[]<>\"'`")) == nil else { return false }
        if value.range(of: "^[A-Za-z_]+\\.[A-Za-z_]+", options: .regularExpression) != nil { return false }
        let words: Set<String> = ["string", "str", "int", "null", "nil", "none", "undefined", "true", "false", "required", "optional", "must", "should", "field", "input"]
        return !words.contains(value.lowercased())
    }

    /// 아이디 한 줄과 비밀번호 한 줄. 주소 한 줄은 더 있어도 된다.
    private static func unlabeled(_ lines: [String]) -> Credential? {
        let site = lines.first { host(of: $0) != nil }
        let rest = lines.filter { $0 != site }
        // 숫자로 시작하는 줄은 날짜·버전(2026-11-23T10:00Z, 1.2.3-beta)일 때가 많다
        guard rest.count == 2, isUsername(rest[0]), looksLikePassword(rest[1]), rest[1].first?.isNumber == false else { return nil }
        return Credential(username: rest[0], password: rest[1], site: site.flatMap(host(of:)) ?? "")
    }

    static func isUsername(_ text: String) -> Bool {
        guard (3...64).contains(text.count) else { return false }
        return text.range(of: "^[A-Za-z0-9._%+@-]+$", options: .regularExpression) != nil
    }

    /// 사람이 고른 비밀번호처럼 보이는지. 기록 카드에서 가리고 계정 저장을 권할 때 쓴다.
    /// 커밋 해시·UUID(16진수), 변수 이름, 주소, 경로는 비밀번호로 보지 않는다.
    static func looksLikePassword(_ text: String) -> Bool {
        guard (8...64).contains(text.count), text.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return false }
        if text.contains("://") || text.hasPrefix("www.") || text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("#") { return false }
        // 함수 호출·배열 접근(print(x1), items[0].Name)은 코드다
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "()[]{}<>\"'`")) != nil { return false }
        if text.range(of: "^[0-9a-fA-F-]+$", options: .regularExpression) != nil { return false }
        if text.range(of: "^[^@\\s]+@[^@\\s]+\\.[A-Za-z]{2,}$", options: .regularExpression) != nil { return false }
        let identifiers = ["^[a-z]+(?:[A-Z][a-z0-9]*)+$", "^[A-Z][a-z]+(?:[A-Z][a-z0-9]*)+$", "^[A-Za-z0-9]+(?:[_.-][A-Za-z0-9]+)+$"]
        let hasSymbol = text.contains { !$0.isLetter && !$0.isNumber }
        // 기호가 _ . - 뿐인 이름(my_var.name)은 식별자다. 다른 기호가 섞이면 비밀번호로 본다
        if identifiers.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return false }
        let classes = [text.contains { $0.isLowercase }, text.contains { $0.isUppercase }, text.contains { $0.isNumber }, hasSymbol]
        return classes.filter { $0 }.count >= 3
    }

    static func firstHost(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" }).lazy.compactMap { host(of: String($0)) }.first
    }

    /// "https://www.naver.com/login" → "naver.com". 주소가 아니면 nil.
    static func host(of text: String) -> String? {
        let raw = text.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>\"'"))
        let withScheme = raw.contains("://") ? raw : (raw.hasPrefix("www.") ? "https://" + raw : nil)
        guard let withScheme, let url = URL(string: withScheme), let host = url.host?.lowercased(), host.contains(".") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 창 제목과 맞춰 볼 낱말. "naver.com" → "naver", "accounts.google.com" → "google".
    static func keyword(_ site: String) -> String? {
        let host = host(of: site) ?? (site.contains(".") && !site.contains(" ") ? site.lowercased() : nil)
        if let host {
            let parts = host.split(separator: ".")
            let core = parts.count >= 2 ? String(parts[parts.count - 2]) : host
            // co.kr처럼 두 칸짜리 끝이면 한 칸 더 앞이 이름이다
            if ["co", "or", "go", "ne", "ac", "com"].contains(core), parts.count >= 3 { return String(parts[parts.count - 3]) }
            return core.count >= 3 ? core : nil
        }
        let word = site.trimmingCharacters(in: .whitespaces).lowercased()
        return word.count >= 2 ? word : nil
    }
}
