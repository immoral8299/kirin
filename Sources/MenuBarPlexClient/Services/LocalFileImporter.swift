import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum LocalFileImporter {
    static let audioExtensions: Set<String> = [
        "mp3", "flac", "wav", "aac", "m4a", "m4b", "m4p",
        "ogg", "oga", "opus", "wma", "alac", "aiff", "aif",
        "dsf", "dff", "wv", "ape"
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "tif", "tiff", "bmp",
        "gif", "heic", "heif"
    ]
    private static let preferredFolderArtworkNames = ["cover", "folder", "front"]

    static func selectFilesAndFolders() async -> LocalFileImportResult {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose audio files or folders containing music"
        panel.prompt = "Choose"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return .empty }

        return await buildTracks(from: panel.urls)
    }

    static func buildTracks(from urls: [URL]) async -> LocalFileImportResult {
        var audioFiles: [LocalAudioFile] = []
        var unsupportedCount = 0

        for url in urls {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if resourceValues?.isDirectory == true || url.hasDirectoryPath {
                let collected = collectAudioFiles(in: url)
                audioFiles.append(contentsOf: collected.files)
                unsupportedCount += collected.unsupportedCount
            } else if resourceValues?.isRegularFile != false {
                guard isSupportedAudioFile(url) else {
                    if !isSupportedImageFile(url) {
                        unsupportedCount += 1
                    }
                    continue
                }
                audioFiles.append(LocalAudioFile(url: url, folderArtworkURL: nil))
            }
        }

        var tracks: [MediaTrack] = []
        for audioFile in audioFiles {
            tracks.append(await LocalTrackMetadataLoader.track(from: audioFile.url, fallbackArtworkURL: audioFile.folderArtworkURL))
        }

        return LocalFileImportResult(tracks: tracks, unsupportedCount: unsupportedCount)
    }

    static func isSupportedAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func collectAudioFiles(in folderURL: URL) -> (files: [LocalAudioFile], unsupportedCount: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], 0)
        }

        var audioFilesByFolder: [URL: [URL]] = [:]
        var imageFilesByFolder: [URL: [URL]] = [:]
        var unsupportedCount = 0

        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let parentURL = fileURL.deletingLastPathComponent().standardizedFileURL
            if isSupportedAudioFile(fileURL) {
                audioFilesByFolder[parentURL, default: []].append(fileURL)
            } else if isSupportedImageFile(fileURL) {
                imageFilesByFolder[parentURL, default: []].append(fileURL)
            } else {
                unsupportedCount += 1
            }
        }

        let folderArtworkByFolder: [URL: URL] = Dictionary(
            uniqueKeysWithValues: audioFilesByFolder.compactMap { folderURL, audioFiles in
                guard audioFiles.count > 1,
                      let artworkURL = folderArtworkURL(from: imageFilesByFolder[folderURL] ?? []) else {
                    return nil
                }
                return (folderURL, artworkURL)
            }
        )

        let files = audioFilesByFolder
            .flatMap { folderURL, audioFiles in
                audioFiles.map { LocalAudioFile(url: $0, folderArtworkURL: folderArtworkByFolder[folderURL]) }
            }
            .sorted {
                $0.url.standardizedFileURL.path.localizedStandardCompare($1.url.standardizedFileURL.path) == .orderedAscending
            }
        return (files, unsupportedCount)
    }

    private static func folderArtworkURL(from imageURLs: [URL]) -> URL? {
        let sortedImageURLs = imageURLs.sorted {
            $0.standardizedFileURL.path.localizedStandardCompare($1.standardizedFileURL.path) == .orderedAscending
        }
        guard sortedImageURLs.count > 1 else { return sortedImageURLs.first }

        for preferredName in preferredFolderArtworkNames {
            if let match = sortedImageURLs.first(where: {
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(preferredName) == .orderedSame
            }) {
                return match
            }
        }

        return sortedImageURLs.first
    }
}

private struct LocalAudioFile {
    let url: URL
    let folderArtworkURL: URL?
}

struct LocalFileImportResult {
    let tracks: [MediaTrack]
    let unsupportedCount: Int

    static let empty = LocalFileImportResult(tracks: [], unsupportedCount: 0)
}

@MainActor
enum LocalTrackMetadataLoader {
    private static var artworkCache: [URL: URL] = [:]

