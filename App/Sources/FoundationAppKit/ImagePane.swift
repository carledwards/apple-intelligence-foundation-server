import SwiftUI

/// Displays an image with zoom, pan, and a rectangular selection.
///
/// The selection is held in normalized 0–1 coordinates rather than points, so it
/// survives resizing the pane, zooming, and the difference between the displayed
/// copy and the full-resolution original it is ultimately cut from.
public struct ImagePane: View {
    public enum Mode: String, CaseIterable, Identifiable {
        case select = "Select"
        case pan = "Pan"
        public var id: String { rawValue }
    }

    let image: LoadedImage
    @Binding var selection: CGRect?

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero
    @State private var mode: Mode = .select
    @State private var dragStart: CGPoint?
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(image: LoadedImage, selection: Binding<CGRect?>) {
        self.image = image
        self._selection = selection
    }

    public var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let frame = fittedFrame(in: geo.size)
                ZStack {
                    Color.black.opacity(0.04)
                    Image(decorative: image.display, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .offset(pan)
                    if let selection {
                        selectionOverlay(selection, frame: frame, container: geo.size)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture(frame: frame, container: geo.size))
                .simultaneousGesture(magnifyGesture(frame: frame, container: geo.size))
                .onChange(of: zoom) { _, _ in
                    // Keeps the slider honest: changing zoom from the slider must
                    // not leave the image parked outside the visible area.
                    pan = clamp(pan, frame: frame, container: geo.size, zoom: zoom)
                    committedPan = pan
                }
            }
            controls
        }
    }

    // MARK: Geometry

    /// Where the image sits at zoom 1, before scale and pan are applied.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let aspect = CGFloat(image.display.width) / CGFloat(image.display.height)
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    /// Container point -> normalized image coordinate, undoing zoom and pan.
    private func normalize(_ point: CGPoint, frame: CGRect, container: CGSize) -> CGPoint {
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let unscaled = CGPoint(
            x: center.x + (point.x - center.x - pan.width) / zoom,
            y: center.y + (point.y - center.y - pan.height) / zoom
        )
        return CGPoint(
            x: min(max((unscaled.x - frame.minX) / frame.width, 0), 1),
            y: min(max((unscaled.y - frame.minY) / frame.height, 0), 1)
        )
    }

    /// Normalized image coordinate -> container point, applying zoom and pan.
    private func denormalize(_ point: CGPoint, frame: CGRect, container: CGSize) -> CGPoint {
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let unscaled = CGPoint(x: frame.minX + point.x * frame.width,
                               y: frame.minY + point.y * frame.height)
        return CGPoint(
            x: center.x + (unscaled.x - center.x) * zoom + pan.width,
            y: center.y + (unscaled.y - center.y) * zoom + pan.height
        )
    }

    // MARK: Gestures

    /// Zooms about the pointer rather than the view centre.
    ///
    /// Anchoring at the centre means the thing you are trying to look at slides
    /// away as you zoom in, which is precisely backwards. Holding the content
    /// point under the cursor fixed is what makes zoom feel like magnification
    /// rather than a scroll.
    private func magnifyGesture(frame: CGRect, container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let target = max(1, min(12, committedZoom * value.magnification))
                guard target != zoom else { return }
                let center = CGPoint(x: container.width / 2, y: container.height / 2)
                let dx = value.startLocation.x - center.x
                let dy = value.startLocation.y - center.y
                let ratio = target / zoom
                // Solves screen = C + (content - C) * z + pan for the pan that
                // leaves the content point under `startLocation` where it is.
                pan = CGSize(width: dx - (dx - pan.width) * ratio,
                             height: dy - (dy - pan.height) * ratio)
                zoom = target
                pan = clamp(pan, frame: frame, container: container, zoom: zoom)
            }
            .onEnded { _ in
                committedZoom = zoom
                committedPan = pan
            }
    }

    /// Keeps the scaled image overlapping the viewport: no panning it off into
    /// nowhere, and anything smaller than the viewport stays centred.
    private func clamp(_ pan: CGSize, frame: CGRect, container: CGSize, zoom: CGFloat) -> CGSize {
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let origin = CGPoint(x: center.x + (frame.minX - center.x) * zoom,
                             y: center.y + (frame.minY - center.y) * zoom)
        let size = CGSize(width: frame.width * zoom, height: frame.height * zoom)

        func axis(origin: CGFloat, size: CGFloat, viewport: CGFloat, value: CGFloat) -> CGFloat {
            if size <= viewport { return (viewport - size) / 2 - origin }
            return min(max(value, viewport - origin - size), -origin)
        }
        return CGSize(
            width: axis(origin: origin.x, size: size.width, viewport: container.width, value: pan.width),
            height: axis(origin: origin.y, size: size.height, viewport: container.height, value: pan.height)
        )
    }

    private func dragGesture(frame: CGRect, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                switch mode {
                case .pan:
                    pan = clamp(
                        CGSize(width: committedPan.width + value.translation.width,
                               height: committedPan.height + value.translation.height),
                        frame: frame, container: container, zoom: zoom
                    )
                case .select:
                    let start = dragStart ?? normalize(value.startLocation, frame: frame, container: container)
                    dragStart = start
                    let current = normalize(value.location, frame: frame, container: container)
                    selection = CGRect(
                        x: min(start.x, current.x), y: min(start.y, current.y),
                        width: abs(current.x - start.x), height: abs(current.y - start.y)
                    )
                }
            }
            .onEnded { _ in
                dragStart = nil
                committedPan = pan
                // A stray click leaves a degenerate rect; treat it as clearing.
                if let selection, selection.width < 0.01 || selection.height < 0.01 {
                    self.selection = nil
                }
            }
    }

    // MARK: Overlays

    private func selectionOverlay(_ rect: CGRect, frame: CGRect, container: CGSize) -> some View {
        let a = denormalize(CGPoint(x: rect.minX, y: rect.minY), frame: frame, container: container)
        let b = denormalize(CGPoint(x: rect.maxX, y: rect.maxY), frame: frame, container: container)
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                         width: abs(b.x - a.x), height: abs(b.y - a.y))
        return ZStack {
            Rectangle()
                .fill(.black.opacity(0.35))
                .reverseMask { Rectangle().frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY) }
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Slider(value: $zoom, in: 1...12) { editing in
                if !editing { committedZoom = zoom }
            }
            .frame(maxWidth: 160)
            Text(String(format: "%.1f×", zoom))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Fit") {
                withAnimation(.easeOut(duration: 0.15)) {
                    zoom = 1; committedZoom = 1; pan = .zero; committedPan = .zero
                }
            }
            .font(.caption)

            if selection != nil {
                // The short label is for phone width, where the full one
                // pushes the row past the screen edge.
                Button(sizeClass == .compact ? "Clear" : "Clear selection") { selection = nil }
                    .font(.caption)
            }
        }
    }
}

private extension View {
    /// Punches a hole in a fill, so the selected region stays unshaded.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            ZStack {
                Rectangle()
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}
