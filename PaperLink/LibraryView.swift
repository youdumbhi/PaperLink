//
//  LibraryView.swift
//  PaperLink
//
//  Full, self-contained LibraryView (iOS)
//
//  ✅ Updated layout rules:
//  - iPhone: smaller cards, less padding, compact grid for Pinned/Recents
//  - Hide empty sections: if no folders/notes, don't show header or big blank space (iPad too)
//  - Keeps all existing features:
//    - Reliable double-tap (custom timer, does not fight draggable)
//    - Anchored menu (opens exactly at the tapped card)
//    - Notes AND folders draggable
//    - Can drop notes into folders
//    - Can drop folders into folders (prevents cycles)
//    - Photo/drawing thumbnails cached to reduce lag
//    - Reading Mode flow preserved
//    - Trash flow: delete now means "Move to Trash" (soft delete)
//    - Compact icon-grid anchored menu
//    - Properties sheet plumbing (note/folder) + PropertiesSheet view
//    - Uses app Theme palette everywhere (no glass/material UI)
//
//  ✅ CHANGE REQUEST APPLIED:
//  - The "lines" button now toggles the sidebar (showSidebar) instead of showing pinned.
//  - Pinned is still visible at top, and "View pinned" stays available.
//
//  ✅ NEW CHANGES APPLIED (per your request):
//  - iPhone grid cards are TRUE squares (width + height constrained), no weird flexible widths
//  - iPhone landscape support:
//      - 3 columns in landscape, 2 columns in portrait
//      - tighter spacing/padding and slightly smaller cards in landscape
//  - Reduce "..." truncation by allowing minimumScaleFactor on title/subtitle
//  - Replaced old camera flow (CameraPicker + “Take another?” dialog)
//    with CustomCameraCaptureView multi-shot camera sheet
//
//  ✅ NEW (Offline policy groundwork):
//  - If offline: users may CREATE new notes/folders, but cannot modify existing notes/folders
//    (no pin/move/trash/remove/drag-drop/reorder/etc).
//  - If offline: tapping still opens notes in PREVIEW.
//  - If offline: double-tap anchored menu is disabled.
//  - If offline: drag & drop is disabled.
//

import SwiftUI
import SwiftData
import PencilKit

#if canImport(PhotosUI)
import PhotosUI
#endif

#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)

