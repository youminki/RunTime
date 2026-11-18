import Cocoa

/// 창 배치가 쉬는 중인지. Rectangle 코드의 감시·단축키 자리 몇 곳이 이 값을 본다 (scripts/sync-rectangle.py의 PATCHES).
/// Rectangle의 관리자들은 앱이 끝날 때까지 사는 구조라, 끌 때는 없애지 않고 쉬게 한다.
enum WindowRuntime {
    static var paused = true
    /// 설정 화면에서 단축키를 새로 기록하는 중. 그동안 모든 단축키를 놓는다.
    static var recording = false
}
