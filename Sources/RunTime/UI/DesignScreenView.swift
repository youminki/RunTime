import AppKit
import DesignSyncCore
import SwiftUI

/// 메뉴 아래 지금 시안 화면 한 줄. 바뀐 적이 없어도 눌러서 명세·이미지를 본다.
struct DesignScreenRow: View {
    let screen: ScreenSnapshot
    let state: ScreenState
    /// 같은 화면 ID의 다른 프레임과 가를 이름.
    var note: String?
    let changes: Int
    let selected: Bool
    let select: () -> Void
    @StateObject private var hover = HoveredKey()

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                DesignStateDot(state: state).padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(screen.title.isEmpty ? screen.screenID : screen.title)
                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        if changes > 0 {
                            Text("변경 \(changes)").font(WL.label).foregroundStyle(WL.accent).fixedSize()
                        }
                    }
                    HStack(spacing: 6) {
                        Text(screen.screenID).font(WL.number).foregroundStyle(WL.muted).lineLimit(1)
                        if let note, !note.isEmpty {
                            Text(note).font(WL.meta).foregroundStyle(WL.muted).lineLimit(1)
                        }
                        Text("명세 \(screen.items.count)").font(WL.meta).foregroundStyle(WL.faint).fixedSize()
                        Spacer(minLength: 0)
                    }
                    .tip(DesignFormat.path(screen.menuPath))
                }
            }
            .padding(.horizontal, WL.gutter - 8)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous)
                .fill(selected ? WL.selected : hover.key == "row" ? WL.hover : .clear))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update("row", $0) }
    }
}

/// 자주 쓰지 않는 동작을 모은 ⋯ 단추. 보조 단추와 같은 테두리로 그린다.
struct MoreMenu<Content: View>: View {
    let tip: String
    let content: Content

    init(tip: String, @ViewBuilder content: () -> Content) {
        self.tip = tip
        self.content = content()
    }

    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(WL.text)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
        .contentShape(Rectangle())
        .tip(tip)
    }
}

struct DesignStateDot: View {
    let state: ScreenState

    var body: some View {
        Circle()
            .fill(state == .done ? WL.done : state == .working ? WL.waiting : Color.secondary.opacity(0.35))
            .frame(width: 7, height: 7)
            .tip(DesignStateDot.name(state))
    }

    static func name(_ state: ScreenState) -> String {
        state == .done ? "완료" : state == .working ? "작업 중" : "상태 모름"
    }
}

