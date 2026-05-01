import Foundation
import SwiftData
import Combine

@MainActor
final class PaperLinkSyncManager: ObservableObject {
    static let shared = PaperLinkSyncManager()
    private init() {}

    private var client: PaperLinkSyncClient?
    private var isProcessingQueue = false
    private var queuePassRequested = false
    private var isSyncingDown = false
    private var isSyncCycleRunning = false
    private var syncCycleRequested = false
    private var fullSyncRequested = false
    private var scheduledKickTask: Task<Void, Never>?
    private var lastSuccessfulPullServerTime: Date?

    func configure(serverBaseURL: String) {
        guard let url = URL(string: serverBaseURL) else { return }
        client = PaperLinkSyncClient(config: .init(baseURL: url))
    }

    func fetchUsageStats() async throws -> RemoteUsageStats {
        guard let client else { throw PaperLinkSyncClient.SyncError.badURL }
        return try await client.fetchUsageStats()
    }

    // MARK: - Queue

    func enqueueFolder(_ folder: PLFolder, ctx: ModelContext) {
        upsertQueueItem(entityType: "folder", entityID: folder.id.uuidString, ctx: ctx)
        scheduleSyncKick(ctx: ctx)
    }

    func enqueueNote(_ note: PLNote, ctx: ModelContext) {
        upsertQueueItem(entityType: "note", entityID: note.id.uuidString, ctx: ctx)
        scheduleSyncKick(ctx: ctx)
    }

    func emptyTrash(ctx: ModelContext) async throws {
        guard let client else { return }
        try await client.emptyTrash()
        _ = await syncDownFromServer(ctx: ctx, forceFullSync: true)
        pruneCompletedQueue(ctx: ctx)
    }

    func runSyncCycle(ctx: ModelContext, allowUpload: Bool, forceFullSync: Bool = false) async {
        guard client != nil else { return }
        guard allowUpload else { return }

        syncCycleRequested = true
        if forceFullSync {
            fullSyncRequested = true
        }
        guard !isSyncCycleRunning else { return }

        isSyncCycleRunning = true
        defer { isSyncCycleRunning = false }

        while syncCycleRequested {
            syncCycleRequested = false

            let shouldForceFullSync = fullSyncRequested || lastSuccessfulPullServerTime == nil
            fullSyncRequested = false

            if let payload = await syncDownFromServer(ctx: ctx, forceFullSync: shouldForceFullSync),
               shouldForceFullSync,
               reconcileLocalStateAgainstRemote(payload, ctx: ctx) {
                queuePassRequested = true
            }
            let didUploadAnything = await processQueueIfPossible(ctx: ctx, allowUpload: allowUpload)
            if didUploadAnything {
                _ = await syncDownFromServer(ctx: ctx, forceFullSync: false)
            }
            pruneCompletedQueue(ctx: ctx)
        }
    }

