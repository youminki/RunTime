import Carbon.HIToolbox
import SwiftUI

/// 띠 위쪽 줄의 키 안내. 자리가 모자라면 짧은 꼴로, 그래도 모자라면 숨긴다.
struct BarKeyHints: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var mode = BarMode.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(full: true)
            row(full: false)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func row(full: Bool) -> some View {
        HStack(spacing: 12) {
            if mode.tab == .accounts {
                hint("↩", "넣기")
                hint("⇧↩", "비밀번호만")
                if full { hint("⌘C", "비밀번호 복사") }
                if full { hint("⌘N", "추가") }
            } else {
                hint("↩", "붙이기")
                hint("⇧↩", "서식 없이")
                if full { hint("⌘P", "고정") }
                if full { hint("\(settings.quickPasteModifierDisplay)1~9", "바로 붙이기") }
            }
            hint("esc", "닫기")
        }
        .fixedSize()
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.chromeTextSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Theme.fieldBG, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(verbatim: label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.chromeTextTertiary)
        }
    }
}

/// 기록이 비었을 때 다음에 할 일. 멈춰 있으면 다시 기록하는 단추를 준다.
struct BarEmptyGuide: View {
    let paused: Bool
    @ObservedObject private var mode = BarMode.shared

    var body: some View {
        if mode.tab == .pinned {
            Text(verbatim: "자주 쓰는 클립은 카드의 핀 단추나 ⌘P로 고정해 두세요. 기록을 정리해도 남습니다.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.chromeTextTertiary)
        } else {
            history
        }
    }

    private var history: some View {
        VStack(spacing: 8) {
            Text(verbatim: paused ? "기록을 멈춘 상태라 복사해도 쌓이지 않습니다." : "다른 앱에서 ⌘C로 복사하면 여기에 쌓입니다.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.chromeTextTertiary)
            if paused {
                Button {
                    AppController.shared.togglePestyPause()
                    // 기록 감시는 관찰되는 값이 아니라 띠가 다시 그려지도록 알린다
                    ClipboardStore.shared.objectWillChange.send()
                } label: {
                    Label { Text(verbatim: "다시 기록") } icon: { Image(systemName: "play.circle") }
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

@MainActor
enum BarGuide {
    /// 여는 단축키가 ⌘V 계열이면 한 번 더 눌렀을 때 맨 앞 클립을 서식 없이 붙인다.
    /// ⇧⌘V는 크롬·슬랙·노션의 '서식 없이 붙여넣기'라, 그 손버릇을 그대로 살린다.
    static var repeatPastesPlain: Bool { Settings.shared.hotkeyKeyCode == kVK_ANSI_V }

    /// 카드에 보일 글. 비밀번호처럼 보이는 클립은 가린다 (미리보기 ⌘Y로는 보인다).
    static func cardText(_ item: ClipItem, query: String) -> AttributedString {
        if CardActions.looksSecret(item) {
            return AttributedString("••••••••••\n\n비밀번호로 보여 가렸고 10분 뒤 기록에서 지웁니다. 남겨 두려면 열쇠 단추로 계정에 옮기세요.")
        }
        return highlighted(item.text ?? "", query: query)
    }

    /// 카드에서 검색어에 맞은 곳을 강조한다. 카드는 열 줄까지만 보여서 앞부분만 다룬다.
    static func highlighted(_ text: String, query: String, size: CGFloat = 12.5) -> AttributedString {
        let shown = text.count > 2000 ? String(text.prefix(2000)) : text
        var out = AttributedString(shown)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return out }
        let text = shown
        for range in ClipSearch.ranges(in: text, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = Color.yellow.opacity(0.55)
            out[lower..<upper].font = .system(size: size, weight: .semibold)
        }
        return out
    }
}
