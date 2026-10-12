import AppKit
import Combine
import GameCore

/// 미니게임 러너에 다는 꾸미기. 그림만 바뀌고 판정과 점수는 같다.
/// 이름·값·등급·색·그림은 아래 `info` 표 한 곳에서 정한다. 동료는 꾸미기가 아니라 Petdex 펫을 데려간다 (`GameWallet.companionID`).
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
        let price: Int
        let rarity: Rarity
        /// 발먼지 색, 꼬리의 바탕색, 미리보기 빛.
        let color: NSColor
        /// Fluent Emoji 그림 이름 (Assets/Fluent). 꼬리·발먼지·부딪힘의 입자로 쓴다.
        var art: String? = nil
        /// 그림이 없는 물건(날씨)을 목록에 보일 SF Symbol.
        var symbol: String? = nil
    }

    private static func row(_ slot: Slot, _ name: String, _ price: Int, _ rarity: Rarity, _ hex: UInt32,
                            art: String? = nil, symbol: String? = nil) -> Info {
        Info(slot: slot, name: name, price: price, rarity: rarity, color: NSColor(hex: hex), art: art, symbol: symbol)
    }

    private static let info: [Cosmetic: Info] = [
        // 트랙: 무대와 게임에서 달리는 곳
        .pineTrack: row(.track, "소나무 숲", 260, .common, 0x3D6B52),
        .autumnTrack: row(.track, "가을 들판", 300, .common, 0xC07A3A),
        .desertTrack: row(.track, "사막", 340, .rare, 0xD9A066),
        .beachTrack: row(.track, "해변", 380, .rare, 0x3E8FB8),
        .snowTrack: row(.track, "설원", 420, .rare, 0xB9CDE0),
        .blossomTrack: row(.track, "벚꽃길", 560, .epic, 0xE9AFC8),
        .peakTrack: row(.track, "설산", 680, .epic, 0x8C9DB8),
        .cityTrack: row(.track, "도시 야경", 1100, .legendary, 0xFFD27A),
        // 날씨: 무대와 게임 하늘에 떠도는 입자
        .drizzleWeather: row(.weather, "이슬비", 180, .common, 0x9DB8D9, symbol: "cloud.drizzle.fill"),
        .snowWeather: row(.weather, "눈", 260, .rare, 0xDCE8F2, symbol: "snowflake"),
        .petalWeather: row(.weather, "꽃잎", 300, .rare, 0xF7B6CF, symbol: "camera.macro"),
        .leafWeather: row(.weather, "단풍", 300, .rare, 0xE0702F, symbol: "leaf.fill"),
        .fogWeather: row(.weather, "안개", 420, .epic, 0xC9D4E3, symbol: "cloud.fog.fill"),
        .fireflyWeather: row(.weather, "반딧불", 520, .epic, 0xD8F27A, symbol: "sparkle"),
        // 꼬리
        .sparkleTrail: row(.trail, "반짝이", 120, .common, 0xFFD45E),
        .heartTrail: row(.trail, "하트", 140, .common, 0xFF8FB8),
        .noteTrail: row(.trail, "음표", 160, .common, 0xB79CFF),
        .cometTrail: row(.trail, "혜성", 180, .rare, 0x8FD3FF),
        .smokeTrail: row(.trail, "증기", 200, .rare, 0xE8EEF5),
        .blossomTrail: row(.trail, "벚꽃", 260, .rare, 0xFFB7D5, art: "blossom"),
        .cloverTrail: row(.trail, "네잎클로버", 260, .rare, 0x7BD88F, art: "clover"),
        .fireTrail: row(.trail, "불꽃", 240, .rare, 0xFF7A2F),
        .mapleTrail: row(.trail, "단풍", 300, .epic, 0xFF8A3D, art: "maple"),
        .snowTrail: row(.trail, "눈송이", 300, .epic, 0xBFE6FF, art: "snowflake"),
        .bubbleTrail: row(.trail, "비눗방울", 340, .epic, 0xA8E4FF, art: "bubbles"),
        .magicTrail: row(.trail, "마법 별", 280, .epic, 0xC68CFF),
        .rainbowTrail: row(.trail, "무지개", 300, .epic, 0xFF9E3D),
        .candyTrail: row(.trail, "사탕", 420, .epic, 0xFF6FA8, art: "candy"),
        .sparkTrail: row(.trail, "번개", 380, .legendary, 0x7FE9FF),
        // 발먼지
        .heartDust: row(.dust, "분홍", 40, .common, 0xFF8FB8),
        .starDust: row(.dust, "하늘빛", 60, .common, 0x8FD3FF),
        .goldDust: row(.dust, "금빛", 90, .common, 0xFFD45E),
        .cloudDust: row(.dust, "구름", 120, .rare, 0xE8EEF5),
        .rainbowDust: row(.dust, "무지개", 150, .rare, 0x5BD86B),
        .noteDust: row(.dust, "콧노래", 220, .rare, 0xB79CFF, art: "note"),
        .sparkleDust: row(.dust, "반짝반짝", 320, .epic, 0xFFE58A, art: "sparkles"),
        // 부딪힘
        .heartCrash: row(.crash, "하트 펑", 100, .common, 0xFF8FB8),
        .fireworksCrash: row(.crash, "폭죽", 200, .rare, 0xFFE14D),
        .flameCrash: row(.crash, "불기둥", 260, .rare, 0xFF8A3D),
        .boomCrash: row(.crash, "쾅!", 280, .rare, 0xFFB03D, art: "collision"),
        .coinCrash: row(.crash, "코인 비", 350, .epic, 0xFFD45E),
        .balloonCrash: row(.crash, "풍선", 380, .epic, 0xFF5C5C, art: "balloon"),
        .magicCrash: row(.crash, "마법진", 400, .epic, 0xC68CFF),
        .sweetCrash: row(.crash, "간식 비", 450, .epic, 0xFFB0C8, art: "donut"),
        .confettiCrash: row(.crash, "축하 파티", 900, .legendary, 0xFFD45E, art: "confetti"),
    ]

    var id: String { rawValue }
    var details: Info { Self.info[self]! }
    var slot: Slot { details.slot }
    var name: String { details.name }
    var price: Int { details.price }
    var rarity: Rarity { details.rarity }
    var color: NSColor { details.color }
    var art: String? { details.art }
    var symbol: String? { details.symbol }

    /// 예전에 팔던 물건(동료, 색)의 값. 상점에서 뺄 때 가지고 있던 만큼 코인으로 보상한다 (상자에서 얻은 것도 같은 값).
    static let retiredPrices: [String: Int] = [
        "tinyBuddy": 220, "greenBuddy": 300, "blueBuddy": 300, "yellowBuddy": 340, "pinkBuddy": 380, "beigeBuddy": 450,
        "boxBuddy": 600, "chickPet": 260, "hamsterPet": 280, "duckPet": 280, "rabbitPet": 300, "dogPet": 320,
        "catPet": 320, "hedgehogPet": 420, "penguinPet": 450, "koalaPet": 450, "foxPet": 480, "pandaPet": 520,
        "otterPet": 520, "slothPet": 560, "parrotPet": 600, "tigerPet": 650, "teddyPet": 650, "snowmanPet": 700,
        "ghostPet": 750, "trexPet": 1200, "unicornPet": 1400, "dragonPet": 1600,
        "theme:ruby": 250, "theme:mint": 250, "theme:gold": 400, "theme:aurora": 800,
    ]

    /// 상점에서 뺀 머리·얼굴 꾸미기의 정가.
    static let retiredHeadPrices: [String: Int] = [
        "capHat": 180, "ribbonHat": 200, "tulipHat": 180, "mushroomHat": 220, "ladybugHat": 240, "sunHat": 260, "hibiscusHat": 280, "militaryHat": 300, "headphoneHat": 320, "helmetHat": 340, "sunflowerHat": 360, "chickHat": 420, "gradHat": 420, "pumpkinHat": 480, "hamsterHat": 520, "cloudHat": 560, "topHat": 650, "rainbowHat": 800, "starHat": 900, "fireHat": 1200, "crownHat": 1500, "bandageFace": 150, "glassesFace": 200, "heartFace": 240, "gogglesFace": 300, "lollipopFace": 340, "divingFace": 420, "sunglassesFace": 450,
    ]

    /// 상점에서 뺀 등 꾸미기의 정가. 가지고 있었으면 한 번 돌려준다.
    static let retiredBackPrices: [String: Int] = [
        "shieldBack": 220, "backpackBack": 260, "guitarBack": 340, "balloonBack": 380, "kiteBack": 450,
        "butterflyBack": 520, "parrotBack": 600, "rocketBack": 750, "wingBack": 1300,
    ]
}

