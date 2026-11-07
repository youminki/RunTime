import Foundation

/// Claude가 글자로 찍어 돌려준 도트 펫. 받은 글을 믿지 않고 크기와 색을 바로잡거나 버린다.
public struct PetSketch: Equatable, Sendable {
    public static let size = 32
    public static let frameNames = ["stand", "stepA", "stepB", "jump"]
    /// 이보다 칠한 칸이 적으면 그림으로 치지 않는다.
    static let minimumPixels = 80

    public struct Color: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
    }

    public let name: String
    /// 프레임 이름별 32×32 칸. 투명은 nil.
    public let frames: [String: [[Color?]]]

    /// JSON을 읽어 만든다. 앞뒤에 다른 글이 있어도 읽고, 쓸 수 없으면 nil.
    /// 긴 줄은 자르고 짧은 줄과 모자란 줄은 투명으로 채운다. 없는 프레임은 서 있는 모습으로 대신한다.
    public static func parse(_ text: String) -> PetSketch? {
        // 고쳐 쓰며 답을 두 번 적을 때가 있어 뒤에 적은 답부터 읽는다
        let starts = text.indices.filter { index in
            text[index] == "{" && ["{\"name\"", "{\"palette\"", "{\"frames\""].contains { text[index...].hasPrefix($0) }
        }.reversed() + [text.firstIndex(of: "{")].compactMap { $0 }
        var parsed: [String: Any]?
        for start in starts {
            var end = text.endIndex
            while parsed == nil, let close = text[start..<end].lastIndex(of: "}") {
                parsed = (try? JSONSerialization.jsonObject(with: Data(text[start...close].utf8))) as? [String: Any]
                end = close
                // 뒤의 군더더기만 건너뛰면 된다. 큰 글에서 오래 돌지 않게 몇 번만 본다
                if text.distance(from: close, to: text.endIndex) > 2000 { break }
            }
            if parsed != nil { break }
        }
        guard let object = parsed,
              let palette = object["palette"] as? [String: String],
              let rawFrames = object["frames"] as? [String: [String]] else { return nil }
        var colors: [Character: Color] = [:]
        for (key, value) in palette {
            guard key.count == 1, let first = key.first, let color = color(value) else { continue }
            colors[first] = color
        }
        guard let standRows = rawFrames["stand"] else { return nil }
        func grid(_ rows: [String]) -> [[Color?]] {
            (0..<size).map { y in
                let row = y < rows.count ? Array(rows[y]) : []
                return (0..<size).map { x in x < row.count ? colors[row[x]] : nil }
            }
        }
        let stand = grid(standRows)
        guard painted(stand) >= minimumPixels else { return nil }
        var frames: [String: [[Color?]]] = [:]
        for name in frameNames {
            let candidate = rawFrames[name].map(grid)
            frames[name] = candidate.flatMap { painted($0) >= minimumPixels ? $0 : nil } ?? stand
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PetSketch(name: String(name.prefix(24)), frames: frames)
    }

    private static func painted(_ grid: [[Color?]]) -> Int {
        grid.reduce(0) { $0 + $1.filter { $0 != nil }.count }
    }

    private static func color(_ text: String) -> Color? {
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// 그림 아래끝을 맨 아래 칸에 맞춘다. 프레임마다 발이 뜨면 걸을 때 출렁인다.
    public func grounded(_ name: String) -> [[Color?]] {
        guard let grid = frames[name],
              let bottom = grid.lastIndex(where: { $0.contains { $0 != nil } }) else { return frames[name] ?? [] }
        let shift = Self.size - 1 - bottom
        guard shift > 0 else { return grid }
        return Array(repeating: Array(repeating: nil, count: Self.size), count: shift) + grid.prefix(Self.size - shift)
    }
}
