# PaperLink

PaperLink is an iOS-first notes app built with SwiftUI, SwiftData, PencilKit, Firebase Auth, and a custom HTTP sync layer. It supports three note kinds:

- `text`
- `photo`
- `drawing`

The app uses local-first storage and then syncs folders/notes/files to a remote service.

## High-Level Architecture

- App entry: `PaperLink/PaperLinkApp.swift`
  - Boots Firebase.
  - Creates a single shared SwiftData `ModelContainer`.
  - Configures `PaperLinkSyncManager` with the production server URL.
  - Injects `PLThemeStore`, `PLAuthStore`, and `NetworkMonitor`.

- Root shell: `PaperLink/RootView.swift`
  - Handles auth gating, theme selection, network state, sidebar, and top-level navigation.
  - Hosts `LibraryView`, `InfoView`, trash/settings tabs, and sign-in flow.

- Main library UI: `PaperLink/LibraryView.swift`
  - Shows folders, pinned notes, recents, and creation flows.
  - Opens existing notes in `NoteEditorScreen`.
  - Creates new drafts via `PLNoteDraft`.
  - Contains drag/drop, anchored menus, reading mode, and camera/photo import flows.

- Note editor: `PaperLink/NoteEditorScreen.swift`
  - Single editor for all note kinds.
  - Text notes: structured block-based editor.
  - Photo notes: image plus separate ink/highlight overlay layers.
  - Drawing notes: infinite PencilKit canvas with custom floating palette.

- PencilKit wrapper: `PaperLink/PencilCanvasView.swift`
  - Wraps `PKCanvasView`.
  - Supports plain and infinite canvas modes.
  - Adds a custom overlay for lined/dot-grid paper.
  - This is the main file to inspect for drawing latency, Pencil issues, zoom, and gesture conflicts.

- Local file storage: `PaperLink/FileStore.swift`
  - Stores photo files and `.pkd` drawing data under Documents/`PaperlinkFiles`.
  - SwiftData models store filenames, not blobs.

- Sync engine: `PaperLink/PaperLinkSyncManager.swift`
  - Local upload queue based on `PLPendingUpload`.
  - Pushes folders/notes/files via `PaperLinkSyncClient`.
  - Pulls remote changes and reconciles them back into SwiftData.

- Sync client and payloads:
  - `PaperLink/PaperLinkSyncClient.swift`
  - `PaperLink/SyncModels.swift`
  - `paperlink_server_hardened.txt` is a server-side reference snapshot, not app code.

## Local Data Model

Defined in `PaperLink/Models.swift`.

- `PLFolder`
  - Hierarchical folder tree via `parentFolderID`.
  - Soft delete via `deletedAt`.
  - Shared media rotation via `mediaRotationQuarterTurns`.
  - Display ordering via `readingOrder`.

- `PLNote`
  - `kindRaw` maps to `PLNoteKind`.
  - Optional payload per kind:
    - `textBody`
    - `photoFilename`
    - `inkDrawingFilename`
    - `highlightDrawingFilename`
  - Soft delete via `deletedAt`.
  - Per-note media rotation override.
  - Drawing paper/tool defaults stored per note.

- `PLPendingUpload`
  - Queue row for deferred sync work.

## Drawing Stack

The drawing system is split across two files:

- `PaperLink/NoteEditorScreen.swift`
  - Chooses active tool/color/width.
  - Builds the floating palette UI.
  - Supplies `PKTool` instances to `PencilCanvasView`.
  - For photo notes, uses separate canvases for ink and highlight.

- `PaperLink/PencilCanvasView.swift`
  - Owns `PKCanvasView`.
  - Applies drawing policy and gesture behavior.
  - Maintains infinite canvas sizing and viewport reset.
  - Avoids pushing drawing data back into the canvas on every SwiftUI update.

### Recent Drawing Pain Points

If another agent is debugging the drawing editor, start here:

- Tool/color bugs are usually in `toolForCurrentState()` in `NoteEditorScreen.swift`.
- Pencil/finger gesture bugs are usually in `configure(_:coordinator:)` in `PencilCanvasView.swift`.
- Lag often comes from unnecessary `drawingData` round-trips between SwiftUI state and `PKCanvasView`.
- Rotation/fullscreen issues for drawing notes are handled in the drawing branch of `zoomableEditorContent` in `NoteEditorScreen.swift`.

## Auth and Network

- Google Sign-In and Firebase Auth are set up in `PaperLink/PaperLinkApp.swift` and `PaperLink/RootView.swift`.
- `NetworkMonitor` gates edit behavior when offline.
- The current policy is roughly:
  - Offline users can still create new content locally.
  - Modifying existing synced content is restricted in some flows.

## Important UX Conventions

- Deletion is usually soft delete, not immediate file removal.
- Reading mode opens notes/folders in a viewer-like flow.
- The app supports theme switching and some dark themes, but many editing surfaces still assume light paper.
- iPhone has tighter restrictions than iPad for media note editing.

## Files Worth Reading First

For a quick mental model, read in this order:

1. `PaperLink/PaperLinkApp.swift`
2. `PaperLink/RootView.swift`
3. `PaperLink/Models.swift`
4. `PaperLink/LibraryView.swift`
5. `PaperLink/NoteEditorScreen.swift`
6. `PaperLink/PencilCanvasView.swift`
7. `PaperLink/FileStore.swift`
8. `PaperLink/PaperLinkSyncManager.swift`
9. `PaperLink/PaperLinkSyncClient.swift`

## Known Constraints

- There is very little automated test coverage.
- Large files like `LibraryView.swift` and `NoteEditorScreen.swift` contain a lot of mixed responsibilities.
- The project currently uses a single large note editor rather than splitting text/photo/drawing editors into separate modules.
- Build system issues have previously shown up in Xcode DerivedData; if the build DB gets locked, clear the project-specific `XCBuildData` under DerivedData.

## Suggested Next Refactors

- Split `NoteEditorScreen.swift` into text/photo/drawing subfeatures.
- Split the floating palette into its own file.
- Introduce narrower sync/domain services instead of keeping most orchestration in `PaperLinkSyncManager`.
- Add targeted UI tests for drawing note creation/editing on iPad.
