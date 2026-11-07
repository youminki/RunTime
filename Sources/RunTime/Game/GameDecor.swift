import AppKit
import Combine
import GameCore

/// 미니게임 러너에 다는 꾸미기. 그림만 바뀌고 판정과 점수는 같다.
/// 이름·색·그림은 아래 `info` 표 한 곳에서 정한다. 동료는 꾸미기가 아니라 Petdex 펫을 데려간다 (`GameDecor.companionID`).
enum Cosmetic: String, CaseIterable, Identifiable {
    case rainbowStarTrail, heartTrail, gemTrail, coinTrail, candyTrail, swirlTrail, fireTrail, smokeTrail, magicTrail
    case bubbleTrail, waterTrail, cometTrail
    case puffDust, smokeDust, heartDust, starDust, sparkleDust, coinDust, candyDust, bubbleDust
    case cloudWoodsTrack, mintForestTrack, greenForestTrack, mistForestTrack, tallForestTrack, bushForestTrack
    case jungleTrack, redForestTrack, amberForestTrack, frostForestTrack, snowPinesTrack, xmasPeaksTrack
    case greenHillsTrack, flowerHillsTrack, sunnyHillsTrack, springFieldTrack, hillTownTrack, greenVillageTrack
    case wheatRoadTrack, castleHillTrack, forestGladeTrack, sunsetFieldTrack, sandDunesTrack, desertArchTrack
    case redCanyonTrack, pyramidTrack, sandPalaceTrack, whiteTempleTrack, summerBeachTrack, sandyBeachTrack
    case tropicalSeaTrack, oceanDayTrack, oceanSunsetTrack, oceanNightTrack, underwaterTrack, deepSeaTrack
    case mintSkyTrack, goldenSkyTrack, skyIslandsTrack, airshipTrack, cloudPeaksTrack, emeraldCloudsTrack
    case pinkCloudsTrack, pinkSunsetTrack, duskPeaksTrack, cherryBridgeTrack, trainBridgeTrack, palaceTrack
    case greenCityTrack, mistCityTrack, harborNightTrack, starCityTrack, violetCityTrack, fullMoonTrack
    case pinkCaveTrack, crystalCaveTrack, violetCaveTrack, mossCaveTrack, lavaCaveTrack
    case starburstCrash, ringCrash, boomCrash, fireCrash, candyCrash, heartCrash, gemCrash, coinCrash, magicCrash

    enum Slot: CaseIterable {
        case track, trail, dust, crash

        var title: String {
            switch self {
            case .track: "트랙"
            case .trail: "꼬리"
            case .dust: "발먼지"
            case .crash: "부딪힘"
            }
        }
    }

    struct Info {
        let slot: Slot
        let name: String
        /// 목록 칸의 빛.
        let color: NSColor
        /// 꼬리·발먼지의 입자 그림 (Assets/FX).
        var fx: GameFX.Shape? = nil
    }

    private static func row(_ slot: Slot, _ name: String, _ hex: UInt32,
                            fx: GameFX.Shape? = nil) -> Info {
        Info(slot: slot, name: name, color: NSColor(hex: hex), fx: fx)
    }

