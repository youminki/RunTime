import AppKit
import Combine
import GameCore

/// 미니게임 러너에 다는 꾸미기. 그림만 바뀌고 판정과 점수는 같다.
/// 이름·색·그림은 아래 `info` 표 한 곳에서 정한다. 동료는 꾸미기가 아니라 Petdex 펫을 데려간다 (`GameDecor.companionID`).
enum Cosmetic: String, CaseIterable, Identifiable {
    case rainbowStarTrail, heartTrail, noteTrail, petalTrail, leafTrail, snowTrail, bubbleTrail, rainbowTrail, fireTrail
    case fireflyTrail, coinTrail, candyTrail
    case puffDust, smokeDust, leafDust, petalDust, starDust, heartDust, dropDust, snowDust, sparkleDust
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
    case starburstCrash, heartCrash, petalCrash, coinCrash, fireCrash, magicCrash, snowCrash, boomCrash, candyCrash
    case butterflyAura, glitterAura, heartPopAura, petalAura, snowAura, fireflyAura, bubbleAura, starAura, noteAura

    /// 꾸미기를 도트 효과로 바꾸며 빠진 것. 쓰던 사람은 가장 비슷한 새 꾸미기로 옮긴다.
    static let renamed: [String: Cosmetic] = [
        "gemTrail": .heartTrail, "swirlTrail": .candyTrail, "smokeTrail": .bubbleTrail, "magicTrail": .rainbowStarTrail,
        "waterTrail": .bubbleTrail, "cometTrail": .rainbowStarTrail, "coinDust": .starDust, "candyDust": .heartDust, "bubbleDust": .sparkleDust, "ringCrash": .magicCrash,
        "gemCrash": .heartCrash, "heartAura": .heartPopAura,
    ]

    enum Slot: CaseIterable {
        case track, trail, aura, dust, crash

        var title: String {
            switch self {
            case .track: "트랙"
            case .trail: "꼬리"
            case .dust: "발먼지"
            case .crash: "부딪힘"
            case .aura: "주변 효과"
            }
        }
    }

