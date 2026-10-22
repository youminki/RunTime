import Foundation
import Testing
@testable import DesignSyncCore

/// 변경 전·후 이미지를 그 버전 그대로 받으려고 파일 버전을 남기고, 프로젝트마다 가져오기 주기를 둔다.
@Suite struct DesignVersionTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func snap(_ frame: String, _ text: String, section: String = "[완료] 상품") -> ScreenSnapshot {
        ScreenSnapshot(frameID: frame, screenID: "SC-" + frame, title: "목록", menuPath: "상품 > 목록", pageID: "1:1",
                       sectionName: section, items: [SpecItem(number: "1", text: text)])
    }

    private func capture(_ screens: [ScreenSnapshot], version: String, at date: Date) -> DesignCapture {
        DesignCapture(fileKey: "F", fileName: "데모", lastModified: ISO8601DateFormatter().string(from: date), coveredPages: ["1:1"],
                      present: Set(screens.map(\.candidateID)), fetched: Set(screens.map(\.candidateID)), screens: screens,
                      version: version, changelog: nil)
    }

    @Test func eventsKeepTheVersionsBeforeAndAfter() {
        var history = DesignHistory()
        history.record(capture([snap("1", "검색"), snap("2", "필터")], version: "v1", at: t0), at: t0)
        #expect(history.files["F"]?.version == "v1")
        let t1 = t0.addingTimeInterval(60)
        let events = history.record(capture([snap("1", "검색 버튼"), snap("3", "새 탭")], version: "v2", at: t1), at: t1)
        let changed = events.first { $0.kind == .changed }
        let added = events.first { $0.kind == .added }
        let removed = events.first { $0.kind == .removed }
        #expect(changed?.beforeVersion == "v1" && changed?.afterVersion == "v2")
        #expect(added?.beforeVersion == nil && added?.afterVersion == "v2")
        #expect(removed?.beforeVersion == "v1" && removed?.afterVersion == nil)
        #expect(history.files["F"]?.version == "v2")
    }

    @Test func mergedWorkingEventKeepsTheFirstBeforeVersion() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))!
        var history = DesignHistory()
        history.record(capture([snap("1", "a", section: "[수정중] 상품")], version: "v1", at: start), at: start, calendar: calendar)
        history.record(capture([snap("1", "ab", section: "[수정중] 상품")], version: "v2", at: start.addingTimeInterval(60)),
                       at: start.addingTimeInterval(60), calendar: calendar)
        history.record(capture([snap("1", "abc", section: "[수정중] 상품")], version: "v3", at: start.addingTimeInterval(120)),
                       at: start.addingTimeInterval(120), calendar: calendar)
        #expect(history.events.count == 1)
        #expect(history.events.first?.beforeVersion == "v1")
        #expect(history.events.first?.afterVersion == "v3")
    }

    @Test func readsVersionAndImages() throws {
        let file = Data(#"{"name":"데모","lastModified":"2026-10-22T00:00:00Z","version":"123","document":{"id":"0:0","type":"DOCUMENT","children":[]}}"#.utf8)
        #expect(try FigmaAPI.parseFile(file).version == "123")
        let images = Data(#"{"err":null,"images":{"1:2":"https://example.com/a.png","3:4":null}}"#.utf8)
        #expect(try FigmaAPI.parseImages(images) == ["1:2": URL(string: "https://example.com/a.png")!])
        #expect(throws: FigmaAPI.Failure.forbidden("Invalid version")) {
            try FigmaAPI.parseImages(Data(#"{"err":"Invalid version","images":{}}"#.utf8))
        }
        let request = FigmaAPI.imagesRequest(fileKey: "K", ids: ["1:2"], version: "123", token: "t")
        #expect(request.url?.absoluteString == "https://api.figma.com/v1/images/K?ids=1:2&format=png&scale=0.5&version=123")
    }

    @Test func projectIntervalDecodesAndDefaultsToNil() throws {
        let old = try JSONDecoder().decode(DesignSource.self, from: Data(#"{"fileKey":"F"}"#.utf8))
        #expect(old.intervalMinutes == nil)
        var source = DesignSource(fileKey: "F")
        source.intervalMinutes = 1440
        let back = try JSONDecoder().decode(DesignSource.self, from: JSONEncoder().encode(source))
        #expect(back.intervalMinutes == 1440)
    }
}
