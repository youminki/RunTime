import Testing
@testable import ClipKit

@Test func choseongFindsHangulText() {
    #expect(ClipSearch.matches("클립보드 기록", query: "ㅋㄹㅂㄷ"))
    #expect(ClipSearch.matches("클립보드 기록", query: "ㅋㄹㅂㄷ ㄱㄹ"))
    #expect(!ClipSearch.matches("클립보드 기록", query: "ㄱㅋ"))
}

@Test func choseongDoesNotSkipOtherLetters() {
    // 한글이 아닌 글자를 건너뛰면 '클a립'이 ㅋㄹ로 걸린다
    #expect(!ClipSearch.matches("클a립", query: "ㅋㄹ"))
    #expect(ClipSearch.matches("abc 클립", query: "ㅋㄹ"))
}

@Test func plainQueryStillMatchesSubstring() {
    #expect(ClipSearch.matches("hello world", query: "lo w"))
    #expect(ClipSearch.matches("클립보드", query: "립보"))
    #expect(!ClipSearch.matches("hello", query: "ㅎ"))
}

@Test func highlightRangesCoverEveryLiteralMatch() {
    let text = "Clip clip CLIP"
    let hits = ClipSearch.ranges(in: text, query: "clip").map { String(text[$0]) }
    #expect(hits == ["Clip", "clip", "CLIP"])
}

@Test func highlightRangesFollowChoseongAcrossSpaces() {
    let text = "업무 일지: 점검"
    let hits = ClipSearch.ranges(in: text, query: "ㅇㅁ ㅇㅈ").map { String(text[$0]) }
    #expect(hits == ["업", "무", "일", "지"])
    #expect(ClipSearch.ranges(in: "클a립", query: "ㅋㄹ").isEmpty)
    #expect(ClipSearch.ranges(in: "짧", query: "ㅉㅉㅉ").isEmpty)
}

@Test func highlightRangesSurviveInvisibleCharacters() {
    // 웹·슬랙에서 복사한 글에 섞인 폭 없는 공백(U+200B)에서 죽지 않는다
    let text = "클립\u{200B}보드"
    #expect(ClipSearch.matches(text, query: "ㅋㄹ"))
    #expect(ClipSearch.ranges(in: text, query: "ㅋㄹ").map { String(text[$0]) } == ["클", "립"])
}
