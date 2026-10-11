import AppKit
import GameCore
import SwiftUI

/// 게임 화면 점검 (`--game-shots <폴더> [러너 id]`). 무대와 같은 코드로 자동 플레이를 돌리며
/// 시작 화면, 달리는 장면 몇 장, 부딪힌 화면을 PNG로 남긴다. 팝오버를 열어 직접 해 보지 않고 모습을 확인할 때 쓴다.
enum GameShots {
    @MainActor
    static func run(to directory: URL, character: RunnerCharacter) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = StageModel()
        let size = CGSize(width: 344, height: RunnerStage.height)
        var date = Date()
        let frame = 1.0 / 60
        model.startGame(character: character, rehearsal: true)
        guard let session = model.game else { return }
        let game = session.game
        let pilot = Autopilot(game: game)
        // 순위 서버 없이 라이벌 목표·깃발·추월 배너가 보이게 가짜 두 명을 둔다
        session.rivalSource = { [Rival(name: "토큰고양이", score: 160), Rival(name: "bob", score: 430)] }

        func step(_ seconds: Double, autoplay: Bool) {
            for _ in 0..<Int(seconds / frame) {
                if autoplay { pilot.step() }
                date = date.addingTimeInterval(frame)
                session.update(date: date)
            }
        }

        func shot(_ name: String) throws {
            let view = Canvas { context, size in
                context.withCGContext { cg in
                    model.draw(cg, size: size, date: date, display: .normal(.running), character: character,
                               theme: character.theme(.natural))
                }
                if let game = model.game { RunnerStage.drawOverlay(game.overlay(size: size), in: &context) }
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }

        step(0.2, autoplay: false)
        try shot("0-entrance")
        step(0.6, autoplay: false)
        try shot("1-ready")
        // 능력을 단 모습 (보호막 방울, 능력 표시)
        game.setAbilities(.init(airJumps: 1, shields: 2, magnet: 3, glide: true))
        session.press()
        session.release()
        for k in 1...12 {
            step(3, autoplay: true)
            try shot("2-play-\(k)")
            if game.phase == .over { break }
        }
        // 꾸미기를 단 모습 (꼬리 셋, 발먼지)
        let looks: [(trail: Cosmetic, dust: Cosmetic, back: Cosmetic, hat: Cosmetic)] = [
            (.rainbowTrail, .rainbowDust, .wingBack, .crownHat), (.fireTrail, .cloudDust, .rocketBack, .topHat),
            (.noteTrail, .starDust, .guitarBack, .capHat), (.heartTrail, .heartDust, .balloonBack, .ribbonHat),
            (.magicTrail, .starDust, .butterflyBack, .starHat), (.smokeTrail, .cloudDust, .kiteBack, .cloudHat),
            (.sparkTrail, .goldDust, .parrotBack, .chickHat), (.blossomTrail, .sparkleDust, .backpackBack, .hibiscusHat),
            (.bubbleTrail, .noteDust, .shieldBack, .fireHat),
        ]
        session.companionOverride = PetdexStore.shared.pets.first.flatMap(PetdexStore.shared.character(for:))
        for (item, dust, back, hat) in looks where game.phase == .playing {
            GameWallet.shared.preview = [item, dust, back, hat, .sunglassesFace, .confettiCrash]
            step(0.5, autoplay: true)
            try shot("2-play-\(item.rawValue)")
        }
        // →를 눌러 앞으로 나간 모습. 자동 플레이는 앞뒤 이동을 셈하지 않아 마지막에 찍는다
        if game.phase == .playing {
            game.setMove(forward: true)
            step(0.6, autoplay: true)
            try shot("2-play-forward")
        }
        // 손을 놓고 부딪히게 둔다 (부딪힘 효과는 폭죽)
        while game.phase == .playing { step(0.02, autoplay: false) }
        step(0.12, autoplay: false)
        try shot("3-crash")
        GameWallet.shared.preview = nil
        step(0.6, autoplay: false)
        try shot("4-over")

        // 방금 판을 고스트로 두고 겨룬다. 같은 자동 플레이에 앞으로 조금 나가 고스트와 겹치지 않게 한다
        // 고스트는 그 판을 달린 러너 모습이어야 한다 (내 러너와 다르게 용으로)
        session.savedGhost = GhostStore.record(of: game, runner: Runner.dragon.rawValue)
        let packed = GhostStore.packInputs(game.inputLog) ?? ""
        let unpacked = GhostStore.unpackInputs(packed) ?? []
        let ok = GhostStore.verified(session.savedGhost!, tuning: game.tuning, runnerWidth: game.runnerWidth,
                                     runnerHeight: game.runnerHeight)
        var forged = session.savedGhost!
        forged = GhostRecord(seed: forged.seed, score: forged.score + 500, layout: forged.layout, inputs: forged.inputs)
        let forgedOK = GhostStore.verified(forged, tuning: game.tuning, runnerWidth: game.runnerWidth,
                                           runnerHeight: game.runnerHeight)
        print("ghost inputs \(game.inputLog.count)개 → \(packed.count)자, 되풀기 \(unpacked == game.inputLog), 확인 \(ok), 부풀린 점수 \(forgedOK)")
        try shot("5-over-ghost")
        session.startRace(session.savedGhost)
        game.setMove(forward: true)
        step(0.4, autoplay: true)
        game.setMove(forward: false)
        step(2.6, autoplay: true)
        try shot("6-race")
        while game.phase == .playing { step(0.25, autoplay: false) }
        step(0.6, autoplay: false)
        try shot("7-race-over")
        print("score \(game.score), coins \(game.coinsTaken), \(String(format: "%.1f", game.elapsed))s, speed \(Int(game.speed))")
    }
}

