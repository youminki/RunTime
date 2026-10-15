import SwiftUI

/// 처음 설치했을 때 한 번 뜨는 안내. 러너가 어디 있고 무엇을 누르면 되는지, 키체인 창을 왜 묻는지 알려 준다.
struct WelcomeView: View {
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                // 사용량 창 무대처럼 하늘과 언덕 위를 고른 러너가 달린다
                ItemPreview(kind: .cosmetic(.pineTrack), character: settings.character)
                    .frame(width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(" 설치했어요").font(.system(size: 20, weight: .bold))
                    Text("Claude Code로 토큰을 빨리 쓸수록 메뉴바의 러너가 빨리 달립니다.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupedSection("이렇게 써요") {
                tip("cursorarrow.click", Palette.blue, "러너 누르기", "세션·주간 사용률과 최근 30분 그래프")
                tip("cursorarrow.click.2", Palette.indigo, "오른쪽 클릭", "일별 사용량, 순위, 설정, 종료")
                tip("command", Palette.gray, GlobalHotKey.displayName, "어느 앱에서든 사용량 열기")
                tip("menubar.rectangle", Palette.orange, "러너는 메뉴바 오른쪽 끝에", "⌘를 누른 채 끌면 자리를 옮길 수 있어요")
            }

            GroupedSection("처음 한 번만", footer: "토큰은 읽기만 하고 Anthropic 말고는 어디에도 보내지 않습니다.") {
                tip("key.fill", Palette.yellow, "키체인 창에서 '항상 허용'",
                    "Claude Code 로그인 정보로 공식 사용률을 받습니다. '허용'만 누르면 다음에 또 물어요.")
                tip("bell.badge.fill", Palette.red, "알림 허용", "사용률이 80%, 95%에 닿으면 알려 드려요")
            }

            HStack {
                Button("설정 열기") {
                    openSettings()
                    close()
                }
                Spacer()
                Button("시작하기", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Palette.groupedBackground)
        .onExitCommand(perform: close)   // esc로도 닫는다
    }

    private func tip(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separator).frame(height: 0.5).padding(.leading, 46)
        }
    }
}
