import AppKit
import WebKit
import WorkLogCore

/// 앱 안에 숨겨 둔 팀즈 웹. 처음 한 번 로그인해 두면 팀즈 창을 띄우지 않고 그 채팅에 보고서를 올린다.
/// 웹훅(Power Automate)도, 손쉬운 사용 권한도 필요 없다. 로그인 쿠키는 이 Mac의 웹 저장소에만 남는다.
/// 입력 칸(`data-tid="ckeditor"`)에 붙여넣기 이벤트로 서식 글을 넣고 보내기 단추를 누른 뒤, 입력 칸이 비었는지로 확인한다.
final class TeamsWeb: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = TeamsWeb()

    enum State: Equatable { case unknown, loading, needsLogin, ready, failed(String) }

    @Published private(set) var state: State = .unknown
    /// 로그인 창을 띄워 둔 동안.
    @Published private(set) var loggingIn = false

    private static let home = URL(string: "https://teams.cloud.microsoft/v2/")!
    private var webView: WKWebView?
    private var window: NSWindow?
    private var readyWaiters: [(Bool) -> Void] = []
    private var watch: Timer?
    private var sending = false
    /// 숨은 팀즈에 지금 떠 있는 채팅 (팀즈는 이동한 뒤 주소에서 대화 ID를 지워 직접 기억한다).
    private var shownConversation: String?
    /// 보낸 뒤 10분 동안 안 쓰면 팀즈 웹을 내려 메모리를 돌려준다 (팀즈 웹은 수백 MB를 쓴다).
    private var idle: Timer?

    /// 로그인해 둔 것이 풀렸다 (다시 로그인하면 지운다). 설정 화면이 이유를 보이려고 둔다.
    @Published private(set) var lostLogin = UserDefaults.standard.bool(forKey: "workLog.teamsWebLost") {
        didSet { UserDefaults.standard.set(lostLogin, forKey: "workLog.teamsWebLost") }
    }

    /// 로그인해 두었는지. 풀린 것을 알면 끄고, 그동안은 팀즈 앱을 여는 길로 보낸다.
    var everReady: Bool {
        get { UserDefaults.standard.bool(forKey: "workLog.teamsWebReady") }
        set { UserDefaults.standard.set(newValue, forKey: "workLog.teamsWebReady") }
    }

    // MARK: 띄우기

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780), configuration: configuration)
        // 팀즈는 웹뷰 기본 사용자 에이전트를 지원하지 않는 브라우저로 본다. 이 Mac의 사파리 버전을 써서
        // 시간이 지나도 ‘오래된 브라우저’로 막히지 않게 한다 (웹뷰와 사파리는 같은 WebKit이다)
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "18.0"
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Safari/605.1.15"
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        // 창 밖에 둔 웹뷰는 타이머가 멈춰 팀즈가 뜨지 않는다. 보이지 않는 창에 넣어 둔다
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.title = "팀즈 로그인"
        window.delegate = self
        self.window = window
        hide()
        return view
    }

    /// 화면에 보이지 않게 둔다 (투명, 클릭 통과, 창 목록·⌘Tab에서 뺌).
    private func hide() {
        guard let window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        window.level = .normal
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        // 로그인 창이 키 창인 채로 숨으면 사용자가 치는 글이 보이지 않는 팀즈 입력 칸으로 간다. 한 번 내렸다 뒤에 둔다
        window.orderOut(nil)
        window.orderBack(nil)
        loggingIn = false
    }

    /// 팀즈를 띄워 로그인돼 있는지 본다. 로그인돼 있지 않으면 `needsLogin`.
    func prepare(_ done: ((Bool) -> Void)? = nil) {
        // 띄워 둔 사이 토큰이 만료돼 로그인 화면으로 넘어갔을 수 있어 주소도 본다
        if state == .ready, webView?.url?.host?.hasSuffix("teams.cloud.microsoft") == true { done?(true); return }
        if state == .ready { state = .unknown }
        // 띄우는 중에 10분 뒤 내리기가 돌면 웹뷰가 사라져 기다리던 쪽이 영영 깨지 않는다
        idle?.invalidate()
        if let done { readyWaiters.append(done) }
        guard state != .loading else { return }
        load()
    }

    /// 팀즈 첫 화면을 새로 읽는다. 새로 읽으면 팀즈가 마지막 채팅을 아무거나 열어 두므로 떠 있는 채팅을 잊는다.
    private func load() {
        state = .loading
        shownConversation = nil
        makeWebView().load(URLRequest(url: Self.home))
        startWatch()
    }

    /// 로그인 창을 보인다. 로그인을 마치면 저절로 숨는다.
    func showLogin() {
        idle?.invalidate()
        _ = makeWebView()
        if state != .ready, state != .loading { load() }
        guard let window else { return }
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loggingIn = true
    }

    /// 로그아웃: 하던 일을 멈추고 마이크로소프트 쪽 쿠키·저장소를 지운다. 다 지운 뒤에 상태를 바꾼다
    /// (지우는 중에 다시 로그인하면 옛 쿠키와 섞인다).
    func signOut() {
        watch?.invalidate()
        idle?.invalidate()
        shownConversation = nil
        finish(false)
        if loggingIn { hide() }
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
        state = .loading
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            let microsoft = records.filter { ["microsoft", "office", "live.com", "teams"].contains(where: $0.displayName.contains) }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: microsoft) {
                self?.everReady = false
                self?.lostLogin = false
                self?.state = .unknown
            }
        }
    }

    /// 팀즈가 다 떴는지(입력 칸이나 채팅 목록), 로그인 화면인지 0.5초마다 본다 (최대 60초, 로그인 중에는 계속).
    /// 팀즈 웹 토큰은 하루마다 만료돼 로그인 화면을 거쳐 저절로 돌아온다. 그래서 로그인 화면에 15초 넘게 머물 때만
    /// 로그인이 풀린 것으로 본다. 그동안 기억한 계정 하나만 있는 계정 고르기와 ‘로그인 상태 유지’는 대신 누른다.
    private func startWatch() {
        watch?.invalidate()
        let started = Date()
        var loginSince: Date?
        var continued: URL?
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard let view = self.webView else {
                timer.invalidate()
                if self.state == .loading { self.state = .unknown }
                return self.finish(false)
            }
            let host = view.url?.host ?? ""
            if host.contains("login.") || host.contains("microsoftonline") || host.contains("live.com") {
                let since = loginSince ?? Date()
                loginSince = since
                // 로그인 창을 띄웠을 때는 다른 계정을 고를 수 있게 사람에게 맡기고, 한 화면에서 한 번만 누른다
                if !self.loggingIn, continued != view.url {
                    continued = view.url
                    view.evaluateJavaScript(Self.autoContinue, completionHandler: nil)
                }
                if self.loggingIn {
                    if self.state != .needsLogin { self.state = .needsLogin }
                } else if Date().timeIntervalSince(since) > 15 {
                    timer.invalidate()
                    self.state = .needsLogin
                    self.notifyLoggedOut()
                    // 다음 보고서가 15초를 다시 기다리지 않고 바로 팀즈 앱 길로 가게
                    if self.everReady { self.lostLogin = true }
                    self.everReady = false
                    self.finish(false)
                }
                return
            }
            loginSince = nil
            view.evaluateJavaScript("!!document.querySelector('[data-tid=\"ckeditor\"], [data-tid=\"app-bar-chat\"], [role=\"tree\"]') && document.title.includes('Microsoft Teams')") { value, _ in
                // 멈춘 뒤(로그아웃 등)에 돌아온 답은 버린다
                guard timer.isValid else { return }
                if value as? Bool == true {
                    timer.invalidate()
                    self.state = .ready
                    self.everReady = true
                    self.lostLogin = false
                    self.notifiedLogout = false
                    if self.loggingIn { self.hide() }
                    self.finish(true)
                } else if !self.loggingIn, Date().timeIntervalSince(started) > 60 {
                    timer.invalidate()
                    if self.state == .loading { self.state = .failed("팀즈 웹이 뜨지 않았습니다") }
                    self.finish(false)
                }
            }
        }
        // 메뉴바 메뉴를 여는 동안에도 돌게 (기본 모드에만 걸면 그동안 멈췄다가 시간 초과로 잘못 판정한다)
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    /// 로그인 화면에서 사람 손 없이 넘어갈 수 있는 두 곳만 누른다. 비밀번호·인증 앱을 묻는 화면은 건드리지 않는다.
    /// - 계정 고르기에 기억된 계정이 하나뿐일 때 그 계정 (‘다른 계정 사용’은 빼고)
    /// - ‘로그인 상태를 유지하시겠습니까?’의 ‘예’ (다음에도 로그인이 풀리지 않게)
    private static let autoContinue = """
    (() => {
      const tiles = [...document.querySelectorAll('#tilesHolder [role="button"][data-test-id]')].filter(t => t.id !== 'otherTile');
      if (tiles.length === 1) { tiles[0].click(); return 'account'; }
      if (document.querySelector('#KmsiCheckboxField, input[name="DontShowAgain"]')) {
        const yes = document.querySelector('#idSIButton9');
        if (yes) { yes.click(); return 'kmsi'; }
      }
      return '';
    })()
    """

    private var notifiedLogout = false

    /// 보고서를 보낼 때가 아니라 미리 알게 한 번만 알린다.
    private func notifyLoggedOut() {
        guard everReady, !notifiedLogout else { return }
        notifiedLogout = true
        Diagnostics.record("팀즈", "웹 로그인이 풀림")
        Notifier.shared.send(title: "팀즈 웹 로그인이 풀렸습니다",
                             body: "설정 > 팀즈에서 다시 로그인하세요. 그동안은 팀즈 앱을 열어 붙여 넣습니다.", opens: .workLog)
    }

    /// 켜 둔 동안 12시간마다 한 번 숨은 팀즈를 띄워 로그인을 새로 하고 (토큰·쿠키가 오래 묵지 않게),
    /// 풀렸으면 보고서를 보내기 전에 알린다. 다 뜨면 10분 뒤 내린다.
    func refreshIfDue() {
        guard everReady, !sending, !loggingIn, state != .loading else { return }
        let last = UserDefaults.standard.object(forKey: "workLog.teamsWebChecked") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 12 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: "workLog.teamsWebChecked")
        prepare { [weak self] _ in self?.scheduleUnload() }
    }

    private func finish(_ ready: Bool) {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0(ready) }
    }

    /// 로그인 중 새 창으로 여는 페이지(계정 고르기 등)는 같은 칸에서 연다.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    /// 로그인 창을 닫으면 없애지 않고 다시 숨긴다 (닫힌 창의 웹뷰는 멈춘다).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// 웹 내용 프로세스가 죽으면 빈 화면이 남아 ‘준비됨’인 채로 보내기가 실패한다. 다음에 다시 띄운다.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Diagnostics.record("팀즈", "웹 화면이 멈춰 다시 띄움")
        watch?.invalidate()
        state = .unknown
        shownConversation = nil
        finish(false)
    }

    /// 문서가 바뀌면(새로 읽기, 팀즈가 스스로 새로 고침) 떠 있던 채팅을 잊는다. 해시만 바뀌는 채팅 이동에서는 불리지 않는다.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        shownConversation = nil
    }

    /// 로그인 리다이렉트 중의 취소는 흔하니 무시하고, 그 밖의 실패도 판정은 지켜보는 타이머에 맡긴다.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    private func noteFailure(_ error: Error) {
        let error = error as NSError
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        Diagnostics.record("팀즈", "웹 읽기 실패: \(error.localizedDescription)")
    }

    private func scheduleUnload() {
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            guard let self, !self.sending, !self.loggingIn, self.state != .loading, self.readyWaiters.isEmpty else { return }
            self.webView?.load(URLRequest(url: URL(string: "about:blank")!))
            self.window?.orderOut(nil)
            self.window?.contentView = nil
            self.window = nil
            self.webView = nil
            self.shownConversation = nil
            if self.state == .ready { self.state = .unknown }
        }
    }

    // MARK: 보내기

    enum Outcome { case sent, unsure(String), failed(String) }

    /// 팀즈 웹으로 보낼 수 있는 링크인지 (채팅만. 채널·메시지 링크는 팀즈 앱 길로 간다).
    static func canSend(_ link: String) -> Bool {
        URL(string: link)?.path.hasPrefix("/l/chat/") == true && TeamsLink.conversationID(link) != nil
    }

    /// 링크의 채팅을 숨은 팀즈에서 열고 보고서를 올린다. `key`는 보낼 곳 이름으로, 그 채팅 창 제목을 기억해 두고
    /// 다음에는 제목에 그 채팅 이름이 있어야만 보낸다 (팀즈가 다른 채팅으로 돌려보내도 거기 올리지 않게).
    func send(_ report: String, title: String, link: String, key: String, done: @escaping (Outcome) -> Void) {
        guard Self.canSend(link), let conversation = TeamsLink.conversationID(link) else {
            return done(.failed("팀즈 채팅 링크가 아닙니다"))
        }
        guard !sending else { return done(.failed("이미 보내는 중입니다")) }
        sending = true
        let titleKey = "workLog.teamsTitle.\(key)"
        let expect = UserDefaults.standard.string(forKey: titleKey).flatMap(TeamsOpener.chatName) ?? ""
        let leftKey = "workLog.teamsWebFirst"
        let previous = UserDefaults.standard.string(forKey: leftKey) ?? ""
        prepare { [weak self] ready in
            guard let self else { return }
            guard ready, let view = self.webView else {
                self.sending = false
                self.scheduleUnload()
                return done(.failed(self.state == .needsLogin ? "팀즈 웹 로그인이 필요합니다" : "팀즈 웹이 뜨지 않았습니다"))
            }
            let html = TeamsLink.html(report, title: title)
            let plain = TeamsLink.plain(report, title: title)
            let first = plain.components(separatedBy: "\n").first ?? title
            UserDefaults.standard.set(first, forKey: leftKey)
            let arguments: [String: Any] = ["conversation": conversation, "html": html, "plain": plain, "first": first,
                                            "previous": previous,
                                            "notes": conversation == "48:notes", "expect": expect,
                                            "already": self.shownConversation == conversation]
            view.callAsyncJavaScript(Self.script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                self?.sending = false
                self?.scheduleUnload()
                switch result {
                case .success(let value):
                    let text = value as? String ?? ""
                    // 채팅을 연 뒤의 실패(쓰다 만 글 등)면 그 채팅이 떠 있다
                    self?.shownConversation = text.hasPrefix("open:") ? nil : conversation
                    if text.hasPrefix("sent:") {
                        // 처음 보낸 채팅이면 이름을 기억해 둔다 (설정 화면에도 보인다)
                        UserDefaults.standard.set(TeamsOpener.normalized(String(text.dropFirst(5))), forKey: titleKey)
                        done(.sent)
                    } else if text.hasPrefix("unsure:") {
                        done(.unsure(String(text.dropFirst(7))))
                    } else {
                        done(.failed(String(text.drop { $0 != ":" }.dropFirst())))
                    }
                case .failure(let error):
                    self?.shownConversation = nil
                    done(.failed("팀즈 웹에서 보내지 못했습니다: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// 채팅을 바꾸고(해시 경로라 다시 읽지 않는다) 그 채팅이 뜰 때까지 기다린 뒤 붙여 넣고 보낸다.
    /// 나와의 채팅은 제목의 (나)로, 다른 채팅은 기억한 채팅 이름으로 (처음이면 제목이 바뀐 것으로) 떴는지 본다.
    /// 어느 채팅이 떠 있는지 모르면 이미 그 채팅이라 제목이 안 바뀔 수 있어 나와의 채팅을 거쳐 간다.
    /// 돌려주는 값: `sent:<창 제목>`, `unsure:<말>`, `open:<말>`(채팅을 못 엶), `fail:<말>`.
    /// 붙여 넣은 뒤 실패하면 편집기를 거쳐 입력 칸을 비운다 (남기면 다음에 ‘쓰다 만 글’로 막히는데 숨은 창이라 지울 길이 없다).
    /// 보내기 확인이 안 된 채 남은 글은 팀즈가 초안으로 다시 띄우므로, 우리가 붙인 보고서(첫 줄로 알아본다)면 지우고 보낸다.
    private static let script = """
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const editor = () => document.querySelector('[data-tid="ckeditor"]');
    const clean = t => t.replace(/^\\(\\d+\\)\\s*/, '');
    const name = t => { const p = clean(t).split(' | '); return p.length >= 3 ? p[1].trim() : null; };
    const isNotes = t => t.includes('(나)') || t.includes('(You)');
    const isTarget = t => notes ? isNotes(t) : (!expect || name(t) === expect);
    // CKEditor·팀즈가 빈 칸에 남기는 보이지 않는 글자(zero-width, word joiner)는 \\s에 걸리지 않는다
    const flat = t => t.replace(/[\\u200B-\\u200D\\u2060\\uFEFF]/g, '').replace(/\\s+/g, ' ').trim();
    const go = id => { location.hash = '#/l/chat/' + id + '/conversations'; };
    async function settle(test) {
      let steady = 0, last = '';
      for (let i = 0; i < 100; i++) {
        await sleep(100);
        const t = document.title;
        steady = t === last ? steady + 1 : 0;
        last = t;
        if (editor() && name(t) && test(t) && steady >= 2) return true;
      }
      return false;
    }
    const opened = '열려던 채팅이 아닌 곳이 떠 있어 보내지 않았습니다';
    if (notes) {
      if (!isNotes(document.title)) go(conversation);
      if (!await settle(isNotes)) return 'open:' + opened;
    } else if (!already) {
      if (!isNotes(document.title)) { go('48:notes'); if (!await settle(isNotes)) return 'open:채팅을 열지 못했습니다'; }
      const before = name(document.title);
      go(conversation);
      if (!await settle(t => name(t) !== before && isTarget(t))) return 'open:' + opened;
    } else if (!await settle(isTarget)) {
      return 'open:' + opened;
    }
    const box = editor();
    const empty = () => flat(box.innerText) === '';
    // CKEditor는 합성 이벤트의 선택 범위를 보지 않아 커서를 끝에 두고 한 글자씩 지운다
    const clear = async () => {
      box.focus();
      const range = document.createRange();
      range.selectNodeContents(box);
      range.collapse(false);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      await sleep(50);
      for (let i = 0; i < 6000 && !empty(); i++) {
        box.dispatchEvent(new InputEvent('beforeinput', { inputType: 'deleteContentBackward', bubbles: true, cancelable: true }));
        if (i % 50 === 49) await sleep(0);
      }
    };
    // 채팅을 바꾼 직후에는 앞 채팅의 초안이 잠깐 남아 있다가 바뀌어서, 입력 칸 글이 멈출 때까지 본다
    for (let i = 0, steady = 0, last = null; i < 20 && steady < 3; i++) {
      await sleep(100);
      const t = flat(box.innerText);
      steady = t === last ? steady + 1 : 0;
      last = t;
    }
    if (!empty()) {
      const left = flat(box.innerText);
      const ours = [first, previous].map(flat).some(w => w && left.includes(w));
      if (!ours) return 'fail:그 채팅 입력 칸에 쓰다 만 글이 있어 보내지 않았습니다';
      await clear();
      if (!empty()) return 'fail:입력 칸에 남은 지난 보고서를 지우지 못했습니다';
    }
    box.focus();
    const data = new DataTransfer();
    data.setData('text/html', html);
    data.setData('text/plain', plain);
    box.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    const want = flat(first);
    for (let i = 0; i < 20 && !flat(box.innerText).includes(want); i++) await sleep(100);
    if (!flat(box.innerText).includes(want)) { await clear(); return 'fail:입력 칸에 붙지 않았습니다'; }
    const button = document.querySelector('[data-tid="newMessageCommands-send"], [data-tid="sendMessageCommands-send"]');
    if (!button) { await clear(); return 'fail:보내기 단추를 찾지 못했습니다'; }
    button.click();
    for (let i = 0; i < 50; i++) { await sleep(100); if (empty()) return 'sent:' + document.title; }
    return 'unsure:보내기를 눌렀지만 확인하지 못했습니다. 다시 보내기 전에 팀즈에서 올라갔는지 보세요';
    """
}
