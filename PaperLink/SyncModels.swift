//
//  FullSyncPayload.swift
//  PaperLink
//
//  Created by Ben Chen on 2/16/26.
//


import Foundation

struct FullSyncPayload: Codable {
    var folders: [RemoteFolder]
    var notes: [RemoteNote]
    var purgedFolders: [RemotePurgedEntity]
    var purgedNotes: [RemotePurgedEntity]
    var serverTime: Date?

    enum CodingKeys: String, CodingKey {
        case folders
        case notes
        case purgedFolders
        case purgedNotes
        case serverTime
    }

    init(
        folders: [RemoteFolder] = [],
        notes: [RemoteNote] = [],
        purgedFolders: [RemotePurgedEntity] = [],
        purgedNotes: [RemotePurgedEntity] = [],
        serverTime: Date? = nil
    ) {
        self.folders = folders
        self.notes = notes
        self.purgedFolders = purgedFolders
        self.purgedNotes = purgedNotes
        self.serverTime = serverTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([RemoteFolder].self, forKey: .folders) ?? []
        notes = try container.decodeIfPresent([RemoteNote].self, forKey: .notes) ?? []
        purgedFolders = try container.decodeIfPresent([RemotePurgedEntity].self, forKey: .purgedFolders) ?? []
        purgedNotes = try container.decodeIfPresent([RemotePurgedEntity].self, forKey: .purgedNotes) ?? []
        serverTime = try container.decodeIfPresent(Date.self, forKey: .serverTime)
    }
}

struct RemoteFolder: Codable {
    var id: UUID
    var name: String
    var parentFolderID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var mediaRotationQuarterTurns: Int16
    var readingOrder: Double?
}

struct RemoteNote: Codable {
    var id: UUID
    var title: String
    var kindRaw: String
    var folderID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var pinned: Bool
    var mediaRotationQuarterTurns: Int16?
    var readingOrder: Double?

    var textBody: String?
    var photoFilename: String?
    var inkDrawingFilename: String?
    var highlightDrawingFilename: String?
    var drawingPaperStyleRaw: String?
    var drawingPenWidth: Double?
    var drawingMarkerWidth: Double?
    var drawingLineSpacing: Double?
    var drawingDotSpacing: Double?
    var drawingDotSize: Double?
}

struct RemotePurgedEntity: Codable {
    var id: UUID
    var purgedAt: Date
}

struct RemoteUsageStats: Codable {
    var storageBytes: Int64
    var noteCounts: RemoteUsageNoteCounts
}

struct RemoteUsageNoteCounts: Codable {
    var text: Int
    var drawing: Int
    var photo: Int
    var all: Int
}
