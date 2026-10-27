import Foundation

/// 피그마 REST API. 요청을 만들고 응답을 읽기만 하고, 보내는 일은 앱이 한다.
/// 화면설계서 페이지 하나가 노드 수만 개라 파일을 통째로 받지 않고 세 단계로 나눠 받는다.
/// 1. 파일 정보(depth=1): 마지막 수정 시각과 페이지 목록
/// 2. 페이지 뼈대(depth=3): 화면 후보 프레임과 제·개정 이력 프레임
/// 3. 후보 노드: 바뀌었을 수 있는 화면만
public enum FigmaAPI {
    static let base = URL(string: "https://api.figma.com/v1/")!
    /// 한 요청에 담는 노드 수. 화면 하나가 노드 수백 개라 많이 묶으면 응답이 수십 MB가 된다.
    public static let nodesPerRequest = 8
    /// 페이지 뼈대 깊이: 페이지 → 섹션 → 화면 → 화면의 자식(헤더 행 등)
    static let outlineDepth = 3

    public enum Failure: Error, Equatable {
        case unauthorized
        /// 토큰에 이 API의 범위가 없다. 피그마가 알려 준 필요한 범위를 담는다.
        case missingScope(required: String)
        /// 토큰은 맞지만 이 파일을 볼 수 없다. 피그마가 준 이유를 담는다.
        case forbidden(String?)
        case notFound
        case rateLimited(retryAfter: Int?)
        case server(Int)
        case malformed

        public var message: String {
            switch self {
            case .unauthorized: return "피그마 토큰이 맞지 않거나 만료됐습니다"
            case .missingScope(let required): return "토큰에 \(required) 범위가 없습니다"
            case .forbidden(let reason):
                return "이 파일을 볼 권한이 없습니다. 토큰을 만든 피그마 계정이 이 파일을 열 수 있는지 확인하세요"
                    + (reason.map { " (\($0))" } ?? "")
            case .notFound: return "파일을 찾지 못했습니다. 주소와, 토큰을 만든 계정이 이 파일을 볼 수 있는지 확인하세요"
            case .rateLimited(let after):
                // 몇 초가 아니라 몇 시에 풀리는지 (한도는 몇 시간·며칠일 수도 있다)
                guard let after else { return "피그마 호출 한도에 걸렸습니다. 잠시 뒤 다시 받습니다" }
                let at = Date().addingTimeInterval(TimeInterval(after))
                let format = DateFormatter()
                format.locale = Locale(identifier: "ko_KR")
                format.dateFormat = after > 20 * 3600 ? "M월 d일 a h:mm" : "a h:mm"
                return "피그마 호출 한도에 걸렸습니다. \(format.string(from: at)) 뒤에 다시 받습니다"
            case .server(let status): return "피그마 응답 오류 (\(status))"
            case .malformed: return "피그마 응답을 읽지 못했습니다"
            }
        }
    }

