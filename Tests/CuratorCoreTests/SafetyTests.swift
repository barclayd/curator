import Testing
import Foundation
@testable import CuratorCore

private func photo(_ id: String, time: Double = 0) -> PhotoRecord {
    PhotoRecord(id: id, created: Date(timeIntervalSince1970: time), resourceSizes: [10])
}
private func decisions() -> [PhotoDecision] {
    [PhotoDecision(photoID: "a", keep: true, reason: "Keeps the moment"),
     PhotoDecision(photoID: "b", keep: false, equivalentKeeperID: "a", reason: "Similar expression and composition")]
}
private func group() -> ReviewGroup {
    ReviewGroup(photos: [photo("a"), photo("b")], decisions: decisions(), summary: "Similar moments", preferences: Preferences())
}

@Test func aValidRecommendationHasIndependentEvidence() throws {
    try RecommendationValidator.validate(photos: group().photos, decisions: decisions(), evidence: [.init("a", "b", distance: 0.1)])
    #expect(throws: SafetyError.invalidEvidence) {
        try RecommendationValidator.validate(photos: group().photos, decisions: decisions(), evidence: [])
    }
}
@Test(arguments: [Double.nan, .infinity, -1, 0.46])
func rejectsInvalidSimilarity(distance: Double) {
    #expect(throws: SafetyError.invalidEvidence) {
        try RecommendationValidator.validate(photos: group().photos, decisions: decisions(), evidence: [.init("a", "b", distance: distance)])
    }
}
@Test func rejectsUnknownDuplicateAndMissingIDs() {
    for invalid in [Array(decisions().prefix(1)), [decisions()[0], decisions()[0]],
                    [decisions()[0], PhotoDecision(photoID: "made-up", keep: false, equivalentKeeperID: "a", reason: "Unknown")]] {
        #expect(throws: SafetyError.incompleteProposal) {
            try RecommendationValidator.validate(photos: group().photos, decisions: invalid, evidence: [.init("a", "b", distance: 0.1)])
        }
    }
}
@Test func neverRemoveEveryPhoto() {
    #expect(throws: SafetyError.noKeeper) { try ReviewSafety.validateSelection(photos: group().photos, removalIDs: ["a", "b"]) }
}
@Test func favoritesEditsAndReadOnlyPhotosAreProtectedEvenManually() {
    for keyPath in [\PhotoRecord.isFavorite, \.isEdited] {
        var photos = group().photos; photos[1][keyPath: keyPath] = true
        #expect(throws: SafetyError.protectedPhoto) { try ReviewSafety.validateSelection(photos: photos, removalIDs: ["b"]) }
    }
    var photos = group().photos; photos[1].canDelete = false
    #expect(throws: SafetyError.protectedPhoto) { try ReviewSafety.validateSelection(photos: photos, removalIDs: ["b"]) }
}
@Test func rawIsEligibleForRemoval() throws {
    var photos = group().photos; photos[1].isRAW = true; photos[1].resourceSizes = [100_000_000, 4_000_000]
    try ReviewSafety.validateSelection(photos: photos, removalIDs: ["b"])
    #expect(photos[1].estimatedBytes == 104_000_000)
}
@Test func preservesMultipleKeepers() throws {
    let photos = [photo("a"), photo("b"), photo("c")]
    let choices = decisions() + [PhotoDecision(photoID: "c", keep: true, reason: "A distinct expression")]
    try RecommendationValidator.validate(photos: photos, decisions: choices, evidence: [.init("a", "b", distance: 0.1)])
}
@Test func cannotUseARemovedPhotoAsKeeper() {
    var choices = decisions(); choices[1].equivalentKeeperID = "b"
    #expect(throws: SafetyError.invalidEvidence) {
        try RecommendationValidator.validate(photos: group().photos, decisions: choices, evidence: [.init("a", "b", distance: 0.1)])
    }
}
@Test func deletionIsExactlyApprovedAndChecksEveryMember() throws {
    var approved = group(); approved.status = .approved
    #expect(try ReviewSafety.deletionIDs(groups: [approved], current: approved.photos) == ["b"])
    #expect(throws: SafetyError.staleGroup) { try ReviewSafety.deletionIDs(groups: [approved], current: [photo("b")]) }
    var edited = approved.photos; edited[0].isEdited = true
    #expect(throws: SafetyError.staleGroup) { try ReviewSafety.deletionIDs(groups: [approved], current: edited) }
    var favorite = approved.photos; favorite[1].isFavorite = true
    #expect(throws: SafetyError.staleGroup) { try ReviewSafety.deletionIDs(groups: [approved], current: favorite) }
    #expect(throws: SafetyError.notApproved) { try ReviewSafety.deletionIDs(groups: [group()], current: group().photos) }
    #expect(throws: SafetyError.overlappingGroups) { try ReviewSafety.deletionIDs(groups: [approved, approved], current: approved.photos) }
}
@Test func unknownSizesStayUnknownAndCompoundResourcesAreCountedOnce() {
    #expect(PhotoRecord(id: "a", resourceSizes: [10, 25]).estimatedBytes == 35)
    #expect(PhotoRecord(id: "a", resourceSizes: [10, nil]).estimatedBytes == nil)
    #expect(PhotoRecord(id: "a", resourceSizes: []).estimatedBytes == nil)
    #expect(PhotoRecord(id: "a", resourceSizes: [-1]).estimatedBytes == nil)
    #expect(PhotoRecord(id: "a", resourceSizes: [.max, 1]).estimatedBytes == nil)
    var original = photo("a"); let fingerprint = original.fingerprint
    original.resourceSizes = [100]
    #expect(original.fingerprint == fingerprint)
}
@Test func knownSizesRankAheadOfUnknown() {
    let known = group()
    var unknown = group(); unknown.id = "unknown"; unknown.photos[1].resourceSizes = [nil]
    #expect([unknown, known].sorted(by: ReviewGroup.ranked).first?.id == known.id)
}
@Test func groupsDoNotBridgeDaysOrLongSequences() {
    var builder = CandidateBuilder(maximumCount: 100)
    #expect(builder.append(photo("a")) == nil)
    #expect(builder.append(photo("b", time: 60)) == nil)
    #expect(builder.append(photo("c", time: 86_400))?.map(\.id) == ["a", "b"])
    #expect(builder.finish() == nil)
    var bounded = CandidateBuilder(maximumCount: 100)
    for index in 0...5 { #expect(bounded.append(photo("\(index)", time: Double(index * 60))) == nil) }
    #expect(bounded.append(photo("6", time: 360))?.count == 6)
}
@Test func hiddenAndSharedAlbumAssetsNeverBecomeCandidates() {
    var builder = CandidateBuilder()
    var hidden = photo("hidden"); hidden.isHidden = true
    var shared = photo("shared"); shared.isSharedAlbum = true
    #expect(builder.append(hidden) == nil); #expect(builder.append(shared) == nil)
    #expect(builder.finish() == nil)
}
@Test func hundredThousandMetadataRecordsUseBoundedChunks() {
    var builder = CandidateBuilder()
    var count = 0
    var largest = 0
    for index in 0..<100_000 {
        if let result = builder.append(photo("\(index)", time: Double(index))) {
            count += result.count; largest = max(largest, result.count)
        }
    }
    count += builder.finish()?.count ?? 0
    #expect(count == 100_000); #expect(largest == 4)
}
@Test func preferencesAndReviewRoundTrip() throws {
    var original = group(); original.status = .approved; original.removalIDs = ["a"]
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(ReviewGroup.self, from: data) == original)
    var preferences = Preferences(); let key = preferences.analysisKey
    preferences.allowCellular = true; #expect(preferences.analysisKey == key)
    preferences.variety = .more; #expect(preferences.analysisKey != key)
}
