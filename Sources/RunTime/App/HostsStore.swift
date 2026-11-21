import AppKit
import HostsCore

/// /etc/hosts 읽기·저장. 고친 것은 `draft`에 모았다가 저장할 때 한 번에 쓴다.
/// 기본은 저장마다 관리자 암호를 묻고, `setPasswordless`로 파일 소유자를 이 계정으로 바꿔 두면 암호 없이 바로 쓴다.
/// 화면 점검은 `RUNTIME_HOSTS`로 다른 파일을 쓰고, 그때는 암호 없이 바로 쓴다.
@MainActor
final class HostsStore: ObservableObject {
    static let shared = HostsStore()

    static let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNTIME_HOSTS"] ?? "/etc/hosts")
    /// `RUNTIME_HOSTS`로 사본을 쓰는 점검은 백업도 사본 옆에 둔다. 진짜 백업을 시험용 판으로 덮지 않게.
    static let backups = ProcessInfo.processInfo.environment["RUNTIME_HOSTS"].map { URL(fileURLWithPath: $0 + "-backups") }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RunTime/hosts-backups")

    /// 디스크에 있는 판.
    @Published private(set) var saved = HostsFile("") { didSet { refreshDerived() } }
    @Published var draft = HostsFile("") { didSet { refreshDerived() } }
    /// 한 번이라도 읽었는지. 못 읽은 채 고치면 빈 판 위에 써서 파일을 날리므로 고치기·저장을 막는다.
    @Published private(set) var loaded = false
    /// 진단·정리·바뀐 줄 수. 검색 글자를 칠 때마다 다시 세지 않게 판이 바뀔 때만 센다.
    @Published private(set) var issues: [HostsIssue] = []
    /// 고칠 판의 묶음. 화면이 그릴 때마다 줄을 다시 훑지 않게 판이 바뀔 때만 센다.
    @Published private(set) var sections: [HostsFile.Section] = []
    /// 판을 통째로 바꿀 때(다시 읽기·되돌리기·저장 뒤) 오른다. 화면은 이 값으로 지연 목록을 새로 만든다
    /// (줄 수가 크게 줄면 지연 목록이 빈 화면이나 옛 줄을 남겨서).
    @Published private(set) var generation = 0
    @Published private(set) var organizedText = ""
    @Published private(set) var changedLines = 0
    /// 기한(메모의 `~yyyy-MM-dd`)이 지났는데 켜져 있는 항목.
    @Published private(set) var expired: [HostsFile.Item] = []
    @Published private(set) var problem: String?
    /// 이 계정이 /etc/hosts를 바로 쓸 수 있는지. 켜 두면 저장할 때 관리자 암호를 묻지 않는다.
    @Published private(set) var passwordless = false
    /// 마지막 저장 직전의 파일 글. 없으면 nil.
    @Published private(set) var previousText: String?
    @Published private(set) var saving = false
    /// 고치는 동안 다른 곳(터미널, 다른 앱)에서 파일이 바뀌었다.
    @Published private(set) var changedOutside = false
    private var modified: Date?
    private var watch: Timer?

    private init() {
        previousText = Self.readPrevious()
        load()
    }

    var dirty: Bool { draft.text != saved.text }
    var canEdit: Bool { loaded && problem == nil }

    private func refreshDerived() {
        issues = HostsDoctor.issues(in: draft)
        sections = draft.sections
        organizedText = HostsFormatter.organized(draft).text
        changedLines = draft == saved ? 0 : LineDiff.changes(from: saved.text, to: draft.text).filter { $0.kind != .same }.count
        expired = draft.expired(on: Self.today())
    }
    private var isSystem: Bool { Self.url.path == "/etc/hosts" }
    /// 저장할 때 관리자 암호를 물어야 하는지. 시험용 파일이나 이미 쓸 수 있는 파일이면 묻지 않는다.
    var needsPassword: Bool { isSystem && !passwordless }

