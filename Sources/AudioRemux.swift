import AVFoundation

/// Rewraps AAC audio into a regular .m4a with Apple's own framework, so the common
/// SoundCloud and YouTube formats need no FFmpeg. Nothing is re-encoded.
enum AudioRemux {
    static func m4a(from source: URL, to output: URL, tags: AudioTags, cancellation: SoundCloudCancellation) throws {
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw DropError.message("AVFoundation не может перепаковать это аудио.")
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .m4a
        var metadata = [
            item(.commonIdentifierTitle, tags.title),
            item(.commonIdentifierArtist, tags.artist),
            item(.commonIdentifierAlbumName, tags.album),
            item(.iTunesMetadataUserComment, tags.comment)
        ]
        if let genre = tags.genre?.nonEmpty { metadata.append(item(.iTunesMetadataUserGenre, genre)) }
        if let year = tags.year { metadata.append(item(.iTunesMetadataReleaseDate, String(year))) }
        if let artwork = tags.artwork {
            let cover = AVMutableMetadataItem()
            cover.identifier = .iTunesMetadataCoverArt
            cover.value = artwork as NSData
            cover.dataType = kCMMetadataBaseDataType_JPEG as String
            metadata.append(cover)
        }
        session.metadata = metadata
        let finished = DispatchSemaphore(value: 0)
        session.exportAsynchronously { finished.signal() }
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled { session.cancelExport() }
        }
        if cancellation.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw SoundCloudError.cancelled
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw DropError.message("AVFoundation не смог перепаковать аудио: " + (session.error?.localizedDescription ?? "неизвестная ошибка"))
        }
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}