extension Rarity {
    var title: String {
        switch self {
        case .common: "일반"
        case .rare: "희귀"
        case .epic: "영웅"
        case .legendary: "전설"
        }
    }

    var color: NSColor {
        switch self {
        case .common: NSColor(hex: 0xA7B0BE)
        case .rare: NSColor(hex: 0x4DA3FF)
        case .epic: NSColor(hex: 0xB57BFF)
        case .legendary: NSColor(hex: 0xFFC233)
        }
    }
}

/// 상점에서 단계별로 사는 능력. 단계마다 값이 오른다.
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

    /// 단계별 값. 개수가 최대 단계다.
    var prices: [Int] {
        switch self {
        case .airJump: [600, 1800]
        case .shield: [300, 800, 1500]
        case .magnet: [250, 600, 1100]
        case .glide: [500]
        }
    }

    var maxLevel: Int { prices.count }

    func detail(level: Int) -> String {
        switch self {
        case .airJump: level >= 2 ? "공중에서 두 번 더 뛰기" : "공중에서 한 번 더 뛰기"
        case .shield: "한 판에 \(max(level, 1))번 부딪혀도 버팀"
        case .magnet: "가까운 코인을 끌어옴 (범위 \(max(level, 1))단계)"
        case .glide: "뛴 채 누르고 있으면 천천히 내려옴"
        }
    }
}

