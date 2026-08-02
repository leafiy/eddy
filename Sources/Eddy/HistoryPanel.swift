import AppKit
import LeafiyUI
import SwiftUI

/// The history panel: the last 500 successful compressions, newest first.
/// Slides in over the trailing edge of the main window; the toolbar button
/// (⌘Y) toggles it. Rows drag out as real files, reopen in Finder, or go
/// back into the queue for another pass.
struct HistoryPanel: View {
    @ObservedObject private var history = HistoryStore.shared

    static let width: CGFloat = 380
    static let slideAnimation: Animation = .easeInOut(duration: 0.25)

    var body: some View {
        VStack(spacing: .zero) {
            header
            Divider()
            if history.entries.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: L("No compressions yet"),
                    subtitle: L("Files you compress show up here — drag them out, reveal them in Finder, or run them again.")
                )
            } else {
                List(history.entries) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                footer
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.separator)
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            Text(L("History"))
                .font(.headline)
            Spacer()
            Button {
                history.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(history.entries.isEmpty)
            .help(L("Remove all history entries"))
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
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
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: LeafiyDesign.Spacing.m) {
            thumbnailView
            VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.xxs) {
                Text(entry.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Formatters.dateTime(entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(help)
            Spacer(minLength: LeafiyDesign.Spacing.m)
            VStack(alignment: .trailing, spacing: LeafiyDesign.Spacing.xxs) {
                savedText
                Text("\(Formatters.bytes(entry.originalBytes)) → \(Formatters.bytes(entry.finalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            recompressControl
        }
        .font(.body.monospacedDigit())
        .padding(.vertical, LeafiyDesign.Spacing.xs)
        .contentShape(Rectangle())
        // Real file drag: drop into Finder, Mail, a browser upload field, or
        // onto the queue side of the window to compress again.
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

    private var help: String {
        if let dimensions = entry.dimensions {
            return "\(entry.path)\n\(dimensions)"
        }
        return entry.path
    }

    /// The row's headline: how much this compression saved. Format conversion
    /// may legitimately grow the file (JPEG → PNG); show "+N%" then.
    private var savedText: some View {
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
        .help(L("Re-compress — send the file back to the queue and run it again"))
    }

    // MARK: - Actions

    /// Puts the file back into the queue and re-runs it with the current
    /// per-drop settings — exactly like re-dropping it.
    private func recompress() {
        guard fileStillExists() else { return }
        let options = SettingsStore.shared.processingOptions
        Store.shared.add(urls: [entry.url], quality: options.quality, maxWidth: options.maxWidth, format: options.format)
    }

    private func showInFinder() {
        guard fileStillExists() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    private func fileStillExists() -> Bool {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            Store.shared.showToast(L("File no longer exists — it may have been moved or deleted"))
            return false
        }
        return true
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
