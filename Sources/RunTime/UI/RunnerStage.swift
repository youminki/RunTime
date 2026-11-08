import Combine
import SwiftUI
import GameCore
import UsageCore

/// 팝오버 맨 위 무대. 러너가 시간대별 하늘 아래를 달리고, 속도에 맞춰 배경이 겹겹이 흘러간다.
/// 메뉴바와 달리 프레임을 미리 굽지 않고 화면 주사율대로 매번 계산해 그린다 (팝오버가 열려 있을 때만).
/// 오른쪽 위 '달리기'·'비행'을 누르면 무대 안에 난이도 판이 뜨고, 고르면 같은 무대에서 그 게임을 한다.
/// 게임 밖에서는 ←→·스페이스와 마우스로 러너를 움직인다.
struct RunnerStage: View {
    @ObservedObject private var decor = GameDecor.shared
    let display: SpriteDisplay
    let character: RunnerCharacter
    let theme: SpriteTheme
    var onPet: (Trick) -> Void = { _ in }
    /// 메뉴에서 고른 동작. 바뀔 때마다 무대 러너가 그 동작을 한다.
    var trickRequest: TrickRequest?
    /// 밖에서 보낸 게임 시작·난이도 판 열기 (화면 점검 도구).
    var stageAction: StageAction?
    /// Claude가 대화 차례를 마쳤다 (폴더 이름).
    var claudeFinished: AnyPublisher<TurnEndDetector.FinishedTurn, Never> = Empty().eraseToAnyPublisher()
    /// 같은 단계 안에서의 빠르기 (사용량이 많을수록 빨리).
    var tempo: Double = 1
    /// 사용량 흐름에서 반응할 순간.
    var reactions: AnyPublisher<UsageReactions.Reaction, Never> = Empty().eraseToAnyPublisher()
    /// 앱 창 러너 화면처럼 크게 띄울 때의 높이. 장면은 높이 150 기준으로 계산하고 그릴 때만 키운다.
    var height: CGFloat = RunnerStage.height

    @StateObject private var model = StageModel()
    @ObservedObject private var updater = AppUpdater.shared
    /// 무대를 누르고 있는지. 제스처가 취소돼도 저절로 풀려 게임 입력이 눌린 채 남지 않는다.
    @GestureState private var pressed = false

    static let height: CGFloat = 150

    /// 그리는 무대 자체. 식이 길면 타입 추론이 멈춰 겉에 붙이는 것과 나눈다.
    @ViewBuilder
    private var scene: some View {
        // 동작 줄이기로 그림이 멈춰 있어도 꾸미기를 고르면 바로 보이게 지켜본다
        let _ = decor.equipped
        // 게임은 사용자가 직접 켠 것이라 동작 줄이기 설정이어도 움직이고, 손맛을 위해 늘 1초 60장으로 그린다.
        // 게임이 아니면 메뉴바 러너와 같은 '움직임' 설정(12·30·60장)을 따라 팝오버를 열어 둔 동안의 CPU를 줄인다
        // 러너를 움직이거나 마우스를 올려 보는 동안에도 60장으로 그려 끊기지 않게 한다
        TimelineView(.animation(minimumInterval: 1.0 / (model.isPlaying || model.lively ? 60 : AppSettings.shared.smoothness.fps),
                                paused: model.reduceMotion && !model.isPlaying && !model.lively)) { timeline in
            Canvas { context, size in
                // 크게 띄우면 좌표계를 늘려 같은 장면을 다시 그린다. 그림을 늘리는 것과 달리 흐려지지 않는다
                let scale = size.height / Self.height
                let scene = CGSize(width: size.width / scale, height: Self.height)
                context.scaleBy(x: scale, y: scale)
                context.withCGContext { cg in
                    model.draw(cg, size: scene, date: timeline.date, display: display, character: character,
                               theme: character.theme(theme), tempo: tempo)
                }
                if let game = model.game { Self.drawOverlay(game.overlay(size: scene), in: &context) }
                if let flight = model.flight { Self.drawOverlay(flight.overlay(size: scene), in: &context) }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .overlay { bubbleLayer }
        .onReceive(claudeFinished) { model.claudeFinished(project: $0.project) }
        .onReceive(reactions) { model.react($0, display: display) }
        // 메뉴바 러너가 하는 동작(혼자 하는 장난, 깨기·잠들기 포함)을 무대도 함께 한다
        .onReceive(SpriteAnimator.performed) { model.mirrored($0) }
        .contentShape(Rectangle())
        .gesture(stageGesture)
        .onChange(of: pressed) { model.setPressed($0) }
        .onChange(of: trickRequest) { request in
            if let request { model.play(request.trick) }
        }
        .onChange(of: stageAction) { run($0?.kind) }
    }

    /// 누르는 순간과 떼는 순간을 따로 받아야 게임에서 길게 누르면 높이 뛴다.
    /// 게임 밖에서는 러너를 누르면 쓰다듬고, 끌면 들어 옮기고, 빈 땅을 누르면 그리로 걸어간다.
    private var stageGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressed) { _, state, _ in state = true }
            .onChanged { value in
                guard !model.isPlaying, model.chooser == nil else { return }
                let scale = height / Self.height
                model.drag(from: CGPoint(value.startLocation.x / scale, value.startLocation.y / scale),
                           to: CGPoint(value.location.x / scale, value.location.y / scale))
            }
            .onEnded { value in
                guard !model.isPlaying else { return }
                if model.chooser != nil {
                    model.chooser = nil
                    return
                }
                let scale = height / Self.height
                let tapped = hypot(value.translation.width, value.translation.height) < 6
                if model.release(at: CGPoint(value.location.x / scale, value.location.y / scale), tapped: tapped) == .pet {
                    onPet(model.pet(character: character, display: display))
                }
            }
    }

    private func attach(_ window: NSWindow?) {
        model.window = window
        model.mirror = onPet
        model.installRoamKeys { [model, character] kind in model.startChosen(kind, character: character) }
    }

    private func hover(_ inside: Bool) {
        model.setPointer(inside)
        model.hovering = inside
    }

