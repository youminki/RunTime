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

extension ClipSearch {
    /// 카드에서 강조할 곳. 글자 그대로 맞은 곳을 모두, 없으면 초성으로 맞은 글자들을 돌려준다.
    static func ranges(in text: String, query rawQuery: String) -> [Range<String.Index>] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let hit = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
            found.append(hit)
            from = hit.upperBound
        }
        if !found.isEmpty { return found }

        let compact = query.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.unicodeScalars.allSatisfy(isConsonantScalar) else { return [] }
        // initials(of:)와 같은 규칙으로 글자마다 초성 한 자를 만들되, 원문 위치를 함께 둔다
        var letters: [Character] = []
        var spots: [Range<String.Index>] = []
        for index in text.indices {
            let char = text[index]
            guard let scalar = char.unicodeScalars.first,
                  let initial = initials(of: String(scalar)).first else { continue }
            letters.append(initial)
            spots.append(index..<text.index(after: index))
        }
        let needle = Array(compact)
        guard needle.count <= letters.count else { return [] }
        for start in 0...(letters.count - needle.count) where Array(letters[start..<start + needle.count]) == needle {
            return Array(spots[start..<start + needle.count])
        }
        return []
    }

    private static func isConsonantScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3131...0x314E).contains(scalar.value)
    }
}
