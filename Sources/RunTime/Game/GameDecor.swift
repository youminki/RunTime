import AppKit
import Combine
import GameCore

/// 미니게임 러너에 다는 꾸미기. 그림만 바뀌고 판정과 점수는 같다.
/// 이름·색·그림은 아래 `info` 표 한 곳에서 정한다. 동료는 꾸미기가 아니라 Petdex 펫을 데려간다 (`GameDecor.companionID`).
enum Cosmetic: String, CaseIterable, Identifiable {
    case sparkleTrail, cometTrail, rainbowTrail, fireTrail, noteTrail, heartTrail, magicTrail, smokeTrail, sparkTrail
    case blossomTrail, cloverTrail, mapleTrail, snowTrail, bubbleTrail, candyTrail
    case heartDust, goldDust, starDust, rainbowDust, cloudDust, sparkleDust, noteDust
    case pineTrack, autumnTrack, desertTrack, beachTrack, snowTrack, blossomTrack, peakTrack, cityTrack
    case drizzleWeather, snowWeather, petalWeather, leafWeather, fogWeather, fireflyWeather
    case fireworksCrash, heartCrash, coinCrash, magicCrash, flameCrash, boomCrash, confettiCrash, balloonCrash, sweetCrash

    enum Slot: CaseIterable {
        case track, weather, trail, dust, crash

        var title: String {
            switch self {
            case .track: "트랙"
            case .weather: "날씨"
            case .trail: "꼬리"
            case .dust: "발먼지"
            case .crash: "부딪힘"
            }
        }
    }

    struct Info {
        let slot: Slot
        let name: String
        /// 발먼지 색, 꼬리의 바탕색, 미리보기 빛.
        let color: NSColor
        /// Fluent Emoji 그림 이름 (Assets/Fluent). 꼬리·발먼지·부딪힘의 입자로 쓴다.
        var art: String? = nil
        /// 그림이 없는 물건(날씨)을 목록에 보일 SF Symbol.
        var symbol: String? = nil
    }

    private static func row(_ slot: Slot, _ name: String, _ hex: UInt32,
                            art: String? = nil, symbol: String? = nil) -> Info {
        Info(slot: slot, name: name, color: NSColor(hex: hex), art: art, symbol: symbol)
    }

    private static let info: [Cosmetic: Info] = [
        // 트랙: 무대와 게임에서 달리는 곳
        .pineTrack: row(.track, "소나무 숲", 0x3D6B52),
        .autumnTrack: row(.track, "가을 들판", 0xC07A3A),
        .desertTrack: row(.track, "사막", 0xD9A066),
        .beachTrack: row(.track, "해변", 0x3E8FB8),
        .snowTrack: row(.track, "설원", 0xB9CDE0),
        .blossomTrack: row(.track, "벚꽃길", 0xE9AFC8),
        .peakTrack: row(.track, "설산", 0x8C9DB8),
        .cityTrack: row(.track, "도시 야경", 0xFFD27A),
        // 날씨: 무대와 게임 하늘에 떠도는 입자
        .drizzleWeather: row(.weather, "이슬비", 0x9DB8D9, symbol: "cloud.drizzle.fill"),
        .snowWeather: row(.weather, "눈", 0xDCE8F2, symbol: "snowflake"),
        .petalWeather: row(.weather, "꽃잎", 0xF7B6CF, symbol: "camera.macro"),
        .leafWeather: row(.weather, "단풍", 0xE0702F, symbol: "leaf.fill"),
        .fogWeather: row(.weather, "안개", 0xC9D4E3, symbol: "cloud.fog.fill"),
        .fireflyWeather: row(.weather, "반딧불", 0xD8F27A, symbol: "sparkle"),
        // 꼬리
        .sparkleTrail: row(.trail, "반짝이", 0xFFD45E),
        .heartTrail: row(.trail, "하트", 0xFF8FB8),
        .noteTrail: row(.trail, "음표", 0xB79CFF),
        .cometTrail: row(.trail, "혜성", 0x8FD3FF),
        .smokeTrail: row(.trail, "증기", 0xE8EEF5),
        .blossomTrail: row(.trail, "벚꽃", 0xFFB7D5, art: "blossom"),
        .cloverTrail: row(.trail, "네잎클로버", 0x7BD88F, art: "clover"),
        .fireTrail: row(.trail, "불꽃", 0xFF7A2F),
        .mapleTrail: row(.trail, "단풍", 0xFF8A3D, art: "maple"),
        .snowTrail: row(.trail, "눈송이", 0xBFE6FF, art: "snowflake"),
        .bubbleTrail: row(.trail, "비눗방울", 0xA8E4FF, art: "bubbles"),
        .magicTrail: row(.trail, "마법 별", 0xC68CFF),
        .rainbowTrail: row(.trail, "무지개", 0xFF9E3D),
        .candyTrail: row(.trail, "사탕", 0xFF6FA8, art: "candy"),
        .sparkTrail: row(.trail, "번개", 0x7FE9FF),
        // 발먼지
        .heartDust: row(.dust, "분홍", 0xFF8FB8),
        .starDust: row(.dust, "하늘빛", 0x8FD3FF),
        .goldDust: row(.dust, "금빛", 0xFFD45E),
        .cloudDust: row(.dust, "구름", 0xE8EEF5),
        .rainbowDust: row(.dust, "무지개", 0x5BD86B),
        .noteDust: row(.dust, "콧노래", 0xB79CFF, art: "note"),
        .sparkleDust: row(.dust, "반짝반짝", 0xFFE58A, art: "sparkles"),
        // 부딪힘
        .heartCrash: row(.crash, "하트 펑", 0xFF8FB8),
        .fireworksCrash: row(.crash, "폭죽", 0xFFE14D),
        .flameCrash: row(.crash, "불기둥", 0xFF8A3D),
        .boomCrash: row(.crash, "쾅!", 0xFFB03D, art: "collision"),
        .coinCrash: row(.crash, "코인 비", 0xFFD45E),
        .balloonCrash: row(.crash, "풍선", 0xFF5C5C, art: "balloon"),
        .magicCrash: row(.crash, "마법진", 0xC68CFF),
        .sweetCrash: row(.crash, "간식 비", 0xFFB0C8, art: "donut"),
        .confettiCrash: row(.crash, "축하 파티", 0xFFD45E, art: "confetti"),
    ]