/// 지금 시안 화면 하나: 이미지, 기능 명세, 참고, 이 화면의 변경, 목업 문구. 프론트 작업을 이 칸 하나로 하게 한다.
struct DesignScreenDetail: View {
    let fileKey: String
    let screen: ScreenSnapshot
    @ObservedObject var sync: DesignSync
    @ObservedObject var page: DesignHistoryPage
    @ObservedObject private var images = DesignImages.shared

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1040
            SlimScrollView {
                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 22) { header; actionRow(compact: geo.size.width * 0.52 < 560); shot(maxHeight: 1400) }
                            .frame(width: (geo.size.width * 0.52).rounded(), alignment: .leading)
                        VStack(alignment: .leading, spacing: 22) { content }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 24)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        header; actionRow(compact: min(geo.size.width - 64, 760) < 560); shot(maxHeight: 640); content
                    }
                    .padding(.horizontal, 32).padding(.vertical, 26)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var state: ScreenState { sync.state(of: screen, in: fileKey) }
    private var link: URL? { FigmaFileURL.link(fileKey: fileKey, nodeID: screen.frameID) }
    private var history: [DesignEvent] { sync.events(for: screen, in: fileKey) }
    private var version: String? { sync.history.files[fileKey]?.version }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(DesignStateDot.name(state)).font(WL.label)
                    .foregroundStyle(state == .done ? WL.done : state == .working ? WL.waiting : WL.muted)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill((state == .done ? WL.done : state == .working ? WL.waiting : WL.muted).opacity(0.12)))
                Text(screen.screenID).font(WL.number).foregroundStyle(WL.muted).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("목록으로") { page.screen = nil }.buttonStyle(TextLinkButtonStyle())
            }
            Text(screen.title.isEmpty ? screen.screenID : screen.title).font(WL.pageTitle).textSelection(.enabled)
            Text(DesignFormat.path(screen.menuPath)).font(WL.body).foregroundStyle(WL.muted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            let meta = [screen.requirementID.isEmpty ? nil : "요구사항 " + screen.requirementID,
                        screen.author.isEmpty ? nil : "작성 " + screen.author,
                        SpecExtractor.stripNote(screen.pageName)].compactMap { $0 }
            HStack(spacing: 5) {
                ProjectSwatch(name: sync.projectName(fileKey), size: 7)
                Text(([sync.projectName(fileKey)] + meta).joined(separator: " · ")).lineLimit(2)
            }
            .font(WL.meta).foregroundStyle(WL.faint).textSelection(.enabled)
        }
    }

    /// 마크업을 시작하는 단추가 맨 앞이다. 덜 쓰는 것은 ⋯에 모은다.
    private func actionRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            let pending = sync.pendingEvents(for: screen, in: fileKey).count
            Button(action: copyPrompt) {
                Label(pending > 0 ? "변경 \(pending)건 Claude 문구 복사" : "Claude 문구 복사", systemImage: "sparkles")
            }
            .buttonStyle(NotionButtonStyle(kind: .primary))
            .tip(pending > 0
                 ? "반영하지 않은 변경 \(pending)건을 전·후 원문으로 정리해, 이 화면 마크업에 반영해 달라는 글을 복사합니다. 체크한 항목은 뺍니다"
                 : "이 화면을 마크업해 달라는 글을 복사합니다. 구현 체크한 기능 명세는 빼고 남은 것만 넣습니다")
            if let link {
                Button { NSWorkspace.shared.open(link) } label: {
                    if compact { FigmaMark(height: 14) } else { HStack(spacing: 7) { FigmaMark(height: 14); Text("피그마에서 열기") } }
                }
                .buttonStyle(NotionButtonStyle())
                .tip("피그마에서 이 화면 프레임 열기")
            }
            MoreMenu(tip: "이미지·링크 복사, 날짜별 비교, 업무 일지에 넣기") {
                Button("화면 이미지 복사") { copyImage() }.disabled(readyImage == nil)
                Button("화면 명세 복사 (MR·레드마인용)") { copyBrief() }
                if let link {
                    Button("피그마 링크 복사") { copy(link.absoluteString, "피그마 링크를 복사했습니다") }
                }
                Button("화면 ID 복사") { copy(screen.screenID, "‘\(screen.screenID)’를 복사했습니다") }
                Divider()
                Button("이 화면 날짜별 비교…") { DesignScreenDetail.compareDates(fileKey: fileKey, screen: screen, page: page) }
                Button("업무 일지 오늘 칸에 넣기") {
                    page.flash(sync.addToWorkLog(screen, in: fileKey) ? "업무 일지 오늘 칸에 넣었습니다" : "업무 일지에 넣지 못했습니다")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var built: Set<String> { sync.history.built(screen, in: fileKey) }

    private func copyPrompt() {
        copy(sync.claudePrompt(for: screen, in: fileKey), "Claude에 붙일 문구를 복사했습니다")
    }

    private func copyBrief() {
        let text = ScreenBrief.text(screen, project: sync.projectName(fileKey), state: DesignStateDot.name(state), link: link,
                                    recent: history.filter { $0.kind != .changelog }, built: built)
        copy(text, "화면 명세를 복사했습니다")
    }

    private func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        page.flash(message)
    }

    /// 받아 둔 화면 이미지. 아직 그리는 중이면 nil.
    private var readyImage: NSImage? {
        guard let version, case .ready(let url) = images.state(fileKey: fileKey, nodeID: screen.frameID, version: version) else { return nil }
        return images.image(url)
    }

    /// Claude나 MR, 메신저에 바로 붙이게 화면 이미지를 복사한다.
    private func copyImage() {
        guard let image = readyImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        page.flash("화면 이미지를 복사했습니다")
    }

    /// 날짜 비교를 이 화면 하나로 열고, 처음이면 최근 3일을 고른다.
    static func compareDates(fileKey: String, screen: ScreenSnapshot, page: DesignHistoryPage) {
        DesignCompareModel.shared.open(fileKey: fileKey, path: screen.menuPath, screen: DesignCompareModel.Target(screen))
        page.scope = .compare
        page.selected = nil
    }

    /// 지금 버전 그대로 그린 화면. 같은 메뉴의 다른 화면도 함께 받아 다음 화면은 바로 열린다.
    @ViewBuilder private func shot(maxHeight: CGFloat) -> some View {
        if let version {
            let state = images.state(fileKey: fileKey, nodeID: screen.frameID, version: version)
            Group {
                if case .ready(let url) = state, let image = images.image(url) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: WL.inner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).strokeBorder(WL.border, lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .top)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .tip("두 번 누르면 크게 엽니다")
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(WL.callout)
                        if case .missing(let reason) = state {
                            Text(reason).font(WL.caption).foregroundStyle(WL.waiting).multilineTextAlignment(.center).padding(10)
                        } else {
                            VStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("피그마에서 그리는 중…").font(WL.caption).foregroundStyle(WL.faint)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 220)
                }
            }
            .onAppear { images.load(fileKey: fileKey, nodeIDs: neighbours, version: version) }
        }
    }

    /// 이 화면과 같은 메뉴의 화면들. 화면 목록에서 이어서 누를 것들이다.
    private var neighbours: [String] {
        let siblings = sync.screens(fileKey, under: screen.menuPath, exact: true).map(\.frameID)
        return [screen.frameID] + siblings.filter { $0 != screen.frameID }.prefix(DesignImages.batchSize - 1)
    }

    @ViewBuilder private var content: some View {
        if !screen.notes.isEmpty {
            section("참고", count: nil) {
                Text(screen.notes).font(WL.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
            }
        }
        if !screen.items.isEmpty {
            let built = built
            let done = screen.items.filter { built.contains($0.text) }.count
            section("기능 명세", trailing: done == 0 ? "\(screen.items.count)" : "구현 \(done)/\(screen.items.count)") {
                ForEach(Array(screen.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { RowDivider(inset: 26) }
                    // 마크업하며 구현한 항목을 체크한다. 작업용 복사에도 구현 여부가 붙는다
                    HStack(alignment: .top, spacing: 8) {
                        AppliedCheck(on: built.contains(item.text)) { sync.toggleBuilt(item, of: screen, in: fileKey) }
                            .padding(.top, 10)
                            .tip(built.contains(item.text) ? "구현 표시 풀기" : "구현했으면 체크")
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.number).font(WL.number).foregroundStyle(WL.accent).frame(minWidth: 22, alignment: .leading)
                            Text(item.text).font(WL.body).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 10)
                        .opacity(built.contains(item.text) ? 0.45 : 1)
                    }
                }
            }
        }
        if !history.isEmpty {
            section("이 화면의 변경", count: history.count) {
                ForEach(Array(history.prefix(20).enumerated()), id: \.element.id) { index, event in
                    if index > 0 { RowDivider(inset: 0) }
                    Button { page.selected = event.id; sync.markSeen([event.id]) } label: {
                        HStack(spacing: 8) {
                            Text(DesignFormat.stamp(event.detectedAt)).font(WL.number).foregroundStyle(WL.muted).fixedSize()
                            Text(event.kind == .changelog ? (event.note.map { DesignText.headline($0, limit: 60) } ?? "제·개정 이력") : event.summary)
                                .font(WL.body).lineLimit(1)
                            Spacer(minLength: 4)
                            if sync.history.isApplied(event) { Text("반영 완료").font(WL.label).foregroundStyle(WL.done) }
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(WL.faint)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        foldable("목업 문구", items: ScreenBrief.orderedTexts(screen), open: $page.showsScreenTexts)
        foldable("컴포넌트", items: ScreenBrief.components(screen).map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name },
                 open: $page.showsScreenComponents)
    }

    @ViewBuilder private func foldable(_ title: String, items: [String], open: Binding<Bool>) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { open.wrappedValue.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                        SectionLabel(title, trailing: "\(items.count)")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open.wrappedValue {
                    Text(items.joined(separator: "\n")).font(WL.body).lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .wlSurface()
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, count: Int?, @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: count.map { "\($0)" }, content: content)
    }

    private func section<Content: View>(_ title: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title, trailing: trailing)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wlSurface()
        }
    }
}