    /// 화면이 보이는 동안만 2초마다 바뀌었는지 본다. hosts는 작아 날짜만 보고 바뀌었을 때만 읽는다.
    func setWatching(_ on: Bool) {
        watch?.invalidate()
        watch = nil
        guard on else { return }
        reloadIfChanged()
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    func reloadIfChanged() {
        // chown·chmod는 수정 시각을 바꾸지 않아 따로 본다 (터미널이나 OS 업데이트가 권한을 되돌릴 수 있다)
        let writable = FileManager.default.isWritableFile(atPath: Self.url.path)
        if writable != passwordless { passwordless = writable }
        let date = (try? FileManager.default.attributesOfItem(atPath: Self.url.path))?[.modificationDate] as? Date
        guard date != modified || modified == nil else { return }
        load()
    }

    func load() {
        passwordless = FileManager.default.isWritableFile(atPath: Self.url.path)
        do {
            let data = try Data(contentsOf: Self.url)
            // UTF-8이 아닌 글자를 다른 인코딩으로 읽어 다시 쓰면 그 줄이 깨진다. 읽기만 하고 고치지 못하게 둔다
            guard let text = String(data: data, encoding: .utf8) else {
                modified = nil
                problem = "\(Self.url.path)에 UTF-8이 아닌 글자가 있어 고칠 수 없습니다. 터미널에서 그 줄을 고친 뒤 다시 여세요"
                return
            }
            modified = (try? FileManager.default.attributesOfItem(atPath: Self.url.path))?[.modificationDate] as? Date
            let file = HostsFile(text)
            problem = nil
            let first = !loaded
            loaded = true
            guard file != saved || first else { return }
            if dirty { changedOutside = true } else { draft = file; generation += 1 }
            saved = file
        } catch {
            // 같은 수정 시각으로 되돌아와도(mv로 되돌림, 권한만 바꿨다 풂) 다음 감시 때 다시 읽게 한다
            modified = nil
            problem = "\(Self.url.path)를 읽지 못했습니다: \(error.localizedDescription)"
            ProblemReporter.screen("호스트", "호스트 파일을 읽지 못함", detail: "파일: \(Self.url.path)\n오류: \(error)")
        }
    }

    /// 고친 것을 버리고 디스크 판으로 돌아간다.
    func discard() {
        draft = saved
        generation += 1
        changedOutside = false
    }

    /// `text`를 쓴다. 실패하면 이유를 넘긴다. 취소도 이유로 넘긴다.
    func save(_ text: String, done: @escaping (String?) -> Void) {
        guard !saving else { return done("이미 저장하는 중입니다") }
        guard canEdit, let current = try? String(contentsOf: Self.url, encoding: .utf8) else {
            return done("파일을 읽지 못해 저장하지 않았습니다")
        }
        guard current == saved.text else {
            load()
            return done("저장하기 전에 다른 곳에서 파일이 바뀌었습니다. 바뀐 내용을 읽었으니 확인하고 다시 저장하세요")
        }
        stageBackup(current)
        saving = true
        // 암호 창이 떠 있는 동안 화면에서 더 고칠 수 있다. 끝난 뒤 그 변경을 덮지 않으려고 지금 판을 적어 둔다
        let editing = draft.text
        let target = Self.url
        let system = isSystem
        // 소유자를 바꿔 둔 파일은 암호 없이 제자리에 쓴다. 그 사이 시스템이 되돌렸으면 아래에서 다시 암호 쓰기로 간다
        let writable = system && FileManager.default.isWritableFile(atPath: target.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure = !system ? Self.writeDirect(text, to: target)
                : writable ? Self.writeInPlace(text, expecting: current, to: target) : Self.writeAsAdmin(text, expecting: current)
            // 확인한 뒤 시스템이 소유자를 되돌렸으면 관리자 암호 쓰기로 다시 시도한다
            if failure == Self.needsAdmin { failure = Self.writeAsAdmin(text, expecting: current) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.saving = false
                // 저장에 실패하거나 취소했으면 진짜 직전 판을 지키려고 임시로 남긴 것을 버린다.
                // 제자리 쓰기가 도중에 실패해 복구까지 못 했으면 그 원래 글이 마지막 보루라 직전 판으로 올린다
                if failure == nil || failure?.contains("온전하지") == true { self.commitBackup() } else { self.discardBackup() }
                // 암호 창을 닫았거나 그사이 파일이 바뀐 것은 사용자 쪽 일이라 기록만 한다
                if let failure, failure.hasPrefix("저장하지 못했습니다") || failure.contains("실행하지 못했습니다") || failure.contains("쓰지 못했습니다") {
                    ProblemReporter.screen("호스트", failure, detail: "파일: \(target.path) · 쓴 방식: \(!system ? "직접" : writable ? "암호 없이 제자리에" : "관리자 권한으로")")
                } else if let failure {
                    Diagnostics.record("호스트", failure)
                }
                // 다시 읽기 전에 그동안 화면에서 더 고쳤는지 본다 (다시 읽으면 고치지 않은 판은 새 판으로 바뀐다)
                let editedMeanwhile = self.draft.text != editing
                self.modified = nil
                self.load()
                if failure == nil {
                    if editedMeanwhile {
                        // 고치던 판이 아닌 글을 저장했으면(메뉴바 빠른 전환) 고친 것을 그대로 저장하면 그 변경을 되돌린다
                        self.changedOutside = editing != text
                    } else {
                        self.draft = self.saved
                        self.generation += 1
                        self.changedOutside = false
                    }
                }
                done(failure)
            }
        }
    }

    private nonisolated static func writeDirect(_ text: String, to url: URL) -> String? {
        do { try text.write(to: url, atomically: true, encoding: .utf8); return nil }
        catch { return "저장하지 못했습니다: \(error.localizedDescription)" }
    }

    /// 제자리 쓰기를 못 열어(소유자가 되돌려짐) 관리자 암호로 다시 써야 한다는 표시.
    private nonisolated static let needsAdmin = "needs-admin"

    /// 소유자가 이 계정인 /etc/hosts에 바로 쓴다. /etc 폴더는 root 것이라 임시 파일로 바꿔치기(mv)는 못 해서 파일을 제자리에서 덮는다.
    /// 파일이 비는 순간이 없게 앞에서부터 새 글을 쓴 뒤 남는 꼬리만 자른다.
    /// 쓰다가 실패하면 읽어 둔 원래 글로 되돌리고, 그것마저 안 되면 그 사실을 알린다.
    private nonisolated static func writeInPlace(_ text: String, expecting old: String, to url: URL) -> String? {
        guard (try? String(contentsOf: url, encoding: .utf8)) == old else {
            return "저장하기 전에 다른 곳에서 파일이 바뀌어 저장하지 않았습니다. 바뀐 내용을 읽었으니 확인하고 다시 저장하세요"
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else { return needsAdmin }
        func overwrite(_ content: String) throws {
            let data = Data(content.utf8)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            try handle.synchronize()
        }
        do {
            try overwrite(text)
        } catch {
            if (try? overwrite(old)) == nil {
                return "저장하지 못했고 파일이 온전하지 않을 수 있습니다. 왼쪽 아래 ‘마지막 저장 전으로’로 되돌리세요: \(error.localizedDescription)"
            }
            return "저장하지 못했습니다: \(error.localizedDescription)"
        }
        // 맥은 hosts가 바뀌면 스스로 다시 읽는다. 캐시 비우기는 관리자 권한이 필요한 mDNSResponder 쪽을 빼고 한다
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        flush.standardOutput = FileHandle.nullDevice
        flush.standardError = FileHandle.nullDevice
        try? flush.run()
        return nil
    }

    /// /etc/hosts의 소유자를 이 계정으로 바꾸거나(켜기) root로 되돌린다(끄기). 관리자 암호를 한 번 묻는다.
    /// 켜 두면 이 계정으로 도는 모든 프로그램이 hosts를 고칠 수 있다.
    func setPasswordless(_ on: Bool, done: @escaping (String) -> Void) {
        guard isSystem else { return }
        guard !saving else { return done("저장하는 중이라 바꾸지 않았습니다") }
        // 소유자를 바꾸는 동안 저장이 끼어들어 되돌리지 않게 막는다
        saving = true
        let owner = on ? NSUserName() : "root:wheel"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // 소유자와 함께 쓰기 권한도 644로 맞춰, 그룹·기타 쓰기가 열려 있어도 켜고 끈 상태가 분명하게 한다
            process.arguments = [
                "-e", "on run argv",
                "-e", "do shell script \"/usr/sbin/chown \" & quoted form of (item 1 of argv) & \" /private/etc/hosts && /bin/chmod 644 /private/etc/hosts\" with prompt \"RunTime이 hosts 파일(/etc/hosts)의 소유자를 바꾸려고 합니다.\" with administrator privileges",
                "-e", "end run", owner,
            ]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            var message = ""
            var ok = false
            if (try? process.run()) != nil {
                message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                ok = process.terminationStatus == 0
            } else {
                message = "osascript를 실행하지 못했습니다"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.saving = false
                self.modified = nil
                self.load()
                // 결과는 명령이 성공했는지가 아니라 지금 파일이 실제로 어떤 상태인지로 알린다
                if ok, self.passwordless == on {
                    done(on ? "이제 암호 없이 저장합니다. 끄려면 왼쪽 아래 ‘암호 없이 저장’ 스위치를 끄세요" : "이제 저장할 때마다 관리자 암호를 묻습니다")
                } else if message.contains("-128") {
                    done("암호 입력을 취소해 바꾸지 않았습니다")
                } else if ok {
                    done(on ? "소유자는 바꿨지만 이 계정이 파일을 쓸 수 없어 저장할 때 계속 암호를 묻습니다" : "소유자를 되돌렸지만 파일이 아직 이 계정에 쓸 수 있게 열려 있습니다. 터미널에서 ls -l /etc/hosts로 확인하세요")
                } else {
                    done("바꾸지 못했습니다: " + message.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    /// 임시 파일을 관리자 권한으로 /etc/hosts 자리에 바꿔 넣고 DNS 캐시를 비운다.
    /// 암호 창이 떠 있는 동안 다른 곳에서 고쳤을 수 있어, 셸 안에서 읽었던 판과 같은지 다시 보고 다르면 손대지 않는다.
    /// 같은 폴더에 다 쓴 뒤 mv로 바꿔 넣어 도중에 끊겨도 반쯤 쓴 파일이 남지 않는다.
    /// 경로는 AppleScript 인자로 넘겨 따옴표가 섞여도 명령이 깨지지 않게 한다.
    private nonisolated static func writeAsAdmin(_ text: String, expecting old: String) -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-hosts-\(UUID().uuidString)")
        let new = folder.appendingPathComponent("new")
        let before = folder.appendingPathComponent("old")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: new, atomically: true, encoding: .utf8)
            try old.write(to: before, atomically: true, encoding: .utf8)
        } catch { return "임시 파일을 쓰지 못했습니다: \(error.localizedDescription)" }
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = [
            "/usr/bin/cmp -s \" & quoted form of (item 2 of argv) & \" /etc/hosts || exit 3",
            "/bin/cp \" & quoted form of (item 1 of argv) & \" /private/etc/hosts.runtime",
            "/usr/sbin/chown root:wheel /private/etc/hosts.runtime",
            "/bin/chmod 644 /private/etc/hosts.runtime",
            "/bin/mv -f /private/etc/hosts.runtime /private/etc/hosts",
            "{ /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder; true; }",
        ].joined(separator: " && ")
        let script = [
            "on run argv",
            "do shell script \"\(shell)\" with prompt \"RunTime이 호스트 파일(/etc/hosts)을 고치려고 합니다.\" with administrator privileges",
            "end run",
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = script.flatMap { ["-e", $0] } + [new.path, before.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do { try process.run() } catch { return "osascript를 실행하지 못했습니다: \(error.localizedDescription)" }
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        if message.contains("-128") { return "암호 입력을 취소해 저장하지 않았습니다" }
        if message.contains("(3)") { return "암호를 묻는 동안 다른 곳에서 파일이 바뀌어 저장하지 않았습니다. 바뀐 내용을 읽었으니 확인하고 다시 저장하세요" }
        return "저장하지 못했습니다: " + message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 메뉴바에서 바로

    /// 메뉴바에서 묶음을 켜고 끈다. 화면에서 고치던 것이 있으면 섞이지 않게 하지 않는다.
    func quickToggle(_ section: HostsFile.Section, _ enabled: Bool, done: @escaping (String?) -> Void) {
        reloadIfChanged()
        guard !dirty else { return done("호스트 화면에 저장하지 않은 변경이 있어 바꾸지 않았습니다") }
        guard let current = saved.section(matching: section) else {
            return done("메뉴를 연 뒤 파일이 바뀌어 바꾸지 않았습니다. 다시 열어 고르세요")
        }
        var file = saved
        file.setEnabled(current.items, enabled)
        save(file.text, done: done)
    }

    /// 기한 지난 항목이 켜져 있으면 하루 한 번 알린다. 끄려면 암호가 필요해 저절로 끄지는 않는다.
    /// 날이 바뀌면 파일이 그대로여도 기한 지남이 달라져, 여기서 그날 날짜로 다시 센다.
    /// 그날 이미 알린 이름만 남았으면 또 알리지 않고, 새로 기한이 지난 이름이 생기면 다시 알린다.
    func remindExpired() {
        load()
        let day = Self.today()
        expired = draft.expired(on: day)
        let onDisk = saved.expired(on: day)
        let names = Set(onDisk.map(\.name))
        let defaults = UserDefaults.standard
        let told = defaults.string(forKey: "hosts.expiredReminded") == day
            ? Set(defaults.stringArray(forKey: "hosts.expiredRemindedNames") ?? []) : []
        guard !names.isEmpty, !names.isSubset(of: told) else { return }
        defaults.set(day, forKey: "hosts.expiredReminded")
        defaults.set(Array(names.union(told)), forKey: "hosts.expiredRemindedNames")
        let list = onDisk.prefix(3).map(\.name).joined(separator: ", ") + (onDisk.count > 3 ? " 외 \(onDisk.count - 3)개" : "")
        Notifier.shared.send(title: "기한 지난 호스트가 켜져 있습니다", body: list, opens: .hosts)
    }

    /// 이 Mac 시간대의 `yyyy-MM-dd`. 기한을 적을 때와 견줄 때 같은 기준을 쓴다.
    nonisolated static func day(_ date: Date) -> String { dayFormat.string(from: date) }
    nonisolated static func today() -> String { day(Date()) }
    nonisolated static func date(_ day: String) -> Date? { dayFormat.date(from: day) }

    private nonisolated static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    // MARK: 환경 전환

    /// 묶음마다 최근에 쓴 주소 (새것부터, 5개). 개발 ↔ 스테이징을 오갈 때 다시 치지 않게.
    func recentIPs(for title: String?) -> [String] {
        UserDefaults.standard.stringArray(forKey: "hosts.recentIPs.\(title ?? "")") ?? []
    }

    func remember(_ ips: [String], for title: String?) {
        let key = "hosts.recentIPs.\(title ?? "")"
        var list = recentIPs(for: title)
        for ip in ips.reversed() { list.removeAll { $0 == ip }; list.insert(ip, at: 0) }
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: key)
    }

    // MARK: 직전 판

    private static var previousURL: URL { backups.appendingPathComponent("previous.txt") }
    private static var pendingURL: URL { backups.appendingPathComponent("previous.pending.txt") }

    private static func readPrevious() -> String? { try? String(contentsOf: previousURL, encoding: .utf8) }

    /// 저장 직전 판을 임시로 적어 둔다. 저장이 끝나기 전에는 진짜 직전 판(previous.txt)을 건드리지 않는다.
    private func stageBackup(_ text: String) {
        try? FileManager.default.createDirectory(at: Self.backups, withIntermediateDirectories: true)
        try? text.write(to: Self.pendingURL, atomically: true, encoding: .utf8)
    }

    /// 저장이 끝났으면 임시로 적어 둔 판을 직전 판으로 올린다. 저장할 때마다 덮어써 하나만 남는다.
    private func commitBackup() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.pendingURL.path) else { return }
        try? fm.removeItem(at: Self.previousURL)
        try? fm.moveItem(at: Self.pendingURL, to: Self.previousURL)
        previousText = Self.readPrevious()
    }

    private func discardBackup() { try? FileManager.default.removeItem(at: Self.pendingURL) }

    // MARK: 확인

    /// 맥이 이 이름을 실제로 어디로 푸는지 (hosts, VPN, DNS를 다 거친 결과).
    nonisolated static func resolve(_ name: String, done: @escaping @Sendable ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
            process.arguments = ["-q", "host", "-a", "name", name]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return DispatchQueue.main.async { done([]) } }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let addresses = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "\n").compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] == "ip_address" || parts[0] == "ipv6_address" else { return nil }
                return parts[1]
            }
            DispatchQueue.main.async { done(Array(NSOrderedSet(array: addresses)) as? [String] ?? addresses) }
        }
    }
}
