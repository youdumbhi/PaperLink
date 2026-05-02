//
//  NoteEditorScreen.swift
//  PaperLink
//
//  ✅ CHANGE REQUEST APPLIED:
//  1) Reduce border/padding to maximize note content.
//  2) On iPhone landscape: move controls to LEFT/RIGHT sides instead of the top bar.
//     - Left: Back
//     - Right: Properties
//     - Title becomes a small floating pill at top-center (minimal padding)
//     - The editor canvas expands nearly full-bleed
//
//  ✅ NEW:
//  - Rotate button (90°) for drawing/photo notes
//    - If readingMode == true, rotation is applied to the folder (affects all media in that folder)
//    - Otherwise applies to the note (per-note override)
//
//  ✅ FIXED / IMPROVED ZOOM:
//  - UIScrollView-backed pinch zoom (smooth, non-glitchy)
//  - Zoom anchors at your fingers (natural pinch behavior)
//  - Two-finger pan only (does NOT steal one-finger drawing)
//  - Double-tap to reset zoom
//
//  ✅ UPDATED TO MATCH APP TRASH MODEL:
//  - “Delete” moves note to Trash (soft delete) instead of hard deleting files
//

import SwiftUI
import SwiftData
import PencilKit
import CoreImage

#if canImport(UIKit)
import UIKit
#endif

enum PLEditMode: String, CaseIterable {
    case ink
    case highlight
    case text
}

enum PLDrawTool: String {
    case pen
    case marker
    case lasso
    case eraser
}

private enum PLFloatingPaletteAnchor: CaseIterable {
    case topLeading
    case topCenter
    case topTrailing
    case leadingCenter
    case trailingCenter
    case bottomLeading
    case bottomCenter
    case bottomTrailing
}

enum PLEditorInkColor: String, CaseIterable, Hashable {
    case black
    case white
    case blue
    case red
    case green
    case purple
    case orange
    case rainbow

    var swatch: Color {
        switch self {
        case .black:
            return Color(.sRGB, white: 0.0, opacity: 1.0)
        case .white:
            return Color(.sRGB, white: 1.0, opacity: 1.0)
        case .blue:
            return Color(red: 0.12, green: 0.35, blue: 0.86)
        case .red:
            return Color(red: 0.80, green: 0.18, blue: 0.16)
        case .green:
            return Color(red: 0.08, green: 0.55, blue: 0.37)
        case .purple:
            return Color(red: 0.45, green: 0.28, blue: 0.76)
        case .orange:
            return Color(red: 0.88, green: 0.43, blue: 0.16)
        case .rainbow:
            return Color(red: 0.12, green: 0.35, blue: 0.86)
        }
    }

#if canImport(UIKit)
    var uiColor: UIColor {
        switch self {
        case .black:
            return UIColor(white: 0.0, alpha: 1.0)
        case .white:
            return UIColor(white: 1.0, alpha: 1.0)
        case .blue:
            return UIColor(red: 0.12, green: 0.35, blue: 0.86, alpha: 1)
        case .red:
            return UIColor(red: 0.80, green: 0.18, blue: 0.16, alpha: 1)
        case .green:
            return UIColor(red: 0.08, green: 0.55, blue: 0.37, alpha: 1)
        case .purple:
            return UIColor(red: 0.45, green: 0.28, blue: 0.76, alpha: 1)
        case .orange:
            return UIColor(red: 0.88, green: 0.43, blue: 0.16, alpha: 1)
        case .rainbow:
            return UIColor(red: 0.12, green: 0.35, blue: 0.86, alpha: 1)
        }
    }
#endif

    var needsDarkBorder: Bool {
        self == .white || self == .rainbow
    }
}

struct PLNoteDraft: Identifiable, Equatable {
    let id = UUID()
    let kind: PLNoteKind
    var title: String
    var folderID: UUID?
    var photoData: Data? = nil
}

private enum PLDrawingPaletteSnapEdge: String, CaseIterable {
    case top
    case bottom
    case leading
    case trailing
}

private struct PLNoteCanvasSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NoteEditorScreen: View {
    @EnvironmentObject private var theme: PLThemeStore
    @AppStorage("pl_apple_pencil_only_draw") private var applePencilOnlyDraw: Bool = false
    @AppStorage(PLDrawingPaletteDefaults.Key.autoMinimize) private var drawingPaletteAutoMinimize: Bool = PLDrawingPaletteDefaults.autoMinimize
    @AppStorage(PLTextDefaults.Key.fontSize) private var textFontSize: Double = PLTextDefaults.fontSize
    @AppStorage(PLDrawingDefaults.Key.paperStyleRaw) private var defaultDrawingPaperStyleRaw: String = PLDrawingDefaults.paperStyleRaw
    @AppStorage(PLDrawingDefaults.Key.penWidth) private var defaultPenWidth: Double = PLDrawingDefaults.penWidth
    @AppStorage(PLDrawingDefaults.Key.markerWidth) private var defaultMarkerWidth: Double = PLDrawingDefaults.markerWidth
    @AppStorage(PLDrawingDefaults.Key.lineSpacing) private var defaultLineSpacing: Double = PLDrawingDefaults.lineSpacing
    @AppStorage(PLDrawingDefaults.Key.dotSpacing) private var defaultDotSpacing: Double = PLDrawingDefaults.dotSpacing
    @AppStorage(PLDrawingDefaults.Key.dotSize) private var defaultDotSize: Double = PLDrawingDefaults.dotSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Environment(\.undoManager) private var undoManager

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    @Query(sort: \PLFolder.createdAt, order: .forward) private var allFolders: [PLFolder]

    private let existingNote: PLNote?
    private let initialDraft: PLNoteDraft?

    private let readingMode: Bool
    private let startInPreview: Bool
    private let hideChrome: Bool

    // Preview/edit state
    @State private var isEditing: Bool = false
    @State private var showUnsavedAlert: Bool = false
    @State private var showDeleteConfirm: Bool = false

    // Properties sheet (simple placeholder)
    @State private var showProperties: Bool = false

    // Snapshot for “unsaved changes”
    private struct Snapshot: Equatable {
        var title: String
        var textBody: String
        var inkData: Data
        var highlightData: Data
        var drawingPaperStyleRaw: String
        var drawWidth: Double
        var markerWidth: Double
        var drawingLineSpacing: Double
        var drawingDotSpacing: Double
        var drawingDotSize: Double
    }
    @State private var snapshot: Snapshot? = nil

    // Modes / Tools
    @State private var mode: PLEditMode = .ink
    @State private var drawTool: PLDrawTool = .pen

    // Tool settings
    @State private var drawColor: PLEditorInkColor = .black
    @State private var customInkColor: Color = Color(red: 0.12, green: 0.35, blue: 0.86)
    @State private var showCustomColorPicker: Bool = false
    @State private var drawWidth: Double = 6
    @State private var markerWidth: Double = 18
    @State private var drawingPaperStyle: PLDrawingPaperStyle = .lined
    @State private var drawingLineSpacing: Double = PLDrawingDefaults.lineSpacing
    @State private var drawingDotSpacing: Double = PLDrawingDefaults.dotSpacing
    @State private var drawingDotSize: Double = PLDrawingDefaults.dotSize

    // Content
    @State private var titleText: String = ""
    @State private var inkData: Data = PKDrawing().dataRepresentation()
    @State private var highlightData: Data = PKDrawing().dataRepresentation()
    @State private var draftTextBody: String = ""
    @State private var textBlocks: [PLTextBlock] = []
    @State private var selectedTextBlockID: UUID? = nil
    @FocusState private var focusedTextBlockID: UUID?
    @State private var drawingPaletteExpanded: Bool = true
    @State private var drawingPaletteSnapEdge: PLDrawingPaletteSnapEdge = .top
    @State private var drawingPaletteEdgeProgress: CGFloat = 0.5
    @State private var drawingPaletteIsDragging: Bool = false
    @State private var drawingPaletteHideWorkItem: DispatchWorkItem? = nil
    @State private var noteCanvasSize: CGSize = .zero

    // Undo stacks
    @State private var inkUndoStack: [Data] = []
    @State private var highlightUndoStack: [Data] = []
    @State private var lastInkData: Data = PKDrawing().dataRepresentation()
    @State private var lastHighlightData: Data = PKDrawing().dataRepresentation()

#if canImport(UIKit)
    @State private var draftPhotoUIImage: UIImage? = nil
#endif

    // ✅ Zoom state (UIScrollView-backed)
    @State private var isZooming: Bool = false
    @State private var zoomResetToken: Int = 0

    private var controlsShouldHide: Bool { false }

    // MARK: - Layout tuning (reduced padding)
    private let outerPadRegular: CGFloat = 10
    private let outerPadLandscape: CGFloat = 4
    private let canvasCorner: CGFloat = 18
    private let canvasShadowRadius: CGFloat = 10
    private let canvasShadowY: CGFloat = 6
    private let sideButtonSize: CGFloat = 54
    private let titlePillHeight: CGFloat = 42

    private enum PLTextBlockKind: Equatable {
        case body
        case heading
        case checklist
        case divider
    }

    private struct PLTextBlock: Identifiable, Equatable {
        let id: UUID
        var kind: PLTextBlockKind
        var text: String
        var checked: Bool

        init(id: UUID = UUID(), kind: PLTextBlockKind, text: String = "", checked: Bool = false) {
            self.id = id
            self.kind = kind
            self.text = text
            self.checked = checked
        }
    }

    // MARK: - Init
    init(note: PLNote, readingMode: Bool = false, startInPreview: Bool = false, hideChrome: Bool = false) {
        self.existingNote = note
        self.initialDraft = nil
        self.readingMode = readingMode
        self.startInPreview = startInPreview
        self.hideChrome = hideChrome
    }

    init(draft: PLNoteDraft) {
        self.existingNote = nil
        self.initialDraft = draft
        self.readingMode = false
        self.startInPreview = false
        self.hideChrome = false
    }

    private var note: PLNote? { existingNote }
    private var isDraft: Bool { existingNote == nil }

    private var currentKind: PLNoteKind {
        if let n = note { return n.kind }
        return initialDraft?.kind ?? .text
    }

    private var isPhone: Bool {
#if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .phone
#else
        return false
#endif
    }

    private var isPhoneLandscape: Bool {
        isPhone && (hSizeClass == .compact) && (vSizeClass == .compact)
    }

    private var usesCompactTopBar: Bool {
        isPhone && !isPhoneLandscape
    }

    // iPhone limitations:
    // - drawing/photo = view-only
    // - text = basic edit allowed
    private var isIPhoneRestrictedReadOnly: Bool {
        guard isPhone else { return false }
        if currentKind == .drawing { return true }
        if currentKind == .photo { return true }
        return false
    }

    private var isPreviewOnly: Bool {
        if readingMode { return true }
        if isDraft { return false }
        if isIPhoneRestrictedReadOnly { return true }
        return startInPreview
    }

    private var isLocked: Bool {
        if readingMode { return true }
        if isDraft { return false }
        if isIPhoneRestrictedReadOnly { return true }
        if isPreviewOnly && !isEditing { return true }
        return false
    }

    private var canCreateDraft: Bool {
        if isPhone, currentKind == .drawing { return false }

        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        if currentKind == .photo {
#if canImport(UIKit)
            return draftPhotoUIImage != nil
#else
            return false
#endif
        }
        return true
    }

    private var hasUnsavedChanges: Bool {
        guard !isDraft, !readingMode, isEditing else { return false }
        guard let snap = snapshot else { return false }
        return snap != Snapshot(
            title: titleText,
            textBody: draftTextBody,
            inkData: inkData,
            highlightData: highlightData,
            drawingPaperStyleRaw: drawingPaperStyle.rawValue,
            drawWidth: drawWidth,
            markerWidth: markerWidth,
            drawingLineSpacing: drawingLineSpacing,
            drawingDotSpacing: drawingDotSpacing,
            drawingDotSize: drawingDotSize
        )
    }

    // MARK: - Folder + rotation helpers
    private var currentFolderID: UUID? {
        if let n = note { return n.folderID }
        return initialDraft?.folderID
    }

    private var currentFolder: PLFolder? {
        guard let id = currentFolderID else { return nil }
        return allFolders.first(where: { $0.id == id })
    }