struct LibraryView: View {
    @Environment(\.modelContext) private var ctx
    @EnvironmentObject private var theme: PLThemeStore
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.plDockedSidebarInset) private var dockedSidebarInset
    @Environment(\.horizontalSizeClass) private var hSizeClass

    // ✅ Added for landscape detection on phone
    @Environment(\.verticalSizeClass) private var vSizeClass

    @Query(sort: \PLNote.updatedAt, order: .reverse) private var allNotes: [PLNote]
    @Query(sort: \PLFolder.createdAt, order: .forward) private var allFolders: [PLFolder]

    @Binding var showPinnedSheet: Bool
    @Binding var showSidebar: Bool

    // NOTE: Kept for compatibility with RootView’s existing binding, but no longer used as “delete mode”.
    @Binding var deleteMode: Bool

    @State private var searchText: String = ""

    // Folder navigation (ID-based)
    @State private var currentFolderID: UUID? = nil

    // Create folder flows
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    @State private var showCreateFolderWithNoteAlert = false
    @State private var folderWithNoteName = ""
    @State private var pendingNoteForFolder: PLNote? = nil

    @State private var showMoveToFolderSheet = false
    @State private var pendingNoteToMove: PLNote? = nil

    // Reading mode
    @State private var showReadingMode: Bool = false
    @State private var readingNotes: [PLNote] = []
    @State private var readingIndex: Int = 0
    @State private var readingFolderTitle: String = ""

    // Draft creation presentation (new note)
    @State private var creatingDraft: PLNoteDraft? = nil

    // Editor presentation (existing note)
    @State private var editingNote: PLNote? = nil

    // "+" menu
    @State private var showNewItemSheet = false

    // Photos picker (IMPORT)
    @State private var showPhotoPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []

    // Multi-photo import -> create folder flow
    @State private var showMultiPhotoFolderAlert = false
    @State private var multiPhotoFolderName: String = ""
    @State private var pendingMultiPhotoDatas: [Data] = []

    // Camera (TAKE) ✅ NEW
    @State private var showCustomCamera = false
    @State private var showCameraUnavailableAlert = false

    // Trash confirmations (slider)
    @State private var showTrashSlider: Bool = false
    @State private var pendingTrashNote: PLNote? = nil
    @State private var pendingTrashFolder: PLFolder? = nil

    // Anchored menu state
    enum MenuKind { case note, folder }
    @State private var showAnchoredMenu: Bool = false
    @State private var menuKind: MenuKind = .note
    @State private var menuNote: PLNote? = nil
    @State private var menuFolder: PLFolder? = nil

    // Properties sheet state
    @State private var showPropertiesSheet: Bool = false
    @State private var propertiesNote: PLNote? = nil
    @State private var propertiesFolder: PLFolder? = nil

    // Reliable double-tap (doesn't fight draggable)
    @State private var pendingSingleTapWorkItem: DispatchWorkItem? = nil
    @State private var lastTapID: UUID? = nil
    @State private var lastTapDate: Date = .distantPast
    private let doubleTapWindow: TimeInterval = 0.18

    // Preview presentation (existing note)
    @State private var previewingNote: PLNote? = nil
    @State private var showPinnedGrid: Bool = false

    private enum ReadingMoveDirection {
        case earlier
        case later
    }

    private enum OrderedFolderContent: Identifiable {
        case folder(PLFolder)
        case note(PLNote)

        var id: String {
            switch self {
            case .folder(let folder):
                return "folder:\(folder.id.uuidString)"
            case .note(let note):
                return "note:\(note.id.uuidString)"
            }
        }
    }

    // MARK: - Offline policy

    /// If false, user may still VIEW and CREATE new things, but cannot modify existing items.
    private var canModifyExisting: Bool { network.isOnline }

    // MARK: - Layout tuning

    private var isPhoneCompact: Bool { hSizeClass == .compact }

    // ✅ NEW: landscape phone detection + tuned sizing/padding rules
    private var isLandscapePhone: Bool {
        isPhoneCompact && vSizeClass == .compact
    }

    // slightly smaller in landscape to fit 3 columns comfortably
    private var phoneCardSide: CGFloat { isLandscapePhone ? 112 : 128 }
    private var cardSide: CGFloat { isPhoneCompact ? phoneCardSide : 175 }

    // allow 3 columns in landscape, 2 in portrait
    private var phoneGridColumns: Int { isLandscapePhone ? 3 : 2 }

    private var gridSpacing: CGFloat { isPhoneCompact ? (isLandscapePhone ? 8 : 10) : 12 }

    // tighten spacing/padding in landscape
    private var pageHPad: CGFloat { isPhoneCompact ? (isLandscapePhone ? 10 : 14) : 22 }
    private var pageBottomPad: CGFloat { isPhoneCompact ? 18 : 26 }
    private var sectionSpacing: CGFloat { isPhoneCompact ? (isLandscapePhone ? 10 : 12) : 18 }
    private var stackTopSpacing: CGFloat { isPhoneCompact ? (isLandscapePhone ? 6 : 10) : 14 }
    private var contentLeadingInset: CGFloat { isPhoneCompact ? 0 : dockedSidebarInset }

    // MARK: - Derived

    private var aliveNotes: [PLNote] {
        allNotes.filter { $0.deletedAt == nil }
    }

    private var aliveFolders: [PLFolder] {
        allFolders.filter { $0.deletedAt == nil }
    }

    private var currentFolder: PLFolder? {
        guard let id = currentFolderID else { return nil }
        return aliveFolders.first(where: { $0.id == id })
    }

    private var scopedNotes: [PLNote] {
        let base = aliveNotes.filter { $0.folderID == currentFolderID }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        let lower = q.lowercased()
        return base.filter { n in
            n.title.lowercased().contains(lower) ||
            (n.textBody ?? "").lowercased().contains(lower)
        }
    }

    private var scopedFolders: [PLFolder] {
        aliveFolders.filter { $0.parentFolderID == currentFolderID }
    }

    private var orderedFolderContents: [OrderedFolderContent] {
        sortOrderedFolderContents(
            scopedFolders.map(OrderedFolderContent.folder)
            + scopedNotes.map(OrderedFolderContent.note)
        )
    }

    private var pinnedNotes: [PLNote] {
        scopedNotes.filter { $0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var recentNotes: [PLNote] {
        Array(scopedNotes.sorted { $0.updatedAt > $1.updatedAt }.prefix(isPhoneCompact ? 8 : 12))
    }

    private var breadcrumbTitle: String {
        currentFolder?.name ?? "Library"
    }

    // MARK: - Body

    var body: some View {
        let p = theme.palette

        ZStack {
            p.background.ignoresSafeArea()

            VStack(spacing: stackTopSpacing) {
                headerBar

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: sectionSpacing) {
                        if currentFolderID != nil {
                            folderBreadcrumb
                        }

                        if currentFolderID != nil {
                            if orderedFolderContents.isEmpty {
                                emptyStateView
                            } else {
                                orderedContentGrid
                            }
                        } else {
                            // Pinned (only if exists)
                            if !pinnedNotes.isEmpty {
                                SectionHeader(title: "Pinned", accessory: "View all pinned") {
                                    showPinnedGrid = true
                                }

                                if isPhoneCompact {
                                    CompactNotesGrid(
                                        notes: Array(pinnedNotes.prefix(4)),
                                        cardSide: cardSide,
                                        gridSpacing: gridSpacing,
                                        outline: p.outline,
                                        columns: phoneGridColumns,
                                        canDrag: canModifyExisting,
                                        onOpen: { note in
                                            Task { @MainActor in handleNoteTap(note) }
                                        }
                                    )
                                } else {
                                    HorizontalPreviewRowSquare(
                                        notes: Array(pinnedNotes.prefix(10)),
                                        cardSide: cardSide,
                                        outline: p.outline,
                                        canDrag: canModifyExisting,
                                        onOpen: { note in
                                            Task { @MainActor in handleNoteTap(note) }
                                        }
                                    )
                                }
                            }

                            if !recentNotes.isEmpty {
                                SectionHeader(title: "Recents")

                                if isPhoneCompact {
                                    CompactNotesGrid(
                                        notes: recentNotes,
                                        cardSide: cardSide,
                                        gridSpacing: gridSpacing,
                                        outline: p.outline,
                                        columns: phoneGridColumns,
                                        canDrag: canModifyExisting,
                                        onOpen: { note in
                                            Task { @MainActor in handleNoteTap(note) }
                                        }
                                    )
                                } else {
                                    HorizontalPreviewRowSquare(
                                        notes: recentNotes,
                                        cardSide: cardSide,
                                        outline: p.outline,
                                        canDrag: canModifyExisting,
                                        onOpen: { note in
                                            Task { @MainActor in handleNoteTap(note) }
                                        }
                                    )
                                }
                            }

                            if !scopedFolders.isEmpty {
                                SectionHeader(title: "Folders", accessory: "New folder") {
                                    showNewFolderAlert = true
                                }
                                folderGrid
                            }

                            if !scopedNotes.isEmpty {
                                SectionHeader(title: "Notes")
                                notesGrid
                            }

                            if pinnedNotes.isEmpty, recentNotes.isEmpty, scopedFolders.isEmpty, scopedNotes.isEmpty {
                                emptyStateView
                            }
                        }
                    }
                    .padding(.horizontal, pageHPad)
                    .padding(.bottom, pageBottomPad)
                }
            }
            .padding(.leading, contentLeadingInset)
            .overlayPreferenceValue(MenuAnchorPreferenceKey.self) { anchors in
                menuOverlay(anchors: anchors)
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.90), value: currentFolderID)

        // If we go offline mid-session, close any destructive/modifying UI.
        .onChange(of: network.isOnline) { _, isOnline in
            if !isOnline {
                Task { @MainActor in
                    closeMenu()
                    showMoveToFolderSheet = false
                    showTrashSlider = false
                    pendingTrashFolder = nil
                    pendingTrashNote = nil
                    pendingNoteToMove = nil
                    pendingNoteForFolder = nil
                }
            }
        }

        // MARK: - Sheets / Alerts

        // Import photo(s)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickerItems,
            maxSelectionCount: 50,
            matching: .images
        )
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let datas = await loadPhotoDatas(items)
                await MainActor.run {
                    pickerItems = []
                    handlePickedPhotoDatas(datas)
                }
            }
        }

        // ✅ NEW: Custom multi-shot camera screen
        .fullScreenCover(isPresented: $showCustomCamera) {
            CustomCameraCaptureView { datas in
                let cleaned = datas.filter { !$0.isEmpty }
                guard !cleaned.isEmpty else { return }
                handlePickedPhotoDatas(cleaned) // your existing multi-photo folder flow
            }
            .ignoresSafeArea()
        }

        .alert("Camera unavailable", isPresented: $showCameraUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The iOS Simulator usually doesn’t have a working camera. Try on a real device.")
        }

        // Existing note: open PREVIEW first
        .fullScreenCover(item: $previewingNote) { note in
            NoteEditorScreen(note: note, startInPreview: true)
        }

        // Draft editor
        .fullScreenCover(item: $creatingDraft) { draft in
            NoteEditorScreen(draft: draft)
        }

        // Reading mode
        .fullScreenCover(isPresented: $showReadingMode) {
            ReadingModeScreen(
                notes: readingNotes,
                startIndex: readingIndex,
                title: readingFolderTitle,
                onClose: { closeReadingModeAndAnyNote() }
            )
        }

        // "+" options sheet
        .sheet(isPresented: $showNewItemSheet) {
            NewItemSheet(
                showDrawingOption: !isPhoneCompact, // iPhone: no drawing note creation
                onNewText: {
                    showNewItemSheet = false
                    creatingDraft = PLNoteDraft(kind: .text, title: "New note", folderID: currentFolderID)
                },
                onNewDrawing: {
                    showNewItemSheet = false
                    creatingDraft = PLNoteDraft(kind: .drawing, title: "New drawing", folderID: currentFolderID)
                },
                onImportPhotos: {
                    showNewItemSheet = false
                    showPhotoPicker = true
                },
                onTakePhotos: {
                    showNewItemSheet = false
#if canImport(UIKit)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCustomCamera = true
                    } else {
                        showCameraUnavailableAlert = true
                    }
#else
                    showCameraUnavailableAlert = true
#endif
                },
                onNewFolder: {
                    showNewItemSheet = false
                    showNewFolderAlert = true
                }
            )
            .modifier(CompactDetentsIfAvailable(height: isPhoneCompact ? 360 : 410))
            .presentationBackground(theme.palette.background)
            .presentationCornerRadius(24)
        }

        // New folder alert
        .alert("New folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create folder") { createFolder(name: newFolderName, parentID: currentFolderID) }
            Button("Cancel", role: .cancel) {}
        }

        // Multi-photo folder name alert (import OR take)
        .alert("Name this folder", isPresented: $showMultiPhotoFolderAlert) {
            TextField("Folder name", text: $multiPhotoFolderName)
            Button("Done") {
                createFolderWithPhotos(
                    name: multiPhotoFolderName,
                    parentID: currentFolderID,
                    photoDatas: pendingMultiPhotoDatas
                )
            }
        } message: {
            Text("You selected \(pendingMultiPhotoDatas.count) photos. They’ll be saved as separate photo notes inside a new folder.")
        }

        // Create folder with note alert
        .alert("New folder with note", isPresented: $showCreateFolderWithNoteAlert) {
            TextField("Folder name", text: $folderWithNoteName)
            Button("Create folder") { createFolderWithNote() }
            Button("Cancel", role: .cancel) {
                pendingNoteForFolder = nil
                folderWithNoteName = ""
            }
        }

        // Move to folder sheet
        .sheet(isPresented: $showMoveToFolderSheet) {
            FolderPickerSheet(
                allFolders: aliveFolders,
                onPick: { picked in
                    movePendingNote(to: picked.id)
                    showMoveToFolderSheet = false
                },
                onMoveToRoot: {
                    movePendingNote(to: nil)
                    showMoveToFolderSheet = false
                },
                onCancel: {
                    showMoveToFolderSheet = false
                }
            )
            .modifier(LargeDetentsIfAvailable())
        }

        // Pinned grid sheet
        .sheet(isPresented: $showPinnedGrid) {
            PinnedNotesGridScreen(
                notes: pinnedNotes,
                cardSide: cardSide,
                gridSpacing: gridSpacing,
                onOpen: { note in
                    Task { @MainActor in handleNoteTap(note) }
                }
            )
            .presentationBackground(theme.palette.background)
            .presentationCornerRadius(24)
        }

        // Trash slider
        .sheet(isPresented: $showTrashSlider) {
            let isFolder = (pendingTrashFolder != nil)
            triggeringDeleteSlider(isFolder: isFolder)
        }

        // Properties sheet (note OR folder)
        .sheet(isPresented: $showPropertiesSheet) {
            PropertiesSheet(
                note: propertiesNote,
                folder: propertiesFolder,
                onClose: {
                    DispatchQueue.main.async {
                        showPropertiesSheet = false
                    }
                }
            )
                .modifier(CompactDetentsIfAvailable(height: 520))
        }
    }

    // MARK: - Trash slider (extracted as full function to keep body clean)

    @ViewBuilder
    private func triggeringDeleteSlider(isFolder: Bool) -> some View {
        DeleteSliderConfirmSheet(
            title: isFolder ? "Move folder to Trash?" : "Move note to Trash?",
            message: isFolder
                ? "This will move the folder, any subfolders, and all notes inside to Recently Deleted."
                : "This will move the note to Recently Deleted.",
            confirmLabel: isFolder ? "Slide to move folder to Trash" : "Slide to move note to Trash",
            onConfirm: {
                if let f = pendingTrashFolder { trashFolder(f) }
                if let n = pendingTrashNote { trashNote(n) }
                pendingTrashFolder = nil
                pendingTrashNote = nil
                showTrashSlider = false
            },
            onCancel: {
                pendingTrashFolder = nil
                pendingTrashNote = nil
                showTrashSlider = false
            }
        )
        .modifier(CompactDetentsIfAvailable(height: 360))
    }

    // MARK: - Header

    private var headerBar: some View {
        let p = theme.palette

        let btnW: CGFloat = isPhoneCompact ? 48 : 54
        let btnH: CGFloat = isPhoneCompact ? 48 : 54

        return HStack(spacing: isPhoneCompact ? 10 : 14) {

            // RootView now owns the menu button; this spacer preserves header alignment.
            Spacer()
                .frame(width: (contentLeadingInset > 0 ? 0 : btnW), height: btnH)

            VStack(alignment: .leading, spacing: 4) {
                Text("Paperlink")
                    .font(.system(size: isPhoneCompact ? 24 : 28, weight: .bold))
                    .foregroundStyle(p.textPrimary)

                Text("Your notes, organized.")
                    .font(.system(size: isPhoneCompact ? 12 : 14, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            SearchPill(text: $searchText)
                .frame(maxWidth: isPhoneCompact ? 190 : 420)

            Button { showNewItemSheet = true } label: {
                if isPhoneCompact {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                } else {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 14)
                        .frame(height: 54)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.textPrimary)
        }
        .padding(.horizontal, pageHPad)
        .padding(.top, isPhoneCompact ? 10 : 16)
    }

    // MARK: - Breadcrumb

    private var folderBreadcrumb: some View {
        let p = theme.palette

        return HStack(spacing: 10) {
            if let currentFolder {
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
                        currentFolderID = currentFolder.parentFolderID
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)

                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
                        currentFolderID = nil
                    }
                } label: {
                    Label("Root", systemImage: "house")
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }

            Text(breadcrumbTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.95))

            Spacer()
        }
        .padding(.top, isPhoneCompact ? 0 : 6)
    }

    // MARK: - Grids

    private var folderGrid: some View {
        let cols = [GridItem(.adaptive(minimum: cardSide, maximum: cardSide), spacing: gridSpacing)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: gridSpacing) {
            ForEach(scopedFolders) { folder in
                let previewNote = folderPreviewNote(folderID: folder.id)

                FolderCardSquare(folder: folder, previewNote: previewNote)
                    .frame(width: cardSide, height: cardSide)
                    .contentShape(RoundedRectangle(cornerRadius: 26))
                    .onTapGesture {
                        Task { @MainActor in
                            handleFolderTap(folder)
                        }
                    }
                    .plIf(canModifyExisting) { view in
                        view.draggable(dragStringForFolder(folder.id)) {
                            DragPreviewCard(outline: theme.palette.outline) {
                                FolderCardSquare(folder: folder, previewNote: previewNote)
                                    .environmentObject(theme) // ✅ IMPORTANT: inject theme into preview
                                    .frame(width: cardSide, height: cardSide)
                            }
                        }
                    }
                    .menuAnchor(id: folder.id, kind: .folder)
                    .plIf(canModifyExisting) { view in
                        view.dropDestination(for: String.self) { items, _ in
                            guard let s = items.first, let parsed = parseDraggedItem(s) else { return false }

                            switch parsed.kind {
                            case "note":
                                guard let note = aliveNotes.first(where: { $0.id == parsed.id }) else { return false }
                                note.folderID = folder.id
                                note.readingOrder = nextReadingOrder(in: folder.id)
                                note.updatedAt = .now
                                folder.updatedAt = .now
                                try? ctx.save()

                                // ✅ ADD (sync both the note + the destination folder)
                                PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
                                PaperLinkSyncManager.shared.enqueueFolder(folder, ctx: ctx)

                                return true


                            case "folder":
                                guard let moving = aliveFolders.first(where: { $0.id == parsed.id }) else { return false }
                                if moving.id == folder.id { return false }
                                if isDescendant(folderID: folder.id, potentialAncestor: moving.id) { return false }

                                moving.parentFolderID = folder.id
                                moving.readingOrder = nextReadingOrder(in: folder.id)
                                moving.updatedAt = .now
                                folder.updatedAt = .now
                                try? ctx.save()

                                // ✅ ADD (sync both the moved folder + the destination folder)
                                PaperLinkSyncManager.shared.enqueueFolder(moving, ctx: ctx)
                                PaperLinkSyncManager.shared.enqueueFolder(folder, ctx: ctx)

                                return true


                            default:
                                return false
                            }
                        }
                    }
            }
        }
    }

    private var orderedContentGrid: some View {
        let cols = [GridItem(.adaptive(minimum: cardSide, maximum: cardSide), spacing: gridSpacing)]

        return LazyVGrid(columns: cols, alignment: .leading, spacing: gridSpacing) {
            ForEach(Array(orderedFolderContents.enumerated()), id: \.element.id) { offset, item in
                orderedContentCard(item, index: offset)
            }
        }
    }

    private var notesGrid: some View {
        let cols = [GridItem(.adaptive(minimum: cardSide, maximum: cardSide), spacing: gridSpacing)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: gridSpacing) {
            ForEach(scopedNotes) { note in
                NoteCardSquare(note: note)
                    .frame(width: cardSide, height: cardSide)
                    .contentShape(RoundedRectangle(cornerRadius: 26))
                    .onTapGesture {
                        Task { @MainActor in
                            handleNoteTap(note)
                        }
                    }
                    .plIf(canModifyExisting) { view in
                        view.draggable(dragStringForNote(note.id))
                    }
                    .menuAnchor(id: note.id, kind: .note)
            }
        }
    }

    @ViewBuilder
    private func orderedContentCard(_ item: OrderedFolderContent, index: Int) -> some View {
        switch item {
        case .folder(let folder):
            let previewNote = folderPreviewNote(folderID: folder.id)

            FolderCardSquare(folder: folder, previewNote: previewNote)
                .frame(width: cardSide, height: cardSide)
                .overlay(alignment: .topTrailing) {
                    orderBadge(number: index + 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 26))
                .onTapGesture {
                    Task { @MainActor in
                        handleFolderTap(folder)
                    }
                }
                .plIf(canModifyExisting) { view in
                    view.draggable(dragStringForFolder(folder.id)) {
                        DragPreviewCard(outline: theme.palette.outline) {
                            FolderCardSquare(folder: folder, previewNote: previewNote)
                                .environmentObject(theme)
                                .frame(width: cardSide, height: cardSide)
                        }
                    }
                }
                .menuAnchor(id: folder.id, kind: .folder)
                .plIf(canModifyExisting) { view in
                    view.dropDestination(for: String.self) { items, _ in
                        guard let s = items.first, let parsed = parseDraggedItem(s) else { return false }

                        switch parsed.kind {
                        case "note":
                            guard let note = aliveNotes.first(where: { $0.id == parsed.id }) else { return false }
                            note.folderID = folder.id
                            note.readingOrder = nextReadingOrder(in: folder.id)
                            note.updatedAt = .now
                            folder.updatedAt = .now
                            try? ctx.save()
                            PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
                            PaperLinkSyncManager.shared.enqueueFolder(folder, ctx: ctx)
                            return true

                        case "folder":
                            guard let moving = aliveFolders.first(where: { $0.id == parsed.id }) else { return false }
                            if moving.id == folder.id { return false }
                            if isDescendant(folderID: folder.id, potentialAncestor: moving.id) { return false }

                            moving.parentFolderID = folder.id
                            moving.readingOrder = nextReadingOrder(in: folder.id)
                            moving.updatedAt = .now
                            folder.updatedAt = .now
                            try? ctx.save()
                            PaperLinkSyncManager.shared.enqueueFolder(moving, ctx: ctx)
                            PaperLinkSyncManager.shared.enqueueFolder(folder, ctx: ctx)
                            return true

                        default:
                            return false
                        }
                    }
                }

        case .note(let note):
            NoteCardSquare(note: note)
                .frame(width: cardSide, height: cardSide)
                .overlay(alignment: .topTrailing) {
                    orderBadge(number: index + 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 26))
                .onTapGesture {
                    Task { @MainActor in
                        handleNoteTap(note)
                    }
                }
                .plIf(canModifyExisting) { view in
                    view.draggable(dragStringForNote(note.id))
                }
                .menuAnchor(id: note.id, kind: .note)
        }
    }

    private func orderBadge(number: Int) -> some View {
        let p = theme.palette

        return Text("\(number)")
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(p.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(p.canvas.opacity(0.95))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(p.outline, lineWidth: 1)
            )
            .padding(12)
    }

    // MARK: - Anchored menu open/close

    @MainActor
    private func openMenu(for note: PLNote) {
        guard canModifyExisting else { return } // ✅ offline: no anchored menu
        menuKind = .note
        menuNote = note
        menuFolder = nil
        showAnchoredMenu = true
    }

    @MainActor
    private func openFolderMenu(for folder: PLFolder) {
        guard canModifyExisting else { return } // ✅ offline: no anchored menu
        menuKind = .folder
        menuFolder = folder
        menuNote = nil
        showAnchoredMenu = true
    }

    @MainActor
    private func closeMenu() {
        showAnchoredMenu = false
        menuNote = nil
        menuFolder = nil
    }

    // MARK: - Open properties for current menu item

    @MainActor
    private func openPropertiesForCurrentMenuItem() {
        // Properties will eventually persist -> treat as modifying existing when offline.
        guard canModifyExisting else { return }

        switch menuKind {
        case .note:
            propertiesNote = menuNote
            propertiesFolder = nil
        case .folder:
            propertiesFolder = menuFolder
            propertiesNote = nil
        }
        showPropertiesSheet = true
    }

    // MARK: - Reliable tap handling

    @MainActor
    private func handleNoteTap(_ note: PLNote) {
        // ✅ Offline: always open preview immediately; no double-tap menu.
        guard canModifyExisting else {
            openEditor(note)
            return
        }

        let now = Date()

        if lastTapID == note.id, now.timeIntervalSince(lastTapDate) <= doubleTapWindow {
            pendingSingleTapWorkItem?.cancel()
            pendingSingleTapWorkItem = nil
            lastTapID = nil
            openMenu(for: note)
            return
        }

        lastTapID = note.id
        lastTapDate = now

        pendingSingleTapWorkItem?.cancel()

        let openDelay: TimeInterval = 0.05

        let work = DispatchWorkItem { @MainActor in
            openEditor(note) // opens PREVIEW
        }

        pendingSingleTapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow + openDelay, execute: work)
    }

    @MainActor
    private func handleFolderTap(_ folder: PLFolder) {
        // ✅ Offline: normal single-tap nav; no double-tap menu.
        guard canModifyExisting else {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
                currentFolderID = folder.id
            }
            return
        }

        let now = Date()

        if lastTapID == folder.id, now.timeIntervalSince(lastTapDate) <= doubleTapWindow {
            pendingSingleTapWorkItem?.cancel()
            pendingSingleTapWorkItem = nil
            lastTapID = nil
            openFolderMenu(for: folder)
            return
        }

        lastTapID = folder.id
        lastTapDate = now

        pendingSingleTapWorkItem?.cancel()
        let work = DispatchWorkItem { @MainActor in
            withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
                currentFolderID = folder.id
            }
        }
        pendingSingleTapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
    }

    // MARK: - Drag payload helpers

    private func dragStringForNote(_ id: UUID) -> String { "note:\(id.uuidString)" }
    private func dragStringForFolder(_ id: UUID) -> String { "folder:\(id.uuidString)" }

    private func parseDraggedItem(_ s: String) -> (kind: String, id: UUID)? {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let uuid = UUID(uuidString: parts[1]) else { return nil }
        return (parts[0], uuid)
    }

    private func isDescendant(folderID: UUID, potentialAncestor: UUID) -> Bool {
        // walk up parents from folderID, see if we hit potentialAncestor
        var current: UUID? = folderID
        while let c = current {
            if c == potentialAncestor { return true }
            current = aliveFolders.first(where: { $0.id == c })?.parentFolderID
        }
        return false
    }

    private func sortOrderedFolderContents(_ contents: [OrderedFolderContent]) -> [OrderedFolderContent] {
        contents.sorted { lhs, rhs in
            let leftOrder = readingSortOrder(for: lhs)
            let rightOrder = readingSortOrder(for: rhs)
            if leftOrder != rightOrder {
                return leftOrder < rightOrder
            }
            return stableTimestamp(for: lhs) < stableTimestamp(for: rhs)
        }
    }

    private func orderedContents(in parentID: UUID?) -> [OrderedFolderContent] {
        sortOrderedFolderContents(
            aliveFolders
                .filter { $0.deletedAt == nil && $0.parentFolderID == parentID }
                .map(OrderedFolderContent.folder)
            + aliveNotes
                .filter { $0.deletedAt == nil && $0.folderID == parentID }
                .map(OrderedFolderContent.note)
        )
    }

    private func readingSortOrder(for item: OrderedFolderContent) -> Double {
        switch item {
        case .folder(let folder):
            return folder.readingOrder == 0 ? folder.createdAt.timeIntervalSinceReferenceDate : folder.readingOrder
        case .note(let note):
            return note.readingOrder == 0 ? note.createdAt.timeIntervalSinceReferenceDate : note.readingOrder
        }
    }

    private func stableTimestamp(for item: OrderedFolderContent) -> Double {
        switch item {
        case .folder(let folder):
            return folder.createdAt.timeIntervalSinceReferenceDate
        case .note(let note):
            return note.createdAt.timeIntervalSinceReferenceDate
        }
    }

    private func nextReadingOrder(in parentID: UUID?) -> Double {
        let contents = orderedContents(in: parentID)
        guard let last = contents.last else { return 1 }
        return readingSortOrder(for: last) + 1
    }

    @MainActor
    private func moveContent(_ item: OrderedFolderContent, direction: ReadingMoveDirection) {
        let parentID: UUID?
        switch item {
        case .folder(let folder):
            parentID = folder.parentFolderID
        case .note(let note):
            parentID = note.folderID
        }

        var siblings = orderedContents(in: parentID)
        guard let currentIndex = siblings.firstIndex(where: { $0.id == item.id }) else { return }

        let targetIndex: Int
        switch direction {
        case .earlier:
            targetIndex = max(currentIndex - 1, 0)
        case .later:
            targetIndex = min(currentIndex + 1, siblings.count - 1)
        }

        guard targetIndex != currentIndex else { return }

        let moved = siblings.remove(at: currentIndex)
        siblings.insert(moved, at: targetIndex)

        let now = Date()
        for (index, sibling) in siblings.enumerated() {
            switch sibling {
            case .folder(let folder):
                folder.readingOrder = Double(index + 1)
                folder.updatedAt = now
                PaperLinkSyncManager.shared.enqueueFolder(folder, ctx: ctx)
            case .note(let note):
                note.readingOrder = Double(index + 1)
                note.updatedAt = now
                PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
            }
        }

        try? ctx.save()
    }

    // MARK: - Actions

    @MainActor
    private func openEditor(_ note: PLNote) {
        previewingNote = note
    }

    @MainActor
    private func createFolder(name: String, parentID: UUID?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? autoFolderName(parentID: parentID) : trimmed

        let f = PLFolder(name: finalName, parentFolderID: parentID, readingOrder: nextReadingOrder(in: parentID))
        ctx.insert(f)
        try? ctx.save()

        PaperLinkSyncManager.shared.enqueueFolder(f, ctx: ctx)

        newFolderName = ""

    }

    @MainActor
    private func createFolderWithNote() {
        // ✅ This modifies an existing note -> block when offline
        guard canModifyExisting else { return }
        guard let note = pendingNoteForFolder else { return }

        let trimmed = folderWithNoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? autoFolderName(parentID: currentFolderID) : trimmed

        let f = PLFolder(name: finalName, parentFolderID: currentFolderID, readingOrder: nextReadingOrder(in: currentFolderID))
        ctx.insert(f)

        note.folderID = f.id
        note.readingOrder = nextReadingOrder(in: f.id)
        note.updatedAt = .now
        f.updatedAt = .now

        try? ctx.save()
        PaperLinkSyncManager.shared.enqueueFolder(f, ctx: ctx)
        PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx) // because it moved folders too


        pendingNoteForFolder = nil
        folderWithNoteName = ""
    }

    @MainActor
    private func movePendingNote(to folderID: UUID?) {
        guard canModifyExisting else { return }
        guard let note = pendingNoteToMove else { return }

        note.folderID = folderID
        note.readingOrder = nextReadingOrder(in: folderID)
        note.updatedAt = .now
        try? ctx.save()

        PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)

        pendingNoteToMove = nil
    }


    // MARK: - Trash (soft delete)

    @MainActor
    private func trashNote(_ note: PLNote) {
        guard canModifyExisting else { return }
        note.deletedAt = .now
        note.updatedAt = .now
        try? ctx.save()

        PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
    }


    @MainActor
    private func trashFolder(_ folder: PLFolder) {
        guard canModifyExisting else { return }

        let allFolderIDs = collectFolderSubtreeIDs(root: folder.id)

        let notesToTrash = aliveNotes.filter { n in
            if let fid = n.folderID { return allFolderIDs.contains(fid) }
            return false
        }
        for n in notesToTrash {
            n.deletedAt = .now
            n.updatedAt = .now
        }

        let foldersToTrash = aliveFolders.filter { allFolderIDs.contains($0.id) }
        for f in foldersToTrash {
            f.deletedAt = .now
            f.updatedAt = .now
        }

        try? ctx.save()

        // ✅ enqueue updates for everything affected
        for f in foldersToTrash { PaperLinkSyncManager.shared.enqueueFolder(f, ctx: ctx) }
        for n in notesToTrash { PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx) }

        if let current = currentFolderID, allFolderIDs.contains(current) {
            currentFolderID = nil
        }
    }


    private func collectFolderSubtreeIDs(root: UUID) -> Set<UUID> {
        var result: Set<UUID> = [root]
        var queue: [UUID] = [root]
        while let next = queue.first {
            queue.removeFirst()
            let children = aliveFolders.filter { $0.parentFolderID == next }.map(\.id)
            for c in children where !result.contains(c) {
                result.insert(c)
                queue.append(c)
            }
        }
        return result
    }

    // MARK: - Import/Take handlers

    @MainActor
    private func handlePickedPhotoDatas(_ datas: [Data]) {
        let cleaned = datas.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        if cleaned.count == 1, let data = cleaned.first {
            creatingDraft = PLNoteDraft(
                kind: .photo,
                title: "Photo note",
                folderID: currentFolderID,
                photoData: data
            )
        } else {
            pendingMultiPhotoDatas = cleaned
            multiPhotoFolderName = ""
            showMultiPhotoFolderAlert = true
        }
    }

    private func loadPhotoDatas(_ items: [PhotosPickerItem]) async -> [Data] {
        await withTaskGroup(of: Data?.self) { group in
            for item in items {
                group.addTask { try? await item.loadTransferable(type: Data.self) }
            }
            var out: [Data] = []
            for await maybe in group {
                if let d = maybe { out.append(d) }
            }
            return out
        }
    }

    @MainActor
    private func createFolderWithPhotos(name: String, parentID: UUID?, photoDatas: [Data]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? autoFolderName(parentID: parentID) : trimmed

        let datas = photoDatas.filter { !$0.isEmpty }
        guard !datas.isEmpty else { return }

        let folder = PLFolder(name: finalName, parentFolderID: parentID, readingOrder: nextReadingOrder(in: parentID))
        ctx.insert(folder)

        // Clear UI state immediately so nothing feels “deleted”
        pendingMultiPhotoDatas = []
        multiPhotoFolderName = ""
        showMultiPhotoFolderAlert = false

        let emptyDrawingData = PKDrawing().dataRepresentation()

        Task(priority: .userInitiated) { @MainActor in
            // produce an immutable array result
            let results: [(photo: String, ink: String?, hl: String?)] = datas.enumerated().compactMap { (idx, data) in
                let photoName = "photo_\(UUID().uuidString)_\(idx + 1).jpg"
                guard let photoFilename = FileStore.shared.writeData(data, preferredName: photoName) else { return nil }

                let inkFilename = FileStore.shared.writeData(emptyDrawingData, preferredName: "ink_\(UUID().uuidString).pkd")
                let hlFilename = FileStore.shared.writeData(emptyDrawingData, preferredName: "highlight_\(UUID().uuidString).pkd")

                return (photo: photoFilename, ink: inkFilename, hl: hlFilename)
            }

            // ✅ 1) enqueue folder once
            PaperLinkSyncManager.shared.enqueueFolder(folder, ctx: ctx)

            // ✅ 2) create notes and enqueue each note right after inserting
            for (i, r) in results.enumerated() {
                let note = PLNote(
                    title: "Photo \(i + 1)",
                    kind: .photo,
                    folderID: folder.id,
                    readingOrder: Double(i + 1)
                )
                note.photoFilename = r.photo
                note.inkDrawingFilename = r.ink
                note.highlightDrawingFilename = r.hl
                note.updatedAt = .now

                ctx.insert(note)

                // ✅ enqueue this note
                PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
            }

            folder.updatedAt = .now
            try? ctx.save()
        }
    }

    // MARK: - Reading mode ordering

    @MainActor
    private func startReadingMode(for folderID: UUID?) {
        let rootID = folderID ?? currentFolderID
        readingFolderTitle = (rootID == nil) ? "Library" : (aliveFolders.first(where: { $0.id == rootID! })?.name ?? "Folder")

        let list = buildFlattenedReadingList(folderID: rootID)
        guard !list.isEmpty else { return }

        readingNotes = list
        readingIndex = 0
        showReadingMode = true
    }

    private func buildFlattenedReadingList(folderID: UUID?) -> [PLNote] {
        var result: [PLNote] = []

        for item in orderedContents(in: folderID) {
            switch item {
            case .folder(let folder):
                result.append(contentsOf: buildFlattenedReadingList(folderID: folder.id))
            case .note(let note):
                result.append(note)
            }
        }

        return result
    }

    private func folderPreviewNote(folderID: UUID) -> PLNote? {
        let notes = aliveNotes
            .filter { $0.folderID == folderID }
            .sorted { $0.updatedAt > $1.updatedAt }
        return notes.first
    }

    @ViewBuilder
    private func menuOverlay(anchors: [MenuAnchorData]) -> some View {
        // ✅ Offline: no anchored menu layer
        if canModifyExisting {
            AnchoredMenuLayer(
                anchors: anchors,
                show: $showAnchoredMenu,
                note: menuNote,
                folder: menuFolder,
                kind: menuKind,
                onClose: { closeMenu() },

                // Properties
                onProperties: {
                    openPropertiesForCurrentMenuItem()
                    closeMenu()
                },

                // note actions
                onPinToggle: {
                    guard let n = menuNote else { return }
                    n.pinned.toggle()
                    n.updatedAt = .now
                    try? ctx.save()
                    PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)
                    closeMenu()
                },

                onNewFolderWithNote: {
                    guard let n = menuNote else { return }
                    pendingNoteForFolder = n
                    folderWithNoteName = ""
                    showCreateFolderWithNoteAlert = true
                    closeMenu()
                },
                onMoveToFolder: {
                    guard let n = menuNote else { return }
                    pendingNoteToMove = n
                    showMoveToFolderSheet = true
                    closeMenu()
                },
                onRemoveFromFolder: {
                    guard let n = menuNote else { return }
                    n.folderID = nil
                    n.updatedAt = .now
                    try? ctx.save()
                    PaperLinkSyncManager.shared.enqueueNote(n, ctx: ctx)

                    closeMenu()
                },
                onMoveToTrashNote: {
                    guard let n = menuNote else { return }
                    pendingTrashNote = n
                    pendingTrashFolder = nil
                    showTrashSlider = true
                    closeMenu()
                },
                onMoveEarlier: {
                    switch menuKind {
                    case .note:
                        guard let note = menuNote else { return }
                        moveContent(.note(note), direction: .earlier)
                    case .folder:
                        guard let folder = menuFolder else { return }
                        moveContent(.folder(folder), direction: .earlier)
                    }
                    closeMenu()
                },
                onMoveLater: {
                    switch menuKind {
                    case .note:
                        guard let note = menuNote else { return }
                        moveContent(.note(note), direction: .later)
                    case .folder:
                        guard let folder = menuFolder else { return }
                        moveContent(.folder(folder), direction: .later)
                    }
                    closeMenu()
                },

                // folder actions
                onReadingMode: {
                    guard let f = menuFolder else { return }
                    startReadingMode(for: f.id)
                    closeMenu()
                },
                onMoveToTrashFolder: {
                    guard let f = menuFolder else { return }
                    pendingTrashFolder = f
                    pendingTrashNote = nil
                    showTrashSlider = true
                    closeMenu()
                }
            )
        }
    }

    @MainActor
    private func closeReadingModeAndAnyNote() {
        showReadingMode = false
        previewingNote = nil
        editingNote = nil
    }

    @ViewBuilder
    private var emptyStateView: some View {
        let p = theme.palette
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        Text(q.isEmpty ? "Nothing here yet." : "No results for “\(q)”.")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(p.textSecondary)
            .padding(.top, 6)

        Button { showNewItemSheet = true } label: {
            Label("Create something", systemImage: "plus")
                .font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(p.railButton)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(p.outline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.textPrimary)
        .padding(.top, 2)
    }

    @MainActor
    private func autoFolderName(parentID: UUID?) -> String {
        let base = "New folder"

        let siblings = aliveFolders
            .filter { $0.parentFolderID == parentID }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }

        if !siblings.contains(where: { $0.caseInsensitiveCompare(base) == .orderedSame }) {
            return base
        }

        var i = 1
        while true {
            let candidate = "\(base) (\(i))"
            if !siblings.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
            i += 1
        }
    }
}

