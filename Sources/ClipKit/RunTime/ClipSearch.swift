import Foundation

/// 띠의 검색어 맞추기. Pesty처럼 글자 그대로 찾고, 검색어가 자음만이면 초성(ㅋㄹㅂㄷ → 클립보드)으로도 찾는다.
enum ClipSearch {
    /// text와 query는 이미 소문자다 (ClipFilter가 맞춘다).
    static func matches(_ text: String, query: String) -> Bool {
        if text.contains(query) { return true }
        let compact = query.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.unicodeScalars.allSatisfy(isConsonant) else { return false }
        return initials(of: text).contains(compact)
    }

    private static let choseong: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")

    private static func isConsonant(_ scalar: Unicode.Scalar) -> Bool {
        (0x3131...0x314E).contains(scalar.value)
    }

    /// 한글 음절은 초성으로, 자음은 그대로 두고 공백은 뺀다. 다른 글자는 초성 검색이 낱말을 건너뛰어 맞지 않게 '·'로 둔다.
    static func initials(of text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3:
                out.append(choseong[Int(scalar.value - 0xAC00) / 588])
            case 0x3131...0x314E:
                out.unicodeScalars.append(scalar)
            default:
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { out.append("·") }
            }
        }
        return out
    }
}
