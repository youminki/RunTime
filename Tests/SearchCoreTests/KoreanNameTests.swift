import Testing
@testable import SearchCore

struct KoreanNameTests {
    @Test func knownCharactersUseDictionary() {
        #expect(KoreanName.make("Shin-chan", slug: "shinchan-5") == "짱구")
        #expect(KoreanName.make("哆啦 A 梦", slug: "doraemon-1") == "도라에몽")
        #expect(KoreanName.make("sonic-pixel", slug: "sonic-pixel") == "소닉")
    }

    @Test func hangulNamesStay() {
        #expect(KoreanName.make("짱구") == "짱구")
    }

    @Test func chineseUsesPinyinTable() {
        #expect(KoreanName.make("肉包") == "러우바오")
        #expect(KoreanName.make("噜噜") == "루루")
        #expect(KoreanName.make("Xiwei") == "시웨이")
    }

    @Test func koreanRomanizationReturnsToHangul() {
        #expect(KoreanName.make("Hyein") == "혜인")
    }

    @Test func englishWords() {
        #expect(KoreanName.make("Gauss") == "가우스")
        #expect(KoreanName.make("Ribbon Pig") == "리본 돼지")
        #expect(KoreanName.make("StarByte") == "스타 바이트")
        #expect(KoreanName.make("QQ DD v2") == "큐큐 디디 브이 2")
        #expect(KoreanName.make("Jill Stingray") == "질 스팅레이")
    }

    @Test func consonantClusters() {
        #expect(KoreanName.make("Block") == "블록")
        #expect(KoreanName.make("Hiyori") == "히요리")
        #expect(KoreanName.make("Sweet") == "스위트")
        #expect(KoreanName.make("Marble") == "마블")
    }

    @Test func hanWithSlugOrLatinPrefersOriginalName() {
        #expect(KoreanName.make("不知火舞", slug: "mai-shiranui") == "마이 시라누이")
        #expect(KoreanName.make("柳玉", slug: "spritesheet-47") == "류위")
        #expect(KoreanName.make("贝拉Kira", slug: "kira") == "키라")
        #expect(KoreanName.make("肉包", slug: "roubao") == "러우바오")
    }

    @Test func knowsWhichNamesAreOfficial() {
        #expect(KoreanName.hasOfficialName(" Patrick Star "))
        #expect(!KoreanName.hasOfficialName("Sky Striker Ace"))
    }

    @Test func officialNames() {
        #expect(KoreanName.make("Patrick Star") == "뚱이")
        #expect(KoreanName.make("卡比兽", slug: "kabi") == "잠만보")
        #expect(KoreanName.make("Hanni-Powerpuff") == "하니")
        #expect(KoreanName.make("Kudo Shinichi") == "남도일")
        #expect(KoreanName.make("富冈义勇 Q版 丰富动作", slug: "giyu-tomioka") == "토미오카 기유")
        #expect(KoreanName.make("Jonathan") == "조나단")
        #expect(KoreanName.make("Luffy Gear 5") == "루피 기어 5")
        // 낱말 하나만 맞을 때는 공백 없는 이름만 쓴다 (Hal Cat이 HAL 9000 캣이 되면 안 된다)
        #expect(KoreanName.make("Hal Cat") == "할 고양이")
        #expect(KoreanName.make("Rem Cat") == "렘 고양이")
        #expect(KoreanName.make("Thorn", official: false) != "쏜")
    }

    @Test func untranslatableKeepsOriginal() {
        #expect(KoreanName.make("!!!") == "!!!")
    }
}