    private var effectiveMediaRotationQuarterTurns: Int16 {
        guard currentKind != .text else { return 0 }
        if let n = note, let perNote = n.mediaRotationQuarterTurns {
            return ((perNote % 4) + 4) % 4
        }
        let folderVal = currentFolder?.mediaRotationQuarterTurns ?? 0
        return ((folderVal % 4) + 4) % 4
    }

    private var effectiveMediaRotationDegrees: Double {
        Double(effectiveMediaRotationQuarterTurns) * 90.0
    }

    private var shouldShowRotate: Bool {
        currentKind == .photo || currentKind == .drawing
    }

    // Draft-only rotation state
    @State private var draftMediaRotationQuarterTurns: Int16 = 0

    private var effectiveDraftRotationQuarterTurns: Int16 {
        ((draftMediaRotationQuarterTurns % 4) + 4) % 4
    }

    private var effectiveRotationForView: Double {
        if isDraft {
            if currentKind == .text { return 0 }
            return Double(effectiveDraftRotationQuarterTurns) * 90.0
        }
        return effectiveMediaRotationDegrees
    }

    private var usesQuarterTurnCanvasRotation: Bool {
        let quarterTurns = Int(round(effectiveRotationForView / 90.0))
        return abs(quarterTurns % 2) == 1
    }

    private func rotate90() {
        guard shouldShowRotate else { return }
        guard currentKind != .text else { return }

        if readingMode {
            guard let f = currentFolder else { return }
            f.mediaRotationQuarterTurns = (f.mediaRotationQuarterTurns + 1) % 4
            f.updatedAt = .now
            try? ctx.save()
            PaperLinkSyncManager.shared.enqueueFolder(f, ctx: ctx)
            zoomResetToken += 1
            return
        }

        if let n = note {
            let current = n.mediaRotationQuarterTurns ?? (currentFolder?.mediaRotationQuarterTurns ?? 0)
            n.mediaRotationQuarterTurns = (current + 1) % 4
            n.updatedAt = .now
            try? ctx.save()
            PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
            zoomResetToken += 1
            return
        }

        draftMediaRotationQuarterTurns = (draftMediaRotationQuarterTurns + 1) % 4
        zoomResetToken += 1
    }

    // MARK: - Tool label
    private var toolHeaderText: String {
        switch drawTool {
        case .pen: return mode == .highlight ? "Highlight" : "Draw"
        case .marker: return "Highlight"
        case .lasso: return "Select"
        case .eraser: return "Erase"
        }
    }

    private var canvasDrawingPolicy: PKCanvasViewDrawingPolicy {
        applePencilOnlyDraw ? .pencilOnly : .anyInput
    }

    private var selectedInkSwatchColor: Color {
        if drawColor == .rainbow { return customInkColor }
        return drawColor.swatch
    }

    private var usesFloatingDrawingPalette: Bool {
        (currentKind == .drawing || currentKind == .photo) && !isPhone && !readingMode && !isLocked
    }

    private var drawWithFingerBinding: Binding<Bool> {
        Binding(
            get: { !applePencilOnlyDraw },
            set: { newValue in
                applePencilOnlyDraw = !newValue
                bumpDrawingPaletteActivity()
            }
        )
    }

#if canImport(UIKit)
    private var selectedInkUIColor: UIColor {
        if drawColor == .rainbow { return UIColor(customInkColor) }
        return drawColor.uiColor
    }
#endif

    private var selectedInkNeedsDarkBorder: Bool {
        if drawColor == .white { return true }
#if canImport(UIKit)
        return colorLuminance(selectedInkUIColor) > 0.82
#else
        return drawColor.needsDarkBorder
#endif
    }

#if canImport(UIKit)
    private var drawingPaperBaseUIColor: UIColor {
        UIColor(red: 0.99, green: 0.99, blue: 0.97, alpha: 1)
    }

    private var drawingPaperGuideUIColor: UIColor {
        UIColor.black.withAlphaComponent(0.10)
    }
#endif

