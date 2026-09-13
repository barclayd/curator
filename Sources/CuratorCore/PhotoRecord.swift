import Foundation
import CryptoKit

public struct PhotoRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var created: Date?
    public var modified: Date?
    public var width: Int
    public var height: Int
    public var burstID: String?
    public var isFavorite: Bool
    public var isEdited: Bool
    public var isHidden: Bool
    public var isSharedAlbum: Bool
    public var canDelete: Bool
    public var isLive: Bool
    public var isRAW: Bool
    public var resourceSizes: [Int64?]

    public init(id: String, created: Date? = nil, modified: Date? = nil,
                width: Int = 0, height: Int = 0, burstID: String? = nil,
                isFavorite: Bool = false, isEdited: Bool = false,
                isHidden: Bool = false, isSharedAlbum: Bool = false,
                canDelete: Bool = true, isLive: Bool = false, isRAW: Bool = false,
                resourceSizes: [Int64?] = []) {
        self.id = id; self.created = created; self.modified = modified
        self.width = width; self.height = height; self.burstID = burstID
        self.isFavorite = isFavorite; self.isEdited = isEdited; self.isHidden = isHidden
        self.isSharedAlbum = isSharedAlbum; self.canDelete = canDelete
        self.isLive = isLive; self.isRAW = isRAW; self.resourceSizes = resourceSizes
    }

    public var isProtected: Bool { isFavorite || isEdited || !canDelete }
    public var isEligible: Bool { !isHidden && !isSharedAlbum && created != nil }

    public var estimatedBytes: Int64? {
        guard !resourceSizes.isEmpty else { return nil }
        var total: Int64 = 0
        for size in resourceSizes {
            guard let size, size >= 0 else { return nil }
            let next = total.addingReportingOverflow(size)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }

    /// Resource sizes becoming available must not invalidate otherwise identical review decisions.
    public var fingerprint: String {
        var copy = self
        copy.resourceSizes = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return StableID.make((try? encoder.encode(copy)) ?? Data())
    }
}

public enum StableID {
    public static func make(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func group(_ photos: [PhotoRecord]) -> String {
        let data = try! JSONEncoder().encode(photos.map(\.id).sorted())
        return make(data)
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public enum Variety: String, Codable, CaseIterable, Sendable { case more = "More variations", balanced = "Balanced", tighter = "Tighter selection" }
    public enum People: String, Codable, CaseIterable, Sendable { case candid = "Candid", posed = "Posed", any = "No preference" }
    public enum Quality: String, Codable, CaseIterable, Sendable { case moment = "Moment", balanced = "Balanced", sharpness = "Sharpness" }
    public var variety: Variety = .balanced
    public var people: People = .any
    public var quality: Quality = .balanced
    public var allowCellular = false
    public init() {}
    public var analysisKey: String { "\(variety.rawValue)|\(people.rawValue)|\(quality.rawValue)" }
}
