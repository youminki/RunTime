import Darwin
import Foundation
import MachO
import ReportCore

/// 메인 스레드가 5초 넘게 응답하지 않으면 그때의 호출 순서를 떠 만든 사람에게 알린다.
/// 앱이 멈추기만 하면 충돌 보고서가 남지 않아서, 따로 지켜보는 스레드가 1초마다 메인 스레드에 묻는다.
/// 멈춘 채 강제로 꺼지면 떠 둔 것을 다음에 켤 때 보낸다.
enum HangWatch {
    /// 아직 서버가 받지 않은 멈춤들(id → 보고). 하나만 두면 보내는 사이 새로 멈춘 것을 덮거나 지운다.
    static let pendingKey = "hangReportsPending"
    static let threshold: Double = 5
    /// 서버가 받을 때까지 쌓아 둘 수. 넘치면 오래된 것부터 버린다.
    private static let pendingLimit = 5
    private static var mainThread: thread_act_t = 0
    private static let lock = NSLock()
    /// 마지막 물음에 메인 스레드가 답한 시각(uptime 나노초). `lock`으로 지킨다.
    private static var answeredAt: UInt64?
    /// 이번 실행에서 뜬 멈춤. 정상 종료 때 끝난 것으로 고친다. `lock`으로 지킨다.
    private static var thisRun: Set<String> = []
    private static var started = false
    /// 앱을 켠 동안 서버가 받은 자리. 같은 곳에서 되풀이해 멈추면 한 번만 보낸다.
    private static var sentPlaces: Set<String> = []

    /// 메인 스레드에서 부른다.
    static func start() {
        guard Bundle.main.infoDictionary?["RunTimeCommitSHA"] != nil, !started else { return }
        started = true
        // mach_thread_self()와 달리 포트 참조를 늘리지 않는다
        mainThread = pthread_mach_thread_np(pthread_self())
        sendPending()
        let thread = Thread { watch() }
        thread.name = "dev.runtime.hang-watch"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// 앱이 정상으로 꺼질 때 부른다. 꺼지는 길에 들어섰으면 메인 스레드는 돌아온 것이라,
    /// 업데이트 설치처럼 오래 걸린 일 뒤 바로 꺼져도 "멈춘 채 꺼짐"으로 남지 않게 한다.
    static func appWillTerminate() {
        lock.lock(); let mine = thisRun; lock.unlock()
        update { pending in for id in mine { pending[id]?.ended = true } }
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func ask() -> UInt64 {
        lock.lock(); answeredAt = nil; lock.unlock()
        let askedAt = now()
        DispatchQueue.main.async {
            lock.lock(); answeredAt = now(); lock.unlock()
        }
        return askedAt
    }

    private static func watch() {
        var askedAt = ask()
        var sampled = false
        var report: HangReport?
        var woke = now()
        while true {
            Thread.sleep(forTimeInterval: 1)
            // 디버거·App Nap으로 이 스레드도 함께 섰다 풀렸으면 그동안을 멈춤으로 세지 않는다
            let last = woke
            woke = now()
            if woke - last > 3_000_000_000 { askedAt = woke; continue }
            lock.lock(); let answer = answeredAt; lock.unlock()
            let seconds = { (end: UInt64) in Double(end > askedAt ? end - askedAt : 0) / 1e9 }
            switch HangReport.step(waited: seconds(woke), answered: answer.map(seconds), sampled: sampled, threshold: threshold) {
            case .wait:
                // 멈춘 채 꺼지면 마지막으로 적은 시간이 남는다
                if var waiting = report, Int(seconds(woke)) % 10 == 0 {
                    waiting.seconds = seconds(woke)
                    report = waiting
                    save(waiting)
                }
            case .sample:
                sampled = true
                guard ProblemReporter.isOn else { break }
                report = sample(seconds: seconds(woke))
                if let report {
                    lock.lock(); thisRun.insert(report.id); lock.unlock()
                    save(report)
                }
            case .report(let length):
                if var ended = report {
                    ended.seconds = length
                    ended.ended = true
                    save(ended)
                    DispatchQueue.main.async { send(ended) }
                }
                (sampled, report) = (false, nil)
                askedAt = ask()
            case .ping:
                askedAt = ask()
            }
        }
    }

    /// 감시 스레드와 메인 스레드가 함께 고치므로 읽고 쓰는 동안 잠근다.
    private static let storeLock = NSLock()

    private static func loadPending() -> [String: HangReport] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [:] }
        return (try? JSONDecoder().decode([String: HangReport].self, from: data)) ?? [:]
    }

