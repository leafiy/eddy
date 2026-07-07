import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var store = Store.shared
    @AppStorage("compressionQuality") private var qualityPercent = 80.0
    @AppStorage("resizeMaxWidth") private var resizeMaxWidth = 0
    @State private var isDropTargeted = false
    @State private var showingOpenPanel = false

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 400)
            .dropDestination(for: URL.self) { urls, _ in
                store.add(urls: urls, quality: qualityPercent / 100, maxWidth: resizeMaxWidth)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .fileImporter(
                isPresented: $showingOpenPanel,
                allowedContentTypes: [.image, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    store.add(urls: urls, quality: qualityPercent / 100, maxWidth: resizeMaxWidth)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) { toastOverlay }
            .animation(.easeOut(duration: 0.2), value: store.toast)
            .toolbar { toolbarContent }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            settingsBar
            Divider()
            if store.items.isEmpty {
                emptyHint
            } else {
                List(store.items) { item in
                    ItemRow(item: item)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                Divider()
                footer
            }
        }
    }

    /// Lives in the window content, not the toolbar: macOS toolbar items do
    /// not reliably re-render on state changes, which froze these controls.
    private var settingsBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            settingControl("Quality") {
                Slider(value: $qualityPercent, in: 10...100, step: 5)
                    .frame(width: 140)
                Text("\(Int(qualityPercent))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
            }
            .help("Lossy quality for JPEG/WebP/AVIF/HEIC. Applies to newly dropped files.")

            Divider()
                .frame(height: 18)

            settingControl("Size") {
                Menu {
                    sizeOption(0, "Original size")
                    sizeOption(800, "800 px — blogs")
                    sizeOption(1080, "1080 px — Instagram")
                    sizeOption(1200, "1200 px — X / Facebook")
                    sizeOption(1600, "1600 px")
                    sizeOption(2048, "2048 px — high-res")
                } label: {
                    Text(resizeMaxWidth == 0 ? "Original size" : "≤ \(resizeMaxWidth) px")
                }
                .fixedSize()
            }
            .help("Downscale to this width (aspect ratio kept, never upscales). Applies to newly dropped files.")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func settingControl<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            content()
        }
    }

    @ViewBuilder private var toastOverlay: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Drop images here")
                .font(.title2)
            Text("JPEG · PNG · GIF · BMP · WebP · AVIF · TIFF · HEIC — or press ⌘O / paste files or a copied image with ⌘V")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Files are compressed and saved in place — originals are only replaced when the result is smaller.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        let finished = store.items.filter { $0.finalBytes != nil }
        let original = finished.reduce(0) { $0 + $1.originalBytes }
        let final = finished.reduce(0) { $0 + ($1.finalBytes ?? 0) }
        let saved = original - final
        return HStack {
            Text("\(store.items.count) file\(store.items.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Spacer()
            if original > 0 {
                Text("Saved \(Formatters.bytes(saved)) (\(Formatters.percent(Double(saved) / Double(original))))")
                    .foregroundStyle(saved > 0 ? Color.green : Color.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private func sizeOption(_ width: Int, _ title: String) -> some View {
        Button {
            resizeMaxWidth = width
        } label: {
            if resizeMaxWidth == width {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

struct ItemRow: View {
    let item: ImageItem

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
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
            Spacer(minLength: 12)
            Text(Formatters.bytes(item.originalBytes))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            statusColumn
                .frame(width: 86, alignment: .trailing)
            Text(item.finalBytes.map(Formatters.bytes) ?? "—")
                .frame(width: 78, alignment: .trailing)
        }
        .font(.body.monospacedDigit())
        .padding(.vertical, 3)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let cgImage = item.thumbnail {
                Image(decorative: cgImage, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            Text("−" + Formatters.percent(item.savedFraction ?? 0))
                .fontWeight(.semibold)
                .foregroundStyle(.green)
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
