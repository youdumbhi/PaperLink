import SwiftUI

#if os(iOS)
import PencilKit
import UIKit

final class PLCanvasView: PKCanvasView, UIScribbleInteractionDelegate {
    override var canBecomeFirstResponder: Bool { false }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override init(frame: CGRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        sanitizeGestureRecognizer(gestureRecognizer)
    }

    override func didMoveToWindow() { super.didMoveToWindow(); suppressEditingGestures() }
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool { false }
    func scribbleInteractionShouldDelayFocus(_ interaction: UIScribbleInteraction) -> Bool { false }

    private func commonInit() {
        addInteraction(UIScribbleInteraction(delegate: self))
        suppressEditingGestures()
    }

    private func suppressEditingGestures() {
        sanitizeGestureRecognizers(in: self)
        subviews.forEach { sanitizeGestureRecognizers(in: $0) }
    }

    private func sanitizeGestureRecognizers(in view: UIView) {
        view.gestureRecognizers?.forEach { sanitizeGestureRecognizer($0) }
        view.subviews.forEach { sanitizeGestureRecognizers(in: $0) }
    }

    private func sanitizeGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer === drawingGestureRecognizer || gestureRecognizer === panGestureRecognizer || gestureRecognizer === pinchGestureRecognizer { return }
        if let tap = gestureRecognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired >= 2 { tap.isEnabled = false; return }
        if gestureRecognizer is UILongPressGestureRecognizer { gestureRecognizer.isEnabled = false; return }
        let name = String(describing: type(of: gestureRecognizer))
        if name.localizedCaseInsensitiveContains("scribble") || name.localizedCaseInsensitiveContains("edit") || name.localizedCaseInsensitiveContains("loupe") {
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
            // Ignore stale SwiftUI echo.
        } else if context.coordinator.lastAppliedDrawingData != drawingData {
            uiView.applyDrawingData(drawingData)
            context.coordinator.lastAppliedDrawingData = drawingData
        }
        if context.coordinator.lastResetToken != resetViewportToken {
            context.coordinator.lastResetToken = resetViewportToken
            uiView.resetViewport(animated: true)
            context.coordinator.onZoomingChanged?(false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(drawingData: $drawingData, onZoomingChanged: onZoomingChanged) }

    private func configure(_ container: PLCanvasContainerView, coordinator: Coordinator) {
        container.canvasScaleMultiplier = canvasScaleMultiplier
        container.minimumCanvasSize = minimumCanvasSize
        container.configurePaper(style: paperStyle, baseColor: paperBaseColor, guideColor: paperGuideColor, lineSpacing: lineSpacing, dotSpacing: dotSpacing, dotSize: dotSize)
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
        container.canvasView.canCancelContentTouches = true
        container.canvasView.bounces = isInfiniteCanvas
        container.canvasView.bouncesZoom = isInfiniteCanvas
        container.canvasView.alwaysBounceHorizontal = isInfiniteCanvas
        container.canvasView.alwaysBounceVertical = isInfiniteCanvas
        container.canvasView.maximumZoomScale = isInfiniteCanvas ? 6.0 : 1.0
        container.canvasView.drawingGestureRecognizer.isEnabled = !isReadOnly
        container.canvasView.panGestureRecognizer.minimumNumberOfTouches = isReadOnly ? 1 : 2
        container.canvasView.panGestureRecognizer.maximumNumberOfTouches = 2
        container.updateAllowedTouchTypes(allowsFingerDrawing: allowsFingerDrawing, drawingPolicy: drawingPolicy)
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

        func attach(to container: PLCanvasContainerView) { self.container = container }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let next = canvasView.drawing.dataRepresentation()
            lastAppliedDrawingData = next
            if drawingData != next { drawingData = next }
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { onZoomingChanged?(true) }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { container?.refreshOverlay() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { container?.refreshOverlay() }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { container?.refreshOverlay(); onZoomingChanged?(false) }
        func isAwaitingBindingUpdate(for data: Data) -> Bool { false }
    }
}

final class PLCanvasContainerView: UIView, UIScrollViewDelegate {
    let overlayView = PLViewportPaperOverlayView()
    let canvasView = PLCanvasView()
    private let readOnlyScrollView = UIScrollView()
    private let readOnlyImageView = UIImageView()

    var canvasScaleMultiplier: CGFloat = 5.0
    var minimumCanvasSize: CGSize = CGSize(width: 1800, height: 1800)
    var isReadOnly: Bool = false {
        didSet { if oldValue != isReadOnly { resetModeState() } }
    }
    var isInfiniteCanvas: Bool = false {
        didSet { if oldValue != isInfiniteCanvas { resetModeState() } }
    }

    private var previousBoundsSize: CGSize = .zero
    private var hasAppliedInitialZoom = false
    private var hasAppliedInitialViewportFocus = false
    private var latestDrawingData: Data?
    private var readOnlySnapshotDirty = true
    private var lastRenderedSnapshotKey: String?

    private var currentPaperStyle: PLDrawingPaperStyle = .lined
    private var currentPaperBaseColor: UIColor = UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
    private var currentPaperGuideColor: UIColor = UIColor.black.withAlphaComponent(0.08)
    private var currentLineSpacing: CGFloat = CGFloat(PLDrawingDefaults.lineSpacing)
    private var currentDotSpacing: CGFloat = CGFloat(PLDrawingDefaults.dotSpacing)
    private var currentDotSize: CGFloat = CGFloat(PLDrawingDefaults.dotSize)

    private var usesReadOnlySnapshotViewer: Bool { isReadOnly && isInfiniteCanvas }
    private let readOnlyCropPadding: CGFloat = 24
    private let alphaCropSearchPadding: CGFloat = 360
    private let maxCropAnalysisPixels: CGFloat = 2200

    override init(frame: CGRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        clipsToBounds = true
        backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        addSubview(overlayView)
        addSubview(canvasView)
        canvasView.overrideUserInterfaceStyle = .light

        readOnlyScrollView.delegate = self
        readOnlyScrollView.backgroundColor = .clear
        readOnlyScrollView.showsHorizontalScrollIndicator = false
        readOnlyScrollView.showsVerticalScrollIndicator = false
        readOnlyScrollView.contentInsetAdjustmentBehavior = .never
        readOnlyScrollView.delaysContentTouches = false
        readOnlyScrollView.canCancelContentTouches = true
        readOnlyScrollView.bounces = true
        readOnlyScrollView.bouncesZoom = true
        readOnlyScrollView.maximumZoomScale = 6.0
        readOnlyScrollView.minimumZoomScale = 1.0
        readOnlyImageView.contentMode = .topLeft
        readOnlyImageView.isUserInteractionEnabled = true
        readOnlyScrollView.addSubview(readOnlyImageView)
        addSubview(readOnlyScrollView)
        updateModeVisibility()
    }

    private func resetModeState() {
        hasAppliedInitialZoom = false
        hasAppliedInitialViewportFocus = false
        updateModeVisibility()
        markReadOnlySnapshotDirty()
        setNeedsLayout()
    }

    func configurePaper(style: PLDrawingPaperStyle, baseColor: UIColor, guideColor: UIColor, lineSpacing: CGFloat, dotSpacing: CGFloat, dotSize: CGFloat) {
        let normalizedLineSpacing = max(8, lineSpacing)
        let normalizedDotSpacing = max(8, dotSpacing)
        let normalizedDotSize = max(0.8, dotSize)
        let changed = currentPaperStyle != style || currentPaperBaseColor != baseColor || currentPaperGuideColor != guideColor || abs(currentLineSpacing - normalizedLineSpacing) > 0.001 || abs(currentDotSpacing - normalizedDotSpacing) > 0.001 || abs(currentDotSize - normalizedDotSize) > 0.001
        currentPaperStyle = style
        currentPaperBaseColor = baseColor
        currentPaperGuideColor = guideColor
        currentLineSpacing = normalizedLineSpacing
        currentDotSpacing = normalizedDotSpacing
        currentDotSize = normalizedDotSize
        overlayView.apply(style: style, baseColor: baseColor, guideColor: guideColor, lineSpacing: normalizedLineSpacing, dotSpacing: normalizedDotSpacing, dotSize: normalizedDotSize)
        if changed { markReadOnlySnapshotDirty() }
    }

    func updateAllowedTouchTypes(allowsFingerDrawing: Bool, drawingPolicy: PKCanvasViewDrawingPolicy) {
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencilTouch = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        switch drawingPolicy {
        case .pencilOnly: canvasView.drawingGestureRecognizer.allowedTouchTypes = [pencilTouch]
        default: canvasView.drawingGestureRecognizer.allowedTouchTypes = allowsFingerDrawing ? [directTouch, pencilTouch] : [pencilTouch]
        }
        canvasView.panGestureRecognizer.allowedTouchTypes = [directTouch]
        canvasView.pinchGestureRecognizer?.allowedTouchTypes = [directTouch]
    }

    override func layoutSubviews() {
        let oldSize = previousBoundsSize
        let oldVisibleCenter = CGPoint(x: canvasView.contentOffset.x + bounds.width * 0.5, y: canvasView.contentOffset.y + bounds.height * 0.5)
        super.layoutSubviews()
        canvasView.frame = bounds
        overlayView.frame = bounds
        readOnlyScrollView.frame = bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        if usesReadOnlySnapshotViewer {
            renderReadOnlySnapshotIfNeeded()
            previousBoundsSize = bounds.size
            return
        }

        if isInfiniteCanvas { ensureLargeCanvasLayout(oldSize: oldSize, oldVisibleCenter: oldVisibleCenter) } else { ensurePlainCanvasLayout() }
        refreshOverlay()
        previousBoundsSize = bounds.size
    }

    func applyDrawingData(_ data: Data) {
        latestDrawingData = data
        if usesReadOnlySnapshotViewer { markReadOnlySnapshotDirty(); renderReadOnlySnapshotIfNeeded(); return }
        guard let next = try? PKDrawing(data: data) else { return }
        if next.dataRepresentation() != canvasView.drawing.dataRepresentation() {
            canvasView.drawing = next
            if isInfiniteCanvas {
                setNeedsLayout()
                if !hasAppliedInitialViewportFocus { focusViewportOnDrawingIfAvailable(animated: false); hasAppliedInitialViewportFocus = true }
            }
        }
    }

    func resetViewport(animated: Bool) {
        if usesReadOnlySnapshotViewer { resetReadOnlySnapshotViewport(animated: animated); return }
        guard isInfiniteCanvas else { return }
        canvasView.setZoomScale(initialViewportZoomScale(), animated: animated)
        DispatchQueue.main.async { self.focusViewportOnDrawingIfAvailable(animated: animated); self.refreshOverlay() }
    }

    func refreshOverlay() {
        overlayView.isHidden = !isInfiniteCanvas || usesReadOnlySnapshotViewer
        overlayView.updateViewport(contentOffset: canvasView.contentOffset, zoomScale: canvasView.zoomScale, contentSize: canvasView.contentSize)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { scrollView === readOnlyScrollView ? readOnlyImageView : nil }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { if scrollView === readOnlyScrollView { centerReadOnlyImageIfNeeded() } }

    private func updateModeVisibility() {
        let showReadOnlyViewer = usesReadOnlySnapshotViewer
        readOnlyScrollView.isHidden = !showReadOnlyViewer
        canvasView.isHidden = showReadOnlyViewer
        overlayView.isHidden = showReadOnlyViewer || !isInfiniteCanvas
    }

    private func markReadOnlySnapshotDirty() { readOnlySnapshotDirty = true; lastRenderedSnapshotKey = nil }

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
        if canvasView.contentSize != targetSize { canvasView.contentSize = targetSize }
        let fillZoom = minimumZoomScaleThatFillsBounds(fallback: 0.2)
        if abs(canvasView.minimumZoomScale - fillZoom) > 0.001 { canvasView.minimumZoomScale = fillZoom }
        let shouldResnap = !hasAppliedInitialZoom || (previousContentSize != targetSize && canvasView.zoomScale <= canvasView.minimumZoomScale + 0.02) || (oldSize != .zero && oldSize != bounds.size && canvasView.zoomScale <= canvasView.minimumZoomScale + 0.02)
        if shouldResnap { canvasView.setZoomScale(initialViewportZoomScale(), animated: false); hasAppliedInitialZoom = true }
        else if canvasView.zoomScale < fillZoom { canvasView.setZoomScale(fillZoom, animated: false) }
        if !hasAppliedInitialViewportFocus { focusViewportOnDrawingIfAvailable(animated: false); hasAppliedInitialViewportFocus = true }
        else if oldSize != .zero, oldSize != bounds.size { canvasView.setContentOffset(clampedOffset(forVisibleCenter: oldVisibleCenter), animated: false) }
    }

    private func largeCanvasSize(for bounds: CGSize) -> CGSize {
        let screenSize = UIScreen.main.bounds.size
        let seed = CGSize(width: max(bounds.width, screenSize.width), height: max(bounds.height, screenSize.height))
        let drawingBounds = canvasView.drawing.bounds
        let drawingPadding: CGFloat = isReadOnly ? 420 : 240
        let requiredDrawingSize = drawingBounds.isEmpty ? .zero : CGSize(width: max(drawingBounds.maxX + drawingPadding, drawingBounds.width + drawingPadding * 2), height: max(drawingBounds.maxY + drawingPadding, drawingBounds.height + drawingPadding * 2))
        return CGSize(width: max(seed.width * canvasScaleMultiplier, minimumCanvasSize.width, requiredDrawingSize.width), height: max(seed.height * canvasScaleMultiplier, minimumCanvasSize.height, requiredDrawingSize.height))
    }

    private func minimumZoomScaleThatFillsBounds(fallback: CGFloat) -> CGFloat {
        guard canvasView.contentSize.width > 1, canvasView.contentSize.height > 1, bounds.width > 1, bounds.height > 1 else { return fallback }
        return max(fallback, bounds.width / canvasView.contentSize.width, bounds.height / canvasView.contentSize.height)
    }

    private func initialViewportZoomScale() -> CGFloat {
        let fillZoom = minimumZoomScaleThatFillsBounds(fallback: 0.2)
        guard isReadOnly else { return fillZoom }
        let drawingBounds = canvasView.drawing.bounds
        guard !drawingBounds.isEmpty, bounds.width > 1, bounds.height > 1 else { return fillZoom }
        let padded = drawingBounds.insetBy(dx: -160, dy: -160)
        let fitZoom = min(bounds.width / max(padded.width, 1), bounds.height / max(padded.height, 1))
        return min(max(fitZoom, fillZoom), canvasView.maximumZoomScale)
    }

    private func focusViewportOnDrawingIfAvailable(animated: Bool) {
        let drawingBounds = canvasView.drawing.bounds
        let center: CGPoint
        if drawingBounds.isEmpty { center = CGPoint(x: canvasView.contentSize.width * 0.5, y: canvasView.contentSize.height * 0.5) }
        else { let padded = drawingBounds.insetBy(dx: isReadOnly ? -160 : -120, dy: isReadOnly ? -160 : -120); center = CGPoint(x: padded.midX, y: padded.midY) }
        canvasView.setContentOffset(clampedOffset(forDocumentCenter: center), animated: animated)
    }

    private func renderReadOnlySnapshotIfNeeded() {
        guard usesReadOnlySnapshotViewer, bounds.width > 1, bounds.height > 1 else { return }
        guard let latestDrawingData, let drawing = try? PKDrawing(data: latestDrawingData) else { return }
        let drawingBounds = drawing.bounds
        let searchRect = drawingBounds.isEmpty ? CGRect(origin: .zero, size: bounds.size) : drawingBounds.insetBy(dx: -alphaCropSearchPadding, dy: -alphaCropSearchPadding)
        let searchScale = min(UIScreen.main.scale, max(0.25, maxCropAnalysisPixels / max(searchRect.width, searchRect.height, 1)))
        let transparentSearchImage = drawing.image(from: searchRect, scale: searchScale)
        let cropRect = alphaBounds(in: transparentSearchImage, sourceRect: searchRect, padding: readOnlyCropPadding) ?? searchRect
        let normalizedSize = CGSize(width: max(1, ceil(cropRect.width)), height: max(1, ceil(cropRect.height)))
        let snapshotKey = "\(latestDrawingData.hashValue)-\(Int(cropRect.minX))-\(Int(cropRect.minY))-\(Int(normalizedSize.width))-\(Int(normalizedSize.height))-\(currentPaperStyle.rawValue)-\(Int(currentLineSpacing))-\(Int(currentDotSpacing))-\(Int(currentDotSize * 10))"
        guard readOnlySnapshotDirty || lastRenderedSnapshotKey != snapshotKey else { layoutReadOnlySnapshotViewport(); return }

        let renderer = UIGraphicsImageRenderer(size: normalizedSize)
        let drawingImage = drawing.image(from: cropRect, scale: UIScreen.main.scale)
        let rendered = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            currentPaperBaseColor.setFill()
            context.fill(CGRect(origin: .zero, size: normalizedSize))
            drawPaperGuides(in: context, size: normalizedSize, cropOrigin: cropRect.origin)
            drawingImage.draw(in: CGRect(origin: .zero, size: normalizedSize))
        }

        readOnlyImageView.image = rendered
        readOnlyImageView.frame = CGRect(origin: .zero, size: normalizedSize)
        readOnlyScrollView.contentSize = normalizedSize
        readOnlySnapshotDirty = false
        lastRenderedSnapshotKey = snapshotKey
        layoutReadOnlySnapshotViewport(resetZoom: true)
    }

    private func alphaBounds(in image: UIImage, sourceRect: CGRect, padding: CGFloat) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        let alphaThreshold: UInt8 = 8
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > alphaThreshold {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pointWidth = sourceRect.width / CGFloat(width)
        let pointHeight = sourceRect.height / CGFloat(height)
        let rect = CGRect(x: sourceRect.minX + CGFloat(minX) * pointWidth, y: sourceRect.minY + CGFloat(minY) * pointHeight, width: CGFloat(maxX - minX + 1) * pointWidth, height: CGFloat(maxY - minY + 1) * pointHeight)
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    private func drawPaperGuides(in context: CGContext, size: CGSize, cropOrigin: CGPoint) {
        switch currentPaperStyle {
        case .blank: return
        case .lined: drawReadOnlyLines(in: context, size: size, cropOrigin: cropOrigin)
        case .dotGrid: drawReadOnlyDots(in: context, size: size, cropOrigin: cropOrigin)
        }
    }

    private func drawReadOnlyLines(in context: CGContext, size: CGSize, cropOrigin: CGPoint) {
        let spacing = max(6, currentLineSpacing)
        let pixel = 1.0 / UIScreen.main.scale
        let phaseY = positiveRemainder(-cropOrigin.y, spacing)
        context.setStrokeColor(currentPaperGuideColor.cgColor)
        context.setLineWidth(pixel)
        var y = phaseY
        while y <= size.height + spacing { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
        context.strokePath()
    }

    private func drawReadOnlyDots(in context: CGContext, size: CGSize, cropOrigin: CGPoint) {
        let spacing = max(6, currentDotSpacing)
        let dotSize = max(0.8, currentDotSize)
        let phaseX = positiveRemainder(-cropOrigin.x, spacing)
        let phaseY = positiveRemainder(-cropOrigin.y, spacing)
        context.setFillColor(currentPaperGuideColor.cgColor)
        var y = phaseY
        while y <= size.height + spacing {
            var x = phaseX
            while x <= size.width + spacing { context.fillEllipse(in: CGRect(x: x - dotSize * 0.5, y: y - dotSize * 0.5, width: dotSize, height: dotSize)); x += spacing }
            y += spacing
        }
    }

    private func layoutReadOnlySnapshotViewport(resetZoom: Bool = false) {
        let contentSize = readOnlyImageView.bounds.size
        guard contentSize.width > 1, contentSize.height > 1, bounds.width > 1, bounds.height > 1 else { return }
        let fitZoom = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let minZoom = min(max(fitZoom, 0.1), 1.0)
        readOnlyScrollView.minimumZoomScale = minZoom
        readOnlyScrollView.maximumZoomScale = max(6.0, minZoom * 6.0)
        if resetZoom || readOnlyScrollView.zoomScale < minZoom || readOnlyScrollView.zoomScale == 1.0 { readOnlyScrollView.setZoomScale(minZoom, animated: false) }
        centerReadOnlyImageIfNeeded()
    }

    private func resetReadOnlySnapshotViewport(animated: Bool) {
        renderReadOnlySnapshotIfNeeded()
        let contentSize = readOnlyImageView.bounds.size
        guard contentSize.width > 1, contentSize.height > 1, bounds.width > 1, bounds.height > 1 else { return }
        let fitZoom = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let minZoom = min(max(fitZoom, 0.1), 1.0)
        readOnlyScrollView.setZoomScale(minZoom, animated: animated)
        centerReadOnlyImageIfNeeded()
    }

    private func centerReadOnlyImageIfNeeded() {
        let scaledWidth = readOnlyImageView.bounds.width * readOnlyScrollView.zoomScale
        let scaledHeight = readOnlyImageView.bounds.height * readOnlyScrollView.zoomScale
        readOnlyScrollView.contentInset = UIEdgeInsets(top: max(0, (bounds.height - scaledHeight) * 0.5), left: max(0, (bounds.width - scaledWidth) * 0.5), bottom: max(0, (bounds.height - scaledHeight) * 0.5), right: max(0, (bounds.width - scaledWidth) * 0.5))
    }

    private func clampedOffset(forDocumentCenter center: CGPoint) -> CGPoint { clampedOffset(forVisibleCenter: CGPoint(x: center.x * canvasView.zoomScale, y: center.y * canvasView.zoomScale)) }

    private func clampedOffset(forVisibleCenter center: CGPoint) -> CGPoint {
        let proposed = CGPoint(x: center.x - bounds.width * 0.5, y: center.y - bounds.height * 0.5)
        let maxX = max(0, canvasView.contentSize.width * canvasView.zoomScale - bounds.width)
        let maxY = max(0, canvasView.contentSize.height * canvasView.zoomScale - bounds.height)
        return CGPoint(x: min(max(0, proposed.x), maxX), y: min(max(0, proposed.y), maxY))
    }

    private func positiveRemainder(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        guard modulus > 0 else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder >= 0 ? remainder : remainder + modulus
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

    func apply(style: PLDrawingPaperStyle, baseColor: UIColor, guideColor: UIColor, lineSpacing: CGFloat, dotSpacing: CGFloat, dotSize: CGFloat) {
        currentStyle = style
        currentBaseColor = baseColor
        currentGuideColor = guideColor
        currentLineSpacing = max(8, lineSpacing)
        currentDotSpacing = max(8, dotSpacing)
        currentDotSize = max(0.8, dotSize)
        setNeedsDisplay()
    }

    func updateViewport(contentOffset: CGPoint, zoomScale: CGFloat, contentSize: CGSize) {
        let newZoom = max(zoomScale, 0.01)
        if viewportOffset != contentOffset || abs(viewportZoomScale - newZoom) > 0.0001 { viewportOffset = contentOffset; viewportZoomScale = newZoom; setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        currentBaseColor.setFill()
        context.fill(bounds)
        switch currentStyle {
        case .blank: return
        case .lined: drawLines(in: context)
        case .dotGrid: drawDots(in: context)
        }
    }

    private func drawLines(in context: CGContext) {
        let spacing = max(6, currentLineSpacing * viewportZoomScale)
        let pixel = 1.0 / UIScreen.main.scale
        let phaseY = positiveRemainder(-viewportOffset.y, spacing)
        context.setStrokeColor(currentGuideColor.cgColor)
        context.setLineWidth(pixel)
        var y = phaseY
        while y <= bounds.height + spacing { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: bounds.width, y: y)); y += spacing }
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
            while x <= bounds.width + spacing { context.fillEllipse(in: CGRect(x: x - size * 0.5, y: y - size * 0.5, width: size, height: size)); x += spacing }
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
    var body: some View { Rectangle().fill(.clear) }
}

#endif
