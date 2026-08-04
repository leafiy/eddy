import AppKit
import LeafiyUI
import SwiftUI

/// The crop sheet: one selection rectangle over the image that drags inward
/// to trim and outward to pad (Extension Background fills the overhang),
/// with the two fixed Decorations as toggles. Saving hands a CropSpec back
/// and the file is overwritten in place — one-step, no save-as.
struct CropView: View {
    let item: ImageItem
    let onSave: (CropSpec) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var image: CGImage?
    /// Selection in image pixel coordinates, top-left origin; may extend
    /// beyond the image bounds up to the working area.
    @State private var selection: CGRect = .zero
    @State private var background: BackgroundChoice = .white
    @State private var customColor: Color = .white
    @State private var addBorder = false
    @State private var addShadow = false

    @State private var activeHandle: Handle?
    @State private var dragStartSelection: CGRect?
    @State private var isAnimatedAsset = false

    /// Minimum selection side, in image pixels.
    private static let minSelectionSide: CGFloat = 16
    /// How far beyond the image the selection may extend, as a fraction of
    /// the longer image side per edge.
    private static let expansionAllowance: CGFloat = 0.5

    private var fileExtension: String { item.url.pathExtension.lowercased() }
    private var allowsTransparency: Bool { Cropper.supportsAlpha(fileExtension) }

