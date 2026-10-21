import Foundation

/// 앱이 레드마인에 보낸 한 건. 잘못 보냈을 때 되돌릴 수 있게, 보내기 전 값과 바꾼 값을 함께 적어 둔다.
public struct RedmineSent: Codable, Equatable, Identifiable {
    /// 일감 칸 값. nil은 비어 있음(날짜) 또는 바꾸지 않음(after 쪽).
    public struct Snapshot: Codable, Equatable {
        public var doneRatio: Int?
        public var statusID: Int?
        public var statusName: String?
        public var startDate: String?
        public var dueDate: String?
        public var assignee: RedmineAPI.Member?

        public init(doneRatio: Int? = nil, statusID: Int? = nil, statusName: String? = nil,
                    startDate: String? = nil, dueDate: String? = nil, assignee: RedmineAPI.Member? = nil) {
            self.assignee = assignee
            self.doneRatio = doneRatio
            self.statusID = statusID
            self.statusName = statusName
            self.startDate = startDate
            self.dueDate = dueDate
        }
    }

    public var id: UUID
    public var issue: Int
    public var sentAt: Date
    public var entryIDs: [UUID]
    /// 보낸 댓글 (레드마인에 실린 그대로, HTML일 수 있다). 비어 있으면 작업 시간만 남긴 건.
    public var note: String
    public var before: Snapshot
    public var after: Snapshot
    public var timeEntryIDs: [Int]
    public var undoneAt: Date?

    public init(id: UUID = UUID(), issue: Int, sentAt: Date = Date(), entryIDs: [UUID], note: String,
                before: Snapshot, after: Snapshot, timeEntryIDs: [Int] = [], undoneAt: Date? = nil) {
        self.id = id
        self.issue = issue
        self.sentAt = sentAt
        self.entryIDs = entryIDs
        self.note = note
        self.before = before
        self.after = after
        self.timeEntryIDs = timeEntryIDs
        self.undoneAt = undoneAt
    }

    /// 되돌릴 때 고칠 칸. 보낸 뒤 다른 사람이 바꾼 칸은 그 값을 두고, 앱이 바꾼 그대로인 칸만 옛 값으로 돌린다.
    /// 날짜를 비워야 하면 빈 글자로 둔다 (레드마인은 빈 값으로 칸을 지운다).
    public func revert(current: Snapshot) -> (doneRatio: Int?, statusID: Int?, startDate: String?, dueDate: String?, assigneeID: Int?) {
        var result: (doneRatio: Int?, statusID: Int?, startDate: String?, dueDate: String?, assigneeID: Int?) = (nil, nil, nil, nil, nil)
        if let sent = after.doneRatio, current.doneRatio == sent, let old = before.doneRatio, old != sent { result.doneRatio = old }
        if let sent = after.statusID, current.statusID == sent, let old = before.statusID, old != sent { result.statusID = old }
        // 비운 날짜는 레드마인이 null로 돌려주니 빈 글자와 같게 본다
        if let sent = after.startDate, (current.startDate ?? "") == sent, (before.startDate ?? "") != sent {
            result.startDate = before.startDate ?? ""
        }
        if let sent = after.dueDate, (current.dueDate ?? "") == sent, (before.dueDate ?? "") != sent {
            result.dueDate = before.dueDate ?? ""
        }
        // 담당자를 비우는 되돌리기는 하지 않는다 (배정이 없던 일감은 드물고, 빈 담당은 누구의 목록에도 안 보인다)
        if let sent = after.assignee, current.assignee?.id == sent.id, let old = before.assignee, old.id != sent.id {
            result.assigneeID = old.id
        }
        return result
    }

    /// 보낸 댓글로 보이는 기록을 고른다: 보낸 뒤에 생겼고 글이 같은 것 가운데 가장 이른 것.
    public func matchJournal(_ journals: [RedmineAPI.Journal]) -> RedmineAPI.Journal? {
        let target = RedmineNote.plain(note)
        guard !target.isEmpty else { return nil }
        return journals
            .filter { $0.createdOn >= sentAt.addingTimeInterval(-120) && RedmineNote.plain($0.notes) == target }
            .min { $0.createdOn < $1.createdOn }
    }
}