/// 그리기 시간 재기 (`--game-bench`). 팝오버 무대와 같은 코드로 무대만, 게임(꾸미기·능력·고스트 포함)을
/// 2배 크기 비트맵에 여러 장 그려 한 장면에 드는 시간을 낸다. 1초 60장이면 장면마다 16.7ms 안이어야 한다.
enum GameBench {
    @MainActor
    static func run(character: RunnerCharacter) {
        let size = CGSize(width: 344, height: RunnerStage.height)
        guard let cg = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        cg.scaleBy(x: 2, y: 2)
        let frames = Int(ProcessInfo.processInfo.environment["BENCH_FRAMES"] ?? "") ?? 600
        var date = Date()

        func measure(_ name: String, _ model: StageModel, before: () -> Void = {}) {
            let start = Date()
            for _ in 0..<frames {
                before()
                date = date.addingTimeInterval(1.0 / 60)
                model.draw(cg, size: size, date: date, display: .normal(.dashing), character: character,
                           theme: character.theme(.natural))
            }
            let ms = Date().timeIntervalSince(start) * 1000 / Double(frames)
            print(String(format: "%@: 장면마다 %.2fms (60fps의 %.0f%%)", name, ms, ms / (1000.0 / 60) * 100))
        }

        measure("무대", StageModel())

        let model = StageModel()
        model.startGame(character: character, rehearsal: true)
        guard let session = model.game else { return }
        let game = session.game
        game.setAbilities(.init(airJumps: 1, shields: 2, magnet: 3, glide: true))
        GameWallet.shared.preview = [.rainbowTrail, .rainbowDust, .fireworksCrash]
        let pilot = Autopilot(game: game)
        session.press()
        session.release()
        measure("게임", model) { pilot.step() }
        GameWallet.shared.preview = nil

        // 상점 칸 미리보기. 한 화면에 칸이 여러 개라 가장 무거운 칸을 본다
        let cell = CGSize(width: 160, height: 62)
        var worst = (name: "", ms: 0.0), total = 0.0
        for item in Cosmetic.allCases {
            let preview = ItemPreview(kind: .cosmetic(item), character: character)
            let start = Date()
            for k in 0..<frames { preview.draw(cg, size: cell, time: Double(k) / 30) }
            let ms = Date().timeIntervalSince(start) * 1000 / Double(frames)
            total += ms
            if ms > worst.ms { worst = (item.rawValue, ms) }
        }
        print(String(format: "상점 칸: 평균 %.2fms, 가장 무거운 %@ %.2fms (20fps 한 칸이면 1초에 %.0fms)",
                     total / Double(Cosmetic.allCases.count), worst.name, worst.ms, worst.ms * 20))
    }
}

