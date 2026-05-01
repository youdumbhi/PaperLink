//
//  CustomCameraCaptureView.swift
//  PaperLink
//
//  Robust multi-shot camera with one-session crop rectangle.
//  UI is unchanged.
//
//  ✅ Key changes:
//  - Do NOT use previewLayer metadata conversion (was unreliable due to coordinate mismatches).
//  - Instead, freeze the SwiftUI preview container size at shutter press,
//    then map crop -> pixels using "aspectFill" math against the ORIENTED captured image.
//  - Full-res CoreImage crop after EXIF orientation.
//  - Full-screen captures remain unchanged (works already).
//

import SwiftUI
import AVFoundation
import UIKit
import Combine
import CoreImage
import ImageIO

#if os(iOS)

struct CustomCameraCaptureView: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when user taps Done
    let onDone: ([Data]) -> Void

    @StateObject private var camera = CameraSession()

    enum Stage { case setCrop, capture }
    @State private var stage: Stage = .capture

    // Whether we apply crop at all
    @State private var useCrop: Bool = false

    // Crop box stored in NORMALIZED coords (0...1) relative to the preview container bounds (GeometryReader size).
    @State private var cropRectNorm: CGRect = CGRect(x: 0.10, y: 0.12, width: 0.80, height: 0.76)

    // Captured photos stored on disk (NOT in RAM)
    @State private var capturedURLs: [URL] = []

    // UI
    @State private var showPermAlert = false
    @State private var isSavingShot = false
    @State private var isFinishingSession = false

    // ✅ We keep track of the preview container size (the same size the crop overlay uses)
    @State private var previewContainerSize: CGSize = .zero

    private var canShowDone: Bool { stage == .capture && !capturedURLs.isEmpty }
    private var usesLargeDeviceLayout: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        GeometryReader { geo in
            let layoutSize = geo.size
            let previewSize = preferredPreviewSize(in: layoutSize)

            ZStack {
                Color.black.ignoresSafeArea()

                if usesLargeDeviceLayout {
                    VStack(spacing: 20) {
                        topBar
                            .padding(.top, max(geo.safeAreaInsets.top, 8))

                        Spacer(minLength: 0)

                        previewSurface(size: previewSize)
                            .clipShape(RoundedRectangle(cornerRadius: 30))
                            .overlay(
                                RoundedRectangle(cornerRadius: 30)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )

                        if stage == .setCrop {
                            cropInstructions
                        }

                        bottomBar
                            .padding(.bottom, max(geo.safeAreaInsets.bottom, 20))

                        Spacer(minLength: 0)
                    }
                } else {
                    previewSurface(size: layoutSize)
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        if stage == .setCrop { cropInstructions }
                        Spacer()
                        bottomBar
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            camera.onPermissionDenied = { DispatchQueue.main.async { showPermAlert = true } }

            // ✅ data + frozen cropNorm + frozen containerSize
            camera.onPhoto = { data, frozenCropNorm, frozenContainerSize in
                DispatchQueue.global(qos: .userInitiated).async {
                    autoreleasepool {
                        let outData: Data?

                        if let frozenCropNorm, frozenContainerSize.width > 1, frozenContainerSize.height > 1 {
                            outData = cropPhotoDataUsingAspectFill(
                                data: data,
                                containerSize: frozenContainerSize,
                                cropNorm: frozenCropNorm
                            )
                        } else {
                            // full-screen success path
                            outData = orientPhotoDataFullRes(data: data)
                        }

                        guard let final = outData else {
                            DispatchQueue.main.async { isSavingShot = false }
                            return
                        }

                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("paperlink_capture_\(UUID().uuidString).jpg")

                        do {
                            try final.write(to: url, options: [.atomic])
                            DispatchQueue.main.async {
                                capturedURLs.append(url)
                                isSavingShot = false
                            }
                        } catch {
                            DispatchQueue.main.async { isSavingShot = false }
                        }
                    }
                }
            }

            camera.start()
        }
        .onDisappear {
            camera.stop()
            if !isFinishingSession {
                cleanupTempFiles()
            }
        }
        .alert("Camera Access Needed", isPresented: $showPermAlert) {
            Button("OK", role: .cancel) {
                cleanupTempFiles()
                dismiss()
            }
        } message: {
            Text("Enable camera access in Settings to take photos.")
        }
    }

    private func preferredPreviewSize(in size: CGSize) -> CGSize {
        guard usesLargeDeviceLayout else { return size }
        let edge = min(size.width - 80, size.height - 260)
        let clamped = max(320, edge)
        return CGSize(width: clamped, height: clamped)
    }

    private func previewSurface(size: CGSize) -> some View {
        ZStack {
            CameraPreview(session: camera)
                .onAppear {
                    DispatchQueue.main.async {
                        previewContainerSize = size
                    }
                }
                .onChange(of: size) { _, newSize in
                    DispatchQueue.main.async {
                        previewContainerSize = newSize
                    }
                }

            if stage == .setCrop {
                CropOverlayEditable(
                    rectNorm: $cropRectNorm,
                    minSizeNorm: CGSize(width: 0.20, height: 0.20)
                )
            }

            if stage == .capture, useCrop {
                CropOverlayFrame(rectNorm: cropRectNorm)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                cleanupTempFiles()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            Spacer()

            Text(stage == .setCrop ? "Set Crop" : "Camera")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))

            Spacer()

            if stage == .capture {
                Button {
                    stage = .setCrop
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: useCrop ? "crop" : "crop.rotate")
                        Text(useCrop ? "Adjust Crop" : "Set Crop")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            } else {
                Color.clear.frame(width: 110, height: 44)
            }

            Spacer()

            if canShowDone {
                Button {
                    guard !isFinishingSession else { return }
                    isFinishingSession = true
                    let datas: [Data] = capturedURLs.compactMap { try? Data(contentsOf: $0) }
                    onDone(datas)
                    cleanupTempFiles()
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .disabled(isFinishingSession)
            } else if stage == .capture {
                Color.clear.frame(width: 76, height: 44)
            } else {
                Button {
                    stage = .capture
                } label: {
                    Text("Back")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        ZStack {
            if stage == .setCrop {
                HStack(spacing: 12) {
                    Button {
                        useCrop = true
                        stage = .capture
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Use this crop")
                        }
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.white.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)

                    Button {
                        useCrop = false
                        stage = .capture
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.expand.vertical")
                            Text("Use entire screen")
                        }
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.white.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
            }

            if stage == .capture {
                Button {
                    guard !isSavingShot else { return }
                    isSavingShot = true

                    // ✅ Freeze crop + container size at shutter press
                    if useCrop {
                        camera.captureWithFrozenAspectFillCrop(
                            cropNorm: cropRectNorm,
                            containerSize: previewContainerSize
                        )
                    } else {
                        camera.captureWithFrozenAspectFillCrop(
                            cropNorm: nil,
                            containerSize: previewContainerSize
                        )
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.95), lineWidth: 4)
                            .frame(width: 74, height: 74)
                        Circle()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 60, height: 60)

                        if isSavingShot {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.black.opacity(0.65))
                        }
                    }
                }
                .buttonStyle(.plain)

                HStack {
                    Spacer()
                    Text("\(capturedURLs.count)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 54, height: 54)
                        .background(Color.black.opacity(0.30))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .padding(.trailing, 16)
                }
            }
        }
        .frame(height: 92)
        .padding(.horizontal, 16)
    }

    private var cropInstructions: some View {
        VStack(spacing: 8) {
            Text("Drag inside to move • drag corners to resize")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
            Text("This crop will apply to every photo you take in this session.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private func cleanupTempFiles() {
        for u in capturedURLs { try? FileManager.default.removeItem(at: u) }
        capturedURLs.removeAll()
    }
}

//
// MARK: - CoreImage helpers (EXIF orient + full-res crop)
//

private let plCIContext: CIContext = CIContext(options: [
    .useSoftwareRenderer: false
])

private func orientedCIImage(from data: Data) -> CIImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

    var exif: CGImagePropertyOrientation = .up
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let raw = props[kCGImagePropertyOrientation] as? UInt32,
       let o = CGImagePropertyOrientation(rawValue: raw) {
        exif = o
    }

    guard let ci = CIImage(data: data) else { return nil }
    return ci.oriented(exif)
}

private func orientPhotoDataFullRes(data: Data) -> Data? {
    guard let oriented = orientedCIImage(from: data) else { return nil }
    let extent = oriented.extent.integral
    guard let cg = plCIContext.createCGImage(oriented, from: extent) else { return nil }
    return UIImage(cgImage: cg, scale: 1, orientation: .up).jpegData(compressionQuality: 0.92)
}

/// ✅ Robust crop mapping:
/// Treat the captured (oriented) image as if it were drawn into the SwiftUI preview container with `.aspectFill`,
/// then convert crop rect from container space back into image pixels.
private func cropPhotoDataUsingAspectFill(
    data: Data,
    containerSize: CGSize,
    cropNorm: CGRect
) -> Data? {
    guard let oriented = orientedCIImage(from: data) else { return nil }

    let imgW = oriented.extent.width
    let imgH = oriented.extent.height
    guard imgW > 10, imgH > 10 else { return nil }

    let contW = max(containerSize.width, 1)
    let contH = max(containerSize.height, 1)

    // 1) How big would the image be when aspectFilled into the container?
    let scale = max(contW / imgW, contH / imgH)
    let drawnW = imgW * scale
    let drawnH = imgH * scale

    // Image is centered; parts may overflow (aspectFill)
    let offsetX = (contW - drawnW) * 0.5
    let offsetY = (contH - drawnH) * 0.5

    // 2) Convert cropNorm -> crop rect in container points
    let cropInCont = CGRect(
        x: cropNorm.minX * contW,
        y: cropNorm.minY * contH,
        width: cropNorm.width * contW,
        height: cropNorm.height * contH
    )

    // 3) Convert crop rect in container -> rect in the drawn image space
    // (undo centering offset, undo scale)
    let cropInDrawn = CGRect(
        x: (cropInCont.minX - offsetX) / scale,
        y: (cropInCont.minY - offsetY) / scale,
        width: cropInCont.width / scale,
        height: cropInCont.height / scale
    )

    // 4) Clamp to image extent
    var cropImg = cropInDrawn.integral.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
    guard cropImg.width > 2, cropImg.height > 2 else { return orientPhotoDataFullRes(data: data) }

    // 5) CoreImage is bottom-left origin; our math above used top-left container coords.
    // We need to flip Y into CI space.
    cropImg = CGRect(
        x: cropImg.origin.x,
        y: (imgH - cropImg.origin.y - cropImg.size.height),
        width: cropImg.size.width,
        height: cropImg.size.height
    ).integral.intersection(oriented.extent)

    guard cropImg.width > 2, cropImg.height > 2 else { return orientPhotoDataFullRes(data: data) }

    let cropped = oriented.cropped(to: cropImg)
    guard let cg = plCIContext.createCGImage(cropped, from: cropped.extent.integral) else { return nil }
    return UIImage(cgImage: cg, scale: 1, orientation: .up).jpegData(compressionQuality: 0.92)
}

//
// MARK: - Crop overlays (unchanged)
//

private struct CropOverlayEditable: View {
    @Binding var rectNorm: CGRect
    let minSizeNorm: CGSize

    enum Mode { case none, move, resize(Corner) }
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    @State private var startRect: CGRect = .zero
    @State private var mode: Mode = .none

    private let cornerHit: CGFloat = 44
    private let centerInset: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rectPx = CGRect(
                x: rectNorm.minX * size.width,
                y: rectNorm.minY * size.height,
                width: rectNorm.width * size.width,
                height: rectNorm.height * size.height
            )

            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRoundedRect(in: rectPx, cornerSize: CGSize(width: 10, height: 10))
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.95), lineWidth: 2)
                    .frame(width: rectPx.width, height: rectPx.height)
                    .position(x: rectPx.midX, y: rectPx.midY)
                    .allowsHitTesting(false)

                cornerDot(at: CGPoint(x: rectPx.minX, y: rectPx.minY))
                cornerDot(at: CGPoint(x: rectPx.maxX, y: rectPx.minY))
                cornerDot(at: CGPoint(x: rectPx.minX, y: rectPx.maxY))
                cornerDot(at: CGPoint(x: rectPx.maxX, y: rectPx.maxY))

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: rectPx.width, height: rectPx.height)
                    .position(x: rectPx.midX, y: rectPx.midY)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if startRect == .zero {
                                    startRect = rectNorm
                                    mode = pickMode(startLocation: value.startLocation, rectPx: rectPx)
                                }

                                let dx = value.translation.width / size.width
                                let dy = value.translation.height / size.height

                                var r = startRect

                                switch mode {
                                case .move:
                                    r.origin.x += dx
                                    r.origin.y += dy
                                case .resize(let c):
                                    switch c {
                                    case .topLeft:
                                        r.origin.x += dx; r.origin.y += dy
                                        r.size.width -= dx; r.size.height -= dy
                                    case .topRight:
                                        r.origin.y += dy
                                        r.size.width += dx; r.size.height -= dy
                                    case .bottomLeft:
                                        r.origin.x += dx
                                        r.size.width -= dx; r.size.height += dy
                                    case .bottomRight:
                                        r.size.width += dx; r.size.height += dy
                                    }
                                case .none:
                                    break
                                }

                                rectNorm = clampRect(r, minSize: minSizeNorm)
                            }
                            .onEnded { _ in
                                startRect = .zero
                                mode = .none
                            }
                    )

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.12))
                    .frame(
                        width: max(1, rectPx.width - centerInset * 2),
                        height: max(1, rectPx.height - centerInset * 2)
                    )
                    .position(x: rectPx.midX, y: rectPx.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func pickMode(startLocation: CGPoint, rectPx: CGRect) -> Mode {
        let tl = CGRect(x: rectPx.minX - cornerHit/2, y: rectPx.minY - cornerHit/2, width: cornerHit, height: cornerHit)
        let tr = CGRect(x: rectPx.maxX - cornerHit/2, y: rectPx.minY - cornerHit/2, width: cornerHit, height: cornerHit)
        let bl = CGRect(x: rectPx.minX - cornerHit/2, y: rectPx.maxY - cornerHit/2, width: cornerHit, height: cornerHit)
        let br = CGRect(x: rectPx.maxX - cornerHit/2, y: rectPx.maxY - cornerHit/2, width: cornerHit, height: cornerHit)

        if tl.contains(startLocation) { return .resize(.topLeft) }
        if tr.contains(startLocation) { return .resize(.topRight) }
        if bl.contains(startLocation) { return .resize(.bottomLeft) }
        if br.contains(startLocation) { return .resize(.bottomRight) }
        return .move
    }

    private func cornerDot(at p: CGPoint) -> some View {
        Circle()
            .fill(Color.white.opacity(0.95))
            .frame(width: 18, height: 18)
            .position(p)
            .shadow(radius: 6)
            .allowsHitTesting(false)
    }

    private func clampRect(_ r: CGRect, minSize: CGSize) -> CGRect {
        var out = r

        if out.size.width < 0 { out.origin.x += out.size.width; out.size.width = abs(out.size.width) }
        if out.size.height < 0 { out.origin.y += out.size.height; out.size.height = abs(out.size.height) }

        out.size.width = max(out.size.width, minSize.width)
        out.size.height = max(out.size.height, minSize.height)
        out.size.width = min(out.size.width, 1.0)
        out.size.height = min(out.size.height, 1.0)

        out.origin.x = min(max(out.origin.x, 0), 1 - out.size.width)
        out.origin.y = min(max(out.origin.y, 0), 1 - out.size.height)

        return out
    }
}

