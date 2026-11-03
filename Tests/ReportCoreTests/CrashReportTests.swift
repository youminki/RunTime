import Foundation
import Testing
@testable import ReportCore

// macOS 27이 남긴 .ips에서 쓰는 칸만 남긴 꼴. 앱 0번, libswiftCore 1번, dyld 2번
private func ips(bug: String = "309", frames: String, exception: String? = nil, asi: String = "null") -> String {
    let header = #"{"app_name":"RunTime","timestamp":"2026-11-03 20:26:44.00 +0900","app_version":"1.4.12","build_version":"812","bug_type":"\#(bug)","os_version":"macOS 27.0.1 (26A434)"}"#
    let body = #"""
    {"pid": 4242, "procLaunch": "2026-11-03 20:20:00.5000 +0900", "cpuType": "ARM-64", "procPath": "/Applications/RunTime.app/Contents/MacOS/RunTime", "captureTime": "2026-11-03 20:26:43.9373 +0900",
     "exception": {"codes": "0x0000000000000001, 0x00000001023b4e14", "type": "EXC_BREAKPOINT", "signal": "SIGTRAP"},
     "termination": {"indicator": "Trace/BPT trap: 5"}, "asi": \#(asi), "faultingThread": 0,
     "threads": [{"triggered": true, "queue": "com.apple.main-thread", "frames": \#(frames)}],
     \#(exception.map { "\"lastExceptionBacktrace\": \($0)," } ?? "")
     "usedImages": [
       {"base": 4294967296, "uuid": "05d0acb2-fbc9-340f-bcc0-1ab7f446f09f", "path": "/Applications/RunTime.app/Contents/MacOS/RunTime", "name": "RunTime"},
       {"base": 7000000000, "path": "/usr/lib/swift/libswiftCore.dylib", "name": "libswiftCore.dylib"},
       {"base": 7100000000, "path": "/usr/lib/dyld", "name": "dyld"}]}
    """#
    return header + "\n" + body
}

private let swiftFrames = #"""
[{"imageOffset": 1445196, "symbol": "_assertionFailure(_:_:file:line:flags:)", "symbolLocation": 216, "imageIndex": 1},
 {"imageOffset": 3816, "symbol": "WorkLogStore.load()", "symbolLocation": 432, "imageIndex": 0},
 {"imageOffset": 9000, "imageIndex": 0},
 {"imageOffset": 204416, "symbol": "start", "symbolLocation": 6688, "imageIndex": 2}]
"""#

@Suite struct CrashReportTests {
    @Test func readsTheCrashedThread() throws {
        let report = try #require(CrashReport(ips: ips(frames: swiftFrames)))
        #expect(report.appName == "RunTime")
        #expect(report.appVersion == "1.4.12" && report.buildVersion == "812")
        #expect(report.pid == 4242)
        #expect(report.arch == "arm64")
        #expect(CrashReport.date(report.procLaunch)?.timeIntervalSince1970 == 1_793_704_800.5)
        #expect(report.exceptionType == "EXC_BREAKPOINT" && report.signal == "SIGTRAP")
        #expect(report.queue == "com.apple.main-thread")
        #expect(report.frames.map(\.inApp) == [false, true, true, false])
        #expect(report.frames[1].symbol == "WorkLogStore.load()")
        #expect(report.appBase == 4294967296)
        #expect(!report.thrown)
    }

    @Test func skipsOtherReportsAndBrokenText() {
        #expect(CrashReport(ips: ips(bug: "288", frames: swiftFrames)) == nil)   // 멈춤 보고서
        #expect(CrashReport(ips: "") == nil)
        #expect(CrashReport(ips: "{}") == nil)
        #expect(CrashReport(ips: "{\"bug_type\":\"309\"}\nnot json") == nil)
    }

    @Test func summaryNamesTheReasonAndAppFrame() throws {
        let report = try #require(CrashReport(ips: ips(frames: swiftFrames)))
        #expect(report.summary(fatal: []) == "EXC_BREAKPOINT (SIGTRAP) · WorkLogStore.load()")
        #expect(report.summary(fatal: ["RunTime/WorkLogStore.swift:88: Fatal error: 형식이 다름"])
                == "Fatal error: 형식이 다름 · WorkLogStore.load()")
        // 죽기 직전 줄이 까닭이고, 실행마다 바뀌는 주소는 지워 같은 충돌이 한 통으로 묶인다
        #expect(report.summary(fatal: ["Assertion failed: 경고", "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '-[A b]: unrecognized selector sent to instance 0x600003a2c000'"])
                == "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '-[A b]: unrecognized selector sent to instance 0x…' · WorkLogStore.load()")
    }

    @Test func readsIntelArchitecture() throws {
        let text = ips(frames: swiftFrames).replacingOccurrences(of: "\"ARM-64\"", with: "\"X86-64\"")
        let report = try #require(CrashReport(ips: text))
        #expect(report.arch == "x86_64")
        #expect(report.detail(fatal: []).contains("-arch x86_64"))
    }

    @Test func summaryUsesOffsetWhenTheAppFrameHasNoSymbol() throws {
        let frames = #"[{"imageOffset": 9000, "imageIndex": 0}]"#
        let report = try #require(CrashReport(ips: ips(frames: frames)))
        #expect(report.summary(fatal: []) == "EXC_BREAKPOINT (SIGTRAP) · RunTime +0x2328")
    }

    @Test func prefersTheThrowSiteOfAnObjCException() throws {
        let thrown = #"[{"imageOffset": 99852, "symbol": "objc_exception_throw", "imageIndex": 1}, {"imageOffset": 3696, "symbol": "HostsStore.save()", "imageIndex": 0}]"#
        let report = try #require(CrashReport(ips: ips(frames: swiftFrames, exception: thrown, asi: #"{"libsystem_c.dylib": ["abort() called"]}"#)))
        #expect(report.thrown)
        #expect(report.notes == ["abort() called"])
        #expect(report.summary(fatal: []).hasSuffix("· HostsStore.save()"))
        #expect(report.detail(fatal: []).contains("예외를 던진 자리"))
    }

    @Test func detailListsAppFramesAndAtos() throws {
        let report = try #require(CrashReport(ips: ips(frames: swiftFrames)))
        let detail = report.detail(fatal: ["RunTime/WorkLogStore.swift:88: Fatal error: 형식이 다름"])
        #expect(detail.contains("버전: 1.4.12 (빌드 812)"))
        #expect(detail.contains("출력: RunTime/WorkLogStore.swift:88: Fatal error: 형식이 다름"))
        #expect(detail.contains("1 ▶ RunTime WorkLogStore.load() + 432"))
        #expect(detail.contains("2 ▶ RunTime +0x2328"))
        // 0x100000000 + 3816, + 9000
        #expect(detail.contains("-l 0x100000000 0x100000ee8 0x100002328"))
        #expect(detail.contains("05d0acb2-fbc9-340f-bcc0-1ab7f446f09f"))
    }

    @Test func detailFitsTheLimit() throws {
        let many = "[" + (0..<200).map { #"{"imageOffset": \#($0), "symbol": "Deep.call\#($0)()", "imageIndex": 0}"# }.joined(separator: ",") + "]"
        let report = try #require(CrashReport(ips: ips(frames: many)))
        let detail = report.detail(fatal: [], limit: 2000)
        #expect(detail.count <= 2000)
        #expect(detail.contains("0 ▶ RunTime Deep.call0()"))
        #expect(detail.contains("atos"))
    }

    @Test func keepsFramesNearTheApp() {
        let frame = { (inApp: Bool) in CrashReport.Frame(image: inApp ? "RunTime" : "lib", symbol: nil, location: nil, offset: 0, inApp: inApp) }
        let frames = [false, false, false, false, false, true, false, false].map(frame)
        #expect(CrashReport.relevant(frames).map(\.0) == [0, 1, 2, 4, 5])
    }

    @Test func picksFatalLinesFromOutput() {
        let output = """
        RunTime pid=4242 commit=abc
        일반 출력
        RunTime/A.swift:3: Fatal error: 하나
        *** Terminating app due to uncaught exception 'NSRangeException', reason: 'index 3'
        \tFatal error: 둘
        """
        #expect(CrashReport.fatalLines(output) == [
            "RunTime/A.swift:3: Fatal error: 하나",
            "*** Terminating app due to uncaught exception 'NSRangeException', reason: 'index 3'",
            "Fatal error: 둘",
        ])
        #expect(CrashReport.fatalLines("") == [])
        #expect(CrashReport.withoutLocation("RunTime/A.swift:3: Fatal error: 하나") == "Fatal error: 하나")
        #expect(CrashReport.withoutLocation("Fatal error: 둘") == "Fatal error: 둘")
    }

    @Test func eventsStopAtTheCrash() {
        let log = """
        2026-11-03 20:20:00 [업데이트] 확인
        2026-11-03 20:26:43 [디자인] 받기 시작
        2026-11-03 20:26:43 [문제 보고] 만든 사람에게 보냄
        시각 없는 줄
        2026-11-03 20:30:00 [업데이트] 다시 켬
        """
        #expect(CrashReport.events(log, before: "2026-11-03 20:26:43.9373 +0900")
                == ["2026-11-03 20:20:00 [업데이트] 확인", "2026-11-03 20:26:43 [디자인] 받기 시작"])
        #expect(CrashReport.events(log, before: "") == [])
    }
}

@Suite struct HangReportTests {
    private let frames = [
        CrashReport.Frame(image: "libsystem_kernel.dylib", symbol: "mach_msg2_trap", location: 8, offset: 100, inApp: false),
        CrashReport.Frame(image: "RunTime", symbol: "DesignSync.load()", location: 40, offset: 0x2000, inApp: true),
    ]

    @Test func summaryIsTheStuckPlace() {
        let report = HangReport(seconds: 6.2, ended: true, frames: frames, base: 0x1_0000_0000, uuid: "u", arch: "arm64",
                                app: "1.4.13", commit: "c", at: "2026-11-03 21:00:00")
        #expect(report.summary == "DesignSync.load()")
        #expect(HangReport(seconds: 6, ended: true, frames: [], base: nil, uuid: "", arch: "arm64", app: "", commit: "", at: "").summary
                == "메인 스레드가 응답하지 않음")
        let detail = report.detail()
        #expect(detail.contains("메인 스레드가 6.2초 넘게 응답하지 않다가 돌아옴"))
        #expect(detail.contains("1 ▶ RunTime DesignSync.load() + 40"))
        #expect(detail.contains("-l 0x100000000 0x100002000"))
    }

    @Test func unfinishedHangSaysTheAppQuit() {
        var report = HangReport(seconds: 5, ended: false, frames: frames, base: nil, uuid: "", arch: "arm64", app: "", commit: "", at: "")
        #expect(report.detail().contains("5.0초 넘게 응답하지 않은 채 앱이 꺼짐"))
        report.ended = true
        #expect(!report.detail().contains("꺼짐"))
    }

    @Test func survivesSaving() throws {
        let report = HangReport(seconds: 7, ended: false, frames: frames, base: 42, uuid: "u", arch: "arm64", app: "a", commit: "c", at: "t")
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(HangReport.self, from: data) == report)
    }

    @Test func watcherSamplesOnceAndReportsWhenMainAnswers() {
        #expect(HangReport.step(waited: 1, answered: nil, sampled: false, threshold: 5) == .wait)
        #expect(HangReport.step(waited: 5, answered: nil, sampled: false, threshold: 5) == .sample)
        #expect(HangReport.step(waited: 9, answered: nil, sampled: true, threshold: 5) == .wait)
        #expect(HangReport.step(waited: 9, answered: 8.5, sampled: true, threshold: 5) == .report(seconds: 8.5))
        #expect(HangReport.step(waited: 1, answered: 0.01, sampled: false, threshold: 5) == .ping)
        // 다 떠 두기 전에 답이 오면 알리지 않는다
        #expect(HangReport.step(waited: 6, answered: 5.5, sampled: false, threshold: 5) == .ping)
    }
}

@Suite struct CrashIncidentTests {
    @Test func readsIncidentAndDay() throws {
        let text = #"{"app_name":"RunTime","bug_type":"309","incident_id":"C9C240BC-F6B4-4BDD-B187-922DC94AC981"}"# + "\n" + #"{"procPath":"/Applications/RunTime.app/Contents/MacOS/RunTime"}"#
        let report = try #require(CrashReport(ips: text))
        #expect(report.incident == "C9C240BC-F6B4-4BDD-B187-922DC94AC981")
        #expect(CrashReport.day(Date(timeIntervalSince1970: 1_793_704_800)).count == 10)
    }
}