#endif

// MARK: - iPhone compact grid (Pinned/Recents)

#if os(iOS)

private struct CompactNotesGrid: View {
    @EnvironmentObject private var theme: PLThemeStore

    let notes: [PLNote]
    let cardSide: CGFloat
    let gridSpacing: CGFloat
    let outline: Color
    let columns: Int
    let canDrag: Bool
    let onOpen: (PLNote) -> Void

    var body: some View {
        // ✅ Fixed-width columns so cards don't get "pushed apart"
        let colCount = max(2, columns)
        let cols = Array(
            repeating: GridItem(.fixed(cardSide), spacing: gridSpacing, alignment: .leading),
            count: colCount
        )

        LazyVGrid(columns: cols, alignment: .leading, spacing: gridSpacing) {
            ForEach(notes) { note in
                NoteCardSquare(note: note)
                    .frame(width: cardSide, height: cardSide) // ✅ TRUE square
                    .clipped()
                    .contentShape(RoundedRectangle(cornerRadius: 26))
                    .onTapGesture { onOpen(note) }
                    .plIf(canDrag) { view in
                        view.draggable("note:\(note.id.uuidString)") {
                            DragPreviewCard(outline: outline) {
                                NoteCardSquare(note: note)
                                    .environmentObject(theme)
                                    .frame(width: cardSide, height: cardSide)
                            }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif

// MARK: - Drag Preview

struct DragPreviewCard<Content: View>: View {
    let outline: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(outline, lineWidth: 1)
            )
    }
}

// MARK: - Menu Icon Button

struct MenuIconButton: View {
    @EnvironmentObject private var theme: PLThemeStore

    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        let p = theme.palette

        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 40)
                    .background(p.railButton.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(p.outline, lineWidth: 1)
                    )

                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(p.textPrimary.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(p.card.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(p.outline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared UI Components

struct SectionHeader: View {
    @EnvironmentObject private var theme: PLThemeStore

    let title: String
    var accessory: String? = nil
    var accessoryAction: (() -> Void)? = nil

    var body: some View {
        let p = theme.palette

        HStack {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.88))
            Spacer()
            if let accessory, let accessoryAction {
                Button(action: accessoryAction) {
                    Text(accessory)
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary.opacity(0.90))
            }
        }
        .padding(.top, 6)
    }
}

struct SearchPill: View {
    @EnvironmentObject private var theme: PLThemeStore

    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let p = theme.palette

        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(p.textSecondary.opacity(0.95))

            TextField("Search notes", text: $text)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($focused)
                .foregroundStyle(p.textPrimary)

            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(p.textSecondary.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(p.canvas.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(p.outline, lineWidth: 1)
        )
        .onTapGesture { focused = true }
    }
}

#if os(iOS)

// MARK: - Thumbnail cache

final class PLThumbStore {
    static let shared = PLThumbStore()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Prevent memory blowups
        cache.countLimit = 250
        cache.totalCostLimit = 90 * 1024 * 1024 // ~90MB for thumbs
    }

    /// Returns a downsampled thumbnail for fast grid rendering.
    /// - Important: Does NOT change original photo resolution on disk.
    func thumbnailForPhoto(filename: String, maxPixel: Int) -> UIImage? {
        let key = NSString(string: "p:\(filename):\(cacheVersion(filename: filename)):\(maxPixel)")
        if let cached = cache.object(forKey: key) { return cached }

        guard let url = FileStore.shared.fileURL(filename) else { return nil }

        guard let img = downsampleImage(at: url, maxPixel: maxPixel) else { return nil }
        cache.setObject(img, forKey: key, cost: img.memoryCost)
        return img
    }

    /// Drawings are already “vector-ish” -> still cache the rendered preview, but keep cost-limited.
    func imageForDrawing(filename: String, renderMaxPixel: Int) -> UIImage? {
        let key = NSString(string: "d:\(filename):\(cacheVersion(filename: filename)):\(renderMaxPixel)")
        if let cached = cache.object(forKey: key) { return cached }

        guard let data = FileStore.shared.readData(filename: filename),
              !data.isEmpty,
              let drawing = try? PKDrawing(data: data) else { return nil }

        let b = drawing.bounds
        let invalid =
            b.isNull || b.isEmpty ||
            b.origin.x.isNaN || b.origin.y.isNaN ||
            b.size.width.isNaN || b.size.height.isNaN ||
            b.size.width <= 0 || b.size.height <= 0

        let rect = invalid ? CGRect(x: 0, y: 0, width: 800, height: 800) : b.insetBy(dx: -30, dy: -30)

        // Render size is based on renderMaxPixel
        let scale = max(1, CGFloat(renderMaxPixel) / max(rect.width, rect.height))
        let img = drawing.image(from: rect, scale: scale)

        cache.setObject(img, forKey: key, cost: img.memoryCost)
        return img
    }

    func imageForAnnotatedPhoto(
        photoFilename: String,
        inkFilename: String?,
        highlightFilename: String?,
        maxPixel: Int
    ) -> UIImage? {
        let key = NSString(
            string: "ap:\(photoFilename):\(cacheVersion(filename: photoFilename)):\(cacheVersion(filename: inkFilename)):\(cacheVersion(filename: highlightFilename)):\(maxPixel)"
        )
        if let cached = cache.object(forKey: key) { return cached }

        guard let base = thumbnailForPhoto(filename: photoFilename, maxPixel: maxPixel) else { return nil }
        let size = base.size
        let rect = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = base.scale
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            base.draw(in: rect)
            drawPhotoOverlay(filename: highlightFilename, in: rect, targetSize: size)
            drawPhotoOverlay(filename: inkFilename, in: rect, targetSize: size)
        }

        cache.setObject(image, forKey: key, cost: image.memoryCost)
        return image
    }

    private func drawPhotoOverlay(filename: String?, in rect: CGRect, targetSize: CGSize) {
        guard let filename,
              let data = FileStore.shared.readData(filename: filename),
              !data.isEmpty,
              let drawing = try? PKDrawing(data: data) else { return }

        let overlay = drawing.image(from: CGRect(origin: .zero, size: targetSize), scale: 1.0)
        overlay.draw(in: rect)
    }

    private func downsampleImage(at url: URL, maxPixel: Int) -> UIImage? {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary

        guard let src = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }

        let thumbOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary

        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func cacheVersion(filename: String?) -> String {
        guard let filename,
              let url = FileStore.shared.fileURL(filename),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return "0"
        }
        return String(modDate.timeIntervalSinceReferenceDate)
    }
}

private extension UIImage {
    var memoryCost: Int {
        guard let cg = self.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

// MARK: - Horizontal Preview Row

struct HorizontalPreviewRowSquare: View {
    @EnvironmentObject private var theme: PLThemeStore // ✅ add

    let notes: [PLNote]
    let cardSide: CGFloat
    let outline: Color
    let canDrag: Bool
    let onOpen: (PLNote) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(notes) { note in
                    NoteCardSquare(note: note)
                        .frame(width: cardSide, height: cardSide)
                        .contentShape(RoundedRectangle(cornerRadius: 26))
                        .onTapGesture { onOpen(note) }
                        .plIf(canDrag) { view in
                            view.draggable("note:\(note.id.uuidString)") {
                                DragPreviewCard(outline: outline) {
                                    NoteCardSquare(note: note)
                                        .environmentObject(theme) // ✅ IMPORTANT
                                        .frame(width: cardSide, height: cardSide)
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: cardSide + 8)
    }
}

// MARK: - Folder Card

struct FolderCardSquare: View {
    @EnvironmentObject private var theme: PLThemeStore

    let folder: PLFolder
    let previewNote: PLNote?

    var body: some View {
        let p = theme.palette

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 26)
                .fill(p.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(p.outline, lineWidth: 1)
                )

            if let previewNote {
                CardBackground(note: previewNote)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
            }

            LinearGradient(
                colors: [Color.black.opacity(0.08), Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 26))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22, weight: .bold))
                        .padding(9)
                        .background(Color.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Spacer()
                }

                Spacer()

                Text(folder.name)
                    .font(.system(size: 15, weight: .bold)) // ✅ tuned
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)               // ✅ tuned
                    .shadow(radius: 6)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .clipped()
    }
}

// MARK: - Note Card

struct NoteCardSquare: View {
    @EnvironmentObject private var theme: PLThemeStore
    let note: PLNote

    var body: some View {
        GeometryReader { geo in
            let p = theme.palette
            let size = geo.size

            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 26)
                    .fill(p.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26)
                            .stroke(p.outline, lineWidth: 1)
                    )

                CardBackground(note: note)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 26))