    private func run(_ kind: StageAction.Kind?) {
        switch kind {
        case .game: model.startGame(character: character)
        case .flight: model.startFlight(character: character)
        case .rehearsal: model.startGame(character: character, rehearsal: true)
        case .chooseRun: model.chooser = .game
        case nil: break
        }
    }

    var body: some View {
        scene
        .overlay { chooserLayer }
        .overlay(alignment: .bottomLeading) { roamHint }
        .overlay(alignment: .topTrailing) { controls }
        .overlay { updateLayer }
        .onChange(of: updater.state) { state in
            if state == .updating, !updater.isSilent { model.say("새 버전 받아 올게요", seconds: 2.6) }
        }
        .background(WindowReader(found: attach))
        .onHover(perform: hover)
        .onAppear {
            model.greet(display: display)
        }
        .onDisappear {
            model.setPointer(false)   // 커서를 올린 채 팝오버가 닫혀도 짝을 맞춘다
            model.hovering = false
            model.popoverClosed()
        }
        .tip(model.isPlaying ? (model.flight != nil ? "누르는 동안 올라가요. →·오른쪽 클릭 가속, esc 나가기"
              : "스페이스·↑·클릭 점프(길게 누르면 높이), ↓·오른쪽 클릭 숙이기, ←→ 이동, G 고스트와 겨루기, esc 나가기") : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(character.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPet(model.pet(character: character, display: display)) }
    }

    /// 오른쪽 위 작은 단추: 게임 고르기, 게임 중에는 소리와 나가기.
    private var controls: some View {
        HStack(spacing: 4) {
            if !model.isPlaying {
                StageButton(systemImage: "figure.run", title: "달리기", selected: model.chooser == .game) {
                    model.chooser = model.chooser == .game ? nil : .game
                }
                .tip("장애물을 넘으며 끝없이 달려요")
                StageButton(systemImage: "paperplane.fill", title: "비행", selected: model.chooser == .flight) {
                    model.chooser = model.chooser == .flight ? nil : .flight
                }
                .tip("누르는 동안 올라가며 끝없이 날아요")
            } else {
                StageButton(systemImage: model.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            label: model.soundOn ? "효과음 끄기" : "효과음 켜기") {
                    model.toggleSound()
                }
                .tip(model.soundOn ? "효과음 끄기" : "효과음 켜기")
                StageButton(systemImage: "xmark", label: "게임 나가기") { model.endGame() }
                    .tip("게임 나가기 (esc)")
            }
        }
        .padding(7)
    }

    static func drawOverlay(_ overlay: (panels: [GameSession.Panel], labels: [GameSession.Label]),
                                    in context: inout GraphicsContext) {
        for panel in overlay.panels {
            let shape = Path(roundedRect: panel.rect, cornerRadius: 8, style: .continuous)
            context.fill(shape, with: .color(Color(white: 0.07).opacity(0.93)))
            context.stroke(shape, with: .color(.white.opacity(0.1)), lineWidth: 1)
        }
        // 러너·하늘 위에서도 읽히게 글자 아래로 1pt 그림자를 둔다 (번지지 않는 또렷한 그림자)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.55), radius: 0, x: 0, y: 1))
            for label in overlay.labels {
                var context = layer
                context.opacity = label.opacity
                context.draw(label.text, at: label.position, anchor: label.anchor)
            }
        }
    }

    /// 난이도 판. 장면과 함께 키워 게임 안내 판과 같은 크기로 보인다.
    @ViewBuilder
    private var chooserLayer: some View {
        if let kind = model.chooser, !model.isPlaying {
            GeometryReader { geo in
                let scale = min(geo.size.height / Self.height, 2.2)
                DifficultyCard(kind: kind, scale: scale,
                               choose: { model.startChosen(kind, character: character) },
                               close: { model.chooser = nil })
                    .position(x: geo.size.width / 2, y: geo.size.height / 2 + 6 * scale)
            }
            .background(Color.black.opacity(0.28))
            // 판 밖을 누르면 닫는다 (판 안의 단추가 먼저 받는다)
            .contentShape(Rectangle())
            .onTapGesture { model.chooser = nil }
            .transition(.opacity)
        }
    }

    /// 게임 밖에서 러너를 움직이는 방법. 마우스를 올렸을 때만 왼쪽 아래에 옅게 보인다.
    @ViewBuilder
    private var roamHint: some View {
        if model.hovering, !model.isPlaying, model.chooser == nil, model.bubble == nil {
            HStack(spacing: 8) {
                hintItem("←→", "걷기")
                hintItem("스페이스", "점프")
                hintItem("끌기", "옮기기")
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.black.opacity(0.42)))
            .padding(8)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func hintItem(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
            Text(action).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
        }
    }