/// 게임 코인 지갑, 산 꾸미기, 오늘의 미션. 이 Mac에만 저장한다.
final class GameWallet: ObservableObject {
    static let shared = GameWallet()

    private enum Key {
        static let coins = "gameWalletCoins"
        static let owned = "gameCosmeticsOwned"
        static let equipped = "gameCosmeticsEquipped"
        static let missions = "gameDailyMissions"
        static let unlocked = "gameUnlocked"
        static let companion = "gameCompanion"
        static let retired = "gameRetiredRefunded"
        static let retiredBack = "gameRetiredBackRefunded"
        static let retiredHead = "gameRetiredHeadRefunded"
        static let abilityLevels = "gameAbilityLevels"
        static let abilitiesOff = "gameAbilitiesOff"
        static let weekly = "gameWeeklyChallenges"
        static let achievements = "gameAchievements"
        static let pending = "gamePendingRewards"
        static let level = "gameRunnerLevel"
        static let attendance = "gameAttendance"
        static let boxes = "gameLuckyBoxes"
        static let deal = "gameDailyDeal"
    }

    private let defaults = UserDefaults.standard

    @Published private(set) var coins: Int { didSet { defaults.set(coins, forKey: Key.coins) } }
    @Published private(set) var owned: Set<Cosmetic> {
        didSet { defaults.set(owned.map(\.rawValue), forKey: Key.owned) }
    }
    @Published private(set) var equipped: Set<Cosmetic> {
        didSet { defaults.set(equipped.map(\.rawValue), forKey: Key.equipped) }
    }
    @Published private var stored: DailyMissions
    @Published private var storedWeekly: DailyMissions
    @Published private(set) var achievements: Achievements {
        didSet { save(achievements, Key.achievements) }
    }
    /// 채웠지만 아직 받지 않은 보상. 퀘스트 탭에서 눌러 받는다.
    @Published private(set) var pending: [PendingReward] { didSet { save(pending, Key.pending) } }
    @Published private(set) var runnerLevel: RunnerLevel { didSet { save(runnerLevel, Key.level) } }
    @Published private(set) var attendance: Attendance { didSet { save(attendance, Key.attendance) } }
    /// 공짜로 열 수 있는 행운 상자 (레벨·출석 보상).
    @Published private(set) var freeBoxes: Int { didSet { defaults.set(freeBoxes, forKey: Key.boxes) } }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    /// 능력별 산 단계와, 사 두고 끈 능력.
    @Published private(set) var abilityLevels: [String: Int] {
        didSet { defaults.set(abilityLevels, forKey: Key.abilityLevels) }
    }
    @Published private(set) var abilitiesOff: Set<String> {
        didSet { defaults.set(Array(abilitiesOff), forKey: Key.abilitiesOff) }
    }
    /// 게임과 무대에서 러너 뒤를 따라 달리는 Petdex 펫 (`PetdexStore.storageID`). 없으면 nil.
    @Published var companionID: String? {
        didSet { defaults.set(companionID, forKey: Key.companion) }
    }

