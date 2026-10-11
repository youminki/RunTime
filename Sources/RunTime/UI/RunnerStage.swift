import Combine
import SwiftUI
import UsageCore

/// 팝오버 맨 위 무대. 러너가 시간대별 하늘 아래를 달리고, 속도에 맞춰 배경이 겹겹이 흘러간다.
/// 메뉴바와 달리 프레임을 미리 굽지 않고 화면 주사율대로 매번 계산해 그린다 (팝오버가 열려 있을 때만).
/// 오른쪽 위 '게임'을 누르면 같은 무대에서 장애물 피하기 게임(GameSession)을 한다.
struct RunnerStage: View {
    let display: SpriteDisplay
    let character: RunnerCharacter
    let theme: SpriteTheme
    var onPet: (Trick) -> Void = { _ in }
    var openLeaderboard: () -> Void = {}
    /// 메뉴에서 고른 동작. 바뀔 때마다 무대 러너가 그 동작을 한다.
    var trickRequest: TrickRequest?
    /// Claude가 대화 차례를 마쳤다 (폴더 이름).
    var claudeFinished: AnyPublisher<TurnEndDetector.FinishedTurn, Never> = Empty().eraseToAnyPublisher()
    /// 같은 단계 안에서의 빠르기 (사용량이 많을수록 빨리).
    var tempo: Double = 1
    /// 사용량 흐름에서 반응할 순간.
    var reactions: AnyPublisher<UsageReactions.Reaction, Never> = Empty().eraseToAnyPublisher()

    @StateObject private var model = StageModel()
    /// 무대를 누르고 있는지. 제스처가 취소돼도 저절로 풀려 게임 입력이 눌린 채 남지 않는다.
    @GestureState private var pressed = false

    static let height: CGFloat = 150