/// README용 게임 장면 (`--game-frames <폴더>`). 용 고스트와 겨루는 판을 1초 20장으로 이어 찍어
/// 0001.png부터 저장한다. GIF는 scripts/make-game-gif.sh가 만든다.
enum GameFrames {
    @MainActor
    static func run(to directory: URL, character: RunnerCharacter) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = StageModel()
        let size = CGSize(width: 344, height: RunnerStage.height)
        var date = Date()
        let frame = 1.0 / 60
        model.startGame(character: character, rehearsal: true)
        guard let session = model.game else { return }
        let game = session.game
        let pilot = Autopilot(game: game)

        func step(_ seconds: Double, every: Int = 0, capture: (() throws -> Void)? = nil) rethrows {
            for k in 0..<Int(seconds / frame) {
                pilot.step()
                date = date.addingTimeInterval(frame)
                session.update(date: date)
                if every > 0, k % every == 0 { try capture?() }
            }
        }

        // 먼저 한 판을 해서 용 고스트를 만든다
        step(0.8)
        session.press()
        session.release()
        step(12)
        while game.phase == .playing { step(0.25) }
        step(0.6)
        session.savedGhost = GhostStore.record(of: game, runner: Runner.dragon.rawValue)

        // 꾸미기와 능력을 달고 고스트와 겨룬다. 앞뒤로 움직여 고스트와 겹치지 않게 한다
        GameWallet.shared.preview = [.rainbowTrail, .rainbowDust]
        game.setAbilities(.init(airJumps: 1, shields: 2, magnet: 2))
        session.startRace(session.savedGhost)
        step(1.2)
        var index = 0
        let capture = {
            index += 1
            let view = Canvas { context, size in
                context.withCGContext { cg in
                    model.draw(cg, size: size, date: date, display: .normal(.running), character: character,
                               theme: character.theme(.natural))
                }
                if let game = model.game { RunnerStage.drawOverlay(game.overlay(size: size), in: &context) }
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(String(format: "%04d.png", index)))
        }
        for k in 0..<4 {
            game.setMove(forward: k % 2 == 0)
            game.setMove(back: k % 2 == 1)
            try step(1.1, every: 3, capture: capture)
        }
        GameWallet.shared.preview = nil
        print("frames \(index)")
    }
}

