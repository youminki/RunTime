import Foundation

/// Petdex 펫 이름(영어·로마자·한자)을 한국어 이름으로 바꾼다. 차례대로 본다.
/// 0. 공식 이름표(KoreanOfficialNames): 사람이 전체 이름을 읽고 고른 정식 이름.
/// 1. 별칭 사전: 짱구(shinchan), 도라에몽(doraemon)처럼 이름이나 slug가 아는 캐릭터면 그 이름.
/// 2. 한자: 병음으로 읽어 외래어 표기법의 중국어 표로 적는다 (肉包 → 러우바오).
/// 3. 로마자 낱말: 병음이면 중국어 표로, 한국 이름 로마자(hyein)면 한글로 되돌리고, 나머지는 영어 소리대로 적는다.
///    흔한 낱말(cat, pig, pixel 등)은 뜻이나 굳은 표기로 바꾼다.
/// 바꿀 수 없으면 원래 이름을 돌려준다.
public enum KoreanName {
    /// `official`을 끄면 이름표 없이 소리대로만 적는다. 저장된 이름이 사용자가 고친 것인지 가릴 때 쓴다.
    /// 사람이 고른 공식 이름표에 있는 이름인지. 없으면 소리대로 옮긴 이름이라 다듬을 여지가 있다.
    public static func hasOfficialName(_ name: String) -> Bool {
        KoreanOfficialNames.table[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil
    }

    public static func make(_ name: String, slug: String = "", official: Bool = true) -> String {
        // 눈에 안 보이는 글자가 붙어 올라온 이름이 있다 (Pikachu + U+200C)
        let visible = String(String.UnicodeScalarView(name.unicodeScalars.filter { !(0x200B...0x200D).contains($0.value) && $0.value != 0xFEFF }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        // 공식 이름표가 먼저다 (Patrick Star → 뚱이, 卡比兽 → 잠만보)
        if official, let found = KoreanOfficialNames.table[trimmed.lowercased()] { return found }
        // 이미 한글 이름이면 그대로 둔다
        if HangulSearch.containsHangul(trimmed) { return trimmed }
        // 이름 전체나 slug가 아는 캐릭터인지 본다 (shinchan-5 → 짱구)
        let slugWords = slug.lowercased().split(separator: "-").filter { Int($0) == nil }.joined(separator: " ")
        for key in [normalized(trimmed), slugWords, slugWords.replacingOccurrences(of: " ", with: "")] where !key.isEmpty {
            if let known = reverse[key] { return known }
        }
        // 한자 이름 안에 아는 이름이 있으면 그 이름만 쓴다 (超级赛亚人孙悟空 → 표, 炭治郎 Q版 → 표)
        if official {
            for token in tokens(trimmed) {
                if case .han(let text) = token, let found = KoreanOfficialNames.table[text.lowercased()] { return found }
            }
        }
        var found = tokens(trimmed)
        // 한 글자 약어(Q版)는 이름으로 치지 않는다
        let hasWord = found.contains { if case .word(let text) = $0 { text.count >= 3 } else { false } }
        let hasHan = found.contains { if case .han = $0 { true } else { false } }
        if hasHan {
            if hasWord {
                // 로마자와 한자가 같이 있으면 한자는 대개 같은 이름의 번역이다 (贝拉Kira)
                found.removeAll { if case .han = $0 { true } else { false } }
            } else if isMeaningful(slugWords), slugWords.replacingOccurrences(of: " ", with: "") != hanReading(trimmed) {
                // 한자만 있으면 영어 slug가 원래 이름인 경우가 많다 (不知火舞 → mai-shiranui).
                // slug가 한자를 병음으로 읽은 것이면 중국어 표로 적는다 (肉包 → roubao → 러우바오)
                found = slugWords.split(separator: " ").map { .word(String($0)) }
            }
        }
        var parts: [String] = []
        for token in found {
            switch token {
            case .han(let text):
                parts.append(pinyinToHangul(latin(text)))
            case .word(let text):
                parts.append(word(text, official: official))
            case .other(let text):
                parts.append(text)
            }
        }
        let result = parts.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return HangulSearch.containsHangul(result) ? result : trimmed
    }

    private static func hanReading(_ text: String) -> String {
        tokens(text).compactMap { if case .han(let han) = $0 { latin(han) } else { nil } }
            .joined().replacingOccurrences(of: " ", with: "")
    }

    /// 올린 도구가 자동으로 붙인 slug(spritesheet-47)는 이름이 아니다.
    private static func isMeaningful(_ slugWords: String) -> Bool {
        !slugWords.isEmpty && !slugWords.contains("spritesheet") && !slugWords.contains("sprite")
    }

    // MARK: 나누기

    private enum Token {
        case han(String)
        case word(String)
        case other(String)
    }

    /// 한자 덩어리, 로마자 낱말(낙타 표기는 나눔: StarByte → Star, Byte), 숫자로 나눈다. 기호는 버린다.
    private static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var current = ""
        var kind = 0   // 0 없음, 1 한자, 2 로마자, 3 숫자
        func flush() {
            guard !current.isEmpty else { return }
            switch kind {
            case 1: out.append(.han(current))
            case 2: out.append(.word(current))
            default: out.append(.other(current))
            }
            current = ""
        }
        for ch in text {
            let next: Int
            if ch.unicodeScalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) }) {
                next = 1
            } else if ch.isASCII && ch.isLetter {
                next = 2
            } else if ch.isNumber {
                next = 3
            } else {
                flush()
                kind = 0
                continue
            }
            // 소문자 뒤 대문자는 새 낱말 (StarByte). 다 대문자인 약어(QQ)는 그대로 둔다
            if next == 2, kind == 2, ch.isUppercase, let last = current.last, last.isLowercase { flush() }
            if next != kind { flush() }
            kind = next
            current.append(ch)
        }
        flush()
        return out
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    private static func latin(_ text: String) -> String {
        (text.applyingTransform(.toLatin, reverse: false) ?? text)
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? text
    }

