import SwiftUI

#if os(iOS)
import PencilKit
import UIKit

final class PLCanvasView: PKCanvasView, UIScribbleInteractionDelegate {
    override var canBecomeFirstResponder: Bool { false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        sanitizeGestureRecognizer(gestureRecognizer)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        suppressEditingGestures()
    }

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        false
    }

    func scribbleInteractionShouldDelayFocus(_ interaction: UIScribbleInteraction) -> Bool {
        false
    }

    private func commonInit() {
        addInteraction(UIScribbleInteraction(delegate: self))
        suppressEditingGestures()
    }

    private func suppressEditingGestures() {
        sanitizeGestureRecognizers(in: self)
        for subview in subviews {
            sanitizeGestureRecognizers(in: subview)
        }
    }

    private func sanitizeGestureRecognizers(in view: UIView) {
        view.gestureRecognizers?.forEach { sanitizeGestureRecognizer($0) }
        for subview in view.subviews {
            sanitizeGestureRecognizers(in: subview)
        }
    }

    private func sanitizeGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer === drawingGestureRecognizer || gestureRecognizer === panGestureRecognizer || gestureRecognizer === pinchGestureRecognizer {
            return
        }

        if let tap = gestureRecognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired >= 2 {
            tap.isEnabled = false
            return
        }

        if gestureRecognizer is UILongPressGestureRecognizer {
            gestureRecognizer.isEnabled = false
            return
        }

        let name = String(describing: type(of: gestureRecognizer))
        if name.localizedCaseInsensitiveContains("scribble") ||
            name.localizedCaseInsensitiveContains("edit") ||
            name.localizedCaseInsensitiveContains("loupe") {
            gestureRecognizer.isEnabled = false
        }
    }
}

struct PencilCanvasView: UIViewRepresentable {
    @Binding var drawingData: Data
    var tool: PKTool
    var toolStateID: String = ""
    var drawingPolicy: PKCanvasViewDrawingPolicy = .anyInput
    var allowsFingerDrawing: Bool = true
    var isReadOnly: Bool = false

    var isInfiniteCanvas: Bool = false
    var paperStyle: PLDrawingPaperStyle = .lined
    var paperBaseColor: UIColor = UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
    var paperGuideColor: UIColor = UIColor.black.withAlphaComponent(0.08)
    var lineSpacing: CGFloat = CGFloat(PLDrawingDefaults.lineSpacing)
    var dotSpacing: CGFloat = CGFloat(PLDrawingDefaults.dotSpacing)
    var dotSize: CGFloat = CGFloat(PLDrawingDefaults.dotSize)
    var resetViewportToken: Int = 0
    var onZoomingChanged: ((Bool) -> Void)? = nil

    private let canvasScaleMultiplier: CGFloat = 5.0
    private let minimumCanvasSize = CGSize(width: 1800, height: 1800)

    func makeUIView(context: Context) -> PLCanvasContainerView {
        let container = PLCanvasContainerView()
        context.coordinator.attach(to: container)
        configure(container, coordinator: context.coordinator)
        container.applyDrawingData(drawingData)
        context.coordinator.lastAppliedDrawingData = drawingData
        context.coordinator.lastToolStateID = toolStateID
        context.coordinator.lastResetToken = resetViewportToken
        return container
    }