    private var bubbleLayer: some View {
        GeometryReader { geo in
            if let text = model.bubble {
                // 크게 띄운 무대에서도 러너 머리 옆에 오게 장면 배율만큼 옮기고 키운다
                let scale = geo.size.height / Self.height
                SpeechBubble(text: text, scale: scale)
                    .position(x: min(geo.size.width * model.bubbleX + 74 * scale, geo.size.width - 64 * scale), y: 24 * scale)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.bubble)
        .allowsHitTesting(false)
    }

    /// 자동으로 받지 못한 새 버전은 러너가 누르면 업데이트하는 말풍선으로 알리고, 눌러서 설치하는 동안에는 아래에 진행 판을 띄운다.
    /// 자동 업데이트는 조용히 한다.
    /// 다른 말풍선이 뜬 동안에는 그 말이 끝날 때까지 비켜 준다. 무대 쓰다듬기 제스처보다 위에 있어야 눌린다.
    private var updateLayer: some View {
        GeometryReader { geo in
            let scale = geo.size.height / Self.height
            if updater.hasPendingUpdate, model.bubble == nil, !model.isPlaying {
                UpdateBubble(text: updater.pendingPrompt) { updater.update() }
                    .tip(updater.incoming.isEmpty ? "누르면 바로 업데이트해요"
                         : "누르면 바로 업데이트해요\n" + updater.incoming.map { "· \($0)" }.joined(separator: "\n"))
                    .scaleEffect(scale)
                    // 오른쪽 위 게임 단추 줄 아래에 둔다
                    .position(x: min(geo.size.width * StageModel.runnerAnchor + 100 * scale, geo.size.width - 100 * scale),
                              y: 46 * scale)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
            if updater.state == .updating, !updater.isSilent, !model.isPlaying, let progress = updater.progress {
                VStack {
                    Spacer()
                    UpdateProgressPanel(progress: progress)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: updater.hasPendingUpdate)
        .animation(.easeOut(duration: 0.2), value: updater.state == .updating)
    }
}

/// 말풍선. 그림자 없이 얇은 테두리만.
private struct SpeechBubble: View {
    let text: String
    /// 무대를 키운 배율. 다 그린 뒤 키우면 글자가 흐려져 크기에 곱해 그린다.
    var scale: CGFloat = 1

    var body: some View {
        Text(text)
            .font(.system(size: (12 * scale).rounded(), weight: .semibold))
            .foregroundStyle(Color(nsColor: NSColor(hex: 0x1F1C26)))
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 4 * scale)
            .background(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous).fill(Color(white: 0.97)))
            .overlay(alignment: .bottomLeading) {
                Triangle().fill(Color(white: 0.97)).frame(width: 7 * scale, height: 5 * scale).offset(x: 9 * scale, y: 4.5 * scale)
            }
            .fixedSize()
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}

/// 무대 위 반투명 작은 단추. 고른 단추는 금색 테두리로 표시한다.
private struct StageButton: View {
    let systemImage: String
    var title: String?
    /// 화면 읽기 프로그램이 읽을 이름. 글자 없는 단추에 붙인다.
    var label: String?
    var selected = false
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                if let title { Text(title).font(.system(size: 12, weight: .semibold)) }
            }
            .foregroundStyle(selected ? GameKit.gold : .white.opacity(hover.on ? 1 : 0.85))
            .padding(.horizontal, title == nil ? 6 : 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.black.opacity(hover.on || selected ? 0.55 : 0.32)))
            .overlay(Capsule().strokeBorder(selected ? GameKit.gold.opacity(0.8) : Color.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .accessibilityLabel(label ?? title ?? "")
    }
}

/// 무대가 놓인 창. 게임을 켤 때 팝오버 창이 키 입력을 받게 한다.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 무대 상태와 그리기

final class StageModel: ObservableObject {
    @Published var bubble: String?
    /// 말풍선을 띄울 가로 자리 (무대 폭 대비). 말할 때의 러너 자리를 따른다.
    @Published private(set) var bubbleX: CGFloat = StageModel.runnerAnchor
    /// 열어 둔 난이도 판 (달리기·비행).
    @Published var chooser: StageAction.Kind?
    /// 마우스를 올렸는지. 움직이는 법을 보이고 60장으로 그린다.
    @Published var hovering = false { didSet { updateLively() } }
    /// 러너를 움직이는 중이라 1초 60장으로 그려야 하는지.
    @Published private(set) var lively = false
    @Published private(set) var game: GameSession?
    @Published private(set) var flight: FlightSession?
    @Published private(set) var soundOn = GameSound.shared.isOn
    weak var window: NSWindow?
    /// 게임 때문에 앱을 앞으로 가져왔는지. 팝오버가 닫히면 키 입력을 원래 앱에 돌려준다.
    private var activatedForGame = false
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// 러너가 서는 가로 위치 (무대 폭 대비).
    static let runnerAnchor: CGFloat = 0.34

    // 아래는 그리는 동안에만 바뀌는 시계 상태. 화면 갱신을 일으키지 않도록 @Published가 아니다.
    private var lastDate: Date?
    private var scroll: CGFloat = 0
    private var speed: CGFloat = 0
    private var gait: CGFloat = 0
    private var trick: (kind: Trick, start: Date)?
    private var lastDisplay: SpriteDisplay?
    private var bubbleToken = 0
    private var lastHop: CGFloat = 0
    /// 최근에 누른 때. 짧은 사이에 여러 번 누르면 간지러워하고 잠깐 쉰다.
    private var pets: [Date] = []
    private var ticklishUntil = Date.distantPast
    private let extras = StageExtras()

    private var pointerPushed = false

    // 게임 밖 자유 이동. 그리는 동안 바뀌는 값이라 @Published가 아니다
    /// 기본 자리에서 옮긴 거리와 땅에서 뜬 높이(pt), 오르는 속도.
    private var roamX: CGFloat = 0
    private var lift: CGFloat = 0
    private var liftSpeed: CGFloat = 0
    /// 보는 쪽 (1 오른쪽, -1 왼쪽).
    private var facing: CGFloat = 1
    private var roamGait: CGFloat = 0
    /// 누르고 있는 방향 키와 걸어갈 자리(기본 자리 기준 x).
    private var leftHeld = false, rightHeld = false
    private var walkTarget: CGFloat?
    /// 끌고 있는 손 자리(장면 좌표)와 손과 발 사이 거리. 러너 몸을 잡고 끌 때만 있다.
    private var dragPoint: CGPoint?
    private var grab: CGSize?
    private var lastInput = Date.distantPast
    private var dropHeight: CGFloat = 0
    /// 직전 프레임의 러너 몸 자리와 무대 크기 (장면 좌표). 누른 곳이 러너인지 가린다.
    private var lastBody = CGRect.zero
    private var lastSize = CGSize(width: 348, height: 150)
    private var roamMonitor: Any?
    /// 무대에서 직접 움직인 순간을 메뉴바 러너에도 알린다 (뛰기, 들기, 떨어뜨리기).
    var mirror: (Trick) -> Void = { _ in }
    /// 동료가 따라갈 러너의 지난 자리 (시각, 발 x, 뜬 높이, 보는 쪽)와 동료의 지금 자리.
    private var buddyTrail: [(time: Double, x: CGFloat, lift: CGFloat, facing: CGFloat)] = []
    private var buddyX: CGFloat?
    private var buddyLift: CGFloat = 0
    private var buddyGait: CGFloat = 0
    /// 점검 도구가 저장하지 않고 동료를 붙여 볼 때.
    var companionOverride: RunnerCharacter?

    // 점검 도구가 읽는 자리 (장면 좌표)
    var roamOffset: CGFloat { roamX }
    var liftHeight: CGFloat { lift }
    var bodyRect: CGRect { lastBody }
    var buddyPosition: CGFloat? { buddyX }

    var isPlaying: Bool { game != nil || flight != nil }

    deinit {
        if let roamMonitor { NSEvent.removeMonitor(roamMonitor) }
    }

    private func updateLively() {
        let now = Date()
        let on = hovering || dragPoint != nil || leftHeld || rightHeld || walkTarget != nil || lift > 0 || chooser != nil
            || now.timeIntervalSince(lastInput) < 1.5
        if on != lively { lively = on }
    }

    // MARK: 자유 이동

    enum Release { case pet, walked, dropped, none }

    /// 게임 밖에서 ←→로 걷고 스페이스·↑로 뛴다. 글 칸에 쓰는 중이거나 다른 창의 키는 건드리지 않는다.
    /// 난이도 판이 열려 있으면 1·2·3으로 고르고 return은 지난번 난이도, esc는 닫기.
    func installRoamKeys(start: @escaping (StageAction.Kind) -> Void) {
        guard roamMonitor == nil else { return }
        roamMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !self.isPlaying,
                  !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            return self.handle(event, start: start) ? nil : event
        }
    }

    private func handle(_ event: NSEvent, start: (StageAction.Kind) -> Void) -> Bool {
        let down = event.type == .keyDown
        if let kind = chooser {
            guard down else { return false }
            switch event.keyCode {
            case 18, 19, 20:
                let index = Int(event.keyCode) - 18
                if kind == .flight { FlightRecords.difficulty = FlightDifficulty.allCases[index] } else {
                    GameRecords.difficulty = RunDifficulty.allCases[index]
                }
                start(kind)
            case 36, 76: start(kind)
            case 53: chooser = nil
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 123: leftHeld = down
        case 124: rightHeld = down
        case 49, 126:
            if down, !event.isARepeat { jump() }
        default: return false
        }
        if down {
            walkTarget = nil
            trick = nil
        }
        touched()
        return true
    }

    /// 고른 난이도로 게임을 켠다.
    func startChosen(_ kind: StageAction.Kind, character: RunnerCharacter) {
        chooser = nil
        kind == .flight ? startFlight(character: character) : startGame(character: character)
    }

    private func touched() {
        lastInput = Date()
        updateLively()
    }

    private func jump() {
        guard lift == 0, dragPoint == nil else { return }
        liftSpeed = 250
        lift = 0.01
        trick = nil
        mirror(.hop)
    }

    /// 러너 몸을 잡고 끌면 손을 따라 들려 다닌다. 다른 곳에서 시작한 끌기는 받지 않는다.
    func drag(from start: CGPoint, to point: CGPoint) {
        if grab == nil {
            guard hypot(point.x - start.x, point.y - start.y) >= 6, lastBody.insetBy(dx: -6, dy: -6).contains(start) else { return }
            grab = CGSize(width: start.x - lastBody.midX, height: start.y - lastBody.maxY)
            trick = nil
            walkTarget = nil
            if Int.random(in: 0..<3) == 0 { say(["으앗!", "어디 가?", "높다!"].randomElement() ?? "으앗!", seconds: 1.2) }
            mirror(.wiggle)
        }
        dragPoint = point
        touched()
    }

    /// 손을 뗐다. 들고 있었으면 떨어뜨리고, 짧게 누른 곳이 러너면 쓰다듬기, 빈 땅이면 그리로 걷는다.
    func release(at point: CGPoint, tapped: Bool) -> Release {
        defer { touched() }
        if grab != nil {
            grab = nil
            dragPoint = nil
            dropHeight = lift
            liftSpeed = 0
            if lift > 18 { mirror(.dizzy) }
            return .dropped
        }
        guard tapped else { return .none }
        if lastBody.insetBy(dx: -4, dy: -4).contains(point) { return .pet }
        walkTarget = point.x - lastSize.width * Self.runnerAnchor
        trick = nil
        return .walked
    }

    /// 이번 프레임의 자유 이동. 걷는 중인지 돌려준다.
    private func updateRoam(dt: CGFloat, size: CGSize, groundY: CGFloat, base: CGFloat, date: Date) -> Bool {
        let range = (24 - base)...(size.width - 24 - base)
        var velocity: CGFloat = 0
        if let dragPoint, let grab {
            let target = min(max(dragPoint.x - grab.width - base, range.lowerBound), range.upperBound)
            velocity = (target - roamX) / max(dt, 0.001)
            roamX += (target - roamX) * min(1, dt * 18)
            // 머리가 무대 위로 나가지 않는 만큼만 들린다
            let room = max(0, lastBody.minY + lift - 6)
            let want = groundY - (dragPoint.y - grab.height)
            lift = min(max(lift + (want - lift) * min(1, dt * 18), 0), room)
            liftSpeed = 0
        } else {
            let keys: CGFloat = (rightHeld ? 1 : 0) - (leftHeld ? 1 : 0)
            if keys != 0 {
                velocity = keys * 130
            } else if let target = walkTarget {
                let gap = min(max(target, range.lowerBound), range.upperBound) - roamX
                if abs(gap) < 3 {
                    walkTarget = nil
                    if target == 0 { facing = 1 }
                } else {
                    velocity = (gap > 0 ? 1 : -1) * min(110, abs(gap) * 4 + 30)
                }
            } else if roamX != 0 || facing < 0, date.timeIntervalSince(lastInput) > 9 {
                // 한동안 두면 제자리로 걸어 돌아와 다시 앞을 보고 달린다
                walkTarget = 0
            }
            roamX = min(max(roamX + velocity * dt, range.lowerBound), range.upperBound)
            if lift > 0 || liftSpeed > 0 {
                liftSpeed -= 900 * dt
                lift += liftSpeed * dt
                let room = max(0, lastBody.minY + lift - 6)
                if lift > room { lift = room; liftSpeed = min(liftSpeed, 0) }
                if lift <= 0 {
                    lift = 0
                    // 높이서 떨어뜨리면 한 번 통 튄다
                    liftSpeed = dropHeight > 18 ? dropHeight * 3.2 : 0
                    if dropHeight > 18 { lift = 0.01 }
                    dropHeight = 0
                }
            }
        }
        if abs(velocity) > 8 { facing = velocity > 0 ? 1 : -1 }
        roamGait += dt * abs(velocity) / 90
        updateLively()
        return abs(velocity) > 8 && dragPoint == nil
    }

    func setPointer(_ inside: Bool) {
        guard inside != pointerPushed else { return }
        inside ? NSCursor.pointingHand.push() : NSCursor.pop()
        pointerPushed = inside
    }

    // MARK: 게임

    /// `rehearsal`이면 키를 받지 않고 기록도 남기지 않는다 (화면 점검 도구).
    func startGame(character: RunnerCharacter, rehearsal: Bool = false) {
        guard !isPlaying else { return }
        chooser = nil
        leftHeld = false
        rightHeld = false
        let session = GameSession(character: character, live: !rehearsal)
        session.window = { [weak self] in self?.window }
        session.onExit = { [weak self] in self?.endGame() }
        session.onFinish = { [weak self] game in
            if game.isNewRecord { DispatchQueue.main.async { self?.say("신기록!", seconds: 1.6) } }
        }
        game = session
        bubble = nil
        guard !rehearsal else { return }
        takeKeys()
    }

    func startFlight(character: RunnerCharacter, rehearsal: Bool = false) {
        guard !isPlaying else { return }
        chooser = nil
        leftHeld = false
        rightHeld = false
        let session = FlightSession(difficulty: FlightRecords.difficulty, character: character, live: !rehearsal)
        session.window = { [weak self] in self?.window }
        session.onExit = { [weak self] in self?.endGame() }
        flight = session
        bubble = nil
        if !rehearsal { takeKeys() }
    }

    /// 메뉴바 앱은 평소 앞에 나서지 않으니, 게임을 켤 때만 팝오버 창이 키를 받게 한다.
    private func takeKeys() {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            activatedForGame = true
        }
        window?.makeKey()
    }

    func endGame() {
        flight = nil
        game = nil
        // 게임 전에 옮겨 둔 자리는 판이 끝나면 처음 자리에서 다시 시작한다
        roamX = 0
        lift = 0
        liftSpeed = 0
        facing = 1
        // 게임이 scroll을 판 거리로 바꿔 놓아 길 위 물건 자리가 어긋난다
        extras.reset()
    }

    func popoverClosed() {
        endGame()
        leftHeld = false
        rightHeld = false
        dragPoint = nil
        grab = nil
        chooser = nil
        // 무대가 닫히며 다른 창(앱 창)을 누른 것이면 그 창이 앞에 있어야 해서 앱을 물리지 않는다
        if activatedForGame, NSApp.isActive, NSApp.keyWindow == nil || NSApp.keyWindow === window { NSApp.deactivate() }
        activatedForGame = false
    }

    func toggleSound() {
        GameSound.shared.isOn.toggle()
        soundOn = GameSound.shared.isOn
    }

    func setPressed(_ down: Bool) {
        down ? game?.press() : game?.release()
        down ? flight?.press() : flight?.release()
    }

    // MARK: 말풍선·장난

    func greet(display: SpriteDisplay) {
        AppUpdater.shared.checkIfStale()
        // 업데이트 소식이 있으면 인사 대신 먼저 말한다
        if let update = AppUpdater.shared.takeBubble() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.say(update, seconds: 2.8)
            }
            return
        }
        let hour = Calendar.current.component(.hour, from: Date())
        let line: String
        switch display {
        case .tired, .alert, .straining, .normal(.sleeping): line = Self.phrases(for: display).randomElement() ?? ""
        default:
            switch hour {
            case 5..<11: line = "좋은 아침"
            case 11..<14: line = "점심은 먹었어?"
            case 14..<18: line = "오후도 힘내"
            case 18..<22: line = "저녁 코딩 중?"
            default: line = "늦었어, 쉬엄쉬엄"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.say(line, seconds: 2.4) }
    }

