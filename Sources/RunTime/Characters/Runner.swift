import Foundation

/// 앱에 실은 기본 펫 (GameArt2D의 CC0 그림, 출처는 Assets/Pets/CREDITS.txt).
/// Petdex 펫과 같은 프레임 폴더(Assets/Pets/<id>)라 같은 SheetRig로 그린다. 인터넷 없이도 첫 실행부터 달린다.
enum Runner: String, CaseIterable {
    case cat, dog, dino, girl, jack

    var displayName: String {
        switch self {
        case .cat: return "고양이"
        case .dog: return "강아지"
        case .dino: return "꼬마 공룡"
        case .girl: return "소녀"
        case .jack: return "호박 잭"
        }
    }

    /// 팝오버에서 러너를 누르면 말풍선으로 내는 소리.
    var sound: String {
        switch self {
        case .cat: return "냥"
        case .dog: return "멍멍"
        case .dino: return "크앙"
        case .girl: return "헤헤"
        case .jack: return "히히"
        }
    }

    /// 칸에 맞게 크기를 맞춘 그림. 계산은 펫마다 한 번만 한다.
    var rig: CharacterRig {
        if let cached = Self.fitted[self] { return cached }
        let folder = Bundle.assets.resourceURL?.appendingPathComponent("Assets/Pets/\(rawValue)")
        let fitted: CharacterRig = folder.flatMap(SheetRig.init(folder:)).map(FittedRig.init) ?? EmptyRig()
        Self.fitted[self] = fitted
        return fitted
    }

    private static var fitted: [Runner: CharacterRig] = [:]
}

/// 그림 폴더가 빠진 빌드에서 앱이 죽지 않게 아무것도 그리지 않는다.
private struct EmptyRig: CharacterRig {
    let palette = CharacterPalette(body: .white, belly: .white, dark: .black)
    var isPicture: Bool { true }
    func draw(_ s: Sketch) {}
}