    // MARK: - Body
    var body: some View {
        editorRoot
            .onAppear {
                bootstrap()
                if usesFloatingDrawingPalette {
                    drawingPaletteExpanded = true
                    bumpDrawingPaletteActivity()
                }
            }
            .onChange(of: theme.theme) { _, _ in
                applyAdaptiveDefaultInkColorIfNeeded()
            }
            .onChange(of: isEditing) { _, editing in
                guard usesFloatingDrawingPalette else { return }
                if editing {
                    drawingPaletteExpanded = true
                    bumpDrawingPaletteActivity()
                } else {
                    cancelDrawingPaletteAutoMinimize()
                    drawingPaletteExpanded = true
                }
            }
            .onChange(of: drawingPaletteAutoMinimize) { _, enabled in
                guard usesFloatingDrawingPalette else { return }
                if enabled {
                    bumpDrawingPaletteActivity()
                } else {
                    cancelDrawingPaletteAutoMinimize()
                    drawingPaletteExpanded = true
                }
            }
            .onChange(of: inkData) { _, newValue in
                guard !isLocked else { return }
                pushInkUndoIfNeeded(newValue)
            }
            .onChange(of: highlightData) { _, newValue in
                guard !isLocked else { return }
                pushHighlightUndoIfNeeded(newValue)
            }
            .onChange(of: drawingPaperStyle) { _, newStyle in
                guard let n = note, n.kind == .drawing else { return }
                guard !readingMode else { return }
                guard isEditing else { return }
                n.drawingPaperStyle = newStyle
                n.updatedAt = .now
                try? ctx.save()
                PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
            }
            .alert("Move note to Trash?", isPresented: $showDeleteConfirm) {
                Button("Move to Trash", role: .destructive) { moveNoteToTrashAndExit() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You can restore it from Recently Deleted.")
            }
            .alert("Keep changes?", isPresented: $showUnsavedAlert) {
                Button("Save") { saveAndExit() }
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You have unsaved changes. Do you want to save before leaving?")
            }
            .sheet(isPresented: $showProperties) {
                propertiesSheetContent
            }
            .sheet(isPresented: $showCustomColorPicker) {
                CustomInkColorSheet(color: $customInkColor)
                    .presentationDetents([.height(420), .large])
                    .presentationDragIndicator(.visible)
            }
            .onDisappear {
                cancelDrawingPaletteAutoMinimize()
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var editorRoot: some View {
        GeometryReader { proxy in
            let p = theme.palette
            let topInset = max(proxy.safeAreaInsets.top, 0)

            ZStack {
                p.background.ignoresSafeArea()

                if isPhoneLandscape {
                    phoneLandscapeLayout(topInset: topInset)
                } else {
                    regularLayout(topInset: topInset)
                }
            }
        }
    }

    private var propertiesSheetContent: some View {
        PropertiesSheetLite(
            note: note,
            kind: currentKind,
            drawingPaperStyle: $drawingPaperStyle,
            drawWidth: $drawWidth,
            markerWidth: $markerWidth,
            drawingLineSpacing: $drawingLineSpacing,
            drawingDotSpacing: $drawingDotSpacing,
            drawingDotSize: $drawingDotSize,
            onClose: {
                DispatchQueue.main.async {
                    showProperties = false
                }
            }
        )
        .presentationDetents([.height(680), .large])
    }

    // MARK: - Layouts
    private func regularLayout(topInset: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            noteCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !hideChrome {
                if isPhone && (currentKind == .drawing || currentKind == .photo) {
                    portraitMediaTopChrome(topInset: topInset)
                        .zIndex(10)
                        .opacity(controlsShouldHide ? 0.0 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: controlsShouldHide)
                } else {
                    topBar
                        .padding(.top, topInset)
                        .zIndex(10)
                        .opacity(controlsShouldHide ? 0.0 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: controlsShouldHide)
                }
            }

            if shouldShowToolRail && !usesFloatingDrawingPalette {
                VStack {
                    Spacer(minLength: topInset + 74)

                    HStack(alignment: .center) {
                        toolRail
                            .opacity(controlsShouldHide ? 0.0 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: controlsShouldHide)
                            .padding(.leading, outerPadRegular)

                        Spacer(minLength: 0)
                    }

                    Spacer(minLength: outerPadRegular)
                }
                .zIndex(9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func portraitMediaTopChrome(topInset: CGFloat) -> some View {
        HStack(spacing: 10) {
            Button { handleBackPressed() } label: {
                Image(systemName: backSystemImage)
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 50, height: 50)
                    .foregroundStyle(.black)
                    .background(Color.white.opacity(0.001))
            }
            .buttonStyle(.plain)

            Text(titleText.isEmpty ? "Untitled" : titleText)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .white.opacity(1.0), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.20), radius: 3, x: 0, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if shouldShowRotate {
                Button { rotate90() } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.black)
                        .background(Color.white.opacity(0.001))
                }
                .buttonStyle(.plain)
            }

            Button { showProperties = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.black)
                    .background(Color.white.opacity(0.001))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, topInset + 4)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func phoneLandscapeLayout(topInset: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            noteCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            if !hideChrome {
                HStack(spacing: 10) {
                    sideBackButton

                    if currentKind == .drawing {
                        Text(titleText.isEmpty ? "Untitled" : titleText)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 180, alignment: .leading)
                    }
                }
                .opacity(controlsShouldHide ? 0.0 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: controlsShouldHide)
                .padding(.leading, 8)
                .padding(.top, topInset + 2)
                .zIndex(20)

                HStack {
                    Spacer()

                    sideRotateButton
                        .opacity((controlsShouldHide || !shouldShowRotate) ? 0.0 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: controlsShouldHide)

                    sidePropertiesButton
                        .opacity(controlsShouldHide ? 0.0 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: controlsShouldHide)
                        .padding(.trailing, 8)
                }
                .padding(.top, topInset + 2)
                .zIndex(20)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        bottomRightActionButton
                            .opacity(controlsShouldHide ? 0.0 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: controlsShouldHide)
                            .padding(.trailing, 10)
                            .padding(.bottom, 8)
                    }
                }
                .zIndex(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var noteCanvas: some View {
        let p = theme.palette
        let resolvedCanvasSize = noteCanvasSize == .zero ? UIScreen.main.bounds.size : noteCanvasSize
        let canvasFillStyle: AnyShapeStyle
        let usesFullBleedCanvas = isPhoneLandscape || currentKind != .text

        if currentKind == .text {
            canvasFillStyle = AnyShapeStyle(p.card)
        } else if currentKind == .drawing {
#if canImport(UIKit)
            canvasFillStyle = AnyShapeStyle(Color(drawingPaperBaseUIColor))
#else
            canvasFillStyle = AnyShapeStyle(p.canvas)
#endif
        } else {
            canvasFillStyle = AnyShapeStyle(
                LinearGradient(
                    colors: [p.canvas, p.card.opacity(0.95)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return ZStack {
            if usesFullBleedCanvas {
                Rectangle()
                    .fill(canvasFillStyle)
                    .overlay(zoomableEditorContent)
            } else {
                RoundedRectangle(cornerRadius: canvasCorner)
                    .fill(canvasFillStyle)
                    .overlay(
                        RoundedRectangle(cornerRadius: canvasCorner)
                            .stroke(p.outline, lineWidth: 1)
                    )
                    .overlay(
                        zoomableEditorContent
                            .clipShape(RoundedRectangle(cornerRadius: canvasCorner))
                    )
            }

            if usesFloatingDrawingPalette {
                FloatingDrawingPalette(
                    containerSize: resolvedCanvasSize,
                    isExpanded: $drawingPaletteExpanded,
                    snapEdge: $drawingPaletteSnapEdge,
                    edgeProgress: $drawingPaletteEdgeProgress,
                    isDragging: $drawingPaletteIsDragging,
                    selectedTool: $drawTool,
                    selectedColor: $drawColor,
                    customColor: $customInkColor,
                    penWidth: $drawWidth,
                    markerWidth: $markerWidth,
                    drawWithFinger: drawWithFingerBinding,
                    autoMinimize: $drawingPaletteAutoMinimize,
                    onSelectTool: { tool in
                        drawTool = tool
                        if tool == .marker {
                            mode = .highlight
                        } else if tool == .pen {
                            mode = .ink
                        }
                        bumpDrawingPaletteActivity()
                    },
                    onUndo: {
                        performUndo()
                        bumpDrawingPaletteActivity()
                    },
                    onActivity: {
                        bumpDrawingPaletteActivity()
                    }
                )
                .zIndex(2)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: PLNoteCanvasSizePreferenceKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(PLNoteCanvasSizePreferenceKey.self) { newSize in
            if noteCanvasSize != newSize {
                noteCanvasSize = newSize
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(
            color: usesFullBleedCanvas ? .clear : .black.opacity(0.10),
            radius: usesFullBleedCanvas ? 0 : canvasShadowRadius,
            x: 0,
            y: usesFullBleedCanvas ? 0 : canvasShadowY
        )
    }

    // MARK: - ✅ Zoom wrapper (UIScrollView)
    @ViewBuilder
    private var zoomableEditorContent: some View {
        if currentKind == .text {
            editorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentKind == .drawing {
            GeometryReader { geo in
                let rotatedSize = usesQuarterTurnCanvasRotation
                    ? CGSize(width: geo.size.height, height: geo.size.width)
                    : geo.size

                editorContent
                    .frame(width: rotatedSize.width, height: rotatedSize.height)
                    .rotationEffect(.degrees(effectiveRotationForView))
                    .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZoomableScrollContainer(
                isZooming: $isZooming,
                resetToken: $zoomResetToken,
                minZoom: 1.0,
                maxZoom: 4.0
            ) {
                editorContent
                    .rotationEffect(.degrees(effectiveRotationForView))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    zoomResetToken += 1
                }
            )
        }
    }

    // MARK: - Side controls (landscape)
    private var sideBackButton: some View {
        let p = theme.palette
        return Button { handleBackPressed() } label: {
            Image(systemName: backSystemImage)
                .font(.system(size: 18, weight: .bold))
                .frame(width: sideButtonSize, height: sideButtonSize)
                .background(p.textPrimary.opacity(0.88))
                .foregroundStyle((p.textPrimary == .black ? Color.white : Color.black).opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)

    }

    private var sideRotateButton: some View {
        let p = theme.palette
        return Group {
            if shouldShowRotate {
                Button { rotate90() } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: sideButtonSize, height: sideButtonSize)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }
        }
    }

    private var sidePropertiesButton: some View {
        let p = theme.palette
        return Button { showProperties = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .bold))
                .frame(width: sideButtonSize, height: sideButtonSize)
                .background(p.railButton)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(p.outline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.textPrimary)
    }

    private var titlePillLandscape: some View {
        TextField("Title", text: $titleText)
            .font(.system(size: 17, weight: .bold))
            .padding(.horizontal, 12)
            .frame(height: titlePillHeight)
            .foregroundStyle(.black)
            .tint(.black)
            .shadow(color: .white.opacity(1.0), radius: 1.5, x: 0, y: 1)
            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(!(isLocked || readingMode))
            .onSubmit {
                guard let n = note, !readingMode, !isLocked else { return }
                n.title = titleText
                n.updatedAt = .now
                try? ctx.save()
                PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
            }
    }

    private var bottomRightActionButton: some View {
        let p = theme.palette

        if isDraft {
            return AnyView(
                Button { createDraftAndExit() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: sideButtonSize, height: sideButtonSize)
                        .background(canCreateDraft ? p.accent : p.textPrimary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .disabled(!canCreateDraft)
            )
        }

        if readingMode {
            return AnyView(EmptyView())
        }

        if isPreviewOnly {
            if isIPhoneRestrictedReadOnly {
                return AnyView(EmptyView())
            }

            if isEditing {
                return AnyView(
                    Button { saveAndExitEditMode() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: sideButtonSize, height: sideButtonSize)
                            .background(p.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(p.outline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                )
            } else {
                return AnyView(
                    Button { enterEditMode() } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: sideButtonSize, height: sideButtonSize)
                            .background(p.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(p.outline.opacity(0.8), lineWidth: 2)
                            )
                            .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                )
            }
        }

        return AnyView(
            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: sideButtonSize, height: sideButtonSize)
                    .background(p.railButton)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.textPrimary)
        )
    }

    // MARK: - Tool rail show rules
    private var shouldShowToolRail: Bool {
        if hideChrome { return false }
        if isPhone { return false }
        if !isPreviewOnly || isEditing || isDraft || readingMode { return true }
        return false
    }

    // MARK: - Bootstrap
    private func bootstrap() {
        zoomResetToken += 1

        if let n = existingNote {
            titleText = n.title
            drawingPaperStyle = n.drawingPaperStyle
            drawWidth = n.drawingPenWidth
            markerWidth = n.drawingMarkerWidth
            drawingLineSpacing = n.drawingLineSpacing
            drawingDotSpacing = n.drawingDotSpacing
            drawingDotSize = n.drawingDotSize

            if isIPhoneRestrictedReadOnly {
                isEditing = false
            } else {
                isEditing = !isPreviewOnly
            }

            if n.kind == .text {
                mode = .text
                draftTextBody = n.textBody ?? ""
                textBlocks = parseTextBlocks(from: draftTextBody)
            } else if n.kind == .photo {
                mode = .ink
                drawTool = .pen
            } else {
                mode = .ink
                drawTool = .pen
            }

            loadLayers(for: n)

            lastInkData = inkData
            lastHighlightData = highlightData
            inkUndoStack = []
            highlightUndoStack = []

            snapshot = Snapshot(
                title: titleText,
                textBody: draftTextBody,
                inkData: inkData,
                highlightData: highlightData,
                drawingPaperStyleRaw: drawingPaperStyle.rawValue,
                drawWidth: drawWidth,
                markerWidth: markerWidth,
                drawingLineSpacing: drawingLineSpacing,
                drawingDotSpacing: drawingDotSpacing,
                drawingDotSize: drawingDotSize
            )
            applyAdaptiveDefaultInkColorIfNeeded()
            return
        }

        if let d = initialDraft {
            titleText = d.title
            isEditing = true
            draftMediaRotationQuarterTurns = 0
            drawingPaperStyle = PLDrawingPaperStyle(rawValue: defaultDrawingPaperStyleRaw) ?? .lined
            drawWidth = defaultPenWidth
            markerWidth = defaultMarkerWidth
            drawingLineSpacing = defaultLineSpacing
            drawingDotSpacing = defaultDotSpacing
            drawingDotSize = defaultDotSize

            if isPhone, d.kind == .drawing {
                mode = .text
            } else if d.kind == .text {
                mode = .text
                draftTextBody = ""
                textBlocks = parseTextBlocks(from: draftTextBody)
            } else if d.kind == .photo {
                mode = .ink
                drawTool = .pen
            } else {
                mode = .ink
                drawTool = .pen
            }

#if canImport(UIKit)
            if d.kind == .photo, let data = d.photoData {
                draftPhotoUIImage = UIImage(data: data)
            }
#endif
            inkData = PKDrawing().dataRepresentation()
            highlightData = PKDrawing().dataRepresentation()

            lastInkData = inkData
            lastHighlightData = highlightData
            inkUndoStack = []
            highlightUndoStack = []
            applyAdaptiveDefaultInkColorIfNeeded(force: true)
        }
    }

    // MARK: - Top Bar (portrait / iPad)
    private var topBar: some View {
        Group {
            if usesCompactTopBar {
                compactTopBar
            } else {
                wideTopBar
            }
        }
        .padding(.horizontal, outerPadRegular)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.outline.opacity(0.85))
                .frame(height: 1)
        }
    }

    private var wideTopBar: some View {
        ViewThatFits(in: .horizontal) {
            wideTopBarSingleRow
                .fixedSize(horizontal: true, vertical: false)

            compactTopBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wideTopBarSingleRow: some View {
        let p = theme.palette

        return HStack(spacing: 10) {
            Button { handleBackPressed() } label: {
                Label(backLabelText, systemImage: backSystemImage)
                    .font(.system(size: 16, weight: .bold))
                    .frame(height: 50)
                    .padding(.horizontal, 14)
                    .background(p.textPrimary.opacity(0.88))
                    .foregroundStyle((p.textPrimary == .black ? Color.white : Color.black).opacity(0.92))
            }
            .buttonStyle(.plain)

            TextField("Title", text: $titleText)
                .font(.system(size: 19, weight: .bold))
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .frame(height: 50)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.black)
                .shadow(color: .white.opacity(1.0), radius: 1.5, x: 0, y: 1)
                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
                .allowsHitTesting(!(isLocked || readingMode))
                .onSubmit {
                    guard let n = note, !readingMode, !isLocked else { return }
                    n.title = titleText
                    n.updatedAt = .now
                    try? ctx.save()
                    PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
                }

            Spacer(minLength: 10)

            if currentKind == .text {
                textSizeControl
            }

            if shouldShowRotate {
                Button { rotate90() } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 50, height: 50)
                        .background(p.railButton)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }

            Button { showProperties = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 50, height: 50)
                    .background(p.railButton)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(p.outline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.textPrimary)

            if isDraft {
                Button { createDraftAndExit() } label: {
                    Label("Create", systemImage: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .frame(height: 50)
                        .padding(.horizontal, 16)
                        .background(canCreateDraft ? p.accent : p.textPrimary.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .disabled(!canCreateDraft)

            } else if readingMode {
                EmptyView()

            } else if isPreviewOnly {
                if isIPhoneRestrictedReadOnly {
                    EmptyView()
                } else {
                    if isEditing {
                        Button { saveAndExitEditMode() } label: {
                            Label("Save", systemImage: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                                .frame(height: 50)
                                .padding(.horizontal, 16)
                                .background(p.accent)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(p.outline, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.black)
                    } else {
                        Button { enterEditMode() } label: {
                            Label("Edit", systemImage: "pencil")
                                .font(.system(size: 16, weight: .bold))
                                .frame(height: 50)
                                .padding(.horizontal, 16)
                                .background(p.accent)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(p.outline.opacity(0.8), lineWidth: 2)
                                )
                                .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.black)
                    }
                }

            } else {
                Button { showDeleteConfirm = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 50, height: 50)
                        .background(p.railButton)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)

                Button {
                    guard let n = note else { return }
                    n.pinned.toggle()
                    n.updatedAt = .now
                    try? ctx.save()
                    PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
                } label: {
                    Image(systemName: (note?.pinned ?? false) ? "pin.fill" : "pin")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 50, height: 50)
                        .background(p.railButton)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }
        }
    }

    private var compactTopBar: some View {
        let p = theme.palette

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { handleBackPressed() } label: {
                    Image(systemName: backSystemImage)
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(p.textPrimary.opacity(0.88))
                        .foregroundStyle((p.textPrimary == .black ? Color.white : Color.black).opacity(0.92))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if shouldShowRotate {
                    compactIconButton(icon: "rotate.right") { rotate90() }
                }

                compactIconButton(icon: "slider.horizontal.3") { showProperties = true }

                compactTrailingActions
            }

            TextField("Title", text: $titleText)
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 12)
                .frame(height: 46)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(p.outline, lineWidth: 1)
                )
                .foregroundStyle(.black)
                .shadow(color: .white.opacity(1.0), radius: 1.5, x: 0, y: 1)
                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
                .allowsHitTesting(!(isLocked || readingMode))
                .onSubmit {
                    guard let n = note, !readingMode, !isLocked else { return }
                    n.title = titleText
                    n.updatedAt = .now
                    try? ctx.save()
                    PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
                }

            if currentKind == .text {
                textSizeControl
            }
        }
    }

    @ViewBuilder
    private var compactTrailingActions: some View {
        let p = theme.palette

        if isDraft {
            Button { createDraftAndExit() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 46, height: 46)
                    .background(canCreateDraft ? p.accent : p.textPrimary.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(p.outline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .disabled(!canCreateDraft)

        } else if readingMode {
            EmptyView()

        } else if isPreviewOnly {
            if isIPhoneRestrictedReadOnly {
                EmptyView()
            } else if isEditing {
                Button { saveAndExitEditMode() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(p.accent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
            } else {
                Button { enterEditMode() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(p.accent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(p.outline.opacity(0.8), lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
            }

        } else {
            HStack(spacing: 10) {
                compactIconButton(icon: "trash") { showDeleteConfirm = true }

                Button {
                    guard let n = note else { return }
                    n.pinned.toggle()
                    n.updatedAt = .now
                    try? ctx.save()
                    PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
                } label: {
                    Image(systemName: (note?.pinned ?? false) ? "pin.fill" : "pin")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(p.railButton)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }
        }
    }

    private func compactIconButton(icon: String, action: @escaping () -> Void) -> some View {
        let p = theme.palette

        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 46, height: 46)
                .background(p.railButton)
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(p.outline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.textPrimary)
    }

    private func cancelDrawingPaletteAutoMinimize() {
        drawingPaletteHideWorkItem?.cancel()
        drawingPaletteHideWorkItem = nil
    }

    private func bumpDrawingPaletteActivity() {
        guard usesFloatingDrawingPalette else { return }
        cancelDrawingPaletteAutoMinimize()
        drawingPaletteExpanded = true

        guard drawingPaletteAutoMinimize else { return }
        let workItem = DispatchWorkItem {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.90)) {
                drawingPaletteExpanded = false
            }
        }
        drawingPaletteHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: workItem)
    }

    private var textSizeControl: some View {
        let p = theme.palette

        return HStack(spacing: 6) {
            Button {
                textFontSize = max(12, textFontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(p.railButton)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.textPrimary)

            Text("\(Int(textFontSize))")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(p.textPrimary)
                .frame(minWidth: 28)

            Button {
                textFontSize = min(30, textFontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(p.railButton)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.textPrimary)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(p.card.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private var headingTextFontSize: Double {
        max(textFontSize + 8, textFontSize * 1.35)
    }

    private var backLabelText: String {
        if isDraft { return "Cancel" }
        return "Back"
    }

    private var backSystemImage: String {
        if isDraft { return "xmark" }
        return "arrow.left"
    }

    private func handleBackPressed() {
        if isDraft { dismiss(); return }
        if readingMode { dismiss(); return }

        if isPreviewOnly && isEditing {
            if hasUnsavedChanges {
                showUnsavedAlert = true
            } else {
                dismiss()
            }
            return
        }

        if let n = note, !isLocked {
            saveLayers(for: n)
        }
        dismiss()
    }

    private func enterEditMode() {
        guard note != nil else { return }
        if isIPhoneRestrictedReadOnly { return }

        isEditing = true

        snapshot = Snapshot(
            title: titleText,
            textBody: draftTextBody,
            inkData: inkData,
            highlightData: highlightData,
            drawingPaperStyleRaw: drawingPaperStyle.rawValue,
            drawWidth: drawWidth,
            markerWidth: markerWidth,
            drawingLineSpacing: drawingLineSpacing,
            drawingDotSpacing: drawingDotSpacing,
            drawingDotSize: drawingDotSize
        )

        inkUndoStack = []
        highlightUndoStack = []
        lastInkData = inkData
        lastHighlightData = highlightData
    }

    private func saveAndExitEditMode() {
        guard let n = note else { return }
        saveLayers(for: n)

        snapshot = Snapshot(
            title: titleText,
            textBody: draftTextBody,
            inkData: inkData,
            highlightData: highlightData,
            drawingPaperStyleRaw: drawingPaperStyle.rawValue,
            drawWidth: drawWidth,
            markerWidth: markerWidth,
            drawingLineSpacing: drawingLineSpacing,
            drawingDotSpacing: drawingDotSpacing,
            drawingDotSize: drawingDotSize
        )

        isEditing = false
    }

    private func saveAndExit() {
        guard let n = note else { dismiss(); return }
        saveLayers(for: n)
        dismiss()
    }

    // MARK: - Tool Rail (iPad-only)
    @ViewBuilder
    private var toolRail: some View {
        let p = theme.palette

        if readingMode {
            VStack(spacing: 14) {
                ToolHeader(icon: "eye", title: "Read")
                Spacer()
            }
            .frame(width: 96)
            .padding(.top, 6)

        } else if currentKind == .text {
            VStack(spacing: 14) {
                ToolHeader(icon: "textformat", title: "Text")
                Spacer()
                undoButton
            }
            .frame(width: 96)
            .padding(.top, 6)

        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    ToolHeader(icon: headerIconName, title: toolHeaderText)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        toolMiniButton(icon: "pencil.tip", selected: drawTool == .pen) {
                            drawTool = .pen
                            mode = .ink
                        }
                        toolMiniButton(icon: "highlighter", selected: drawTool == .marker) {
                            drawTool = .marker
                            mode = .highlight
                        }
                        toolMiniButton(icon: "lasso", selected: drawTool == .lasso) {
                            drawTool = .lasso
                        }
                        toolMiniButton(icon: "eraser", selected: drawTool == .eraser) {
                            drawTool = .eraser
                        }
                    }

                    VStack(spacing: 10) {
                        Text("Size")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(p.textSecondary)

                        Circle()
                            .fill(selectedInkSwatchColor.opacity(drawTool == .marker ? 0.55 : 0.98))
                            .frame(width: CGFloat(sizeBinding.wrappedValue), height: CGFloat(sizeBinding.wrappedValue))
                            .overlay(
                                Circle()
                                    .stroke(
                                        selectedInkNeedsDarkBorder ? p.textPrimary.opacity(0.22) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                            .padding(.bottom, 2)

                        VerticalValueSlider(
                            value: sizeBinding,
                            range: 2...24,
                            height: 260,
                            trackWidth: 6,
                            thumbSize: 18
                        )
                    }
                    .padding(12)
                    .background(p.card.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )

                    VStack(spacing: 10) {
                        Text("Color")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(p.textSecondary)

                        VStack(spacing: 10) {
                            ForEach(colorPalette, id: \.self) { c in
                                ZStack {
                                    colorSwatch(for: c)

                                    Circle()
                                        .stroke(
                                            drawColor == c ? p.textPrimary.opacity(0.28) : Color.clear,
                                            lineWidth: 3
                                        )
                                        .frame(width: 34, height: 34)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    drawColor = c
                                    if c == .rainbow { showCustomColorPicker = true }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(p.card.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )

                    undoButton
                        .padding(.bottom, 6)
                }
            }
            .frame(width: 96)
            .padding(.top, 6)
        }
    }

    private var headerIconName: String {
        switch drawTool {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .lasso: return "lasso"
        case .eraser: return "eraser"
        }
    }

    private var sizeBinding: Binding<Double> {
        Binding(
            get: {
                if drawTool == .marker { return markerWidth }
                return drawWidth
            },
            set: { newValue in
                if drawTool == .marker { markerWidth = newValue }
                else { drawWidth = newValue }
            }
        )
    }

    private var colorPalette: [PLEditorInkColor] { PLEditorInkColor.allCases }

    @ViewBuilder
    private func colorSwatch(for color: PLEditorInkColor) -> some View {
        let p = theme.palette

        if color == .rainbow {
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            .red, .orange, .yellow, .green, .blue, .purple, .red
                        ]),
                        center: .center
                    )
                )
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .stroke(p.textPrimary.opacity(0.15), lineWidth: 1)
                )
        } else {
            Circle()
                .fill(color.swatch)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .stroke(
                            color.needsDarkBorder ? p.textPrimary.opacity(0.18) : Color.clear,
                            lineWidth: 1
                        )
                )
        }
    }

    private func toolMiniButton(icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        let p = theme.palette

        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 40, height: 40)
                .background(selected ? p.accent.opacity(0.55) : p.railButton)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(p.outline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.textPrimary)
        .disabled(isLocked)
        .opacity(isLocked ? 0.35 : 1.0)
    }

    private var undoButton: some View {
        let p = theme.palette

        return Button { performUndo() } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 56, height: 56)
                    .background(p.railButton)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )

                Text("Undo")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(p.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.textPrimary)
        .disabled(isLocked)
        .opacity(isLocked ? 0.35 : 1.0)
    }

    private func performUndo() {
        guard !isLocked else { return }

        switch currentKind {
        case .text:
            undoManager?.undo()

        case .drawing:
            if let prev = inkUndoStack.popLast() {
                inkData = prev
                lastInkData = prev
            }

        case .photo:
            if mode == .highlight {
                if let prev = highlightUndoStack.popLast() {
                    highlightData = prev
                    lastHighlightData = prev
                }
            } else {
                if let prev = inkUndoStack.popLast() {
                    inkData = prev
                    lastInkData = prev
                }
            }
        }
    }

    // MARK: - Editor Content
    @ViewBuilder
    private var editorContent: some View {
        switch currentKind {
        case .text: textEditor
        case .drawing: drawingEditor
        case .photo: photoEditor
        }
    }

    private var textEditor: some View {
        let p = theme.palette

        return VStack(spacing: 0) {
            if !isLocked {
                textQuickActionsBar
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                Rectangle()
                    .fill(p.outline.opacity(0.9))
                    .frame(height: 1)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($textBlocks) { $block in
                        textBlockRow(block: $block)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .foregroundStyle(p.textPrimary)
        }
        .background(p.card.opacity(0.32))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { ensureTextBlocksSeeded() }
        .onChange(of: focusedTextBlockID) { _, newID in
            if let newID { selectedTextBlockID = newID }
        }
        .onChange(of: textBlocks) { _, _ in
            syncDraftTextFromBlocks()
        }
    }

    private var textQuickActionsBar: some View {
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                textActionButton("Checklist", icon: "checkmark.square") {
                    insertTextBlock(kind: .checklist, text: "", checked: false)
                }
                textActionButton("Bullet", icon: "list.bullet") {
                    insertTextBlock(kind: .body, text: "• ")
                }
                textActionButton("Numbered", icon: "list.number") {
                    insertTextBlock(kind: .body, text: "\(nextNumberedLinePrefix()) ")
                }
                textActionButton(
                    "Heading",
                    icon: "textformat",
                    selected: selectedTextBlockKind == .heading
                ) {
                    toggleHeadingForSelectedLine()
                }
                textActionButton("Divider", icon: "minus") {
                    insertTextBlock(kind: .divider)
                }
                textActionButton("Date", icon: "calendar") {
                    insertTextBlock(kind: .body, text: Date.now.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func textActionButton(
        _ title: String,
        icon: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let p = theme.palette

        return Button(action: {
            guard !isLocked else { return }
            action()
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))

                Text(title)
                    .font(.system(size: 12, weight: .bold))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? p.accent.opacity(0.62) : p.railButton)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(p.outline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.textPrimary)
        .disabled(isLocked)
        .opacity(isLocked ? 0.35 : 1.0)
    }

    private func nextNumberedLinePrefix() -> String {
        let lines = textBodyFromBlocks(textBlocks).split(separator: "\n")
        if let last = lines.last,
           let number = Int(last.split(separator: ".").first ?? "") {
            return "\(number + 1)."
        }
        return "1."
    }

    @ViewBuilder
    private func textBlockRow(block: Binding<PLTextBlock>) -> some View {
        let p = theme.palette
        let isSelected = selectedTextBlockID == block.wrappedValue.id
        let kind = block.wrappedValue.kind

        switch kind {
        case .divider:
            HStack(spacing: 10) {
                Rectangle()
                    .fill(p.textPrimary.opacity(0.26))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)

                if !isLocked {
                    Button {
                        removeTextBlock(id: block.wrappedValue.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(p.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(isSelected ? p.accent.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { selectedTextBlockID = block.wrappedValue.id }

        case .checklist:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    toggleChecklist(id: block.wrappedValue.id)
                } label: {
                    Image(systemName: block.wrappedValue.checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(block.wrappedValue.checked ? p.accent : p.textSecondary)

                if isLocked {
                    Text(block.wrappedValue.text.isEmpty ? " " : block.wrappedValue.text)
                        .font(.system(size: textFontSize, weight: .regular))
                        .foregroundStyle(p.textPrimary.opacity(block.wrappedValue.checked ? 0.58 : 0.92))
                        .strikethrough(block.wrappedValue.checked, color: p.textSecondary.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("List item", text: block.text, axis: .vertical)
                        .font(.system(size: textFontSize, weight: .regular))
                        .textFieldStyle(.plain)
                        .focused($focusedTextBlockID, equals: block.wrappedValue.id)
                        .onTapGesture { selectedTextBlockID = block.wrappedValue.id }
                        .submitLabel(.return)
                        .onSubmit {
                            insertTextBlock(kind: .body, after: block.wrappedValue.id)
                        }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? p.accent.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .heading, .body:
            if isLocked {
                Text(block.wrappedValue.text.isEmpty ? " " : block.wrappedValue.text)
                    .font(
                        kind == .heading
                        ? .system(size: headingTextFontSize, weight: .heavy)
                        : .system(size: textFontSize, weight: .regular)
                    )
                    .foregroundStyle(p.textPrimary.opacity(kind == .heading ? 0.98 : 0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, kind == .heading ? 8 : 4)
                    .padding(.horizontal, 8)
                    .background(isSelected ? p.accent.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { selectedTextBlockID = block.wrappedValue.id }
            } else {
                TextField(kind == .heading ? "Heading" : "Write...", text: block.text, axis: .vertical)
                    .font(
                        kind == .heading
                        ? .system(size: headingTextFontSize, weight: .heavy)
                        : .system(size: textFontSize, weight: .regular)
                    )
                    .textFieldStyle(.plain)
                    .focused($focusedTextBlockID, equals: block.wrappedValue.id)
                    .onTapGesture { selectedTextBlockID = block.wrappedValue.id }
                    .submitLabel(.return)
                    .onSubmit {
                        insertTextBlock(kind: .body, after: block.wrappedValue.id)
                    }
                    .padding(.vertical, kind == .heading ? 8 : 4)
                    .padding(.horizontal, 8)
                    .background(isSelected ? p.accent.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var selectedTextBlockKind: PLTextBlockKind? {
        guard let id = selectedTextBlockID else { return nil }
        return textBlocks.first(where: { $0.id == id })?.kind
    }

    private func ensureTextBlocksSeeded() {
        if textBlocks.isEmpty {
            textBlocks = [PLTextBlock(kind: .body, text: "")]
        }
        if selectedTextBlockID == nil {
            selectedTextBlockID = textBlocks.first?.id
        }
    }

    private func selectedTextBlockIndex() -> Int? {
        guard let id = selectedTextBlockID else { return nil }
        return textBlocks.firstIndex(where: { $0.id == id })
    }

    private func insertionIndex(after selectedID: UUID?) -> Int {
        guard let selectedID,
              let idx = textBlocks.firstIndex(where: { $0.id == selectedID }) else {
            return textBlocks.count
        }
        return min(idx + 1, textBlocks.count)
    }

    private func insertTextBlock(kind: PLTextBlockKind, text: String = "", checked: Bool = false, after selectedID: UUID? = nil) {
        ensureTextBlocksSeeded()
        let idx = insertionIndex(after: selectedID ?? selectedTextBlockID)
        let block = PLTextBlock(kind: kind, text: text, checked: checked)
        textBlocks.insert(block, at: idx)
        selectedTextBlockID = block.id
        if !isLocked, kind != .divider {
            focusedTextBlockID = block.id
        }
    }

    private func removeTextBlock(id: UUID) {
        guard !isLocked else { return }
        guard let idx = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        textBlocks.remove(at: idx)

        if textBlocks.isEmpty {
            let replacement = PLTextBlock(kind: .body, text: "")
            textBlocks = [replacement]
            selectedTextBlockID = replacement.id
            focusedTextBlockID = replacement.id
            return
        }

        let nextIdx = min(idx, textBlocks.count - 1)
        selectedTextBlockID = textBlocks[nextIdx].id
    }

    private func toggleHeadingForSelectedLine() {
        ensureTextBlocksSeeded()

        guard let idx = selectedTextBlockIndex() else {
            insertTextBlock(kind: .heading)
            return
        }

        guard textBlocks[idx].kind != .divider else { return }
        textBlocks[idx].kind = (textBlocks[idx].kind == .heading) ? .body : .heading
    }

    private func toggleChecklist(id: UUID) {
        guard let idx = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        textBlocks[idx].checked.toggle()
        selectedTextBlockID = id

        if isLocked {
            syncDraftTextFromBlocks()
            persistTextBodyImmediatelyIfPossible()
        }
    }

    private func syncDraftTextFromBlocks() {
        draftTextBody = textBodyFromBlocks(textBlocks)
    }

    private func persistTextBodyImmediatelyIfPossible() {
        guard let n = note, !isDraft, n.kind == .text else { return }
        guard !readingMode else { return }
        n.textBody = draftTextBody
        n.updatedAt = .now
        try? ctx.save()
        PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
    }

    private func parseTextBlocks(from raw: String) -> [PLTextBlock] {
        let lines = raw.components(separatedBy: "\n")
        if lines.isEmpty || (lines.count == 1 && lines[0].isEmpty) {
            return [PLTextBlock(kind: .body, text: "")]
        }

        return lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                return PLTextBlock(kind: .divider)
            }

            let lower = line.lowercased()
            if lower.hasPrefix("- [x] ") {
                return PLTextBlock(kind: .checklist, text: String(line.dropFirst(6)), checked: true)
            }
            if lower.hasPrefix("- [ ] ") {
                return PLTextBlock(kind: .checklist, text: String(line.dropFirst(6)), checked: false)
            }
            if lower.hasPrefix("[x] ") {
                return PLTextBlock(kind: .checklist, text: String(line.dropFirst(4)), checked: true)
            }
            if lower.hasPrefix("[ ] ") {
                return PLTextBlock(kind: .checklist, text: String(line.dropFirst(4)), checked: false)
            }

            if line.hasPrefix("## ") {
                return PLTextBlock(kind: .heading, text: String(line.dropFirst(3)))
            }
            if line.hasPrefix("# ") {
                return PLTextBlock(kind: .heading, text: String(line.dropFirst(2)))
            }

            return PLTextBlock(kind: .body, text: line)
        }
    }

    private func textBodyFromBlocks(_ blocks: [PLTextBlock]) -> String {
        blocks.map { block in
            switch block.kind {
            case .body:
                return block.text
            case .heading:
                return "# \(block.text)"
            case .checklist:
                return block.checked ? "- [x] \(block.text)" : "- [ ] \(block.text)"
            case .divider:
                return "---"
            }
        }
        .joined(separator: "\n")
    }

    private var drawingEditor: some View {
        GeometryReader { geo in
#if canImport(UIKit)
            PencilCanvasView(
                drawingData: $inkData,
                tool: toolForCurrentState(),
                toolStateID: currentToolStateID(),
                drawingPolicy: canvasDrawingPolicy,
                allowsFingerDrawing: !applePencilOnlyDraw,
                isReadOnly: isLocked,
                isInfiniteCanvas: true,
                paperStyle: drawingPaperStyle,
                paperBaseColor: drawingPaperBaseUIColor,
                paperGuideColor: drawingPaperGuideUIColor,
                lineSpacing: CGFloat(drawingLineSpacing),
                dotSpacing: CGFloat(drawingDotSpacing),
                dotSize: CGFloat(drawingDotSize),
                resetViewportToken: zoomResetToken,
                onZoomingChanged: { zooming in
                    if isZooming != zooming { isZooming = zooming }
                }
            )
            .frame(width: geo.size.width, height: geo.size.height)
#else
            PencilCanvasView(
                drawingData: $inkData,
                tool: toolForCurrentState(),
                toolStateID: currentToolStateID(),
                drawingPolicy: canvasDrawingPolicy,
                allowsFingerDrawing: !applePencilOnlyDraw,
                isReadOnly: isLocked,
                isInfiniteCanvas: true,
                paperStyle: drawingPaperStyle,
                lineSpacing: CGFloat(drawingLineSpacing),
                dotSpacing: CGFloat(drawingDotSpacing),
                dotSize: CGFloat(drawingDotSize),
                resetViewportToken: zoomResetToken,
                onZoomingChanged: { zooming in
                    if isZooming != zooming { isZooming = zooming }
                }
            )
            .frame(width: geo.size.width, height: geo.size.height)
#endif
        }
        .allowsHitTesting(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var photoEditor: some View {
        ZStack {
#if canImport(UIKit)
            if let uiImage = currentPhotoUIImage() {
                GeometryReader { geo in
                    let fitted = fittedRect(imageSize: uiImage.size, in: geo.size)

                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    let canEditOverlays = (!isLocked && !isPhone)

                    PencilCanvasView(
                        drawingData: $highlightData,
                        tool: toolForCurrentState(highlightLayer: true),
                        toolStateID: currentToolStateID(highlightLayer: true),
                        drawingPolicy: canvasDrawingPolicy,
                        allowsFingerDrawing: !applePencilOnlyDraw,
                        isReadOnly: !(canEditOverlays && mode == .highlight)
                    )
                        .frame(width: fitted.size.width, height: fitted.size.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .allowsHitTesting(canEditOverlays && mode == .highlight)

                    PencilCanvasView(
                        drawingData: $inkData,
                        tool: toolForCurrentState(highlightLayer: false),
                        toolStateID: currentToolStateID(highlightLayer: false),
                        drawingPolicy: canvasDrawingPolicy,
                        allowsFingerDrawing: !applePencilOnlyDraw,
                        isReadOnly: !(canEditOverlays && mode == .ink)
                    )
                        .frame(width: fitted.size.width, height: fitted.size.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .allowsHitTesting(canEditOverlays && mode == .ink)
                }
            } else {
                Text("No photo")
                    .font(.headline)
                    .opacity(0.7)
            }
#else
            Text("Photo notes are view-only here.")
                .font(.headline)
                .opacity(0.7)
#endif
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

#if canImport(UIKit)
    private func currentPhotoUIImage() -> UIImage? {
        if isDraft { return draftPhotoUIImage }
        if let n = note, let photoFilename = n.photoFilename,
           let data = FileStore.shared.readData(filename: photoFilename),
           let uiImage = UIImage(data: data) { return uiImage }
        return nil
    }
#endif

    // MARK: - PencilKit tool building
    private func toolForCurrentState(highlightLayer: Bool? = nil) -> PKTool {
        if isLocked { return PKEraserTool(.bitmap) }

        if drawTool == .lasso { return PKLassoTool() }
        if drawTool == .eraser { return PKEraserTool(.bitmap) }

        if currentKind == .photo {
            let isHL = (highlightLayer ?? (mode == .highlight))
            if isHL {
#if canImport(UIKit)
                return PKInkingTool(.marker, color: selectedInkUIColor.withAlphaComponent(0.38), width: CGFloat(markerWidth))
#else
                return PKInkingTool(.marker, color: .yellow, width: CGFloat(markerWidth))
#endif
            } else {
#if canImport(UIKit)
                return PKInkingTool(.pen, color: selectedInkUIColor, width: CGFloat(drawWidth))
#else
                return PKInkingTool(.pen, color: .black, width: CGFloat(drawWidth))
#endif
            }
        }

        if drawTool == .marker || mode == .highlight {
#if canImport(UIKit)
            return PKInkingTool(.marker, color: selectedInkUIColor.withAlphaComponent(0.38), width: CGFloat(markerWidth))
#else
            return PKInkingTool(.marker, color: .yellow, width: CGFloat(markerWidth))
#endif
        } else {
#if canImport(UIKit)
            return PKInkingTool(.pen, color: selectedInkUIColor, width: CGFloat(drawWidth))
#else
            return PKInkingTool(.pen, color: .black, width: CGFloat(drawWidth))
#endif
        }
    }

    private func currentToolStateID(highlightLayer: Bool? = nil) -> String {
        let resolvedTool: String
        if isLocked {
            resolvedTool = "locked"
        } else if drawTool == .lasso {
            resolvedTool = "lasso"
        } else if drawTool == .eraser {
            resolvedTool = "eraser"
        } else if currentKind == .photo {
            resolvedTool = (highlightLayer ?? (mode == .highlight)) ? "photo-marker" : "photo-pen"
        } else if drawTool == .marker || mode == .highlight {
            resolvedTool = "marker"
        } else {
            resolvedTool = "pen"
        }

#if canImport(UIKit)
        let inkDescription = selectedInkUIColor.description
#else
        let inkDescription = drawColor.rawValue
#endif

        return [
            resolvedTool,
            drawColor.rawValue,
            String(format: "%.3f", drawWidth),
            String(format: "%.3f", markerWidth),
            applePencilOnlyDraw ? "pencil-only" : "any-input",
            inkDescription
        ].joined(separator: "|")
    }

    private var isThemeMostlyLight: Bool {
#if canImport(UIKit)
        colorLuminance(UIColor(theme.palette.background)) >= 0.55
#else
        true
#endif
    }

    private func applyAdaptiveDefaultInkColorIfNeeded(force: Bool = false) {
        guard currentKind == .drawing || currentKind == .photo else { return }
        if !force, hasMarkupContent { return }
        drawColor = adaptiveDefaultInkColor()
    }

    private var hasMarkupContent: Bool {
        !isDrawingDataEmpty(inkData) || !isDrawingDataEmpty(highlightData)
    }

    private func adaptiveDefaultInkColor() -> PLEditorInkColor {
        if currentKind == .drawing {
            return .black
        }
#if canImport(UIKit)
        if currentKind == .photo,
           let image = currentPhotoUIImage(),
           let imageLuminance = averageImageLuminance(image) {
            return imageLuminance >= 0.55 ? .black : .white
        }
#endif
        return isThemeMostlyLight ? .black : .white
    }

    private func isDrawingDataEmpty(_ data: Data) -> Bool {
        guard let drawing = try? PKDrawing(data: data) else { return true }
        return drawing.bounds.isEmpty
    }

#if canImport(UIKit)
    private func colorLuminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
        }

        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &a) {
            return white
        }

        return 1
    }

    private func averageImageLuminance(_ image: UIImage) -> CGFloat? {
        guard let cgImage = image.cgImage else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard !extent.isEmpty else { return nil }

        let filter = CIFilter(name: "CIAreaAverage")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let output = filter?.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let r = CGFloat(pixel[0]) / 255.0
        let g = CGFloat(pixel[1]) / 255.0
        let b = CGFloat(pixel[2]) / 255.0
        return (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    }
#endif

    // MARK: - Undo stack helpers
    private func pushInkUndoIfNeeded(_ newValue: Data) {
        if newValue == lastInkData { return }
        if isPreviewOnly && !isEditing { return }

        inkUndoStack.append(lastInkData)
        if inkUndoStack.count > 40 { inkUndoStack.removeFirst(inkUndoStack.count - 40) }
        lastInkData = newValue
    }

    private func pushHighlightUndoIfNeeded(_ newValue: Data) {
        if newValue == lastHighlightData { return }
        if isPreviewOnly && !isEditing { return }

        highlightUndoStack.append(lastHighlightData)
        if highlightUndoStack.count > 40 { highlightUndoStack.removeFirst(highlightUndoStack.count - 40) }
        lastHighlightData = newValue
    }

    // MARK: - Draft create
    @MainActor
    private func createDraftAndExit() {
        guard isDraft, let draft = initialDraft else { return }
        if isPhone, draft.kind == .drawing { return }

        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let newNote = PLNote(title: trimmed, kind: draft.kind, folderID: draft.folderID)

        if draft.kind != .text {
            newNote.mediaRotationQuarterTurns = (effectiveDraftRotationQuarterTurns % 4)
        }

        switch draft.kind {
        case .text:
            newNote.textBody = draftTextBody

        case .drawing:
            newNote.drawingPaperStyle = drawingPaperStyle
            newNote.drawingPenWidth = drawWidth
            newNote.drawingMarkerWidth = markerWidth
            newNote.drawingLineSpacing = drawingLineSpacing
            newNote.drawingDotSpacing = drawingDotSpacing
            newNote.drawingDotSize = drawingDotSize
            if newNote.inkDrawingFilename == nil {
                newNote.inkDrawingFilename = FileStore.shared.writeData(inkData, preferredName: "drawing.pkd")
            } else if let f = newNote.inkDrawingFilename {
                FileStore.shared.overwriteData(inkData, filename: f)
            }

        case .photo:
            newNote.drawingPenWidth = drawWidth
            newNote.drawingMarkerWidth = markerWidth
            if let photoData = draft.photoData,
               let photoFilename = FileStore.shared.writeData(photoData, preferredName: "photo.jpg") {
                newNote.photoFilename = photoFilename
            }

            let empty = PKDrawing().dataRepresentation()
            newNote.inkDrawingFilename = FileStore.shared.writeData(empty, preferredName: "ink.pkd")
            newNote.highlightDrawingFilename = FileStore.shared.writeData(empty, preferredName: "highlight.pkd")
        }

        ctx.insert(newNote)
        try? ctx.save()

        PaperLinkSyncManager.shared.enqueueNote(newNote, ctx: ctx)

        dismiss()

    }

    // MARK: - Existing load/save
    private func loadLayers(for note: PLNote) {
        drawWidth = note.drawingPenWidth
        markerWidth = note.drawingMarkerWidth
        drawingLineSpacing = note.drawingLineSpacing
        drawingDotSpacing = note.drawingDotSpacing
        drawingDotSize = note.drawingDotSize

        if note.kind == .drawing {
            drawingPaperStyle = note.drawingPaperStyle
            if note.inkDrawingFilename == nil {
                note.inkDrawingFilename = FileStore.shared.writeData(PKDrawing().dataRepresentation(), preferredName: "drawing.pkd")
                note.updatedAt = .now
                try? ctx.save()
                PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
            }
            if let f = note.inkDrawingFilename,
               let d = FileStore.shared.readData(filename: f),
               !d.isEmpty { inkData = d }
        }

        if note.kind == .photo {
            var didBackfill = false
            if note.inkDrawingFilename == nil {
                note.inkDrawingFilename = FileStore.shared.writeData(PKDrawing().dataRepresentation(), preferredName: "ink.pkd")
                didBackfill = true
            }
            if note.highlightDrawingFilename == nil {
                note.highlightDrawingFilename = FileStore.shared.writeData(PKDrawing().dataRepresentation(), preferredName: "highlight.pkd")
                didBackfill = true
            }
            if didBackfill {
                note.updatedAt = .now
            }
            try? ctx.save()
            if didBackfill {
                PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
            }

            if let f = note.inkDrawingFilename, let d = FileStore.shared.readData(filename: f), !d.isEmpty { inkData = d }
            if let f = note.highlightDrawingFilename, let d = FileStore.shared.readData(filename: f), !d.isEmpty { highlightData = d }
        }
    }

    private func saveLayers(for note: PLNote) {
        if readingMode { return }
        if isPreviewOnly && !isEditing { return }
        if isIPhoneRestrictedReadOnly { return }

        note.title = titleText

        if note.kind == .text {
            note.textBody = draftTextBody
            note.updatedAt = .now
            try? ctx.save()
            PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
            return
        }

        if note.kind == .drawing {
            note.drawingPaperStyle = drawingPaperStyle
            note.drawingPenWidth = drawWidth
            note.drawingMarkerWidth = markerWidth
            note.drawingLineSpacing = drawingLineSpacing
            note.drawingDotSpacing = drawingDotSpacing
            note.drawingDotSize = drawingDotSize
            if note.inkDrawingFilename == nil {
                note.inkDrawingFilename = FileStore.shared.writeData(inkData, preferredName: "drawing.pkd")
            } else if let f = note.inkDrawingFilename {
                FileStore.shared.overwriteData(inkData, filename: f)
            }
        }

        if note.kind == .photo {
            note.drawingPenWidth = drawWidth
            note.drawingMarkerWidth = markerWidth
            if note.inkDrawingFilename == nil {
                note.inkDrawingFilename = FileStore.shared.writeData(inkData, preferredName: "ink.pkd")
            } else if let f = note.inkDrawingFilename {
                FileStore.shared.overwriteData(inkData, filename: f)
            }

            if note.highlightDrawingFilename == nil {
                note.highlightDrawingFilename = FileStore.shared.writeData(highlightData, preferredName: "highlight.pkd")
            } else if let f = note.highlightDrawingFilename {
                FileStore.shared.overwriteData(highlightData, filename: f)
            }
        }

        note.updatedAt = .now
        try? ctx.save()
        PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
    }

    // MARK: - Trash (soft delete)
    @MainActor
    private func moveNoteToTrashAndExit() {
        guard let n = note else { return }
        n.deletedAt = .now
        n.updatedAt = .now
        try? ctx.save()
        PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
        dismiss()
    }

    // MARK: - Geometry helper
    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let imageAspect = imageSize.width / max(imageSize.height, 1)
        let containerAspect = container.width / max(container.height, 1)

        var size: CGSize
        if imageAspect > containerAspect {
            size = CGSize(width: container.width, height: container.width / imageAspect)
        } else {
            size = CGSize(width: container.height * imageAspect, height: container.height)
        }
        let origin = CGPoint(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - Small UI helpers

private struct FloatingDrawingPalette: View {
    @EnvironmentObject private var theme: PLThemeStore

    let containerSize: CGSize
    @Binding var isExpanded: Bool
    @Binding var snapEdge: PLDrawingPaletteSnapEdge
    @Binding var edgeProgress: CGFloat
    @Binding var isDragging: Bool
    @Binding var selectedTool: PLDrawTool
    @Binding var selectedColor: PLEditorInkColor
    @Binding var customColor: Color
    @Binding var penWidth: Double
    @Binding var markerWidth: Double
    @Binding var drawWithFinger: Bool
    @Binding var autoMinimize: Bool

    let onSelectTool: (PLDrawTool) -> Void
    let onUndo: () -> Void
    let onActivity: () -> Void

    @State private var dragOriginCenter: CGPoint? = nil
    @State private var liveCenter: CGPoint? = nil
    @State private var showSettings = false
    @State private var showCustomColorPopover = false

    private let outerInset: CGFloat = 18
    private let edgeBreakDistance: CGFloat = 92
    private let snapRetentionDistance: CGFloat = 26

    private var isVerticalDock: Bool {
        snapEdge == .leading || snapEdge == .trailing
    }

    private var baseExpandedPaletteSize: CGSize {
        if isVerticalDock {
            return CGSize(width: 152, height: min(max(containerSize.height - 40, 292), 420))
        }
        return CGSize(width: min(max(containerSize.width - 28, 316), 460), height: 196)
    }

    private var paletteSize: CGSize {
        if isExpanded {
            return baseExpandedPaletteSize
        }
        return CGSize(width: 72, height: 72)
    }

    private var currentCenter: CGPoint {
        liveCenter ?? snappedCenter
    }

    private var currentOrigin: CGPoint {
        CGPoint(
            x: currentCenter.x - (paletteSize.width * 0.5),
            y: currentCenter.y - (paletteSize.height * 0.5)
        )
    }

    private var currentWidthValue: Binding<Double> {
        Binding(
            get: { selectedTool == .marker ? markerWidth : penWidth },
            set: { newValue in
                if selectedTool == .marker {
                    markerWidth = newValue
                } else {
                    penWidth = newValue
                }
                onActivity()
            }
        )
    }

    private var supportsWidthControls: Bool {
        selectedTool == .pen || selectedTool == .marker
    }

    private var presetColors: [PLEditorInkColor] {
        [.black, .white, .blue, .green, .orange, .red]
    }

    private var extendedPresetColors: [PLEditorInkColor] {
        [.black, .white, .blue, .green, .orange, .red, .purple]
    }

    private var selectedDisplayColor: Color {
        selectedColor == .rainbow ? customColor : selectedColor.swatch
    }

    private var paletteFill: Color {
        Color.white.opacity(0.94)
    }

    private var paletteForeground: Color {
        Color.black.opacity(0.82)
    }

    private var paletteSecondaryForeground: Color {
        Color.black.opacity(0.42)
    }

    private var paletteDivider: Color {
        Color.black.opacity(0.08)
    }

    private var paletteButtonFill: Color {
        Color.black.opacity(0.05)
    }

    private var paletteButtonSelectedFill: Color {
        Color.black.opacity(0.11)
    }

    private var paletteShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isExpanded ? 34 : 24, style: .continuous)
    }

    private var paletteTransitionAnchor: UnitPoint {
        switch snapEdge {
        case .top:
            return .top
        case .bottom:
            return .bottom
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    private var expandedPaletteTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.92, anchor: paletteTransitionAnchor).combined(with: .opacity),
            removal: .scale(scale: 0.97, anchor: paletteTransitionAnchor).combined(with: .opacity)
        )
    }

    private var minimizedPaletteTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.72, anchor: paletteTransitionAnchor).combined(with: .opacity),
            removal: .scale(scale: 0.88, anchor: paletteTransitionAnchor).combined(with: .opacity)
        )
    }

    private var snappedCenter: CGPoint {
        center(for: snapEdge, progress: edgeProgress, paletteSize: paletteSize)
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { customColor },
            set: { newValue in
                dismissActiveTextInput()
                customColor = newValue
                selectedColor = .rainbow
                onActivity()
            }
        )
    }

    private func dismissActiveTextInput() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }

    private func sanitizePalettePosition() {
        let clampedCenter = clamped(center: currentCenter, paletteSize: paletteSize)
        let target = nearestSnapTarget(
            to: clampedCenter,
            currentEdge: snapEdge,
            start: snappedCenter
        )
        snapEdge = target.edge
        edgeProgress = target.progress
        liveCenter = nil
        dragOriginCenter = nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if isExpanded {
                    expandedPalette
                        .transition(expandedPaletteTransition)
                        .zIndex(1)
                } else {
                    minimizedPalette
                        .transition(minimizedPaletteTransition)
                        .zIndex(0)
                }
            }
            .frame(width: paletteSize.width, height: paletteSize.height)
            .offset(x: currentOrigin.x, y: currentOrigin.y)
            .contentShape(paletteShape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(isDragging ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.88), value: isExpanded)
        .animation(isDragging ? nil : .interactiveSpring(response: 0.30, dampingFraction: 0.90), value: snapEdge)
        .animation(isDragging ? nil : .interactiveSpring(response: 0.30, dampingFraction: 0.90), value: edgeProgress)
        .onAppear {
            sanitizePalettePosition()
        }
        .onChange(of: containerSize) { _, _ in
            sanitizePalettePosition()
        }
        .onChange(of: isExpanded) { _, _ in
            sanitizePalettePosition()
        }
    }

    private var expandedPalette: some View {
        paletteBody
            .frame(width: baseExpandedPaletteSize.width, height: baseExpandedPaletteSize.height)
            .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 10)
    }

    private var paletteBody: some View {
        VStack(spacing: 0) {
            dragHandle
            if isVerticalDock {
                verticalPaletteContent
            } else {
                horizontalPaletteContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            paletteShape
                .fill(paletteFill)
                .contentShape(paletteShape)
                .onTapGesture {
                    onActivity()
                }
        )
        .overlay(
            paletteShape
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .contentShape(paletteShape)
    }

    private var horizontalPaletteContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                paletteCircleButton(systemName: "arrow.uturn.backward", enabled: true) {
                    dismissActiveTextInput()
                    onUndo()
                }
                .opacity(0.8)

                paletteCircleButton(systemName: "ellipsis", enabled: true) {
                    dismissActiveTextInput()
                    showSettings = true
                }
                .popover(isPresented: $showSettings) {
                    paletteSettings
                }

                paletteCircleButton(systemName: "chevron.down", enabled: true) {
                    dismissActiveTextInput()
                    withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.88)) {
                        isExpanded = false
                    }
                }

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44, maximum: 64), spacing: 10), count: 4), spacing: 10) {
                ForEach([PLDrawTool.pen, .marker, .lasso, .eraser], id: \.self) { tool in
                    toolButton(for: tool)
                }
            }

            if supportsWidthControls {
                widthCluster
                    .frame(maxWidth: .infinity)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 40, maximum: 56), spacing: 10), count: 4), spacing: 10) {
                ForEach(extendedPresetColors, id: \.self) { color in
                    colorButton(for: color)
                }
                customColorButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var verticalPaletteContent: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                paletteCircleButton(systemName: "arrow.uturn.backward", enabled: true) {
                    dismissActiveTextInput()
                    onUndo()
                }
                .opacity(0.8)

                paletteCircleButton(systemName: "ellipsis", enabled: true) {
                    dismissActiveTextInput()
                    showSettings = true
                }
                .popover(isPresented: $showSettings) {
                    paletteSettings
                }

                paletteCircleButton(systemName: "chevron.down", enabled: true) {
                    dismissActiveTextInput()
                    withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.88)) {
                        isExpanded = false
                    }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44, maximum: 52), spacing: 10), count: 2), spacing: 10) {
                ForEach([PLDrawTool.pen, .marker, .lasso, .eraser], id: \.self) { tool in
                    toolButton(for: tool)
                }
            }

            if supportsWidthControls {
                widthCluster
                    .frame(maxWidth: .infinity)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 40, maximum: 48), spacing: 10), count: 2), spacing: 10) {
                ForEach(extendedPresetColors, id: \.self) { color in
                    colorButton(for: color)
                }
                customColorButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    private var minimizedPalette: some View {
        Button {
            dismissActiveTextInput()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isExpanded = true
            }
            onActivity()
        } label: {
            ZStack {
                paletteShape
                    .fill(paletteFill)

                VStack(spacing: 6) {
                    Image(systemName: iconName(for: selectedTool))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(paletteForeground)

                    Circle()
                        .fill(selectedDisplayColor)
                        .frame(width: 12, height: 12)
                }
            }
            .overlay(
                paletteShape
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .contentShape(paletteShape)
        .simultaneousGesture(paletteDragGesture)
    }

    private var paletteSettings: some View {
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 12) {
            Text("Palette")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(paletteForeground)

            Toggle("Auto-Minimize", isOn: $autoMinimize)
                .font(.system(size: 15, weight: .semibold))
                .tint(p.accent)
                .onChange(of: autoMinimize) { _, _ in
                    onActivity()
                }

            Toggle("Draw with Finger", isOn: $drawWithFinger)
                .font(.system(size: 15, weight: .semibold))
                .tint(p.accent)

            Text("Turn off finger drawing for stronger palm rejection.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(paletteSecondaryForeground)
        }
        .padding(18)
        .frame(width: 280, alignment: .leading)
        .background(paletteFill)
    }

    private var divider: some View {
        Rectangle()
            .fill(paletteDivider)
            .frame(width: 1, height: 28)
    }

    private var dragHandle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))

            Capsule()
                .fill(paletteSecondaryForeground.opacity(0.22))
                .frame(width: 42, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .highPriorityGesture(paletteDragGesture)
    }

    private var widthCluster: some View {
        HStack(spacing: 8) {
            paletteCircleButton(systemName: "minus", enabled: true) {
                currentWidthValue.wrappedValue = max(1, currentWidthValue.wrappedValue - 1)
            }

            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(selectedDisplayColor.opacity(selectedTool == .marker ? 0.50 : 0.95))
                    .frame(width: max(6, min(CGFloat(currentWidthValue.wrappedValue), 16)), height: 28)

                Text("\(Int(currentWidthValue.wrappedValue))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(paletteSecondaryForeground)
            }
            .frame(width: 28)

            paletteCircleButton(systemName: "plus", enabled: true) {
                currentWidthValue.wrappedValue = min(selectedTool == .marker ? 36 : 24, currentWidthValue.wrappedValue + 1)
            }
        }
    }

    private func paletteCircleButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            dismissActiveTextInput()
            action()
            onActivity()
        }) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(enabled ? paletteButtonFill : paletteButtonFill.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? paletteForeground : paletteSecondaryForeground)
        .disabled(!enabled)
    }

    private func toolButton(for tool: PLDrawTool) -> some View {
        Button {
            onSelectTool(tool)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: iconName(for: tool))
                    .font(.system(size: 18, weight: .semibold))

                Capsule()
                    .fill(selectedTool == tool ? paletteForeground.opacity(0.88) : paletteSecondaryForeground.opacity(0.25))
                    .frame(width: 20, height: 3)
            }
            .frame(width: 48, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selectedTool == tool ? paletteButtonSelectedFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(paletteForeground)
    }

    private func colorButton(for color: PLEditorInkColor) -> some View {
        let isSelected = selectedColor == color
        let ringColor: Color = {
            if !isSelected {
                return color == .white ? Color.black.opacity(0.18) : Color.clear
            }
            return color == .black ? Color.white.opacity(0.95) : Color.black.opacity(0.90)
        }()

        return Button {
            guard selectedColor != color else { return }
            selectedColor = color
            showCustomColorPopover = false
            onActivity()
        } label: {
            ZStack {
                Circle()
                    .fill(color.swatch)
                    .frame(width: 32, height: 32)

                Circle()
                    .stroke(ringColor, lineWidth: isSelected ? 3 : 1)
                    .frame(width: 38, height: 38)
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var customColorButton: some View {
        Button {
            dismissActiveTextInput()
            selectedColor = .rainbow
            showCustomColorPopover = true
            onActivity()
        } label: {
            ZStack {
                Circle()
                    .fill(selectedColor == .rainbow ? customColor : Color.white)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(selectedColor == .rainbow ? 0.90 : 0.12), lineWidth: selectedColor == .rainbow ? 3 : 1)
                    )

                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(selectedColor == .rainbow ? Color.white.opacity(0.95) : paletteForeground)
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCustomColorPopover) {
            customColorPopover
        }
    }

    private var customColorPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            ColorPicker("Pick a color", selection: customColorBinding, supportsOpacity: false)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(paletteForeground)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 28, maximum: 36), spacing: 10), count: 4), spacing: 10) {
                ForEach(extendedPresetColors, id: \.self) { color in
                    colorButton(for: color)
                }
            }
        }
        .padding(18)
        .frame(width: 240, alignment: .leading)
        .background(Color.white)
    }

    private var paletteDragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let start = dragOriginCenter ?? snappedCenter
                dragOriginCenter = start
                isDragging = true
                showSettings = false
                showCustomColorPopover = false

                let rawCenter = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                liveCenter = clamped(center: rawCenter, paletteSize: paletteSize)
            }
            .onEnded { value in
                let start = dragOriginCenter ?? snappedCenter
                let endCenter = clamped(
                    center: CGPoint(
                        x: start.x + value.translation.width,
                        y: start.y + value.translation.height
                    ),
                    paletteSize: paletteSize
                )
                let target = nearestSnapTarget(
                    to: endCenter,
                    currentEdge: snapEdge,
                    start: start
                )
                withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.90)) {
                    snapEdge = target.edge
                    edgeProgress = target.progress
                    liveCenter = nil
                    isDragging = false
                }
                dragOriginCenter = nil
                onActivity()
            }
    }

    private func nearestSnapTarget(
        to center: CGPoint,
        currentEdge: PLDrawingPaletteSnapEdge,
        start: CGPoint
    ) -> (edge: PLDrawingPaletteSnapEdge, progress: CGFloat) {
        let distances = distancesToEdges(for: center, paletteSize: paletteSize)
        let best = distances.min { lhs, rhs in lhs.value < rhs.value } ?? (key: currentEdge, value: .greatestFiniteMagnitude)
        let shouldHoldCurrentEdge = distances[currentEdge, default: .greatestFiniteMagnitude] <= best.value + snapRetentionDistance
        let isBreakoutDrag = breakoutDistance(from: start, to: center, edge: currentEdge) > edgeBreakDistance
        let edge = shouldHoldCurrentEdge && !isBreakoutDrag ? currentEdge : best.key
        return (edge, progress(for: center, edge: edge, paletteSize: paletteSize))
    }

    private func clamped(center: CGPoint, paletteSize: CGSize) -> CGPoint {
        let halfWidth = paletteSize.width * 0.5
        let halfHeight = paletteSize.height * 0.5
        let minX = halfWidth + outerInset
        let maxX = max(minX, containerSize.width - halfWidth - outerInset)
        let minY = halfHeight + outerInset
        let maxY = max(minY, containerSize.height - halfHeight - outerInset)
        return CGPoint(
            x: min(max(center.x, minX), maxX),
            y: min(max(center.y, minY), maxY)
        )
    }

    private func center(for edge: PLDrawingPaletteSnapEdge, progress: CGFloat, paletteSize: CGSize) -> CGPoint {
        let clampedProgress = min(max(progress, 0), 1)
        let halfWidth = paletteSize.width * 0.5
        let halfHeight = paletteSize.height * 0.5
        let minX = halfWidth + outerInset
        let maxX = max(minX, containerSize.width - halfWidth - outerInset)
        let minY = halfHeight + outerInset
        let maxY = max(minY, containerSize.height - halfHeight - outerInset)

        switch edge {
        case .top:
            return CGPoint(x: lerp(minX, maxX, clampedProgress), y: minY)
        case .bottom:
            return CGPoint(x: lerp(minX, maxX, clampedProgress), y: maxY)
        case .leading:
            return CGPoint(x: minX, y: lerp(minY, maxY, clampedProgress))
        case .trailing:
            return CGPoint(x: maxX, y: lerp(minY, maxY, clampedProgress))
        }
    }

    private func progress(for center: CGPoint, edge: PLDrawingPaletteSnapEdge, paletteSize: CGSize) -> CGFloat {
        let halfWidth = paletteSize.width * 0.5
        let halfHeight = paletteSize.height * 0.5
        let minX = halfWidth + outerInset
        let maxX = max(minX, containerSize.width - halfWidth - outerInset)
        let minY = halfHeight + outerInset
        let maxY = max(minY, containerSize.height - halfHeight - outerInset)

        switch edge {
        case .top, .bottom:
            return normalized(center.x, min: minX, max: maxX)
        case .leading, .trailing:
            return normalized(center.y, min: minY, max: maxY)
        }
    }

    private func distancesToEdges(for center: CGPoint, paletteSize: CGSize) -> [PLDrawingPaletteSnapEdge: CGFloat] {
        let halfWidth = paletteSize.width * 0.5
        let halfHeight = paletteSize.height * 0.5
        let minX = halfWidth + outerInset
        let maxX = max(minX, containerSize.width - halfWidth - outerInset)
        let minY = halfHeight + outerInset
        let maxY = max(minY, containerSize.height - halfHeight - outerInset)

        return [
            .top: abs(center.y - minY),
            .bottom: abs(center.y - maxY),
            .leading: abs(center.x - minX),
            .trailing: abs(center.x - maxX)
        ]
    }

    private func breakoutDistance(from start: CGPoint, to center: CGPoint, edge: PLDrawingPaletteSnapEdge) -> CGFloat {
        switch edge {
        case .top, .bottom:
            return abs(center.y - start.y)
        case .leading, .trailing:
            return abs(center.x - start.x)
        }
    }

    private func lerp(_ minValue: CGFloat, _ maxValue: CGFloat, _ progress: CGFloat) -> CGFloat {
        minValue + (maxValue - minValue) * progress
    }

    private func normalized(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard maxValue > minValue else { return 0.5 }
        return min(max((value - minValue) / (maxValue - minValue), 0), 1)
    }

    private func iconName(for tool: PLDrawTool) -> String {
        switch tool {
        case .pen:
            return "pencil.tip"
        case .marker:
            return "highlighter"
        case .lasso:
            return "lasso"
        case .eraser:
            return "eraser.line.dashed"
        }
    }
}

