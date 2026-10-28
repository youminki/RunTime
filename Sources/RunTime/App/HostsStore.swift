import AppKit
import HostsCore

/// /etc/hosts 읽기·저장. 고친 것은 `draft`에 모았다가 저장할 때 한 번에 쓴다 (저장마다 관리자 암호를 물어서).
/// 화면 점검은 `RUNTIME_HOSTS`로 다른 파일을 쓰고, 그때는 암호 없이 바로 쓴다.
@MainActor
final class HostsStore: ObservableObject {
    static let shared = HostsStore()

    static let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNTIME_HOSTS"] ?? "/etc/hosts")
    static let backups = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RunTime/hosts-backups")
    private static let keptBackups = 20

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
    @Published private(set) var saving = false
    /// 고치는 동안 다른 곳(터미널, 다른 앱)에서 파일이 바뀌었다.
    @Published private(set) var changedOutside = false
    private var modified: Date?
    private var watch: Timer?

    private init() { load() }

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
        let date = (try? FileManager.default.attributesOfItem(atPath: Self.url.path))?[.modificationDate] as? Date
        guard date != modified || modified == nil else { return }
        load()
    }

    func load() {
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
        backup(current)
        saving = true
        // 암호 창이 떠 있는 동안 화면에서 더 고칠 수 있다. 끝난 뒤 그 변경을 덮지 않으려고 지금 판을 적어 둔다
        let editing = draft.text
        let target = Self.url
        let system = isSystem
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = system ? Self.writeAsAdmin(text, expecting: current) : Self.writeDirect(text, to: target)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.saving = false
                if let failure { Diagnostics.record("호스트", failure) }
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

    // MARK: 백업

    struct Backup: Identifiable {
        var id: URL { url }
        let url: URL
        let date: Date
    }

    var backupList: [Backup] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "txt" }.map { url in
            Backup(url: url, date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    /// 저장 직전 판을 남긴다. 바로 앞 백업과 같으면 또 남기지 않는다.
    private func backup(_ text: String) {
        try? FileManager.default.createDirectory(at: Self.backups, withIntermediateDirectories: true)
        let list = backupList
        if let last = list.first, (try? String(contentsOf: last.url, encoding: .utf8)) == text { return }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        try? text.write(to: Self.backups.appendingPathComponent("hosts-\(format.string(from: Date())).txt"), atomically: true, encoding: .utf8)
        for old in backupList.dropFirst(Self.keptBackups) { try? FileManager.default.removeItem(at: old.url) }
    }

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
