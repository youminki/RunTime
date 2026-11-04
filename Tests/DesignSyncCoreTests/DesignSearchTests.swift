import Testing
@testable import DesignSyncCore

/// 찾기: 낱말은 모두 들어 있어야 하고, 띄어쓰기와 대소문자는 가리지 않는다.
@Suite struct DesignSearchTests {
    @Test func matchesAllTermsIgnoringSpacesAndCase() {
        let fields = ["SC-ACC-ADM-001", "관리자 계정 관리", "계정 관리 > 관리자 계정 관리"]
        #expect(DesignSearch.matches(DesignSearch.terms("계정관리"), fields))
        #expect(DesignSearch.matches(DesignSearch.terms("관리자  계정"), fields))
        #expect(DesignSearch.matches(DesignSearch.terms("sc-acc"), fields))
        #expect(!DesignSearch.matches(DesignSearch.terms("계정 대시보드"), fields))
        #expect(DesignSearch.matches(DesignSearch.terms("   "), fields))
    }
}
