import AppKit
import LeafiyUI
import SwiftUI

enum ImageEditorIntent {
    case edit
    case removeBackground
}

/// The non-destructive image editor. Crop/padding, subject lifting, rotation,
/// border and shadow are previewed together, share one local undo stack, and
/// are committed to the file only when the user saves.
struct CropView: View {
    let item: ImageItem
    let intent: ImageEditorIntent
    let onSave: (CropSpec) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Orientation-normalized source and the currently rendered edit preview.
    @State private var image: CGImage?
    @State private var displayedImage: CGImage?
    /// Cached Vision result in source orientation. Undoing background removal
    /// keeps the cache so enabling it again is instant.
    @State private var foregroundImage: CGImage?
    /// Selection in image pixel coordinates, top-left origin; may extend
    /// beyond the image bounds up to the working area.
    @State private var selection: CGRect = .zero
    @State private var background: BackgroundChoice = .white
    @State private var customColor: Color = .white
    @State private var addBorder = false
    @State private var addShadow = false
    @State private var rotation: ImageRotation = .none
    @State private var isBackgroundRemoved = false
    @State private var isRemovingBackground = false
    @State private var editorError: String?
    @State private var undoStack: [EditSnapshot] = []

    @State private var activeHandle: Handle?
    @State private var dragStartSelection: CGRect?
    @State private var isAnimatedAsset = false

    /// Minimum selection side, in image pixels.
    private static let minSelectionSide: CGFloat = 16
    /// How far beyond the image the selection may extend, as a fraction of
    /// the longer image side per edge.
    private static let expansionAllowance: CGFloat = 0.5
    private static let maximumUndoDepth = 100

    private var fileExtension: String { item.url.pathExtension.lowercased() }
    private var allowsTransparency: Bool {
        isBackgroundRemoved || Cropper.supportsAlpha(fileExtension)
    }

    private enum BackgroundChoice: Hashable {
        case white, black, transparent, custom
    }

