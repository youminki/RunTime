import AppKit
import DesignSyncCore
import SwiftUI

/// 날짜 비교 칸: 범위(프로젝트·메뉴)와 기간을 고르면 그 사이 바뀐 화면을 화면별로 묶어 보인다.
/// 결과는 기록에서 바로 보거나, 피그마 버전 두 개를 받아 정확히 견준다. 한 번에 Claude 문구로 넘길 수 있다.
struct DesignCompareView: View {
    @ObservedObject var sync: DesignSync
    @ObservedObject var page: DesignHistoryPage
    @ObservedObject var model: DesignCompareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .padding(.horizontal, WL.gutter)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Rectangle().fill(WL.border).frame(height: 1)
            SlimScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { results }
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            let visible = sync.settings.sources.filter { !$0.isHidden }.map(\.fileKey)
            if !visible.contains(model.fileKey ?? ""), let first = visible.first { model.open(fileKey: first, path: nil) }
        }
        .onChange(of: model.source) { source in
            // 피그마 버전을 고르면 바로 견준다. 같은 조건의 결과가 있으면 다시 받지 않는다
            if source == .figma && model.currentResult == nil && !model.running { run() }
        }
    }

    // MARK: 고르기

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("날짜 비교").font(WL.title)
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { model.fileKey ?? "" }, set: { model.open(fileKey: $0, path: nil) })) {
                    ForEach(sync.settings.sources.filter { !$0.isHidden }) { source in
                        Text(sync.projectName(source.fileKey)).tag(source.fileKey)
                    }
                }
                .labelsHidden().frame(maxWidth: 120)
                Picker("", selection: Binding(get: { model.path ?? "" }, set: { model.open(fileKey: model.fileKey ?? "", path: $0.isEmpty ? nil : $0) })) {
                    Text("전체 메뉴").tag("")
                    ForEach(paths, id: \.self) { path in Text(DesignFormat.path(path)).tag(path) }
                }
                .labelsHidden()
                .disabled(model.screen != nil)
            }
            if let screen = model.screen { screenChip(screen) }
            // 기간은 자주 쓰는 길이를 한 번에 고르고, 직접 고를 때만 날짜 칸을 연다
            Picker("", selection: $model.preset) {
                ForEach(DesignCompareModel.presets, id: \.days) { Text($0.title).tag($0.days) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .tip("오늘까지 며칠 동안 바뀐 것을 볼지 고릅니다")
            if model.preset == 0 {
                HStack(spacing: 6) {
                    DatePicker("", selection: $model.from, in: ...Date(), displayedComponents: .date).labelsHidden()
                    Image(systemName: "arrow.right").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WL.muted)
                    DatePicker("", selection: $model.to, in: ...Date(), displayedComponents: .date).labelsHidden()
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $model.source) {
                    Text("기록").tag(DesignCompareModel.Source.record)
                    Text("피그마 버전").tag(DesignCompareModel.Source.figma)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .tip("기록: 가져올 때 남긴 변경을 요청 없이 바로 봅니다 (가져오지 않은 기간은 비어 있음)\n피그마 버전: 두 날짜의 피그마 버전을 받아 정확히 견줍니다 (file_versions:read 필요)")
                Spacer(minLength: 0)
                if model.source == .figma {
                    if model.running {
                        ProgressView().controlSize(.small)
                    } else if model.currentResult == nil {
                        Button { run() } label: { Label("비교", systemImage: "arrow.left.arrow.right") }
                            .buttonStyle(NotionButtonStyle(kind: .primary))
                            .disabled((model.fileKey ?? "").isEmpty || !sync.settings.hasToken)
                    }
                }
            }
            if model.running, !model.progress.isEmpty {
                Text(model.progress).font(WL.caption).foregroundStyle(WL.muted).lineLimit(1)
            }
            if model.source == .figma && !sync.settings.hasToken {
                Button("피그마 버전 비교는 토큰이 있어야 합니다 (file_versions:read 범위)") { page.openSettings(.figma) }
                    .buttonStyle(TextLinkButtonStyle()).font(WL.caption)
            } else if model.source == .figma && model.resultIsStale {
                Text("조건을 바꿨습니다. ‘비교’를 누르면 새 조건으로 견줍니다.").font(WL.caption).foregroundStyle(WL.muted)
            }
            if model.source == .figma, let error = model.error {
                Text(error).font(WL.caption).foregroundStyle(WL.waiting).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func screenChip(_ screen: DesignCompareModel.Target) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 11.5)).foregroundStyle(WL.accent)
            Text(screen.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            Text(screen.screenID).font(WL.number).foregroundStyle(WL.muted).lineLimit(1)
            Spacer(minLength: 4)
            Button { model.open(fileKey: model.fileKey ?? "", path: model.path) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(WL.muted)
            }
            .buttonStyle(.plain)
            .tip("화면 하나만 보기를 풀고 메뉴 전체를 견줍니다")
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.selected.opacity(0.7)))
    }

    private func run() {
        // 다시 견주면 결과의 변경이 새로 만들어져, 고른 결과는 풀어 빈 상세가 남지 않게 한다
        if let id = page.selected, !sync.history.events.contains(where: { $0.id == id }) { page.selected = nil }
        model.run()
    }

    /// 메뉴와 그 위 묶음 경로 (`대응`, `대응 > 조치 티켓`).
    private var paths: [String] {
        guard let key = model.fileKey, let screens = sync.history.files[key]?.screens.values else { return [] }
        var all = Set<String>()
        for screen in screens {
            let parts = screen.menuPath.components(separatedBy: " > ")
            for index in parts.indices { all.insert(parts[...index].joined(separator: " > ")) }
        }
        return all.sorted()
    }

    // MARK: 결과

    /// 지금 고른 기준의 변경. 피그마 버전은 결과가 있을 때만.
    private var events: [DesignEvent]? {
        model.source == .figma && model.currentResult == nil ? nil : model.shownEvents
    }

    /// 범위 이름. Claude 문구 제목과 빈 결과 문구에 쓴다.
    private var scopeTitle: String {
        if let screen = model.screen { return screen.title }
        return model.path ?? model.fileKey.map(sync.projectName) ?? ""
    }

    @ViewBuilder private var results: some View {
        if let events {
            let screens = Self.groups(events.filter { $0.kind != .changelog })
            let notes = events.filter { $0.kind == .changelog }
            summary(screens: screens.count, changes: events.count)
            if screens.count > 20 && model.path == nil && model.screen == nil {
                Text("범위가 넓습니다. 위에서 메뉴를 고르면 문구가 짧아지고 Claude가 한 번에 다루기 좋습니다.")
                    .font(WL.caption).foregroundStyle(WL.waiting)
                    .padding(.horizontal, WL.gutter).padding(.bottom, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.source == .figma, let result = model.currentResult { versionNote(result) }
            if screens.isEmpty && notes.isEmpty {
                Text(model.source == .record
                     ? "이 기간에 기록한 변경이 없습니다. 가져오지 않은 기간은 ‘피그마 버전’으로 봅니다."
                     : "고른 범위의 화면은 바뀌지 않았습니다.")
                    .font(WL.meta).foregroundStyle(WL.muted)
                    .padding(.horizontal, WL.gutter).padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let frameNotes = duplicateNotes(screens)
            ForEach(screens, id: \.id) { group in screenRow(group, note: frameNotes[group.latest.frameID ?? ""]) }
            if !notes.isEmpty {
                header("디자이너가 적은 이력", count: notes.count)
                ForEach(notes) { event in
                    DesignEventRow(event: event, seen: true, selected: page.selected == event.id) { page.selected = event.id }
                }
            }
        }
    }

    /// 몇 화면이 바뀌었는지와, 그 변경을 한 번에 Claude에 넘기는 단추.
    private func summary(screens: Int, changes: Int) -> some View {
        HStack(spacing: 8) {
            Text(screens == 0 ? "바뀐 화면 없음" : "화면 \(screens)개 · 변경 \(changes)건")
                .font(WL.heading).lineLimit(1)
            Spacer(minLength: 4)
            if screens > 0, let events {
                Button {
                    NSPasteboard.general.clearContents()
                    let prompt = sync.claudePrompt(events: events, title: scopeTitle)
                    NSPasteboard.general.setString(prompt, forType: .string)
                    page.flash(DesignFormat.copied(prompt))
                } label: { Label("Claude 문구", systemImage: "sparkles") }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .tip("이 기간의 변경을 화면별로 묶어 복사합니다. 같은 항목을 여러 번 고친 것은 처음→마지막 한 줄로 합치고, 반영 체크한 항목은 뺍니다")
            }
        }
        .padding(.horizontal, WL.gutter).padding(.top, 14).padding(.bottom, 6)
    }

    private func versionNote(_ result: DesignCompareModel.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let checked = result.checkedAt ?? result.to.createdAt
            Text("\(DesignFormat.stamp(result.from.createdAt)) 버전 → "
                 + (result.toIsRecord ? "지금 상태 (\(DesignFormat.stamp(checked)) 확인)" : "\(DesignFormat.stamp(result.to.createdAt)) 버전"))
                .font(WL.meta).foregroundStyle(WL.muted)
                .tip("오늘과 견줄 때는 피그마에 다시 묻지 않고 마지막으로 가져온 상태를 씁니다. 파일을 마지막으로 고친 때는 \(DesignFormat.stamp(result.to.createdAt))입니다")
            if result.toIsRecord, Date().timeIntervalSince(checked) > DesignCompareModel.staleRecord {
                HStack(spacing: 6) {
                    Label("가져온 지 \(DesignCompareModel.age(checked)) 지났습니다", systemImage: "exclamationmark.circle")
                        .font(WL.caption).foregroundStyle(WL.waiting)
                    Button("최신으로 가져와 다시 비교") {
                        if let id = page.selected, !sync.history.events.contains(where: { $0.id == id }) { page.selected = nil }
                        model.refreshAndRun()
                    }
                    .buttonStyle(TextLinkButtonStyle()).font(WL.caption)
                }
            }
            ForEach(result.named, id: \.id) { version in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(version.label ?? "").font(WL.number).foregroundStyle(WL.accent).fixedSize()
                    Text(DesignText.headline(version.description ?? "", limit: 80)).font(WL.meta).foregroundStyle(WL.muted)
                        .lineLimit(2).tip(version.description ?? "")
                }
            }
        }
        .padding(.horizontal, WL.gutter).padding(.bottom, 6)
    }

    /// 화면 하나에 그 기간 쌓인 변경. 최근 것이 대표다.
    struct ScreenGroup {
        var id: String
        var events: [DesignEvent]
        var latest: DesignEvent { events.max { $0.detectedAt < $1.detectedAt }! }
    }

    /// 화면(프레임)마다 묶고, 최근에 바뀐 화면이 위.
    static func groups(_ events: [DesignEvent]) -> [ScreenGroup] {
        Dictionary(grouping: events) { $0.frameID ?? $0.screenID }
            .map { ScreenGroup(id: $0.key, events: $0.value) }
            .sorted { $0.latest.detectedAt > $1.latest.detectedAt }
    }

    /// 화면 한 줄: 이름, 화면 ID와 경로, 그 기간에 합친 바뀐 항목 수. 누르면 최근 변경을 연다.
    /// 같은 화면 ID를 쓰는 프레임(상태별 화면)을 가를 이름. 화면 목록과 같은 규칙으로, 지금 시안의 같은 ID 프레임 전부에서 센다.
    private func duplicateNotes(_ groups: [ScreenGroup]) -> [String: String] {
        guard let key = model.fileKey else { return [:] }
        let ids = Set(groups.map(\.latest.screenID))
        return DesignTimeline.duplicateNotes(sync.screens(key).filter { ids.contains($0.screenID) })
    }

    private func screenRow(_ group: ScreenGroup, note: String?) -> some View {
        let latest = group.latest
        let merged = ClaudePrompt.merged(group.events.sorted { $0.detectedAt < $1.detectedAt }.flatMap(\.changes).filter { $0.op != .renumbered })
        let counts = DesignHistoryView.layerOrder.compactMap { layer -> String? in
            let n = merged.filter { $0.layer == layer }.count
            return n > 0 ? "\(DesignHistoryView.layerName(layer)) \(n)" : nil
        }
        let selected = group.events.contains { $0.id == page.selected }
        let kind = latest.kind == .added ? "새 화면" : latest.kind == .removed ? "화면 삭제" : nil
        return Button { page.selected = latest.id; if sync.history.events.contains(where: { $0.id == latest.id }) { sync.markSeen([latest.id]) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(DesignFormat.title(latest)).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if group.events.count > 1 {
                        Text("\(group.events.count)번 바뀜").font(WL.label).foregroundStyle(WL.muted).fixedSize()
                    }
                }
                Text(([note].compactMap { $0 } + [DesignFormat.subtitle(latest)]).joined(separator: " · "))
                    .font(WL.meta).foregroundStyle(WL.muted).lineLimit(1)
                HStack(spacing: 6) {
                    DesignPhaseBadge(phase: latest.phase)
                    Text(([kind].compactMap { $0 } + (counts.isEmpty && kind == nil ? ["바뀐 항목 없음 (되돌림)"] : counts)).joined(separator: " · "))
                        .font(WL.meta).foregroundStyle(WL.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, WL.gutter - 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WL.inner, style: .continuous).fill(selected ? WL.selected : .clear))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip("\(DesignFormat.path(latest.menuPath))\n누르면 이 화면의 최근 변경을 엽니다")
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(WL.label).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)건").font(WL.label).foregroundStyle(WL.muted)
        }
        .padding(.horizontal, WL.gutter)
        .padding(.top, 14).padding(.bottom, 6)
    }
}
