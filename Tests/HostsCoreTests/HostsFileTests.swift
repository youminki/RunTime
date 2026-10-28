import Testing
@testable import HostsCore

// 예시 주소(RFC 5737)와 example 도메인만 쓴다
private let sample = """
##
# Host Database
##
127.0.0.1\tlocalhost
255.255.255.255\tbroadcasthost
::1             localhost
203.0.113.5 solo.example.com

## Local - Start ##
127.0.0.1 app.local #Local Site
- End ##
198.51.100.7 a.example.org b.example.org
#198.51.100.8 off.example.org
## other
198.51.100.7  a.example.org
198.51.100.9 a.example.org
191.168.10.40 typo.example.net

"""

@Suite struct HostsFileTests {
    @Test func readsAndWritesBackUnchanged() {
        #expect(HostsFile(sample).text == sample)
        #expect(HostsFile("a\nb").text == "a\nb")
        #expect(HostsFile("").text == "")
    }

    @Test func keepsSystemHeaderOutOfSections() {
        let file = HostsFile(sample)
        #expect(file.headerEnd == 6)
        let sections = file.sections
        #expect(sections.map(\.title) == [nil, "Local", nil, "other"])
        #expect(sections[2].items.map(\.name) == ["a.example.org", "b.example.org", "off.example.org"])
        #expect(sections[2].items.last?.enabled == false)
        #expect(sections[1].items.first?.note == "Local Site")
    }

    @Test func doesNotReadProseCommentsAsEntries() {
        #expect(HostsFile.parse("# 10.0.0.1 is gateway") == .comment("10.0.0.1 is gateway"))
        #expect(HostsFile.parse("192.168.1.300 a.example.com") == .invalid)
        #expect(HostsFile.parse("fe80::1%lo0 localhost") != .invalid)
        #expect(HostsFile.parse("fe80::1 v6.example.com") != .invalid)
    }

    @Test func togglesOneNameBySplittingTheLine() {
        var file = HostsFile(sample)
        let b = file.items.first { $0.name == "b.example.org" }!
        file.setEnabled(b, false)
        #expect(file.lines[b.line].raw == "198.51.100.7\ta.example.org")
        #expect(file.lines[b.line + 1].raw == "#198.51.100.7\tb.example.org")

        let solo = file.items.first { $0.name == "solo.example.com" }!
        file.setEnabled(solo, false)
        #expect(file.lines[solo.line].raw == "#203.0.113.5 solo.example.com")
        file.setEnabled(file.items.first { $0.name == "solo.example.com" }!, true)
        #expect(file.lines[solo.line].raw == "203.0.113.5 solo.example.com")
    }

    @Test func togglesWholeGroupWithoutSplittingLines() {
        var file = HostsFile(sample)
        let count = file.lines.count
        file.setEnabled(file.sections[2].items, false)
        #expect(file.sections[2].items.allSatisfy { !$0.enabled })
        #expect(file.sections[2].items.count == 3)
        #expect(file.lines.count == count)
        #expect(file.lines[11].raw == "#198.51.100.7 a.example.org b.example.org")
    }

    @Test func staleItemsFindTheirLineOrDoNothing() {
        var file = HostsFile(sample)
        let solo = file.items.first { $0.name == "solo.example.com" }!
        file.lines.insert(HostsFile.Line("203.0.113.99 pushed.example.com"), at: file.headerEnd)
        file.remove(solo)
        #expect(!file.items.contains { $0.name == "solo.example.com" })
        #expect(file.items.contains { $0.name == "pushed.example.com" })
        let before = file
        file.remove(solo)
        file.update(HostsFile.Item(line: 999, slot: 5, ip: "203.0.113.5", name: "gone.example.com", enabled: true, note: nil),
                    ip: "203.0.113.6", name: "x.example.com", note: nil)
        #expect(file == before)
    }

    @Test func notesCannotAddLines() {
        var file = HostsFile("127.0.0.1 localhost\n203.0.113.1 a.example.com\n")
        file.update(file.items[0], ip: "203.0.113.1", name: "a.example.com", note: "one\n203.0.113.66 evil.example.com")
        #expect(file.text == "127.0.0.1 localhost\n203.0.113.1\ta.example.com # one 203.0.113.66 evil.example.com\n")
    }

