import AppKit

/// 꾸미기·동작 효과의 도트 그림. Petdex 펫과 도트 배경 사이에서 겉돌지 않게 모두 같은 결로 그린다:
/// 짙은 보라 외곽선, 두 단 명암, 흰 하이라이트, 같은 점 크기 (`nominal` 줄이 요청한 키가 된다).
/// 예전에 섞어 쓰던 그림(고해상도 폭발, 점 크기가 제각각인 도트)은 이름을 이어 받아 이 그림으로 그린다 (`aliases`).
/// 그림은 글자 격자로 적는다. `.`은 빈칸, 나머지 글자는 그림마다의 팔레트 색이다.
enum PixelFX {
    struct Sprite {
        let frames: [[String]]
        let palette: [Character: NSColor]
        /// 이 줄 수가 요청한 키가 된다. 줄이 더 많은 장면(커지는 터짐)은 그만큼 크게 그려진다.
        var nominal = 7
        /// 계속 도는 그림(하트 콩닥, 코인 돌기)은 초당 이만큼 넘긴다. nil이면 수명 동안 한 번 재생한다.
        var fps: Double?
    }

    /// 요청한 키보다 키워 그리는 배율. 2026-11-12 게임 화면에서 7줄 그림이 꼬리·발먼지로 잘 안 보여 맞췄다.
    static let boost: CGFloat = 1.4

    private static let outline = NSColor(hex: 0x3A2B4A)
    private static let white = NSColor.white

    private static func palette(_ colors: [Character: UInt32], outline: UInt32? = nil, alpha: [Character: CGFloat] = [:])
        -> [Character: NSColor] {
        var result: [Character: NSColor] = ["o": outline.map { NSColor(hex: $0) } ?? Self.outline, "w": white]
        for (key, hex) in colors { result[key] = NSColor(hex: hex).withAlphaComponent(alpha[key] ?? 1) }
        return result
    }

    // MARK: 작은 그림 (입자)

    private static let heart = Sprite(frames: [
        [".oo.oo.",
         "oRhoRRo",
         "oRRRRRo",
         "oRRRRro",
         ".oRRro.",
         "..oro..",
         "...o..."],
        [".ooo.ooo.",
         "oRhRoRRRo",
         "oRhRRRRRo",
         "oRRRRRRro",
         ".oRRRRro.",
         "..oRRro..",
         "...oro...",
         "....o...."],
    ], palette: palette(["R": 0xFF5C7A, "r": 0xD93A63, "h": 0xFFC2CF]), fps: 3)

    private static let star = Sprite(frames: [
        ["...o...",
         "..oYo..",
         "ooYhYoo",
         "oYYYYyo",
         ".oYYyo.",
         ".oYoyo.",
         ".oo.oo."],
        ["...o...",
         "..oho..",
         "ooYYYoo",
         "oYYhYyo",
         ".oYYyo.",
         ".oYoyo.",
         ".oo.oo."],
    ], palette: palette(["Y": 0xFFD84A, "y": 0xE8A317, "h": 0xFFF6B0]), fps: 2.5)

    private static let sparkle = Sprite(frames: [
        [".o.",
         "oSo",
         ".o."],
        ["..o..",
         ".oSo.",
         "oSwSo",
         ".oSo.",
         "..o.."],
        ["...o...",
         "...S...",
         "..oSo..",
         "oSSwSSo",
         "..oSo..",
         "...S...",
         "...o..."],
        ["..s..",
         ".....",
         "s.w.s",
         ".....",
         "..s.."],
    ], palette: palette(["S": 0xD9C6FF, "s": 0xA98BF2]))

    private static let note = Sprite(frames: [
        ["...ooo.",
         "...oNNo",
         "...o.oo",
         "...o...",
         ".ooo...",
         "oNhNo..",
         "oNNno..",
         ".ooo..."],
        ["...ooo.",
         "...oNNo",
         "...o.oo",
         "...o...",
         ".ooo...",
         "oNNho..",
         "oNNno..",
         ".ooo..."],
    ], palette: palette(["N": 0x7A95FF, "n": 0x4A63D9, "h": 0xD2DCFF]), fps: 2)