    /// 메뉴바 러너가 시작한 동작. 무대가 보낸 동작이 돌아온 것이면 처음부터 다시 하지 않는다.
    func mirrored(_ kind: Trick) {
        guard !isPlaying, dragPoint == nil, lift == 0 else { return }
        if let trick, trick.kind == kind, Date().timeIntervalSince(trick.start) < 0.4 { return }
        play(kind)
    }

    /// 메뉴에서 고른 동작을 무대 러너도 한다. 게임 중에는 판을 방해하지 않게 하지 않는다.
    func play(_ kind: Trick, at date: Date = Date()) {
        guard !isPlaying else { return }
        trick = (kind, date)
    }

    /// 누르면 장난 하나 + 말풍선. 메뉴바 러너도 같은 장난을 하도록 고른 동작을 돌려준다.
    func pet(character: RunnerCharacter, display: SpriteDisplay) -> Trick {
        let kind: Trick
        switch display {
        case .normal(.sleeping): kind = .wakeUp
        case .tired, .alert, .straining: kind = .shake
        default:
            let now = Date()
            pets = pets.filter { now.timeIntervalSince($0) < 3 } + [now]
            if now < ticklishUntil {
                // 간지러워하는 동안에는 동작을 끊지 않는다
                return trick?.kind ?? .greet
            }
            if pets.count >= 4 {
                pets.removeAll()
                ticklishUntil = now.addingTimeInterval(2.5)
                trick = (.dizzy, now)
                say("간지러워!", seconds: 1.6)
                return .dizzy
            }
            kind = Trick.petting.filter { $0 != trick?.kind }.randomElement() ?? .greet
        }
        trick = (kind, Date())
        GameSound.shared.play(.pet)
        pat(at: Date())
        // 매번 말하면 시끄러워 가끔만 소리를 낸다
        if Int.random(in: 0..<4) == 0 { say("\(character.sound)!", seconds: 1.4) }
        return kind
    }