    @Test func addsToExistingOrNewGroup() {
        var file = HostsFile(sample)
        let pasted = HostsFile.records(fromPasted: "203.0.113.20 new.example.com x.example.com\nnot a line\n# memo")
        #expect(pasted.records.count == 1)
        #expect(pasted.skipped == ["not a line"])
        file.add(pasted.records, to: "Local")
        #expect(file.sections[1].items.map(\.name) == ["app.local", "new.example.com", "x.example.com"])

        file.add([.init(ip: "203.0.113.30", names: ["z.example.com"])], to: "새 묶음")
        #expect(file.sections.last?.title == "새 묶음")
        #expect(file.text.hasSuffix("\n\n## 새 묶음\n203.0.113.30\tz.example.com\n"))
    }

    @Test func removesAndUpdatesOneName() {
        var file = HostsFile(sample)
        file.remove(file.items.first { $0.name == "a.example.org" }!)
        #expect(file.items.first { $0.ip == "198.51.100.7" }?.name == "b.example.org")
        file.update(file.items.first { $0.name == "solo.example.com" }!, ip: "203.0.113.6", name: "solo.example.com", note: "메모")
        #expect(file.text.contains("203.0.113.6\tsolo.example.com # 메모\n"))
    }
}

@Suite struct HostsDoctorTests {
    @Test func findsProblems() {
        let issues = HostsDoctor.issues(in: HostsFile(sample))
        let kinds = issues.map(\.kind)
        #expect(kinds.contains(.brokenMarker))
        #expect(issues.contains { $0.kind == .duplicate && $0.line == 14 })
        #expect(issues.contains { $0.kind == .conflict && $0.line == 15 })
        #expect(issues.contains { $0.kind == .suspiciousIP && $0.message.contains("192.168.10.40") })
        #expect(issues.contains { $0.kind == .mdns })
        #expect(!issues.contains { $0.line < 6 })
    }

    @Test func cleanFileHasNoIssues() {
        #expect(HostsDoctor.issues(in: HostsFile("127.0.0.1 localhost\n203.0.113.1 a.example.com\n")).isEmpty)
    }
}