    func updateUIView(_ uiView: PLCanvasContainerView, context: Context) {
        context.coordinator.onZoomingChanged = onZoomingChanged
        context.coordinator.attach(to: uiView)
        configure(uiView, coordinator: context.coordinator)
        if context.coordinator.isAwaitingBindingUpdate(for: drawingData) {
            // Ignore stale SwiftUI echo while a newer PencilKit drawing is waiting to commit.
        } else if context.coordinator.lastAppliedDrawingData != drawingData {
            uiView.applyDrawingData(drawingData)
            context.coordinator.lastAppliedDrawingData = drawingData
        }

        if context.coordinator.lastResetToken != resetViewportToken {
            context.coordinator.lastResetToken = resetViewportToken
            uiView.resetViewport(animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawingData: $drawingData, onZoomingChanged: onZoomingChanged)
    }

    private func configure(_ container: PLCanvasContainerView, coordinator: Coordinator) {
        container.canvasScaleMultiplier = canvasScaleMultiplier
        container.minimumCanvasSize = minimumCanvasSize
        container.isInfiniteCanvas = isInfiniteCanvas
        container.isReadOnly = isReadOnly
        container.canvasView.tool = tool
        coordinator.lastToolStateID = toolStateID
        container.canvasView.drawingPolicy = drawingPolicy
        container.canvasView.allowsFingerDrawing = allowsFingerDrawing
        container.canvasView.delegate = coordinator
        container.canvasView.backgroundColor = .clear
        container.canvasView.isOpaque = false
        container.canvasView.clipsToBounds = true
        container.canvasView.contentInsetAdjustmentBehavior = .never
        container.canvasView.showsHorizontalScrollIndicator = false
        container.canvasView.showsVerticalScrollIndicator = false
        container.canvasView.delaysContentTouches = false
        container.canvasView.canCancelContentTouches = !isReadOnly
        container.canvasView.decelerationRate = .fast
        container.canvasView.bounces = isInfiniteCanvas && !isReadOnly
        container.canvasView.bouncesZoom = isInfiniteCanvas && !isReadOnly
        container.canvasView.alwaysBounceHorizontal = isInfiniteCanvas && !isReadOnly
        container.canvasView.alwaysBounceVertical = isInfiniteCanvas && !isReadOnly
        container.canvasView.maximumZoomScale = isInfiniteCanvas ? 6.0 : 1.0
        container.canvasView.drawingGestureRecognizer.isEnabled = !isReadOnly
        // Keep drawing responsive: one contact draws, two fingers pan/zoom.
        // In read-only mode, one-finger panning makes iPhone viewing usable.
        container.canvasView.panGestureRecognizer.minimumNumberOfTouches = isReadOnly ? 1 : 2
        container.canvasView.panGestureRecognizer.maximumNumberOfTouches = 2
        container.updateAllowedTouchTypes(
            allowsFingerDrawing: allowsFingerDrawing,
            drawingPolicy: drawingPolicy
        )
        container.overlayView.apply(
            style: paperStyle,
            baseColor: paperBaseColor,
            guideColor: paperGuideColor,
            lineSpacing: lineSpacing,
            dotSpacing: dotSpacing,
            dotSize: dotSize
        )
        container.refreshOverlay()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawingData: Data
        var onZoomingChanged: ((Bool) -> Void)?
        private weak var container: PLCanvasContainerView?
        var lastAppliedDrawingData: Data
        var lastToolStateID: String = ""
        var lastResetToken: Int = 0

        init(drawingData: Binding<Data>, onZoomingChanged: ((Bool) -> Void)?) {
            _drawingData = drawingData
            self.lastAppliedDrawingData = drawingData.wrappedValue
            self.onZoomingChanged = onZoomingChanged
        }

        func attach(to container: PLCanvasContainerView) {
            self.container = container
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let next = canvasView.drawing.dataRepresentation()
            lastAppliedDrawingData = next
            if drawingData != next {
                drawingData = next
            }
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            // Avoid bouncing through SwiftUI state here; that caused a visible pause before panning resumed on iPhone.
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.refreshOverlay()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.refreshOverlay()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            container?.refreshOverlay()
        }

        func isAwaitingBindingUpdate(for data: Data) -> Bool {
            false
        }
    }
}

final class PLCanvasContainerView: UIView {
    let overlayView = PLViewportPaperOverlayView()
    let canvasView = PLCanvasView()

    var canvasScaleMultiplier: CGFloat = 5.0
    var minimumCanvasSize: CGSize = CGSize(width: 1800, height: 1800)
    var isReadOnly: Bool = false {
        didSet {
            if oldValue != isReadOnly {
                hasAppliedInitialZoom = false
                hasAppliedInitialViewportFocus = false
                if let originalDrawingData {
                    applyDrawingData(originalDrawingData)
                } else {
                    setNeedsLayout()
                }
            }
        }
    }
    var isInfiniteCanvas: Bool = false {
        didSet {
            if oldValue != isInfiniteCanvas {
                hasAppliedInitialZoom = false
                hasAppliedInitialViewportFocus = false
            }
        }
    }

    private let readOnlyCropPadding: CGFloat = 56
    private var originalDrawingData: Data?
    private var previousBoundsSize: CGSize = .zero
    private var hasAppliedInitialZoom = false
    private var hasAppliedInitialViewportFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        clipsToBounds = true
        backgroundColor = .clear

        overlayView.isUserInteractionEnabled = false
        addSubview(overlayView)

        addSubview(canvasView)
        // PencilKit can flip light/dark ink appearance under dark traits.
        // The note surface is always rendered as light paper, so keep the canvas in light mode.
        canvasView.overrideUserInterfaceStyle = .light
    }

