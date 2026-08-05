import AppKit
import SwiftUI
import LeafiyUI
import UniformTypeIdentifiers

struct ResizeMaxWidthOption: Identifiable {
    let width: Int

    var id: Int { width }
    var title: String {
        switch width {
        case 0: return L("Original size")
        case 800: return L("800 px — blogs")
        case 1080: return L("1080 px — Instagram")
        case 1200: return L("1200 px — X / Facebook")
        case 1600: return L("1600 px")
        case 2048: return L("2048 px — high-res")
        default: return String(format: L("≤ %d px"), width)
        }
    }


    static let all = [
        ResizeMaxWidthOption(width: 0),
        ResizeMaxWidthOption(width: 800),
        ResizeMaxWidthOption(width: 1080),
        ResizeMaxWidthOption(width: 1200),
        ResizeMaxWidthOption(width: 1600),
        ResizeMaxWidthOption(width: 2048)
    ]

    static func title(for width: Int) -> String {
        all.first { $0.width == width }?.title ?? String(format: L("≤ %d px"), width)
    }
}

struct ContentView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject var settingsStore: SettingsStore
    @State private var isDropTargeted = false
    @State private var showingOpenPanel = false
    @ObservedObject private var history = HistoryStore.shared

    private enum Metrics {
        /// Fixed slider width keeps the quality/size strip one compact line
        /// instead of the slider greedily spanning the whole window.
        static let qualitySliderWidth: CGFloat = 140
    }

    var body: some View {
        content
            .frame(minWidth: LeafiyDesign.Size.mainWindowMinWidth, minHeight: LeafiyDesign.Size.mainWindowMinHeight)
            .dropDestination(for: URL.self) { urls, _ in
                let options = settingsStore.processingOptions
                store.add(urls: urls, quality: options.quality, maxWidth: options.maxWidth, format: options.format)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .fileImporter(
                isPresented: $showingOpenPanel,
                allowedContentTypes: [.image, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    let options = settingsStore.processingOptions
                    store.add(urls: urls, quality: options.quality, maxWidth: options.maxWidth, format: options.format)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: LeafiyDesign.Radius.card)
                        .strokeBorder(Color.accentColor, lineWidth: LeafiyDesign.Spacing.xxs)
                        .padding(LeafiyDesign.Spacing.xs)
                }
            }
            .overlay(alignment: .trailing) {
                if history.isPresented {
                    HistoryPanel()
                        .transition(.move(edge: .trailing))
                }
            }
            .leafiyToast(store.toast)
            .alert(L("Set up Quick Share"), isPresented: $store.needsQuickShareSetup) {
                Button(L("Open Settings")) { LeafiySettingsWindow.open() }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(L("Quick Share uploads compressed files to your own object storage. Add your storage account in Settings → Share first."))
            }
            .sheet(item: $store.editorRequest) { request in
                CropView(item: request.item, intent: request.intent) { spec in
                    store.applyCrop(request.item.id, spec: spec)
                }
            }
            .toolbar { toolbarContent }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: .zero) {
            settingsBar
                .padding(.horizontal, LeafiyDesign.Spacing.m)
                .padding(.vertical, LeafiyDesign.Spacing.s)
            if store.items.isEmpty {
                emptyHint
            } else {
                List(store.items) { item in
                    ItemRow(item: item)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                footer
            }
        }
    }

    /// Quick per-drop settings. Lives in the window content, not the toolbar:
    /// macOS toolbar items do not reliably re-render on state changes, which
    /// froze these controls. Save format is Settings-only by request.
    private var settingsBar: some View {
        ControlBar {
            settingControl(L("Quality")) {
                Slider(value: qualityBinding, in: 10...100, step: 5)
                    .frame(width: Metrics.qualitySliderWidth)
                Text("\(Int(settingsStore.settings.compressionQuality))%")
                    .monospacedDigit()
            }
            .help(L("Lossy quality for JPEG/WebP/AVIF/HEIC. Applies to newly dropped files."))

            Divider()

            settingControl(L("Size")) {
                Menu {
                    ForEach(ResizeMaxWidthOption.all) { option in
                        sizeOption(option)
                    }
                } label: {
                    Text(ResizeMaxWidthOption.title(for: settingsStore.settings.resizeMaxWidth))
                }
                .fixedSize()
            }
            .help(L("Downscale to this width (aspect ratio kept, never upscales). Applies to newly dropped files."))
            Spacer()
        }
        .font(.callout)
        .controlSize(.small)
        // A Divider inside an HStack expands to any proposed height, which
        // made the whole strip vertically greedy — the VStack then gave it
        // half the window. Pin the strip to its one-line ideal height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func settingControl<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            Text(title)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func sizeOption(_ option: ResizeMaxWidthOption) -> some View {
        Button {
            settingsStore.update { $0.resizeMaxWidth = option.width }
        } label: {
            if settingsStore.settings.resizeMaxWidth == option.width {
                Label(option.title, systemImage: "checkmark")
            } else {
                Text(option.title)
            }
        }
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { settingsStore.settings.compressionQuality },
            set: { newValue in settingsStore.update { $0.compressionQuality = newValue } }
        )
    }

    private var emptyHint: some View {
        EmptyStateView(
            systemImage: "photo.on.rectangle.angled",
            title: L("Drop images here"),
            subtitle: L("JPEG · PNG · GIF · BMP · WebP · AVIF · TIFF · HEIC\n⌘O to open · ⌘V to paste · files are optimized in place, replaced only when smaller")
        )
    }

    private var footer: some View {
        let finished = store.items.filter { $0.finalBytes != nil }
        let original = finished.reduce(0) { $0 + $1.originalBytes }
        let final = finished.reduce(0) { $0 + ($1.finalBytes ?? 0) }
        let saved = original - final
        return FooterBar {
            Text(store.items.count == 1
                ? String(format: L("%d file"), store.items.count)
                : String(format: L("%d files"), store.items.count))
                .monospacedDigit()
            Spacer()
            if original > 0 {
                Text(String(format: L("Saved %@ (%@)"), Formatters.bytes(saved), Formatters.percent(Double(saved) / Double(original))))
                    .fontWeight(saved > 0 ? .semibold : .regular)
                    .monospacedDigit()
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                showingOpenPanel = true
            } label: {
                Label(L("Open"), systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help(L("Choose images or folders (⌘O)"))
        }
        ToolbarItem(placement: .automatic) {
            Button {
                withAnimation(HistoryPanel.slideAnimation) {
                    history.isPresented.toggle()
                }
            } label: {
                Label(L("History"), systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("y", modifiers: .command)
            .help(L("Show or hide compression history (⌘Y)"))
        }
        ToolbarItem(placement: .automatic) {
            Button {
                store.clearFinished()
            } label: {
                Label(L("Clear"), systemImage: "trash")
            }
            .disabled(store.items.isEmpty)
            .help(L("Remove finished entries from the list"))
        }
    }
}

struct ItemRow: View {
    let item: ImageItem

    var body: some View {
        HStack(spacing: LeafiyDesign.Spacing.m) {
            thumbnail
            VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.xxs) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let dimensions = item.dimensions {
                    Text(dimensions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help(item.url.path)
            Spacer(minLength: LeafiyDesign.Spacing.m)
            Text(Formatters.bytes(item.originalBytes))
                .foregroundStyle(.secondary)
            statusColumn
            Text(item.finalBytes.map(Formatters.bytes) ?? "—")
            shareControl
        }
        .font(.body.monospacedDigit())
        .padding(.vertical, LeafiyDesign.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(item.url)
        }
        .contextMenu {
            Button(L("Quick Share")) {
                Store.shared.quickShare(item.id)
            }
            .disabled(!item.isShareable || item.isSharing)
            Divider()
            Button(L("Crop…")) {
                Store.shared.beginCrop(item.id)
            }
            .disabled(!item.isCroppable)
            Button(L("Remove Background…")) {
                Store.shared.beginBackgroundRemoval(item.id)
            }
            .disabled(!item.isCroppable)
            Button(L("Restore Original")) {
                Store.shared.restoreOriginal(item.id)
            }
            .disabled(!item.isRestorable)
            Divider()
            Button(L("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button(L("Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            Button(L("Remove from List")) {
                Store.shared.removeItem(item.id)
            }
        }
    }

    /// Quick Share button; spins while the upload is in flight. Fixed width
    /// so rows stay column-aligned whether or not the item is shareable yet.
    @ViewBuilder private var shareControl: some View {
        Group {
            if item.isSharing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Store.shared.quickShare(item.id)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(!item.isShareable)
                .opacity(item.isShareable ? 1 : 0.3)
                .help(L("Quick Share — upload the compressed file and copy the public link"))
            }
        }
        .frame(width: LeafiyDesign.Size.rowIcon)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LeafiyDesign.Radius.control)
                .fill(.quaternary)
            if let cgImage = item.thumbnail {
                Image(nsImage: NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: LeafiyDesign.Size.rowIcon, height: LeafiyDesign.Size.rowIcon)
                ))
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: LeafiyDesign.Size.rowIcon, height: LeafiyDesign.Size.rowIcon)
        .clipShape(RoundedRectangle(cornerRadius: LeafiyDesign.Radius.control))
    }

    @ViewBuilder private var statusColumn: some View {
        switch item.status {
        case .pending:
            Text(L("waiting"))
                .foregroundStyle(.secondary)
        case .processing:
            ProgressView()
                .controlSize(.small)
        case .done:
            // Format conversion may legitimately grow the file (JPEG → PNG);
            // show "+N%" instead of a garbled double minus.
            let fraction = item.savedFraction ?? 0
            Text(fraction < 0
                ? "+" + Formatters.percent(-fraction)
                : "−" + Formatters.percent(fraction))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        case .unchanged:
            Text("0%")
                .foregroundStyle(.secondary)
                .help(L("Already smaller than the re-encoded result; original kept"))
        case .failed(let message):
            Label(L("failed"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }
}

enum Formatters {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ count: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(count))
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}
