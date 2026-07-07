import SwiftUI

/// Centered placeholder for empty content areas (drop targets, empty
/// history, no results).
public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let subtitle: String?

    public init(systemImage: String, title: String, subtitle: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: LeafiyDesign.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LeafiyDesign.Spacing.xxl)
    }
}

/// Thin status bar pinned under the main content: divider on top, bar
/// material behind, callout-sized secondary text inside.
public struct FooterBar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: LeafiyDesign.Spacing.m) {
                content
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, LeafiyDesign.Spacing.l)
            .padding(.vertical, LeafiyDesign.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

/// Inline control strip inside main-window content (e.g. per-batch options),
/// visually one rounded group.
public struct ControlBar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: LeafiyDesign.Spacing.l) {
            content
        }
        .padding(.horizontal, LeafiyDesign.Spacing.l)
        .padding(.vertical, LeafiyDesign.Spacing.s)
        .background(
            .quaternary.opacity(0.5),
            in: RoundedRectangle(cornerRadius: LeafiyDesign.Radius.card)
        )
    }
}

/// Rounded, hairline-bordered container for primary content areas
/// (text editors, result panes).
public struct LeafiyCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(LeafiyDesign.Spacing.m)
            .background(
                .background,
                in: RoundedRectangle(cornerRadius: LeafiyDesign.Radius.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LeafiyDesign.Radius.card)
                    .strokeBorder(.quaternary)
            )
    }
}

/// The family-standard transient toast.
public struct ToastCapsule: View {
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, LeafiyDesign.Spacing.l)
            .padding(.vertical, LeafiyDesign.Spacing.s)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .shadow(radius: 8, y: 2)
    }
}

extension View {
    /// Presents the family-standard toast at the bottom while `message`
    /// is non-nil.
    public func leafiyToast(_ message: String?) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                ToastCapsule(message)
                    .padding(.bottom, LeafiyDesign.Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}
