import Foundation

/// macOS가 앱이 죽을 때 `~/Library/Logs/DiagnosticReports`에 남기는 `.ips` 충돌 보고서.
/// 첫 줄은 머리 JSON, 나머지는 본문 JSON이다. 충돌(bug_type 309)만 읽는다.
public struct CrashReport: Equatable {
    public struct Frame: Equatable {
        public var image: String
        public var symbol: String?
        public var location: Int?
        public var offset: Int
        /// 이 앱 실행 파일의 줄인지. 고칠 자리는 여기서 찾는다.
        public var inApp: Bool
    }

    public var appName: String
    public var appVersion: String
    public var buildVersion: String
    /// `2026-11-03 20:26:43.9373 +0900`. 그 Mac의 현지 시각이다.
    public var captureTime: String
    /// 그 실행을 켠 시각. 같은 pid로 켠 다른 실행의 출력과 가른다.
    public var procLaunch: String
    public var pid: Int?
    /// `atos -arch`에 넣을 값.
    public var arch: String
    public var procPath: String
    public var exceptionType: String
    public var signal: String
    public var codes: String
    public var indicator: String
    /// 시스템 라이브러리가 남긴 말 (`abort() called` 같은).
    public var notes: [String]
    public var queue: String
    /// 죽은 스레드의 호출 순서. ObjC 예외로 죽었으면 예외를 던진 자리의 호출 순서다.
    public var frames: [Frame]
    public var thrown: Bool
    /// `atos -l`에 넣을 실행 파일 적재 주소와 UUID.
    public var appBase: Int?
    public var appUUID: String

    /// 충돌 보고서가 아니거나 모양이 다르면 nil.
    public init?(ips text: String) {
        guard let newline = text.firstIndex(of: "\n"),
              let header = Self.object(text[..<newline]),
              let body = Self.object(text[text.index(after: newline)...]),
              "\(header["bug_type"] ?? "")" == "309" else { return nil }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let procPath = body["procPath"] as? String ?? ""
        let executable = (procPath as NSString).lastPathComponent
        let appIndex = images.firstIndex { ($0["path"] as? String) == procPath }
            ?? images.firstIndex { ($0["name"] as? String) == executable }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let thread = threads.indices.contains(faulting) ? threads[faulting] : [:]
        let exceptionFrames = body["lastExceptionBacktrace"] as? [[String: Any]]
        let rawFrames = exceptionFrames ?? thread["frames"] as? [[String: Any]] ?? []
        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]