@Suite struct HostsFormatterTests {
    @Test func organizesWithoutChangingWhereNamesResolve() {
        let before = HostsFile(sample)
        let after = HostsFormatter.organized(before)
        #expect(after.text == """
        ##
        # Host Database
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost

        ## example.com
        203.0.113.5 solo.example.com

        ## Local
        127.0.0.1 app.local # Local Site

        ## example.org
        198.51.100.7  a.example.org
        198.51.100.7  b.example.org
        #198.51.100.8 off.example.org

        ## other
        191.168.10.40 typo.example.net
        198.51.100.9  a.example.org

        """)
        #expect(HostsFormatter.enabledAddresses(before) == HostsFormatter.enabledAddresses(after))
        let left = HostsDoctor.issues(in: after).filter(\.fixable)
        #expect(left.isEmpty)
        // 두 번 정리해도 같다
        #expect(HostsFormatter.organized(after).text == after.text)
    }

    @Test func keepsUnreadableLinesAsComments() {
        let after = HostsFormatter.organized(HostsFile("127.0.0.1 localhost\n## A\n203.0.113.1 a.example.com\noops\n"))
        #expect(after.text.hasSuffix("## A\n203.0.113.1 a.example.com\noops\n"))
    }

    @Test func keepsGroupNotesAndDotlessDisabledEntries() {
        let text = "127.0.0.1 localhost\n## Dev\n# VPN 필요\n203.0.113.1 a.example.com\n#203.0.113.5 nas\n"
        let file = HostsFile(text)
        #expect(file.sections.map(\.title) == ["Dev"])
        #expect(file.items.map(\.name) == ["a.example.com", "nas"])
        #expect(HostsFormatter.organized(file).text == "127.0.0.1 localhost\n\n## Dev\n# VPN 필요\n203.0.113.1  a.example.com\n#203.0.113.5 nas\n")
    }

    @Test func keepsCRLFAndTrailingDotEntriesWorking() {
        let file = HostsFile("127.0.0.1 localhost\r\n203.0.113.1 a.example.com\r\n203.0.113.2 b.example.com.\r\n")
        #expect(file.items.map(\.name) == ["a.example.com", "b.example.com."])
        #expect(HostsDoctor.issues(in: file).isEmpty)
        #expect(HostsFormatter.organized(file).text == "127.0.0.1 localhost\n\n## example.com\n203.0.113.1 a.example.com\n203.0.113.2 b.example.com.\n")
    }

    @Test func titlesEndingInEndAreNotMarkers() {
        #expect(!HostsFile.isEndMarker("Back-end"))
        #expect(!HostsFile.isEndMarker("Front end"))
        #expect(!HostsFile.isEndMarker("Weekend"))
        #expect(HostsFile.isEndMarker("Local - End ##"))
        #expect(HostsFile.isEndMarker("- End ##"))
        #expect(HostsFile.isEndMarker("END"))
        var file = HostsFile("127.0.0.1 localhost\n## Back-end\n203.0.113.1 a.example.com\n")
        #expect(file.sections.map(\.title) == ["Back-end"])
        file.add([.init(ip: "203.0.113.2", names: ["b.example.com"])], to: "Back-end")
        #expect(file.sections.count == 1)
    }

    @Test func diffStaysSmallForLargeFiles() {
        let big = (0..<50_000).map { "10.0.\($0 / 250).\($0 % 250) h\($0).example.com" }
        var edited = big
        edited[25_000] = "#" + edited[25_000]
        let changes = LineDiff.changes(from: big.joined(separator: "\n"), to: edited.joined(separator: "\n"))
        #expect(changes.count == 50_001)
        #expect(changes.filter { $0.kind != .same }.map(\.text) == [big[25_000], edited[25_000]])
        // 통째로 바뀐 판은 표를 만들지 않고 뺀 줄·더한 줄로 보인다
        let other = (0..<3000).map { "x\($0)" }.joined(separator: "\n")
        let rewritten = LineDiff.changes(from: big.prefix(3000).joined(separator: "\n"), to: other)
        #expect(rewritten.filter { $0.kind == .removed }.count == 3000)
    }

    @Test func diffMarksChangedLines() {
        let changes = LineDiff.changes(from: "a\nb\nc", to: "a\nx\nc")
        #expect(changes.map(\.kind) == [.same, .removed, .added, .same])
    }
}

@Suite struct HostsToolsTests {
    @Test func readsExpiryAndFindsExpired() {
        let file = HostsFile("127.0.0.1 localhost\n203.0.113.1 a.example.com # 2026-10-01 추가 · ~2026-10-27\n#203.0.113.2 b.example.com # ~2026-10-01\n203.0.113.3 c.example.com # ~2026-10-28\n")
        #expect(file.items.map(\.expiry) == ["2026-10-27", "2026-10-01", "2026-10-28"])
        #expect(file.expired(on: "2026-10-28").map(\.name) == ["a.example.com"])
    }

    @Test func switchesGroupAddressKeepingLayout() {
        var file = HostsFile("127.0.0.1 localhost\n## Dev\n203.0.113.1    a.example.com b.example.com\n203.0.113.1    c.example.com\n203.0.113.9    other.example.com\n## Prod\n203.0.113.1 z.example.com\n")
        let dev = file.sections[0].items
        file.replaceIP(in: dev, from: "203.0.113.1", to: "198.51.100.1")
        #expect(file.text == "127.0.0.1 localhost\n## Dev\n198.51.100.1    a.example.com b.example.com\n198.51.100.1    c.example.com\n203.0.113.9    other.example.com\n## Prod\n203.0.113.1 z.example.com\n")
        // 한 줄의 이름 일부만 고르면 그 이름만 떼어 바꾼다
        file.replaceIP(in: [file.sections[0].items[1]], from: "198.51.100.1", to: "203.0.113.50")
        #expect(file.sections[0].items.map(\.ip) == ["198.51.100.1", "203.0.113.50", "198.51.100.1", "203.0.113.9"])
    }

    @Test func swapsTwoAddressesWithoutMixing() {
        var file = HostsFile("## Dev\n203.0.113.1 a.example.com\n203.0.113.2 b.example.com c.example.com\n")
        let before = file.items
        file.replaceIP(in: before.filter { $0.ip == "203.0.113.1" }, from: "203.0.113.1", to: "203.0.113.2")
        file.replaceIP(in: before.filter { $0.ip == "203.0.113.2" }, from: "203.0.113.2", to: "203.0.113.1")
        #expect(file.items.map { "\($0.name)=\($0.ip)" } == ["a.example.com=203.0.113.2", "b.example.com=203.0.113.1", "c.example.com=203.0.113.1"])
    }

    @Test func ignoresImpossibleOrNonASCIIDates() {
        #expect(HostsFile.isDay("2028-02-29"))
        #expect(!HostsFile.isDay("2026-02-29"))
        #expect(!HostsFile.isDay("2026-13-01"))
        let file = HostsFile("203.0.113.1 a.example.com # ~2026-13-45\n203.0.113.2 b.example.com # ~٢٠٢٦-١٠-٠١\n")
        #expect(file.items.map(\.expiry) == [nil, nil])
    }

    @Test func replacesExistingExpiryInNote() {
        #expect(HostsFile.note("2026-10-28 추가 · ~2026-11-01", until: "2026-12-01") == "2026-10-28 추가 · ~2026-12-01")
        #expect(HostsFile.note(nil, until: "2026-12-01") == "~2026-12-01")
        #expect(HostsFile.note("~2026-11-01", until: nil) == nil)
    }

    @Test func findsSameSectionAfterLinesShift() {
        let old = HostsFile("## Dev\n203.0.113.1 a.example.com\n## Prod\n203.0.113.1 a.example.com\n")
        var moved = old
        moved.lines.insert(HostsFile.Line("203.0.113.9 new.example.com"), at: 0)
        let dev = moved.section(matching: old.sections[0])
        #expect(dev?.title == "Dev")
        #expect(dev?.items.first?.line == 2)
        var renamed = old
        renamed.remove(renamed.items[0])
        #expect(renamed.section(matching: old.sections[0]) == nil)
        #expect(renamed.sections.map(\.title) == ["Prod"])
    }

    @Test func readsNameFirstPastedLines() {
        let pasted = HostsFile.records(fromPasted: "api.example.com 203.0.113.4 # 받은 것\nexample 문서\n")
        #expect(pasted.records == [.init(ip: "203.0.113.4", names: ["api.example.com"], note: "받은 것")])
        #expect(pasted.skipped == ["example 문서"])
    }

    @Test func plansAdditionAgainstExistingNames() {
        let file = HostsFile("## Dev\n203.0.113.1 on.example.com\n#203.0.113.2 off.example.com\n203.0.113.3 moved.example.com\n")
        let plan = file.additionPlan([
            .init(ip: "203.0.113.1", names: ["ON.example.com", "fresh.example.com"]),
            .init(ip: "203.0.113.2", names: ["off.example.com"]),
            .init(ip: "203.0.113.9", names: ["moved.example.com", "fresh.example.com"]),
            .init(ip: "203.0.113.1", names: ["fresh.example.com"]),
        ])
        #expect(plan.entries.map(\.status) == [.exists, .new, .reenable, .conflict("203.0.113.3"), .new, .exists])
        #expect(plan.records.map(\.names) == [["fresh.example.com"], ["moved.example.com", "fresh.example.com"]])
        #expect(plan.reenable.map(\.name) == ["off.example.com"])
        #expect(plan.conflicting.map(\.ip) == ["203.0.113.3"])
        #expect(plan.count == 4)
        #expect(file.conflicts(name: "on.example.com", ip: "203.0.113.7").map(\.line) == [1])
        #expect(file.conflicts(name: "on.example.com", ip: "203.0.113.1").isEmpty)
    }

    @Test func exportsEnabledItemsAligned() {
        let file = HostsFile("## Dev\n203.0.113.1 a.example.com\n#203.0.113.2 off.example.com\n198.51.100.10 b.example.com\n")
        #expect(HostsFile.exportText(title: "Dev", items: file.items) == "## Dev\n203.0.113.1   a.example.com\n198.51.100.10 b.example.com\n")
    }
}
