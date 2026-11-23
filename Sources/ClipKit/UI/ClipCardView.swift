import AppKit
import ImageIO
import SwiftUI

struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool

    @ViewState private var hovering = false
    @ViewState private var preview: NSImage? = nil
    @ViewState private var previewFailed = false
    @ViewState private var fileInfo: ClipPreviewProvider.FileInfo? = nil
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var settings = Settings.shared
    private var headerColor: Color { SourceColor.color(for: item.sourceBundleID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
        }
        .frame(width: Theme.cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .background {
            if selected {
                RoundedRectangle(
                    cornerRadius: Theme.cardCorner + Theme.selectedCardRing,
                    style: .continuous
                )
                .fill(Theme.selection)
                .padding(-Theme.selectedCardRing)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(selected ? Theme.selection : Theme.cardBorder,
                              lineWidth: selected ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .scaleEffect(hovering && !selected ? 1.015 : 1.0)
        .zIndex(selected ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: selected)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(ClipCardInteractions(
            select: { CardActions.shared.cardClicked { store.select(item.id) } },
            extendSelection: { CardActions.shared.cardClicked { store.extendSelection(to: item.id) } },
            toggleSelection: { CardActions.shared.cardClicked { store.toggleSelection(item.id) } },
            paste: { if !CardActions.shared.blocksPaste { AppController.shared.pasteItem(item) } }))
        .onDrag { ClipDragProvider.make(for: item) }
        .contextMenu { menu }
        .task(id: item.id) { await loadPreview() }
    }

    private var header: some View {
        ZStack {
            headerColor
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if Pinned.contains(item) {
                            Image(systemName: "pin.fill").font(.system(size: 11, weight: .bold))
                        }
                        Text(cardTypeLabel)
                    }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.headerText)
                    Text(item.createdAt.clipRelativeLong)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.headerSubText)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                appIconTile
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
        }
        .frame(height: Theme.headerHeight)
    }

    private var cardTypeLabel: String {
        if CardActions.looksSecret(item) { return "비밀번호" }
        if item.type == .file, item.fileURLs.count > 1 { return String(localized: "\(item.fileURLs.count) files") }
        return item.type.label
    }

    private var appIconTile: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.white.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14))
            )
            .frame(width: 56, height: 56)
            .overlay(
                Image(nsImage: AppIconProvider.icon(forBundleID: item.sourceBundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
            )
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, showsImage ? 0 : 13)
                .padding(.top, showsImage ? 0 : 11)
            footer
                .padding(.horizontal, 13)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cardBody)
        .overlay(alignment: .bottom) {
            if hovering {
                CardActionBar(item: item)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
    }

    /// Image clips, and file clips pointing at an image, which is how a copied
    /// screenshot usually arrives, run edge to edge instead of sitting inset.
    private var showsImage: Bool {
        ClipPreviewProvider.showsImage(item) && !previewFailed
    }

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .image:
            imageCanvas
        case .color:
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(hex: item.colorHex ?? "#000") ?? .black)
                Text(item.colorHex ?? "")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white).shadow(radius: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .file:
            if showsImage {
                imageCanvas
            } else {
                fileContent
            }
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.cardTextPrimary)
                    .lineLimit(2)
                Text(BarGuide.highlighted(metaLeft, query: store.searchText, size: 12))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.cardTextSecondary)
                    .lineLimit(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Text(BarGuide.cardText(item, query: store.searchText))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.cardTextPrimary.opacity(0.9))
                .lineLimit(10)
                .multilineTextAlignment(.leading)
        }
    }

    /// Over a checkerboard, so a transparent cut-out is distinguishable from
    /// an image on white.
    private var imageCanvas: some View {
        ZStack {
            CheckerboardBackground()
            if let image = preview ?? ClipPreviewProvider.cachedImage(for: item) {
                Image(nsImage: image)
                    .resizable().interpolation(.medium).scaledToFit()
            } else {
                placeholder("photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var fileContent: some View {
        VStack(spacing: 9) {
            if let icon = fileInfo?.icon ?? ClipPreviewProvider.cachedIcon(for: item) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Theme.fileIconSize, height: Theme.fileIconSize)
                    .opacity(fileInfo?.isMissing == true ? 0.5 : 1)
            } else {
                Image(systemName: "doc.fill").font(.system(size: 32))
                    .foregroundStyle(headerColor)
            }
            Text(item.displayTitle).font(.system(size: 12))
                .foregroundStyle(Theme.cardTextSecondary).lineLimit(2)
                .multilineTextAlignment(.center)
            if fileInfo?.isMissing == true {
                Text("File not found")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.cardTextTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadPreview() async {
        preview = ClipPreviewProvider.cachedImage(for: item)
        fileInfo = nil
        previewFailed = false
        if ClipPreviewProvider.showsImage(item) {
            if preview == nil {
                preview = await ClipPreviewProvider.image(for: item, scale: NSScreen.main?.backingScaleFactor ?? 2)
            }
            guard preview == nil, item.type == .file else { return }
            previewFailed = true
        }
        guard item.type == .file else { return }
        fileInfo = await ClipPreviewProvider.fileInfo(for: item)
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 30))
            .foregroundStyle(Theme.cardTextTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 6) {
                // A path is worth reading in full, so it wraps rather than
                // collapsing to an ellipsis; everything else stays one line.
                Text(footerLeft)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.cardTextSecondary)
                    .lineLimit(item.type == .file ? 3 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if index < 9 {
                    HStack(spacing: 3) {
                        Text(settings.quickPasteModifierDisplay)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.cardTextTertiary)
                }
            }
        }
        .padding(.top, 8)
    }

    private var isSingleImageFile: Bool {
        ClipPreviewProvider.imageFileURL(for: item) != nil
    }

    /// NSHomeDirectory is the sandbox container in the App Store build, so the
    /// real home comes from the account record instead.
    private static let homePath: String = {
        if let home = getpwuid(getuid())?.pointee.pw_dir { return String(cString: home) }
        return NSHomeDirectory()
    }()

    private static func abbreviatedPath(_ path: String) -> String {
        if path == homePath { return "~" }
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }

    /// 링크 주소와 색 값은 카드 가운데에 이미 크게 있으니 아래에는 다른 정보를 둔다.
    private var footerLeft: String {
        switch item.type {
        case .link: return ""
        case .color:
            guard let hex = item.colorHex, let c = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return metaLeft }
            return "RGB \(Int((c.redComponent * 255).rounded())), \(Int((c.greenComponent * 255).rounded())), \(Int((c.blueComponent * 255).rounded()))"
        default: return metaLeft
        }
    }

    private var metaLeft: String {
        switch item.type {
        case .text, .richText:
            return String(localized: "\(item.charCount) characters")
        case .link:
            return (item.text ?? "").replacingOccurrences(of: "https://", with: "")
                                    .replacingOccurrences(of: "http://", with: "")
        case .file:
            guard item.fileURLs.count == 1,
                  let url = item.fileURLs.first.flatMap(URL.init(string:)) else {
                return item.fileURLs
                    .compactMap { URL(string: $0)?.lastPathComponent }
                    .joined(separator: ", ")
            }
            // An image shows what it is, so its size is the useful fact; a
            // screenshot's path is a timestamped folder nobody reads. Files
            // without a preview get the full location instead, since two
            // documents of the same name differ only by where they live.
            if isSingleImageFile {
                guard let size = ImagePixelSize.of(url) else { return url.lastPathComponent }
                return "\(Int(size.width)) × \(Int(size.height))"
            }
            return Self.abbreviatedPath(url.path)
        case .image:
            guard let size = ImagePixelSize.of(item) else { return String(localized: "Image") }
            return "\(Int(size.width)) × \(Int(size.height))"
        case .color:
            return item.colorHex ?? String(localized: "Color")
        }
    }

    @ViewBuilder
    private var menu: some View {
        // Paste and Copy act on the whole multi-selection when this card is
        // part of it, the same way Delete does.
        let selection = AppController.shared.selection(containing: item)

        Button { AppController.shared.pasteSelection(containing: item) } label: {
            Label(AppController.shared.pasteMenuTitle(clipCount: selection.count),
                  systemImage: "doc.on.clipboard")
        }

        Button { AppController.shared.pasteSelection(containing: item, format: .plainText) } label: {
            Label("Paste as Plain Text", systemImage: "text.alignleft")
        }
        .disabled(!selection.contains { $0.plainText != nil })

        Button { AppController.shared.copySelection(containing: item) } label: {
            Label(selection.count > 1 ? "Copy \(selection.count) Clips" : "Copy",
                  systemImage: "doc.on.doc")
        }

        Divider()

        Button { Pinned.toggle(selection) } label: {
            if selection.allSatisfy(Pinned.contains) {
                Label("고정 풀기 (⌘P)", systemImage: "pin.slash")
            } else {
                Label("고정 (⌘P)", systemImage: "pin")
            }
        }

        if item.type == .text || item.type == .richText {
            Button { AccountActions.save(from: item) } label: {
                Label("계정으로 저장…", systemImage: "key")
            }
        }

        Button { AppController.shared.editItem(item) } label: {
            Label("Edit", systemImage: "pencil")
        }
        .disabled(!isEditable)

        Button { renameItem() } label: {
            Label("Rename…", systemImage: "pencil.line")
        }

        Button { AppController.shared.showPreview(for: item) } label: {
            Label("미리보기 (⌘Y)", systemImage: "eye")
        }

        Divider()

        Button(role: .destructive) {
            AppController.shared.deleteSelection(containing: item)
        } label: {
            Label(deleteMenuTitle, systemImage: "trash")
        }
    }

    private var deleteMenuTitle: String {
        let count = store.multiSelectedIDs.contains(item.id) ? store.multiSelectedIDs.count : 1
        return count > 1 ? String(localized: "Delete \(count) Clips") : String(localized: "Delete")
    }

    private var isEditable: Bool {
        [.text, .richText, .link, .color].contains(item.type)
    }

    private var writingToolsAvailable: Bool {
        guard [.text, .richText, .link].contains(item.type) else { return false }
        guard #available(macOS 15.2, *) else { return false }
        return NSWritingToolsCoordinator.isWritingToolsAvailable
    }

    private func renameItem() {
        if let title = TextPrompt.run(title: String(localized: "Rename"), message: String(localized: "Card title"),
                                      defaultValue: item.customTitle ?? "") {
            store.setTitle(title, for: item)
        }
    }
}

