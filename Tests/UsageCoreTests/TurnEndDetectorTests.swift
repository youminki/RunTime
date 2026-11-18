import Foundation
import Testing
@testable import UsageCore

struct TurnEndDetectorTests {
    private static func line(stop: String, sidechain: String = "false", cwd: String = "/Users/me/GitHub/RunTime") -> String {
        JSONLParserTests.validLine
            .replacingOccurrences(of: #""entrypoint":"cli","#,
                                  with: #""entrypoint":"cli","cwd":"\#(cwd)","isSidechain":\#(sidechain),"#)
            .replacingOccurrences(of: #""role":"assistant","#, with: #""role":"assistant","stop_reason":\#(stop),"#)
    }

    @Test func parsesEndTurnAndProject() throws {
        let event = try #require(JSONLParser.parse(line: Self.line(stop: #""end_turn""#)))
        #expect(event.endsTurn)
        #expect(event.project == "RunTime")
    }

    @Test func toolUseSidechainAndOddValuesAreNotTurnEnds() throws {
        #expect(try #require(JSONLParser.parse(line: Self.line(stop: #""tool_use""#))).endsTurn == false)
        #expect(try #require(JSONLParser.parse(line: Self.line(stop: "null"))).endsTurn == false)
        #expect(try #require(JSONLParser.parse(line: Self.line(stop: #""end_turn""#, sidechain: "true"))).endsTurn == false)
        // 형식이 다른 부가 필드 때문에 사용량 레코드가 버려지면 안 된다
        let odd = try #require(JSONLParser.parse(line: Self.line(stop: "1", sidechain: #""yes""#)))
        #expect(odd.endsTurn == false)
        #expect(odd.totalTokens > 0)
    }

    @Test func announcesEachRecentMessageOnce() throws {
        let event = try #require(JSONLParser.parse(line: Self.line(stop: #""end_turn""#)))
        let now = event.timestamp.addingTimeInterval(5)
        var detector = TurnEndDetector()
        // 한 응답이 여러 줄로 기록된다
        #expect(detector.finishedTurns(in: [event, event], now: now).count == 1)
        #expect(detector.finishedTurns(in: [event], now: now).isEmpty)
    }

    @Test func ignoresOldHistoryReadAtLaunch() throws {
        let event = try #require(JSONLParser.parse(line: Self.line(stop: #""end_turn""#)))
        var detector = TurnEndDetector()
        #expect(detector.finishedTurns(in: [event], now: event.timestamp.addingTimeInterval(3600)).isEmpty)
    }
}

struct TurnDurationTests {
    private func event(_ at: Date, id: String, ends: Bool = false, project: String = "RunTime") -> UsageEvent {
        UsageEvent(timestamp: at, model: "claude-opus-5-5", requestId: "req_\(id)", messageId: "msg_\(id)",
                   inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0,
                   endsTurn: ends, project: project)
    }

    @Test func measuresFromFirstReplyToEnd() {
        let start = Date()
        var detector = TurnEndDetector()
        // 여러 번에 나눠 읽어도 첫 응답부터 센다
        #expect(detector.finishedTurns(in: [event(start, id: "a")], now: start).isEmpty)
        #expect(detector.finishedTurns(in: [event(start.addingTimeInterval(60), id: "b")], now: start.addingTimeInterval(60)).isEmpty)
        let end = start.addingTimeInterval(150)
        let turns = detector.finishedTurns(in: [event(end, id: "c", ends: true)], now: end)
        #expect(turns.count == 1)
        #expect(turns.first?.duration == 150)
        #expect(turns.first?.project == "RunTime")
        // 다음 차례는 다시 처음부터
        let next = end.addingTimeInterval(30)
        #expect(detector.finishedTurns(in: [event(next, id: "d", ends: true)], now: next).first?.duration == 0)
    }

    @Test func projectsAreTimedSeparately() {
        let start = Date()
        var detector = TurnEndDetector()
        _ = detector.finishedTurns(in: [event(start, id: "a", project: "A")], now: start)
        let later = start.addingTimeInterval(100)
        let turns = detector.finishedTurns(in: [event(later, id: "b", ends: true, project: "B")], now: later)
        #expect(turns.first?.duration == 0)
    }

    @Test func longIdleStartsANewTurn() {
        let start = Date()
        var detector = TurnEndDetector()
        _ = detector.finishedTurns(in: [event(start, id: "a")], now: start)
        let end = start.addingTimeInterval(3600)
        // 끝 표시 없이 한 시간 쉬었다가 온 대답은 그 대답부터 센다
        let turns = detector.finishedTurns(in: [event(end.addingTimeInterval(-20), id: "b"), event(end, id: "c", ends: true)],
                                           now: end)
        #expect(turns.first?.duration == 20)
    }
}

extension TurnEndDetectorTests {
    @Test func workingUntilTurnEndsOrGoesQuiet() throws {
        let tool = try #require(JSONLParser.parse(line: Self.line(stop: #""tool_use""#)))
        let end = try #require(JSONLParser.parse(line: Self.line(stop: #""end_turn""#)))
        let now = tool.timestamp.addingTimeInterval(5)
        var detector = TurnEndDetector()
        #expect(!detector.isWorking(now: now, within: 300))
        _ = detector.finishedTurns(in: [tool], now: now)
        #expect(detector.isWorking(now: now, within: 300))
        // 끝 표시 없이 조용해진 차례는 일하는 중으로 보지 않는다
        #expect(!detector.isWorking(now: now.addingTimeInterval(300), within: 300))
        _ = detector.finishedTurns(in: [end], now: now)
        #expect(!detector.isWorking(now: now, within: 300))
    }

    @Test func longTurnsAreCelebrated() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func turn(_ minutes: Double) -> TurnEndDetector.FinishedTurn {
            TurnEndDetector.FinishedTurn(project: nil, endedAt: start, duration: minutes * 60)
        }
        #expect(!turn(9.9).isLong)
        #expect(turn(10).isLong)
    }
}
