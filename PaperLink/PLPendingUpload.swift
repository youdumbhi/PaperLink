import Foundation
import SwiftData

@Model
final class PLPendingUpload {
    @Attribute(.unique) var id: UUID

    /// "note" or "folder"
    var entityType: String

    /// UUID string for entity id
    var entityID: String

    /// "create_or_upsert" for now
    var op: String

    var createdAt: Date

    /// "pending", "uploading", "done", "failed"
    var stateRaw: String
    var lastError: String?

    init(entityType: String, entityID: String, op: String = "create_or_upsert") {
        self.id = UUID()
        self.entityType = entityType
        self.entityID = entityID
        self.op = op
        self.createdAt = .now
        self.stateRaw = "pending"
        self.lastError = nil
    }

    enum State: String { case pending, uploading, done, failed }

    var state: State {
        get { State(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}