                LinearGradient(
                    colors: [Color.black.opacity(0.00), Color.black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 26))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(note.title)
                            .font(.system(size: 14, weight: .bold)) // ✅ tuned
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)               // ✅ tuned
                            .shadow(radius: 8)

                        Spacer()

                        if note.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 12, weight: .bold))
                                .opacity(0.95)
                                .shadow(radius: 8)
                            }
                    }

                    if let subtitle = subtitle(for: note), !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .semibold)) // ✅ tuned
                            .opacity(0.95)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)                   // ✅ tuned
                            .shadow(radius: 8)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .contentShape(RoundedRectangle(cornerRadius: 26))
        }
    }

    private func subtitle(for note: PLNote) -> String? {
        switch note.kind {
        case .text:
            return nil
        case .photo:
            return "Photo note"
        case .drawing:
            return "Drawing note"
        }
    }
}

struct CardBackground: View {
    let note: PLNote

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                switch note.kind {
                case .photo:
                    if let f = note.photoFilename,
                       let img = PLThumbStore.shared.imageForAnnotatedPhoto(
                            photoFilename: f,
                            inkFilename: note.inkDrawingFilename,
                            highlightFilename: note.highlightDrawingFilename,
                            maxPixel: 420
                       ) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                    } else {
                        fallback("photo", size: size)
                    }

