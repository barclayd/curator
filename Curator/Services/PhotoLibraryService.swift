import Photos
import UIKit
import UniformTypeIdentifiers
import CuratorCore

enum PhotoAccessError: Error, LocalizedError, Equatable {
    case unavailable, needsDownload, noMotion
    var errorDescription: String? {
        switch self {
        case .unavailable: "This photo isn't available right now."
        case .needsDownload: "Some photos need to download from iCloud. Connect to Wi-Fi and resume."
        case .noMotion: "This Live Photo's motion isn't available to compare yet."
        }
    }
}

protocol PhotoInventoryReading: Actor {
    var count: Int { get }
    func nextBatch(limit: Int) throws -> [PhotoRecord]
}

protocol PhotoLibraryAccess: Sendable {
    func inventory() async throws -> any PhotoInventoryReading
    func records(for ids: [String]) async -> [PhotoRecord]
    func image(for id: String, dimension: Int, network: Bool) async throws -> CGImage
    func delete(_ groups: [ReviewGroup]) async throws
}

actor PhotoInventory: PhotoInventoryReading {
    private let assets: PHFetchResult<PHAsset>
    private var index = 0
    var count: Int { assets.count }

    init() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        assets = PHAsset.fetchAssets(with: .image, options: options)
    }

    func nextBatch(limit: Int = 128) throws -> [PhotoRecord] {
        try Task.checkCancellation()
        let end = min(index + limit, assets.count)
        guard index < end else { return [] }
        let batch = (index..<end).map { PhotoLibraryService.record(assets.object(at: $0)) }
        index = end
        return batch
    }
}

actor PhotoLibraryService: PhotoLibraryAccess {
    func inventory() throws -> any PhotoInventoryReading {
        guard Self.hasAccess else { throw PhotoAccessError.unavailable }
        return PhotoInventory()
    }

    nonisolated static var hasAccess: Bool {
        [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    nonisolated static func record(_ asset: PHAsset) -> PhotoRecord {
        let resources = PHAssetResource.assetResources(for: asset)
        return PhotoRecord(
            id: asset.localIdentifier, created: asset.creationDate, modified: asset.modificationDate,
            width: asset.pixelWidth, height: asset.pixelHeight, burstID: asset.burstIdentifier,
            isFavorite: asset.isFavorite, isEdited: asset.hasAdjustments,
            isHidden: asset.isHidden, isSharedAlbum: asset.sourceType.contains(.typeCloudShared),
            canDelete: asset.canPerform(.delete), isLive: asset.mediaSubtypes.contains(.photoLive),
            isRAW: resources.contains { $0.contentType.conforms(to: .rawImage) },
            resourceSizes: resources.map { $0.dataSize.map(Int64.init) }
        )
    }

    func records(for ids: [String]) -> [PhotoRecord] {
        guard Self.hasAccess else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        return (0..<fetch.count).map { Self.record(fetch.object(at: $0)) }
    }

    func image(for id: String, dimension: Int = 768, network: Bool) async throws -> CGImage {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoAccessError.unavailable
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isNetworkAccessAllowed = network
        let request = PhotoRequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.onCancellation { continuation.resume(throwing: CancellationError()) }
                let identifier = PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: dimension, height: dimension),
                    contentMode: .aspectFit, options: options
                ) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    request.finish {
                        if (info?[PHImageCancelledKey] as? Bool) == true {
                            continuation.resume(throwing: CancellationError())
                        } else if let error = info?[PHImageErrorKey] as? Error {
                            continuation.resume(throwing: error)
                        } else if let image, let cgImage = Self.orientedImage(image) {
                            continuation.resume(returning: cgImage)
                        } else {
                            continuation.resume(throwing: (info?[PHImageResultIsInCloudKey] as? Bool) == true
                                                ? PhotoAccessError.needsDownload : PhotoAccessError.unavailable)
                        }
                    }
                }
                request.set(identifier)
            }
        } onCancel: { request.cancel() }
    }

    nonisolated private static func orientedImage(_ image: UIImage) -> CGImage? {
        guard image.imageOrientation != .up else { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    func delete(_ groups: [ReviewGroup]) async throws {
        guard Self.hasAccess else { throw SafetyError.staleGroup }
        let ids = groups.flatMap { $0.photos.map(\.id) }
        _ = try ReviewSafety.deletionIDs(groups: groups, current: records(for: ids))
        let validation = DeletionValidation()
        try await PHPhotoLibrary.shared().performChanges {
            // Repeat validation at the mutation boundary, including every retained photo.
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            let current = (0..<assets.count).map { Self.record(assets.object(at: $0)) }
            do {
                guard Self.hasAccess else { throw SafetyError.staleGroup }
                let removals = try ReviewSafety.deletionIDs(groups: groups, current: current)
                let selected = (0..<assets.count).map { assets.object(at: $0) }
                    .filter { removals.contains($0.localIdentifier) }
                guard selected.count == removals.count else { throw SafetyError.staleGroup }
                PHAssetChangeRequest.deleteAssets(selected as NSArray)
            } catch { validation.set(error) }
        }
        if let error = validation.error { throw error }
    }
}

/// PhotoKit callbacks may race cancellation and invoke more than once.
final class PhotoRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: PHImageRequestID?
    private var cancelled = false
    private var finished = false
    private var cancellation: (() -> Void)?
    func onCancellation(_ action: @escaping () -> Void) {
        lock.lock()
        if cancelled && !finished {
            finished = true; lock.unlock(); action()
        } else { cancellation = action; lock.unlock() }
    }
    func set(_ id: PHImageRequestID) {
        lock.lock(); identifier = id; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(id) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = identifier
        let action = finished ? nil : cancellation
        if action != nil { finished = true; cancellation = nil }
        lock.unlock()
        action?()
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
    func finish(_ body: () -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; cancellation = nil; lock.unlock(); body()
    }
}

private final class DeletionValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    func set(_ error: Error) { lock.lock(); storedError = error; lock.unlock() }
}