private struct CropOverlayFrame: View {
    let rectNorm: CGRect

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect = CGRect(
                x: rectNorm.minX * size.width,
                y: rectNorm.minY * size.height,
                width: rectNorm.width * size.width,
                height: rectNorm.height * size.height
            )

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                Group {
                    Circle().fill(Color.white.opacity(0.90)).frame(width: 10, height: 10).position(x: rect.minX, y: rect.minY)
                    Circle().fill(Color.white.opacity(0.90)).frame(width: 10, height: 10).position(x: rect.maxX, y: rect.minY)
                    Circle().fill(Color.white.opacity(0.90)).frame(width: 10, height: 10).position(x: rect.minX, y: rect.maxY)
                    Circle().fill(Color.white.opacity(0.90)).frame(width: 10, height: 10).position(x: rect.maxX, y: rect.maxY)
                }
            }
        }
    }
}

//
// MARK: - Camera session + preview
//

final class CameraSession: NSObject, ObservableObject {
    fileprivate let session = AVCaptureSession()
    fileprivate let output = AVCapturePhotoOutput()

    // data + cropNorm + containerSize
    var onPhoto: ((Data, CGRect?, CGSize) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let queue = DispatchQueue(label: "paperlink.camera.session")
    private var configured = false
    private var isCapturing = false
    private var currentVideoRotationAngle: CGFloat = 90

    // Frozen values for next capture
    private var pendingCropNorm: CGRect? = nil
    private var pendingContainerSize: CGSize = .zero

    func updateVideoRotationAngle(_ angle: CGFloat) {
        currentVideoRotationAngle = angle
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { self.onPermissionDenied?(); return }
            self.queue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.isCapturing = false
        }
    }

