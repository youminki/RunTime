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
