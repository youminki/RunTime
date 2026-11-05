import Foundation
import Testing
@testable import WorkLogCore

private func entry(_ title: String) -> WorkEntry {
    WorkEntry(day: "2026-11-03", project: "velox", title: title)
}

/// 앱처럼 제목의 마지막 ` > ` 앞을 경로로 둔다.
private func placement(_ entry: WorkEntry) -> String? {
    guard let range = entry.title.range(of: " > ", options: .backwards) else { return nil }
    return String(entry.title[..<range.lowerBound])
}

/// 머리는 `# 제목 (줄 수)`, 줄은 `- 제목 [묶음 경로]`로 깊이만큼 들여 적는다.
private func outline(_ entries: [WorkEntry], folded: Set<String> = []) -> [String] {
    WorkPathTree.items(entries, placement: placement, isFolded: folded.contains).map { item in
        switch item {
        case .heading(_, let title, let depth, let count):
            return String(repeating: "  ", count: depth) + "# \(title) (\(count))"
        case .row(let entry, let path, let depth):
            return String(repeating: "  ", count: depth) + "- \(entry.title)" + (path.map { " [\($0)]" } ?? "")
        }
    }
}

@Suite struct WorkPathTreeTests {
    @Test func groupsSharedParentsAndKeepsSinglesInside() {
        let lines = outline([
            entry("데이터 탐색 API 연동"),
            entry("데이터 탐색 > SQL 편집기 > 쿼리 실행"),
            entry("데이터 탐색 > SQL 편집기 > 차트 생성"),
            entry("데이터 탐색 > 쿼리 목록 > 쿼리 삭제"),
            entry("데이터 탐색 > BI 대시보드 > 목록"),
            entry("데이터 탐색 > BI 대시보드 > 상세"),
            entry("데이터 수집 > 파이프라인 > 이벤트 연계"),
        ])
        #expect(lines == [
            "- 데이터 탐색 API 연동",
            "# 데이터 탐색 (5)",
            "  # SQL 편집기 (2)",
            "    - 데이터 탐색 > SQL 편집기 > 쿼리 실행 [데이터 탐색 > SQL 편집기]",
            "    - 데이터 탐색 > SQL 편집기 > 차트 생성 [데이터 탐색 > SQL 편집기]",
            "  - 데이터 탐색 > 쿼리 목록 > 쿼리 삭제 [데이터 탐색]",
            "  # BI 대시보드 (2)",
            "    - 데이터 탐색 > BI 대시보드 > 목록 [데이터 탐색 > BI 대시보드]",
            "    - 데이터 탐색 > BI 대시보드 > 상세 [데이터 탐색 > BI 대시보드]",
            "- 데이터 수집 > 파이프라인 > 이벤트 연계",
        ])
    }

    @Test func mergesSingleChildChainIntoOneHeading() {
        let lines = outline([
            entry("데이터 탐색 > SQL 편집기 > 쿼리 실행"),
            entry("회의"),
            entry("데이터 탐색 > SQL 편집기 > 차트 생성"),
        ])
        // 묶음은 첫 줄 자리에 두고, 아래가 하나뿐인 `데이터 탐색`은 `SQL 편집기`와 한 머리로 합친다
        #expect(lines == [
            "# 데이터 탐색 > SQL 편집기 (2)",
            "  - 데이터 탐색 > SQL 편집기 > 쿼리 실행 [데이터 탐색 > SQL 편집기]",
            "  - 데이터 탐색 > SQL 편집기 > 차트 생성 [데이터 탐색 > SQL 편집기]",
            "- 회의",
        ])
    }

    @Test func entryOnGroupPathStaysDirectlyUnderIt() {
        let lines = outline([
            entry("데이터 탐색 > 화면 정리"),
            entry("데이터 탐색 > SQL 편집기 > 쿼리 실행"),
            entry("데이터 탐색 > SQL 편집기 > 차트 생성"),
        ])
        #expect(lines == [
            "# 데이터 탐색 (3)",
            "  - 데이터 탐색 > 화면 정리 [데이터 탐색]",
            "  # SQL 편집기 (2)",
            "    - 데이터 탐색 > SQL 편집기 > 쿼리 실행 [데이터 탐색 > SQL 편집기]",
            "    - 데이터 탐색 > SQL 편집기 > 차트 생성 [데이터 탐색 > SQL 편집기]",
        ])
    }

    @Test func foldedGroupKeepsOnlyItsHeading() {
        let lines = outline([
            entry("데이터 탐색 > SQL 편집기 > 쿼리 실행"),
            entry("데이터 탐색 > SQL 편집기 > 차트 생성"),
            entry("데이터 탐색 > 목록 > 삭제"),
        ], folded: ["데이터 탐색"])
        #expect(lines == ["# 데이터 탐색 (3)"])
    }

    @Test func placementPinsAnEntryWhileItIsEdited() {
        let edited = entry("데이터 탐색 > SQL 편집기 > 쿼리")
        let other = entry("데이터 탐색 > SQL 편집기 > 차트 생성")
        // 고치는 줄은 제목이 바뀌어도 고정한 묶음에 남는다
        let items = WorkPathTree.items([edited, other]) { $0.id == edited.id ? "데이터 탐색 > SQL 편집기" : placement($0) }
        guard case .row(let first, let path, 1) = items[1] else { Issue.record("줄이 묶음 안에 없다"); return }
        #expect(first.id == edited.id && path == "데이터 탐색 > SQL 편집기")
    }

    @Test func keptEntryHoldsItsGroupWhenLeftAlone() {
        let edited = entry("데이터 탐색 > SQL 편집기 > 쿼리 실행")
        let items = WorkPathTree.items([entry("회의"), edited], placement: placement, keeps: { $0.id == edited.id })
        guard items.count == 3, case .heading(let path, _, 0, 1) = items[1], case .row(_, let rowPath, 1) = items[2] else {
            Issue.record("고치는 줄의 묶음이 풀렸다")
            return
        }
        #expect(path == "데이터 탐색 > SQL 편집기" && rowPath == path)
    }

    @Test func toleratesExtraSpacesAndEmptySegments() {
        let lines = outline([entry("데이터 탐색 >  > 목록 > 조회"), entry("데이터 탐색 > 목록 > 삭제")])
        #expect(lines.first == "# 데이터 탐색 > 목록 (2)")
    }
}