    /// 사용량 흐름에 반응한다. 메뉴바 러너와 같은 동작을 하고 무슨 일인지 말풍선으로 알린다. 게임 중에는 판을 방해하지 않는다.
    func react(_ reaction: UsageReactions.Reaction, display: SpriteDisplay) {
        guard !isPlaying, AppSettings.shared.tricksEnabled, !display.isLimited else { return }
        play(SpriteAnimator.trick(for: reaction))
        let line = switch reaction {
        case .burst: "갑자기 바빠졌네"
        case .resumed: "다시 시작이다"
        case .sessionMilestone(let percent): "세션 \(percent)% 썼어"
        case .multitask(let count): "\(count)곳에서 같이 일하는 중"
        case .newSession: "새 세션, 한도 초기화"
        }
        say(line, seconds: 2.4)
    }

    /// 게임 중이면 판을 멈추지 않고 화면 위에 알리고, 아니면 러너가 말한다.
    func claudeFinished(project: String?) {
        let name = project.map { " · \($0)" } ?? ""
        if let game, game.game.phase == .playing {
            game.announce("Claude 작업 끝\(name)")
        } else if let flight, flight.isPlaying {
            flight.announce("Claude 작업 끝\(name)")
        } else {
            play(.greet)
            say("Claude가 끝났어요\(name)", seconds: 3)
        }
    }

