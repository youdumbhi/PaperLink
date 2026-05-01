import Foundation
import FirebaseAuth

final class PaperLinkSyncClient {
    struct Config {
        let baseURL: URL

        /// Optional: If you protect the tunnel with Cloudflare Access "Service Auth",
        /// set these (Client ID + Secret) and they’ll be attached to every request.
        let cloudflareAccessClientId: String?
        let cloudflareAccessClientSecret: String?

        init(baseURL: URL,
             cloudflareAccessClientId: String? = nil,
             cloudflareAccessClientSecret: String? = nil) {
            self.baseURL = baseURL
            self.cloudflareAccessClientId = cloudflareAccessClientId
            self.cloudflareAccessClientSecret = cloudflareAccessClientSecret
        }
    }

    private let config: Config
    private let session: URLSession

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Folder upsert
    func uploadUpsertFolder(folder: PLFolder) async throws {
        let token = try await fetchIDToken()
        let url = endpoint("v1/folders/upsert")

        let payload: [String: Any] = [
            "id": folder.id.uuidString,
            "name": folder.name,
            "createdAt": folder.createdAt.iso8601String(),
            "updatedAt": folder.updatedAt.iso8601String(),
            "parentFolderID": folder.parentFolderID?.uuidString as Any,
            "deletedAt": folder.deletedAt?.iso8601String() as Any,
            "mediaRotationQuarterTurns": Int(folder.mediaRotationQuarterTurns),
            "readingOrder": folder.readingOrder
        ]

        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let (body, boundary) = MultipartFormData.build(
            fields: [("payload", payloadData, "application/json")],
            files: []
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        attachAuthHeaders(&req, token: token)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60

        _ = try await perform(req, label: "uploadUpsertFolder")
    }

    // MARK: - Note create/upsert (metadata + optional blobs)
    func uploadCreateNote(note: PLNote) async throws {
        let token = try await fetchIDToken()
        let url = endpoint("v1/notes/create")

        let payload: [String: Any] = [
            "id": note.id.uuidString,
            "title": note.title,
            "kindRaw": note.kindRaw,
            "createdAt": note.createdAt.iso8601String(),
            "updatedAt": note.updatedAt.iso8601String(),
            "pinned": note.pinned,
            "textBody": note.textBody as Any,
            "photoFilename": note.photoFilename as Any,
            "inkDrawingFilename": note.inkDrawingFilename as Any,
            "highlightDrawingFilename": note.highlightDrawingFilename as Any,
            "drawingPaperStyleRaw": note.drawingPaperStyleRaw as Any,
            "drawingPenWidth": note.drawingPenWidth,
            "drawingMarkerWidth": note.drawingMarkerWidth,
            "drawingLineSpacing": note.drawingLineSpacing,
            "drawingDotSpacing": note.drawingDotSpacing,
            "drawingDotSize": note.drawingDotSize,
            "folderID": note.folderID?.uuidString as Any,
            "deletedAt": note.deletedAt?.iso8601String() as Any,
            "mediaRotationQuarterTurns": note.mediaRotationQuarterTurns as Any,
            "readingOrder": note.readingOrder
        ]

        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let allowMissingFiles = note.deletedAt != nil
        var files: [(field: String, filename: String, mime: String, data: Data)] = []

        if let photo = try uploadFile(
            filename: note.photoFilename,
            field: "photo",
            mime: "image/jpeg",
            allowMissing: allowMissingFiles
        ) {
            files.append(photo)
        }
        if let ink = try uploadFile(
            filename: note.inkDrawingFilename,
            field: "ink",
            mime: "application/octet-stream",
            allowMissing: allowMissingFiles
        ) {
            files.append(ink)
        }
        if let highlight = try uploadFile(
            filename: note.highlightDrawingFilename,
            field: "highlight",
            mime: "application/octet-stream",
            allowMissing: allowMissingFiles
        ) {
            files.append(highlight)
        }

        let (body, boundary) = MultipartFormData.build(
            fields: [("payload", payloadData, "application/json")],
            files: files
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        attachAuthHeaders(&req, token: token)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60

        _ = try await perform(req, label: "uploadCreateNote")
    }

    // MARK: - Full sync (pull)
    func fetchFullSync() async throws -> FullSyncPayload {
        let token = try await fetchIDToken()
        let url = endpoint("v1/sync/full")

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        attachAuthHeaders(&req, token: token)
        req.timeoutInterval = 60

        let data = try await perform(req, label: "fetchFullSync")
        return try Self.makeSyncDecoder().decode(FullSyncPayload.self, from: data)
    }

    func fetchSyncPull(since: Date?) async throws -> FullSyncPayload {
        let token = try await fetchIDToken()

        var comps = URLComponents(url: endpoint("v1/sync/pull"), resolvingAgainstBaseURL: false)
        if let since {
            comps?.queryItems = [URLQueryItem(name: "since", value: since.iso8601String())]
        }
        guard let url = comps?.url else { throw SyncError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        attachAuthHeaders(&req, token: token)
        req.timeoutInterval = 60

        let data = try await perform(req, label: "fetchSyncPull")
        return try Self.makeSyncDecoder().decode(FullSyncPayload.self, from: data)
    }

    func emptyTrash() async throws {
        let token = try await fetchIDToken()
        let url = endpoint("v1/trash/empty")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        attachAuthHeaders(&req, token: token)
        req.timeoutInterval = 60

        _ = try await perform(req, label: "emptyTrash")
    }

    // MARK: - Download file by filename
    func downloadFile(filename: String) async throws -> Data {
        let token = try await fetchIDToken()

        var comps = URLComponents(url: endpoint("v1/files/get"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = comps?.url else { throw SyncError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        attachAuthHeaders(&req, token: token)
        req.timeoutInterval = 60

        return try await perform(req, label: "downloadFile")
    }

    // MARK: - Usage stats
    func fetchUsageStats() async throws -> RemoteUsageStats {
        let token = try await fetchIDToken()
        let url = endpoint("v1/stats/usage")

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        attachAuthHeaders(&req, token: token)
        req.timeoutInterval = 30

        let data = try await perform(req, label: "fetchUsageStats")
        return try JSONDecoder().decode(RemoteUsageStats.self, from: data)
    }

    // MARK: - Internals

    private func endpoint(_ path: String) -> URL {
        // Ensures baseURL works with or without trailing slash and avoids double-slashes.
        var base = config.baseURL
        if base.path.isEmpty { base.appendPathComponent("") } // keeps URL well-formed
        return base.appendingPathComponent(path)
    }

    private func attachAuthHeaders(_ req: inout URLRequest, token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // Optional Cloudflare Access Service Auth
        if let id = config.cloudflareAccessClientId,
           let secret = config.cloudflareAccessClientSecret {
            req.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }

    private func uploadFile(
        filename: String?,
        field: String,
        mime: String,
        allowMissing: Bool
    ) throws -> (field: String, filename: String, mime: String, data: Data)? {
        guard let filename = normalizedFilename(filename) else { return nil }
        guard let data = FileStore.shared.readData(filename: filename) else {
            if allowMissing {
                return nil
            }
            throw SyncError.missingLocalFile(filename)
        }
        return (field: field, filename: filename, mime: mime, data: data)
    }

    private func normalizedFilename(_ filename: String?) -> String? {
        guard let filename else { return nil }
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func perform(_ req: URLRequest, label: String) async throws -> Data {
        log("[\(label)] \(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "<nil>")")

        do {
            let (data, resp) = try await session.data(for: req)
            try Self.require2xx(resp: resp, data: data, label: label, url: req.url)
            logResponse(label: label, resp: resp, data: data)
            return data
        } catch let syncError as SyncError {
            log("[\(label)] ERROR: \(String(describing: syncError))")
            throw syncError
        } catch {
            // Make networking failures obvious.
            log("[\(label)] ERROR: \(String(describing: error))")
            throw SyncError.network(error.localizedDescription)
        }
    }

    private func logResponse(label: String, resp: URLResponse, data: Data) {
        guard let http = resp as? HTTPURLResponse else {
            log("[\(label)] Non-HTTP response")
            return
        }
        let preview = String(data: data.prefix(4096), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        log("[\(label)] HTTP \(http.statusCode) (\(data.count) bytes) bodyPreview=\(preview)")
    }

    private func log(_ s: String) {
        #if DEBUG
        print("🛰️ PaperLinkSyncClient \(s)")
        #endif
    }

    // MARK: - Firebase token
    private func fetchIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else { throw SyncError.notSignedIn }
        return try await withCheckedThrowingContinuation { cont in
            user.getIDTokenForcingRefresh(false) { token, err in
                if let err { cont.resume(throwing: err); return }
                guard let token, !token.isEmpty else { cont.resume(throwing: SyncError.missingToken); return }
                cont.resume(returning: token)
            }
        }
    }

    private static func require2xx(resp: URLResponse, data: Data, label: String, url: URL?) throws {
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badResponse }

        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"

            if http.statusCode == 409 {
                throw SyncError.conflict("[\(label)] \(http.statusCode) \(url?.absoluteString ?? "") :: \(msg)")
            }

            throw SyncError.server("[\(label)] \(http.statusCode) \(url?.absoluteString ?? "") :: \(msg)")
        }
    }

    private static func makeSyncDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = iso8601FractionalSecondsFormatter.date(from: value)
                ?? iso8601Formatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO8601 date with or without fractional seconds."
            )
        }
        return dec
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601FractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    enum SyncError: Error {
        case notSignedIn
        case missingToken
        case badURL
        case badResponse
        case conflict(String)
        case server(String)
        case network(String)
        case missingLocalFile(String)
    }
}

// MARK: - Multipart helper
private enum MultipartFormData {
    static func build(
        fields: [(name: String, data: Data, mime: String)],
        files: [(field: String, filename: String, mime: String, data: Data)]
    ) -> (Data, String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        for f in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(f.name)\"\r\n")
            append("Content-Type: \(f.mime)\r\n\r\n")
            body.append(f.data)
            append("\r\n")
        }

        for file in files {
            let safeName = file.filename.replacingOccurrences(of: "\"", with: "")
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(safeName)\"\r\n")
            append("Content-Type: \(file.mime)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }

        append("--\(boundary)--\r\n")
        return (body, boundary)
    }
}

// MARK: - ISO helper
private extension Date {
    func iso8601String() -> String {
        Self.paperLinkISO8601Formatter.string(from: self)
    }

    static let paperLinkISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