    static func track(from fileURL: URL, fallbackArtworkURL: URL? = nil) async -> MediaTrack {
        let metadata = await readMetadata(from: fileURL)
        return MediaTrack(
            id: fileURL.standardizedFileURL.path,
            playQueueItemID: nil,
            ratingKey: nil,
            albumRatingKey: nil,
            artistRatingKey: nil,
            durationMilliseconds: metadata.durationMs,
            title: metadata.title,
            trackArtist: metadata.artist,
            albumArtist: metadata.albumArtist,
            albumName: metadata.albumName,
            artworkURL: metadata.artworkURL ?? fallbackArtworkURL,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            streamURL: fileURL
        )
    }

    private static func readMetadata(from url: URL) async -> LocalTrackMetadata {
        let asset = AVURLAsset(url: url)

        var title: String?
        var artist: String?
        var albumArtist: String?
        var albumName: String?
        var trackNumber: Int?
        var discNumber: Int?
        var durationMs: Int?
        var artworkURL: URL?

        let metadata = try? await asset.load(.commonMetadata)
        let formats = try? await asset.load(.metadata)
        let duration = try? await asset.load(.duration)

        if let d = duration {
            let seconds = CMTimeGetSeconds(d)
            if seconds.isFinite && seconds > 0 {
                durationMs = Int(seconds * 1000)
            }
        }

        if let metadata {
            for item in metadata {
                guard let value = try? await item.load(.value) else { continue }

                switch item.commonKey {
                case .commonKeyTitle:
                    title = value as? String
                case .commonKeyArtist:
                    artist = value as? String
                case .commonKeyAlbumName:
                    albumName = value as? String
                case .commonKeyArtwork:
                    break
                default:
                    break
                }
            }

            let artworkItems = metadata.filter { $0.commonKey == .commonKeyArtwork }
            if let artworkItem = artworkItems.first,
               let data = try? await artworkItem.load(.dataValue) {
                artworkURL = cachedArtworkURL(for: url, data: data)
            }
        }

        if let formats {
            for item in formats {
                guard let identifier = item.identifier?.rawValue.lowercased() else { continue }
                if identifier.contains("albumartist"), albumArtist == nil {
                    albumArtist = try? await item.load(.stringValue)
                } else if identifier.contains("tracknumber"), trackNumber == nil {
                    trackNumber = await integerMetadataValue(from: item)
                } else if identifier.contains("discnumber"), discNumber == nil {
                    discNumber = await integerMetadataValue(from: item)
                }
            }
        }

        if title == nil || title?.isEmpty == true {
            title = url.deletingPathExtension().lastPathComponent
        }
        if artist == nil || artist?.isEmpty == true {
            artist = "Unknown Artist"
        }
        if albumName == nil || albumName?.isEmpty == true {
            albumName = url.deletingLastPathComponent().lastPathComponent
            if albumName == "/" || albumName?.isEmpty == true {
                albumName = "Unknown Album"
            }
        }
        albumArtist = albumArtist ?? artist

        return LocalTrackMetadata(
            title: title ?? url.deletingPathExtension().lastPathComponent,
            artist: artist,
            albumArtist: albumArtist,
            albumName: albumName ?? "Unknown Album",
            trackNumber: trackNumber,
            discNumber: discNumber,
            durationMs: durationMs,
            artworkURL: artworkURL
        )
    }

    private static func integerMetadataValue(from item: AVMetadataItem) async -> Int? {
        if let number = try? await item.load(.numberValue) {
            return number.intValue
        }

        guard let string = try? await item.load(.stringValue) else { return nil }
        return Int(string.split(separator: "/").first ?? "")
    }

    private static func cachedArtworkURL(for fileURL: URL, data: Data) -> URL? {
        if let cachedURL = artworkCache[fileURL] {
            return cachedURL
        }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KirinLocalArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let fileName = Data(fileURL.standardizedFileURL.path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .prefix(120)
        let artworkFile = cacheDirectory.appendingPathComponent("\(fileName).artwork")
        do {
            try data.write(to: artworkFile, options: .atomic)
            artworkCache[fileURL] = artworkFile
            return artworkFile
        } catch {
            return nil
        }
    }
}

private struct LocalTrackMetadata {
    let title: String
    let artist: String?
    let albumArtist: String?
    let albumName: String
    let trackNumber: Int?
    let discNumber: Int?
    let durationMs: Int?
    let artworkURL: URL?
}
