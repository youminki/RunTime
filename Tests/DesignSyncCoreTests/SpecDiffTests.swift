import Foundation
import Testing
@testable import DesignSyncCore

@Suite struct SpecDiffTests {
    private func items(_ pairs: [(String, String)]) -> [SpecItem] { pairs.map { SpecItem(number: $0.0, text: $0.1) } }

    @Test func insertingAnItemDoesNotMarkShiftedItemsAsModified() {
        let old = items([("1", "검색 버튼 클릭 시 조회"), ("2", "정렬: 등록 최신순"), ("3", "페이징 20개")])
        let new = items([("1", "검색 버튼 클릭 시 조회"), ("2", "카테고리 탭: 전체 / 의류 / 잡화"), ("3", "정렬: 등록 최신순"), ("4", "페이징 20개")])
        let changes = SpecDiff.spec(old, new)
        #expect(changes.filter { $0.op == .added }.map(\.after) == ["카테고리 탭: 전체 / 의류 / 잡화"])
        #expect(changes.filter { $0.op == .modified }.isEmpty)
        #expect(changes.filter { $0.op == .renumbered }.map { [$0.before, $0.after] } == [["2", "3"], ["3", "4"]])
    }

    @Test func editedItemIsModifiedNotRemovedAndAdded() {
        let old = items([("1", "정렬: 판매중 > 품절 등록 최신순, 판매중 상단 고정"), ("2", "상세 이동")])
        let new = items([("1", "정렬: 등록 최신순 (상태 무관), 판매중 상단 고정 삭제"), ("2", "상세 이동")])
        let changes = SpecDiff.spec(old, new)
        #expect(changes.count == 1)
        #expect(changes[0].op == .modified)
        #expect(changes[0].before == "정렬: 판매중 > 품절 등록 최신순, 판매중 상단 고정")
    }

    @Test func appendedConditionIsStillTheSameItem() {
        let changes = SpecDiff.spec(items([("1", "검색"), ("2", "초기화")]), items([("1", "검색 (Enter 키 포함)"), ("2", "초기화")]))
        #expect(changes.map(\.op) == [.modified])
        #expect(changes[0].before == "검색")
    }

    @Test func shortTextInsideAnotherItemIsNotPairedAcrossNumbers() {
        // 번호가 다른데 `검색`이 `검색 결과 없음 안내` 안에 들어 있다고 같은 항목으로 보면 안 된다
        let changes = SpecDiff.spec(items([("1", "검색")]), items([("1", "정렬"), ("2", "검색 결과 없음 안내")]))
        #expect(changes.filter { $0.op == .modified }.isEmpty)
        #expect(changes.filter { $0.op == .added }.count == 2)
        #expect(changes.filter { $0.op == .removed }.map(\.before) == ["검색"])
    }

    @Test func unrelatedReplacementIsRemovedAndAdded() {
        let changes = SpecDiff.spec(items([("1", "재고 수 컬럼")]), items([("1", "할인 없음 체크박스")]))
        #expect(changes.map(\.op).sorted { $0.rawValue < $1.rawValue } == [.added, .removed])
    }

    @Test func duplicateNumbersStillMatchByContent() {
        // 같은 번호를 두 번 쓰는 화면설계서가 있다
        let old = items([("2", "카테고리 탭"), ("2", "텍스트 검색 Placeholder: 상품명 검색")])
        let new = items([("2", "카테고리 탭"), ("2", "텍스트 검색 Placeholder: 상품명 또는 코드 검색")])
        let changes = SpecDiff.spec(old, new)
        #expect(changes.count == 1)
        #expect(changes[0].op == .modified)
        #expect(changes[0].after == "텍스트 검색 Placeholder: 상품명 또는 코드 검색")
    }

    @Test func similarityIsSpacingTolerant() {
        #expect(SpecDiff.similarity("장바구니 담기", "장바구니담기") == 1)
        #expect(SpecDiff.similarity("abc", "xyz") == 0)
        #expect(SpecDiff.similarity("", "a") == 0)
    }

    @Test func recreatedTextWithNewIDIsNotAChange() {
        let changes = SpecDiff.texts(["1": "등록", "2": "가격"], ["9": "등록", "2": "판매 가격", "3": "재고"])
        #expect(changes == [
            SpecChange(layer: .text, op: .modified, label: "판매 가격", before: "가격", after: "판매 가격"),
            SpecChange(layer: .text, op: .added, label: "재고", after: "재고"),
        ])
    }

    @Test func componentAddsAreTalliedAndSwapsListed() {
        let old = ["1": SpecComponent(name: "button", componentID: "c:primary"), "2": SpecComponent(name: "input", componentID: "c:in")]
        let new = ["1": SpecComponent(name: "button", componentID: "c:secondary"), "2": SpecComponent(name: "input", componentID: "c:in"),
                   "3": SpecComponent(name: "checkbox", componentID: "c:cb"), "4": SpecComponent(name: "checkbox", componentID: "c:cb")]
        let changes = SpecDiff.components(old, new)
        #expect(changes.contains(SpecChange(layer: .component, op: .modified, label: "button 변형 교체", before: "button", after: "button")))
        #expect(changes.contains(SpecChange(layer: .component, op: .added, label: "컴포넌트 추가", after: "checkbox 2")))
        #expect(!changes.contains { $0.op == .removed })
    }

    @Test func headerAndSectionChangesAreReported() {
        let old = ScreenSnapshot(frameID: "1", screenID: "SC-1", title: "목록", sectionName: "[수정중] 상품")
        var new = old
        new.title = "상품 목록"
        new.sectionName = "[완료] 상품"
        let labels = SpecDiff.changes(from: old, to: new).map(\.label)
        #expect(labels == ["화면명", "섹션"])
    }

    @Test func identicalSnapshotsHaveNoChanges() {
        let snapshot = SpecExtractor.screens(in: Spec.screen("10:1"), page: Spec.page1)[0]
        #expect(SpecDiff.changes(from: snapshot, to: snapshot).isEmpty)
    }

    @Test func inlineDiffMarksChangedWords() {
        let segments = InlineDiff.segments(before: "가격 필수 입력", after: "가격 선택 입력")
        #expect(segments.map(\.kind) == [.same, .removed, .added, .same])
        #expect(segments.filter { $0.kind != .removed }.map(\.text).joined() == "가격 선택 입력")
        #expect(segments.filter { $0.kind != .added }.map(\.text).joined() == "가격 필수 입력")
    }
}
