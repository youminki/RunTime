import Foundation

/// 키 순서와 문자열·숫자의 원래 글자를 지키는 JSON. 남의 설정 파일(`~/.claude/settings.json`)을 고칠 때
/// 손대지 않은 부분이 그대로 남게 한다. 쓸 때는 Claude Code와 같은 `JSON.stringify(v, null, 2)` 꼴로 쓴다.
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    /// 따옴표를 포함한 원래 글자.
    case string(raw: String)
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON
        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    public struct ParseError: Error, Equatable {}

    public static func string(_ value: String) -> OrderedJSON {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("\"\"".utf8)
        return .string(raw: String(decoding: data, as: UTF8.self))
    }

    /// 문자열 값. 문자열이 아니면 nil.
    public var stringValue: String? {
        guard case .string(let raw) = self else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) as? String
    }

    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// 객체의 한 키를 바꾸거나 끝에 더한다. nil이면 지운다. 객체가 아니면 그대로 둔다.
    public func setting(_ key: String, _ value: OrderedJSON?) -> OrderedJSON {
        guard case .object(var members) = self else { return self }
        if let index = members.firstIndex(where: { $0.key == key }) {
            if let value { members[index].value = value } else { members.remove(at: index) }
        } else if let value {
            members.append(Member(key, value))
        }
        return .object(members)
    }

    // MARK: - 읽기

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError() }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            skipSpace()
            guard index < bytes.count else { throw ParseError() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [Member] = []
                skipSpace()
                if consume("}") { return .object(members) }
                repeat {
                    skipSpace()
                    guard let key = try string().stringValue else { throw ParseError() }
                    skipSpace()
                    guard consume(":") else { throw ParseError() }
                    members.append(Member(key, try value()))
                    skipSpace()
                } while consume(",")
                guard consume("}") else { throw ParseError() }
                return .object(members)
            case UInt8(ascii: "["):
                index += 1
                var items: [OrderedJSON] = []
                skipSpace()
                if consume("]") { return .array(items) }
                repeat { items.append(try value()); skipSpace() } while consume(",")
                guard consume("]") else { throw ParseError() }
                return .array(items)
            case UInt8(ascii: "\""):
                return try string()
            case UInt8(ascii: "t"):
                return try literal("true", .bool(true))
            case UInt8(ascii: "f"):
                return try literal("false", .bool(false))
            case UInt8(ascii: "n"):
                return try literal("null", .null)
            default:
                let start = index
                while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
                guard index > start else { throw ParseError() }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                guard Double(text) != nil else { throw ParseError() }
                return .number(text)
            }
        }

        mutating func string() throws -> OrderedJSON {
            let start = index
            guard consume("\"") else { throw ParseError() }
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    let value = OrderedJSON.string(raw: String(decoding: bytes[start..<index], as: UTF8.self))
                    // 잘못된 이스케이프는 여기서 걸러 쓸 때 깨진 파일을 만들지 않는다
                    guard value.stringValue != nil else { throw ParseError() }
                    return value
                default: index += 1
                }
            }
            throw ParseError()
        }

        mutating func literal(_ word: String, _ value: OrderedJSON) throws -> OrderedJSON {
            let end = index + word.utf8.count
            guard end <= bytes.count, Array(bytes[index..<end]) == Array(word.utf8) else { throw ParseError() }
            index = end
            return value
        }

        mutating func consume(_ char: Character) -> Bool {
            guard index < bytes.count, bytes[index] == char.asciiValue else { return false }
            index += 1
            return true
        }
    }

    // MARK: - 쓰기

    /// `JSON.stringify(v, null, 2)`와 같은 꼴.
    public func serialized(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let lines = members.map { "\(inner)\(OrderedJSON.string($0.key).serialized()): \($0.value.serialized(indent: inner))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + $0.serialized(indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .string(let raw): return raw
        case .number(let text): return text
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }
}