    func updateAllowedTouchTypes(allowsFingerDrawing: Bool, drawingPolicy: PKCanvasViewDrawingPolicy) {
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencilTouch = NSNumber(value: UITouch.TouchType.pencil.rawValue)

        switch drawingPolicy {
        case .pencilOnly:
            canvasView.drawingGestureRecognizer.allowedTouchTypes = [pencilTouch]
        default:
            canvasView.drawingGestureRecognizer.allowedTouchTypes = allowsFingerDrawing
                ? [directTouch, pencilTouch]
                : [pencilTouch]
        }

        // Never let scroll/pinch gestures consume Pencil touches.
        canvasView.panGestureRecognizer.allowedTouchTypes = [directTouch]
        canvasView.pinchGestureRecognizer?.allowedTouchTypes = [directTouch]
    }

    override func layoutSubviews() {
        let oldSize = previousBoundsSize
        let oldVisibleCenter = CGPoint(
            x: canvasView.contentOffset.x + bounds.width * 0.5,
            y: canvasView.contentOffset.y + bounds.height * 0.5
        )

        super.layoutSubviews()
        canvasView.frame = bounds
        overlayView.frame = bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        if isInfiniteCanvas {
            ensureLargeCanvasLayout(oldSize: oldSize, oldVisibleCenter: oldVisibleCenter)
        } else {
            ensurePlainCanvasLayout()
        }

        refreshOverlay()
        previousBoundsSize = bounds.size
    }

    func applyDrawingData(_ data: Data) {
        originalDrawingData = data
        guard let next = try? PKDrawing(data: data) else { return }
        let displayDrawing = normalizedReadOnlyDrawingIfNeeded(next)
        if displayDrawing.dataRepresentation() != canvasView.drawing.dataRepresentation() {
            canvasView.drawing = displayDrawing
            if isInfiniteCanvas {
                hasAppliedInitialZoom = false
                hasAppliedInitialViewportFocus = false
                setNeedsLayout()
                DispatchQueue.main.async {
                    self.focusViewportOnDrawingIfAvailable(animated: false)
                    self.hasAppliedInitialViewportFocus = true
                    self.refreshOverlay()
                }
            }
        }
    }

    func resetViewport(animated: Bool) {
        guard isInfiniteCanvas else { return }
        let targetZoom = initialViewportZoomScale()
        canvasView.setZoomScale(targetZoom, animated: animated)
        DispatchQueue.main.async {
            self.focusViewportOnDrawingIfAvailable(animated: false)
            self.refreshOverlay()
        }
    }

    func refreshOverlay() {
        overlayView.isHidden = !isInfiniteCanvas
        overlayView.updateViewport(
            contentOffset: canvasView.contentOffset,
            zoomScale: canvasView.zoomScale,
            contentSize: canvasView.contentSize
        )
    }

    private func ensurePlainCanvasLayout() {
        canvasView.isScrollEnabled = false
        canvasView.minimumZoomScale = 1.0
        canvasView.maximumZoomScale = 1.0
        canvasView.zoomScale = 1.0
        canvasView.contentSize = bounds.size
    }

    private func ensureLargeCanvasLayout(oldSize: CGSize, oldVisibleCenter: CGPoint) {
        canvasView.isScrollEnabled = true
        let previousContentSize = canvasView.contentSize
        let targetSize = largeCanvasSize(for: bounds.size)
        if canvasView.contentSize != targetSize {
            canvasView.contentSize = targetSize
        }

        let fillZoom = minimumZoomScaleThatFillsBounds(fallback: 0.2)
        if abs(canvasView.minimumZoomScale - fillZoom) > 0.001 {
            canvasView.minimumZoomScale = fillZoom
        }
        let shouldResnapToInitialViewport =
            !hasAppliedInitialZoom ||
            (previousContentSize != targetSize && canvasView.zoomScale <= canvasView.minimumZoomScale + 0.02) ||
            (oldSize != .zero && oldSize != bounds.size && canvasView.zoomScale <= canvasView.minimumZoomScale + 0.02)

        if shouldResnapToInitialViewport {
            canvasView.setZoomScale(initialViewportZoomScale(), animated: false)
            hasAppliedInitialZoom = true
        } else if canvasView.zoomScale < fillZoom {
            canvasView.setZoomScale(fillZoom, animated: false)
        }

        if !hasAppliedInitialViewportFocus {
            focusViewportOnDrawingIfAvailable(animated: false)
            hasAppliedInitialViewportFocus = true
        } else if oldSize != .zero, oldSize != bounds.size {
            canvasView.setContentOffset(clampedOffset(forVisibleCenter: oldVisibleCenter), animated: false)
        }
    }