    /// 머리 위로 하트가 피어오른다.
    func pat(at date: Date) {
        extras.pat(at: date.timeIntervalSinceReferenceDate)
    }

    func say(_ text: String, seconds: Double) {
        bubbleToken += 1
        let token = bubbleToken
        bubbleX = min(max((lastSize.width * Self.runnerAnchor + roamX) / max(lastSize.width, 1), 0.08), 0.9)
        bubble = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.bubbleToken == token else { return }
            self.bubble = nil
        }
    }

    static func phrases(for display: SpriteDisplay) -> [String] {
        switch display {
        case .normal(.sleeping): return ["쿨쿨", "5분만 더", "음냐"]
        case .normal(.walking): return ["산책 중", "느긋하게", "천천히 가자"]
        case .normal(.running): return ["좋은 페이스", "몸 풀렸다", "이 속도 좋아"]
        case .normal(.dashing): return ["속도 붙었다", "바람 좋다", "이대로 쭉"]
        case .normal(.rainbow): return ["숨 차다", "지금이 제일 빨라", "전력으로 가는 중"]
        case .tired: return ["헥헥", "좀 쉬자", "한도가 가까워"]
        case .alert: return ["한도 거의 다 썼어", "여기서 멈추자", "/usage 한번 봐 줘"]
        case .straining(_, critical: false): return ["헥헥, 그래도 간다", "한도가 가까워", "숨 차다"]
        case .straining(_, critical: true): return ["한도 거의 다 썼어", "곧 멈춰야 해", "/usage 한번 봐 줘"]
        }
    }

    // MARK: 한 프레임

    func draw(_ cg: CGContext, size: CGSize, date: Date, display: SpriteDisplay, character: RunnerCharacter,
              theme: SpriteTheme, tempo: Double = 1) {
        if let game {
            drawGame(game, cg, size: size, date: date, character: character, theme: theme)
            return
        }
        if let flight {
            drawFlight(flight, cg, size: size, date: date, character: character, theme: theme)
            return
        }
        let dt = CGFloat(min(max(date.timeIntervalSince(lastDate ?? date), 0), 0.1))
        lastDate = date
        let time = CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))

        updateTricks(date: date, display: display)
        let active = trick.map { (kind: $0.kind, t: CGFloat(date.timeIntervalSince($0.start) / $0.kind.duration)) }
        if let active, active.t >= 1 { trick = nil }
        let playing = active.flatMap { $0.t < 1 ? $0 : nil }

        // 속도는 목표를 향해 부드럽게 따라간다 (장난 중에는 멈춘다)
        let target: CGFloat = (playing != nil && playing?.kind != .zoom) ? 0 : Self.worldSpeed(display) * CGFloat(tempo)
        speed += (target - speed) * min(1, dt * 2.4)
        scroll += speed * dt
        if playing == nil { gait += dt / CGFloat(display.cycle) * CGFloat(tempo) }

        let groundY = size.height - 15
        let scale: CGFloat = 5.0
        lastSize = size
        let base = size.width * Self.runnerAnchor + speed / 140 * 16
        let walking = updateRoam(dt: dt, size: size, groundY: groundY, base: base, date: date)
        let runnerX = base + roamX
        let clock = date.timeIntervalSinceReferenceDate
        // 길 위 물건은 달리기를 따라 생긴다. 장난 중이거나 지쳤으면 새로 놓지 않는다
        let hop = extras.update(time: clock, scroll: scroll, speed: speed, size: size,
                                active: playing == nil && !display.isLimited)
        let origin = CGPoint(runnerX - Stage.size.width / 2 * scale, groundY - Stage.ground * scale - hop - lift)
        let sky = Sky.at(hour: Sky.hourOverride ?? Calendar.current.component(.hour, from: date), space: false)

        drawBackdrop(cg, size: size, sky: sky, time: time, groundY: groundY)
        extras.drawSky(cg, size: size, sky: sky, time: clock)
        // 한도가 가까우면 배경만 어둡게 눌러 러너와 위 게이지로 눈이 가게 한다
        // 달리는 중에는 덜 눌러 속도감이 남게 한다
        let dim: CGFloat = switch display {
        case .alert: 0.34
        case .tired: 0.16
        case .straining(_, let critical): critical ? 0.2 : 0.08
        case .normal: 0
        }
        if dim > 0 {
            cg.setFillColor(NSColor.black.withAlphaComponent(dim).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
        }

        // 러너 장면
        let rig = character.rig
        var frame = playing.map { $0.kind.frame(at: $0.t) } ?? display.motion(at: gait)
        if walking {
            frame = MotionFrame(pose: CharacterPose(activity: .run, phase: roamGait - floor(roamGait)))
        }
        // 길 위 장애물을 넘을 때 그림 러너는 점프 줄로: 오를 때 도약, 내려올 때 착지 준비
        if playing == nil, hop > 2 {
            frame.pose.jump = hop >= lastHop ? 0.3 : 0.7
        }
        // 들려 있거나 뛰는 중이면 점프 줄로 (끌려 있으면 발을 버둥거리는 도약 자세)
        if lift > 0.5 {
            frame.pose.jump = dragPoint != nil ? 0.45 : (liftSpeed > 0 ? 0.3 : 0.7)
        }
        frame.transform.scaleX = abs(frame.transform.scaleX) * facing
        lastHop = hop
        var scene = CharacterScene(rig: rig, pose: frame.pose, transform: frame.transform)
        // 공중제비처럼 무대 위로 넘치는 장면은 무대 높이 안으로 줄여 넣는다
        scene.fit(verticallyIn: (-origin.y / scale + 0.4)...((size.height - origin.y) / scale))
        let bounds = scene.placedBounds

        // 그림자: 높이 뜰수록 옅고 작아진다
        let lift = max(0, Stage.ground - bounds.maxY) + hop / scale
        let shadowW = bounds.width * scale * 0.5 * (1 - min(lift / 14, 0.6))
        cg.setFillColor(NSColor.black.withAlphaComponent(0.28 * (1 - min(lift / 10, 0.8))).cgColor)
        cg.fillEllipse(in: CGRect(x: origin.x + bounds.midX * scale - shadowW / 2, y: groundY - 2.5,
                                  width: shadowW, height: 5))

        // 데려간 동료는 러너가 0.25초 전에 있던 자리 뒤를 따라 걷고 뛰며, 러너가 보는 쪽을 함께 본다
        if let companion = companionOverride ?? GameDecor.shared.companion {
            drawBuddy(companion, cg, feetX: origin.x + bounds.midX * scale, lift: lift + hop, bodyWidth: bounds.width * scale,
                      groundY: groundY, dt: dt, clock: clock, theme: theme)
        } else {
            buddyTrail.removeAll()
            buddyX = nil
        }

        // 몸 자리(화면 좌표)를 넘겨 코인 줍기·장애물 넘기·꼬리·발먼지를 맞춘다
        let screenBody = CGRect(x: origin.x + bounds.minX * scale, y: origin.y + bounds.minY * scale,
                                width: bounds.width * scale, height: bounds.height * scale)
        lastBody = screenBody
        extras.record(back: CGPoint(screenBody.minX + screenBody.width * 0.18, screenBody.midY + screenBody.height * 0.08),
                      scroll: scroll, speed: speed, body: screenBody)
        if playing == nil {
            extras.step(gait: gait, time: clock, scroll: scroll,
                        feet: CGPoint(screenBody.minX + screenBody.width * 0.3, groundY - 1), airborne: hop > 2 || lift > 2,
                        speed: max(speed, walking ? 60 : 0))
        }
        extras.drawGround(cg, groundY: groundY, scroll: scroll, time: clock)

        cg.saveGState()
        cg.translateBy(x: origin.x, y: origin.y)
        cg.scaleBy(x: scale, y: scale)
        let loopPhase = gait - floor(gait)
        // 무대는 메뉴바보다 훨씬 커서 흐린 잔상과 빛 꼬리가 번져 보인다. 전력 질주도 공기 줄만 쓰고,
        // 그 대신 하늘 바람 줄·꼬리·발먼지로 빠르기를 보인다
        let effects = Self.stageEffects(display)
        if playing == nil {
            effects.drawLoopEffects(in: cg, scene: scene, phase: loopPhase, tint: .white, front: false)
        }
        var look = CharacterLook(rich: true, palette: theme.richPalette(rig.palette, phase: time / 6),
                                 tint: .white, outline: 0.36)
        look.alarm = display.isCritical && playing == nil
        scene.draw(in: cg, look: look)
        if playing == nil {
            effects.drawLoopEffects(in: cg, scene: scene, phase: loopPhase, tint: .white, front: true)
        }
        for effect in frame.effects {
            effect.draw(in: cg, around: bounds, tint: .white)
        }
        cg.restoreGState()
        extras.drawFront(cg, groundY: groundY, scroll: scroll, time: clock)

    }

    /// 동료 한 프레임. 러너를 조금 늦게 따라 하고, 너무 멀어지면 달려서 따라붙는다.
    private func drawBuddy(_ companion: RunnerCharacter, _ cg: CGContext, feetX: CGFloat, lift: CGFloat, bodyWidth: CGFloat,
                           groundY: CGFloat, dt: CGFloat, clock: Double, theme: SpriteTheme) {
        buddyTrail.append((clock, feetX, lift, facing))
        while buddyTrail.count > 1, clock - buddyTrail[1].time >= 0.25 { buddyTrail.removeFirst() }
        let lead = buddyTrail[0]
        let target = lead.x - lead.facing * (bodyWidth / 2 + 28)
        let x = buddyX ?? target
        let velocity = min(max((target - x) * 6, -240), 240)
        let next = x + velocity * dt
        buddyX = next
        // 동료는 러너보다 작아 같은 높이를 뛰면 붕 떠 보여서 덜 뛴다
        let height = lead.lift * 0.6
        let rising = height > buddyLift
        buddyLift = height
        let walking = abs(velocity) > 12
        let moving = walking || speed > 1
        buddyGait += (abs(velocity) + speed) * dt / 40
        let look: CGFloat = walking ? (velocity > 0 ? 1 : -1) : lead.facing
        cg.setFillColor(NSColor.black.withAlphaComponent(0.22 * (1 - min(height / 40, 0.7))).cgColor)
        cg.fillEllipse(in: CGRect(x: next - 16, y: groundY - 2.5, width: 32, height: 5))
        GameFX.drawCompanion(companion, feet: CGPoint(x: next, y: groundY - height), height: 44,
                             phase: moving ? buddyGait : CGFloat(clock / 2.4), moving: moving,
                             jump: height > 2 ? (rising ? 0.3 : 0.7) : nil, facing: look, theme: theme, cg)
    }

    /// 깨기·잠들기와 혼자 하는 장난은 메뉴바 러너가 정하고 무대는 `mirrored`로 따라 한다 (둘이 같은 동작을 하게).
    /// 여기서는 한도 경고에 처음 들어설 때 하던 장난만 끊는다. 경고 중 걷기·달리기가 바뀔 때마다 끊으면 쓰다듬기가 잘린다.
    private func updateTricks(date: Date, display: SpriteDisplay) {
        defer { lastDisplay = display }
        if let previous = lastDisplay, display.isLimited, !previous.isLimited { trick = nil }
    }

    /// 무대에서 쓸 늘 붙는 효과. 전력 질주의 빛 꼬리 대신 질주의 공기 줄을 쓴다.
    static func stageEffects(_ display: SpriteDisplay) -> SpriteDisplay {
        switch display {
        case .normal(.rainbow): .normal(.dashing)
        case .straining(.rainbow, let critical): .straining(.dashing, critical: critical)
        default: display
        }
    }

    /// 배경이 흘러가는 속도 (pt/초).
    static func worldSpeed(_ display: SpriteDisplay) -> CGFloat {
        switch display {
        case .normal(.sleeping), .tired, .alert: return 0
        case .straining(let state, _): return worldSpeed(.normal(state))
        case .normal(.walking): return 16
        case .normal(.running): return 46
        case .normal(.dashing): return 88
        case .normal(.rainbow): return 140
        }
    }

    private func drawGame(_ game: GameSession, _ cg: CGContext, size: CGSize, date: Date, character: RunnerCharacter,
                          theme: SpriteTheme) {
        game.use(character)
        game.update(date: date)
        lastDate = date
        let groundY = size.height - 15
        let time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
        scroll = CGFloat(game.game.distance)
        let sky = game.sky(hour: Sky.hourOverride ?? Calendar.current.component(.hour, from: date))
        let shake = game.shakeOffset
        cg.saveGState()
        cg.translateBy(x: shake.x, y: shake.y)
        drawBackdrop(cg, size: size, sky: sky, time: CGFloat(time), groundY: groundY)
        game.drawWorld(cg, size: size, groundY: groundY, stageAnchorX: size.width * Self.runnerAnchor, stageScale: 5,
                       theme: theme, time: time)
        cg.restoreGState()
    }

    private func drawFlight(_ flight: FlightSession, _ cg: CGContext, size: CGSize, date: Date, character: RunnerCharacter,
                            theme: SpriteTheme) {
        flight.use(character)
        flight.update(date: date)
        lastDate = date
        let groundY = size.height - 15
        let time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
        scroll = CGFloat(flight.game.x)
        let sky = Sky.at(hour: Sky.hourOverride ?? Calendar.current.component(.hour, from: date), space: false)
        Backdrop.draw(cg, size: size, sky: sky, time: CGFloat(time), groundY: groundY, scroll: scroll, speed: speed,
                      track: GameDecor.shared.equipped(.track) ?? flight.zoneTrack)
        flight.draw(cg, size: size, groundY: groundY, theme: theme, time: time)
    }

    // MARK: 배경

    private func drawBackdrop(_ cg: CGContext, size: CGSize, sky: Sky, time: CGFloat, groundY: CGFloat) {
        Backdrop.draw(cg, size: size, sky: sky, time: time, groundY: groundY, scroll: scroll, speed: speed,
                      track: GameDecor.shared.equipped(.track))
    }

    /// 0~1 고정 난수 (자리마다 같은 값).
    static func hash(_ i: Int, _ salt: Int) -> CGFloat {
        let v = sin(CGFloat(i) * 12.9898 + CGFloat(salt) * 78.233) * 43758.5453
        return v - floor(v)
    }
}

