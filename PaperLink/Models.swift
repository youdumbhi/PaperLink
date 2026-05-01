import Foundation
import SwiftData

enum PLNoteKind: String, Codable, CaseIterable {
    case text
    case photo
    case drawing
}

enum PLDrawingPaperStyle: String, Codable, CaseIterable {
    case lined
    case dotGrid
    case blank
}

enum PLDrawingDefaults {
    static let paperStyleRaw = PLDrawingPaperStyle.lined.rawValue
    static let penWidth: Double = 6
    static let markerWidth: Double = 18
    static let lineSpacing: Double = 30
    static let dotSpacing: Double = 28
    static let dotSize: Double = 2

    enum Key {
        static let paperStyleRaw = "pl_default_drawing_paper_style"
        static let penWidth = "pl_default_pen_width"
        static let markerWidth = "pl_default_marker_width"
        static let lineSpacing = "pl_default_line_spacing"
        static let dotSpacing = "pl_default_dot_spacing"
        static let dotSize = "pl_default_dot_size"
    }
}

enum PLDrawingPaletteDefaults {
    static let autoMinimize = true

    enum Key {
        static let autoMinimize = "pl_drawing_palette_auto_minimize"
    }
}

enum PLTextDefaults {
    static let fontSize: Double = 18

    enum Key {
        static let fontSize = "pl_default_text_font_size"
    }
}

@Model
final class PLFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    // Instead of @Relationship
    var parentFolderID: UUID?

    // Recently Deleted support
    var deletedAt: Date?

    // NEW: Media rotation for whole folder (quarter-turns: 0,1,2,3)
    // Applies to photo + drawing notes in this folder (not text)
    // Default at declaration so SwiftData migration can populate existing rows.
    var mediaRotationQuarterTurns: Int16 = 0

    // Reading order inside the parent container.
    var readingOrder: Double = 0

    init(name: String, parentFolderID: UUID? = nil, readingOrder: Double? = nil) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.updatedAt = .now
        self.parentFolderID = parentFolderID
        self.deletedAt = nil

        self.mediaRotationQuarterTurns = 0
        self.readingOrder = readingOrder ?? self.createdAt.timeIntervalSinceReferenceDate
    }
}

@Model
final class PLNote {
    @Attribute(.unique) var id: UUID

    var title: String
    var kindRaw: String

    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool

    var textBody: String?
    var photoFilename: String?
    var inkDrawingFilename: String?
    var highlightDrawingFilename: String?

    // Instead of @Relationship
    var folderID: UUID?

    // Recently Deleted support
    var deletedAt: Date?

    // NEW: Optional per-note media rotation (quarter-turns: 0,1,2,3)
    // If nil, the folder rotation (if any) is used.
    var mediaRotationQuarterTurns: Int16?

    // Drawing paper style (lined / dot grid / blank).
    // Default at declaration so existing rows can migrate.
    var drawingPaperStyleRaw: String = PLDrawingPaperStyle.lined.rawValue
    var drawingPenWidth: Double = PLDrawingDefaults.penWidth
    var drawingMarkerWidth: Double = PLDrawingDefaults.markerWidth
    var drawingLineSpacing: Double = PLDrawingDefaults.lineSpacing
    var drawingDotSpacing: Double = PLDrawingDefaults.dotSpacing
    var drawingDotSize: Double = PLDrawingDefaults.dotSize

    // Reading order inside the containing folder/root.
    var readingOrder: Double = 0

    init(title: String, kind: PLNoteKind, folderID: UUID? = nil, readingOrder: Double? = nil) {
        self.id = UUID()
        self.title = title
        self.kindRaw = kind.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.pinned = false

        self.textBody = nil
        self.photoFilename = nil
        self.inkDrawingFilename = nil
        self.highlightDrawingFilename = nil

        self.folderID = folderID
        self.deletedAt = nil

        self.mediaRotationQuarterTurns = nil
        self.drawingPaperStyleRaw = PLDrawingPaperStyle.lined.rawValue
        self.drawingPenWidth = PLDrawingDefaults.penWidth
        self.drawingMarkerWidth = PLDrawingDefaults.markerWidth
        self.drawingLineSpacing = PLDrawingDefaults.lineSpacing
        self.drawingDotSpacing = PLDrawingDefaults.dotSpacing
        self.drawingDotSize = PLDrawingDefaults.dotSize
        self.readingOrder = readingOrder ?? self.createdAt.timeIntervalSinceReferenceDate
    }

    var kind: PLNoteKind {
        get { PLNoteKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var drawingPaperStyle: PLDrawingPaperStyle {
        get { PLDrawingPaperStyle(rawValue: drawingPaperStyleRaw) ?? .lined }
        set { drawingPaperStyleRaw = newValue.rawValue }
    }
}