    private func largeCanvasSize(for bounds: CGSize) -> CGSize {
        let drawingBounds = canvasView.drawing.bounds

        if isReadOnly, !drawingBounds.isEmpty {
            let compactWidth = drawingBounds.maxX + readOnlyCropPadding
            let compactHeight = drawingBounds.maxY + readOnlyCropPadding
            return CGSize(
                width: max(bounds.width, compactWidth),
                height: max(bounds.height, compactHeight)
            )
        }

        let screenSize = UIScreen.main.bounds.size
        let seed = CGSize(
            width: max(bounds.width, screenSize.width),
            height: max(bounds.height, screenSize.height)
        )
        let drawingPadding: CGFloat = 240
        let requiredDrawingSize: CGSize
        if drawingBounds.isEmpty {
            requiredDrawingSize = .zero
        } else {
            requiredDrawingSize = CGSize(
                width: max(drawingBounds.maxX + drawingPadding, drawingBounds.width + drawingPadding * 2),
                height: max(drawingBounds.maxY + drawingPadding, drawingBounds.height + drawingPadding * 2)
            )
        }
        return CGSize(
            width: max(seed.width * canvasScaleMultiplier, minimumCanvasSize.width, requiredDrawingSize.width),
            height: max(seed.height * canvasScaleMultiplier, minimumCanvasSize.height, requiredDrawingSize.height)
        )
    }

    private func minimumZoomScaleThatFillsBounds(fallback: CGFloat) -> CGFloat {
        guard canvasView.contentSize.width > 1, canvasView.contentSize.height > 1, bounds.width > 1, bounds.height > 1 else {
            return fallback
        }

        let fillWidth = bounds.width / canvasView.contentSize.width
        let fillHeight = bounds.height / canvasView.contentSize.height
        return max(fallback, fillWidth, fillHeight)
    }

    private func initialViewportZoomScale() -> CGFloat {
        let fillZoom = minimumZoomScaleThatFillsBounds(fallback: 0.2)
        guard isReadOnly else { return fillZoom }

        let drawingBounds = canvasView.drawing.bounds
        guard !drawingBounds.isEmpty, bounds.width > 1, bounds.height > 1 else {
            return fillZoom
        }

        let padded = drawingBounds.insetBy(dx: -readOnlyCropPadding, dy: -readOnlyCropPadding)
        let fitWidth = bounds.width / max(padded.width, 1)
        let fitHeight = bounds.height / max(padded.height, 1)
        let fitZoom = min(fitWidth, fitHeight)
        return min(max(fitZoom, fillZoom), canvasView.maximumZoomScale)
    }

    private func focusViewportOnDrawingIfAvailable(animated: Bool) {
        let drawingBounds = canvasView.drawing.bounds
        let center: CGPoint
        if drawingBounds.isEmpty {
            center = CGPoint(x: canvasView.contentSize.width * 0.5, y: canvasView.contentSize.height * 0.5)
        } else {
            center = CGPoint(x: drawingBounds.midX, y: drawingBounds.midY)
        }
        canvasView.setContentOffset(clampedOffset(forDocumentCenter: center), animated: animated)
    }

    private func normalizedReadOnlyDrawingIfNeeded(_ drawing: PKDrawing) -> PKDrawing {
        guard isReadOnly, isInfiniteCanvas else { return drawing }
        let drawingBounds = drawing.bounds
        guard !drawingBounds.isEmpty else { return drawing }

        let transform = CGAffineTransform(
            translationX: readOnlyCropPadding - drawingBounds.minX,
            y: readOnlyCropPadding - drawingBounds.minY
        )
        return drawing.transformed(using: transform)
    }

    private func clampedOffset(forDocumentCenter center: CGPoint) -> CGPoint {
        let scaledCenter = CGPoint(x: center.x * canvasView.zoomScale, y: center.y * canvasView.zoomScale)
        return clampedOffset(forVisibleCenter: scaledCenter)
    }

    private func clampedOffset(forVisibleCenter center: CGPoint) -> CGPoint {
        let proposed = CGPoint(
            x: center.x - bounds.width * 0.5,
            y: center.y - bounds.height * 0.5
        )

        let maxX = max(0, canvasView.contentSize.width * canvasView.zoomScale - bounds.width)
        let maxY = max(0, canvasView.contentSize.height * canvasView.zoomScale - bounds.height)

        return CGPoint(
            x: min(max(0, proposed.x), maxX),
            y: min(max(0, proposed.y), maxY)
        )
    }
}