private struct ToolHeader: View {
    @EnvironmentObject private var theme: PLThemeStore
    let icon: String
    let title: String

    var body: some View {
        let p = theme.palette

        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 56, height: 56)
                .background(p.accent.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(p.outline, lineWidth: 1)
                )

            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(p.textSecondary)
        }
    }
}

// MARK: - Properties sheet (lightweight placeholder)

private struct PropertiesSheetLite: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: PLThemeStore

    let note: PLNote?
    let kind: PLNoteKind
    @Binding var drawingPaperStyle: PLDrawingPaperStyle
    @Binding var drawWidth: Double
    @Binding var markerWidth: Double
    @Binding var drawingLineSpacing: Double
    @Binding var drawingDotSpacing: Double
    @Binding var drawingDotSize: Double
    let onClose: () -> Void
    @State private var showDrawingPreferences: Bool = false

    var body: some View {
        let p = theme.palette

        VStack(spacing: 14) {
            Capsule().fill(p.textPrimary.opacity(0.18)).frame(width: 44, height: 5).padding(.top, 10)

            Text("Properties")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(p.textPrimary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if kind == .drawing {
                        propStepper("Pen width", value: $drawWidth, range: 1...24, suffix: "px")
                        propStepper("Marker width", value: $markerWidth, range: 4...36, suffix: "px")
                        paperStylePicker
                        propStepper("Line spacing", value: $drawingLineSpacing, range: 12...80, suffix: "px")
                        propStepper("Dot spacing", value: $drawingDotSpacing, range: 12...80, suffix: "px")
                        propStepper("Dot size", value: $drawingDotSize, range: 1...8, suffix: "px")
                        preferencesLinkButton
                    } else if kind == .photo {
                        propStepper("Pen width", value: $drawWidth, range: 1...24, suffix: "px")
                        propStepper("Marker width", value: $markerWidth, range: 4...36, suffix: "px")
                    } else {
                        Text("Text size now lives in the top bar while you edit.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.textSecondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.card.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(p.outline, lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }

            HStack(spacing: 10) {
                Button("Close") {
                    onClose()
                    dismiss()
                }
                    .font(.system(size: 16, weight: .bold))
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
                    .background(p.railButton)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )
                    .foregroundStyle(p.textPrimary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .background(p.background)
        .sheet(isPresented: $showDrawingPreferences) {
            DrawingPreferencesSheet()
                .presentationDetents([.height(620), .large])
        }
    }

    private func propStepper(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        let p = theme.palette

        return HStack {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.85))

            Spacer()

            Stepper("", value: value, in: range, step: 1).labelsHidden()

            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(14)
        .background(p.card.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private var paperStylePicker: some View {
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 10) {
            Text("Drawing paper")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.85))

            HStack(spacing: 8) {
                ForEach(PLDrawingPaperStyle.allCases, id: \.self) { style in
                    Button {
                        drawingPaperStyle = style
                    } label: {
                        Text(style.label)
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .frame(maxWidth: .infinity)
                            .background(drawingPaperStyle == style ? p.accent.opacity(0.75) : p.railButton)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(p.outline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(p.textPrimary)
                }
            }
        }
        .padding(14)
        .background(p.card.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private var preferencesLinkButton: some View {
        let p = theme.palette

        return Button {
            showDrawingPreferences = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preferences")
                        .font(.system(size: 14, weight: .bold))
                    Text("Set the defaults for brand new notes.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(p.textPrimary)
            .padding(14)
            .background(p.card.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(p.outline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DrawingPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PLDrawingDefaults.Key.paperStyleRaw) private var defaultDrawingPaperStyleRaw: String = PLDrawingDefaults.paperStyleRaw
    @AppStorage(PLDrawingDefaults.Key.penWidth) private var defaultPenWidth: Double = PLDrawingDefaults.penWidth
    @AppStorage(PLDrawingDefaults.Key.markerWidth) private var defaultMarkerWidth: Double = PLDrawingDefaults.markerWidth
    @AppStorage(PLDrawingDefaults.Key.lineSpacing) private var defaultLineSpacing: Double = PLDrawingDefaults.lineSpacing
    @AppStorage(PLDrawingDefaults.Key.dotSpacing) private var defaultDotSpacing: Double = PLDrawingDefaults.dotSpacing
    @AppStorage(PLDrawingDefaults.Key.dotSize) private var defaultDotSize: Double = PLDrawingDefaults.dotSize

    var body: some View {
        NavigationStack {
            ScrollView {
                PLDrawingPreferencesSection(
                    paperStyle: Binding(
                        get: { PLDrawingPaperStyle(rawValue: defaultDrawingPaperStyleRaw) ?? .lined },
                        set: { defaultDrawingPaperStyleRaw = $0.rawValue }
                    ),
                    penWidth: $defaultPenWidth,
                    markerWidth: $defaultMarkerWidth,
                    lineSpacing: $defaultLineSpacing,
                    dotSpacing: $defaultDotSpacing,
                    dotSize: $defaultDotSize
                )
                .padding(18)
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension PLDrawingPaperStyle {
    var label: String {
        switch self {
        case .lined: return "Lined"
        case .dotGrid: return "Dot Grid"
        case .blank: return "Blank"
        }
    }
}

private struct CustomInkColorSheet: View {
    @EnvironmentObject private var theme: PLThemeStore
    @Environment(\.dismiss) private var dismiss

    @Binding var color: Color

    var body: some View {
        let p = theme.palette

        VStack(spacing: 14) {
            Capsule()
                .fill(p.textPrimary.opacity(0.18))
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            Text("Custom Color")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(p.textPrimary)

            ColorPicker("Pick a color", selection: $color, supportsOpacity: false)
                .font(.system(size: 16, weight: .bold))
                .padding(14)
                .background(p.card.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(p.outline, lineWidth: 1)
                )
                .padding(.horizontal, 18)

            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .bold))
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .background(p.accent.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(p.outline, lineWidth: 1)
                )
                .foregroundStyle(p.textPrimary)
                .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
        .background(p.background)
    }
}

struct VerticalValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var height: CGFloat = 240
    var trackWidth: CGFloat = 6
    var thumbSize: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let h = max(height, geo.size.height)
            let pct = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let y = (1 - pct) * (h - thumbSize) + thumbSize / 2

            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .frame(width: trackWidth, height: h)

                Capsule()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: trackWidth, height: max(0, pct * h))
                    .offset(y: (h / 2) - (max(0, pct * h) / 2))

                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: geo.size.width / 2, y: y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let localY = min(max(g.location.y, thumbSize / 2), h - thumbSize / 2)
                        let p = 1 - (localY - thumbSize / 2) / (h - thumbSize)
                        let newVal = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
                        value = newVal
                    }
            )
        }
        .frame(width: max(thumbSize, 44), height: height)
    }
}

#if canImport(UIKit)

// MARK: - ✅ UIScrollView Zoom Container (pinch anchor follows fingers)

struct ZoomableScrollContainer<Content: View>: UIViewRepresentable {
    @Binding var isZooming: Bool
    @Binding var resetToken: Int

    let minZoom: CGFloat
    let maxZoom: CGFloat
    let content: () -> Content

    init(
        isZooming: Binding<Bool>,
        resetToken: Binding<Int>,
        minZoom: CGFloat = 1.0,
        maxZoom: CGFloat = 4.0,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._isZooming = isZooming
        self._resetToken = resetToken
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.content = content
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator

        scroll.minimumZoomScale = minZoom
        scroll.maximumZoomScale = maxZoom
        scroll.zoomScale = 1.0

        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false

        scroll.bouncesZoom = true
        scroll.bounces = true

        // ✅ two-finger pan only (don't steal PencilKit one-finger strokes)
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2

        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true

        // ✅ Strongly retained hosting controller
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        scroll.addSubview(host.view)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),

            // Fit at zoom=1.0
            host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            host.view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        context.coordinator.scroll = scroll
        context.coordinator.host = host
        context.coordinator.zoomView = host.view

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content()

        let previousBounds = context.coordinator.lastKnownBoundsSize
        let newBounds = scroll.bounds.size
        if previousBounds != .zero, previousBounds != newBounds {
            context.coordinator.preserveVisibleCenter(from: previousBounds, to: newBounds)
        }
        context.coordinator.lastKnownBoundsSize = newBounds

        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            context.coordinator.resetZoom(animated: true)
        }

        context.coordinator.centerIfNeeded()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let parent: ZoomableScrollContainer
        weak var scroll: UIScrollView?

        // ✅ MUST be strong or zoom breaks
        var host: UIHostingController<Content>!
        var zoomView: UIView?

        var lastResetToken: Int = 0
        var lastKnownBoundsSize: CGSize = .zero

        init(_ parent: ZoomableScrollContainer) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            zoomView
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            parent.isZooming = true
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerIfNeeded()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            let clamped = min(max(scale, parent.minZoom), parent.maxZoom)
            if abs(clamped - scale) > 0.0001 {
                scrollView.setZoomScale(clamped, animated: true)
            }
            parent.isZooming = false
            centerIfNeeded()
        }

        func resetZoom(animated: Bool) {
            guard let scroll else { return }
            parent.isZooming = false
            scroll.setZoomScale(1.0, animated: animated)
            scroll.setContentOffset(.zero, animated: animated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                self.centerIfNeeded()
            }
        }

        func centerIfNeeded() {
            guard let scroll, let v = zoomView else { return }

            let boundsSize = scroll.bounds.size
            let contentSize = v.frame.size

            let insetX = max(0, (boundsSize.width - contentSize.width) / 2)
            let insetY = max(0, (boundsSize.height - contentSize.height) / 2)

            scroll.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        func preserveVisibleCenter(from oldSize: CGSize, to newSize: CGSize) {
            guard let scroll else { return }

            let center = CGPoint(
                x: scroll.contentOffset.x + (oldSize.width * 0.5),
                y: scroll.contentOffset.y + (oldSize.height * 0.5)
            )

            let proposed = CGPoint(
                x: center.x - (newSize.width * 0.5),
                y: center.y - (newSize.height * 0.5)
            )

            let maxX = max(-scroll.contentInset.left, scroll.contentSize.width - newSize.width + scroll.contentInset.right)
            let maxY = max(-scroll.contentInset.top, scroll.contentSize.height - newSize.height + scroll.contentInset.bottom)

            let clamped = CGPoint(
                x: min(max(-scroll.contentInset.left, proposed.x), maxX),
                y: min(max(-scroll.contentInset.top, proposed.y), maxY)
            )

            scroll.setContentOffset(clamped, animated: false)
        }
    }
}

#endif