    /// 응답 상태가 실패면 그 이유. 성공이면 nil.
    /// 피그마는 틀린 토큰, 범위 부족, 파일 권한 없음을 모두 403으로 주고 이유는 본문(`err` 또는 `message`)에 적는다.
    public static func failure(status: Int, retryAfter: String?, body: Data? = nil) -> Failure? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403:
            let reason = body.flatMap(errorText)
            if let reason, reason.localizedCaseInsensitiveContains("invalid token") { return .unauthorized }
            if let reason, reason.hasPrefix("Invalid scope") { return .missingScope(required: requiredScope(reason) ?? reason) }
            return .forbidden(reason)
        case 404: return .notFound
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        default: return .server(status)
        }
    }

    /// `{"status":403,"err":"Invalid token"}` 또는 `{"status":403,"error":true,"message":"Invalid scope: …"}`
    static func errorText(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return (object["err"] as? String) ?? (object["message"] as? String)
    }

    /// `… This endpoint requires the file_read or files:read or current_user:read scope.` → `file_read or files:read or current_user:read`
    static func requiredScope(_ text: String) -> String? {
        guard let range = text.range(of: "requires the "), let end = text.range(of: " scope", range: range.upperBound..<text.endIndex)
        else { return nil }
        return String(text[range.upperBound..<end.lowerBound])
    }

    // MARK: 요청

    static func request(_ path: String, query: [URLQueryItem], token: String) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        request.timeoutInterval = 60
        return request
    }

    /// 토큰 주인. 연결을 확인할 때 쓴다.
    public static func meRequest(token: String) -> URLRequest {
        request("me", query: [], token: token)
    }

    /// `version`을 주면 그 버전 그대로 받는다 (날짜 비교).
    public static func fileRequest(fileKey: String, version: String? = nil, token: String) -> URLRequest {
        var query = [URLQueryItem(name: "depth", value: "1")]
        if let version { query.append(URLQueryItem(name: "version", value: version)) }
        return request("files/\(fileKey)", query: query, token: token)
    }

    public static func nodesRequest(fileKey: String, ids: [String], depth: Int? = nil, version: String? = nil, token: String) -> URLRequest {
        var query = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        if let depth { query.append(URLQueryItem(name: "depth", value: String(depth))) }
        if let version { query.append(URLQueryItem(name: "version", value: version)) }
        return request("files/\(fileKey)/nodes", query: query, token: token)
    }

    /// 파일 버전 기록 (최근 것부터). 자동 저장도 30분 안팎마다 남는다. file_versions:read 범위가 있어야 한다.
    /// `next`는 피그마가 준 다음(더 오래된) 쪽 주소다.
    public static func versionsRequest(fileKey: String, next: URL? = nil, token: String) -> URLRequest {
        guard let next else { return request("files/\(fileKey)/versions", query: [URLQueryItem(name: "page_size", value: "50")], token: token) }
        var request = URLRequest(url: next)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        request.timeoutInterval = 60
        return request
    }

    /// 프레임을 그 버전 그대로 PNG로 그려 달라는 요청. 받는 것은 잠깐 쓸 수 있는 이미지 주소다.
    /// 화면설계서 프레임은 2400px 안팎이라 반으로 줄여 받는다 (견주어 보기에 충분하고 용량은 4분의 1).
    public static func imagesRequest(fileKey: String, ids: [String], version: String?, scale: Double = 0.5, token: String) -> URLRequest {
        var query = [URLQueryItem(name: "ids", value: ids.joined(separator: ",")), URLQueryItem(name: "format", value: "png"),
                     URLQueryItem(name: "scale", value: String(scale))]
        if let version { query.append(URLQueryItem(name: "version", value: version)) }
        return request("images/\(fileKey)", query: query, token: token)
    }

    public struct FileVersion: Codable, Equatable, Sendable {
        public var id: String
        public var createdAt: Date
        /// 디자이너가 붙인 이름. 자동 저장은 nil이다.
        public var label: String?
        public var description: String?

        public init(id: String, createdAt: Date, label: String? = nil, description: String? = nil) {
            self.id = id
            self.createdAt = createdAt
            self.label = label
            self.description = description
        }
    }

    public static func parseVersions(_ data: Data) throws -> (versions: [FileVersion], next: URL?) {
        struct Raw: Decodable {
            struct Version: Decodable { let id: String; let created_at: String; let label: String?; let description: String? }
            struct Pagination: Decodable { let next_page: String? }
            let versions: [Version]
            let pagination: Pagination?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw Failure.malformed }
        let format = ISO8601DateFormatter()
        let versions = raw.versions.compactMap { item in
            format.date(from: item.created_at).map {
                FileVersion(id: item.id, createdAt: $0, label: item.label.flatMap { $0.isEmpty ? nil : $0 },
                            description: item.description.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        return (versions, raw.pagination?.next_page.flatMap { URL(string: $0.replacingOccurrences(of: " ", with: "%20")) })
    }

    /// 노드 ID → 이미지 주소. 그리지 못한 노드(그 버전에 없던 프레임 등)는 빠진다.
    public static func parseImages(_ data: Data) throws -> [String: URL] {
        struct Raw: Decodable {
            let err: String?
            let images: [String: String?]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw Failure.malformed }
        if let err = raw.err, !err.isEmpty { throw Failure.forbidden(err) }
        return (raw.images ?? [:]).compactMapValues { $0.flatMap(URL.init(string:)) }
    }

    public static func outlineRequest(fileKey: String, pageIDs: [String], version: String? = nil, token: String) -> URLRequest {
        nodesRequest(fileKey: fileKey, ids: pageIDs, depth: outlineDepth, version: version, token: token)
    }

    // MARK: 응답

    public struct FileInfo: Equatable, Sendable {
        public var name: String
        public var lastModified: String
        /// 파일 버전 ID. 이미지를 그 버전 그대로 그려 받을 때 쓴다.
        public var version: String?
        public var pages: [SpecExtractor.Page]
    }

    public static func parseFile(_ data: Data) throws -> FileInfo {
        struct Raw: Decodable {
            let name: String
            let lastModified: String
            let version: String?
            let document: FigmaNode
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw Failure.malformed }
        let pages = raw.document.children.filter { $0.type == "CANVAS" }.map { SpecExtractor.Page(id: $0.id, name: $0.name) }
        return FileInfo(name: raw.name, lastModified: raw.lastModified, version: raw.version, pages: pages)
    }

    /// `nodes` 응답. 지워졌거나 권한이 없는 노드는 null로 와서 뺀다.
    public static func parseNodes(_ data: Data) throws -> [String: FigmaNode] {
        struct Entry: Decodable { let document: FigmaNode? }
        struct Raw: Decodable { let nodes: [String: Entry?] }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw Failure.malformed }
        return raw.nodes.compactMapValues { $0?.document }
    }

    /// 사용자 이름(handle). 연결 확인에 보여 준다.
    public static func parseMe(_ data: Data) throws -> String {
        struct Raw: Decodable { let handle: String }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw Failure.malformed }
        return raw.handle
    }

    // MARK: 후보

    /// 화면일 수 있는 프레임. 내용을 받기 전이라 크기와 위치만 보고 고른다.
    public struct Candidate: Codable, Equatable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var pageID: String
        public var sectionName: String
        public var isChangelog: Bool
        /// 이 후보를 감싼 페이지·섹션·그룹과 뼈대에 보인 바로 아래 프레임. 링크로 고른 화면이 이 후보에 드는지 본다.
        public var within: [String]? = nil
    }

    /// 표지·간지 섹션과 화면 크기에 못 미치는 프레임은 뺀다.
    static let skippedSections: Set<String> = ["간지", "표지"]

    public static func candidates(in page: FigmaNode, pageID: String) -> [Candidate] {
        var found: [Candidate] = []
        walk(page.children, pageID: pageID, section: "", parents: [pageID], into: &found)
        return found
    }

    private static func walk(_ nodes: [FigmaNode], pageID: String, section: String, parents: [String], into found: inout [Candidate]) {
        for node in nodes where node.visible {
            if SpecExtractor.isChangelog(node) {
                found.append(Candidate(id: node.id, name: node.name, pageID: pageID, sectionName: section, isChangelog: true, within: parents))
                continue
            }
            switch node.type {
            case "SECTION":
                if skippedSections.contains(SpecExtractor.stripStatus(node.name)) {
                    // 간지 섹션에 제·개정 이력 프레임을 같이 두는 디자이너가 있다
                    for child in node.children where child.visible && SpecExtractor.isChangelog(child) {
                        found.append(Candidate(id: child.id, name: child.name, pageID: pageID, sectionName: node.name, isChangelog: true,
                                               within: parents + [node.id]))
                    }
                    continue
                }
                walk(node.children, pageID: pageID, section: node.name, parents: parents + [node.id], into: &found)
            case "GROUP":
                // 화면 프레임 여럿을 그룹으로 묶어 두기도 해서 섹션처럼 안을 본다
                walk(node.children, pageID: pageID, section: section, parents: parents + [node.id], into: &found)
            case "FRAME", "COMPONENT", "INSTANCE":
                // 뼈대만으로는 화면과 화면 여럿을 묶은 틀을 가를 수 없어 큰 프레임은 모두 후보로 받는다.
                // 틀이면 받은 뒤 SpecExtractor가 안쪽 화면을 찾는다
                guard (node.height ?? 0) >= SpecExtractor.minimumScreenHeight else { continue }
                // 틀 안쪽 화면의 링크를 붙여 넣어도 이 후보로 찾게 바로 아래 프레임도 적어 둔다
                let inner = node.children.filter { ["FRAME", "COMPONENT", "INSTANCE", "GROUP"].contains($0.type) }.map(\.id)
                found.append(Candidate(id: node.id, name: node.name, pageID: pageID, sectionName: section, isChangelog: false,
                                       within: parents + inner))
            default:
                continue
            }
        }
    }

    /// 링크로 고른 노드가 이 후보이거나, 이 후보를 감싸거나, 이 후보 바로 안에 있는지.
    public static func covers(_ nodeIDs: Set<String>, _ candidate: Candidate) -> Bool {
        nodeIDs.contains(candidate.id) || !(nodeIDs.isDisjoint(with: candidate.within ?? []))
    }

    /// 기본으로 지켜보지 않는 페이지. 구분선, 공통 컴포넌트, 시안, 백업 같은 것.
    public static func isSkippedPage(_ name: String) -> Bool {
        let trimmed = SpecExtractor.stripNote(name)
        if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "-" || $0 == "—" || $0 == " " }) { return true }
        let skipped = ["공통", "공통 컴포넌트", "컨셉 시안", "디자인 컨셉 시안", "RFP/IA", "print", "bak", "backup"]
        return skipped.contains { trimmed.caseInsensitiveCompare($0) == .orderedSame }
    }
}
