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
                    .artworkLoadingPulse(isLoading)
            }
    }
}

private struct ArtworkLoadingPulseModifier: ViewModifier {
    let isActive: Bool
    @State private var isDimmed = false
    @State private var pulseTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .opacity(isDimmed ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.7), value: isDimmed)
            .onAppear {
                guard isActive else { return }
                startPulsing()
            }
            .onChange(of: isActive) { newValue in
                if newValue {
                    startPulsing()
                } else {
                    stopPulsing()
                }
            }
            .onDisappear(perform: stopPulsing)
    }

    private func startPulsing() {
        pulseTask?.cancel()
        isDimmed = true
        pulseTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.7))
                guard !Task.isCancelled else { break }
                isDimmed.toggle()
            }
        }
    }

    private func stopPulsing() {
        pulseTask?.cancel()
        pulseTask = nil
        isDimmed = false
    }
}

private extension View {
    func artworkLoadingPulse(_ isActive: Bool) -> some View {
        modifier(ArtworkLoadingPulseModifier(isActive: isActive))
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
    private let thumbnailStore: ArtworkThumbnailStore
    private let thumbnailMaxPixelSize = 256

    private init() {
        let diskCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KirinArtworkThumbnails", isDirectory: true)
        thumbnailStore = ArtworkThumbnailStore(
            diskCacheDirectory: diskCacheDirectory,
            thumbnailMaxPixelSize: thumbnailMaxPixelSize
        )

        cache.countLimit = 256
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func loadThumbnail(for url: URL) async -> NSImage? {
        if let cachedImage = image(for: url) {
            return cachedImage
        }

        guard let thumbnailData = await thumbnailStore.thumbnailData(for: url),
              let thumbnail = NSImage(data: thumbnailData) else {
            return nil
        }

        storeInMemory(thumbnail, for: url)
        return thumbnail
    }

    private func storeInMemory(_ image: NSImage, for url: URL) {
        let pixelSize = image.representations.first?.pixelsWide ?? thumbnailMaxPixelSize
        cache.setObject(image, forKey: url as NSURL, cost: pixelSize * pixelSize * 4)
    }
}

private actor ArtworkThumbnailStore {
    private let fileManager = FileManager.default
    private let diskCacheDirectory: URL
    private let thumbnailMaxPixelSize: Int
    private let staleThumbnailAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    private var inFlightRequests: [URL: Task<Data?, Never>] = [:]

    init(diskCacheDirectory: URL, thumbnailMaxPixelSize: Int) {
        self.diskCacheDirectory = diskCacheDirectory
        self.thumbnailMaxPixelSize = thumbnailMaxPixelSize

        try? fileManager.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
        Self.cleanUpStaleThumbnails(
            in: diskCacheDirectory,
            staleThumbnailAge: staleThumbnailAge
        )
    }

    func thumbnailData(for url: URL) async -> Data? {
        if let inFlightRequest = inFlightRequests[url] {
            return await inFlightRequest.value
        }

        let request = Task { [diskCacheDirectory, thumbnailMaxPixelSize] in
            await Self.loadThumbnailData(
                for: url,
                diskCacheDirectory: diskCacheDirectory,
                thumbnailMaxPixelSize: thumbnailMaxPixelSize
            )
        }
        inFlightRequests[url] = request
        let data = await request.value
        inFlightRequests[url] = nil
        return data
    }

    private static func loadThumbnailData(
        for url: URL,
        diskCacheDirectory: URL,
        thumbnailMaxPixelSize: Int
    ) async -> Data? {
        let fileURL = diskCacheFileURL(for: url, diskCacheDirectory: diskCacheDirectory)
        if let cachedData = try? Data(contentsOf: fileURL) {
            return cachedData
        }

        do {
            let originalData: Data
            if url.isFileURL {
                originalData = try Data(contentsOf: url)
            } else {
                let (downloadedData, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ... 299).contains(httpResponse.statusCode) else {
                    return nil
                }
                originalData = downloadedData
            }

            guard let thumbnailData = makeThumbnailData(from: originalData, maxPixelSize: thumbnailMaxPixelSize) else {
                return nil
            }

            Task.detached(priority: .utility) {
                try? thumbnailData.write(to: fileURL, options: .atomic)
            }

            return thumbnailData
        } catch {
            return nil
        }
    }

    private static func diskCacheFileURL(for url: URL, diskCacheDirectory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appendingPathComponent(filename).appendingPathExtension("png")
    }

    private static func makeThumbnailData(from data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: thumbnail)
        return representation.representation(using: .png, properties: [:])
    }

    private static func cleanUpStaleThumbnails(in diskCacheDirectory: URL, staleThumbnailAge: TimeInterval) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let cutoffDate = Date().addingTimeInterval(-staleThumbnailAge)
            guard let fileURLs = try? fileManager.contentsOfDirectory(
                at: diskCacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for fileURL in fileURLs {
                guard !Task.isCancelled else { return }
                let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modificationDate = resourceValues?.contentModificationDate,
                      modificationDate < cutoffDate else { continue }
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
}