    private static let info: [Cosmetic: Info] = [
        // 트랙: 무대와 게임에서 달리는 곳
        .cloudWoodsTrack: row(.track, "구름 숲", 0x48A4AC),
        .mintForestTrack: row(.track, "연둣빛 숲", 0x6EAD6A),
        .greenForestTrack: row(.track, "초록 숲", 0x699A49),
        .mistForestTrack: row(.track, "신비한 숲", 0x587548),
        .tallForestTrack: row(.track, "키 큰 숲", 0x344B2C),
        .bushForestTrack: row(.track, "덤불 숲", 0x73A049),
        .jungleTrack: row(.track, "정글", 0x58833E),
        .redForestTrack: row(.track, "빨간 나무 숲", 0x6C9358),
        .amberForestTrack: row(.track, "황금 숲", 0x6A4F37),
        .frostForestTrack: row(.track, "서리 숲", 0x76A3A9),
        .snowPinesTrack: row(.track, "눈 내린 숲", 0x81C3CA),
        .xmasPeaksTrack: row(.track, "크리스마스 산", 0x569B91),
        .greenHillsTrack: row(.track, "푸른 언덕", 0x68B2A6),
        .flowerHillsTrack: row(.track, "꽃 언덕", 0x83DA83),
        .sunnyHillsTrack: row(.track, "햇살 언덕", 0x6A926E),
        .springFieldTrack: row(.track, "봄 들판", 0x91F787),
        .hillTownTrack: row(.track, "언덕 마을", 0xA68D7B),
        .greenVillageTrack: row(.track, "초록 마을", 0xACD7A8),
        .wheatRoadTrack: row(.track, "밀밭 길", 0xC9DB9F),
        .castleHillTrack: row(.track, "성 언덕", 0xB4CCB4),
        .forestGladeTrack: row(.track, "숲속 공터", 0x469F1A),
        .sunsetFieldTrack: row(.track, "저녁 들판", 0x636633),
        .sandDunesTrack: row(.track, "모래 언덕", 0xC6EEC1),
        .desertArchTrack: row(.track, "바위 사막", 0x9B9CA0),
        .redCanyonTrack: row(.track, "붉은 협곡", 0xCAA988),
        .pyramidTrack: row(.track, "피라미드", 0x8FF7D1),
        .sandPalaceTrack: row(.track, "모래 궁전", 0xD8A970),
        .whiteTempleTrack: row(.track, "하얀 신전", 0xCDC0A1),
        .summerBeachTrack: row(.track, "여름 해변", 0x76E4E6),
        .sandyBeachTrack: row(.track, "모래 해변", 0x4DA6B1),
        .tropicalSeaTrack: row(.track, "열대 바다", 0x67E2EC),
        .oceanDayTrack: row(.track, "낮 바다", 0x3767A9),
        .oceanSunsetTrack: row(.track, "노을 바다", 0xCD8152),
        .oceanNightTrack: row(.track, "밤바다", 0x0E4F6F),
        .underwaterTrack: row(.track, "바닷속", 0x4ECDAD),
        .deepSeaTrack: row(.track, "깊은 바다", 0x22ADB6),
        .mintSkyTrack: row(.track, "민트 하늘", 0x95F2DE),
        .goldenSkyTrack: row(.track, "황금 하늘", 0xEFC14E),
        .skyIslandsTrack: row(.track, "하늘섬", 0x82DFC3),
        .airshipTrack: row(.track, "비행선 하늘", 0x69CCD1),
        .cloudPeaksTrack: row(.track, "구름 위 설산", 0xE2EFEA),
        .emeraldCloudsTrack: row(.track, "에메랄드 구름", 0x219073),
        .pinkCloudsTrack: row(.track, "분홍 구름", 0x5A5F66),
        .pinkSunsetTrack: row(.track, "분홍 노을", 0xF4C9B7),
        .duskPeaksTrack: row(.track, "노을 산맥", 0x784F68),
        .cherryBridgeTrack: row(.track, "벚꽃 다리", 0xCECBD1),
        .trainBridgeTrack: row(.track, "기차 다리", 0xB7C4AF),
        .palaceTrack: row(.track, "기와 궁궐", 0xB2A78F),
        .greenCityTrack: row(.track, "초록빛 도시", 0xAFC582),
        .mistCityTrack: row(.track, "안개 도시", 0xAECCD6),
        .harborNightTrack: row(.track, "항구 야경", 0x56272C),
        .starCityTrack: row(.track, "별밤 도시", 0x312E59),
        .violetCityTrack: row(.track, "보랏빛 도시", 0x574064),
        .fullMoonTrack: row(.track, "보름달 밤", 0x131B40),
        .pinkCaveTrack: row(.track, "분홍 동굴", 0xAC719E),
        .crystalCaveTrack: row(.track, "수정 동굴", 0xA79AAA),
        .violetCaveTrack: row(.track, "보랏빛 동굴", 0xAF4CC5),
        .mossCaveTrack: row(.track, "이끼 동굴", 0x1E3F4A),
        .lavaCaveTrack: row(.track, "용암 동굴", 0xA43C23),
        // 꼬리
        .rainbowStarTrail: row(.trail, "무지개 별", 0xFFD45E, fx: .sprite("rainbowStar")),
        .heartTrail: row(.trail, "콩닥 하트", 0xFF6F7F, fx: .sprite("pumpingHeart")),
        .gemTrail: row(.trail, "보석 하트", 0xFF8FB8, fx: .sprite("gemHeart")),
        .coinTrail: row(.trail, "코인", 0xFFD45E, fx: .sprite("coin")),
        .candyTrail: row(.trail, "무지개 사탕", 0xFF6FA8, fx: .candy("lollipop_rainbow")),
        .swirlTrail: row(.trail, "소용돌이 사탕", 0xFFB7D5, fx: .candy("swirl_pink")),
        .fireTrail: row(.trail, "불꽃", 0xFF7A2F, fx: .sprite("firePlume")),
        .smokeTrail: row(.trail, "구름", 0xE8EEF5, fx: .sprite("puff")),
        .magicTrail: row(.trail, "마법 가루", 0xC68CFF, fx: .sprite("plasmaSparkle")),
        .bubbleTrail: row(.trail, "분홍 방울", 0xFF9AE0, fx: .sprite("plasmaBubble")),
        .waterTrail: row(.trail, "물빛", 0x5CA8FF, fx: .sprite("water")),
        .cometTrail: row(.trail, "혜성", 0xE8F4FF, fx: .sprite("pure")),
        // 발먼지
        .puffDust: row(.dust, "퐁퐁 구름", 0xE8EEF5, fx: .sprite("puff")),
        .smokeDust: row(.dust, "흙먼지", 0xB8B0A8, fx: .sprite("smokePoff")),
        .heartDust: row(.dust, "하트", 0xFF6F7F, fx: .sprite("pumpingHeart")),
        .starDust: row(.dust, "무지개 별", 0xFFD45E, fx: .sprite("rainbowStar")),
        .sparkleDust: row(.dust, "반짝이", 0xC68CFF, fx: .sprite("plasmaSparkle")),
        .coinDust: row(.dust, "코인", 0xFFD45E, fx: .sprite("coin")),
        .candyDust: row(.dust, "젤리", 0xFF8FB8, fx: .candy("jelly_pink")),
        .bubbleDust: row(.dust, "보라 방울", 0xB48CFF, fx: .sprite("plasmaPuff")),
        // 부딪힘
        .starburstCrash: row(.crash, "별 터짐", 0xBFE6FF),
        .ringCrash: row(.crash, "링 폭발", 0xFFB03D),
        .boomCrash: row(.crash, "쾅!", 0xFF8A3D),
        .fireCrash: row(.crash, "불꽃 펑", 0xFF7A2F),
        .candyCrash: row(.crash, "사탕 펑", 0xFF6FA8),
        .heartCrash: row(.crash, "하트 펑", 0xFF6F7F),
        .gemCrash: row(.crash, "보석 비", 0xFF8FB8),
        .coinCrash: row(.crash, "코인 비", 0xFFD45E),
        .magicCrash: row(.crash, "마법", 0xC68CFF),
    ]

    var id: String { rawValue }
    var details: Info { Self.info[self]! }
    var slot: Slot { details.slot }
    var name: String { details.name }
    var color: NSColor { details.color }
    var fx: GameFX.Shape? { details.fx }
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

    /// 능력 칸의 그림 (Assets/FX). 게임에서 그 능력이 보이는 모습이다.
    var sprite: String {
        switch self {
        case .airJump: "puff"
        case .shield: "pumpingHeart"
        case .magnet: "candyPop_blue"
        case .glide: "rainbowStar"
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
    /// 같이 달리는 펫. 기본 펫, Petdex 펫, 내 그림 어느 것이든 데려간다.
    var companion: RunnerCharacter? {
        AppSettings.character(forRunnerID: companionID)
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
