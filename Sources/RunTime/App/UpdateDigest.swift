import Foundation

/// 업데이트 커밋 제목을 메뉴바 말풍선에 보일 몇 줄로 줄인다. 커밋 머리말로 나눈 패치노트 줄을 그대로 쓴다.
/// Claude로 다듬지 않는다 (업데이트마다 토큰을 쓰지 않게).
enum UpdateDigest {
    static let limit = 3

    static func make(_ lines: [String]) -> [String] {
        Array((PatchNotes.make(from: lines, limit: limit)?.sections.flatMap(\.items) ?? []).prefix(limit))
    }
}
