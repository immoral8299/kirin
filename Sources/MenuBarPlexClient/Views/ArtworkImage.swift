import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

struct ArtworkImage: View {
    let url: URL?
    let placeholderSystemImage: String
    @StateObject private var loader = ArtworkThumbnailLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder(isLoading: loader.isLoading)
            }
        }
        .task(id: url) {
            await loader.load(url: url)
        }
    }

    private func placeholder(isLoading: Bool) -> some View {
        AppTheme.artworkPlaceholder
            .overlay {
                Image(systemName: placeholderSystemImage)
                    .foregroundStyle(.secondary.opacity(0.55))
            }
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
    }
}

@MainActor
private final class ArtworkThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false

    func load(url: URL?) async {
        image = nil
        isLoading = url != nil

        guard let url else { return }

        if let cachedImage = ArtworkThumbnailCache.shared.image(for: url) {
            image = cachedImage
            isLoading = false
            return
        }

        let loadedImage = await ArtworkThumbnailCache.shared.loadThumbnail(for: url)
        guard !Task.isCancelled else { return }

        image = loadedImage
        isLoading = false
    }
}

@MainActor
private final class ArtworkThumbnailCache {
    static let shared = ArtworkThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()
    private let fileManager = FileManager.default
    private let diskCacheDirectory: URL
    private let thumbnailMaxPixelSize = 256

    private init() {
        diskCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KirinArtworkThumbnails", isDirectory: true)

        cache.countLimit = 256
        cache.totalCostLimit = 24 * 1_024 * 1_024

        try? fileManager.removeItem(at: diskCacheDirectory)
        try? fileManager.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func loadThumbnail(for url: URL) async -> NSImage? {
        if let cachedImage = image(for: url) {
            return cachedImage
        }

        if let diskCachedImage = loadDiskCachedThumbnail(for: url) {
            storeInMemory(diskCachedImage, for: url)
            return diskCachedImage
        }

        do {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (downloadedData, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ... 299).contains(httpResponse.statusCode) else {
                    return nil
                }
                data = downloadedData
            }

            guard let thumbnail = makeThumbnail(from: data) else { return nil }

            storeInMemory(thumbnail, for: url)
            storeOnDisk(thumbnail, for: url)
            return thumbnail
        } catch {
            return nil
        }
    }

    private func storeInMemory(_ image: NSImage, for url: URL) {
        let pixelSize = image.representations.first?.pixelsWide ?? thumbnailMaxPixelSize
        cache.setObject(image, forKey: url as NSURL, cost: pixelSize * pixelSize * 4)
    }

    private func loadDiskCachedThumbnail(for url: URL) -> NSImage? {
        let fileURL = diskCacheFileURL(for: url)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return makeThumbnail(from: data)
    }

    private func storeOnDisk(_ image: NSImage, for url: URL) {
        guard let representation = image.representations.first as? NSBitmapImageRep,
              let data = representation.representation(using: .png, properties: [:]) else {
            return
        }

        try? data.write(to: diskCacheFileURL(for: url), options: .atomic)
    }

    private func diskCacheFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appendingPathComponent(filename).appendingPathExtension("png")
    }

    private func makeThumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: thumbnail)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