    struct Info {
        let slot: Slot
        let name: String
        /// 목록 칸의 빛.
        let color: NSColor
        /// 입자·장식 그림 이름 (`PixelFX`).
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
        // 꼬리: 모두 같은 결의 도트 그림 (PixelFX)
        .rainbowStarTrail: row(.trail, "별가루", 0xFFD84A, fx: .sprite("star|sparkle")),
        .heartTrail: row(.trail, "콩닥 하트", 0xFF5C7A, fx: .sprite("heart")),
        .noteTrail: row(.trail, "음표", 0x7A95FF, fx: .sprite("note")),
        .petalTrail: row(.trail, "벚꽃잎", 0xFFB7CF, fx: .sprite("petal")),
        .leafTrail: row(.trail, "나뭇잎", 0x86D96F, fx: .sprite("leaf")),
        .snowTrail: row(.trail, "눈송이", 0xBFE2FF, fx: .sprite("snow")),
        .bubbleTrail: row(.trail, "비눗방울", 0x8FDFFF, fx: .sprite("bubble")),
        .rainbowTrail: row(.trail, "무지개", 0xFFA24A, fx: .sprite("rainbow")),
        .fireTrail: row(.trail, "불꽃", 0xFF8A2A, fx: .sprite("flame")),
        .fireflyTrail: row(.trail, "반딧불", 0xE2FF7A, fx: .sprite("firefly")),
        .coinTrail: row(.trail, "코인", 0xFFD84A, fx: .sprite("coin")),
        .candyTrail: row(.trail, "막대사탕", 0xFF7FB3, fx: .sprite("candyPink|candyBlue|candyYellow|candyTeal")),
        // 발먼지
        .puffDust: row(.dust, "퐁퐁 구름", 0xE8EEF5, fx: .sprite("cloud")),
        .smokeDust: row(.dust, "흙먼지", 0xD8C3A5, fx: .sprite("dust")),
        .leafDust: row(.dust, "풀잎", 0x86D96F, fx: .sprite("leaf")),
        .petalDust: row(.dust, "꽃잎", 0xFFB7CF, fx: .sprite("petal")),
        .starDust: row(.dust, "별", 0xFFD84A, fx: .sprite("star")),
        .heartDust: row(.dust, "하트", 0xFF5C7A, fx: .sprite("heart")),
        .dropDust: row(.dust, "물방울", 0x6CC4FF, fx: .sprite("drop")),
        .snowDust: row(.dust, "눈", 0xBFE2FF, fx: .sprite("snow")),
        .sparkleDust: row(.dust, "반짝이", 0xD9C6FF, fx: .sprite("sparkle")),
        // 부딪힘
        .starburstCrash: row(.crash, "별 터짐", 0xFFE15A),
        .heartCrash: row(.crash, "하트 펑", 0xFF5C7A),
        .petalCrash: row(.crash, "꽃잎 펑", 0xFFB7CF),
        .coinCrash: row(.crash, "코인 비", 0xFFD84A),
        .fireCrash: row(.crash, "불꽃 펑", 0xFF8A2A),
        .magicCrash: row(.crash, "마법 링", 0xB48CFF),
        .snowCrash: row(.crash, "눈송이 펑", 0x9CD3FF),
        .boomCrash: row(.crash, "연기 펑", 0xC9D3E0),
        .candyCrash: row(.crash, "사탕 펑", 0xFF7FB3),
        // 주변 효과: 서 있어도 몸 둘레를 늘 은은하게 감돈다. 정신없지 않게 몇 개만 둔다
        .butterflyAura: row(.aura, "나비 한 쌍", 0xF7B6E0, fx: .sprite("butterfly")),
        .glitterAura: row(.aura, "반짝반짝", 0xFFE3F1, fx: .sprite("glitter")),
        .heartPopAura: row(.aura, "하트 뿅", 0xFF8FA8, fx: .sprite("tinyHeart")),
        .petalAura: row(.aura, "꽃비", 0xFFB7CF, fx: .sprite("petal")),
        .snowAura: row(.aura, "눈 오는 날", 0xBFE2FF, fx: .sprite("snow")),
        .fireflyAura: row(.aura, "반딧불", 0xE2FF7A, fx: .sprite("firefly")),
        .bubbleAura: row(.aura, "방울방울", 0x8FDFFF, fx: .sprite("bubble")),
        .starAura: row(.aura, "별 궤도", 0xFFD84A, fx: .sprite("star|sparkle")),
        .noteAura: row(.aura, "콧노래", 0x7A95FF, fx: .sprite("note")),
    ]

    var id: String { rawValue }
    var details: Info { Self.info[self]! }
    var slot: Slot { details.slot }
    var name: String { details.name }
    var color: NSColor { details.color }
    var fx: GameFX.Shape? { details.fx }
}

/// 쓰는 꾸미기와 동료. 모두 자유롭게 켜고 끈다. 이 Mac에만 저장한다.
final class GameDecor: ObservableObject {
    static let shared = GameDecor()

    private enum Key {
        static let equipped = "gameCosmeticsEquipped"
        static let companion = "gameCompanion"
    }

    private let defaults = UserDefaults.standard

    @Published private(set) var equipped: Set<Cosmetic> {
        didSet { defaults.set(equipped.map(\.rawValue), forKey: Key.equipped) }
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
        equipped = Set((defaults.stringArray(forKey: Key.equipped) ?? []).compactMap { Cosmetic(rawValue: $0) ?? Cosmetic.renamed[$0] })
        companionID = defaults.string(forKey: Key.companion)
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

    /// 갈래마다 하나씩 쓴다. 쓰는 것을 다시 고르면 뗀다.
    func choose(_ item: Cosmetic) {
        if equipped.contains(item) {
            equipped.remove(item)
        } else {
            equipped = equipped.filter { $0.slot != item.slot }.union([item])
        }
    }
}