/// 시간대별 하늘색.
struct Sky {
    /// 낮 그림을 밤으로 누를 때 덮는 색.
    var top: NSColor
    var ground: NSColor
    var edge: NSColor
    var stars: CGFloat = 0
    var orbLow = false

    /// 화면 점검(--ui-shots)에서 시간대별 하늘을 찍으려고 시각을 고정한다.
    static var hourOverride: Int?

    /// 두 하늘 사이 (게임 구간이 바뀔 때).
    func mixed(with other: Sky, _ t: CGFloat) -> Sky {
        func mix(_ a: NSColor, _ b: NSColor) -> NSColor { a.blended(withFraction: t, of: b) ?? b }
        var sky = Sky(top: mix(top, other.top), ground: mix(ground, other.ground), edge: mix(edge, other.edge))
        sky.stars = stars + (other.stars - stars) * t
        sky.orbLow = t < 0.5 ? orbLow : other.orbLow
        return sky
    }

    static func at(hour: Int, space: Bool) -> Sky {
        if space {
            return Sky(top: NSColor(hex: 0x120B2E), ground: NSColor(hex: 0x170C36), edge: NSColor(hex: 0xA17BFF),
                       stars: 1)
        }
        switch hour {
        case 5..<8:
            return Sky(top: NSColor(hex: 0x4E5A86), ground: NSColor(hex: 0x3A3352), edge: NSColor(hex: 0xE6C4A8),
                       stars: 0.2, orbLow: true)
        case 8..<17:
            return Sky(top: NSColor(hex: 0x6191C4), ground: NSColor(hex: 0x4C7A5C), edge: NSColor(hex: 0xA9CDA2))
        case 17..<20:
            return Sky(top: NSColor(hex: 0x4D4373), ground: NSColor(hex: 0x372D4D), edge: NSColor(hex: 0xE9B391), orbLow: true)
        default:
            return Sky(top: NSColor(hex: 0x131A33), ground: NSColor(hex: 0x131A34), edge: NSColor(hex: 0x4E5E98), stars: 0.85)
        }
    }
}

/// 무대에 동작을 요청한다. 같은 동작을 다시 골라도 바뀐 것으로 보이게 매번 새 id를 붙인다.
struct TrickRequest: Equatable {
    let id = UUID()
    let trick: Trick
}

/// 펫 카드에서 무대에 보내는 간식 주기·포토카드. 같은 것을 다시 눌러도 바뀐 것으로 보이게 매번 새 id를 붙인다.
struct StageAction: Equatable {
    /// `chooseRun`은 달리기 난이도 판을 연다 (화면 점검 도구).
    enum Kind: Equatable { case game, flight, rehearsal, chooseRun }
    let id = UUID()
    let kind: Kind
}