                case .drawing:
                    if let f = note.inkDrawingFilename,
                       let img = PLThumbStore.shared.imageForDrawing(filename: f, renderMaxPixel: 420) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                    } else {
                        fallback("pencil.tip", size: size)
                    }

                case .text:
                    RoundedRectangle(cornerRadius: 26)
                        .fill(Color.white.opacity(0.14))
                        .frame(width: size.width, height: size.height)

                    Text((note.textBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "Text note"
                         : (note.textBody ?? ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(10)
                        .padding(14)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func fallback(_ systemName: String, size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(Color.white.opacity(0.10))
                .frame(width: size.width, height: size.height)

            Image(systemName: systemName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

#endif

// MARK: - Anchored menu infrastructure (PreferenceKey)

#if os(iOS)

enum MenuAnchorKind { case note, folder }

struct MenuAnchorData: Equatable {
    let id: UUID
    let kind: MenuAnchorKind
    let rect: CGRect
}

private struct MenuAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [MenuAnchorData] = []
    static func reduce(value: inout [MenuAnchorData], nextValue: () -> [MenuAnchorData]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func menuAnchor(id: UUID, kind: MenuAnchorKind) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: MenuAnchorPreferenceKey.self,
                        value: [MenuAnchorData(id: id, kind: kind, rect: geo.frame(in: .global))]
                    )
            }
        )
    }
}

#endif

// MARK: - AnchoredMenuLayer

struct AnchoredMenuLayer: View {
    @EnvironmentObject private var theme: PLThemeStore

    let anchors: [MenuAnchorData]

    @Binding var show: Bool
    let note: PLNote?
    let folder: PLFolder?
    let kind: LibraryView.MenuKind

    let onClose: () -> Void

    let onProperties: () -> Void

    // note actions
    let onPinToggle: () -> Void
    let onNewFolderWithNote: () -> Void
    let onMoveToFolder: () -> Void
    let onRemoveFromFolder: () -> Void
    let onMoveToTrashNote: () -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void

    // folder actions
    let onReadingMode: () -> Void
    let onMoveToTrashFolder: () -> Void

    @State private var targetRect: CGRect = .zero

    private let menuWidth: CGFloat = 320
    private let menuHeight: CGFloat = 360   // used for positioning only
    private let gap: CGFloat = 12

    var body: some View {
        Group {
            if show {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                GeometryReader { geo in
                    menuView
                        .frame(width: menuWidth)
                        .position(menuPosition(in: geo.size))
                }
                .ignoresSafeArea()
            }
        }
        .onAppear { resolveTarget() }
        .onChange(of: show) { _, _ in resolveTarget() }
        .onChange(of: note?.id) { _, _ in resolveTarget() }
        .onChange(of: folder?.id) { _, _ in resolveTarget() }
        .onChange(of: anchors.count) { _, _ in resolveTarget() }
    }

    private func resolveTarget() {
        guard show else { return }
        switch kind {
        case .note:
            guard let id = note?.id else { return }
            if let a = anchors.first(where: { $0.id == id && $0.kind == .note }) {
                targetRect = a.rect
            }
        case .folder:
            guard let id = folder?.id else { return }
            if let a = anchors.first(where: { $0.id == id && $0.kind == .folder }) {
                targetRect = a.rect
            }
        }
    }

    private func menuPosition(in containerSize: CGSize) -> CGPoint {
        let preferredBelowY = targetRect.maxY + gap + menuHeight / 2
        let preferredAboveY = targetRect.minY - gap - menuHeight / 2

        let minY = menuHeight / 2 + 20
        let maxY = containerSize.height - menuHeight / 2 - 20

        let y: CGFloat
        if preferredBelowY <= maxY {
            y = preferredBelowY
        } else if preferredAboveY >= minY {
            y = preferredAboveY
        } else {
            y = min(max(preferredBelowY, minY), maxY)
        }

        let halfW = menuWidth / 2
        let minX = halfW + 20
        let maxX = containerSize.width - halfW - 20
        let x = min(max(targetRect.midX, minX), maxX)

        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private var menuView: some View {
        switch kind {
        case .note: noteMenu
        case .folder: folderMenu
        }
    }

    private var noteMenu: some View {
        let p = theme.palette

        return VStack(spacing: 12) {
            HStack {
                Text(note?.title ?? "Note")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(p.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {

                MenuIconButton(
                    title: (note?.pinned ?? false) ? "Unpin" : "Pin",
                    icon: (note?.pinned ?? false) ? "pin.slash" : "pin"
                ) { onPinToggle() }

                MenuIconButton(title: "Move", icon: "folder") { onMoveToFolder() }

                MenuIconButton(title: "New folder", icon: "folder.badge.plus") { onNewFolderWithNote() }

                if note?.folderID != nil {
                    MenuIconButton(title: "Remove", icon: "tray.and.arrow.up") { onRemoveFromFolder() }
                    MenuIconButton(title: "Earlier", icon: "arrow.left.circle") { onMoveEarlier() }
                    MenuIconButton(title: "Later", icon: "arrow.right.circle") { onMoveLater() }
                }

                MenuIconButton(title: "Properties", icon: "slider.horizontal.3") { onProperties() }
            }

            Divider().opacity(0.15)

            HStack(spacing: 10) {
                Button { onMoveToTrashNote() } label: {
                    Label("Move to Trash", systemImage: "trash")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(p.danger.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)

                Button(action: onClose) {
                    Text("Close")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 92, height: 50)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(p.canvas.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(p.outline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.20), radius: 20, x: 0, y: 10)
        )
    }

    private var folderMenu: some View {
        let p = theme.palette

        return VStack(spacing: 12) {
            HStack {
                Text(folder?.name ?? "Folder")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(p.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {
                MenuIconButton(title: "Reading", icon: "book") { onReadingMode() }
                MenuIconButton(title: "Properties", icon: "slider.horizontal.3") { onProperties() }
                if folder?.parentFolderID != nil {
                    MenuIconButton(title: "Earlier", icon: "arrow.left.circle") { onMoveEarlier() }
                    MenuIconButton(title: "Later", icon: "arrow.right.circle") { onMoveLater() }
                }
            }

            Divider().opacity(0.15)

            HStack(spacing: 10) {
                Button { onMoveToTrashFolder() } label: {
                    Label("Move to Trash", systemImage: "trash")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(p.danger.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)

                Button(action: onClose) {
                    Text("Close")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 92, height: 50)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(p.canvas.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(p.outline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.20), radius: 20, x: 0, y: 10)
        )
    }
}

// MARK: - Folder Picker Sheet

#if os(iOS)

struct FolderPickerSheet: View {
    @EnvironmentObject private var theme: PLThemeStore

    let allFolders: [PLFolder]
    let onPick: (PLFolder) -> Void
    let onMoveToRoot: () -> Void
    let onCancel: () -> Void

    @State private var query: String = ""

    var body: some View {
        let p = theme.palette

        NavigationStack {
            List {
                Section {
                    Button("Move to Root") { onMoveToRoot() }
                }

                Section("Folders") {
                    ForEach(filteredRootFolders(), id: \.id) { f in
                        FolderRow(folder: f, allFolders: allFolders, query: query, depth: 0, onPick: onPick)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(p.canvas.ignoresSafeArea())
            .navigationTitle("Move to folder")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        }
    }

    private func filteredRootFolders() -> [PLFolder] {
        let roots = allFolders.filter { $0.parentFolderID == nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return roots.sorted { $0.name.lowercased() < $1.name.lowercased() } }
        return roots.filter { subtreeContains(folder: $0, query: q) }
    }

    private func subtreeContains(folder: PLFolder, query: String) -> Bool {
        if folder.name.lowercased().contains(query) { return true }
        let children = allFolders.filter { $0.parentFolderID == folder.id }
        return children.contains { subtreeContains(folder: $0, query: query) }
    }
}

struct FolderRow: View {
    let folder: PLFolder
    let allFolders: [PLFolder]
    let query: String
    let depth: Int
    let onPick: (PLFolder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onPick(folder)
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text(folder.name)
                    Spacer()
                    Image(systemName: "chevron.right").opacity(0.3)
                }
            }

            let children = filteredChildren()
            if !children.isEmpty {
                ForEach(children, id: \.id) { c in
                    FolderRow(folder: c, allFolders: allFolders, query: query, depth: depth + 1, onPick: onPick)
                        .padding(.leading, 18)
                }
            }
        }
    }

    private func filteredChildren() -> [PLFolder] {
        let kids = allFolders
            .filter { $0.parentFolderID == folder.id }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return kids }
        return kids.filter { subtreeContains(folder: $0, query: q) }
    }

    private func subtreeContains(folder: PLFolder, query: String) -> Bool {
        if folder.name.lowercased().contains(query) { return true }
        let children = allFolders.filter { $0.parentFolderID == folder.id }
        return children.contains { subtreeContains(folder: $0, query: query) }
    }
}

#endif

// MARK: - Reading Mode Screen

#if os(iOS)

struct ReadingModeScreen: View {
    @EnvironmentObject private var theme: PLThemeStore

    let notes: [PLNote]
    let startIndex: Int
    let title: String
    let onClose: () -> Void

    @State private var idx: Int = 0

    var body: some View {
        let p = theme.palette

        ZStack {
            p.background.ignoresSafeArea()

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button(action: onClose) {
                        Label("Done", systemImage: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .frame(height: 52)
                            .padding(.horizontal, 16)
                            .background(p.textPrimary.opacity(0.92))
                            .foregroundStyle(p.background)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)

                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(p.textPrimary.opacity(0.90))

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                ZStack {
                    NoteEditorScreen(note: notes[idx], readingMode: true, hideChrome: true)
                        .id(notes[idx].id)

                    HStack {
                        Button { idx = max(0, idx - 1) } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .bold))
                                .frame(width: 52, height: 52)
                                .background(p.railButton)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(p.outline, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(idx <= 0)
                        .opacity(idx <= 0 ? 0.35 : 1)
                        .foregroundStyle(p.textPrimary)

                        Spacer()

                        Button { idx = min(notes.count - 1, idx + 1) } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18, weight: .bold))
                                .frame(width: 52, height: 52)
                                .background(p.railButton)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(p.outline, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(idx >= notes.count - 1)
                        .opacity(idx >= notes.count - 1 ? 0.35 : 1)
                        .foregroundStyle(p.textPrimary)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .onAppear {
            idx = min(max(0, startIndex), max(0, notes.count - 1))
        }
    }
}

#endif

// MARK: - Delete Slider Confirm Sheet

struct DeleteSliderConfirmSheet: View {
    @EnvironmentObject private var theme: PLThemeStore

    let title: String
    let message: String
    let confirmLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        let p = theme.palette

        VStack(spacing: 14) {
            Capsule()
                .fill(p.textPrimary.opacity(0.18))
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(p.textPrimary)

            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)

            slider

            Button("Cancel", role: .cancel) { onCancel() }
                .font(.system(size: 16, weight: .bold))
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .background(p.railButton)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(p.outline, lineWidth: 1)
                )
                .padding(.horizontal, 18)
                .foregroundStyle(p.textPrimary)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 18)
        .background(p.background)
    }

    private var slider: some View {
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 10) {
            Text(confirmLabel)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textSecondary)
                .padding(.horizontal, 18)

            GeometryReader { geo in
                let w = geo.size.width
                let knobSize: CGFloat = 54
                let maxX = max(0, w - knobSize)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(p.textPrimary.opacity(0.10))
                        .frame(height: 58)

                    RoundedRectangle(cornerRadius: 18)
                        .fill(p.danger.opacity(0.18))
                        .frame(width: knobSize + (maxX * progress), height: 58)

                    HStack {
                        Text("Slide")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(p.textSecondary.opacity(0.85))
                        Spacer()
                    }
                    .padding(.horizontal, 18)

                    RoundedRectangle(cornerRadius: 18)
                        .fill(p.danger.opacity(0.90))
                        .frame(width: knobSize, height: 58)
                        .overlay(
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .offset(x: maxX * progress)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let x = min(max(0, value.translation.width), maxX)
                                    progress = (maxX <= 0) ? 0 : (x / maxX)
                                }
                                .onEnded { _ in
                                    if progress > 0.92 {
                                        onConfirm()
                                        progress = 0
                                    } else {
                                        withAnimation(.spring()) { progress = 0 }
                                    }
                                }
                        )
                }
            }
            .frame(height: 58)
            .padding(.horizontal, 18)
        }
        .padding(.top, 8)
    }
}

// MARK: - Detents helpers

struct CompactDetentsIfAvailable: ViewModifier {
    let height: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) { content.presentationDetents([.height(height)]) }
        else { content }
    }
}

struct LargeDetentsIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) { content.presentationDetents([.medium, .large]) }
        else { content }
    }
}

