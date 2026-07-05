import SwiftUI

struct ContentView: View {
    @ObservedObject private var store = Store.shared
    @AppStorage("compressionQuality") private var qualityPercent = 80.0
    @State private var isDropTargeted = false

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 400)
            .dropDestination(for: URL.self) { urls, _ in
                store.add(urls: urls, quality: qualityPercent / 100)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                }
            }
            .toolbar { toolbarContent }
    }

    @ViewBuilder private var content: some View {
        if store.items.isEmpty {
            emptyHint
        } else {
            VStack(spacing: 0) {
                List(store.items) { item in
                    ItemRow(item: item)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                Divider()
                footer
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Drop images here")
                .font(.title2)
            Text("JPEG · PNG · GIF · BMP · WebP · TIFF · HEIC — compressed and saved in place")
                .font(.callout)
                .foregroundStyle(.secondary)
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
            HStack(spacing: 8) {
                Text("Quality")
                Slider(value: $qualityPercent, in: 10...100, step: 5)
                    .frame(width: 140)
                Text("\(Int(qualityPercent))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
            }
            .help("Lossy quality for JPEG/WebP/HEIC. Applies to newly dropped files.")
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
        HStack(spacing: 10) {
            thumbnail
            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)
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
