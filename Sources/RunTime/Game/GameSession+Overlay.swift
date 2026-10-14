import GameCore
import SwiftUI

/// 점수판과 시작·끝 화면 글자.
extension GameSession {
    // MARK: 점수판

    /// 무대 위 글자. 그리기 컨텍스트가 바로 그리도록 위치와 함께 넘긴다.
    struct Label {
        let text: Text
        let position: CGPoint
        var anchor: UnitPoint = .center
        var opacity: Double = 1
    }

    struct Panel {
        let rect: CGRect
    }

    func overlay(size: CGSize) -> (panels: [Panel], labels: [Label]) {
        var labels: [Label] = []
        var panels: [Panel] = []
        // 100점마다 점수가 잠깐 커진다
        let digits = GameFont.pixel(18 * (1 + 0.3 * milestoneGlow * milestoneGlow))
        // 설명 글은 시스템 글꼴로 둔다. 픽셀 글꼴은 점수·제목처럼 크게 읽는 글자에만 쓴다
        let caption = Font.system(size: 10.5, weight: .semibold).monospacedDigit()
        let gold = Color(nsColor: NSColor(hex: 0xFFD45E))

        // 끝난 화면은 결과 카드가 점수를 크게 보여 준다
        if game.phase == .playing {
            // 뛰어오른 러너나 위에 떠 있는 장애물이 점수판 밑을 지나면 점수판을 옅게 해 가리지 않게 한다
            let groundY = size.height - 15
            let hud = CGRect(x: 0, y: 0, width: 170, height: 50)
            let runnerTop = groundY - CGFloat(game.runnerY + Self.runnerHeight * 1.3)
            let covered = (runnerTop < hud.maxY && runnerLeft < hud.maxX)
                || game.obstacles.contains { o in
                    let x = screenX(o.x)
                    return groundY - CGFloat(o.y + o.height) < hud.maxY && x < hud.maxX && x + CGFloat(o.width) > hud.minX
                }
            hudAlpha += ((covered ? 0.3 : 1) - hudAlpha) * 0.2
            let glow = milestoneGlow > 0 && Int(milestoneGlow * 10) % 2 == 0
            labels.append(Label(text: Text(String(format: "%05d", game.score)).font(digits)
                                    .foregroundColor(glow ? gold : .white),
                                position: CGPoint(12, 10), anchor: .topLeading, opacity: hudAlpha))
            // 점수 아래 한 줄: 최고 점수, 먹은 코인, 남은 보호막
            var line = Text(verbatim: "BEST \(max(game.best, game.score))").foregroundColor(.white.opacity(0.6))
            if game.coinsTaken > 0 || boosted {
                line = line + Text("   ") + Text(Image(systemName: "circle.fill")).foregroundColor(gold)
                    + Text(verbatim: " \(game.coinsTaken)").foregroundColor(gold)
                if boosted { line = line + Text(" ×2").foregroundColor(gold.opacity(0.75)) }
            }
            if game.abilities.shields > 0 {
                line = line + Text("   ") + Text(Image(systemName: "shield.fill"))
                    .foregroundColor(Color(nsColor: NSColor(hex: 0x8FD3FF)).opacity(game.shieldsLeft > 0 ? 1 : 0.35))
                    + Text(verbatim: " \(game.shieldsLeft)").foregroundColor(.white.opacity(game.shieldsLeft > 0 ? 0.85 : 0.4))
            }
            labels.append(Label(text: line.font(caption), position: CGPoint(13, 31), anchor: .topLeading, opacity: hudAlpha))
        }
        for popup in popups {
            labels.append(Label(text: Text(popup.text).font(GameFont.pixel(12))
                                    .foregroundColor(gold.opacity(Double(min(1, popup.life * 2)))),
                                position: CGPoint(popup.position.x, (size.height - 15) - popup.position.y - 14)))
        }
        if game.phase == .playing, let next = tracker.next {
            // 오른쪽 위 단추와 겹치지 않게 긴 닉네임은 자른다
            let name = next.name.count > 6 ? next.name.prefix(6) + "…" : Substring(next.name)
            labels.append(Label(text: (Text(Image(systemName: "flag.fill")).foregroundColor(Color(nsColor: NSColor(hex: 0xFF6B5E)))
                                       + Text(" \(String(name))까지 ").foregroundColor(.white.opacity(0.7))
                                       + Text(verbatim: "\(max(0, next.score + 1 - game.score))").foregroundColor(.white))
                                    .font(caption),
                                position: CGPoint(size.width / 2, 14)))
            if let x = flagX(), x > 0, x < size.width {
                labels.append(Label(text: Text(next.name).font(.system(size: 9.5, weight: .bold))
                                        .foregroundColor(.white),
                                    position: CGPoint(x + 8, size.height - 15 - 56)))
            }
        }
        if game.phase == .playing, let lead = raceLead, let raceTarget {
            let who = Self.shortName(raceTarget.name)
            let text = lead > 0 ? "\(who) 추월 +\(lead)" : "\(who)까지 \(1 - lead)"
            labels.append(Label(text: Text(text).font(caption).foregroundColor(lead > 0 ? gold : .white.opacity(0.85)),
                                position: CGPoint(size.width / 2, 14)))
        }
        if let overtaken, game.phase == .playing {
            labels.append(Label(text: Text("\(overtaken.name) 추월!").font(GameFont.pixel(18))
                                    .foregroundColor(gold.opacity(Double(min(1, overtaken.life * 2)))),
                                position: CGPoint(size.width / 2, 34)))
        }
        if let zoneBanner, game.phase == .playing {
            labels.append(Label(text: Text(zoneBanner.text).font(GameFont.pixel(18))
                                    .foregroundColor(.white.opacity(Double(min(1, zoneBanner.life * 2)))),
                                position: CGPoint(size.width / 2, 52)))
        }
        if let notice {
            labels.append(Label(text: Text(notice.text).font(caption)
                                    .foregroundColor(Color(nsColor: NSColor(hex: 0x8FD3FF)).opacity(Double(min(1, notice.life * 2)))),
                                position: CGPoint(size.width / 2, game.phase == .playing ? 70 : 14)))
        }
        if recordBanner > 0, game.phase == .playing {
            labels.append(Label(text: Text("신기록!").font(GameFont.pixel(18))
                                    .foregroundColor(gold.opacity(Double(min(1, recordBanner * 3)))),
                                position: CGPoint(size.width / 2, overtaken == nil ? 34 : 52)))
        }

        // 시작·결과 카드는 오른쪽에 두어 왼쪽의 러너와 부딪힌 장애물이 가려지지 않게 한다
        let cardWidth: CGFloat = 164
        // 러너 몸 가운데가 무대 가운데보다 오른쪽이면 카드를 왼쪽에 둔다
        let cardLeft = runnerLeft + CGFloat(Self.runnerWidth) / 2 > size.width / 2 ? 10 : size.width - cardWidth - 10
        let cardTop: CGFloat = 36
        let inset = cardLeft + 12
        // 고스트 단축키. 두 개까지 한 줄에 두고 키 글자만 금색으로
        var races: [(key: String, text: String)] = []
        if let savedGhost { races.append(("G", "내 고스트 \(savedGhost.score)")) }
        if let top = TopGhost.all.record {
            races.append(("1", "\(top.rank.map { "\($0)위" } ?? "1위") \(Self.shortName(top.name))"))
        }
        if let week = weekGhost { races.append(("2", "주간 \(Self.shortName(week.name))")) }
        let raceText = races.prefix(2).enumerated().reduce(Text("")) { line, item in
            line + Text(item.offset == 0 ? "" : "   ") + Text(item.element.key).foregroundColor(gold)
                .font(.system(size: 10.5, weight: .heavy).monospaced())
                + Text(" \(item.element.text)").foregroundColor(.white.opacity(0.7))
        }
        func card(height: CGFloat) {
            panels.append(Panel(rect: CGRect(x: cardLeft, y: cardTop, width: cardWidth, height: height)))
        }
        switch game.phase {
        case .ready where entrance >= 1:
            labels.append(Label(text: Text("토큰 러너").font(GameFont.pixel(18)).foregroundColor(.white),
                                position: CGPoint(inset, cardTop + 10), anchor: .topLeading))
            labels.append(Label(text: Text(game.best > 0 ? "BEST \(game.best)" : "첫 판").font(caption)
                                    .foregroundColor(gold), position: CGPoint(cardLeft + cardWidth - 12, cardTop + 15), anchor: .topTrailing))
            labels.append(Label(text: (Text("스페이스") .foregroundColor(.white) + Text(" 또는 ").foregroundColor(.white.opacity(0.6))
                                       + Text("클릭").foregroundColor(.white) + Text("으로 시작").foregroundColor(.white.opacity(0.6)))
                                    .font(caption), position: CGPoint(inset, cardTop + 38), anchor: .topLeading))
            labels.append(Label(text: Text("↑ 길게 높이  ↓ 숙이기  ←→ 이동").font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5)), position: CGPoint(inset, cardTop + 54), anchor: .topLeading))
            var height: CGFloat = 72
            if !races.isEmpty {
                labels.append(Label(text: raceText.font(caption), position: CGPoint(inset, cardTop + 72), anchor: .topLeading))
                height += 18
            }
            card(height: height)
        case .over:
            // 겨루는 판은 순위 대신 고스트와의 차이를 보여 준다
            let raceLine = raceLead.map { lead in
                lead > 0 ? "\(lead)점 앞섬 · 기록에는 남지 않음" : "\(-lead + 1)점 모자람"
            }
            let middle = raceLine ?? rankLine
            let won = (raceLead ?? 0) > 0
            let who = raceTarget?.name.map { "\(Self.shortName($0)) 고스트" } ?? "고스트"
            let title = isRace ? (won ? "\(who)를 이겼다" : "\(who)에게 졌다")
                : game.isNewRecord ? "신기록" : "부딪혔다"
            let highlight = won || (!isRace && game.isNewRecord)
            labels.append(Label(text: Text(title).font(.system(size: 11, weight: .bold))
                                    .foregroundColor(highlight ? gold : .white.opacity(0.65)),
                                position: CGPoint(inset, cardTop + 11), anchor: .topLeading))
            labels.append(Label(text: Text(verbatim: "\(game.score)").font(GameFont.pixel(24)).foregroundColor(.white),
                                position: CGPoint(inset - 1, cardTop + 27), anchor: .topLeading))
            labels.append(Label(text: Text(verbatim: "BEST \(game.best)").font(caption).foregroundColor(.white.opacity(0.55)),
                                position: CGPoint(cardLeft + cardWidth - 12, cardTop + 12), anchor: .topTrailing))
            if game.coinsTaken > 0 {
                labels.append(Label(text: (Text(Image(systemName: "circle.fill")) + Text(verbatim: " +\(game.coinsTaken)")).font(caption)
                                        .foregroundColor(gold),
                                    position: CGPoint(cardLeft + cardWidth - 12, cardTop + 38), anchor: .topTrailing))
            }
            var y = cardTop + 60
            if let middle {
                labels.append(Label(text: Text(middle).font(caption).foregroundColor(gold),
                                    position: CGPoint(inset, y), anchor: .topLeading))
                y += 16
            }
            labels.append(Label(text: (Text("스페이스").foregroundColor(.white) + Text("로 새 판").foregroundColor(.white.opacity(0.6)))
                                    .font(caption), position: CGPoint(inset, y), anchor: .topLeading))
            y += 16
            if !races.isEmpty, y + 18 < size.height - 4 {
                labels.append(Label(text: raceText.font(caption), position: CGPoint(inset, y), anchor: .topLeading))
                y += 16
            }
            card(height: y - cardTop + 6)
        default:
            break
        }
        return (panels, labels)
    }
}