    private static let petal = Sprite(frames: [
        [".oo..",
         "ohPo.",
         "oPPpo",
         ".oPpo",
         "..oo."],
        [".ooo.",
         "oPhPo",
         "oPPpo",
         ".ooo."],
        ["..oo.",
         ".oPho",
         "opPPo",
         "opPo.",
         ".oo.."],
        [".ooo.",
         "oPPpo",
         ".ooo."],
    ], palette: palette(["P": 0xFFB7CF, "p": 0xF28AAE, "h": 0xFFE6EE]), nominal: 7, fps: 6)

    private static let leaf = Sprite(frames: [
        ["....oo",
         "..ooGo",
         ".oGhGo",
         "oGGgo.",
         "oGgo..",
         "oo...."],
        ["oo....",
         "oGoo..",
         "oGhGo.",
         ".oGGgo",
         "..oGgo",
         "....oo"],
    ], palette: palette(["G": 0x86D96F, "g": 0x52AC4C, "h": 0xD2F5B3]), fps: 4)

    private static let snow = Sprite(frames: [
        ["...b...",
         ".b.B.b.",
         "..bBb..",
         "bBBwBBb",
         "..bBb..",
         ".b.B.b.",
         "...b..."],
    ], palette: palette(["B": 0xE4F4FF, "b": 0x8EC2EE]), fps: 1)

    private static let bubble = Sprite(frames: Array(repeating:
        ["..ccc..",
         ".cCCCc.",
         "cCwCCCc",
         "cCwCCCc",
         "cCCCCCc",
         ".cCCCc.",
         "..ccc.."], count: 6) + [
        [".c...c.",
         "c.....c",
         ".......",
         ".......",
         ".......",
         "c.....c",
         ".c...c."],
        ["c.....c",
         ".......",
         ".......",
         ".......",
         ".......",
         ".......",
         "c.....c"],
    ], palette: palette(["C": 0xA6EBFF, "c": 0x5FBFE6], alpha: ["C": 0.45]))

    private static let flame = Sprite(frames: [
        ["..r..",
         ".rFr.",
         ".rFFr",
         "rFYFr",
         "rFYYr",
         "rFYFr",
         ".rrr."],
        [".r...",
         ".rFr.",
         "rFFr.",
         "rFYFr",
         "rFYYr",
         "rFYFr",
         ".rrr."],
        ["...r.",
         ".rFr.",
         ".rFFr",
         "rFYFr",
         "rYYFr",
         "rFYFr",
         ".rrr."],
    ], palette: palette(["F": 0xFF8A2A, "Y": 0xFFE15A, "r": 0xA8321F]), fps: 8)

    private static let coin = Sprite(frames: [
        ["..ooo..",
         ".oYYYo.",
         "oYhYYdo",
         "oYhYYdo",
         "oYYYYdo",
         ".oYddo.",
         "..ooo.."],
        [".ooo.",
         "oYYdo",
         "ohYdo",
         "ohYdo",
         "oYYdo",
         "oYddo",
         ".ooo."],
        [".o.",
         "oYo",
         "oho",
         "oYo",
         "oYo",
         "odo",
         ".o."],
        [".ooo.",
         "oYYdo",
         "oYhdo",
         "oYhdo",
         "oYYdo",
         "oYddo",
         ".ooo."],
    ], palette: palette(["Y": 0xFFD84A, "d": 0xD89B1A, "h": 0xFFF6B0]), fps: 8)

    private static func candy(_ main: UInt32, _ shade: UInt32) -> Sprite {
        Sprite(frames: [
            ["..ooo..",
             ".oPWPo.",
             "oPWPPWo",
             "oWPPWPo",
             "oPPWPpo",
             ".oPppo.",
             "..ooo..",
             "..oko..",
             "..oko..",
             "...o..."],
        ], palette: palette(["P": main, "p": shade, "W": 0xFFFFFF, "k": 0xF5E6D3]), nominal: 8)
    }

