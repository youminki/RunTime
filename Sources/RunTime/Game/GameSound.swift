import AppKit

/// 게임 효과음 (Kenney Digital Audio, CC0). 메뉴바 앱이라 작게 낸다.
final class GameSound {
    enum Effect: String, CaseIterable {
        case jump, coin, hit, milestone, record, airjump, shield, nearmiss
        // 짧은 음악: 신기록·고스트 이김, 게임 오버, 미션 완료, 상점에서 사기
        case fanfare, gameover, mission, purchase
    }

    static let shared = GameSound()

    private static let key = "gameSoundOn"
    private var sounds: [Effect: NSSound] = [:]

    var isOn: Bool {
        get { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    private init() {
        let folder = Bundle.assets.resourceURL?.appendingPathComponent("Assets/Game")
        for effect in Effect.allCases {
            guard let url = folder?.appendingPathComponent("\(effect.rawValue).m4a"),
                  let sound = NSSound(contentsOf: url, byReference: false) else { continue }
            sound.volume = switch effect {
            case .jump, .nearmiss: 0.25
            case .fanfare, .gameover, .mission: 0.3
            default: 0.35
            }
            sounds[effect] = sound
        }
    }

    func play(_ effect: Effect) {
        guard isOn, let sound = sounds[effect] else { return }
        // 같은 소리가 겹치면 처음부터 다시
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
