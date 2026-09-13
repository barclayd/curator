import Foundation

public struct PhotoDecision: Codable, Equatable, Sendable {
    public var photoID: String
    public var keep: Bool
    public var equivalentKeeperID: String?
    public var reason: String
    public init(photoID: String, keep: Bool, equivalentKeeperID: String? = nil, reason: String) {
        self.photoID = photoID; self.keep = keep
        self.equivalentKeeperID = equivalentKeeperID; self.reason = reason
    }
}

public struct SimilarityEvidence: Sendable {
    public var first: String
    public var second: String
    public var distance: Double
    public init(_ first: String, _ second: String, distance: Double) {
        self.first = first; self.second = second; self.distance = distance
    }
    public func connects(_ a: String, _ b: String) -> Bool {
        (first == a && second == b) || (first == b && second == a)
    }
}

public enum SafetyError: Error, Equatable, LocalizedError {
    case incompleteProposal, noKeeper, protectedPhoto, invalidEvidence, staleGroup, notApproved, overlappingGroups
    public var errorDescription: String? {
        switch self {
        case .incompleteProposal: "This suggestion needs another look. No photos have been removed."
        case .noKeeper: "Keep at least one photo in this group."
        case .protectedPhoto: "Favourites, edited photos and photos that cannot be deleted stay protected."
        case .invalidEvidence: "These photos aren't similar enough for a suggestion."
        case .staleGroup: "Your library has changed. Review these photos again before removing any."
        case .notApproved: "Review and approve this group first."
        case .overlappingGroups: "These groups need to be scanned again before removal."
        }
    }
}

public enum RecommendationValidator {
    /// Provisional threshold; calibration is a release gate, not a claim of accuracy.
    public static let maximumDistance = 0.45

    public static func validate(photos: [PhotoRecord], decisions: [PhotoDecision],
                                evidence: [SimilarityEvidence]) throws {
        let ids = Set(photos.map(\.id))
        guard photos.count >= 2, ids.count == photos.count,
              decisions.count == ids.count, Set(decisions.map(\.photoID)) == ids,
              decisions.allSatisfy({ !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw SafetyError.incompleteProposal }
        let keepers = Set(decisions.filter(\.keep).map(\.photoID))
        let removals = Set(decisions.filter { !$0.keep }.map(\.photoID))
        try ReviewSafety.validateSelection(photos: photos, removalIDs: removals)
        guard !removals.isEmpty else { throw SafetyError.incompleteProposal }
        for decision in decisions {
            if decision.keep {
                guard decision.equivalentKeeperID == nil else { throw SafetyError.incompleteProposal }
            } else {
                guard let keeper = decision.equivalentKeeperID, keepers.contains(keeper),
                      evidence.contains(where: {
                          $0.connects(decision.photoID, keeper) && $0.distance.isFinite &&
                          $0.distance >= 0 && $0.distance <= maximumDistance
                      }) else { throw SafetyError.invalidEvidence }
            }
        }
    }
}

public struct ReviewGroup: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, approved, deferred, keptAll }
    public var id: String
    public var photos: [PhotoRecord]
    public var decisions: [PhotoDecision]
    public var removalIDs: Set<String>
    public var summary: String
    public var status: Status
    public var analysisKey: String
    public var pipelineVersion: String

    public init(photos: [PhotoRecord], decisions: [PhotoDecision], summary: String, preferences: Preferences) {
        id = StableID.group(photos); self.photos = photos; self.decisions = decisions
        removalIDs = Set(decisions.filter { !$0.keep }.map(\.photoID))
        self.summary = summary; status = .pending; analysisKey = preferences.analysisKey
        pipelineVersion = CandidateBuilder.pipelineVersion
    }
    public var estimatedBytes: Int64? {
        PhotoRecord(id: id, resourceSizes: photos.filter { removalIDs.contains($0.id) }.map(\.estimatedBytes)).estimatedBytes
    }
    public static func ranked(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.estimatedBytes != rhs.estimatedBytes {
            if let left = lhs.estimatedBytes, let right = rhs.estimatedBytes { return left > right }
            return lhs.estimatedBytes != nil
        }
        return lhs.id < rhs.id
    }
}

public enum ReviewSafety {
    public static func validateSelection(photos: [PhotoRecord], removalIDs: Set<String>) throws {
        let ids = Set(photos.map(\.id))
        guard ids.count == photos.count, removalIDs.isSubset(of: ids), photos.allSatisfy(\.isEligible)
        else { throw SafetyError.incompleteProposal }
        guard !ids.subtracting(removalIDs).isEmpty else { throw SafetyError.noKeeper }
        guard !photos.contains(where: { removalIDs.contains($0.id) && $0.isProtected })
        else { throw SafetyError.protectedPhoto }
    }

    public static func deletionIDs(groups: [ReviewGroup], current: [PhotoRecord]) throws -> Set<String> {
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var members: Set<String> = []
        var result: Set<String> = []
        for group in groups {
            guard group.status == .approved else { throw SafetyError.notApproved }
            let ids = Set(group.photos.map(\.id))
            guard members.isDisjoint(with: ids) else { throw SafetyError.overlappingGroups }
            members.formUnion(ids)
            for photo in group.photos {
                guard let fresh = currentByID[photo.id], fresh.fingerprint == photo.fingerprint else {
                    throw SafetyError.staleGroup
                }
            }
            try validateSelection(photos: group.photos, removalIDs: group.removalIDs)
            result.formUnion(group.removalIDs)
        }
        return result
    }
}
