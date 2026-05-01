import Foundation

final class FileStore {
    static let shared = FileStore()
    private init() {}

    // MARK: - Base Directory

    private var baseURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperlinkFiles", isDirectory: true)
    }

    func ensureBaseDir() {
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
    }

    // MARK: - Write (new unique filename)

    /// Writes `data` to a new unique filename. Returns the stored filename.
    func writeData(_ data: Data, preferredName: String) -> String? {
        ensureBaseDir()

        let safePreferred = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = safePreferred.isEmpty ? "file.bin" : safePreferred

        let filename = "\(UUID().uuidString)-\(suffix)"
        let url = baseURL.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: [.atomic])
            return filename
        } catch {
            print("File write error:", error)
            return nil
        }
    }

    /// ✅ Save data to an EXACT filename (no UUID prefix). Used for server restore.
    func writeDataExact(_ data: Data, filename: String) {
        ensureBaseDir()

        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url = baseURL.appendingPathComponent(trimmed)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            print("File write exact error:", error)
        }
    }

    /// Overwrites an existing stored filename.
    func overwriteData(_ data: Data, filename: String) {
        ensureBaseDir()

        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url = baseURL.appendingPathComponent(trimmed)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            print("File overwrite error:", error)
        }
    }

    // MARK: - Read

    func readData(filename: String) -> Data? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        ensureBaseDir()
        let url = baseURL.appendingPathComponent(trimmed)
        return try? Data(contentsOf: url)
    }

    // MARK: - Delete

    func delete(filename: String) {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        ensureBaseDir()
        let url = baseURL.appendingPathComponent(trimmed)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - URL helper

    func fileURL(_ filename: String) -> URL? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        ensureBaseDir()
        return baseURL.appendingPathComponent(trimmed)
    }

    func fileExists(_ filename: String) -> Bool {
        guard let url = fileURL(filename) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