    private static let rainbow = Sprite(frames: [
        ["RR", "OO", "YY", "GG", "BB", "VV"],
    ], palette: palette(["R": 0xFF6B6B, "O": 0xFFA24A, "Y": 0xFFE15A, "G": 0x6BD66B, "B": 0x5AB4FF, "V": 0xA97BFF]),
       nominal: 7)

    private static let firefly = Sprite(frames: [
        [".ggg.",
         "gGGGg",
         "gGwGg",
         "gGGGg",
         ".ggg."],
        [".....",
         "..G..",
         ".GwG.",
         "..G..",
         "....."],
    ], palette: palette(["G": 0xE2FF7A, "g": 0xB8F24A], alpha: ["g": 0.45]), nominal: 6, fps: 2)

    private static func puff(_ fill: UInt32, _ shade: UInt32, _ light: UInt32, outline: UInt32) -> Sprite {
        Sprite(frames: [
            [".o.",
             "oDo",
             ".o."],
            [".oo..",
             "oDho.",
             "oDDDo",
             ".ooo."],
            ["..oo...",
             ".oDhoo.",
             "oDDDDDo",
             "oDdDDdo",
             ".ooooo."],
            ["..o....",
             ".o.h.o.",
             "o.D.D.o",
             ".d...d.",
             "..o.o.."],
        ], palette: palette(["D": fill, "d": shade, "h": light], outline: outline), nominal: 6)
    }

    private static let drop = Sprite(frames: [
        ["..o..",
         ".oBo.",
         "oBhBo",
         "oBBBo",
         "oBBbo",
         ".ooo."],
    ], palette: palette(["B": 0x6CC4FF, "b": 0x3A93E0, "h": 0xD6F0FF]), nominal: 7)

    // MARK: 주변 효과 그림

    private static let butterfly = Sprite(frames: [
        ["oo.....oo",
         "oPPo.oPPo",
         "oPhPoPhPo",
         "oPPPoPPPo",
         ".oPPoPPo.",
         "oPpo.opPo",
         ".oo...oo."],
        ["...o.o...",
         "..oPoPo..",
         ".oPhoPho.",
         ".oPPoPPo.",
         "..oPoPo..",
         "..opoPo..",
         "...o.o..."],
    ], palette: palette(["P": 0xF7B6E0, "p": 0xD98CC4, "h": 0xFFF0FA], outline: 0x6B4A7A), nominal: 7, fps: 7)

    private static let glitter = Sprite(frames: [
        [".",
         ],
        [".s.",
         "sws",
         ".s."],
        ["..s..",
         "..S..",
         "sSwSs",
         "..S..",
         "..s.."],
        [".s.",
         "sws",
         ".s."],
        ["."],
    ], palette: palette(["S": 0xFFE3F1, "s": 0xFFB8D9]), nominal: 7)

    private static let tinyHeart = Sprite(frames: [
        [".o.o.",
         "oRoRo",
         "oRhRo",
         ".oRo.",
         "..o.."],
    ], palette: palette(["R": 0xFF8FA8, "h": 0xFFD6DF]), nominal: 7)

    // MARK: 큰 그림 (터짐)

    /// 가운데에서 번쩍이고, 빛줄기가 뻗고, 점 고리로 흩어지는 터짐. 색만 바꿔 별·불꽃·사탕 터짐으로 쓴다.
    private static func burst(_ core: UInt32, _ ray: UInt32) -> Sprite {
        Sprite(frames: [
            ["...w...",
             "..wYw..",
             ".wYYYw.",
             "wYYwYYw",
             ".wYYYw.",
             "..wYw..",
             "...w..."],
            [".....Y.....",
             ".Y...Y...Y.",
             "..Y..O..Y..",
             "...YOOOY...",
             "....OwO....",
             "YYOOwwwOOYY",
             "....OwO....",
             "...YOOOY...",
             "..Y..O..Y..",
             ".Y...Y...Y.",
             ".....Y....."],
            ring(radius: 6, char: "Y", dotted: 2),
            ring(radius: 6, char: "O", dotted: 3),
        ], palette: palette(["Y": core, "O": ray]), nominal: 11)
    }

