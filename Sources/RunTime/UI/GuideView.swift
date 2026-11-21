import AVKit
import SwiftUI

/// 앱 안 사용법. 메뉴마다 짧은 영상으로 순서를 보여 주고, 오른쪽 단계 카드가 영상에 맞춰 따라간다.
/// 영상은 scripts/make-guide-gifs.sh가 실제 화면으로 만든다 (Sources/RunTime/Assets/Guide).
struct GuideStep: Hashable {
    let title: String
    let detail: String
}

struct GuideTopic: Identifiable, Hashable {
    enum Target: Hashable {
        case page(MainPage)
        case settings(SettingsView.Tab)
    }

    let id: String
    let group: String
    let title: String
    let icon: String
    let summary: String
    let steps: [GuideStep]
    let tips: [String]
    let target: Target
    let openTitle: String

    static func == (lhs: GuideTopic, rhs: GuideTopic) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 이 화면을 처음 열었을 때 사용법을 권할 주제.
    static func topic(for page: MainPage) -> GuideTopic? {
        let id: String
        switch page {
        case .usage: id = "usage"
        case .runners: id = "runners"
        case .workLog: id = "workLog"
        case .redmine: id = "redmine"
        case .design: id = "figma"
        case .hosts: id = "hosts"
        case .settings, .guide: return nil
        }
        return all.first { $0.id == id }
    }

    var videoURL: URL? { Bundle.assets.url(forResource: id, withExtension: "mp4", subdirectory: "Assets/Guide") }