    private struct EditSnapshot {
        let selection: CGRect
        let background: BackgroundChoice
        let customColor: Color
        let addBorder: Bool
        let addShadow: Bool
        let rotation: ImageRotation
        let isBackgroundRemoved: Bool
    }

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
            displayedImage = loaded
            if let loaded {
                selection = CGRect(x: 0, y: 0, width: loaded.width, height: loaded.height)
                if intent == .removeBackground, !animated {
                    await removeBackground()
                }
            }
        }
        .alert(L("Image Editing Failed"), isPresented: Binding(
            get: { editorError != nil },
            set: { if !$0 { editorError = nil } }
        )) {
            Button(L("OK"), role: .cancel) { editorError = nil }
        } message: {
            Text(editorError ?? "")
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
                Text(L("All frames receive the same edits — animation is preserved"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(selection.width.rounded())) × \(Int(selection.height.rounded())) px")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)

            Divider().frame(height: 18)

            ControlGroup {
                Button { undo() } label: {
                    Label(L("Undo"), systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoStack.isEmpty || isRemovingBackground)
                .help(L("Undo last edit (⌘Z)"))

                Button { rotate(.left) } label: {
                    Label(L("Rotate Left"), systemImage: "rotate.left")
                }
                .disabled(displayedImage == nil || isRemovingBackground)
                .help(L("Rotate Left"))

                Button { rotate(.right) } label: {
                    Label(L("Rotate Right"), systemImage: "rotate.right")
                }
                .disabled(displayedImage == nil || isRemovingBackground)
                .help(L("Rotate Right"))
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)

            if isRemovingBackground {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 130)
                    .help(L("Removing background…"))
            } else {
                Button {
                    Task { await removeBackground() }
                } label: {
                    Label(
                        isBackgroundRemoved ? L("Background Removed") : L("Remove Background"),
                        systemImage: isBackgroundRemoved ? "checkmark" : "person.crop.rectangle"
                    )
                }
                .controlSize(.small)
                .disabled(image == nil || isAnimatedAsset || isBackgroundRemoved)
                .help(backgroundRemovalHelp)
            }
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            if let image = displayedImage {
                canvasContent(image: image, viewSize: proxy.size)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .padding(LeafiyDesign.Spacing.m)
        .allowsHitTesting(!isRemovingBackground)
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
                    // Foreground borders are baked from Vision's alpha mask by
                    // rebuildDisplayedImage(), so only regular images need the
                    // legacy rectangular image-edge overlay here.
                    if addBorder, !isBackgroundRemoved {
                        Rectangle()
                            .strokeBorder(Color(white: 0.62), lineWidth: max(unit, 0.5))
                    }
                }
                .shadow(
                    color: addShadow ? .black.opacity(Cropper.standardShadowOpacity) : .clear,
                    radius: addShadow ? Cropper.standardShadowBlur * unit : 0,
                    x: 0,
                    y: addShadow ? Cropper.standardShadowOffset * unit : 0
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
                    guard let handle = hitTest(value.startLocation, selectionRect: selectionRect) else {
                        return
                    }
                    activeHandle = handle
                    dragStartSelection = selection
                    recordUndo()
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
            ColorPicker("", selection: customColorBinding, supportsOpacity: false)
                .labelsHidden()
                .overlay(alignment: .bottom) {
                    if background == .custom {
                        selectionDot
                    }
                }
                .help(L("Custom color"))

            Divider().frame(height: 16)

            Toggle(L("Border"), isOn: borderBinding)
                .toggleStyle(.checkbox)
            Toggle(L("Shadow"), isOn: shadowBinding)
                .toggleStyle(.checkbox)

            Spacer()

            Button(L("Reset Selection")) {
                if let image = displayedImage {
                    let fullImage = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                    guard selection != fullImage else { return }
                    performEdit { selection = fullImage }
                }
            }
            .disabled(displayedImage == nil || isRemovingBackground)
            Button(L("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Save Changes")) { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(displayedImage == nil || isRemovingBackground)
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
    }

    private func swatch(_ choice: BackgroundChoice, fill: Color, label: String) -> some View {
        Button {
            guard background != choice else { return }
            performEdit { background = choice }
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

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { customColor },
            set: { newValue in
                performEdit {
                    customColor = newValue
                    background = .custom
                }
            }
        )
    }

    private var borderBinding: Binding<Bool> {
        Binding(
            get: { addBorder },
            set: { newValue in
                guard newValue != addBorder else { return }
                performEdit { addBorder = newValue }
                rebuildDisplayedImage()
            }
        )
    }

    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { addShadow },
            set: { newValue in
                guard newValue != addShadow else { return }
                performEdit { addShadow = newValue }
            }
        )
    }

    // MARK: - Editing & undo

    private var backgroundRemovalHelp: String {
        if isAnimatedAsset {
            return L("Background removal is unavailable for animated images")
        }
        if isBackgroundRemoved {
            return L("Use Undo to restore the background")
        }
        return L("Remove the background with Apple Vision")
    }

    private func snapshot() -> EditSnapshot {
        EditSnapshot(
            selection: selection,
            background: background,
            customColor: customColor,
            addBorder: addBorder,
            addShadow: addShadow,
            rotation: rotation,
            isBackgroundRemoved: isBackgroundRemoved
        )
    }

    private func recordUndo() {
        if undoStack.count == Self.maximumUndoDepth {
            undoStack.removeFirst()
        }
        undoStack.append(snapshot())
    }

    private func performEdit(_ change: () -> Void) {
        recordUndo()
        change()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        selection = previous.selection
        background = previous.background
        customColor = previous.customColor
        addBorder = previous.addBorder
        addShadow = previous.addShadow
        rotation = previous.rotation
        isBackgroundRemoved = previous.isBackgroundRemoved
        rebuildDisplayedImage()
    }

    private func rotate(_ direction: ImageRotationDirection) {
        guard let current = displayedImage else { return }
        performEdit {
            selection = Cropper.rotate(
                selection,
                in: CGSize(width: current.width, height: current.height),
                direction: direction
            ).integral
            rotation = rotation.rotated(direction)
        }
        rebuildDisplayedImage()
    }

    @MainActor
    private func removeBackground() async {
        guard let image, !isAnimatedAsset, !isBackgroundRemoved, !isRemovingBackground else {
            return
        }

        if foregroundImage == nil {
            isRemovingBackground = true
            do {
                foregroundImage = try await Task.detached(priority: .userInitiated) {
                    try BackgroundRemover.removeBackground(from: image)
                }.value
            } catch {
                editorError = error.localizedDescription
                isRemovingBackground = false
                return
            }
            isRemovingBackground = false
        }

        recordUndo()
        isBackgroundRemoved = true
        // A removed background should be visible and exportable by default.
        background = .transparent
        rebuildDisplayedImage()
    }

    private func rebuildDisplayedImage() {
        guard let source = isBackgroundRemoved ? foregroundImage : image else {
            displayedImage = nil
            return
        }
        do {
            let rotated = try Cropper.rotate(source, rotation: rotation)
            displayedImage = isBackgroundRemoved && addBorder
                ? try Cropper.addingSubjectBorder(to: rotated)
                : rotated
        } catch {
            editorError = error.localizedDescription
        }
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
            shadow: addShadow,
            rotation: rotation,
            foregroundImage: isBackgroundRemoved ? foregroundImage : nil
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