    /// 고리로 퍼지는 터짐 (마법, 눈, 사탕 펑). 고리가 커지며 점으로 흩어진다.
    private static func pop(_ main: UInt32, _ light: UInt32) -> Sprite {
        Sprite(frames: [
            ring(radius: 2, char: "M", dotted: 0),
            ring(radius: 4, char: "M", dotted: 0, inner: "L"),
            ring(radius: 5, char: "M", dotted: 1),
            ring(radius: 6, char: "L", dotted: 2),
        ], palette: palette(["M": main, "L": light]), nominal: 11)
    }

    /// 뭉게뭉게 커지는 연기 덩어리.
    private static let smoke = Sprite(frames: [
        blob(radius: 2), blob(radius: 3), blob(radius: 5), ring(radius: 6, char: "D", dotted: 2),
    ], palette: palette(["D": 0xF1F4F8, "d": 0xC9D3E0, "h": 0xFFFFFF], outline: 0x7F8BA3), nominal: 11)

    /// 반지름 `radius`의 고리 격자. `dotted`가 0보다 크면 그만큼 건너뛰어 점으로 남긴다. `inner`면 안을 옅게 채운다.
    private static func ring(radius: Int, char: Character, dotted: Int, inner: Character? = nil) -> [String] {
        let size = radius * 2 + 1
        return (0..<size).map { y in
            String((0..<size).map { x -> Character in
                let d = hypot(Double(x - radius), Double(y - radius))
                if abs(d - Double(radius)) < 0.55 {
                    guard dotted > 0 else { return char }
                    return (x + y) % (dotted + 1) == 0 ? char : "."
                }
                if let inner, d < Double(radius) - 0.5 { return (x + y) % 2 == 0 ? inner : "." }
                return "."
            })
        }
    }

    /// 외곽선과 하이라이트가 있는 둥근 덩어리.
    private static func blob(radius: Int) -> [String] {
        let size = radius * 2 + 1
        return (0..<size).map { y in
            String((0..<size).map { x -> Character in
                let d = hypot(Double(x - radius), Double(y - radius))
                if d > Double(radius) + 0.4 { return "." }
                if d > Double(radius) - 0.6 { return "o" }
                if x < radius && y < radius && d < Double(radius) * 0.5 { return "h" }
                return x + y > radius * 2 ? "d" : "D"
            })
        }
    }

    // MARK: 이름

    private static let sprites: [String: Sprite] = [
        "heart": heart, "star": star, "sparkle": sparkle, "note": note, "petal": petal, "leaf": leaf, "snow": snow,
        "bubble": bubble, "flame": flame, "coin": coin, "rainbow": rainbow, "firefly": firefly, "drop": drop,
        "dust": puff(0xD8C3A5, 0xB39B7E, 0xF2E6D3, outline: 0x6E5A48),
        "cloud": puff(0xFFFFFF, 0xDCE6F2, 0xFFFFFF, outline: 0x8FA3BF),
        "candyPink": candy(0xFF7FB3, 0xD9548E), "candyBlue": candy(0x7FC8FF, 0x4A93D9),
        "candyYellow": candy(0xFFE066, 0xD9B23A), "candyTeal": candy(0x6FE0C8, 0x3FB39C),
        "candyRed": candy(0xFF6B6B, 0xD94545),
        "burst": burst(0xFFE15A, 0xFFA24A), "fireBurst": burst(0xFFB23D, 0xFF5A2A),
        "popPink": pop(0xFF7FB3, 0xFFD1E3), "popBlue": pop(0x7FC8FF, 0xD6EEFF), "popGreen": pop(0x7EDB72, 0xD6F7CF),
        "popRed": pop(0xFF6B6B, 0xFFD0D0), "magic": pop(0xB48CFF, 0xE6DAFF), "snowPop": pop(0x9CD3FF, 0xFFFFFF),
        "smoke": smoke,
        "butterfly": butterfly, "glitter": glitter, "tinyHeart": tinyHeart,
    ]