    // MARK: 사전

    /// 영어 낱말 → 한국어. 손으로 고른 표(앞쪽 이름이 대표)가 Wikidata 표보다 먼저고,
    /// 한 낱말이 여러 표에 있으면 낱말이 적은(더 구체적인) 표를 쓴다 (shiba → 시바, 강아지 아님).
    static let reverse: [String: String] = {
        var map: [String: (name: String, specificity: Int)] = [:]
        for (names, values) in KoreanAliases.table {
            let name = String(names.split(separator: "/").first ?? "")
            for value in values where map[value].map({ values.count < $0.specificity }) ?? true {
                map[value] = (name, values.count)
            }
        }
        var result = map.mapValues(\.name)
        // Wikidata 표는 같은 낱말에 이름이 여럿이면 짧은 것을 쓴다
        for (name, values) in KoreanAliases.generated.sorted(by: { $0.key.count > $1.key.count }) {
            for value in values where map[value] == nil { result[value] = name }
        }
        for (word, korean) in common { result[word] = korean }
        return result
    }()

    /// 펫 이름에 자주 나오는 낱말의 굳은 표기.
    private static let common: [String: String] = [
        "pixel": "픽셀", "circuit": "서킷", "star": "스타", "byte": "바이트", "ribbon": "리본", "mini": "미니",
        "baby": "베이비", "little": "리틀", "super": "슈퍼", "cute": "큐트", "chibi": "치비", "pet": "펫", "boy": "보이",
        "girl": "걸", "king": "킹", "queen": "퀸", "prince": "프린스", "princess": "프린세스", "angel": "엔젤",
        "devil": "데빌", "moon": "문", "sun": "선", "sky": "스카이", "cloud": "클라우드", "ice": "아이스", "fire": "파이어",
        "water": "워터", "rose": "로즈", "lily": "릴리", "cherry": "체리", "candy": "캔디", "sugar": "슈거",
        "honey": "허니", "cookie": "쿠키", "cake": "케이크", "milk": "밀크", "coffee": "커피", "tea": "티",
        "mochi": "모찌", "bubble": "버블", "happy": "해피", "lucky": "럭키", "magic": "매직", "dream": "드림",
        "night": "나이트", "light": "라이트", "dark": "다크", "blue": "블루", "red": "레드", "pink": "핑크",
        "green": "그린", "gold": "골드", "silver": "실버", "ninja": "닌자", "knight": "나이트", "mecha": "메카",
        "cyber": "사이버", "neon": "네온", "space": "스페이스", "astro": "아스트로", "the": "더", "of": "오브",
        "and": "앤드", "mr": "미스터", "ms": "미즈", "chan": "짱", "kun": "군", "san": "상", "sama": "사마",
        "bot": "봇", "doll": "돌", "plush": "플러시", "jelly": "젤리", "berry": "베리", "lemon": "레몬",
        "peach": "피치", "apple": "애플", "banana": "바나나", "potato": "포테이토", "tofu": "토푸", "sushi": "스시",
        "pudding": "푸딩", "cream": "크림", "choco": "초코", "chocolate": "초콜릿", "latte": "라테", "boba": "보바",
    ]