    var body: some View {
        // 게임은 사용자가 직접 켠 것이라 동작 줄이기 설정이어도 움직이고, 손맛을 위해 늘 1초 60장으로 그린다.
        // 게임이 아니면 메뉴바 러너와 같은 '움직임' 설정(12·30·60장)을 따라 팝오버를 열어 둔 동안의 CPU를 줄인다
        TimelineView(.animation(minimumInterval: 1.0 / (model.game == nil ? AppSettings.shared.smoothness.fps : 60),
                                paused: model.reduceMotion && model.game == nil)) { timeline in
            Canvas { context, size in
                context.withCGContext { cg in
                    model.draw(cg, size: size, date: timeline.date, display: display, character: character,
                               theme: character.theme(theme), tempo: tempo)
                }
                if let game = model.game { Self.drawOverlay(game.overlay(size: size), in: &context) }
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .overlay { bubbleLayer }
        .onReceive(claudeFinished) { model.claudeFinished(project: $0.project) }
        .onReceive(reactions) { model.react($0, display: display) }
        .contentShape(Rectangle())
        // 누르는 순간과 떼는 순간을 따로 받아야 게임에서 길게 누르면 높이 뛴다
        .gesture(DragGesture(minimumDistance: 0)
            .updating($pressed) { _, state, _ in state = true }
            .onEnded { value in
                // 게임 밖에서는 끌지 않고 누른 것만 쓰다듬기로 받는다
                guard model.game == nil, hypot(value.translation.width, value.translation.height) < 6 else { return }
                onPet(model.pet(character: character, display: display))
            })
        .onChange(of: pressed) { model.setPressed($0) }
        .onChange(of: trickRequest) { request in
            if let request { model.play(request.trick) }
        }
        .overlay(alignment: .topTrailing) { controls }
        .background(WindowReader { model.window = $0 })
        .onHover { model.setPointer($0) }
        .onAppear {
            model.listenForNews()
            model.greet(display: display)
        }
        .onDisappear {
            model.setPointer(false)   // 커서를 올린 채 팝오버가 닫혀도 짝을 맞춘다
            model.popoverClosed()
            LeaderboardFeed.shared.stageDisappeared()
        }
        .help(model.game == nil ? "러너를 누르면 장난을 쳐요"
              : "스페이스·↑·클릭 점프(길게 누르면 높이), ↓·오른쪽 클릭 숙이기, ←→ 이동, G·1·2 고스트와 겨루기, esc 나가기")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(character.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPet(model.pet(character: character, display: display)) }
    }

    /// 오른쪽 위 작은 단추: 게임 켜기, 게임 중에는 소리와 나가기.
    private var controls: some View {
        HStack(spacing: 4) {
            if Leaderboard.shared.isAvailable {
                StageButton(systemImage: "trophy.fill", label: "순위", action: openLeaderboard).help("순위")
            }
            if model.game == nil {
                StageButton(systemImage: "gamecontroller.fill", title: "게임") { model.startGame(character: character) }
                    .help("장애물 피하기 게임 (최고 \(GameRecords.best)점)")
            } else {
                StageButton(systemImage: model.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            label: model.soundOn ? "효과음 끄기" : "효과음 켜기") {
                    model.toggleSound()
                }
                .help(model.soundOn ? "효과음 끄기" : "효과음 켜기")
                StageButton(systemImage: "xmark", label: "게임 나가기") { model.endGame() }
                    .help("게임 나가기 (esc)")
            }
        }
        .padding(7)
    }

    static func drawOverlay(_ overlay: (panels: [GameSession.Panel], labels: [GameSession.Label]),
                                    in context: inout GraphicsContext) {
        for panel in overlay.panels {
            let shape = Path(roundedRect: panel.rect, cornerRadius: 10, style: .continuous)
            context.fill(shape, with: .color(.black.opacity(0.5)))
            context.stroke(shape, with: .color(.white.opacity(0.12)), lineWidth: 1)
        }
        for label in overlay.labels {
            context.draw(label.text, at: label.position, anchor: label.anchor)
        }
    }

    private var bubbleLayer: some View {
        GeometryReader { geo in
            if let text = model.bubble {
                SpeechBubble(text: text)
                    .position(x: min(geo.size.width * StageModel.runnerAnchor + 74, geo.size.width - 64), y: 24)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.bubble)
        .allowsHitTesting(false)
    }
}

/// 말풍선. 그림자 없이 얇은 테두리만.
private struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(nsColor: NSColor(hex: 0x1F1C26)))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.97)))
            .overlay(alignment: .bottomLeading) {
                Triangle().fill(Color(white: 0.97)).frame(width: 7, height: 5).offset(x: 9, y: 4.5)
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

/// 무대 위 반투명 작은 단추.
private struct StageButton: View {
    let systemImage: String
    var title: String?
    /// 화면 읽기 프로그램이 읽을 이름. 글자 없는 단추에 붙인다.
    var label: String?
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                if let title { Text(title).font(.system(size: 10.5, weight: .semibold)) }
            }
            .foregroundStyle(.white.opacity(hover.on ? 1 : 0.85))
            .padding(.horizontal, title == nil ? 6 : 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.black.opacity(hover.on ? 0.5 : 0.32)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
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
    @Published private(set) var game: GameSession?
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
    private var nextIdle = Date().addingTimeInterval(5)
    private var lastIdleTrick: Trick?
    private var bubbleToken = 0

    private var pointerPushed = false

    func setPointer(_ inside: Bool) {
        guard inside != pointerPushed else { return }
        inside ? NSCursor.pointingHand.push() : NSCursor.pop()
        pointerPushed = inside
    }

    // MARK: 게임

    /// `rehearsal`이면 키를 받지 않고 기록도 남기지 않는다 (화면 점검 도구).
    func startGame(character: RunnerCharacter, rehearsal: Bool = false) {
        guard game == nil else { return }
        let session = GameSession(character: character, live: !rehearsal)
        session.window = { [weak self] in self?.window }
        session.onExit = { [weak self] in self?.endGame() }
        session.rivalSource = { LeaderboardFeed.shared.rivals }
        session.onFinish = { [weak self, weak session] game in
            if game.isNewRecord { DispatchQueue.main.async { self?.say("신기록!", seconds: 1.6) } }
            guard !rehearsal, let run = session?.runID else { return }
            // 판 사이에 미뤄 둔 순위 소식
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.deliverNews() }
            // 다음 판이 game을 다시 쓰므로 고스트는 지금 떠 둔다
            let ghost = GhostStore.record(of: game, runner: AppSettings.shared.shareableRunnerID)
            Leaderboard.shared.submit(game) { result in
                // 올린 결과로 1위가 됐는지, 라이벌이 바뀌었는지 바로 다시 본다
                if case .success = result {
                    LeaderboardFeed.shared.refresh()
                    Leaderboard.shared.uploadGhost(ghost)
                }
                guard let session, session.runID == run else { return }
                switch result {
                case .success(let rank): session.rankLine = "전체 \(rank.rank)위 · \(rank.total)명"
                case .failure(let error): session.rankLine = error.localizedDescription
                }
            }
        }
        game = session
        bubble = nil
        guard !rehearsal else { return }
        // 메뉴바 앱은 평소 앞에 나서지 않으니, 게임을 켤 때만 팝오버 창이 키를 받게 한다
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            activatedForGame = true
        }
        window?.makeKey()
    }

    func endGame() {
        game = nil
    }

    func popoverClosed() {
        endGame()
        if activatedForGame, NSApp.isActive { NSApp.deactivate() }
        activatedForGame = false
    }

    func toggleSound() {
        GameSound.shared.isOn.toggle()
        soundOn = GameSound.shared.isOn
    }

    func setPressed(_ down: Bool) {
        down ? game?.press() : game?.release()
    }

    // MARK: 말풍선·장난

    /// 순위 소식을 듣는다. 열 때 한 번 받고, 열려 있는 동안 30초마다 받는다.
    func listenForNews() {
        LeaderboardFeed.shared.onNews = { [weak self] in self?.deliverNews() }
        LeaderboardFeed.shared.stageAppeared()
    }

    /// 쌓인 소식을 차례로 말한다. 게임 중이면 판이 끝날 때까지 미룬다.
    func deliverNews() {
        guard game?.game.phase != .playing, LeaderboardFeed.shared.hasNews else { return }
        for (i, line) in LeaderboardFeed.shared.takeNews().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 + Double(i) * 2.9) { [weak self] in
                self?.say(line, seconds: 2.6)
            }
        }
    }

    func greet(display: SpriteDisplay) {
        AppUpdater.shared.checkIfStale()
        // 업데이트 소식, 자리를 비운 사이 생긴 순위 소식 순서로 인사 대신 먼저 말한다
        if let update = AppUpdater.shared.takeBubble() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.say(update, seconds: 2.8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.deliverNews() }
            }
            return
        }
        if LeaderboardFeed.shared.hasNews {
            deliverNews()
            return
        }
        let hour = Calendar.current.component(.hour, from: Date())
        let line: String
        switch display {
        case .tired, .alert, .normal(.sleeping): line = Self.phrases(for: display).randomElement() ?? ""
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

    /// 메뉴에서 고른 동작을 무대 러너도 한다. 게임 중에는 판을 방해하지 않게 하지 않는다.
    func play(_ kind: Trick) {
        guard game == nil else { return }
        trick = (kind, Date())
        nextIdle = Date().addingTimeInterval(kind.duration + 9)
    }

    /// 누르면 장난 하나 + 말풍선. 메뉴바 러너도 같은 장난을 하도록 고른 동작을 돌려준다.
    func pet(character: RunnerCharacter, display: SpriteDisplay) -> Trick {
        let kind: Trick
        switch display {
        case .normal(.sleeping): kind = .wakeUp
        case .tired, .alert: kind = .shake
        default: kind = Trick.petting.filter { $0 != trick?.kind }.randomElement() ?? .hop
        }
        trick = (kind, Date())
        nextIdle = Date().addingTimeInterval(kind.duration + 9)
        let line = Bool.random() ? "\(character.sound)!" : (Self.phrases(for: display).randomElement() ?? character.sound)
        say(line, seconds: 1.8)
        return kind
    }

    /// 사용량 흐름에 반응한다. 메뉴바 러너와 같은 동작을 하고 무슨 일인지 말풍선으로 알린다. 게임 중에는 판을 방해하지 않는다.
    func react(_ reaction: UsageReactions.Reaction, display: SpriteDisplay) {
        guard game == nil, AppSettings.shared.tricksEnabled, display != .tired, display != .alert else { return }
        play(SpriteAnimator.trick(for: reaction))
        let line = switch reaction {
        case .burst: "부스트! 토큰이 쏟아진다"
        case .resumed: "다시 달려 볼까"
        case .sessionMilestone(let percent): "세션 \(percent)% 지났어"
        case .multitask(let count): "프로젝트 \(count)개 동시 진행!"
        case .newSession: "새 세션! 다시 가득 찼어"
        }
        say(line, seconds: 2.4)
    }

    /// 게임 중이면 판을 멈추지 않고 화면 위에 알리고, 아니면 러너가 말한다.
    func claudeFinished(project: String?) {
        let name = project.map { " · \($0)" } ?? ""
        if let game, game.game.phase == .playing {
            game.announce("Claude 작업 끝\(name)")
        } else {
            say("Claude가 끝났어요\(name)", seconds: 3)
        }
    }

    func say(_ text: String, seconds: Double) {
        bubbleToken += 1
        let token = bubbleToken
        bubble = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.bubbleToken == token else { return }
            self.bubble = nil
        }
    }

    static func phrases(for display: SpriteDisplay) -> [String] {
        switch display {
        case .normal(.sleeping): return ["쿨쿨...", "5분만 더...", "꿈에서 토큰 세는 중", "음냐음냐"]
        case .normal(.walking): return ["산책 중", "느긋하게 가자", "오늘도 코딩?", "천천히, 꾸준히"]
        case .normal(.running): return ["달린다!", "토큰 냠냠", "좋은 페이스", "가보자고"]
        case .normal(.dashing): return ["질주 중!", "바람을 가른다", "속도 올라간다", "따라올 테면 와 봐"]
        case .normal(.rainbow): return ["무지개 모드!", "전력 질주!", "아무도 못 말려", "토큰이 불탄다"]
        case .tired: return ["헥헥...", "좀 쉬자...", "한도가 가까워", "물 한 잔만..."]
        case .alert: return ["한도 코앞!", "브레이크!", "/usage 확인해", "곧 멈춰야 해"]
        }
    }

    // MARK: 한 프레임

    func draw(_ cg: CGContext, size: CGSize, date: Date, display: SpriteDisplay, character: RunnerCharacter,
              theme: SpriteTheme, tempo: Double = 1) {
        if let game {
            drawGame(game, cg, size: size, date: date, character: character, theme: theme)
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
        let runnerX = size.width * Self.runnerAnchor + speed / 140 * 16
        let origin = CGPoint(runnerX - Stage.size.width / 2 * scale, groundY - Stage.ground * scale)
        let isSpace = display == .normal(.rainbow)
        let sky = Sky.at(hour: Sky.hourOverride ?? Calendar.current.component(.hour, from: date), space: isSpace)

        drawBackdrop(cg, size: size, sky: sky, time: time, groundY: groundY)

        // 러너 장면
        let rig = character.rig
        let frame = playing.map { $0.kind.frame(at: $0.t) } ?? display.motion(at: gait)
        var scene = CharacterScene(rig: rig, pose: frame.pose, transform: frame.transform)
        // 공중제비처럼 무대 위로 넘치는 장면은 무대 높이 안으로 줄여 넣는다
        scene.fit(verticallyIn: (-origin.y / scale + 0.4)...((size.height - origin.y) / scale))
        let bounds = scene.placedBounds

        // 그림자: 높이 뜰수록 옅고 작아진다
        let lift = max(0, Stage.ground - bounds.maxY)
        let shadowW = bounds.width * scale * 0.5 * (1 - min(lift / 14, 0.6))
        cg.setFillColor(NSColor.black.withAlphaComponent(0.28 * (1 - min(lift / 10, 0.8))).cgColor)
        cg.fillEllipse(in: CGRect(x: origin.x + bounds.midX * scale - shadowW / 2, y: groundY - 2.5,
                                  width: shadowW, height: 5))

        // 데려간 Petdex 펫이 러너 뒤를 따라 걷는다 (멈춰 있으면 제자리에서 숨 쉰다)
        if let companion = GameWallet.shared.companion {
            let x = origin.x + bounds.minX * scale - 26
            let moving = speed > 1
            cg.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
            cg.fillEllipse(in: CGRect(x: x - 16, y: groundY - 2.5, width: 32, height: 5))
            GameFX.drawCompanion(companion, feet: CGPoint(x: x, y: groundY), height: 44,
                                 phase: moving ? scroll / 60 : time / 2.4, moving: moving, theme: theme, cg)
        }

        if isSpace && playing == nil { drawStarStreaks(cg, size: size, time: time, groundY: groundY) }
        if display == .normal(.dashing) || (isSpace && playing == nil) {
            drawWind(cg, size: size, time: time, groundY: groundY, strong: isSpace)
        }

        cg.saveGState()
        cg.translateBy(x: origin.x, y: origin.y)
        cg.scaleBy(x: scale, y: scale)
        let leftEdge = -origin.x / scale
        let loopPhase = gait - floor(gait)
        if playing == nil {
            display.drawLoopEffects(in: cg, scene: scene, phase: loopPhase, tint: .white, front: false, leftEdge: leftEdge)
        }
        var look = CharacterLook(rich: true, palette: theme.richPalette(rig.palette, phase: time / 6),
                                 tint: .white, outline: 0.36)
        look.alarm = display == .alert && playing == nil
        let back = GameWallet.shared.equipped(.back)
        GameFX.drawBack(back, on: scene, time: Double(time), front: false, cg)
        scene.draw(in: cg, look: look)
        GameFX.drawAccessories(hat: GameWallet.shared.equipped(.hat), face: GameWallet.shared.equipped(.face), on: scene,
                               time: Double(time), cg)
        GameFX.drawBack(back, on: scene, time: Double(time), front: true, cg)
        if playing == nil {
            display.drawLoopEffects(in: cg, scene: scene, phase: loopPhase, tint: .white, front: true, leftEdge: leftEdge)
        }
        for effect in frame.effects {
            effect.draw(in: cg, around: bounds, tint: .white)
        }
        cg.restoreGState()

        if display == .alert { drawAlarm(cg, size: size, time: time) }
    }

    private func updateTricks(date: Date, display: SpriteDisplay) {
        defer { lastDisplay = display }
        if let previous = lastDisplay, previous != display {
            switch (previous.isAsleep, display) {
            case (true, .normal(let s)) where s != .sleeping: trick = (.wakeUp, date)
            case (false, .normal(.sleeping)): trick = (.fallAsleep, date)
            case (false, .normal(.rainbow)): trick = (.celebrate, date)
            case (_, .tired), (_, .alert): trick = nil
            default: break
            }
        }
        guard trick == nil, date >= nextIdle else { return }
        nextIdle = date.addingTimeInterval(.random(in: 7...14))
        guard display != .tired && display != .alert else { return }
        let pool = (display.isAsleep ? Trick.asleep : Trick.awake).filter { $0 != lastIdleTrick }
        if let kind = pool.randomElement() {
            lastIdleTrick = kind
            trick = (kind, date)
        }
    }

    /// 배경이 흘러가는 속도 (pt/초).
    static func worldSpeed(_ display: SpriteDisplay) -> CGFloat {
        switch display {
        case .normal(.sleeping), .tired, .alert: return 0
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

    // MARK: 배경

    private func drawBackdrop(_ cg: CGContext, size: CGSize, sky: Sky, time: CGFloat, groundY: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        if let gradient = CGGradient(colorsSpace: space, colors: [sky.top.cgColor, sky.bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(0, groundY), options: [.drawsAfterEndLocation])
        }

        // 별
        if sky.stars > 0 {
            for i in 0..<34 {
                let x = Self.hash(i, 1) * size.width
                let y = Self.hash(i, 2) * (groundY - 30) + 4
                let twinkle = 0.35 + 0.65 * abs(sin(time * (0.8 + Self.hash(i, 3) * 1.6) + CGFloat(i)))
                let r = 0.5 + Self.hash(i, 4) * 0.9
                cg.setFillColor(NSColor.white.withAlphaComponent(sky.stars * twinkle).cgColor)
                cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }

        // 해·달
        let orb = CGPoint(size.width * 0.6, sky.orbLow ? groundY - 24 : 26)   // 오른쪽 위는 단추 자리
        cg.setFillColor(sky.orb.withAlphaComponent(0.16).cgColor)
        cg.fillEllipse(in: CGRect(x: orb.x - 14, y: orb.y - 14, width: 28, height: 28))
        cg.setFillColor(sky.orb.cgColor)
        cg.fillEllipse(in: CGRect(x: orb.x - 8, y: orb.y - 8, width: 16, height: 16))
        if sky.moon {
            cg.setFillColor(sky.top.blended(withFraction: 0.25, of: sky.bottom)?.cgColor ?? sky.top.cgColor)
            cg.fillEllipse(in: CGRect(x: orb.x - 3.5, y: orb.y - 11, width: 16, height: 16))
        }

        // 구름
        if sky.clouds > 0 {
            for i in 0..<4 {
                let span = size.width + 90
                let raw = Self.hash(i, 7) * span - scroll * 0.22 - time * 4
                let x = raw - floor(raw / span) * span - 45
                let y = 12 + Self.hash(i, 8) * 14   // 러너 머리보다 위로 지나가게
                let s = 0.7 + Self.hash(i, 9) * 0.6
                cg.setFillColor(NSColor.white.withAlphaComponent(0.6 * sky.clouds).cgColor)
                for (dx, dy, r) in [(0.0, 0.0, 7.0), (8.0, -3.0, 8.5), (17.0, 0.0, 6.5), (8.0, 2.5, 7.0)] as [(CGFloat, CGFloat, CGFloat)] {
                    cg.fillEllipse(in: CGRect(x: x + dx * s - r * s, y: y + dy * s - r * s, width: r * 2 * s, height: r * 2 * s))
                }
            }
        }

        // 먼 산과 가까운 언덕
        layer(cg, size: size, base: groundY - 20, amplitude: 13, frequency: 0.022, parallax: 0.12, color: sky.far, seed: 1)
        layer(cg, size: size, base: groundY - 7, amplitude: 7, frequency: 0.045, parallax: 0.35, color: sky.near, seed: 2)

        // 땅
        cg.setFillColor(sky.ground.cgColor)
        cg.fill(CGRect(x: 0, y: groundY, width: size.width, height: size.height - groundY))
        cg.setFillColor(sky.edge.withAlphaComponent(0.9).cgColor)
        cg.fill(CGRect(x: 0, y: groundY - 1, width: size.width, height: 2))
        let dash: CGFloat = 26
        let offset = scroll.truncatingRemainder(dividingBy: dash)
        cg.setFillColor(sky.edge.withAlphaComponent(0.35).cgColor)
        var x = -offset
        while x < size.width {
            cg.addPath(CGPath(roundedRect: CGRect(x: x, y: groundY + 5, width: 10, height: 2), cornerWidth: 1,
                              cornerHeight: 1, transform: nil))
            x += dash
        }
        cg.fillPath()
        // 풀 무더기
        let tuftGap: CGFloat = 47
        let tuftOffset = scroll.truncatingRemainder(dividingBy: tuftGap)
        cg.setStrokeColor(sky.edge.withAlphaComponent(0.7).cgColor)
        cg.setLineWidth(1.2)
        cg.setLineCap(.round)
        x = -tuftOffset + 12
        while x < size.width + 10 {
            for dx in [-2.5, 0, 2.5] as [CGFloat] {
                cg.move(to: CGPoint(x + dx * 0.4, groundY - 0.5))
                cg.addLine(to: CGPoint(x + dx, groundY - 4 + abs(dx) * 0.4))
            }
            x += tuftGap
        }
        cg.strokePath()
    }

    /// 사인파를 겹친 능선. 시차를 둬서 멀수록 느리게 흐른다.
    private func layer(_ cg: CGContext, size: CGSize, base: CGFloat, amplitude: CGFloat, frequency: CGFloat,
                       parallax: CGFloat, color: NSColor, seed: CGFloat) {
        let path = CGMutablePath()
        path.move(to: CGPoint(0, size.height))
        var x: CGFloat = 0
        let shift = scroll * parallax
        while x <= size.width + 4 {
            let w = x + shift
            let y = base - amplitude * (0.55 * sin(w * frequency + seed) + 0.3 * sin(w * frequency * 2.3 + seed * 2)
                                        + 0.15 * sin(w * frequency * 5.1))
            path.addLine(to: CGPoint(x, y))
            x += 4
        }
        path.addLine(to: CGPoint(size.width, size.height))
        path.closeSubpath()
        cg.setFillColor(color.cgColor)
        cg.addPath(path)
        cg.fillPath()
    }

    /// 무지개 질주 중 뒤로 쏟아지는 별빛.
    private func drawStarStreaks(_ cg: CGContext, size: CGSize, time: CGFloat, groundY: CGFloat) {
        cg.setLineCap(.round)
        for i in 0..<14 {
            let span = size.width + 60
            let raw = Self.hash(i, 11) * span - scroll * (1.2 + Self.hash(i, 12))
            let x = raw - floor(raw / span) * span - 30
            let y = Self.hash(i, 13) * (groundY - 16) + 6
            let length = 10 + Self.hash(i, 14) * 22
            let color = SpriteEffects.rainbow[i % SpriteEffects.rainbow.count].tinted(by: 0.4)
            cg.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
            cg.setLineWidth(1.2)
            cg.move(to: CGPoint(x, y))
            cg.addLine(to: CGPoint(x + length, y))
            cg.strokePath()
            SpriteEffects.sparkle(cg, at: CGPoint(x, y), radius: 2.2 + sin(time * 6 + CGFloat(i)) * 0.8, color: color)
        }
    }

    private func drawWind(_ cg: CGContext, size: CGSize, time: CGFloat, groundY: CGFloat, strong: Bool) {
        cg.setLineCap(.round)
        for i in 0..<6 {
            let span = size.width + 80
            let raw = Self.hash(i, 21) * span - scroll * 2.2
            let x = raw - floor(raw / span) * span - 40
            let y = 20 + Self.hash(i, 22) * (groundY - 30)
            let length = 24 + Self.hash(i, 23) * 30
            cg.setStrokeColor(NSColor.white.withAlphaComponent(strong ? 0.35 : 0.28).cgColor)
            cg.setLineWidth(1.1)
            cg.move(to: CGPoint(x, y))
            cg.addLine(to: CGPoint(x + length, y))
            cg.strokePath()
        }
    }

    private func drawAlarm(_ cg: CGContext, size: CGSize, time: CGFloat) {
        let pulse = 0.18 + 0.14 * sin(time * 5)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let center = CGPoint(size.width / 2, size.height / 2)
        if let gradient = CGGradient(colorsSpace: space, colors: [NSColor.systemRed.withAlphaComponent(0).cgColor,
                                                                  NSColor.systemRed.withAlphaComponent(pulse).cgColor] as CFArray,
                                     locations: [0.35, 1]) {
            cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                  endRadius: size.width * 0.6, options: [.drawsAfterEndLocation])
        }
    }

    /// 0~1 고정 난수 (자리마다 같은 값).
    static func hash(_ i: Int, _ salt: Int) -> CGFloat {
        let v = sin(CGFloat(i) * 12.9898 + CGFloat(salt) * 78.233) * 43758.5453
        return v - floor(v)
    }
}

/// 시간대별 하늘색.
struct Sky {
    var top: NSColor
    var bottom: NSColor
    var far: NSColor
    var near: NSColor
    var ground: NSColor
    var edge: NSColor
    var stars: CGFloat = 0
    var clouds: CGFloat = 0
    var orb: NSColor
    var moon = false
    var orbLow = false

    /// 화면 점검(--ui-shots)에서 시간대별 하늘을 찍으려고 시각을 고정한다.
    static var hourOverride: Int?

    /// 두 하늘 사이 (게임 구간이 바뀔 때).
    func mixed(with other: Sky, _ t: CGFloat) -> Sky {
        func mix(_ a: NSColor, _ b: NSColor) -> NSColor { a.blended(withFraction: t, of: b) ?? b }
        var sky = Sky(top: mix(top, other.top), bottom: mix(bottom, other.bottom), far: mix(far, other.far),
                      near: mix(near, other.near), ground: mix(ground, other.ground), edge: mix(edge, other.edge),
                      orb: mix(orb, other.orb))
        sky.stars = stars + (other.stars - stars) * t
        sky.clouds = clouds + (other.clouds - clouds) * t
        sky.moon = t < 0.5 ? moon : other.moon
        sky.orbLow = t < 0.5 ? orbLow : other.orbLow
        return sky
    }

    static func at(hour: Int, space: Bool) -> Sky {
        if space {
            return Sky(top: NSColor(hex: 0x120B2E), bottom: NSColor(hex: 0x3A1A6E), far: NSColor(hex: 0x2A1658),
                       near: NSColor(hex: 0x1E1045), ground: NSColor(hex: 0x170C36), edge: NSColor(hex: 0xA17BFF),
                       stars: 1, orb: NSColor(hex: 0xFFE7A3), moon: true)
        }
        switch hour {
        case 5..<8:
            return Sky(top: NSColor(hex: 0x4E5A86), bottom: NSColor(hex: 0xE4B39A), far: NSColor(hex: 0x7F7194),
                       near: NSColor(hex: 0x5B5174), ground: NSColor(hex: 0x3A3352), edge: NSColor(hex: 0xE6C4A8),
                       stars: 0.2, clouds: 0.45, orb: NSColor(hex: 0xF6D6A8), orbLow: true)
        case 8..<17:
            return Sky(top: NSColor(hex: 0x6191C4), bottom: NSColor(hex: 0xBCD6E8), far: NSColor(hex: 0x93B2CC),
                       near: NSColor(hex: 0x739F7C), ground: NSColor(hex: 0x4C7A5C), edge: NSColor(hex: 0xA9CDA2),
                       clouds: 0.9, orb: NSColor(hex: 0xFBF1CF))
        case 17..<20:
            return Sky(top: NSColor(hex: 0x4D4373), bottom: NSColor(hex: 0xE59B80), far: NSColor(hex: 0x7B5B80),
                       near: NSColor(hex: 0x514166), ground: NSColor(hex: 0x372D4D), edge: NSColor(hex: 0xE9B391),
                       clouds: 0.5, orb: NSColor(hex: 0xF4B48A), orbLow: true)
        default:
            return Sky(top: NSColor(hex: 0x131A33), bottom: NSColor(hex: 0x2B3660), far: NSColor(hex: 0x212C52),
                       near: NSColor(hex: 0x19223F), ground: NSColor(hex: 0x131A34), edge: NSColor(hex: 0x4E5E98),
                       stars: 0.85, orb: NSColor(hex: 0xF2EBD0), moon: true)
        }
    }
}

/// 무대에 동작을 요청한다. 같은 동작을 다시 골라도 바뀐 것으로 보이게 매번 새 id를 붙인다.
struct TrickRequest: Equatable {
    let id = UUID()
    let trick: Trick
}