    /// 영상에서 단계마다 시작하는 시각(초).
    var stepTimes: [Double] {
        guard let url = Bundle.assets.url(forResource: id, withExtension: "json", subdirectory: "Assets/Guide"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let times = json["steps"] as? [Double] else { return [] }
        return times
    }

    static let all: [GuideTopic] = [
        GuideTopic(
            id: "usage", group: "Claude", title: "사용량", icon: "gauge.medium",
            summary: "Claude Code를 얼마나 썼는지, 한도까지 얼마나 남았는지 한눈에 봐요.",
            steps: [
                GuideStep(title: "세션과 주간 사용률", detail: "왼쪽은 최근 5시간, 오른쪽은 이번 주에 쓴 양이에요. 100%에 가까울수록 한도가 얼마 안 남은 거예요."),
                GuideStep(title: "흰 눈금은 지난 시간", detail: "파란 막대가 눈금보다 앞서 있으면 시간에 비해 빨리 쓰고 있다는 뜻이에요."),
                GuideStep(title: "최근 30분 그래프", detail: "마우스를 올리면 그 시각에 쓴 양을 볼 수 있어요."),
                GuideStep(title: "아래 단추", detail: "업무 일지, 새로고침, 설정, 종료를 여기서 눌러요."),
            ],
            tips: ["메뉴바의 펫을 누르면 이 창이 열려요.", "사용률이 --로 보이면 공식 값을 못 받은 거예요. 이유는 창 맨 아래에 나와요."],
            target: .page(.usage), openTitle: "사용량 열기"),
        GuideTopic(
            id: "runners", group: "Claude", title: "펫과 게임", icon: "hare",
            summary: "메뉴바에서 달리는 펫을 고르고, 직접 만들고, 꾸며요.",
            steps: [
                GuideStep(title: "펫 고르기", detail: "‘내 펫’에서 마음에 드는 펫을 누르면 바로 바뀌어요."),
                GuideStep(title: "새 펫 만들기", detail: "만들고 싶은 모습을 적고 ‘만들기’를 누르면 이 Mac이 그려 줘요. 6~8분쯤 걸려요."),
                GuideStep(title: "Petdex에서 받기", detail: "이미 만들어진 펫 5천여 종 가운데 골라 받을 수 있어요."),
                GuideStep(title: "꾸미기와 게임", detail: "‘꾸미기’에서 배경과 꼬리를 바꾸고, 오른쪽 위 ‘달리기’·‘비행’으로 게임을 해요."),
            ],
            tips: ["‘화면에 펫 꺼내기’를 누르면 펫이 화면 가장자리를 돌아다녀요.", "펫 만들기는 처음에 그림 모델(약 5GB)을 한 번 받아요."],
            target: .page(.runners), openTitle: "펫 화면 열기"),
        GuideTopic(
            id: "workLog", group: "업무", title: "업무 일지", icon: "checklist",
            summary: "한 일을 적어 두면 일일·주간 보고 글이 만들어져요.",
            steps: [
                GuideStep(title: "한 일 적기", detail: "프로젝트 아래 ‘할 일 추가’에 적고 Enter를 눌러요. 끝에 (60%)를 붙이면 진행률도 저장돼요."),
                GuideStep(title: "진행 상태 바꾸기", detail: "줄 왼쪽 동그라미를 눌러서 완료나 진행률로 바꿔요."),
                GuideStep(title: "보고 글 복사하기", detail: "오른쪽 복사 단추를 누르면 보고 글이 복사돼요. 메신저에 붙여 넣으면 끝이에요."),
            ],
            tips: ["다른 앱을 쓰다가 한 줄만 적고 싶으면 펫을 오른쪽 클릭해서 ‘업무 한 줄 적기’를 눌러요.", "위쪽 ‘주간’, ‘월간’ 탭에서 같은 기록으로 주간·월간 보고를 만들어요."],
            target: .page(.workLog), openTitle: "업무 일지 열기"),
        GuideTopic(
            id: "redmine", group: "업무", title: "레드마인 연결", icon: "list.bullet.rectangle.portrait",
            summary: "처음 한 번만 연결하면, 앱에서 내 일감을 보고 진척률과 댓글을 올릴 수 있어요.",
            steps: [
                GuideStep(title: "설정에서 레드마인 열기", detail: "설정 > 연동 > 레드마인 칸으로 가요."),
                GuideStep(title: "레드마인 주소 넣기", detail: "https로 시작하는 우리 회사 레드마인 주소를 적어요."),
                GuideStep(title: "API 키 붙여넣기", detail: "레드마인의 ‘내 계정 > API 접근 키’를 복사해 와서 ‘붙여넣기’를 누르면 연결까지 확인해요."),
                GuideStep(title: "Claude Code를 쓰고 있다면", detail: "‘Claude 설정에서 가져오기’ 한 번으로 주소와 키를 옮겨 올 수 있어요."),
            ],
            tips: ["연결하면 왼쪽 막대의 ‘레드마인’에서 일감을 보고 고쳐요.", "키는 이 Mac의 키체인에만 저장하고, 그 레드마인에만 보내요."],
            target: .settings(.workLog), openTitle: "레드마인 설정 열기"),
        GuideTopic(
            id: "figma", group: "업무", title: "피그마 연결", icon: "paintpalette",
            summary: "화면설계서에서 어느 화면이 언제 바뀌었는지 날짜별로 모아 줘요.",
            steps: [
                GuideStep(title: "설정에서 피그마 열기", detail: "설정 > 연동 > 피그마 칸으로 가요."),
                GuideStep(title: "피그마 토큰 넣기", detail: "피그마 설정 > Security > Personal access tokens에서 만든 토큰을 넣어요."),
                GuideStep(title: "화면설계서 링크 붙여넣기", detail: "지켜볼 피그마 링크를 복사해 와서 ‘붙여넣기’를 눌러요."),
                GuideStep(title: "‘가져오기’ 누르기", detail: "이때가 기준이 되고, 다음부터 바뀐 화면이 쌓여요. 왼쪽 막대의 ‘피그마’에서 봐요."),
            ],
            tips: ["마크업할 메뉴가 정해져 있으면 그 메뉴만 가져오는 게 빨라요.", "‘Claude 문구’ 단추는 바뀐 내용을 Claude Code에 붙여 넣을 글로 복사해 줘요."],
            target: .settings(.figma), openTitle: "피그마 설정 열기"),
        GuideTopic(
            id: "hosts", group: "도구", title: "호스트", icon: "network",
            summary: "개발·스테이징 서버 주소(/etc/hosts)를 스위치로 켜고 꺼요.",
            steps: [
                GuideStep(title: "스위치로 켜고 끄기", detail: "끄면 줄이 지워지지 않고 앞에 #만 붙어서, 언제든 다시 켤 수 있어요."),
                GuideStep(title: "저장하기", detail: "고친 내용은 아래 ‘저장…’을 눌러야 적용돼요. 바뀌는 줄을 보여 주고 관리자 암호를 물어봐요."),
                GuideStep(title: "되돌리기", detail: "저장할 때마다 이전 판이 백업돼요. 위쪽 시계 단추에서 골라 되돌려요."),
            ],
            tips: ["‘추가’(⌘N)에 메신저에서 받은 hosts 줄을 그대로 붙여 넣어도 돼요.", "‘접속 확인’은 켜 둔 주소가 실제로 열리는지 알려 줘요."],
            target: .page(.hosts), openTitle: "호스트 열기"),
        GuideTopic(
            id: "clipboard", group: "도구", title: "클립보드 기록", icon: "doc.on.clipboard",
            summary: "복사한 것을 쌓아 두고, 나중에 골라서 다시 붙여 넣어요.",
            steps: [
                GuideStep(title: "⇧⌘V로 열기", detail: "복사해 둔 텍스트, 이미지, 파일, 색이 화면 아래 띠에 최근 순으로 떠요."),
                GuideStep(title: "골라서 붙이기", detail: "방향키로 고르고 Enter를 누르면 쓰던 앱에 바로 붙어요."),
                GuideStep(title: "종류로 거르기", detail: "위쪽 단추로 링크나 이미지처럼 한 종류만 모아 봐요."),
                GuideStep(title: "초성으로 찾기", detail: "ㅇㅁ ㅇㅈ처럼 초성만 쳐도 ‘업무 일지’를 찾아 줘요."),
                GuideStep(title: "보드에 모아 두기", detail: "자주 쓰는 것은 보드에 담아 두면 지워지지 않아요."),
            ],
            tips: ["처음에는 설정 > 클립보드에서 ‘클립보드 기록 켜기’를 눌러야 해요.", "암호 관리자에서 복사한 암호는 기록하지 않아요. 기록은 이 Mac에만 있어요."],
            target: .settings(.clipboard), openTitle: "클립보드 설정 열기"),
        GuideTopic(
            id: "windows", group: "도구", title: "창 배치", icon: "rectangle.split.2x1",
            summary: "앞에 있는 창을 단축키로 반쪽, 모서리, 3분할 자리에 딱 맞춰 놓아요.",
            steps: [
                GuideStep(title: "이름이나 초성 치기", detail: "‘ㅇㅉ’처럼 초성만 쳐도 명령이 걸러져요."),
                GuideStep(title: "맨 위 명령 보기", detail: "걸러진 것 중 맨 위가 선택돼 있어요. 방향키로 다른 명령을 골라도 돼요."),
                GuideStep(title: "Enter로 적용", detail: "Enter를 누르면 앞에 있던 창이 그 자리로 가요."),
            ],
            tips: ["처음에는 설정 > 창 배치에서 켜고, 손쉬운 사용 권한을 허용해야 해요.", "자주 쓰는 명령은 단축키를 정해 두면 더 빨라요. 설정 > 창 배치에서 바꿔요."],
            target: .settings(.windows), openTitle: "창 배치 설정 열기"),
    ]
}

/// 영상 재생. 끝나면 처음부터 다시, 단계가 바뀌면 알린다.
@MainActor
final class GuidePlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var step = 0
    private var times: [Double] = []
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            let index = self.times.lastIndex { $0 <= seconds + 0.05 } ?? 0
            if index != self.step { self.step = index }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ topic: GuideTopic) {
        times = topic.stepTimes
        step = 0
        guard let url = topic.videoURL else {
            player.replaceCurrentItem(with: nil)
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    func seek(toStep index: Int) {
        guard index < times.count else { return }
        player.seek(to: CMTime(seconds: times[index] + 0.02, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func stop() { player.pause() }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

/// 앱 창 안의 사용법 화면 (설정처럼 왼쪽 목록과 오른쪽 내용). 뒤로 단추로 돌아간다.
struct GuideView: View {
    @ObservedObject var state: GuideState
    @StateObject private var player = GuidePlayer()
    var open: (GuideTopic.Target) -> Void
    private var selected: GuideTopic { state.selected }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.separator).frame(width: 0.5)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { player.load(selected) }
        .onDisappear { player.stop() }
        .onReceive(state.$selected.dropFirst()) { player.load($0) }
    }

    // MARK: 왼쪽 목록

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("사용법").font(.system(size: 17, weight: .bold)).padding(.horizontal, 10).padding(.bottom, 2)
            Text("메뉴를 고르면 영상으로 보여 드려요").font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 10)
            ForEach(["Claude", "업무", "도구"], id: \.self) { group in
                Text(group).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                ForEach(GuideTopic.all.filter { $0.group == group }) { topic in row(topic) }
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 188)
        .frame(maxHeight: .infinity)
        .background(Palette.groupedBackground)
    }

    private func row(_ topic: GuideTopic) -> some View {
        let on = selected == topic
        return Button {
            state.selected = topic
        } label: {
            HStack(spacing: 9) {
                Image(systemName: topic.icon).frame(width: 18)
                Text(topic.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.accentColor.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 오른쪽 영상과 단계

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: selected.icon).font(.system(size: 22)).foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.title).font(.system(size: 20, weight: .bold))
                    Text(selected.summary).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(selected.openTitle) { open(selected.target) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            HStack(alignment: .top, spacing: 18) {
                video
                steps
            }
            if !selected.tips.isEmpty { tips }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var video: some View {
        Group {
            if selected.videoURL != nil {
                VideoSurface(player: player.player)
            } else {
                Color.black.opacity(0.05).overlay(Text("영상을 찾지 못했어요").foregroundStyle(.secondary))
            }
        }
        .aspectRatio(776.0 / 586.0, contentMode: .fit)
        .frame(width: 540)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.separator))
        .accessibilityLabel("\(selected.title) 사용 영상")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(selected.steps.enumerated()), id: \.offset) { index, step in
                let on = player.step == index
                Button { player.seek(toStep: index) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(on ? .white : Color.accentColor)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(on ? Color.accentColor : Color.accentColor.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(step.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: player.step)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("알아 두면 좋아요").font(.system(size: 12, weight: .semibold))
            ForEach(selected.tips, id: \.self) { tip in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 1)
                    Text(tip).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.07)))
    }
}

/// 화면을 처음 열었을 때 위에 뜨는 한 줄 안내. 한 번 닫으면 그 화면에서는 다시 뜨지 않는다.
struct GuideHint: View {
    let topic: GuideTopic
    var show: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle.fill").foregroundStyle(Color.accentColor)
            Text("처음 쓰시나요? 짧은 영상으로 순서를 보여 드릴게요.").font(.system(size: 12))
            Button("영상 보기", action: show).controlSize(.small)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("닫기")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

enum GuideSeen {
    private static let key = "guideSeenTopics"
    static func has(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id) }
    static func mark(_ id: String) {
        var seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !seen.contains(id) { seen.append(id); UserDefaults.standard.set(seen, forKey: key) }
    }
}

/// 앱 창이 드는 사용법 상태: 사용법 화면에서 고른 주제와, 이번에 안내를 닫은 화면.
final class GuideState: ObservableObject {
    @Published var selected: GuideTopic = GuideTopic.all[0]
    @Published var dismissed: Set<String> = []
}
