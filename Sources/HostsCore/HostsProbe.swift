import Foundation

/// 이름 하나를 실제로 찔러 본 결과. 통신은 앱이 하고 판정은 여기서 한다.
public struct HostProbe: Equatable, Sendable {
    public enum Port: Equatable, Sendable { case open, refused, silent }

    public let name: String
    public let ip: String
    /// 맥이 실제로 푼 주소 (hosts, VPN, DNS를 다 거친 결과).
    public var resolved: [String]
    public var https: Port
    public var http: Port
    /// 웹 응답 코드. 포트가 열려도 웹 서버가 아니면 nil이다.
    public var status: Int?
    public var certificateExpiry: Date?
    public var certificateTrusted: Bool?

    public init(name: String, ip: String, resolved: [String], https: Port, http: Port, status: Int? = nil,
                certificateExpiry: Date? = nil, certificateTrusted: Bool? = nil) {
        self.name = name
        self.ip = ip
        self.resolved = resolved
        self.https = https
        self.http = http
        self.status = status
        self.certificateExpiry = certificateExpiry
        self.certificateTrusted = certificateTrusted
    }

    public struct Verdict: Equatable, Sendable {
        public enum Level: Int, Equatable, Sendable { case ok, warning, problem }
        public let level: Level
        /// 줄에 붙는 짧은 말.
        public let label: String
        /// 무엇을 보면 되는지.
        public let detail: String
    }

    /// 인증서가 이만큼 안에 끝나면 미리 알린다.
    static let expiryWarningDays = 14

    public func verdict(now: Date = Date()) -> Verdict {
        func problem(_ label: String, _ detail: String) -> Verdict { Verdict(level: .problem, label: label, detail: detail) }
        func warning(_ label: String, _ detail: String) -> Verdict { Verdict(level: .warning, label: label, detail: detail) }
        if !resolved.isEmpty, !resolved.contains(ip) {
            return problem("다른 주소로 풀림", "hosts에는 \(ip)인데 맥은 \(resolved.joined(separator: ", "))로 풉니다. 같은 이름의 다른 줄이나 VPN의 DNS를 확인하세요")
        }
        if https == .silent, http == .silent {
            return Self.isLocal(ip) ? problem("응답 없음", "443·80 포트가 답하지 않습니다. 사내망·VPN에 연결됐는지, 서버가 켜져 있는지 확인하세요")
                : problem("응답 없음", "443·80 포트가 답하지 않습니다. 주소가 맞는지 확인하세요")
        }
        if https != .open, http != .open {
            // 내 맥의 개발 서버는 꺼져 있는 것이 보통이라 문제로 세지 않는다
            if Self.isLoopback(ip) { return Verdict(level: .ok, label: "켜진 서버 없음", detail: "이 맥에서 443·80을 듣는 서버가 없습니다") }
            return warning("80·443 닫힘", "서버는 있지만 웹 포트가 닫혀 있습니다. 다른 포트를 쓰는 서버일 수 있습니다")
        }
        guard let status else {
            return warning("웹 응답 없음", "포트는 열렸지만 웹 응답이 없습니다. 웹 서버가 아니거나 응답이 늦습니다")
        }
        if status >= 500 { return problem("서버 오류 \(status)", "서버까지는 닿았지만 서버가 오류를 돌려줍니다") }
        if let expiry = certificateExpiry {
            let days = Int(expiry.timeIntervalSince(now) / 86_400)
            if expiry <= now { return problem("인증서 만료", "HTTPS 인증서가 끝났습니다") }
            if days < Self.expiryWarningDays { return warning("인증서 \(days)일 남음", "HTTPS 인증서가 곧 끝납니다") }
        }
        if certificateTrusted == false { return warning("인증서 미신뢰", "HTTPS 인증서를 이 맥이 믿지 않습니다. 사내 인증서면 브라우저 경고가 뜰 수 있습니다") }
        return Verdict(level: .ok, label: "응답 \(status)", detail: "서버가 응답합니다")
    }

    /// 사내 주소가 모두 답하지 않으면 서버마다가 아니라 연결 문제다.
    public static func overview(_ probes: [HostProbe]) -> String? {
        let local = probes.filter { isLocal($0.ip) }
        guard local.count >= 2, local.allSatisfy({ $0.https == .silent && $0.http == .silent }) else { return nil }
        return "사내 주소 \(local.count)개가 모두 답하지 않습니다. 서버보다 VPN이나 사내망 연결을 먼저 확인하세요"
    }

    /// 사설망 주소. 공인 주소처럼 보이는 `191.168.x.x`는 들어가지 않는다.
    static func isLocal(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    static func isLoopback(_ ip: String) -> Bool { ip.hasPrefix("127.") || ip == "::1" }

    /// `HTTP/1.1 200 OK`에서 응답 코드를 읽는다.
    public static func status(fromHead text: String) -> Int? {
        let parts = text.prefix(64).split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }
}
