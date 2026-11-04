import Foundation

/// 디자인 화면의 찾기 규칙. 띄어 쓴 말은 모두 들어 있어야 하고, 띄어쓰기는 가리지 않는다
/// ("계정관리"로 "계정 관리"를, "목록 계정"으로 "계정 관리 > 목록"을 찾는다).
public enum DesignSearch {
    /// 찾는 말을 낱말로 나눈다. 비었으면 빈 배열.
    public static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 낱말마다 어느 한 칸에 들어 있으면 된다. 띄어쓰기를 뺀 비교는 칸마다 따로 해서 칸 경계를 넘어 맞지 않게 한다.
    public static func matches(_ terms: [String], _ fields: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let lowered = fields.map { $0.lowercased() }
        return terms.allSatisfy { term in
            lowered.contains { $0.contains(term) } || lowered.contains { $0.filter { !$0.isWhitespace }.contains(term) }
        }
    }
}
