import XCTest
import SwiftData
import FoundationModels
import CoreGraphics
import Photos
import CuratorCore
@testable import Curator

@MainActor
final class CuratorTests: XCTestCase {
    func testPauseAndResumeKeepsCompletedWorkWithoutDuplicatingGroups() async throws {
        let container = try ModelContainer(for: ScanRecord.self, SettingsRecord.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try ReviewStore(container: container)
        var preferences = Preferences(); preferences.allowCellular = true
        try store.savePreferences(preferences)
        let photos = [0.0, 1.0, 1_000.0, 1_001.0].enumerated().map {
            PhotoRecord(id: "\($0.offset)", created: Date(timeIntervalSince1970: $0.element))
        }
        let library = FixtureLibrary(photos: photos)
        let analyzer = ControlledAnalyzer()
        let model = try AppModel(store: store, library: library, analyzer: analyzer,
                                 readinessProvider: { .ready }, authorizationProvider: { .authorized }, observeLibrary: false)
        model.startScan()
        for _ in 0..<500 {
            if await analyzer.calls.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.groups.count, 1)
        model.pause()
        try await waitForScan(model)
        XCTAssertEqual(model.scanState, .paused)
        await analyzer.unblock()
        model.startScan()
        try await waitForScan(model)
        XCTAssertEqual(model.scanState, .finished)
        XCTAssertEqual(model.groups.count, 2)
        let calls = await analyzer.calls
        XCTAssertEqual(calls.filter { $0 == "0" }.count, 1, "Completed comparisons must not run again")
        XCTAssertEqual(calls.filter { $0 == "2" }.count, 2, "Interrupted work is retried once on resume")
    }

    func testPreferencesPreserveApprovalsAndRevocationClearsLocalRecords() async throws {
        let model = try PreviewFixtures.makeModel()
        let original = try XCTUnwrap(model.groups.first)
        model.saveReview(original, status: .approved)
        var preferences = model.preferences; preferences.variety = .more
        model.savePreferences(preferences)
        XCTAssertEqual(model.basket.count, 1)
        XCTAssertEqual(model.basket.first?.removalIDs, original.removalIDs)
        var access = PHAuthorizationStatus.authorized
        let revokedModel = try AppModel(store: model.store, library: model.library,
                                        readinessProvider: { .ready }, authorizationProvider: { access }, observeLibrary: false)
        access = .denied
        await revokedModel.refresh()
        XCTAssertTrue(revokedModel.groups.isEmpty)
        XCTAssertTrue(revokedModel.store.records.isEmpty)
    }

    func testPhotoRequestCancellationCompletesExactlyOnce() {
        let request = PhotoRequestCancellation()
        var cancellationCount = 0
        var completionCount = 0
        request.cancel()
        request.onCancellation { cancellationCount += 1 }
        request.finish { completionCount += 1 }
        request.cancel()
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(completionCount, 0)
    }

    private func waitForScan(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.isScanRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scan did not finish or cancel promptly")
        model.pause()
    }

    func testCheckpointAndApprovalSurviveStoreRecreation() throws {
        let container = try ModelContainer(for: ScanRecord.self, SettingsRecord.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try ReviewStore(container: container)
        let photos = [PhotoRecord(id: "a", created: .distantPast), PhotoRecord(id: "b", created: .distantPast)]
        var group = ReviewGroup(photos: photos, decisions: [.init(photoID: "a", keep: true, reason: "Keep"),
            .init(photoID: "b", keep: false, equivalentKeeperID: "a", reason: "Similar")], summary: "A moment", preferences: Preferences())
        try store.checkpoint(photos, preferences: Preferences(), group: group)
        group.status = .approved
        try store.update(group)
        let reopened = try ReviewStore(container: container)
        XCTAssertTrue(reopened.isCompleted(photos, preferences: Preferences()))
        XCTAssertEqual(try reopened.groups(), [group])
        var preferences = Preferences(); preferences.variety = .more
        XCTAssertFalse(reopened.isCompleted(photos, preferences: preferences))
        try reopened.clear()
        XCTAssertTrue(try reopened.groups().isEmpty)
    }

}

private actor ControlledAnalyzer: RecommendationAnalyzing {
    var calls: [String] = []
    private var blocked = true
    func unblock() { blocked = false }
    func analyze(_ photos: [PhotoRecord], preferences: Preferences, network: Bool) async throws -> ReviewGroup? {
        calls.append(photos[0].id)
        if photos[0].id == "2" && blocked { try await Task.sleep(for: .seconds(30)) }
        return ReviewGroup(photos: photos, decisions: [
            .init(photoID: photos[0].id, keep: true, reason: "Keeper"),
            .init(photoID: photos[1].id, keep: false, equivalentKeeperID: photos[0].id, reason: "Similar")
        ], summary: "A repeated moment", preferences: preferences)
    }
}
