import AppKit
import LeafiyUI
import SwiftUI

/// The history window: the last 500 successful compressions, newest first.
/// Rows drag out as real files, reopen in Finder, or go back into the main
/// window for another pass.
struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        content
            .frame(minWidth: LeafiyDesign.Size.mainWindowMinWidth, minHeight: LeafiyDesign.Size.mainWindowMinHeight)
            .leafiyToast(toast)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        history.clear()
                    } label: {
                        Label(L("Clear"), systemImage: "trash")
                    }
                    .disabled(history.entries.isEmpty)
                    .help(L("Remove all history entries"))
                }
            }
    }

    @ViewBuilder private var content: some View {
        if history.entries.isEmpty {
            EmptyStateView(
                systemImage: "clock.arrow.circlepath",
                title: L("No compressions yet"),
                subtitle: L("Files you compress show up here — drag them out, reveal them in Finder, or run them again.")
            )
        } else {
            VStack(spacing: .zero) {
                List(history.entries) { entry in
                    HistoryRow(
                        entry: entry,
                        recompress: { recompress(entry) },
                        showInFinder: { showInFinder(entry) }
                    )
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                footer
            }
        }
    }

    private var footer: some View {
        FooterBar {
            Text(history.entries.count == 1
                ? String(format: L("%d file"), history.entries.count)
                : String(format: L("%d files"), history.entries.count))
                .monospacedDigit()
            Spacer()
            if history.totalSavedBytes > 0 {
                Text(String(format: L("Saved %@ in total"), Formatters.bytes(history.totalSavedBytes)))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Actions

    /// Puts the file back into the main window queue and re-runs it with the
    /// current per-drop settings — exactly like re-dropping it.
    private func recompress(_ entry: HistoryEntry) {
        guard fileStillExists(entry) else { return }
        EddyWindows.presentMain(openWindow)
        let options = SettingsStore.shared.processingOptions
        Store.shared.add(urls: [entry.url], quality: options.quality, maxWidth: options.maxWidth, format: options.format)
    }

    private func showInFinder(_ entry: HistoryEntry) {
        guard fileStillExists(entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    private func fileStillExists(_ entry: HistoryEntry) -> Bool {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            showToast(L("File no longer exists — it may have been moved or deleted"))
            return false
        }
        return true
    }

    private func showToast(_ message: String, seconds: Double = 2.8) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let recompress: () -> Void
    let showInFinder: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: LeafiyDesign.Spacing.m) {
            thumbnailView
            VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.xxs) {
                Text(entry.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(entry.path)
            Spacer(minLength: LeafiyDesign.Spacing.m)
            Text(Formatters.bytes(entry.originalBytes))
                .foregroundStyle(.secondary)
            savedColumn
            Text(Formatters.bytes(entry.finalBytes))
            recompressControl
        }
        .font(.body.monospacedDigit())
        .padding(.vertical, LeafiyDesign.Spacing.xs)
        .contentShape(Rectangle())
        // Real file drag: drop into Finder, Mail, a browser upload field, or
        // back onto the main window to compress again.
        .onDrag {
            NSItemProvider(contentsOf: entry.url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(entry.url)
        }
        .contextMenu {
            Button(L("Re-compress"), action: recompress)
            Divider()
            Button(L("Show in Finder"), action: showInFinder)
            Button(L("Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
            Divider()
            Button(L("Remove from History")) {
                HistoryStore.shared.remove(entry.id)
            }
        }
        .task(id: entry.path) {
            let url = entry.url
            thumbnail = await Task.detached(priority: .utility) {
                Compressor.thumbnail(for: url)
            }.value
        }
    }

    private var caption: String {
        let date = Formatters.dateTime(entry.date)
        if let dimensions = entry.dimensions {
            return "\(dimensions) · \(date)"
        }
        return date
    }

    /// The row's headline: how much this compression saved. Format conversion
    /// may legitimately grow the file (JPEG → PNG); show "+N%" then.
    private var savedColumn: some View {
        let fraction = entry.savedFraction
        return Text(fraction < 0
            ? "+" + Formatters.percent(-fraction)
            : "−" + Formatters.percent(fraction))
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
    }

    private var recompressControl: some View {
        Button(action: recompress) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .help(L("Re-compress — send the file back to the main window and run it again"))
        .frame(width: LeafiyDesign.Size.rowIcon)
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LeafiyDesign.Radius.control)
                .fill(.quaternary)
            if let cgImage = thumbnail {
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
}