    var id: String { rawValue }
    var details: Info { Self.info[self]! }
    var slot: Slot { details.slot }
    var name: String { details.name }
    var color: NSColor { details.color }
    var art: String? { details.art }
    var symbol: String? { details.symbol }
}

enum Ability: String, CaseIterable, Identifiable {
    case airJump, shield, magnet, glide

    var id: String { rawValue }

    var name: String {
        switch self {
        case .airJump: "이단 점프"
        case .shield: "보호막"
        case .magnet: "자석"
        case .glide: "글라이드"
        }
    }

    var icon: String {
        switch self {
        case .airJump: "arrow.up.to.line"
        case .shield: "shield.lefthalf.filled"
        case .magnet: "dot.circle.and.hand.point.up.left.fill"
        case .glide: "wind"
        }
    }

    /// 켜면 쓰는 단계.
    var level: Int {
        switch self {
        case .airJump: 2
        case .shield, .magnet: 3
        case .glide: 1
        }
    }

    var detail: String {
        switch self {
        case .airJump: "공중에서 두 번 더 뛰기"
        case .shield: "한 판에 세 번 부딪혀도 버팀"
        case .magnet: "가까운 코인을 끌어옴"
        case .glide: "뛴 채 누르고 있으면 천천히 내려옴"
        }
    }
}

/// 쓰는 꾸미기와 능력, 동료. 모두 자유롭게 켜고 끈다. 이 Mac에만 저장한다.
final class GameDecor: ObservableObject {
    static let shared = GameDecor()

    private enum Key {
        static let equipped = "gameCosmeticsEquipped"
        static let companion = "gameCompanion"
        static let abilities = "gameAbilitiesOn"
        // 예전에 산 능력을 그대로 켜 두려고 처음 한 번 읽는다
        static let oldLevels = "gameAbilityLevels", oldOff = "gameAbilitiesOff"
    }

    private let defaults = UserDefaults.standard

    @Published private(set) var equipped: Set<Cosmetic> {
        didSet { defaults.set(equipped.map(\.rawValue), forKey: Key.equipped) }
    }
    @Published private(set) var abilitiesOn: Set<Ability> {
        didSet { defaults.set(abilitiesOn.map(\.rawValue), forKey: Key.abilities) }
    }
    /// 게임과 무대에서 러너 뒤를 따라 달리는 Petdex 펫 (`PetdexStore.storageID`). 없으면 nil.
    @Published var companionID: String? {
        didSet { defaults.set(companionID, forKey: Key.companion) }
    }

    /// 화면 점검 도구가 저장하지 않고 꾸미기를 달아 볼 때.
    var preview: Set<Cosmetic>?

    /// 마우스를 올려 써 보는 물건 하나. 그 갈래만 덮어써서, 써 보는 동안 다른 갈래를 바꿔도 그대로 반영된다.
    @Published var tryingOn: Cosmetic?

    private init() {
        equipped = Set((defaults.stringArray(forKey: Key.equipped) ?? []).compactMap(Cosmetic.init(rawValue:)))
        companionID = defaults.string(forKey: Key.companion)
        if let saved = defaults.stringArray(forKey: Key.abilities) {
            abilitiesOn = Set(saved.compactMap(Ability.init(rawValue:)))
        } else {
            let levels = defaults.dictionary(forKey: Key.oldLevels) as? [String: Int] ?? [:]
            let off = Set(defaults.stringArray(forKey: Key.oldOff) ?? [])
            abilitiesOn = Set(Ability.allCases.filter { (levels[$0.rawValue] ?? 0) > 0 && !off.contains($0.rawValue) })
        }
    }

    /// 데려갈 동료 그림. 펫을 지웠으면 nil.
    var companion: RunnerCharacter? {
        companionID.flatMap { PetdexStore.shared.pet(storageID: $0) }.flatMap(PetdexStore.shared.character(for:))
    }

    func equipped(_ slot: Cosmetic.Slot) -> Cosmetic? {
        if let tryingOn, tryingOn.slot == slot { return tryingOn }
        return (preview ?? equipped).first { $0.slot == slot }
    }

    func isOn(_ ability: Ability) -> Bool { abilitiesOn.contains(ability) }

    func toggle(_ ability: Ability) {
        if abilitiesOn.contains(ability) { abilitiesOn.remove(ability) } else { abilitiesOn.insert(ability) }
    }

    /// 다음 판에 쓸 능력 (켜 둔 것만).
    var abilities: RunnerGame.Abilities {
        RunnerGame.Abilities(airJumps: isOn(.airJump) ? Ability.airJump.level : 0,
                             shields: isOn(.shield) ? Ability.shield.level : 0,
                             magnet: isOn(.magnet) ? Ability.magnet.level : 0,
                             glide: isOn(.glide))
    }

    /// 갈래마다 하나씩 쓴다. 쓰는 것을 다시 고르면 뗀다.
    func choose(_ item: Cosmetic) {
        if equipped.contains(item) {
            equipped.remove(item)
        } else {
            equipped = equipped.filter { $0.slot != item.slot }.union([item])
        }
    }
}
