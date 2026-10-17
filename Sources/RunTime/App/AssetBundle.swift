import Foundation

extension Bundle {
    /// 앱에 넣은 리소스 번들. 예전 툴체인이 만든 Bundle.module은 Contents/Resources를 보지 않고
    /// 클론의 .build 절대 경로를 찾아서, 클론을 옮기거나 .build를 지우면 켜자마자 죽는다.
    static let assets: Bundle = Bundle.main.resourceURL
        .flatMap { Bundle(url: $0.appendingPathComponent("RunTime_RunTime.bundle")) } ?? .module
}