    var body: some View {
        VStack(spacing: .zero) {
            header
            Divider()
            canvas
            Divider()
            controls
        }
        .frame(minWidth: 700, idealWidth: 820, minHeight: 520, idealHeight: 620)
        .task {
            let url = item.url
            let (loaded, animated) = await Task.detached(priority: .userInitiated) {
                (Cropper.previewFrame(for: url), Cropper.isAnimated(url))
            }.value
            isAnimatedAsset = animated
            image = loaded
            if let loaded {
                selection = CGRect(x: 0, y: 0, width: loaded.width, height: loaded.height)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            Text(item.filename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if isAnimatedAsset {
                Text(L("All frames are cropped identically — animation is preserved"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(selection.width.rounded())) × \(Int(selection.height.rounded())) px")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            if let image {
                canvasContent(image: image, viewSize: proxy.size)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .padding(LeafiyDesign.Spacing.m)
    }

    /// View-space geometry for one layout pass: the working area (image
    /// bounds inflated by the expansion allowance) scaled to fit.
    private struct Mapping {
        let workingRect: CGRect   // image coords
        let scale: CGFloat
        let origin: CGPoint       // view-space origin of workingRect

        func toView(_ rect: CGRect) -> CGRect {
            CGRect(
                x: origin.x + (rect.minX - workingRect.minX) * scale,
                y: origin.y + (rect.minY - workingRect.minY) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
    }

    private func mapping(image: CGImage, viewSize: CGSize) -> Mapping {
        let allowance = Self.expansionAllowance * CGFloat(max(image.width, image.height))
        let working = CGRect(
            x: -allowance,
            y: -allowance,
            width: CGFloat(image.width) + 2 * allowance,
            height: CGFloat(image.height) + 2 * allowance
        )
        let scale = min(viewSize.width / working.width, viewSize.height / working.height)
        let origin = CGPoint(
            x: (viewSize.width - working.width * scale) / 2,
            y: (viewSize.height - working.height * scale) / 2
        )
        return Mapping(workingRect: working, scale: scale, origin: origin)
    }

    @ViewBuilder
    private func canvasContent(image: CGImage, viewSize: CGSize) -> some View {
        let map = mapping(image: image, viewSize: viewSize)
        let imageRect = map.toView(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let selectionRect = map.toView(selection)
        // Same perceptual scaling the engine uses (Cropper.decorationUnit).
        let unit = max(1, CGFloat(min(image.width, image.height)) / 400) * map.scale

        ZStack(alignment: .topLeading) {
            // Extension Background preview, only within the selection.
            Group {
                if background == .transparent {
                    Checkerboard()
                } else {
                    Rectangle().fill(backgroundPreviewColor)
                }
            }
            .frame(width: selectionRect.width, height: selectionRect.height)
            .offset(x: selectionRect.minX, y: selectionRect.minY)

            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: imageRect.width, height: imageRect.height)
                .overlay {
                    if addBorder {
                        Rectangle()
                            .strokeBorder(Color(white: 0.62), lineWidth: max(unit, 0.5))
                    }
                }
                .shadow(
                    color: addShadow ? .black.opacity(0.3) : .clear,
                    radius: addShadow ? 10 * unit : 0,
                    x: 0,
                    y: addShadow ? 3 * unit : 0
                )
                .offset(x: imageRect.minX, y: imageRect.minY)

            // Dim everything being cropped away (outside the selection).
            Path { path in
                path.addRect(CGRect(origin: .zero, size: viewSize))
                path.addRect(selectionRect)
            }
            .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            selectionChrome(selectionRect)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(map: map))
    }

    private var backgroundPreviewColor: Color {
        switch background {
        case .white:       return .white
        case .black:       return .black
        case .transparent: return .clear
        case .custom:      return customColor
        }
    }

    @ViewBuilder
    private func selectionChrome(_ rect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
        ForEach(Handle.resizeHandles, id: \.self) { handle in
            let center = handle.position(in: rect)
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .position(center)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Selection dragging

    private enum Handle: Hashable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
        case move

        static let resizeHandles: [Handle] = [
            .topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight,
        ]

        func position(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
            case .top:         return CGPoint(x: rect.midX, y: rect.minY)
            case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
            case .left:        return CGPoint(x: rect.minX, y: rect.midY)
            case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .move:        return CGPoint(x: rect.midX, y: rect.midY)
            }
        }

        var movesLeftEdge: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRightEdge: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTopEdge: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottomEdge: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    }

    private func dragGesture(map: Mapping) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeHandle == nil {
                    let selectionRect = map.toView(selection)
                    activeHandle = hitTest(value.startLocation, selectionRect: selectionRect)
                    dragStartSelection = selection
                }
                guard let handle = activeHandle, let start = dragStartSelection else { return }
                let dx = value.translation.width / map.scale
                let dy = value.translation.height / map.scale
                selection = Self.adjusted(
                    start,
                    handle: handle,
                    dx: dx,
                    dy: dy,
                    within: map.workingRect,
                    minSide: Self.minSelectionSide
                )
            }
            .onEnded { _ in
                activeHandle = nil
                dragStartSelection = nil
                selection = selection.integral
            }
    }

    /// Which handle a drag starting at `point` grabs: a resize handle within
    /// tolerance wins, anywhere inside the selection moves it, outside is inert.
    private func hitTest(_ point: CGPoint, selectionRect: CGRect) -> Handle? {
        let tolerance: CGFloat = 12
        for handle in Handle.resizeHandles {
            let center = handle.position(in: selectionRect)
            if abs(point.x - center.x) <= tolerance, abs(point.y - center.y) <= tolerance {
                return handle
            }
        }
        return selectionRect.contains(point) ? .move : nil
    }

    private static func adjusted(
        _ start: CGRect,
        handle: Handle,
        dx: CGFloat,
        dy: CGFloat,
        within bounds: CGRect,
        minSide: CGFloat
    ) -> CGRect {
        if handle == .move {
            let x = min(max(start.minX + dx, bounds.minX), bounds.maxX - start.width)
            let y = min(max(start.minY + dy, bounds.minY), bounds.maxY - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        }
        var minX = start.minX
        var maxX = start.maxX
        var minY = start.minY
        var maxY = start.maxY
        if handle.movesLeftEdge {
            minX = min(max(start.minX + dx, bounds.minX), maxX - minSide)
        }
        if handle.movesRightEdge {
            maxX = max(min(start.maxX + dx, bounds.maxX), minX + minSide)
        }
        if handle.movesTopEdge {
            minY = min(max(start.minY + dy, bounds.minY), maxY - minSide)
        }
        if handle.movesBottomEdge {
            maxY = max(min(start.maxY + dy, bounds.maxY), minY + minSide)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Controls

    private enum BackgroundChoice: Hashable {
        case white, black, transparent, custom
    }

    private var controls: some View {
        HStack(spacing: LeafiyDesign.Spacing.m) {
            Text(L("Extension background"))
                .foregroundStyle(.secondary)
            swatch(.white, fill: .white, label: L("White"))
            swatch(.black, fill: .black, label: L("Black"))
            swatch(.transparent, fill: .clear, label: L("Transparent"))
                .disabled(!allowsTransparency)
                .opacity(allowsTransparency ? 1 : 0.3)
                .help(allowsTransparency
                    ? L("Transparent")
                    : L("This format cannot store transparency"))
            ColorPicker("", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: customColor) { _, _ in background = .custom }
                .overlay(alignment: .bottom) {
                    if background == .custom {
                        selectionDot
                    }
                }
                .help(L("Custom color"))

            Divider().frame(height: 16)

            Toggle(L("Border"), isOn: $addBorder)
                .toggleStyle(.checkbox)
            Toggle(L("Shadow"), isOn: $addShadow)
                .toggleStyle(.checkbox)

            Spacer()

            Button(L("Reset Selection")) {
                if let image {
                    selection = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                }
            }
            .disabled(image == nil)
            Button(L("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Crop and Save")) { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(image == nil)
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
    }

    private func swatch(_ choice: BackgroundChoice, fill: Color, label: String) -> some View {
        Button {
            background = choice
        } label: {
            ZStack {
                if choice == .transparent {
                    Checkerboard()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(fill)
                }
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        background == choice ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: background == choice ? 2 : 1
                    )
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var selectionDot: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 4, height: 4)
            .offset(y: 5)
    }

    // MARK: - Saving

    private func save() {
        guard image != nil else { return }
        let cgBackground: CGColor?
        switch background {
        case .white:
            cgBackground = CGColor(gray: 1, alpha: 1)
        case .black:
            cgBackground = CGColor(gray: 0, alpha: 1)
        case .transparent:
            cgBackground = allowsTransparency ? nil : CGColor(gray: 1, alpha: 1)
        case .custom:
            cgBackground = NSColor(customColor).usingColorSpace(.sRGB)?.cgColor
                ?? CGColor(gray: 1, alpha: 1)
        }
        onSave(CropSpec(
            rect: selection.integral,
            background: cgBackground,
            border: addBorder,
            shadow: addShadow
        ))
        dismiss()
    }
}

/// Classic transparency checkerboard, used behind the transparent
/// Extension Background preview and on its swatch.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 7
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var y: CGFloat = 0
            var rowOffset = false
            while y < size.height {
                var x: CGFloat = rowOffset ? square : 0
                while x < size.width {
                    context.fill(
                        Path(CGRect(x: x, y: y, width: square, height: square)),
                        with: .color(Color(white: 0.8))
                    )
                    x += square * 2
                }
                y += square
                rowOffset.toggle()
            }
        }
    }
}
