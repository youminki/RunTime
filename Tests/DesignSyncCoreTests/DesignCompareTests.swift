import Foundation
import Testing
@testable import DesignSyncCore

/// 두 날짜의 버전을 견줘, 기록이 없던 기간의 변경도 본다.
@Suite struct DesignCompareTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func day(_ text: String, _ hour: Int = 12) -> Date {
        let parts = text.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    private func screen(_ frame: String, id: String, path: String = "주문 > 목록", text: String = "조회", candidate: String = "c1") -> ScreenSnapshot {
        ScreenSnapshot(frameID: frame, candidateID: candidate, screenID: id, title: id, menuPath: path, pageID: "p", sectionName: "[완료] 주문",
                       texts: ["t": text])
    }

    private func snapshot(_ version: String, _ screens: [String: [ScreenSnapshot]], outline: [String]? = nil,
                          changelog: [ChangelogEntry] = []) -> VersionSnapshot {
        var snapshot = VersionSnapshot(fileKey: "F", version: version)
        snapshot.screens = screens
        snapshot.candidates = (outline ?? Array(screens.keys)).map { FigmaAPI.Candidate(id: $0, name: "", pageID: "p", sectionName: "", isChangelog: false) }
        snapshot.changelog = changelog.isEmpty ? [:] : ["log": changelog]
        return snapshot
    }

    @Test func picksTheLastVersionOfThatDay() {
        let versions = [FigmaAPI.FileVersion(id: "3", createdAt: day("2026-10-27", 9)),
                        FigmaAPI.FileVersion(id: "2", createdAt: day("2026-10-25", 23), label: "1.2"),
                        FigmaAPI.FileVersion(id: "1", createdAt: day("2026-10-25", 9))]
        #expect(DesignCompare.version(atEndOf: day("2026-10-25"), in: versions, calendar: calendar)?.id == "2")
        #expect(DesignCompare.version(atEndOf: day("2026-10-26"), in: versions, calendar: calendar)?.id == "2")
        #expect(DesignCompare.version(atEndOf: day("2026-10-24"), in: versions, calendar: calendar) == nil)
        #expect(DesignCompare.named(between: versions[2], and: versions[0], in: versions).map(\.id) == ["2"])
    }

    @Test func savedVersionListJoinsTheLatestPage() {
        let v = (1...5).map { FigmaAPI.FileVersion(id: "\($0)", createdAt: day("2026-10-2\($0)")) }.reversed().map { $0 }
        #expect(DesignCompare.merge(latest: Array(v[0...2]), saved: Array(v[2...4]))?.map(\.id) == ["5", "4", "3", "2", "1"])
        #expect(DesignCompare.merge(latest: Array(v[0...1]), saved: Array(v[3...4])) == nil)
    }

    @Test func findsChangedAddedRemovedAndReplacedScreens() {
        let before = snapshot("v1", ["c1": [screen("1", id: "A"), screen("2", id: "B"), screen("3", id: "C")]])
        let after = snapshot("v2", ["c1": [screen("1", id: "A", text: "검색"), screen("4", id: "C"), screen("5", id: "D")]])
        let events = DesignCompare.events(fileKey: "F", fileName: "f", before: before, after: after,
                                          beforeDate: day("2026-10-25"), afterDate: day("2026-10-27"), include: { _ in true })
        let kinds = Dictionary(uniqueKeysWithValues: events.map { ($0.screenID, $0.kind) })
        #expect(kinds == ["A": .changed, "B": .removed, "C": .replaced, "D": .added])
        #expect(events.first { $0.screenID == "A" }?.beforeVersion == "v1")
        #expect(events.first { $0.screenID == "A" }?.afterVersion == "v2")
        #expect(events.first { $0.screenID == "A" }?.phase == .afterDone)
    }

    /// 한쪽에서 받지 않은 후보의 화면을 지운 것으로 보지 않는다. 뼈대에 없으면 정말 지운 것이다.
    @Test func unfetchedCandidateIsNotRemoved() {
        let before = snapshot("v1", ["c1": [screen("1", id: "A")], "c2": [screen("2", id: "B", candidate: "c2")]])
        let notFetched = snapshot("v2", ["c1": [screen("1", id: "A")]], outline: ["c1", "c2"])
        let gone = snapshot("v2", ["c1": [screen("1", id: "A")]], outline: ["c1"])
        let compare = { (after: VersionSnapshot) in
            DesignCompare.events(fileKey: "F", fileName: "f", before: before, after: after,
                                 beforeDate: day("2026-10-25"), afterDate: day("2026-10-27"), include: { _ in true })
        }
        #expect(compare(notFetched).isEmpty)
        #expect(compare(gone).map(\.kind) == [.removed])
    }