/// The standard transparency checkerboard drawn behind image clips. A Canvas
/// rather than a tiled image: the pattern is a handful of rects, and this keeps
/// it resolution independent without shipping an asset.
private struct CheckerboardBackground: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for row in 0..<max(rows, 0) {
                for column in 0..<max(columns, 0) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square,
                                      y: CGFloat(row) * square,
                                      width: square,
                                      height: square)
                    context.fill(Path(rect), with: .color(Color(white: 0.87)))
                }
            }
        }
        .drawingGroup()
    }
}

/// Reads an image clip's pixel dimensions from the file's metadata instead of
/// decoding it, and remembers them: the card footer asks on every render.
@MainActor
enum ImagePixelSize {
    private static var cache: [String: CGSize?] = [:]
    private static let cacheLimit = 512

    static func of(_ item: ClipItem) -> CGSize? {
        guard item.imageFileName != nil,
              let url = ClipboardStore.shared.imageURL(for: item) else { return nil }
        return of(url)
    }

    static func of(_ url: URL) -> CGSize? {
        let name = url.path
        if let cached = cache[name] { return cached }
        if cache.count >= cacheLimit { cache.removeAll() }
        let size = read(url)
        cache.updateValue(size, forKey: name)
        return size
    }

    private static func read(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }
}
