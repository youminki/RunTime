import Testing
@testable import WorkLogCore

@Suite struct KoreanHolidaysTests {
    @Test func namesFixedAndLunarHolidays() {
        #expect(KoreanHolidays.name(on: "2026-03-01") == "삼일절")
        #expect(KoreanHolidays.name(on: "2026-02-17") == "설날")
        #expect(KoreanHolidays.name(on: "2026-10-05") == "대체 공휴일")
        #expect(KoreanHolidays.name(on: "2030-12-25") == "성탄절")
        #expect(KoreanHolidays.name(on: "2026-10-21") == nil)
    }

    @Test func joinsHolidaysOnTheSameDay() {
        #expect(KoreanHolidays.name(on: "2025-05-05") == "어린이날·부처님오신날")
    }

    @Test func tableHasOnlyValidDays() {
        for key in KoreanHolidays.dated.keys { #expect(WorkDay.date(key) != nil, "\(key)") }
    }
}