    /// 뒤 버전에서 살펴보지 않은 페이지의 화면은 지운 것으로 보지 않는다.
    @Test func unoutlinedPageIsNotRemoved() {
        var other = screen("2", id: "B", candidate: "c2")
        other.pageID = "q"
        var before = snapshot("v1", ["c1": [screen("1", id: "A")], "c2": [other]])
        before.candidates = before.candidates?.map { candidate in
            var candidate = candidate
            if candidate.id == "c2" { candidate.pageID = "q" }
            return candidate
        }
        var after = snapshot("v2", ["c1": [screen("1", id: "A")]])
        after.outlined = ["p"]
        let events = DesignCompare.events(fileKey: "F", fileName: "f", before: before, after: after,
                                          beforeDate: day("2026-10-25"), afterDate: day("2026-10-27"), include: { _ in true })
        #expect(events.isEmpty)
        after.outlined = ["p", "q"]
        #expect(DesignCompare.events(fileKey: "F", fileName: "f", before: before, after: after,
                                     beforeDate: day("2026-10-25"), afterDate: day("2026-10-27"), include: { _ in true }).map(\.kind) == [.removed])
    }

    @Test func changelogRowsBetweenTheDatesOnly() {
        let old = ChangelogEntry(pageID: "p", pageName: "주문", version: "1.0", date: "2026-10-24", text: "[목록] 최초")
        let edge = ChangelogEntry(pageID: "p", pageName: "주문", version: "1.1", date: "2026-10-25", text: "[목록] 필터")
        let new = ChangelogEntry(pageID: "p", pageName: "주문", version: "1.2", date: "2026-10-26", text: "[목록] 정렬")
        let other = ChangelogEntry(pageID: "p", pageName: "주문", version: "1.3", date: "2026-10-26", text: "[배송] 문구")
        let screens = ["c1": [screen("1", id: "A")]]
        let events = DesignCompare.events(fileKey: "F", fileName: "f", before: snapshot("v1", screens, changelog: [old, edge]),
                                          after: snapshot("v2", screens, changelog: [old, edge, new, other]),
                                          beforeDate: day("2026-10-25"), afterDate: day("2026-10-27"), include: { _ in true },
                                          knownPaths: ["주문 > 목록", "주문 > 배송"])
        #expect(events.map(\.note) == ["[목록] 정렬"])
        // 기준 버전을 저장한 날 오후에 같은 날짜로 적은 줄도 잡는다
        let sameDay = ChangelogEntry(pageID: "p", pageName: "주문", version: "1.1.1", date: "2026-10-25", text: "[목록] 문구")
        let late = DesignCompare.events(fileKey: "F", fileName: "f", before: snapshot("v1", screens, changelog: [old, edge]),
                                        after: snapshot("v2", screens, changelog: [old, edge, sameDay]),
                                        beforeDate: day("2026-10-25"), afterDate: day("2026-10-27"), include: { _ in true },
                                        knownPaths: ["주문 > 목록"])
        #expect(late.map(\.note) == ["[목록] 문구"])
        #expect(events.first?.menus == ["주문 > 목록"])
    }

    @Test func recordBecomesTheLatestSnapshot() {
        var history = DesignHistory()
        let capture = DesignCapture(fileKey: "F", fileName: "f", lastModified: "2026-10-27T00:00:00Z", coveredPages: ["p"], present: ["c1"],
                                    fetched: ["c1"], screens: [screen("1", id: "A")], version: "v9", changelog: [])
        history.record(capture, at: day("2026-10-27"))
        let snapshot = VersionSnapshot(record: history.files["F"]!, fileKey: "F")
        #expect(snapshot?.version == "v9")
        #expect(snapshot?.screens["c1"]?.map(\.screenID) == ["A"])
        #expect(snapshot?.candidates?.map(\.id) == ["c1"])
    }
}
