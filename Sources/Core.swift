import Foundation
import CryptoKit

enum ImportStage: String, Codable {
    case queued, importing, imported, failed, needsReview
}

struct ImportEntry: Codable, Identifiable, Equatable {
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
    /// The playlist the track goes into after the import; nil keeps it in the library only.
    var playlist: String?
    var playlistError: String?
    var error: String?

    var cloudRetryMessage: String? {
        guard cloudSyncPending == true, CloudState.canAutoRetry(cloudStatus), cloudPermissionBlocked != true else { return nil }
        return cloudUpdateError == nil ? "Ждём загрузку в облако · автоматический повтор включён"
            : "Обновление облака в очереди · повторим автоматически"
    }
}

/// Tags written into prepared audio files.
struct AudioTags {
    let title: String
    let artist: String
    let album: String
    let comment: String
    var genre: String?
    var year: Int?
    /// Square JPEG cover art.
    var artwork: Data?

    /// FFmpeg options for these tags. With `cover` (the file of input #1) the picture is attached as album art.
    func ffmpegArguments(cover: URL?) -> (inputs: [String], outputs: [String]) {
        var outputs = ["-metadata", "title=" + title, "-metadata", "artist=" + artist,
                       "-metadata", "album=" + album, "-metadata", "comment=" + comment]
        if let genre = genre?.nonEmpty { outputs += ["-metadata", "genre=" + genre] }
        if let year { outputs += ["-metadata", "date=" + String(year)] }
        guard let cover else { return ([], ["-vn"] + outputs) }
        return (["-i", cover.path], ["-map", "1:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"] + outputs)
    }

    /// Writes the artwork next to the audio for FFmpeg, which reads it as a second input.
    func coverFile(in directory: URL) -> URL? {
        guard let artwork else { return nil }
        let url = directory.appendingPathComponent("cover.jpg")
        return (try? artwork.write(to: url)) == nil ? nil : url
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
    /// `moving` is for Music Drop's own finished downloads: a rename is instant and nothing else writes them.
    static func preserve(_ source: URL, digest: String, directory: URL, moving: Bool = false) throws -> URL {
        let fm = FileManager.default
        let trackDirectory = directory.appendingPathComponent(digest, isDirectory: true)
        try fm.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
        let destination = trackDirectory.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            if moving { try? fm.removeItem(at: source) }
            return destination
        }
        if moving {
            try fm.moveItem(at: source, to: destination)
            return destination
        }
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

    /// FFmpeg is optional: AAC audio is rewrapped by AVFoundation, FFmpeg covers MP3 and rarer formats.
    /// An explicit path is used only when it is executable.
    static func ffmpeg(_ explicit: URL? = nil) -> URL? {
        let candidates = explicit.map { [$0] }
            ?? ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// True when the file starts like an ISO media file (MP4, M4A or joined fMP4 segments).
    static func isMP4(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12 else { return false }
        return head[4..<8].elementsEqual("ftyp".utf8) || head[4..<8].elementsEqual("styp".utf8)
    }

    /// yt-dlp ships unpacked, so it starts without extracting itself to a temporary folder on every run.
    /// A single-file build from an older installer is still accepted.
    static func extractor(in resources: URL) -> URL {
        let folder = resources.appendingPathComponent("Helpers/yt-dlp", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return URL(fileURLWithPath: folder.path)
        }
        return folder.appendingPathComponent("yt-dlp_macos")
    }

    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// Follows yt-dlp's machine-readable progress lines while it writes them to its log files.
final class ProgressTail {
    static let arguments = ["--progress", "--newline", "--progress-template",
                            "download:MDPROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s"]
    private let files: [URL]
    private var offsets: [URL: UInt64] = [:]
    private let report: (Double) -> Void

    init(files: [URL], report: @escaping (Double) -> Void) {
        self.files = files
        self.report = report
    }

    /// Reads only complete new lines and reports the newest fraction.
    func poll() {
        var latest: Double?
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let offset = offsets[file] ?? 0
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty,
                  let end = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let complete = data[data.startIndex...end]
            offsets[file] = offset + UInt64(complete.count)
            for line in String(decoding: complete, as: UTF8.self).split(whereSeparator: \.isNewline) {
                if let value = Self.fraction(line) { latest = value }
            }
        }
        if let latest { report(latest) }
    }

    static func fraction(_ line: Substring) -> Double? {
        let parts = line.split(separator: " ")
        guard let marker = parts.firstIndex(of: "MDPROGRESS"), parts.count > marker + 2,
              let done = Double(parts[marker + 1]), let total = Double(parts[marker + 2]), total > 0 else { return nil }
        return min(1, max(0, done / total))
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