final class PLViewportPaperOverlayView: UIView {
    private var currentStyle: PLDrawingPaperStyle = .lined
    private var currentBaseColor: UIColor = .white
    private var currentGuideColor: UIColor = UIColor.black.withAlphaComponent(0.08)
    private var currentLineSpacing: CGFloat = CGFloat(PLDrawingDefaults.lineSpacing)
    private var currentDotSpacing: CGFloat = CGFloat(PLDrawingDefaults.dotSpacing)
    private var currentDotSize: CGFloat = CGFloat(PLDrawingDefaults.dotSize)

    private var viewportOffset: CGPoint = .zero
    private var viewportZoomScale: CGFloat = 1.0
    private var redrawQueued = false

    func apply(
        style: PLDrawingPaperStyle,
        baseColor: UIColor,
        guideColor: UIColor,
        lineSpacing: CGFloat,
        dotSpacing: CGFloat,
        dotSize: CGFloat
    ) {
        currentStyle = style
        currentBaseColor = baseColor
        currentGuideColor = guideColor
        currentLineSpacing = max(8, lineSpacing)
        currentDotSpacing = max(8, dotSpacing)
        currentDotSize = max(0.8, dotSize)
        queueRedraw()
    }

    func updateViewport(contentOffset: CGPoint, zoomScale: CGFloat, contentSize: CGSize) {
        let newZoom = max(zoomScale, 0.01)
        if viewportOffset != contentOffset || abs(viewportZoomScale - newZoom) > 0.0001 {
            viewportOffset = contentOffset
            viewportZoomScale = newZoom
            queueRedraw()
        }
    }

    private func queueRedraw() {
        guard !redrawQueued else { return }
        redrawQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawQueued = false
            self.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        currentBaseColor.setFill()
        context.fill(bounds)

        switch currentStyle {
        case .blank:
            return

        case .lined:
            drawLines(in: context)

        case .dotGrid:
            drawDots(in: context)
        }
    }

    private func drawLines(in context: CGContext) {
        let spacing = max(6, currentLineSpacing * viewportZoomScale)
        let pixel = 1.0 / UIScreen.main.scale
        let phaseY = positiveRemainder(-viewportOffset.y, spacing)

        context.setStrokeColor(currentGuideColor.cgColor)
        context.setLineWidth(pixel)

        var y = phaseY
        while y <= bounds.height + spacing {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
            y += spacing
        }
        context.strokePath()
    }

    private func drawDots(in context: CGContext) {
        let spacing = max(6, currentDotSpacing * viewportZoomScale)
        let size = max(0.8, currentDotSize * max(viewportZoomScale, 0.35))
        let phaseX = positiveRemainder(-viewportOffset.x, spacing)
        let phaseY = positiveRemainder(-viewportOffset.y, spacing)

        context.setFillColor(currentGuideColor.cgColor)

        var y = phaseY
        while y <= bounds.height + spacing {
            var x = phaseX
            while x <= bounds.width + spacing {
                let rect = CGRect(x: x - size * 0.5, y: y - size * 0.5, width: size, height: size)
                context.fillEllipse(in: rect)
                x += spacing
            }
            y += spacing
        }
    }

    private func positiveRemainder(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        guard modulus > 0 else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder >= 0 ? remainder : remainder + modulus
    }
}

#else

struct PencilCanvasView: View {
    @Binding var drawingData: Data
    var tool: Any? = nil
    var drawingPolicy: Any? = nil
    var allowsFingerDrawing: Bool = true
    var isReadOnly: Bool = false
    var isInfiniteCanvas: Bool = false
    var paperStyle: PLDrawingPaperStyle = .lined
    var paperBaseColor: Color = .white
    var paperGuideColor: Color = .gray
    var lineSpacing: CGFloat = CGFloat(PLDrawingDefaults.lineSpacing)
    var dotSpacing: CGFloat = CGFloat(PLDrawingDefaults.dotSpacing)
    var dotSize: CGFloat = CGFloat(PLDrawingDefaults.dotSize)
    var resetViewportToken: Int = 0
    var onZoomingChanged: ((Bool) -> Void)? = nil

    var body: some View {
        Rectangle().fill(.clear)
    }
}

#endif
