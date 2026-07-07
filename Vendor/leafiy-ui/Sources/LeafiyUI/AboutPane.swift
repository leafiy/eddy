import AppKit
import SwiftUI

/// The standardized About tab, identical across the app family: app icon,
/// name, version, a one-line tagline, optional links, optional copyright.
public struct AboutPane: View {
    public struct PaneLink: Identifiable {
        public let title: String
        public let url: URL

        public var id: String { title }

        public init(_ title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    private let title: String
    private let systemImage: String
    private let appName: String
    private let tagline: String
    private let links: [PaneLink]
    private let copyright: String?
    private let icon: NSImage

    /// - Parameters:
    ///   - title: Tab title; pass a localized string ("About", "关于").
    ///   - appName: Defaults to the bundle display name.
    ///   - tagline: One sentence describing the app.
    ///   - icon: Defaults to the application icon.
    public init(
        title: String = "About",
        systemImage: String = "info.circle",
        appName: String? = nil,
        tagline: String,
        links: [PaneLink] = [],
        copyright: String? = nil,
        icon: NSImage? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.appName = appName ?? Self.bundleName
        self.tagline = tagline
        self.links = links
        self.copyright = copyright
        self.icon = icon ?? NSApplication.shared.applicationIconImage ?? NSImage()
    }

    public var body: some View {
        SettingsPane(title, systemImage: systemImage, height: LeafiyDesign.Size.aboutPaneHeight) {
            Section {
                VStack(spacing: LeafiyDesign.Spacing.m) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(
                            width: LeafiyDesign.Size.aboutIcon,
                            height: LeafiyDesign.Size.aboutIcon
                        )
                    Text(appName)
                        .font(.title2.weight(.semibold))
                    Text(Self.versionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(tagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !links.isEmpty {
                        HStack(spacing: LeafiyDesign.Spacing.l) {
                            ForEach(links) { link in
                                Link(link.title, destination: link.url)
                            }
                        }
                        .font(.callout)
                    }
                    if let copyright {
                        Text(copyright)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, LeafiyDesign.Spacing.xl)
            }
        }
    }

    private static var bundleName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? ProcessInfo.processInfo.processName
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build:
            return "Version \(short) (\(build))"
        case let (short?, _):
            return "Version \(short)"
        case let (nil, build?):
            return "Version \(build)"
        default:
            return "Development build"
        }
    }
}