    func processQueueIfPossible(ctx: ModelContext, allowUpload: Bool) async -> Bool {
        guard allowUpload else { return false }
        guard let client else { return false }
        if isProcessingQueue {
            queuePassRequested = true
            return false
        }

        isProcessingQueue = true
        defer { isProcessingQueue = false }
        var didUploadAnything = false
        repeat {
            queuePassRequested = false
            var uploadedFolderIDsThisPass = Set<UUID>()

            while let item = nextQueuedUpload(ctx: ctx) {
                if Task.isCancelled { return didUploadAnything }

                item.state = .uploading
                item.lastError = nil
                try? ctx.save()

                do {
                    if item.entityType == "folder" {
                        guard let fid = UUID(uuidString: item.entityID) else { throw SyncErr.badID }
                        let fetch = FetchDescriptor<PLFolder>(predicate: #Predicate { $0.id == fid })
                        guard let folder = (try? ctx.fetch(fetch))?.first else { throw SyncErr.missingEntity }

                        try await withRetry {
                            try await client.uploadUpsertFolder(folder: folder)
                        }
                        didUploadAnything = true

                    } else if item.entityType == "note" {
                        guard let nid = UUID(uuidString: item.entityID) else { throw SyncErr.badID }
                        let fetch = FetchDescriptor<PLNote>(predicate: #Predicate { $0.id == nid })
                        guard let note = (try? ctx.fetch(fetch))?.first else { throw SyncErr.missingEntity }

                        if let folderID = note.folderID, !uploadedFolderIDsThisPass.contains(folderID) {
                            let folderFetch = FetchDescriptor<PLFolder>(predicate: #Predicate { $0.id == folderID })
                            if let folder = (try? ctx.fetch(folderFetch))?.first {
                                try await withRetry {
                                    try await client.uploadUpsertFolder(folder: folder)
                                }
                                uploadedFolderIDsThisPass.insert(folderID)
                                didUploadAnything = true
                            } else {
                                enqueueFolderIfNeeded(folderID: folderID, ctx: ctx)
                            }
                        }

                        try await withRetry {
                            try await client.uploadCreateNote(note: note)
                        }
                        didUploadAnything = true

                    } else {
                        throw SyncErr.unknownType
                    }

                    item.state = .done
                    item.lastError = nil
                    try? ctx.save()

                } catch SyncErr.missingEntity {
                    // Entity was removed locally; this queue item is no longer actionable.
                    item.state = .done
                    item.lastError = nil
                    try? ctx.save()

                } catch let error as PaperLinkSyncClient.SyncError {
                    if case .conflict(let detail) = error {
                        // Server has a newer version; stop retrying this local stale mutation.
                        item.state = .done
                        item.lastError = detail
                        try? ctx.save()

                        _ = await syncDownFromServer(ctx: ctx, forceFullSync: true)
                        continue
                    }

                    if case .missingLocalFile = error {
                        _ = await syncDownFromServer(ctx: ctx, forceFullSync: true)
                    }

                    item.state = .failed
                    item.lastError = String(describing: error)
                    print("UPLOAD FAILED:", item.entityType, item.entityID, error)
                    try? ctx.save()

                } catch {
                    item.state = .failed
                    item.lastError = String(describing: error)
                    print("UPLOAD FAILED:", item.entityType, item.entityID, error)
                    try? ctx.save()
                }
            }
        } while queuePassRequested
        return didUploadAnything
    }

    // MARK: - ✅ PULL (restore from server)

    func syncDownFromServer(ctx: ModelContext, forceFullSync: Bool = false) async -> FullSyncPayload? {
        guard let client else { return nil }
        guard !isSyncingDown else { return nil }

        isSyncingDown = true
        defer { isSyncingDown = false }

        do {
            let payload: FullSyncPayload
            if forceFullSync || lastSuccessfulPullServerTime == nil {
                payload = try await client.fetchFullSync()
            } else {
                payload = try await client.fetchSyncPull(since: lastSuccessfulPullServerTime)
            }

            applyRemotePurges(payload, ctx: ctx)

            // ----- Folders -----
            for rf in payload.folders {
                let fid = rf.id
                let fetch = FetchDescriptor<PLFolder>(predicate: #Predicate { $0.id == fid })
                let existing = (try? ctx.fetch(fetch))?.first

                if let f = existing {
                    let hasLocalChanges = hasLocalPendingUpload(
                        entityType: "folder",
                        entityID: rf.id.uuidString,
                        ctx: ctx
                    )
                    guard !hasLocalChanges else { continue }

                    if rf.updatedAt > f.updatedAt
                        || (rf.updatedAt == f.updatedAt && shouldApplyRemoteFolder(rf, to: f)) {
                        applyRemoteFolder(rf, to: f)
                    }
                } else {
                    let f = PLFolder(name: rf.name, parentFolderID: rf.parentFolderID)
                    f.id = rf.id
                    f.createdAt = rf.createdAt
                    f.updatedAt = rf.updatedAt
                    f.deletedAt = rf.deletedAt
                    f.mediaRotationQuarterTurns = rf.mediaRotationQuarterTurns
                    f.readingOrder = rf.readingOrder ?? rf.createdAt.timeIntervalSinceReferenceDate
                    ctx.insert(f)
                }
            }

            // ----- Notes -----
            for rn in payload.notes {
                let nid = rn.id
                let fetch = FetchDescriptor<PLNote>(predicate: #Predicate { $0.id == nid })
                let existing = (try? ctx.fetch(fetch))?.first

                if let n = existing {
                    let hasLocalChanges = hasLocalPendingUpload(
                        entityType: "note",
                        entityID: rn.id.uuidString,
                        ctx: ctx
                    )
                    guard !hasLocalChanges else { continue }

                    await downloadFileIfNeeded(filename: rn.photoFilename, client: client)
                    await downloadFileIfNeeded(filename: rn.inkDrawingFilename, client: client)
                    await downloadFileIfNeeded(filename: rn.highlightDrawingFilename, client: client)

                    if rn.updatedAt > n.updatedAt
                        || (rn.updatedAt == n.updatedAt && shouldApplyRemoteNote(rn, to: n)) {
                        applyRemoteNote(rn, to: n)
                    }
                } else {
                    await downloadFileIfNeeded(filename: rn.photoFilename, client: client)
                    await downloadFileIfNeeded(filename: rn.inkDrawingFilename, client: client)
                    await downloadFileIfNeeded(filename: rn.highlightDrawingFilename, client: client)

                    let n = PLNote(
                        title: rn.title,
                        kind: PLNoteKind(rawValue: rn.kindRaw) ?? .text,
                        folderID: rn.folderID
                    )
                    n.id = rn.id
                    n.createdAt = rn.createdAt
                    n.updatedAt = rn.updatedAt
                    n.pinned = rn.pinned
                    n.deletedAt = rn.deletedAt
                    n.mediaRotationQuarterTurns = rn.mediaRotationQuarterTurns
                    n.readingOrder = rn.readingOrder ?? rn.createdAt.timeIntervalSinceReferenceDate

                    n.textBody = rn.textBody
                    n.photoFilename = rn.photoFilename
                    n.inkDrawingFilename = rn.inkDrawingFilename
                    n.highlightDrawingFilename = rn.highlightDrawingFilename
                    n.drawingPaperStyleRaw = rn.drawingPaperStyleRaw ?? PLDrawingPaperStyle.lined.rawValue
                    n.drawingPenWidth = rn.drawingPenWidth ?? PLDrawingDefaults.penWidth
                    n.drawingMarkerWidth = rn.drawingMarkerWidth ?? PLDrawingDefaults.markerWidth
                    n.drawingLineSpacing = rn.drawingLineSpacing ?? PLDrawingDefaults.lineSpacing
                    n.drawingDotSpacing = rn.drawingDotSpacing ?? PLDrawingDefaults.dotSpacing
                    n.drawingDotSize = rn.drawingDotSize ?? PLDrawingDefaults.dotSize

                    ctx.insert(n)
                }
            }

            try? ctx.save()
            if let serverTime = payload.serverTime {
                if let lastSuccessfulPullServerTime {
                    self.lastSuccessfulPullServerTime = max(lastSuccessfulPullServerTime, serverTime)
                } else {
                    self.lastSuccessfulPullServerTime = serverTime
                }
            }
            return payload
        } catch {
            print("syncDownFromServer failed:", error)
            return nil
        }
    }

    private func applyRemotePurges(_ payload: FullSyncPayload, ctx: ModelContext) {
        let purgedNoteIDs = Set(payload.purgedNotes.map(\.id))
        let purgedFolderIDs = Set(payload.purgedFolders.map(\.id))
        guard !purgedNoteIDs.isEmpty || !purgedFolderIDs.isEmpty else { return }

        if let localNotes = try? ctx.fetch(FetchDescriptor<PLNote>()) {
            for note in localNotes where purgedNoteIDs.contains(note.id) {
                purgeLocalFiles(for: note)
                ctx.delete(note)
            }
        }

        if let localFolders = try? ctx.fetch(FetchDescriptor<PLFolder>()) {
            for folder in localFolders where purgedFolderIDs.contains(folder.id) {
                ctx.delete(folder)
            }
        }

        clearQueueItems(
            entityType: "note",
            entityIDs: Set(purgedNoteIDs.map(\.uuidString)),
            ctx: ctx
        )
        clearQueueItems(
            entityType: "folder",
            entityIDs: Set(purgedFolderIDs.map(\.uuidString)),
            ctx: ctx
        )
    }

    private func purgeLocalFiles(for note: PLNote) {
        if let filename = normalizedFilename(note.photoFilename) {
            FileStore.shared.delete(filename: filename)
        }
        if let filename = normalizedFilename(note.inkDrawingFilename) {
            FileStore.shared.delete(filename: filename)
        }
        if let filename = normalizedFilename(note.highlightDrawingFilename) {
            FileStore.shared.delete(filename: filename)
        }
    }

    private func downloadFileIfNeeded(filename: String?, client: PaperLinkSyncClient) async {
        guard let filename, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if FileStore.shared.fileExists(filename) { return }

        do {
            let data = try await client.downloadFile(filename: filename)
            FileStore.shared.writeDataExact(data, filename: filename) // ✅ preserve filename
        } catch {
            print("file download failed:", filename, error)
        }
    }

    private func shouldApplyRemoteFolder(_ remote: RemoteFolder, to local: PLFolder) -> Bool {
        remote.name != local.name
        || remote.parentFolderID != local.parentFolderID
        || remote.deletedAt != local.deletedAt
        || remote.mediaRotationQuarterTurns != local.mediaRotationQuarterTurns
        || (remote.readingOrder != nil && remote.readingOrder != local.readingOrder)
        || remote.createdAt != local.createdAt
        || remote.updatedAt != local.updatedAt
    }

    private func applyRemoteFolder(_ remote: RemoteFolder, to local: PLFolder) {
        local.name = remote.name
        local.parentFolderID = remote.parentFolderID
        local.deletedAt = remote.deletedAt
        local.mediaRotationQuarterTurns = remote.mediaRotationQuarterTurns
        if let readingOrder = remote.readingOrder {
            local.readingOrder = readingOrder
        }
        local.createdAt = remote.createdAt
        local.updatedAt = remote.updatedAt
    }

    private func shouldApplyRemoteNote(_ remote: RemoteNote, to local: PLNote) -> Bool {
        remote.title != local.title
        || remote.kindRaw != local.kindRaw
        || remote.folderID != local.folderID
        || remote.pinned != local.pinned
        || remote.deletedAt != local.deletedAt
        || remote.mediaRotationQuarterTurns != local.mediaRotationQuarterTurns
        || (remote.readingOrder != nil && remote.readingOrder != local.readingOrder)
        || remote.textBody != local.textBody
        || remote.photoFilename != local.photoFilename
        || remote.inkDrawingFilename != local.inkDrawingFilename
        || remote.highlightDrawingFilename != local.highlightDrawingFilename
        || (remote.drawingPaperStyleRaw != nil && remote.drawingPaperStyleRaw != local.drawingPaperStyleRaw)
        || (remote.drawingPenWidth != nil && remote.drawingPenWidth != local.drawingPenWidth)
        || (remote.drawingMarkerWidth != nil && remote.drawingMarkerWidth != local.drawingMarkerWidth)
        || (remote.drawingLineSpacing != nil && remote.drawingLineSpacing != local.drawingLineSpacing)
        || (remote.drawingDotSpacing != nil && remote.drawingDotSpacing != local.drawingDotSpacing)
        || (remote.drawingDotSize != nil && remote.drawingDotSize != local.drawingDotSize)
        || remote.createdAt != local.createdAt
        || remote.updatedAt != local.updatedAt
    }

    private func applyRemoteNote(_ remote: RemoteNote, to local: PLNote) {
        local.title = remote.title
        local.kindRaw = remote.kindRaw
        local.folderID = remote.folderID
        local.pinned = remote.pinned
        local.deletedAt = remote.deletedAt
        local.mediaRotationQuarterTurns = remote.mediaRotationQuarterTurns
        if let readingOrder = remote.readingOrder {
            local.readingOrder = readingOrder
        }
        local.textBody = remote.textBody
        local.photoFilename = remote.photoFilename
        local.inkDrawingFilename = remote.inkDrawingFilename
        local.highlightDrawingFilename = remote.highlightDrawingFilename
        if let drawingPaperStyleRaw = remote.drawingPaperStyleRaw {
            local.drawingPaperStyleRaw = drawingPaperStyleRaw
        }
        if let drawingPenWidth = remote.drawingPenWidth {
            local.drawingPenWidth = drawingPenWidth
        }
        if let drawingMarkerWidth = remote.drawingMarkerWidth {
            local.drawingMarkerWidth = drawingMarkerWidth
        }
        if let drawingLineSpacing = remote.drawingLineSpacing {
            local.drawingLineSpacing = drawingLineSpacing
        }
        if let drawingDotSpacing = remote.drawingDotSpacing {
            local.drawingDotSpacing = drawingDotSpacing
        }
        if let drawingDotSize = remote.drawingDotSize {
            local.drawingDotSize = drawingDotSize
        }
        local.createdAt = remote.createdAt
        local.updatedAt = remote.updatedAt
    }

    private func reconcileLocalStateAgainstRemote(_ payload: FullSyncPayload, ctx: ModelContext) -> Bool {
        let remoteFoldersByID = Dictionary(uniqueKeysWithValues: payload.folders.map { ($0.id, $0) })
        let remoteNotesByID = Dictionary(uniqueKeysWithValues: payload.notes.map { ($0.id, $0) })
        var didQueueAnything = false

        if let localFolders = try? ctx.fetch(FetchDescriptor<PLFolder>()) {
            for folder in localFolders where shouldReuploadLocalFolder(folder, remote: remoteFoldersByID[folder.id]) {
                upsertQueueItem(entityType: "folder", entityID: folder.id.uuidString, ctx: ctx)
                didQueueAnything = true
            }
        }

        if let localNotes = try? ctx.fetch(FetchDescriptor<PLNote>()) {
            for note in localNotes where shouldReuploadLocalNote(note, remote: remoteNotesByID[note.id]) {
                upsertQueueItem(entityType: "note", entityID: note.id.uuidString, ctx: ctx)
                didQueueAnything = true
            }
        }

        return didQueueAnything
    }

    private func shouldReuploadLocalFolder(_ local: PLFolder, remote: RemoteFolder?) -> Bool {
        if let remote {
            return local.updatedAt > remote.updatedAt
        }

        return local.deletedAt == nil
    }

    private func shouldReuploadLocalNote(_ local: PLNote, remote: RemoteNote?) -> Bool {
        if let remote {
            if local.updatedAt > remote.updatedAt {
                return true
            }
            return hasRecoverableLocalFileDrift(local, remote: remote)
        }

        return local.deletedAt == nil
    }

    private func hasRecoverableLocalFileDrift(_ local: PLNote, remote: RemoteNote) -> Bool {
        hasRecoverableLocalFile(local.photoFilename, remoteFilename: remote.photoFilename)
        || hasRecoverableLocalFile(local.inkDrawingFilename, remoteFilename: remote.inkDrawingFilename)
        || hasRecoverableLocalFile(local.highlightDrawingFilename, remoteFilename: remote.highlightDrawingFilename)
    }

    private func hasRecoverableLocalFile(_ localFilename: String?, remoteFilename: String?) -> Bool {
        guard let localFilename = normalizedFilename(localFilename) else { return false }
        guard FileStore.shared.fileExists(localFilename) else { return false }
        return normalizedFilename(remoteFilename) != localFilename
    }

    private func normalizedFilename(_ filename: String?) -> String? {
        guard let filename else { return nil }
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clearQueueItems(entityType: String, entityIDs: Set<String>, ctx: ModelContext) {
        guard !entityIDs.isEmpty else { return }
        guard let queuedItems = try? ctx.fetch(FetchDescriptor<PLPendingUpload>()) else { return }

        for item in queuedItems where item.entityType == entityType && entityIDs.contains(item.entityID) {
            ctx.delete(item)
        }
    }

    private func nextQueuedUpload(ctx: ModelContext) -> PLPendingUpload? {
        let desc = FetchDescriptor<PLPendingUpload>(
            predicate: #Predicate { $0.stateRaw == "pending" || $0.stateRaw == "failed" },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return (try? ctx.fetch(desc))?.first
    }

    private func hasLocalPendingUpload(entityType: String, entityID: String, ctx: ModelContext) -> Bool {
        let desc = FetchDescriptor<PLPendingUpload>(
            predicate: #Predicate {
                $0.entityType == entityType
                && $0.entityID == entityID
                && ($0.stateRaw == "pending" || $0.stateRaw == "uploading" || $0.stateRaw == "failed")
            }
        )
        guard let items = try? ctx.fetch(desc) else { return false }
        return !items.isEmpty
    }

    private func upsertQueueItem(entityType: String, entityID: String, ctx: ModelContext) {
        let activeFetch = FetchDescriptor<PLPendingUpload>(
            predicate: #Predicate {
                $0.entityType == entityType
                && $0.entityID == entityID
                && ($0.stateRaw == "pending" || $0.stateRaw == "uploading" || $0.stateRaw == "failed")
            },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let active = (try? ctx.fetch(activeFetch)) ?? []

        if active.contains(where: { $0.stateRaw == "pending" }) {
            return
        }

        if let failed = active.first(where: { $0.stateRaw == "failed" }) {
            failed.state = .pending
            failed.lastError = nil
            failed.createdAt = .now
            try? ctx.save()
            return
        }

        if active.contains(where: { $0.stateRaw == "uploading" }) {
            let item = PLPendingUpload(entityType: entityType, entityID: entityID)
            ctx.insert(item)
            try? ctx.save()
            return
        }

        let doneFetch = FetchDescriptor<PLPendingUpload>(
            predicate: #Predicate {
                $0.entityType == entityType
                && $0.entityID == entityID
                && $0.stateRaw == "done"
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let done = (try? ctx.fetch(doneFetch))?.first {
            done.state = .pending
            done.lastError = nil
            done.createdAt = .now
            try? ctx.save()
            return
        }

        let item = PLPendingUpload(entityType: entityType, entityID: entityID)
        ctx.insert(item)
        try? ctx.save()
    }

    private func pruneCompletedQueue(ctx: ModelContext) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let desc = FetchDescriptor<PLPendingUpload>(
            predicate: #Predicate { $0.stateRaw == "done" && $0.createdAt < cutoff }
        )
        guard let staleItems = try? ctx.fetch(desc), !staleItems.isEmpty else { return }

        for item in staleItems {
            ctx.delete(item)
        }
        try? ctx.save()
    }

    private func scheduleSyncKick(ctx: ModelContext) {
        scheduledKickTask?.cancel()
        scheduledKickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            await self.runSyncCycle(ctx: ctx, allowUpload: true)
        }
    }

    private func enqueueFolderIfNeeded(folderID: UUID, ctx: ModelContext) {
        upsertQueueItem(entityType: "folder", entityID: folderID.uuidString, ctx: ctx)
    }

    private func withRetry<T>(
        attempts: Int = 3,
        delayNanoseconds: UInt64 = 500_000_000,
        operation: () async throws -> T
    ) async throws -> T {
        var remaining = max(attempts, 1)
        while true {
            do {
                return try await operation()
            } catch {
                remaining -= 1
                guard remaining > 0, isRetryable(error) else { throw error }
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let syncError = error as? PaperLinkSyncClient.SyncError {
            switch syncError {
            case .network(_):
                return true
            case .server(let msg):
                return msg.contains(" 429 ")
                || msg.contains(" 500 ")
                || msg.contains(" 502 ")
                || msg.contains(" 503 ")
                || msg.contains(" 504 ")
            case .conflict(_), .notSignedIn, .missingToken, .badURL, .badResponse, .missingLocalFile(_):
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .notConnectedToInternet, .networkConnectionLost,
                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        return false
    }

    enum SyncErr: Error { case badID, missingEntity, unknownType }
}