        appName = header["app_name"] as? String ?? executable
        appVersion = header["app_version"] as? String ?? ""
        buildVersion = header["build_version"] as? String ?? ""
        captureTime = body["captureTime"] as? String ?? header["timestamp"] as? String ?? ""
        procLaunch = body["procLaunch"] as? String ?? ""
        pid = body["pid"] as? Int
        arch = (body["cpuType"] as? String ?? "").uppercased().hasPrefix("X86") ? "x86_64" : "arm64"
        self.procPath = procPath
        exceptionType = exception["type"] as? String ?? ""
        signal = exception["signal"] as? String ?? ""
        codes = exception["codes"] as? String ?? ""
        indicator = termination["indicator"] as? String ?? ""
        notes = (body["asi"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
            .flatMap { $0.value as? [String] ?? [] }
        queue = thread["queue"] as? String ?? thread["name"] as? String ?? ""
        thrown = exceptionFrames != nil
        frames = rawFrames.map { frame in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : [:]
            return Frame(image: image["name"] as? String ?? "?", symbol: frame["symbol"] as? String,
                         location: frame["symbolLocation"] as? Int, offset: frame["imageOffset"] as? Int ?? 0,
                         inApp: index >= 0 && index == appIndex)
        }
        let app = appIndex.map { images[$0] }
        appBase = app?["base"] as? Int
        appUUID = app?["uuid"] as? String ?? ""
    }

    private static func object(_ text: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// 메일 제목·묶음 열쇠에 쓰는 한 줄. 같은 자리의 같은 충돌은 같은 줄이 나와야 하루 한 통으로 묶인다.
    /// 주소처럼 실행마다 바뀌는 값은 넣지 않는다. 죽기 직전 줄이 까닭이라 마지막 줄을 쓴다.
    public func summary(fatal: [String]) -> String {
        let reason = fatal.last.map { Self.withoutLocation($0).replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0x…", options: .regularExpression) }
            ?? ([exceptionType, signal.isEmpty ? "" : "(\(signal))"].filter { !$0.isEmpty }.joined(separator: " "))
        let place = frames.first { $0.inApp }.map { $0.symbol ?? "\($0.image) +0x\(String($0.offset, radix: 16))" }
        return [reason.isEmpty ? "앱이 죽음" : reason, place].compactMap { $0 }.joined(separator: " · ")
    }

    /// `RunTime/AppDelegate.swift:12: Fatal error: 까닭`에서 위치를 뗀 `Fatal error: 까닭`.
    static func withoutLocation(_ line: String) -> String {
        guard let range = line.range(of: #"^\S+\.swift:\d+: "#, options: .regularExpression) else { return line }
        return String(line[range.upperBound...])
    }

    /// 메일의 상황 칸. 위에서부터 읽어 고칠 자리를 찾게 까닭, 호출 순서, 기호 찾는 명령 순으로 둔다.
    /// 호출 순서는 이 앱 줄과 그 바로 위 시스템 줄 위주로 남기고, 길면 아래부터 덜어 `limit`자 안에 맞춘다.
    public func detail(fatal: [String], limit: Int = 2000) -> String {
        var head = ["버전: \(appVersion.isEmpty ? "-" : appVersion) (빌드 \(buildVersion.isEmpty ? "-" : buildVersion)) · 죽은 시각: \(captureTime)"]
        head.append("예외: " + [exceptionType, signal, codes].filter { !$0.isEmpty }.joined(separator: " · ")
                    + (indicator.isEmpty ? "" : " · \(indicator)"))
        head += fatal.map { "출력: \($0)" }
        head += notes.map { "시스템: \($0)" }
        let title = thrown ? "예외를 던진 자리" : "죽은 스레드" + (queue.isEmpty ? "" : " (\(queue))")
        let shown = Self.relevant(frames)
        var lines = shown.map { index, frame in
            let name = frame.symbol.map { "\($0)" + (frame.location.map { " + \($0)" } ?? "") } ?? "+0x\(String(frame.offset, radix: 16))"
            return "\(index) \(frame.inApp ? "▶ " : "")\(frame.image) \(name)"
        }
        var tail: [String] = []
        let addresses = frames.filter(\.inApp).prefix(8).compactMap { frame in appBase.map { "0x" + String($0 + frame.offset, radix: 16) } }
        if let base = appBase, !addresses.isEmpty {
            // -g는 기계어를 바꾸지 않아 주소가 같고, 붙여야 atos가 파일·줄까지 찾는다
            tail = ["", "코드 줄 찾기 (그 커밋에서 swift build -c release -Xswiftc -g --scratch-path .build/symbols):",
                    "atos -o .build/symbols/release/RunTime -arch \(arch) -l 0x\(String(base, radix: 16)) \(addresses.joined(separator: " "))"]
            if !appUUID.isEmpty { tail.append("실행 파일 UUID: \(appUUID)") }
        }
        func joined() -> String { (head + ["", title] + lines + tail).joined(separator: "\n") }
        while joined().count > limit, lines.count > 1 { lines.removeLast() }
        if joined().count > limit { tail = [] }
        return String(joined().prefix(limit))
    }

    /// 앱 줄과 그 바로 위 한 줄(어느 시스템 함수에서 죽었는지), 맨 위 세 줄만 남긴다.
    static func relevant(_ frames: [Frame]) -> [(Int, Frame)] {
        let keep = Set(frames.indices.filter { index in
            index < 3 || frames[index].inApp || (index + 1 < frames.count && frames[index + 1].inApp)
        })
        return frames.enumerated().filter { keep.contains($0.offset) }.map { ($0.offset, $0.element) }
    }

    /// 앱이 stderr에 남긴 출력에서 죽은 까닭 줄만 고른다. Swift 런타임과 Foundation이 죽기 전에 이 꼴로 찍는다.
    /// 최적화 빌드는 범위 밖·nil 풀기의 까닭을 지우고 `fatalError` 글만 남긴다.
    public static func fatalLines(_ output: String) -> [String] {
        let markers = ["Fatal error:", "Precondition failed", "Assertion failed", "Terminating app due to uncaught exception"]
        return Array(output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in markers.contains { line.contains($0) } }
            .suffix(3))
    }

    private static let stampPattern = #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d"#

    /// `yyyy-MM-dd HH:mm:ss…` 꼴 현지 시각을 그 Mac 시간대로 읽는다. 충돌 보고서의 시각에는 시간대가 붙어 있어 그것을 쓴다.
    public static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return formatter.date(from: text)
    }

    /// 죽기 전까지의 진단 기록. 다시 켠 뒤 쌓인 줄은 그 충돌과 상관없어 뺀다.
    /// 기록 줄은 `yyyy-MM-dd HH:mm:ss [영역] …`이고 충돌 시각도 같은 현지 시각이라 글자로 견준다.
    public static func events(_ log: String, before captureTime: String, count: Int = 25) -> [String] {
        let limit = String(captureTime.prefix(19))
        guard limit.range(of: stampPattern, options: .regularExpression) != nil else { return [] }
        return Array(log.components(separatedBy: "\n")
            .filter { $0.range(of: stampPattern, options: .regularExpression) != nil && $0.prefix(19) <= limit && !$0.contains("[문제 보고]") }
            .suffix(count))
    }
}