// MARK: - Camera Picker (kept; unused now)

#if os(iOS)

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage {
                onImage(img)
            } else {
                onCancel()
            }
        }
    }
}

#endif

// MARK: - New Item Sheet

#if os(iOS)

struct NewItemSheet: View {
    @EnvironmentObject private var theme: PLThemeStore

    let showDrawingOption: Bool
    let onNewText: () -> Void
    let onNewDrawing: () -> Void
    let onImportPhotos: () -> Void
    let onTakePhotos: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        let p = theme.palette

        VStack(spacing: 14) {
            Capsule()
                .fill(p.textPrimary.opacity(0.18))
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            Text("New")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(p.textPrimary)

            VStack(spacing: 10) {
                sheetButton("Text note", systemImage: "doc.text", action: onNewText)

                if showDrawingOption {
                    sheetButton("Drawing note", systemImage: "pencil.tip", action: onNewDrawing)
                }

                sheetButton("Import photo(s)", systemImage: "photo.on.rectangle", action: onImportPhotos)
                sheetButton("Take photo(s)", systemImage: "camera", action: onTakePhotos)
                sheetButton("New folder", systemImage: "folder.badge.plus", action: onNewFolder)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.background.ignoresSafeArea())
    }

    private func sheetButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        let p = theme.palette

        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 28)

                Text(title)
                    .font(.system(size: 17, weight: .bold))

                Spacer()

                Image(systemName: "chevron.right")
                    .opacity(0.35)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .background(p.card)
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