    private init() {
        coins = defaults.integer(forKey: Key.coins)
        let names = { (key: String) in Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(Cosmetic.init)) }
        let owned = names(Key.owned)
        self.owned = owned
        equipped = names(Key.equipped).intersection(owned)
        companionID = defaults.string(forKey: Key.companion)
        abilityLevels = defaults.dictionary(forKey: Key.abilityLevels) as? [String: Int] ?? [:]
        abilitiesOff = Set(defaults.stringArray(forKey: Key.abilitiesOff) ?? [])
        stored = defaults.data(forKey: Key.missions).flatMap { try? JSONDecoder().decode(DailyMissions.self, from: $0) }
            ?? DailyMissions(day: Self.today())
        storedWeekly = defaults.data(forKey: Key.weekly).flatMap { try? JSONDecoder().decode(DailyMissions.self, from: $0) }
            ?? .week(Self.thisWeek())
        achievements = defaults.data(forKey: Key.achievements).flatMap { try? JSONDecoder().decode(Achievements.self, from: $0) }
            ?? Achievements()
        pending = (defaults.data(forKey: Key.pending).flatMap { try? JSONDecoder().decode([PendingReward].self, from: $0) } ?? [])
            .map(Self.renamingTitles)
        runnerLevel = defaults.data(forKey: Key.level).flatMap { try? JSONDecoder().decode(RunnerLevel.self, from: $0) }
            ?? RunnerLevel()
        attendance = defaults.data(forKey: Key.attendance).flatMap { try? JSONDecoder().decode(Attendance.self, from: $0) }
            ?? Attendance()
        freeBoxes = defaults.integer(forKey: Key.boxes)
        refundRetired()
        // 저장된 원본 목록을 한 번만 읽어 모든 환불에 쓴다. 앞 환불이 목록을 고쳐 쓰면 뒤 환불이 셀 것을 잃는다
        let saved = defaults.stringArray(forKey: Key.owned) ?? []
        let refunded = [refundRemoved(Cosmetic.retiredBackPrices, key: Key.retiredBack, from: saved),
                        refundRemoved(Cosmetic.retiredHeadPrices, key: Key.retiredHead, from: saved)]
        if refunded.contains(true) {
            // 저장된 목록에서도 뺀 물건을 지워, 옛 값을 다시 읽어 셈하는 일이 없게 한다
            defaults.set(owned.map(\.rawValue), forKey: Key.owned)
            defaults.set(equipped.map(\.rawValue), forKey: Key.equipped)
        }
    }

    /// 상점에서 뺀 동료와 색을 가지고 있었으면 그 값을 한 번 보상한다. 색은 이제 누구나 고를 수 있다.
    private func refundRetired() {
        guard !defaults.bool(forKey: Key.retired) else { return }
        let bought = (defaults.stringArray(forKey: Key.owned) ?? []) + (defaults.stringArray(forKey: Key.unlocked) ?? [])
        coins += bought.compactMap { Cosmetic.retiredPrices[$0] }.reduce(0, +)
        defaults.removeObject(forKey: Key.unlocked)
        defaults.set(true, forKey: Key.retired)
    }

    /// 상점에서 뺀 꾸미기를 가지고 있었으면 정가를 한 번 돌려준다 (행운 상자로 받은 것도 같은 값).
    /// 이번에 처음 환불했으면 true.
    private func refundRemoved(_ prices: [String: Int], key: String, from bought: [String]) -> Bool {
        guard !defaults.bool(forKey: key) else { return false }
        coins += bought.compactMap { prices[$0] }.reduce(0, +)
        defaults.set(true, forKey: key)
        return true
    }

    /// 업적·미션 이름을 바꾸기 전에 쌓인 보상도 새 이름으로 보여 준다.
    private static func renamingTitles(_ reward: PendingReward) -> PendingReward {
        let renamed = ["꾸준한 러너": "꾸준히 달리기", "코인 수집가": "코인 모으기", "기록 사냥꾼": "최고 점수",
                       "점프 장인": "점프", "아슬아슬 달인": "아슬아슬 피하기", "고스트 버스터": "고스트 이기기",
                       "미션 해결사": "미션 채우기"]
        var title = renamed.reduce(reward.title) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        title = title.replacingOccurrences(of: #"아슬! (\d+)번"#, with: "아슬아슬하게 $1번 피하기", options: .regularExpression)
        guard title != reward.title else { return reward }
        return PendingReward(id: reward.id, title: title, coins: reward.coins, boxes: reward.boxes)
    }

    /// 데려갈 동료 그림. 펫을 지웠으면 nil.
    var companion: RunnerCharacter? {
        companionID.flatMap { PetdexStore.shared.pet(storageID: $0) }.flatMap(PetdexStore.shared.character(for:))
    }

    /// 날을 이어서 셀 수 있는 번호 (2001년 1월 1일부터 지난 날 수, 이 Mac의 시간대).
    static func dayNumber(_ date: Date = Date()) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0)),
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// 이번 주 (ISO 주, 월요일 시작). yyyyww.
    static func thisWeek(_ date: Date = Date()) -> Int {
        let parts = Calendar(identifier: .iso8601).dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return (parts.yearForWeekOfYear ?? 0) * 100 + (parts.weekOfYear ?? 0)
    }

    /// 이번 주 도전. 주가 바뀌었으면 새 도전.
    var weekly: DailyMissions {
        let week = Self.thisWeek()
        return storedWeekly.day == week ? storedWeekly : .week(week)
    }

    static func today(_ date: Date = Date()) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// 오늘의 미션. 날이 바뀌었으면 새 미션.
    var missions: DailyMissions {
        let day = Self.today()
        return stored.day == day ? stored : DailyMissions(day: day)
    }

    /// 화면 점검 도구가 저장하지 않고 꾸미기를 달아 볼 때.
    var preview: Set<Cosmetic>?

    /// 상점에서 마우스를 올려 써 보는 물건 하나. 그 갈래만 덮어써서, 써 보는 동안 다른 갈래를 바꿔도 그대로 반영된다.
    var tryingOn: Cosmetic?

    func equipped(_ slot: Cosmetic.Slot) -> Cosmetic? {
        if let tryingOn, tryingOn.slot == slot { return tryingOn }
        return (preview ?? equipped).first { $0.slot == slot }
    }

    /// 미션·도전·업적·레벨·출석을 채워 생긴 보상. 같은 id는 한 번만 생긴다.
    struct PendingReward: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let coins: Int
        var boxes = 0
    }

    typealias Reward = PendingReward

    /// 판이 끝났다. 먹은 코인은 바로 넣고, 새로 채운 퀘스트 보상은 받기 전까지 쌓아 둔다. 새로 생긴 보상을 돌려준다.
    func finishRun(_ run: DailyMissions.Run, bonusCoins: Int = 0) -> [Reward] {
        var board = missions
        let daily = board.record(run)
        stored = board
        if let data = try? JSONEncoder().encode(board) { defaults.set(data, forKey: Key.missions) }
        var week = weekly
        let challenges = week.record(run)
        storedWeekly = week
        if let data = try? JSONEncoder().encode(week) { defaults.set(data, forKey: Key.weekly) }
        var book = achievements
        let tiers = book.record(run, missionsDone: daily.count + challenges.count)
        achievements = book
        var rewards: [Reward] = []
        for mission in daily {
            let index = board.missions.firstIndex(of: mission) ?? 0
            rewards.append(Reward(id: "d\(board.day)-\(index)", title: mission.title(weekly: false), coins: mission.reward))
        }
        for challenge in challenges {
            let index = week.missions.firstIndex(of: challenge) ?? 0
            rewards.append(Reward(id: "w\(week.day)-\(index)", title: challenge.title(weekly: true), coins: challenge.reward))
        }
        rewards += tiers.map { Reward(id: "a\($0.kind.rawValue)-\($0.level)", title: $0.title, coins: $0.reward) }
        var level = runnerLevel
        for reached in level.add(RunnerLevel.xp(for: run)) {
            let reward = RunnerLevel.reward(reaching: reached)
            rewards.append(Reward(id: "l\(reached)", title: "러너 레벨 \(reached) 달성", coins: reward.coins, boxes: reward.box ? 1 : 0))
        }
        runnerLevel = level
        var days = attendance
        let today = Self.dayNumber()
        if let streak = days.check(in: today) {
            let reward = Attendance.reward(day: streak)
            rewards.append(Reward(id: "s\(today)", title: "출석 \(streak)일째", coins: reward.coins, boxes: reward.box ? 1 : 0))
        }
        attendance = days
        let known = Set(pending.map(\.id))
        let fresh = rewards.filter { !known.contains($0.id) }
        pending += fresh
        coins += run.coins + bonusCoins
        return fresh
    }

    /// 쌓인 보상 하나를 받는다.
    @discardableResult
    func claim(_ id: String) -> Reward? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let reward = pending.remove(at: index)
        coins += reward.coins
        freeBoxes += reward.boxes
        return reward
    }

    /// 쌓인 보상을 모두 받는다. 받은 코인 합을 돌려준다.
    @discardableResult
    func claimAll() -> Int {
        let total = pending.reduce(0) { $0 + $1.coins }
        freeBoxes += pending.reduce(0) { $0 + $1.boxes }
        coins += total
        pending.removeAll()
        return total
    }

    // MARK: 행운 상자 · 오늘의 특가

    static let boxPrice = 200
    /// 모두 모은 뒤 연 상자는 이만큼 돌려준다.
    static let boxRefund = 120

    enum BoxResult: Equatable {
        case item(Cosmetic)
        case refund(Int)
    }

    /// 아직 모으지 못한 꾸미기가 있는지. 다 모았으면 코인으로는 열 수 없다 (열수록 코인이 줄기만 해서).
    var hasUncollected: Bool { Cosmetic.allCases.contains { !owned.contains($0) } }

    var canOpenBox: Bool { freeBoxes > 0 || (hasUncollected && coins >= Self.boxPrice) }

    /// 행운 상자를 연다. 공짜 상자가 있으면 그것부터 쓴다. 아직 없는 꾸미기 가운데 등급 확률로 하나가 나온다.
    func openBox() -> BoxResult? {
        guard canOpenBox else { return nil }
        if freeBoxes > 0 { freeBoxes -= 1 } else { coins -= Self.boxPrice }
        let candidates = Cosmetic.allCases.filter { !owned.contains($0) }.map { (item: $0, rarity: $0.rarity) }
        guard let item = LuckyBox.pick(from: candidates, roll: .random(in: 0..<1), second: .random(in: 0..<1)) else {
            coins += Self.boxRefund
            return .refund(Self.boxRefund)
        }
        owned.insert(item)
        return .item(item)
    }

    /// 오늘의 특가: 그날 처음 볼 때 아직 없는 희귀 이상 꾸미기 하나를 골라 하루 동안 40% 싸게 판다.
    /// 고른 물건은 저장해 두어, 사거나 상자에서 얻어도 그날은 다른 물건으로 바뀌지 않는다.
    var dailyDeal: Cosmetic? {
        let today = Self.today()
        let saved = defaults.string(forKey: Key.deal)?.split(separator: ":")
        // 상점에서 뺀 물건이 저장돼 있으면 새로 고른다
        if let saved, saved.count == 2, Int(saved[0]) == today, let item = Cosmetic(rawValue: String(saved[1])) {
            return owned.contains(item) ? nil : item
        }
        let left = Cosmetic.allCases.filter { !owned.contains($0) && $0.rarity >= .rare }
        guard !left.isEmpty else { return nil }
        let item = left[today % left.count]
        defaults.set("\(today):\(item.rawValue)", forKey: Key.deal)
        return item
    }

    static let dealDiscount = 0.4

    func price(of item: Cosmetic) -> Int {
        item == dailyDeal ? Int((Double(item.price) * (1 - Self.dealDiscount)).rounded()) : item.price
    }

    /// 모은 꾸미기 수와 전체.
    var collection: (owned: Int, total: Int) {
        (owned.intersection(Cosmetic.allCases).count, Cosmetic.allCases.count)
    }

    func level(_ ability: Ability) -> Int { min(abilityLevels[ability.rawValue] ?? 0, ability.maxLevel) }
    func isOn(_ ability: Ability) -> Bool { level(ability) > 0 && !abilitiesOff.contains(ability.rawValue) }

    /// 다음 단계 값. 최대면 nil.
    func nextPrice(_ ability: Ability) -> Int? {
        let current = level(ability)
        return current < ability.maxLevel ? ability.prices[current] : nil
    }

    /// 다음 단계를 산다. 산 능력은 바로 켠다.
    @discardableResult
    func upgrade(_ ability: Ability) -> Bool {
        guard let price = nextPrice(ability), coins >= price else { return false }
        coins -= price
        abilityLevels[ability.rawValue] = level(ability) + 1
        abilitiesOff.remove(ability.rawValue)
        return true
    }

    func toggle(_ ability: Ability) {
        guard level(ability) > 0 else { return }
        if abilitiesOff.contains(ability.rawValue) { abilitiesOff.remove(ability.rawValue) } else { abilitiesOff.insert(ability.rawValue) }
    }

    /// 다음 판에 쓸 능력 (켜 둔 것만).
    var abilities: RunnerGame.Abilities {
        RunnerGame.Abilities(airJumps: isOn(.airJump) ? level(.airJump) : 0,
                             shields: isOn(.shield) ? level(.shield) : 0,
                             magnet: isOn(.magnet) ? level(.magnet) : 0,
                             glide: isOn(.glide))
    }


    /// 없으면 사서 달고, 있으면 달거나 뗀다. 코인이 모자라면 false.
    @discardableResult
    func choose(_ item: Cosmetic) -> Bool {
        if !owned.contains(item) {
            let price = price(of: item)
            guard coins >= price else { return false }
            coins -= price
            owned.insert(item)
        }
        if equipped.contains(item) {
            equipped.remove(item)
        } else {
            equipped = equipped.filter { $0.slot != item.slot }.union([item])
        }
        return true
    }
}