    /// 대문자 약어는 글자 이름으로 읽는다 (QQ → 큐큐).
    private static let letters: [Character: String] = [
        "a": "에이", "b": "비", "c": "시", "d": "디", "e": "이", "f": "에프", "g": "지", "h": "에이치", "i": "아이",
        "j": "제이", "k": "케이", "l": "엘", "m": "엠", "n": "엔", "o": "오", "p": "피", "q": "큐", "r": "알", "s": "에스",
        "t": "티", "u": "유", "v": "브이", "w": "더블유", "x": "엑스", "y": "와이", "z": "지",
    ]

    // MARK: 로마자 낱말

    private static func word(_ original: String, official: Bool) -> String {
        let word = original.lowercased()
        // 낱말 하나만 맞을 때는 짧은 이름만 쓴다 (Hal Cat이 HAL 9000 캣이 되면 안 된다)
        if official, let found = KoreanOfficialNames.table[word], word.count >= 3, !found.contains(" "), found.allSatisfy({ !$0.isASCII }) {
            return found
        }
        if let known = reverse[word] { return known }
        if original.count == 1 || (original.count <= 3 && original == original.uppercased()) {
            return word.map { letters[$0] ?? "" }.joined()
        }
        if let pinyin = pinyinWord(word) { return pinyin }
        if let korean = koreanRomanization(word) { return korean }
        return english(word)
    }

    /// 한국 이름을 로마자로 적은 낱말인지 (hyein → 혜인, sakura → 사쿠라). 영어 낱말을 로마자로 읽으면
    /// 받침에 ㅌ·ㅅ 같은 어색한 소리가 끼거나 낱자가 남아 걸러진다.
    private static func koreanRomanization(_ word: String) -> String? {
        // 끝의 '모음+자음+e'는 영어 낱말이다 (pipe, game)
        let tail = Array(word.suffix(3))
        if tail.count == 3, tail[2] == "e", vowels.contains(tail[0]), !vowels.contains(tail[1]) { return nil }
        guard word.count <= 8, word.allSatisfy({ !"fqvxz".contains($0) }),
              let hangul = word.applyingTransform(StringTransform(rawValue: "Latin-Hangul"), reverse: false)
        else { return nil }
        // 한글을 다시 로마자로 읽어 그대로 돌아와야 한다 (jill → 질르 → jilleu는 아님)
        let back = hangul.applyingTransform(StringTransform(rawValue: "Latin-Hangul"), reverse: true)?.lowercased()
        guard back == word else { return nil }
        let allowed: Set<Int> = [0, 1, 4, 8, 16, 21]   // 받침 없음, ㄱ, ㄴ, ㄹ, ㅁ, ㅇ
        let syllables = hangul.unicodeScalars.map(\.value)
        guard (2...4).contains(syllables.count),
              syllables.allSatisfy({ (0xAC00...0xD7A3).contains($0) && allowed.contains(Int($0 - 0xAC00) % 28) })
        else { return nil }
        return hangul
    }

    // MARK: 병음

