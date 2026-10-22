import DesignSyncCore
import Foundation

/// `--design-check <피그마 주소>`: 저장한 토큰으로 화면설계서를 앱 코드 그대로 받아 보고, 무엇을 읽었는지 개수만 찍는다.
/// 기록은 저장하지 않는다. 화면 내용은 찍지 않아 터미널에 회사 화면설계서가 남지 않는다.
@MainActor
enum DesignCheck {
    private actor Counter {
        private(set) var requests = 0
        func add() { requests += 1 }
    }

    static func run(url: String) {
        guard let key = FigmaFileURL.fileKey(from: url) else { finish("피그마 디자인 파일 주소가 아닙니다", ok: false) }
        guard let token = DesignSyncSettings.shared.token else { finish("피그마 토큰이 없습니다 (설정 > 디자인 > 피그마)", ok: false) }
        let counter = Counter()
        let transport: DesignSyncEngine.Transport = { request in
            await counter.add()
            return try await FigmaClient.shared.send(request)
        }
        Task {
            do {
                let started = Date()
                let outcome = try await DesignSyncEngine.run(source: DesignSource(fileKey: key), token: token, known: nil,
                                                             transport: transport, progress: { print("  " + $0) })
                guard case .captured(let capture) = outcome else { finish("처음 받기인데 받지 않았습니다", ok: false) }
                let screens = capture.screens
                let components = screens.flatMap(\.components.values)
                print("""
                파일: \(capture.fileName) · 마지막 수정 \(capture.lastModified)
                페이지 \(capture.coveredPages.count) · 화면 후보 \(capture.present.count) · 받은 후보 \(capture.fetched.count) · 화면이 아닌 후보 \(capture.fetched.count - Set(screens.map(\.candidateID)).count)
                화면 \(screens.count) (화면 ID \(Set(screens.map(\.screenID)).count)) · 메뉴 \(Set(screens.map(\.menuPath)).count) · 화면 경로 없음 \(screens.filter { $0.menuPath.isEmpty }.count)
                명세 항목 \(screens.reduce(0) { $0 + $1.items.count }) · 명세 없는 화면 \(screens.filter { $0.items.isEmpty }.count) · 목업 문구 \(screens.reduce(0) { $0 + $1.texts.count })
                컴포넌트 \(components.filter { !$0.isImage }.count) · 이미지 \(components.filter(\.isImage).count) · 제·개정 이력 \(capture.changelog.map { "\($0.count)줄" } ?? "받지 못함")
                요청 \(await counter.requests)번 · \(Int(Date().timeIntervalSince(started)))초
                """)
                // 같은 화면을 다시 견줘도 바뀐 게 없어야 하고, 파일이 그대로면 파일 정보 한 번만 묻고 끝나야 한다
                var history = DesignHistory()
                history.record(capture, at: Date())
                let unstable = screens.filter { !SpecDiff.changes(from: $0, to: $0).isEmpty }.count
                let before = await counter.requests
                let again = try await DesignSyncEngine.run(source: DesignSource(fileKey: key), token: token, known: history.files[key],
                                                           transport: transport)
                let unchanged: Bool
                if case .unchanged = again { unchanged = true } else { unchanged = false }
                print("다시 견준 거짓 변경 \(unstable) · 다시 받기: \(unchanged ? "바뀌지 않아 건너뜀" : "파일이 그새 바뀌어 다시 받음") (요청 \(await counter.requests - before)번)")
                // 변경 전·후 비교 이미지: 화면 하나를 지금 버전 그대로 그려 받아 본다 (앱이 쓰는 이미지 칸에 남는다)
                if let screen = screens.first, let version = capture.version {
                    let images = DesignImages.shared
                    images.load(fileKey: key, nodeID: screen.frameID, version: version)
                    for _ in 0..<120 {
                        if let state = images.state(fileKey: key, nodeID: screen.frameID, version: version), state != .loading { break }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    switch images.state(fileKey: key, nodeID: screen.frameID, version: version) {
                    case .ready(let url):
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                        let size = images.image(url).map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "?"
                        print("비교 이미지: 받음 \(size) · \(bytes / 1024)KB (버전 \(version.prefix(6))…)")
                    case .missing(let reason): print("비교 이미지: 받지 못함 · \(reason)")
                    default: print("비교 이미지: 60초 안에 받지 못함")
                    }
                }
                finish("완료", ok: true)
            } catch let failure as FigmaAPI.Failure {
                finish(failure.message, ok: false)
            } catch {
                finish(error.localizedDescription, ok: false)
            }
        }
    }

    private static func finish(_ message: String, ok: Bool) -> Never {
        print(ok ? message : "실패: " + message)
        exit(ok ? 0 : 1)
    }
}