extension DailyMissions.Mission {
    var title: String { title(weekly: false) }

    func title(weekly: Bool) -> String {
        let text = switch kind {
        case .coins: "코인 \(target)개 먹기"
        case .nearMisses: "아슬아슬하게 \(target)번 피하기"
        case .score: "한 판 \(target)점 넘기"
        case .plays: "\(target)판 하기"
        case .jumps: "\(target)번 뛰기"
        case .ghostWins: target == 1 ? "고스트 이기기" : "고스트 \(target)번 이기기"
        case .totalScore: "점수 합 \(target.formatted())점"
        }
        return weekly ? "주간 · \(text)" : text
    }

    var icon: String {
        switch kind {
        case .coins: "dollarsign.circle.fill"
        case .nearMisses: "bolt.fill"
        case .score: "flag.checkered"
        case .plays: "gamecontroller.fill"
        case .jumps: "arrow.up.circle.fill"
        case .ghostWins: "person.2.fill"
        case .totalScore: "sum"
        }
    }
}

extension Achievements.Kind {
    var name: String {
        switch self {
        case .plays: "꾸준히 달리기"
        case .coins: "코인 모으기"
        case .bestScore: "최고 점수"
        case .jumps: "점프"
        case .nearMisses: "아슬아슬 피하기"
        case .ghostWins: "고스트 이기기"
        case .missions: "미션 채우기"
        }
    }

    func goal(_ target: Int) -> String {
        let n = target.formatted()
        return switch self {
        case .plays: "\(n)판 달리기"
        case .coins: "코인 \(n)개 모으기"
        case .bestScore: "한 판 \(n)점"
        case .jumps: "\(n)번 뛰기"
        case .nearMisses: "아슬아슬하게 \(n)번 피하기"
        case .ghostWins: "고스트 \(n)번 이기기"
        case .missions: "미션·도전 \(n)개 채우기"
        }
    }

    var icon: String {
        switch self {
        case .plays: "figure.run"
        case .coins: "dollarsign.circle.fill"
        case .bestScore: "trophy.fill"
        case .jumps: "arrow.up.circle.fill"
        case .nearMisses: "bolt.fill"
        case .ghostWins: "person.2.fill"
        case .missions: "checklist"
        }
    }
}

extension Achievements.Tier {
    static let numerals = ["Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ"]

    var title: String { "업적 · \(kind.name) \(Self.numerals[min(level, Self.numerals.count - 1)])" }
}