    private static let pinyinInitials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
                                         "j", "q", "x", "r", "z", "c", "s", "y", "w"]
    /// 운모 → 한글 (초성 없이). 외래어 표기법 중국어 표를 따른다.
    private static let pinyinFinals: [String: String] = [
        "a": "아", "o": "오", "e": "어", "i": "이", "u": "우", "v": "위", "ai": "아이", "ei": "에이", "ao": "아오",
        "ou": "어우", "an": "안", "en": "언", "ang": "앙", "eng": "엉", "ong": "웅", "er": "얼", "ia": "야", "ie": "예",
        "iao": "야오", "iu": "유", "ian": "옌", "in": "인", "iang": "양", "ing": "잉", "iong": "융", "ua": "와",
        "uo": "워", "uai": "와이", "ui": "웨이", "uan": "완", "un": "운", "uang": "왕", "ve": "웨", "ue": "웨",
        "van": "위안", "vn": "윈",
    ]
    private static let initialJamo: [String: Int] = [
        "b": 7, "p": 17, "m": 6, "f": 17, "d": 3, "t": 16, "n": 2, "l": 5, "g": 0, "k": 15, "h": 18, "j": 12,
        "q": 14, "x": 9, "zh": 12, "ch": 14, "sh": 9, "r": 5, "z": 13, "c": 14, "s": 10,
    ]

    /// 'x·q·zh'가 있는 낱말을 병음 음절로 끝까지 나눌 수 있으면 한글로 적는다 (xiwei → 시웨이).
    private static func pinyinWord(_ word: String) -> String? {
        guard word.contains("x") || word.contains("q") || word.contains("zh") else { return nil }
        guard let syllables = splitPinyin(word) else { return nil }
        return syllables.map(pinyinSyllable).joined()
    }

    private static func pinyinToHangul(_ text: String) -> String {
        // 가나는 로마자로 읽혀 병음이 아니면 소리대로 적는다
        text.split(separator: " ").map { syllable in
            splitPinyin(String(syllable))?.map(pinyinSyllable).joined() ?? english(String(syllable))
        }.joined()
    }

    private static func splitPinyin(_ word: String) -> [(String, String)]? {
        if word.isEmpty { return [] }
        let initial = pinyinInitials.first { word.hasPrefix($0) } ?? ""
        let rest = word.dropFirst(initial.count)
        // 긴 운모부터 맞춰 본다
        for length in stride(from: min(4, rest.count), through: 1, by: -1) {
            var final = String(rest.prefix(length))
            if ["j", "q", "x", "y"].contains(initial), final.hasPrefix("u") { final = "v" + final.dropFirst() }
            guard pinyinFinals[final] != nil || (initial == "y" || initial == "w") else { continue }
            if let tail = splitPinyin(String(rest.dropFirst(length))) { return [(initial, final)] + tail }
        }
        return nil
    }

    private static func pinyinSyllable(_ part: (String, String)) -> String {
        var (initial, final) = part
        // y·w는 운모의 앞소리다 (ya = ia, wo = uo)
        if initial == "y" {
            initial = ""
            final = final.hasPrefix("i") || final.hasPrefix("v") ? final : "i" + final
            if final == "iu" { final = "iou" }
            if final == "iou" { final = "iu" }
        } else if initial == "w" {
            initial = ""
            final = final.hasPrefix("u") ? final : "u" + final
            if final == "uei" { final = "ui" }
            if final == "uen" { final = "un" }
        }
        // zi·ci·si는 '으', zhi·chi·shi·ri도 '으'로 읽는다
        if final == "i", ["z", "c", "s", "zh", "ch", "sh", "r"].contains(initial) {
            return compose(initialJamo[initial] ?? 11, 18, 0)
        }
        guard var korean = pinyinFinals[final] else { return "" }
        guard let jamo = initialJamo[initial] else { return korean }
        // 첫 음절의 초성 ㅇ을 성모로 바꾼다. ㅈ·ㅉ·ㅊ 뒤 'ㅑ·ㅖ·ㅛ·ㅠ'는 'ㅏ·ㅔ·ㅗ·ㅜ'로 적는다
        var scalars = Array(korean.unicodeScalars)
        let index = Int(scalars[0].value - 0xAC00)
        var medial = (index % 588) / 28
        let finalJamo = index % 28
        if [12, 13, 14].contains(jamo) { medial = [2: 0, 7: 5, 12: 8, 17: 13][medial] ?? medial }
        scalars[0] = Unicode.Scalar(UInt32(0xAC00 + (jamo * 21 + medial) * 28 + finalJamo))!
        korean = String(String.UnicodeScalarView(scalars))
        return korean
    }

    // MARK: 영어

    private enum Sound: Equatable {
        case consonant(String)
        case glide(String)          // y, w
        case vowel([Int])           // 중성 번호 하나나 둘 (ei → ㅔ, ㅣ)
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// 영어 낱말을 소리대로 적는다. 외래어 표기법을 단순하게 따른 규칙이라 정확하지 않을 수 있다.
    static func english(_ word: String) -> String {
        var letters = Array(word)
        // 끝의 '모음+자음+e'는 긴 모음 (byte → bait, meme → mim)
        var longVowel: Int?
        if letters.count >= 4, letters.last == "e", !vowels.contains(letters[letters.count - 2]),
           vowels.contains(letters[letters.count - 3]) || letters[letters.count - 3] == "y",
           !vowels.contains(letters[letters.count - 4]) {
            longVowel = letters.count - 3
            letters.removeLast()
        }
        // 끝의 '자음+le'는 e를 읽지 않는다 (marble → 마블)
        if letters.count >= 4, letters.suffix(2) == ["l", "e"], !vowels.contains(letters[letters.count - 3]) {
            letters.removeLast()
        }
        var sounds: [Sound] = []
        var i = 0
        func at(_ k: Int) -> Character? { k < letters.count ? letters[k] : nil }
        func isVowelAt(_ k: Int) -> Bool { at(k).map { vowels.contains($0) || $0 == "y" } ?? false }
        while i < letters.count {
            let c = letters[i], pair = at(i + 1).map { String([c, $0]) } ?? ""
            if i == longVowel {
                let long: [Character: [Int]] = ["a": [5, 20], "e": [20], "i": [0, 20], "y": [0, 20], "o": [8], "u": [17]]
                sounds.append(.vowel(long[c] ?? [20]))
                i += 1
                continue
            }
            if (c == "y" || c == "w") && at(i + 1).map({ vowels.contains($0) }) == true {
                sounds.append(.glide(String(c)))
                i += 1
                continue
            }
            if vowels.contains(c) || (c == "y" && i > 0) {
                let groups: [(String, [Int])] = [("ee", [20]), ("ea", [20]), ("ie", [20]), ("oo", [13]), ("ou", [0, 13]),
                                                 ("ai", [5, 20]), ("ay", [5, 20]), ("ei", [5, 20]), ("ey", [5, 20]),
                                                 ("oa", [8]), ("au", [0, 13]), ("aw", [8]), ("oi", [8, 20]),
                                                 ("oy", [8, 20]), ("ue", [13]), ("ow", [8])]
                if let group = groups.first(where: { $0.0 == pair }) {
                    sounds.append(.vowel(group.1))
                    i += 2
                    continue
                }
                let single: [Character: Int] = ["a": 0, "e": 5, "i": 20, "o": 8, "u": 13, "y": 20]
                // 끝의 'er'은 '어'
                if c == "e", at(i + 1) == "r", !isVowelAt(i + 2) {
                    sounds.append(.vowel([4]))
                    i += 2
                    continue
                }
                sounds.append(.vowel([single[c] ?? 20]))
                i += 1
                continue
            }
            let digraphs: [String: [Sound]] = ["sh": [.consonant("sh")], "ch": [.consonant("ch")], "th": [.consonant("s")],
                                               "ph": [.consonant("p")], "ck": [.consonant("k")], "ng": [.consonant("ng")],
                                               "qu": [.consonant("k"), .glide("w")], "wh": [.glide("w")], "gh": []]
            if let mapped = digraphs[pair] {
                sounds += mapped
                i += 2
                continue
            }
            // 같은 자음이 겹치면 하나로 (모음 사이 l은 아래에서 ㄹㄹ로 적는다)
            if at(i + 1) == c {
                i += 1
                continue
            }
            switch c {
            case "x": sounds += [.consonant("k"), .consonant("s")]
            case "c": sounds.append(.consonant(at(i + 1).map { "eiy".contains($0) } == true ? "s" : "k"))
            case "q": sounds.append(.consonant("k"))
            case "r" where !isVowelAt(i + 1): break      // 모음 뒤 r은 읽지 않는다 (star → 스타)
            case "h" where !isVowelAt(i + 1): break
            case "w", "y": sounds.append(.vowel([13]))
            default: sounds.append(.consonant(String(c)))
            }
            i += 1
        }
        return syllables(sounds)
    }

    private static let consonantJamo: [String: Int] = [
        "g": 0, "k": 15, "n": 2, "d": 3, "l": 5, "r": 5, "m": 6, "b": 7, "v": 7, "p": 17, "f": 17, "s": 9, "sh": 9,
        "j": 12, "z": 12, "ch": 14, "t": 16, "h": 18, "ng": 11,
    ]
    /// 받침으로 쓰는 소리 (짧은 모음 뒤 k·p는 ㄱ·ㅂ 받침).
    private static let finalJamo: [String: Int] = ["n": 4, "m": 16, "ng": 21, "l": 8, "k": 1, "p": 17]

    private static func syllables(_ sounds: [Sound]) -> String {
        var out: [(initial: Int, medial: Int, final: Int)] = []
        var pending: [Sound] = []
        func standalone(_ sound: Sound, atEnd: Bool = false) {
            guard case .consonant(let c) = sound, let jamo = consonantJamo[c] else { return }
            // 받침이 없는 앞 음절에 받침으로 붙일 수 있으면 붙인다. k·p는 낱말 끝에서만 (sprout → 스프라우트)
            if let last = out.last, last.final == 0, let final = finalJamo[c], atEnd || !["k", "p"].contains(c) {
                out[out.count - 1].final = final
                return
            }
            let medial = ["sh", "ch", "j"].contains(c) ? 20 : 18   // 시·치·지, 나머지는 '으'
            out.append((c == "ng" ? 11 : jamo, medial, 0))
        }
        for sound in sounds {
            guard case .vowel(let medials) = sound else {
                pending.append(sound)
                continue
            }
            var glide: String?
            if case .glide(let g) = pending.last {
                glide = g
                pending.removeLast()
            }
            var initial = 11
            // sw·tw는 자음을 따로 읽는다 (sweet → 스위트). qu만 붙인다 (queen → 퀸)
            if glide == "w", case .consonant(let c) = pending.last, c != "k" {
                pending.removeLast()
                out.append((consonantJamo[c] ?? 11, 18, 0))
            }
            if case .consonant(let c) = pending.last {
                pending.removeLast()
                initial = consonantJamo[c] ?? 11
                if c == "sh", glide == nil { glide = "y" }
                pending.forEach { standalone($0) }
                pending.removeAll()
                // 모음 사이 l과 자음 뒤 l은 앞에 ㄹ을 받친다 (lily → 릴리, block → 블록)
                if c == "l", let last = out.last, last.final == 0 { out[out.count - 1].final = 8 }
            }
            pending.forEach { standalone($0) }
            pending.removeAll()
            var first = medials[0]
            if glide == "y" { first = [0: 2, 5: 7, 8: 12, 13: 17, 4: 6][first] ?? first }
            if glide == "w" { first = [0: 9, 5: 15, 20: 16, 8: 14, 4: 14][first] ?? first }
            out.append((initial, first, 0))
            for extra in medials.dropFirst() { out.append((11, extra, 0)) }
        }
        for sound in pending { standalone(sound, atEnd: true) }
        return out.map { compose($0.initial, $0.medial, $0.final) }.joined()
    }

    private static func compose(_ initial: Int, _ medial: Int, _ final: Int) -> String {
        String(Unicode.Scalar(UInt32(0xAC00 + (initial * 21 + medial) * 28 + final))!)
    }
}
