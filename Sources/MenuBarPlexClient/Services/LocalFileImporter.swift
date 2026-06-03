import AVFoundation
import AppKit
import Foundation

@MainActor
enum LocalFileImporter {
    static let audioExtensions: Set<String> = [
        "mp3", "flac", "wav", "aac", "m4a", "m4b", "m4p",
        "ogg", "oga", "opus", "wma", "alac", "aiff", "aif",
        "dsf", "dff", "wv", "ape"
    ]

    static func selectFilesAndFolders() async -> [MediaTrack] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose audio files or folders containing music"
        panel.prompt = "Add to Queue"

        guard panel.runModal() == .OK else { return [] }

        let urls = panel.urls
        return await buildTracks(from: urls)
    }

    static func selectMusicFolder() async -> [MediaTrack] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a music folder"
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return [] }

        return await buildTracks(from: [url])
    }

    private static func buildTracks(from urls: [URL]) async -> [MediaTrack] {
        var audioFiles: [URL] = []

        for url in urls {
            if url.hasDirectoryPath {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                while let fileURL = enumerator?.nextObject() as? URL {
                    guard audioExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                    audioFiles.append(fileURL)
                }
            } else {
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                audioFiles.append(url)
            }
        }

        audioFiles.sort { $0.lastPathComponent < $1.lastPathComponent }

        var tracks: [MediaTrack] = []
        for fileURL in audioFiles {
            let metadata = await readMetadata(from: fileURL)
            let track = MediaTrack(
                id: fileURL.path,
                playQueueItemID: nil,
                ratingKey: fileURL.path,
                albumRatingKey: nil,
                artistRatingKey: nil,
                durationMilliseconds: metadata.durationMs,
                title: metadata.title,
                trackArtist: metadata.artist,
                albumArtist: metadata.albumArtist,
                albumName: metadata.albumName,
                artworkURL: metadata.artworkURL,
                trackNumber: metadata.trackNumber,
                discNumber: nil,
                streamURL: fileURL
            )
            tracks.append(track)
        }

        return tracks
    }

    private static func readMetadata(from url: URL) async -> LocalTrackMetadata {
        let asset = AVURLAsset(url: url)

        var title: String?
        var artist: String?
        var albumArtist: String?
        var albumName: String?
        let trackNumber: Int? = nil
        var durationMs: Int?
        var artworkURL: URL?

        let metadata = try? await asset.load(.commonMetadata)
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
                default:
                    break
                }
            }

            let artworkItems = metadata.filter { $0.commonKey == .commonKeyArtwork }
            if let artworkItem = artworkItems.first,
               let data = try? await artworkItem.load(.dataValue) {
                let fileName = url.pathComponents.suffix(2).joined(separator: "-") + ".jpg"
                let tempDir = FileManager.default.temporaryDirectory
                let artworkFile = tempDir.appendingPathComponent(fileName)
                try? data.write(to: artworkFile)
                artworkURL = artworkFile
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
            durationMs: durationMs,
            artworkURL: artworkURL
        )
    }
}

private struct LocalTrackMetadata {
    let title: String
    let artist: String?
    let albumArtist: String?
    let albumName: String
    let trackNumber: Int?
    let durationMs: Int?
    let artworkURL: URL?
}