    private static func storePending(_ pending: [String: HangReport]) {
        let kept = pending.values.sorted { $0.at > $1.at }.prefix(pendingLimit)
        let trimmed = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
        if let data = try? JSONEncoder().encode(trimmed) { UserDefaults.standard.set(data, forKey: pendingKey) }
    }

    private static func update(_ change: (inout [String: HangReport]) -> Void) {
        storeLock.lock(); defer { storeLock.unlock() }
        var pending = loadPending()
        change(&pending)
        storePending(pending)
    }

    private static func save(_ report: HangReport) { update { $0[report.id] = report } }
    private static func remove(_ id: String) { update { $0[id] = nil } }

    /// 지난 실행이 멈춘 채 꺼졌거나, 멈췄다 돌아왔는데 보내지 못한 것. 서버가 1분에 두 건까지 받아 가장 최근 하나만 보낸다.
    private static func sendPending() {
        storeLock.lock(); let pending = loadPending(); storeLock.unlock()
        if let newest = pending.values.max(by: { $0.at < $1.at }) { send(newest) }
    }

    /// 서버가 받았을 때만 그 보고를 지워, 망이 없을 때 멈춘 것은 다음에 켤 때 다시 보낸다.
    private static func send(_ report: HangReport) {
        guard ProblemReporter.isOn else { remove(report.id); return }
        guard !CrashReports.rejectedToday(.hang) else { return }
        // 이번 실행에서 서버가 이미 받은 자리면 같은 메일이라 보내지 않는다
        guard !sentPlaces.contains(report.summary) else { remove(report.id); return }
        let events = CrashReport.events((try? String(contentsOf: Diagnostics.logURL, encoding: .utf8)) ?? "", before: report.at)
        Diagnostics.record("문제 보고", "앱이 멈춤: \(report.summary) (\(String(format: "%.1f", report.seconds))초)")
        ProblemReporter.send(.hang, report.summary, detail: report.detail(), app: report.app, commit: report.commit,
                             log: (["[멈추기 전 기록]"] + events).joined(separator: "\n")) { status in
            if status == 200 {
                sentPlaces.insert(report.summary)
                remove(report.id)
            }
            if status == 400 { CrashReports.markRejected(.hang) }
        }
    }

    // MARK: - 호출 순서 뜨기

    private static let maxFrames = 64

