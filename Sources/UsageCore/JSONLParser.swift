import Foundation

/// JSONL 한 줄 → UsageEvent. 스키마-관용적: 필요한 필드가 없으면 nil 반환(skip).
/// 스킵 규칙은 docs/jsonl-schema.md 참조.
public enum JSONLParser {

    private struct Record: Decodable {
        let type: String
        let timestamp: String?
        let requestId: String?
        let entrypoint: String?
        let version: LenientString?
        let cwd: LenientString?
        let isSidechain: LenientBool?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
            let stop_reason: LenientString?
        }

        /// 문자열이 아니면 nil. 부가 정보 하나 때문에 사용량 레코드가 통째로 버려지지 않게 한다.
        struct LenientString: Decodable {
            let value: String?
            init(from decoder: Decoder) throws {
                value = try? decoder.singleValueContainer().decode(String.self)
            }
        }

        struct LenientBool: Decodable {
            let value: Bool?
            init(from decoder: Decoder) throws {
                value = try? decoder.singleValueContainer().decode(Bool.self)
            }
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
    }

    private static let decoder = JSONDecoder()

    public static func parse(line: Data) -> UsageEvent? {
        guard let record = try? decoder.decode(Record.self, from: line) else { return nil }
        guard record.type == "assistant",
              let message = record.message,
              let usage = message.usage,
              let model = message.model, model != "<synthetic>",
              let messageId = message.id,
              let requestId = record.requestId,
              let timestampString = record.timestamp,
              let timestamp = ISODate.parse(timestampString)
        else { return nil }

        return UsageEvent(
            timestamp: timestamp,
            model: model,
            requestId: requestId,
            messageId: messageId,
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            entrypoint: record.entrypoint,
            clientVersion: record.version?.value,
            // 서브에이전트(사이드체인)가 끝난 것은 사람이 기다리는 대화가 끝난 것이 아니다
            endsTurn: message.stop_reason?.value == "end_turn" && record.isSidechain?.value != true,
            project: record.cwd?.value.map { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }

    public static func parse(line: String) -> UsageEvent? {
        parse(line: Data(line.utf8))
    }

    private static let limitMarker = Data("usage_limit_reached".utf8)

    private struct LimitRecord: Decodable {
        let timestamp: String?
        let apiError: String?
        let quotaLimits: Quota?
        struct Quota: Decodable {
            let resetsAt: Double?
            let rateLimitType: String?
        }
    }

    /// Claude Code가 한도에 막혀 남긴 줄(`"apiError":"usage_limit_reached"`). 아니면 nil.
    /// 거의 모든 줄이 아니므로 표시 문자열이 없으면 디코딩하지 않는다.
    public static func parseLimitHit(line: Data) -> LimitHit? {
        guard line.range(of: limitMarker) != nil,
              let record = try? decoder.decode(LimitRecord.self, from: line),
              record.apiError == "usage_limit_reached",
              let timestamp = record.timestamp.flatMap(ISODate.parse)
        else { return nil }
        let kind = record.quotaLimits?.rateLimitType ?? ""
        return LimitHit(timestamp: timestamp,
                        window: kind.hasPrefix("seven_day") ? .weekly : .session,
                        resetsAt: record.quotaLimits?.resetsAt.map { Date(timeIntervalSince1970: $0) })
    }
}

/// Claude Code 요청이 사용 한도에 막힌 순간.
public struct LimitHit: Equatable, Sendable {
    public enum Window: Sendable { case session, weekly }
    public let timestamp: Date
    public let window: Window
    public let resetsAt: Date?

    public init(timestamp: Date, window: Window, resetsAt: Date?) {
        self.timestamp = timestamp
        self.window = window
        self.resetsAt = resetsAt
    }
}
