import Foundation

/// Accepts chronologically sorted metadata without retaining the entire library.
public struct CandidateBuilder: Sendable {
    public static let pipelineVersion = "prototype-1"
    public let maximumCount: Int
    private var pending: [PhotoRecord] = []
    public init(maximumCount: Int = 4) { self.maximumCount = max(2, maximumCount) }

    public mutating func append(_ photo: PhotoRecord) -> [PhotoRecord]? {
        guard photo.isEligible, let date = photo.created else { return nil }
        var finished: [PhotoRecord]?
        if let last = pending.last, let lastDate = last.created, let firstDate = pending.first?.created {
            let sameBurst = photo.burstID != nil && photo.burstID == last.burstID
            let gap = date.timeIntervalSince(lastDate)
            let belongs = gap >= 0 && (sameBurst || (gap <= 60 && date.timeIntervalSince(firstDate) <= 300))
            if !belongs || pending.count == maximumCount {
                if pending.count > 1 { finished = pending }
                pending = []
            }
        }
        pending.append(photo)
        return finished
    }

    public mutating func finish() -> [PhotoRecord]? {
        defer { pending = [] }
        return pending.count > 1 ? pending : nil
    }
}