#endif

// MARK: - PropertiesSheet

struct PropertiesSheet: View {
    @EnvironmentObject private var theme: PLThemeStore

    let note: PLNote?
    let folder: PLFolder?
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    // UI state (we’ll persist later; this is still UI-only)
    @State private var folderColor: Color = .gray.opacity(0.25)
    @State private var drawingLineWidth: Double = 6
    @State private var cardZoom: Double = 1.0

    var body: some View {
        let p = theme.palette

        VStack(spacing: 14) {
            Capsule()
                .fill(p.textPrimary.opacity(0.18))
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(p.textPrimary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    if folder != nil {
                        sectionTitle("Folder")
                        colorRow("Folder color", selection: $folderColor)
                        hint("This will tint the folder card + breadcrumb (once saved).")
                    }

                    if note != nil {
                        sectionTitle("Note")
                        stepperRow("Drawing line", value: $drawingLineWidth, range: 2...20, suffix: "px")
                        sliderRow("Preview zoom", value: $cardZoom, range: 0.85...1.15)
                        hint("Text size now lives in the editor top bar. Drawing line still controls drawing/photo ink defaults.")
                    }

                    sectionTitle("More")
                    Toggle("Show advanced info", isOn: .constant(true))
                        .disabled(true)
                    hint("Next: created date, updated date, file sizes, note count in folder, etc.")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }

            HStack(spacing: 10) {
                Button("Cancel") {
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

                Button("Save") {
                    // Persistence gets wired later
                    onClose()
                    dismiss()
                }
                .font(.system(size: 16, weight: .bold))
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .background(p.accent.opacity(0.80))
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
    }

    private var title: String {
        if folder != nil { return "Folder Properties" }
        return "Note Properties"
    }

    private func sectionTitle(_ text: String) -> some View {
        let p = theme.palette

        return Text(text)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(p.textPrimary.opacity(0.90))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        let p = theme.palette

        return Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(p.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepperRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        let p = theme.palette

        return HStack {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.90))
            Spacer()
            Stepper("\(Int(value.wrappedValue))\(suffix)", value: value, in: range, step: 1)
                .labelsHidden()
            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(14)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p.textPrimary.opacity(0.90))
                Spacer()
                Text(String(format: "%.2f×", value.wrappedValue))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p.textSecondary)
            }
            Slider(value: value, in: range)
        }
        .padding(14)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private func colorRow(_ label: String, selection: Binding<Color>) -> some View {
        let p = theme.palette

        return HStack {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.90))
            Spacer()
            HStack(spacing: 10) {
                ForEach(palette, id: \.self) { c in
                    Circle()
                        .fill(c)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle().stroke(p.textPrimary.opacity(selection.wrappedValue == c ? 0.35 : 0.0), lineWidth: 3)
                        )
                        .onTapGesture { selection.wrappedValue = c }
                }
            }
        }
        .padding(14)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private var palette: [Color] {
        [
            .white.opacity(0.25),
            .black.opacity(0.15),
            .blue.opacity(0.75),
            .purple.opacity(0.75),
            .green.opacity(0.75),
            .red.opacity(0.75)
        ]
    }
}

// MARK: - Pinned Notes Grid Screen

struct PinnedNotesGridScreen: View {
    @EnvironmentObject private var theme: PLThemeStore
    @Environment(\.dismiss) private var dismiss

    let notes: [PLNote]
    let cardSide: CGFloat
    let gridSpacing: CGFloat
    let onOpen: (PLNote) -> Void

    var body: some View {
        let p = theme.palette
        let cols = [GridItem(.adaptive(minimum: cardSide, maximum: cardSide), spacing: gridSpacing)]

        ZStack {
            p.background.ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Text("Pinned")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(p.textPrimary)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 40, height: 40)
                            .background(p.railButton)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(p.outline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(p.textPrimary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: cols, alignment: .leading, spacing: gridSpacing) {
                        ForEach(notes) { note in
                            NoteCardSquare(note: note)
                                .frame(width: cardSide, height: cardSide)
                                .contentShape(RoundedRectangle(cornerRadius: 26))
                                .onTapGesture { onOpen(note) }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

// MARK: - Conditional modifier helper

private extension View {
    @ViewBuilder
    func plIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
