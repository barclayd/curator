import Photos
import AVFoundation

actor LivePhotoLoader {
    private let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CuratorMotion", isDirectory: true)
    init() {
        // A previous process may have terminated before its defer could remove temporary motion.
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
    }
    func frames(for id: String, network: Bool) async throws -> [CGImage] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .pairedVideo })
        else { throw PhotoAccessError.noMotion }
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let download = ResourceDownload()
        try await download.write(resource, to: url, network: network)
        try Task.checkCancellation()
        let movie = AVURLAsset(url: url)
        let duration = try await movie.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PhotoAccessError.noMotion }
        let generator = AVAssetImageGenerator(asset: movie)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        var frames: [CGImage] = []
        for fraction in [0.25, 0.75] {
            try Task.checkCancellation()
            let frame = try await generator.image(at: CMTime(seconds: duration * fraction, preferredTimescale: 600))
            frames.append(frame.image)
        }
        return frames
    }
}

/// Streams motion to a temporary file with a hard bound; never holds the movie in memory.
private final class ResourceDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var failure: Error?
    private var bytes = 0
    private var handle: FileHandle?

    func write(_ resource: PHAssetResource, to url: URL, network: Bool) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        defer { try? handle?.close(); handle = nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = network
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    self.receive(data)
                } completionHandler: { error in
                    self.lock.lock()
                    let resultError = self.cancelled ? CancellationError() : (self.failure ?? error)
                    self.lock.unlock()
                    if let resultError { continuation.resume(throwing: resultError) }
                    else { continuation.resume() }
                }
                self.lock.lock(); self.id = requestID; let cancel = self.cancelled; self.lock.unlock()
                if cancel { PHAssetResourceManager.default().cancelDataRequest(requestID) }
            }
        } onCancel: { self.cancel() }
    }

    private func receive(_ data: Data) {
        lock.lock()
        guard !cancelled, failure == nil else { lock.unlock(); return }
        bytes += data.count
        do {
            guard bytes <= 100 * 1024 * 1024 else { throw PhotoAccessError.noMotion }
            try handle?.write(contentsOf: data)
        } catch { failure = error }
        let shouldCancel = failure != nil
        let requestID = id
        lock.unlock()
        if shouldCancel, let requestID { PHAssetResourceManager.default().cancelDataRequest(requestID) }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let requestID = id; lock.unlock()
        if let requestID { PHAssetResourceManager.default().cancelDataRequest(requestID) }
    }
}
