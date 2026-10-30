import Foundation
import CryptoKit

enum ImportStage: String, Codable {
    case queued, importing, imported, failed, needsReview
}

struct ImportEntry: Codable, Identifiable {
    var id = UUID()
    var sourcePath: String
    var title: String
    var date = Date()
    var stage: ImportStage = .queued
    var digest: String?
    var managedPath: String?
    var trackID: String?
    var cloudStatus: String?
    var isFavorite: Bool?
    var favoriteError: String?
    var cloudUpdateRequestedAt: Date?
    var cloudUpdateError: String?
    var cloudSyncPending: Bool?
    var cloudRetryAt: Date?
    var cloudRetryCount: Int?
    var cloudPermissionBlocked: Bool?
    var soundCloudID: String?
    var soundCloudURL: URL?
    var youtubeID: String?
    var youtubeURL: URL?
    var error: String?

    var cloudRetryMessage: String? {
        guard cloudSyncPending == true, CloudState.canAutoRetry(cloudStatus), cloudPermissionBlocked != true else { return nil }
        return cloudUpdateError == nil ? "Ждём загрузку в облако · автоматический повтор включён"
            : "Обновление облака в очереди · повторим автоматически"
    }
}

enum DropError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum FileTools {
    static func validate(_ url: URL, allowedExtensions: Set<String> = ["mp3"]) throws {
        guard url.isFileURL, allowedExtensions.contains(url.pathExtension.lowercased()) else {
            throw DropError.message("Не поддерживается формат аудиофайла.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw DropError.message("Файл пуст или недоступен. Загрузи его на Mac и попробуй снова.")
        }
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A persistent copy also protects tracks when Music's own copy setting is off.
    static func preserve(_ source: URL, digest: String, directory: URL) throws -> URL {
        let fm = FileManager.default
        let trackDirectory = directory.appendingPathComponent(digest, isDirectory: true)
        try fm.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
        let destination = trackDirectory.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: destination.path) { return destination }
        let temporary = trackDirectory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        // The source may have changed while we copied it.
        guard try self.digest(temporary) == digest else {
            throw DropError.message("Файл изменился во время копирования. Попробуй ещё раз.")
        }
        try fm.moveItem(at: temporary, to: destination)
        return destination
    }

    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

enum CloudState {
    static func canAutoRetry(_ status: String?) -> Bool {
        !isReady(status) && !["ineligible", "duplicate", "removed", "missing", "no longer available"].contains(status ?? "")
    }

    static func retryDelay(attempt: Int, commandAccepted: Bool) -> TimeInterval {
        // A successful request needs time to upload. A busy menu can be retried sooner.
        let base: Double = commandAccepted ? 60 : 15
        return min(300, base * pow(2, Double(min(5, max(0, attempt - 1)))))
    }

    static func label(_ status: String?) -> String {
        switch status {
        case "uploaded": return "Загружено в облако"
        case "matched": return "Сопоставлено · доступно в облаке"
        case "purchased", "subscription": return "Доступно в облаке"
        case "ineligible": return "На Mac · не подходит для облака"
        case "error": return "На Mac · ошибка синхронизации"
        case "duplicate": return "На Mac · дубликат в облаке"
        case "removed": return "На Mac · удалено из облака"
        case "no longer available": return "На Mac · недоступно в облаке"
        case "not uploaded", "prerelease": return "На Mac · ожидает синхронизации"
        default: return "Добавлено на Mac · облако не подтверждено"
        }
    }

    static func isReady(_ status: String?) -> Bool {
        ["uploaded", "matched", "purchased", "subscription"].contains(status ?? "")
    }

    static func isWarning(_ status: String?) -> Bool {
        ["ineligible", "error", "duplicate", "removed", "no longer available"].contains(status ?? "")
    }
}
