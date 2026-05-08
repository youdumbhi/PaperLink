# PaperLink

PaperLink is a local-first notes app for iPhone, iPad, and Mac Catalyst built with SwiftUI, SwiftData, PencilKit, Firebase Auth, Google Sign-In, and a custom HTTP sync backend.

It supports three note kinds:

- `text`
- `photo`
- `drawing`

## Features

- Folder hierarchy with pinned notes and recents
- Soft delete and a sync-backed trash flow
- Theme switching
- Camera capture and photo import
- PencilKit drawing with custom tools, paper styles, and an infinite canvas
- Separate ink and highlight layers for photo notes
- Local-first storage with background sync to a remote service
- Offline restrictions that still allow creating new content locally

## Project Layout

- `PaperLink/PaperLinkApp.swift`: app entry point, Firebase bootstrap, SwiftData container, sync setup, and sync heartbeat
- `PaperLink/RootView.swift`: auth gate, sidebar shell, top-level navigation, settings, and offline banner
- `PaperLink/LibraryView.swift`: library browser, folder/note creation flows, drag and drop, reading mode, photo import, and camera entry points
- `PaperLink/FolderBrowserView.swift`: folder-only browser view
- `PaperLink/InfoView.swift`: workspace info and usage stats
- `PaperLink/PinnedNotesSheet.swift`: pinned notes sheet
- `PaperLink/NoteEditorScreen.swift`: editor for text, photo, and drawing notes
- `PaperLink/PencilCanvasView.swift`: PencilKit wrapper and infinite canvas behavior
- `PaperLink/CustomCameraCaptureView.swift`: in-app camera capture
- `PaperLink/FileStore.swift`: file-backed media storage in `Documents/PaperlinkFiles`
- `PaperLink/Models.swift`: SwiftData models and local defaults
- `PaperLink/SyncModels.swift`: sync payload DTOs
- `PaperLink/PaperLinkSyncManager.swift`: local queue, sync orchestration, reconciliation, and purge handling
- `PaperLink/PaperLinkSyncClient.swift`: HTTP client for the backend API
- `PaperLink/PLPendingUpload.swift`: deferred sync queue row
- `paperlink_server_hardened.txt`: backend reference snapshot, not app code

## Data Model

- `PLFolder`
  - Folder tree via `parentFolderID`
  - Soft delete via `deletedAt`
  - Folder-wide media rotation via `mediaRotationQuarterTurns`
  - Reading order via `readingOrder`
- `PLNote`
  - `kindRaw` maps to `PLNoteKind`
  - Optional payload fields for text, photo, ink, and highlight content
  - Soft delete via `deletedAt`
  - Per-note media rotation override
  - Drawing defaults for paper style, pen width, marker width, line spacing, dot spacing, and dot size
- `PLPendingUpload`
  - Queue row for deferred folder/note sync work

## Sync Model

PaperLink is local-first.

- Local changes enqueue `PLPendingUpload` rows
- The sync manager pushes folders and notes to the backend
- The sync manager pulls full or incremental updates from the backend
- Remote purges remove local records and associated files
- Media files are stored separately from SwiftData and are fetched by filename when needed

The backend contract is documented by the app client and mirrored in `paperlink_server_hardened.txt`.

## Requirements

- Xcode 26.2 or newer
- iOS 18.6 / macOS 14.6 deployment targets in the current project
- A Firebase project with Google Sign-In enabled
- A valid `GoogleService-Info.plist`
- A backend that implements the PaperLink sync API

## Setup

1. Open `PaperLink.xcodeproj` in Xcode.
2. Add or replace `PaperLink/GoogleService-Info.plist` with your Firebase app configuration.
3. Make sure the Google URL scheme in `PaperLink/Info.plist` matches your Firebase reversed client ID.
4. Update the sync server URL in `PaperLink/PaperLinkApp.swift` if you are not using the current backend host.
5. Build and run on an iPhone, iPad, or Mac Catalyst destination.

The app currently points the sync client at `https://paperlink.benchen.io`.

## Backend Contract

The client expects these endpoints under `/v1/`:

- `POST /v1/folders/upsert`
- `POST /v1/notes/create`
- `GET /v1/sync/full`
- `GET /v1/sync/pull`
- `POST /v1/trash/empty`
- `GET /v1/files/get`
- `GET /v1/stats/usage`

Requests are authenticated with Firebase ID tokens. The client also supports optional Cloudflare Access service-auth headers.

## Notes

- Deletion is soft delete by default.
- On iPhone, photo and drawing notes are generally view-only in the editor; text editing is more flexible.
- The current unit and UI test targets are placeholders and do not provide meaningful coverage yet.