    /// 메인 스레드를 잠깐 세워 호출 순서를 뜬다. 세운 동안 메모리를 잡으면 메인 스레드가 쥔 malloc 잠금에 걸려
    /// 앱 전체가 굳으므로, 버퍼는 세우기 전에 잡고 세운 동안에는 레지스터와 스택만 읽는다.
    /// 세운 동안에는 전역 값도 읽지 않게(접근 검사가 메모리를 잡을 수 있다) 스레드 포트를 미리 꺼내 둔다.
    static func sample(seconds: Double) -> HangReport? {
        var addresses = [UInt](repeating: 0, count: maxFrames)
        let thread = mainThread
        let count = addresses.withUnsafeMutableBufferPointer { buffer -> Int in
            guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
            let count = walk(thread, into: buffer)
            thread_resume(thread)
            return count
        }
        guard count > 0 else { return nil }
        let image = AppImage.shared
        var frames = addresses.prefix(count).enumerated().map { image.frame($0.element, returnAddress: $0.offset > 0) }
        // lr이 이미 돌아온 자리(같은 함수 안)를 가리키면 같은 함수가 두 줄로 나와 하나를 뺀다
        if frames.count > 1, frames[0].inApp == frames[1].inApp, frames[0].image == frames[1].image,
           frames[0].symbol != nil, frames[0].symbol == frames[1].symbol {
            frames.remove(at: 1)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        return HangReport(seconds: seconds, ended: false, frames: frames, base: Int(bitPattern: image.base), uuid: image.uuid,
                          arch: AppImage.arch, app: info["CFBundleShortVersionString"] as? String ?? "",
                          commit: info["RunTimeCommitSHA"] as? String ?? "", at: AppImage.stamp())
    }

    /// 포인터 인증 비트를 뗀 주소. 사용자 주소는 47비트 안에 있다.
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    /// 지역 함수로 두면 붙잡은 값이 힙에 잡힐 수 있어 따로 둔다.
    private static func add(_ address: UInt, to buffer: UnsafeMutableBufferPointer<UInt>, count: inout Int) {
        let address = strip(address)
        guard address != 0, count < buffer.count, count == 0 || buffer[count - 1] != address else { return }
        buffer[count] = address
        count += 1
    }

    /// 프레임 포인터를 따라 돌아갈 주소를 모은다. 프레임 기록은 [이전 프레임 포인터, 돌아갈 주소] 꼴이다.
    private static func walk(_ thread: thread_act_t, into buffer: UnsafeMutableBufferPointer<UInt>) -> Int {
        var pc: UInt = 0, fp: UInt = 0, lr: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        (pc, fp, lr) = (UInt(state.__pc), UInt(state.__fp), UInt(state.__lr))
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &stateCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        (pc, fp) = (UInt(state.__rip), UInt(state.__rbp))
        // x86_64에는 lr이 없어, 프레임을 만들지 않는 함수에서 멈췄으면 부른 곳이 스택 맨 위에 있다
        var top: UInt = 0
        var topRead: vm_size_t = 0
        let topResult = withUnsafeMutablePointer(to: &top) { pointer in
            vm_read_overwrite(mach_task_self_, vm_address_t(state.__rsp), vm_size_t(MemoryLayout<UInt>.size),
                              vm_address_t(UInt(bitPattern: pointer)), &topRead)
        }
        if topResult == KERN_SUCCESS, topRead == MemoryLayout<UInt>.size { lr = top }
        #endif
        var count = 0
        add(pc, to: buffer, count: &count)
        // 프레임을 만들지 않는 함수(시스템 호출 감싸개 등)에서 멈췄으면 부른 곳은 lr(x86_64는 스택 맨 위)에만 있다
        add(lr, to: buffer, count: &count)
        var frame: (UInt, UInt) = (0, 0)
        while fp != 0, fp % 8 == 0, count < buffer.count {
            var read: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &frame) { pointer in
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                  vm_address_t(UInt(bitPattern: pointer)), &read)
            }
            guard ok == KERN_SUCCESS, read == MemoryLayout<(UInt, UInt)>.size else { break }
            add(frame.1, to: buffer, count: &count)
            // 스택은 아래로 자라서 부른 쪽 프레임은 늘 더 높은 주소에 있다. 아니면 망가진 고리라 멈춘다
            guard frame.0 > fp else { break }
            fp = frame.0
        }
        return count
    }

    /// 메인 스레드를 일부러 붙잡고 호출 순서를 떠 본다 (`--report-preview hang`).
    static func preview() -> HangReport? {
        mainThread = pthread_mach_thread_np(pthread_self())
        var result: HangReport?
        let done = DispatchSemaphore(value: 0)
        Thread {
            Thread.sleep(forTimeInterval: 0.5)
            result = sample(seconds: 1.5)
            done.signal()
        }.start()
        previewBusy(until: Date().addingTimeInterval(1.5))
        done.wait()
        return result
    }

    @inline(never)
    static func previewBusy(until end: Date) {
        while Date() < end { usleep(10_000) }
    }
}

/// 이 앱 실행 파일. 호출 순서의 주소를 기호 이름과 실행 파일 안 위치로 바꾼다.
/// 시스템이 주는 dladdr는 내보낸 기호만 알아 앱 안 함수 이름을 틀리게 주므로, 실행 파일의 기호 표를 직접 읽는다.
final class AppImage {
    static let shared = AppImage()
    #if arch(arm64)
    static let arch = "arm64"
    #else
    static let arch = "x86_64"
    #endif

    let base: UInt
    let uuid: String
    /// (옮기기 전 주소, 문자열 표 위치)를 주소 순으로.
    private var symbols: [(UInt64, UInt32)] = []
    private var strings: UnsafePointer<CChar>?
    private var slide: Int = 0