    /// 예전 효과 그림 이름. 게임·무대·동작이 부르던 이름을 그대로 두고 새 그림으로 그린다.
    private static let aliases: [String: String] = [
        "pumpingHeart": "heart", "gemHeart": "heart", "rainbowStar": "star", "plasmaSparkle": "sparkle",
        "plasmaPuff": "sparkle", "pure": "sparkle", "plasmaBubble": "bubble", "firePlume": "flame", "water": "drop",
        "smokePoff": "dust", "puff": "cloud", "starburst": "burst", "pixelBoom": "burst", "fireBlast": "fireBurst",
        "ringBoom": "magic", "boom": "smoke", "candyPop_pink": "popPink", "candyPop_blue": "popBlue",
        "candyPop_green": "popGreen", "candyPop_red": "popRed",
    ]

    static func sprite(_ name: String) -> Sprite? { sprites[aliases[name] ?? name] }

    /// 예전 사탕 그림 이름(`lollipop_pink`, `jelly_yellow` …)을 색이 맞는 도트 사탕으로.
    static func candyName(_ name: String) -> String {
        for (word, sprite) in [("pink", "candyPink"), ("blue", "candyBlue"), ("yellow", "candyYellow"), ("teal", "candyTeal"),
                               ("red", "candyRed"), ("green", "candyTeal")] where name.contains(word) { return sprite }
        return "candyPink"
    }

    // MARK: 그리기

    private static var images: [String: CGImage] = [:]

    /// 한 장면을 픽셀 그림으로 만든다 (위 줄이 그림의 위). 그림마다 한 번만 만든다. 메인 스레드에서 쓴다.
    private static func image(_ name: String, sprite: Sprite, frame: Int) -> CGImage? {
        let key = "\(name)#\(frame)"
        if let cached = images[key] { return cached }
        let rows = sprite.frames[frame]
        let h = rows.count, w = rows.map(\.count).max() ?? 0
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for (y, row) in rows.enumerated() {
            for (x, char) in row.enumerated() {
                guard let color = sprite.palette[char]?.usingColorSpace(.sRGB) else { continue }
                let a = color.alphaComponent, i = (y * w + x) * 4
                pixels[i] = UInt8(color.redComponent * a * 255)
                pixels[i + 1] = UInt8(color.greenComponent * a * 255)
                pixels[i + 2] = UInt8(color.blueComponent * a * 255)
                pixels[i + 3] = UInt8(a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        images[key] = image
        return image
    }

    /// 지금 그릴 장면. 도는 그림은 `time`으로, 한 번 재생하는 그림은 `progress`(0~1)로 고른다.
    static func frame(_ name: String, progress: CGFloat, time: Double) -> (image: CGImage, rows: Int, nominal: Int)? {
        guard let sprite = sprite(name) else { return nil }
        let count = sprite.frames.count
        let index = sprite.fps.map { Int(time * $0) % count } ?? min(max(Int(progress * CGFloat(count)), 0), count - 1)
        guard let image = image(aliases[name] ?? name, sprite: sprite, frame: index) else { return nil }
        return (image, sprite.frames[index].count, sprite.nominal)
    }

    static func loops(_ name: String) -> Bool { sprite(name)?.fps != nil }

    /// 입자가 어떻게 움직이는지. 꽃잎·잎·눈·코인·사탕은 팔랑이며 떨어지고, 구름·먼지·방울·음표·반딧불·불꽃은 떠오르고,
    /// 하트·별·무지개는 제자리에서 둥실거린다.
    enum Drift { case fall, rise, bob }

    static func drift(_ name: String) -> Drift? {
        let key = aliases[name] ?? name
        guard sprites[key] != nil else { return nil }
        if ["petal", "leaf", "snow", "coin"].contains(key) || key.hasPrefix("candy") { return .fall }
        if ["heart", "star", "rainbow"].contains(key) { return .bob }
        return .rise
    }
}
