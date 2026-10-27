import DesignSyncCore
import SwiftUI

/// 날짜 비교 칸: 프로젝트·메뉴와 두 날짜를 고르면 그 사이 쌓인 기록은 바로, 피그마 버전 비교는 누르면 보인다.
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
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    versionSection
                    recordedSection
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            let visible = sync.settings.sources.filter { !$0.isHidden }.map(\.fileKey)
            if !visible.contains(model.fileKey ?? ""), let first = visible.first { model.open(fileKey: first, path: nil) }
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
            if let screen = model.screen {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 10.5)).foregroundStyle(WL.accent)
                    Text(screen.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(screen.screenID).font(WL.number).foregroundStyle(WL.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.open(fileKey: model.fileKey ?? "", path: model.path) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .tip("화면 하나만 보기를 풀고 메뉴 전체를 견줍니다")
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WL.selected.opacity(0.7)))
                Text("이 화면의 변경과 이 화면을 적은 이력만 견줍니다. 피그마에서도 이 화면이 있는 페이지만 받습니다.")
                    .font(WL.caption).foregroundStyle(WL.faint).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                DatePicker("", selection: $model.from, in: ...Date(), displayedComponents: .date).labelsHidden()
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(WL.faint)
                DatePicker("", selection: $model.to, in: ...Date(), displayedComponents: .date).labelsHidden()
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                quick("어제→오늘", days: 1)
                quick("최근 3일", days: 3)
                quick("최근 7일", days: 7)
                Spacer(minLength: 0)
                Button { clearComparedSelection(); model.run() } label: {
                    if model.running { ProgressView().controlSize(.small) } else { Label("버전 비교", systemImage: "arrow.left.arrow.right") }
                }
                .buttonStyle(NotionButtonStyle(kind: .primary))
                .disabled(model.running || (model.fileKey ?? "").isEmpty || !sync.settings.hasToken)
                .tip("두 날짜 끝 무렵의 피그마 버전을 받아 견줍니다. 한 번 받은 버전은 저장해 두어 다시 보면 바로 나옵니다")
            }
            if model.running, !model.progress.isEmpty {
                Text(model.progress).font(WL.caption).foregroundStyle(WL.muted).lineLimit(1)
            }
            if !sync.settings.hasToken {
                Button("버전 비교를 하려면 피그마 토큰을 넣으세요 (file_versions:read 범위)") { page.openSettings(.figma) }
                    .buttonStyle(TextLinkButtonStyle()).font(WL.caption)
            } else if model.resultIsStale {
                Text("조건을 바꿨습니다. ‘버전 비교’를 다시 누르면 새 기간으로 견줍니다.").font(WL.caption).foregroundStyle(WL.muted)
            }
            if let error = model.error {
                Text(error).font(WL.caption).foregroundStyle(WL.waiting).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 다시 견주면 결과의 변경이 새로 만들어져, 고른 결과는 풀어 빈 상세가 남지 않게 한다.
    private func clearComparedSelection() {
        if let id = page.selected, !sync.history.events.contains(where: { $0.id == id }) { page.selected = nil }
    }

    private func quick(_ title: String, days: Int) -> some View {
        Button(title) {
            model.to = Date()
            model.from = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        }
        .buttonStyle(TextLinkButtonStyle())
        .font(WL.meta)
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

    @ViewBuilder private var versionSection: some View {
        if let result = model.currentResult {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(DesignFormat.stamp(result.from.createdAt)) 버전 → "
                         + (result.toIsRecord ? "마지막으로 가져온 상태 (\(DesignFormat.stamp(result.to.createdAt)))"
                            : "\(DesignFormat.stamp(result.to.createdAt)) 버전"))
                        .font(WL.meta).foregroundStyle(WL.muted)
                        .tip("오늘과 견줄 때는 피그마에 다시 묻지 않고 마지막으로 가져온 상태를 씁니다")
                    if result.toIsRecord, Date().timeIntervalSince(result.to.createdAt) > DesignCompareModel.staleRecord {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("마지막으로 가져온 지 \(DesignCompareModel.age(result.to.createdAt)) 지났습니다", systemImage: "exclamationmark.circle")
                                .font(WL.caption).foregroundStyle(WL.waiting)
                            Button("최신으로 가져와 다시 비교") { clearComparedSelection(); model.refreshAndRun() }
                                .buttonStyle(TextLinkButtonStyle()).font(WL.caption)
                        }
                    }
                    ForEach(result.named, id: \.id) { version in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(version.label ?? "").font(WL.number).foregroundStyle(WL.accent).fixedSize()
                            Text(DesignText.headline(version.description ?? "", limit: 80)).font(WL.meta).foregroundStyle(WL.text.opacity(0.8))
                                .lineLimit(2).tip(version.description ?? "")
                        }
                    }
                    if result.events.isEmpty {
                        Text(result.from.id == result.to.id ? "두 날짜 사이에 저장된 버전이 없습니다." : "고른 범위의 화면은 바뀌지 않았습니다.")
                            .font(WL.caption).foregroundStyle(WL.faint)
                    }
                }
                .padding(.horizontal, WL.gutter).padding(.bottom, 6)
                ForEach(result.events) { event in
                    DesignEventRow(event: event, seen: true, selected: page.selected == event.id) { page.selected = event.id }
                }
            } header: {
                header("피그마 버전 비교", count: result.events.count)
            }
        }
    }

    @ViewBuilder private var recordedSection: some View {
        let events = model.recorded()
        Section {
            if events.isEmpty {
                Text("이 기간에 기록한 변경이 없습니다. 지켜보기 전이나 가져오지 않은 기간은 ‘버전 비교’로 봅니다.")
                    .font(WL.caption).foregroundStyle(WL.faint)
                    .padding(.horizontal, WL.gutter).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(events) { event in
                DesignEventRow(event: event, seen: sync.history.isSeen(event), selected: page.selected == event.id,
                               progress: sync.history.progress(event)) {
                    page.selected = event.id
                    sync.markSeen([event.id])
                }
            }
        } header: {
            header("기록에 남은 변경", count: events.count)
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(WL.label).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)건").font(WL.label).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, WL.gutter)
        .padding(.top, 12).padding(.bottom, 6)
        .background(WL.canvas)
    }
}
