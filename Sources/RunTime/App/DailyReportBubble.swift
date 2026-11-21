import AppKit
import WorkLogCore

/// 펫 메뉴에서 고르면 진행 예정·진행 사항을 펫 위 말풍선으로 띄운다.
/// 일지 창을 열지 않고 말풍선에서 바로 복사하거나 팀즈로 보낸다.
enum DailyReportBubble {
    enum Kind: String, CaseIterable {
        case plan, progress

        var name: String { self == .plan ? "진행 예정" : "진행 사항" }
    }

    /// 일지에서 만든 글 (고쳐 쓰기 전). 일지 창의 보고서와 같은 글을 만든다.
    static func generated(_ kind: Kind, day: String) -> String {
        let store = WorkLogStore.shared, sync = WorkLogSync.shared
        switch kind {
        case .plan:
            return WorkReport.plan(day: day, in: store.log, closed: sync.closedStatusIDs)
        case .progress:
            let entries = store.log.entries(on: day)
            var pending: [Int: Int] = [:]
            for update in WorkReport.redmineUpdates(entries.filter(\.needsRedmine), log: store.log) where update.needsNote {
                if let ratio = sync.prepared(update, edit: nil).doneRatio { pending[update.issue] = ratio }
            }
            let ratios = WorkReport.reportRatios(entries, in: store.log, pending: pending)
            return WorkReport.daily(entries, in: store.log, doneFirst: true, byIssue: true,
                                    compact: WorkLogSettings.shared.reportCompact, ratios: ratios)
        }
    }

    /// 그날 올릴 머리줄과 몸통. 일지 창이나 말풍선에서 고쳐 쓴 글이 있으면 그 글.
    static func report(_ kind: Kind, day: String = WorkDay.today()) -> (title: String, body: String)? {
        let page = WorkLogPage.shared, made = generated(kind, day: day)
        let body = (kind == .plan ? page.savedPlan(for: day) : page.savedProgress(for: day, generated: made)) ?? made
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (WorkReport.dayHeader(day, plan: kind == .plan), trimmed)
    }

    /// 말풍선에서 고쳐 쓴 글을 일지 창과 같은 자리에 남기고, 말풍선에 보일 새 글을 돌려준다.
    private static func save(_ text: String, kind: Kind, day: String) -> String? {
        let page = WorkLogPage.shared, made = generated(kind, day: day)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .plan { page.editPlan(body, day: day, generated: made) } else { page.editProgress(body, day: day, generated: made) }
        return report(kind, day: day).map { $0.title + "\n" + $0.body }
    }

    /// 사람이 고른 때. 올릴 글이 없으면 왜 없는지 말풍선으로 알린다.
    static func showOrExplain(_ kind: Kind) {
        guard !show(kind) else { return }
        MenuBarNews.post(.init(title: "오늘 \(kind.name)", items: ["아직 올릴 글이 없습니다. 업무 일지에 오늘 한 일을 적어 주세요."],
                               actionTitle: "업무 일지 열기", action: { MenuBarNews.open(.workLog) }, keeps: false))
    }

    /// 말풍선을 띄운다. 올릴 글이 없으면 띄우지 않고 false.
    @discardableResult
    static func show(_ kind: Kind) -> Bool {
        let day = WorkDay.today()
        guard let report = report(kind, day: day) else { return false }
        let settings = WorkLogSettings.shared
        let target = settings.reportTarget
        // 말풍선에서 고쳐 쓸 수 있어, 복사·보내기는 누를 때의 글을 쓴다
        let copy = MenuBarBubble.Choice(title: "복사", icon: "doc.on.doc") { finish in
            guard let now = Self.report(kind, day: day) else { return finish("올릴 글이 없습니다", false) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(now.title + "\n" + now.body, forType: .string)
            finish("\(kind.name)를 복사했습니다", false)
        }
        // 보고 채팅은 여러 사람이 보는 곳이라 한 번 더 눌러야 올린다. 나에게는 바로 보낸다
        let send = MenuBarBubble.Choice(title: target == .chat ? "보고 채팅에 올리기" : "팀즈 나에게 보내기", icon: "paperplane.fill",
                                        primary: true, confirm: target == .chat ? "한 번 더 누르면 보고 채팅에 올립니다" : nil) { finish in
            guard let now = Self.report(kind, day: day) else { return finish("올릴 글이 없습니다", false) }
            WorkLogSync.shared.postTeams(now.body, title: now.title, to: target) { message, failed in
                if target == .chat, !failed, message.hasSuffix("보냈습니다") {
                    UserDefaults.standard.set(now.body, forKey: "workLog.teamsLastPost")
                }
                // 올라간 것을 확인하지 못한 결과는 닫지 않고 남겨 다시 보내거나 복사할 수 있게 한다
                finish(message, !failed && message.hasSuffix("보냈습니다"))
            }
        }
        MenuBarNews.post(.init(title: kind == .plan ? "오늘 진행 예정 사항" : "오늘 진행 사항", items: [],
                               actionTitle: "업무 일지 열기", action: { MenuBarNews.open(.workLog) },
                               keeps: false, report: report.title + "\n" + report.body, buttons: [copy, send],
                               editing: .init(header: report.title,
                                              body: { Self.report(kind, day: day)?.body ?? "" },
                                              save: { Self.save($0, kind: kind, day: day) })))
        return true
    }
}
