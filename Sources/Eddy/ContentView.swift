import AppKit
import SwiftUI
import LeafiyUI
import UniformTypeIdentifiers

struct ResizeMaxWidthOption: Identifiable {
    let width: Int
    let title: String

    var id: Int { width }

    static let all = [
        ResizeMaxWidthOption(width: 0, title: "Original size"),
        ResizeMaxWidthOption(width: 800, title: "800 px — blogs"),
        ResizeMaxWidthOption(width: 1080, title: "1080 px — Instagram"),
        ResizeMaxWidthOption(width: 1200, title: "1200 px — X / Facebook"),
        ResizeMaxWidthOption(width: 1600, title: "1600 px"),
        ResizeMaxWidthOption(width: 2048, title: "2048 px — high-res")
    ]
}

struct ContentView: View {
    @ObservedObject private var store = Store.shared
    @AppStorage("compressionQuality") private var qualityPercent = 80.0
    @AppStorage("resizeMaxWidth") private var resizeMaxWidth = 0
    @AppStorage("defaultSaveFormat") private var saveFormatRaw = SaveFormat.keep.rawValue
    @State private var isDropTargeted = false
    @State private var showingOpenPanel = false

    private var saveFormat: SaveFormat { SaveFormat(rawValue: saveFormatRaw) ?? .keep }

    var body: some View {
        content
            .frame(minWidth: LeafiyDesign.Size.mainWindowMinWidth, minHeight: LeafiyDesign.Size.mainWindowMinHeight)
            .dropDestination(for: URL.self) { urls, _ in
                store.add(urls: urls, quality: qualityPercent / 100, maxWidth: resizeMaxWidth, format: saveFormat)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .fileImporter(
                isPresented: $showingOpenPanel,
                allowedContentTypes: [.image, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    store.add(urls: urls, quality: qualityPercent / 100, maxWidth: resizeMaxWidth, format: saveFormat)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: LeafiyDesign.Radius.card)
                        .strokeBorder(Color.accentColor, lineWidth: LeafiyDesign.Spacing.xxs)
                        .padding(LeafiyDesign.Spacing.xs)
                }
            }
            .leafiyToast(store.toast)
            .toolbar { toolbarContent }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: .zero) {
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

    private var emptyHint: some View {
        EmptyStateView(
            systemImage: "photo.on.rectangle.angled",
            title: "Drop images here",
            subtitle: "JPEG · PNG · GIF · BMP · WebP · AVIF · TIFF · HEIC\n⌘O to open · ⌘V to paste · files are optimized in place, replaced only when smaller"
        )
    }

    private var footer: some View {
        let finished = store.items.filter { $0.finalBytes != nil }
        let original = finished.reduce(0) { $0 + $1.originalBytes }
        let final = finished.reduce(0) { $0 + ($1.finalBytes ?? 0) }
        let saved = original - final
        return FooterBar {
            Text("\(store.items.count) file\(store.items.count == 1 ? "" : "s")")
                .monospacedDigit()
            Spacer()
            if original > 0 {
                Text("Saved \(Formatters.bytes(saved)) (\(Formatters.percent(Double(saved) / Double(original))))")
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
                Label("Open", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Choose images or folders (⌘O)")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                store.clearFinished()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(store.items.isEmpty)
            .help("Remove finished entries from the list")
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
        }
        .font(.body.monospacedDigit())
        .padding(.vertical, LeafiyDesign.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(item.url)
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            Button("Remove from List") {
                Store.shared.removeItem(item.id)
            }
        }
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
            Text("waiting")
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
                .help("Already smaller than the re-encoded result; original kept")
        case .failed(let message):
            Label("failed", systemImage: "exclamationmark.triangle.fill")
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

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}