    private init() {
        base = UInt(bitPattern: #dsohandle)
        var uuid = ""
        var text: UInt64 = 0
        var linkedit: segment_command_64?
        var symtab: symtab_command?
        let header = UnsafeRawPointer(#dsohandle).assumingMemoryBound(to: mach_header_64.self)
        var command = UnsafeRawPointer(#dsohandle).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            switch Int32(bitPattern: load.cmd) {
            case Int32(bitPattern: UInt32(LC_SEGMENT_64)):
                let segment = command.assumingMemoryBound(to: segment_command_64.self).pointee
                let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { text = segment.vmaddr }
                if name == "__LINKEDIT" { linkedit = segment }
            case Int32(bitPattern: UInt32(LC_SYMTAB)):
                symtab = command.assumingMemoryBound(to: symtab_command.self).pointee
            case Int32(bitPattern: UInt32(LC_UUID)):
                let raw = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                uuid = UUID(uuid: raw).uuidString.lowercased()
            default:
                break
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        self.uuid = uuid
        slide = Int(bitPattern: base) - Int(text)
        guard let linkedit, let symtab else { return }
        let start = UnsafeRawPointer(bitPattern: slide + Int(linkedit.vmaddr) - Int(linkedit.fileoff))!
        strings = start.advanced(by: Int(symtab.stroff)).assumingMemoryBound(to: CChar.self)
        let table = start.advanced(by: Int(symtab.symoff)).assumingMemoryBound(to: nlist_64.self)
        symbols = (0..<Int(symtab.nsyms)).compactMap { index in
            let entry = table[index]
            // 디버그 줄(N_STAB)은 빼고 섹션 안에 정의된 기호만
            guard entry.n_type & UInt8(N_STAB) == 0, entry.n_type & UInt8(N_TYPE) == UInt8(N_SECT),
                  entry.n_un.n_strx < symtab.strsize else { return nil }
            return (entry.n_value, entry.n_un.n_strx)
        }.sorted { $0.0 < $1.0 }
    }

    /// 돌아갈 주소는 부른 명령의 다음 자리라, 함수 끝에서 불렀으면 다음 함수를 가리킨다. 기호는 한 칸 앞으로 찾는다.
    func frame(_ address: UInt, returnAddress: Bool = false) -> CrashReport.Frame {
        let lookup = returnAddress && address > 0 ? address - 1 : address
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0, let start = info.dli_fbase else {
            return CrashReport.Frame(image: "?", symbol: nil, location: nil, offset: Int(bitPattern: address), inApp: false)
        }
        let imageBase = UInt(bitPattern: start)
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let offset = Int(bitPattern: address &- imageBase)
        if imageBase == base {
            let found = symbol(at: lookup)
            return CrashReport.Frame(image: image, symbol: found?.0, location: found.map { $0.1 + Int(address - lookup) }, offset: offset, inApp: true)
        }
        let symbol = info.dli_sname.map { Self.readable(String(cString: $0)) }
        let location = info.dli_saddr.map { Int(bitPattern: address &- UInt(bitPattern: $0)) }
        return CrashReport.Frame(image: image, symbol: symbol, location: location, offset: offset, inApp: false)
    }

    /// 주소를 넘지 않는 가장 가까운 기호와 그 기호에서 떨어진 거리.
    private func symbol(at address: UInt) -> (String, Int)? {
        guard let strings else { return nil }
        let target = UInt64(Int(bitPattern: address) - slide)
        var low = 0, high = symbols.count
        while low < high {
            let middle = (low + high) / 2
            if symbols[middle].0 <= target { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let (value, index) = symbols[low - 1]
        return (Self.readable(String(cString: strings.advanced(by: Int(index)))), Int(target - value))
    }

    /// `_$s7RunTime…` 꼴 Swift 이름을 사람이 읽는 꼴로. 모듈 이름은 뗀다.
    static func readable(_ name: String) -> String {
        let bare = name.hasPrefix("_") ? String(name.dropFirst()) : name
        guard let demangled = bare.withCString({ swift_demangle($0, strlen($0), nil, nil, 0) }) else { return bare }
        defer { free(demangled) }
        // 컴파일러가 특수화한 사본은 `function signature specialization <…> of`가 붙어 원래 함수 이름만 남긴다
        return String(cString: demangled)
            .replacingOccurrences(of: #"^((\w+ )*specialization <[^>]*> of )+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(RunTime|Swift|Foundation|AppKit|SwiftUI|ReportCore|UsageCore|GameCore|SearchCore|WorkLogCore|DesignSyncCore|HostsCore)\."#,
                                  with: "", options: .regularExpression)
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

@_silgen_name("swift_demangle")
private func swift_demangle(_ mangled: UnsafePointer<CChar>?, _ length: Int, _ output: UnsafeMutablePointer<CChar>?,
                            _ outputSize: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