    func captureWithFrozenAspectFillCrop(cropNorm: CGRect?, containerSize: CGSize) {
        // Freeze values at shutter press
        pendingCropNorm = cropNorm
        pendingContainerSize = containerSize
        capture()
    }

    private func capture() {
        queue.async {
            guard self.configured, self.session.isRunning, !self.isCapturing else { return }
            self.isCapturing = true

            let settings = AVCapturePhotoSettings()
            if #available(iOS 16.0, *),
               self.output.maxPhotoDimensions.width > 0,
               self.output.maxPhotoDimensions.height > 0 {
                settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            }

            if let conn = self.output.connection(with: .video) {
                plApplyVideoRotationAngle(self.currentVideoRotationAngle, to: conn)
            }

            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = photo.fileDataRepresentation()
        let errorDescription = error.map { String(describing: $0) }

        Task { @MainActor in
            defer { self.queue.async { self.isCapturing = false } }

            if let errorDescription {
                print("Camera capture error:", errorDescription)
                return
            }

            guard let data else { return }

            let crop = self.pendingCropNorm
            let size = self.pendingContainerSize
            self.pendingCropNorm = nil
            self.pendingContainerSize = .zero

            self.onPhoto?(data, crop, size)
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    @ObservedObject var session: CameraSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session.session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        v.onRotationAngleChanged = { angle in
            session.updateVideoRotationAngle(angle)
        }
        v.refreshOrientation()
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onRotationAngleChanged = { angle in
            session.updateVideoRotationAngle(angle)
        }
        uiView.refreshOrientation()
    }
}

private final class PreviewView: UIView {
    var onRotationAngleChanged: ((CGFloat) -> Void)?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOrientationChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOrientationChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshOrientation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshOrientation()
    }

    @objc private func handleOrientationChange() {
        refreshOrientation()
    }

    func refreshOrientation() {
        let angle = plCurrentVideoRotationAngle(for: window?.windowScene)
        onRotationAngleChanged?(angle)
        if let conn = videoPreviewLayer.connection {
            plApplyVideoRotationAngle(angle, to: conn)
        }
    }
}

private func plApplyVideoRotationAngle(_ angle: CGFloat, to connection: AVCaptureConnection) {
    if #available(iOS 17.0, *) {
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}

private func plCurrentVideoRotationAngle(for scene: UIWindowScene?) -> CGFloat {
    guard let scene = scene ?? UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else {
        return 90
    }

    switch scene.interfaceOrientation {
    case .landscapeLeft:
        return 180
    case .landscapeRight:
        return 0
    case .portraitUpsideDown:
        return 270
    default:
        return 90
    }
}

#endif
