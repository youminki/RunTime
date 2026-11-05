import Foundation
import HostsCore
import Network
import Security

/// hosts의 이름이 실제로 닿는지 본다. 목록에 적힌 이름에만 포트 연결과 내용 없는 `HEAD` 요청을 보낸다.
enum HostsProber {
    private static let portTimeout: TimeInterval = 3
    private static let webTimeout: TimeInterval = 5
    /// 사내 서버에 한꺼번에 몰리지 않게 이만큼씩 본다.
    private static let parallel = 6

    static func probeAll(_ targets: [(name: String, ip: String)], each: @escaping @Sendable (HostProbe) async -> Void) async {
        await withTaskGroup(of: HostProbe.self) { group in
            var next = targets.makeIterator()
            func add() -> Bool {
                guard let target = next.next() else { return false }
                group.addTask { await probe(name: target.name, ip: target.ip) }
                return true
            }
            for _ in 0..<parallel where !add() { break }
            while let result = await group.next() {
                await each(result)
                _ = add()
            }
        }
    }

    static func probe(name: String, ip: String) async -> HostProbe {
        async let resolved = resolve(name)
        async let https = port(ip, 443)
        async let http = port(ip, 80)
        var result = HostProbe(name: name, ip: ip, resolved: await resolved, https: await https, http: await http)
        // 맥이 다른 주소로 풀면 이름으로 보낸 요청은 이 줄의 서버로 가지 않아 보지 않는다
        guard result.resolved.isEmpty || result.resolved.contains(ip) else { return result }
        if result.https == .open {
            let web = await secureHead(name)
            result.status = web.status
            result.certificateExpiry = web.expiry
            result.certificateTrusted = web.trusted
        }
        if result.status == nil, result.http == .open { result.status = await plainHead(name: name, ip: ip) }
        return result
    }

    private static func resolve(_ name: String) async -> [String] {
        await withCheckedContinuation { continuation in
            HostsStore.resolve(name) { continuation.resume(returning: $0) }
        }
    }

    static func port(_ ip: String, _ port: UInt16) async -> HostProbe.Port {
        await withConnection(ip, port) { _, finish in finish(.open) } ?? .silent
    }

    /// 앱 번들은 ATS가 평문 `URLSession`을 막아 80번은 직접 보낸다.
    private static func plainHead(name: String, ip: String) async -> Int? {
        let result: Int?? = await withConnection(ip, 80) { connection, finish in
            let head = "HEAD / HTTP/1.1\r\nHost: \(name)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
                if error != nil { finish(nil) }
            })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, _ in
                finish(data.flatMap { HostProbe.status(fromHead: String(decoding: $0, as: UTF8.self)) })
            }
        }
        return result ?? nil
    }

    /// 연결되면 `ready`를 부른다. 끊겼으면 `HostProbe.Port`를 돌려주는 경우에만 거절을 가른다.
    private static func withConnection<Value>(_ ip: String, _ port: UInt16,
                                              ready: @escaping (NWConnection, @escaping (Value) -> Void) -> Void) async -> Value? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "dev.runtime.RunTime.hosts-probe")
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port) ?? .http, using: .tcp)
            var finished = false
            func finish(_ value: Value?) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready(connection) { value in queue.async { finish(value) } }
                case .waiting(let error), .failed(let error):
                    if case .posix(.ECONNREFUSED) = error { finish(HostProbe.Port.refused as? Value) }
                    else if case .failed = state { finish(nil) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + portTimeout) { finish(nil) }
        }
    }

    private static func secureHead(_ name: String) async -> (status: Int?, expiry: Date?, trusted: Bool?) {
        guard let url = URL(string: "https://\(name)/") else { return (nil, nil, nil) }
        var request = URLRequest(url: url, timeoutInterval: webTimeout)
        request.httpMethod = "HEAD"
        let watcher = CertificateWatcher()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: watcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let response = try? await session.data(for: request).1
        return ((response as? HTTPURLResponse)?.statusCode, watcher.expiry, watcher.trusted)
    }

    /// 사내 인증서도 응답을 볼 수 있게 믿지 않아도 잇되, 믿는지와 만료일을 적어 둔다. 내용 없는 요청이라 보낼 비밀이 없다.
    private final class CertificateWatcher: NSObject, URLSessionTaskDelegate {
        var expiry: Date?
        var trusted: Bool?

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
            trusted = SecTrustEvaluateWithError(trust, nil)
            if let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
               let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: [CFString: Any]],
               let seconds = values[kSecOIDX509V1ValidityNotAfter]?[kSecPropertyKeyValue] as? NSNumber {
                expiry = Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        // 넘겨주는 곳으로 따라가지 않고 그 응답 코드를 그대로 본다
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