/// 모자·안경 점검 (`--accessory-sheet <파일>`): 모든 러너에 왕관과 선글라스를 씌운 모습을 한 장에 모아 PNG로 저장한다.
enum AccessorySheet {
    @MainActor
    /// `set`: 기본 러너(nil), "petdex", "pack". 그림 러너는 본래 색·황금·루비로 그려 색 입히기도 함께 본다.
    static func run(to url: URL, set: String? = nil, hat: Cosmetic = .crownHat, face: Cosmetic = .sunglassesFace) throws {
        if set == "items" { return try items(to: url) }
        let images = set != nil
        let runners: [RunnerCharacter] = switch set {
        case "petdex": PetdexStore.shared.pets.compactMap(PetdexStore.shared.character(for:))
        default: Runner.allCases.map(\.character)
        }
        let cell = CGSize(width: 140, height: 84), columns = 7
        let rows = (runners.count + columns - 1) / columns
        let size = CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows) + 80)
        guard let cg = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 무대와 같은 위가 0인 좌표로 그린다
        cg.translateBy(x: 0, y: size.height * 2)
        cg.scaleBy(x: 2, y: -2)
        cg.setFillColor(NSColor(hex: 0x1B2140).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        for (i, runner) in runners.enumerated() {
            let origin = CGPoint(x: CGFloat(i % columns) * cell.width, y: CGFloat(i / columns) * cell.height + 80)
            let character = runner
            // 서기, 달리기, 뒤돈 모습 (모자가 뒤집히지 않는지). 그림 러너는 색 입히기도 함께 본다
            let poses: [(CharacterPose.Activity, CGFloat)] = [(.stand, 1), (.run, 1), (.stand, -1)]
            let themes: [SpriteTheme] = images ? [.auto, .gold, .ruby] : [.auto, .auto, .auto]
            for (k, (activity, facing)) in poses.enumerated() {
                var turn = CharacterTransform()
                turn.scaleX = facing
                let scene = CharacterScene(rig: character.rig, pose: CharacterPose(activity: activity, phase: 0.3), transform: turn)
                let scale: CGFloat = 1.9
                cg.saveGState()
                cg.translateBy(x: origin.x + CGFloat(k) * 46 + 2, y: origin.y + 4)
                cg.scaleBy(x: scale, y: scale)
                let look = CharacterLook(rich: true, palette: character.theme(themes[k]).richPalette(character.rig.palette, phase: 0),
                                         tint: .white, outline: 0.36)
                scene.draw(in: cg, look: look)
                GameFX.drawAccessories(hat: hat, face: face, on: scene, cg)
                cg.restoreGState()
            }
        }
        guard let image = cg.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 머리·얼굴·등 꾸미기를 하나씩 여러 러너(기본 러너 몇과 Petdex 펫)에 달아 크게 그린다 (`--accessory-sheet <파일> items`).
    @MainActor
    static func items(to url: URL) throws {
        let items = Cosmetic.allCases.filter { [.hat, .face, .back].contains($0.slot) }
        let runners = [Runner.cat, .penguin, .dog, .whale, .robot].map(\.character)
            + PetdexStore.shared.pets.prefix(3).compactMap(PetdexStore.shared.character(for:))
        let cell = CGSize(width: 110, height: 80)
        let size = CGSize(width: 90 + cell.width * CGFloat(runners.count), height: cell.height * CGFloat(items.count))
        guard let cg = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        cg.translateBy(x: 0, y: size.height * 2)
        cg.scaleBy(x: 2, y: -2)
        cg.setFillColor(NSColor(hex: 0x1B2140).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        for (row, item) in items.enumerated() {
            let label = NSAttributedString(string: item.name, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                          .foregroundColor: NSColor.white])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            label.draw(at: CGPoint(x: 6, y: CGFloat(row) * cell.height + 30))
            NSGraphicsContext.restoreGraphicsState()
            for (column, character) in runners.enumerated() {
                let scene = CharacterScene(rig: character.rig, pose: CharacterPose(activity: .run, phase: 0.3))
                let scale: CGFloat = 2.6
                cg.saveGState()
                cg.translateBy(x: 90 + CGFloat(column) * cell.width + 8, y: CGFloat(row) * cell.height + 18)
                cg.scaleBy(x: scale, y: scale)
                let look = CharacterLook(rich: true, palette: character.theme(.auto).richPalette(character.rig.palette, phase: 0),
                                         tint: .white, outline: 0.36)
                GameFX.drawBack(item.slot == .back ? item : nil, on: scene, time: 0.3, front: false, cg)
                scene.draw(in: cg, look: look)
                GameFX.drawAccessories(hat: item.slot == .hat ? item : nil, face: item.slot == .face ? item : nil, on: scene,
                                       time: 0.3, cg)
                GameFX.drawBack(item.slot == .back ? item : nil, on: scene, time: 0.3, front: true, cg)
                cg.restoreGState()
            }
        }
        guard let image = cg.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
