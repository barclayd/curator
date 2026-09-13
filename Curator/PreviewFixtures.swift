#if DEBUG
import SwiftData
import UIKit
import CuratorCore

/// Accessible only through an explicit debug launch argument. Never selected in production.
@MainActor enum PreviewFixtures {
    static func makeModel() throws -> AppModel {
        let container = try ModelContainer(for: ScanRecord.self, SettingsRecord.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try ReviewStore(container: container)
        let date = Date(timeIntervalSince1970: 1_784_030_400)
        let photos = [
            PhotoRecord(id: "fixture-a", created: date, resourceSizes: [4_000_000]),
            PhotoRecord(id: "fixture-b", created: date.addingTimeInterval(2), isRAW: true, resourceSizes: [80_000_000]),
            PhotoRecord(id: "fixture-c", created: date.addingTimeInterval(4), isFavorite: true, resourceSizes: [4_000_000])
        ]
        let group = ReviewGroup(photos: photos, decisions: [
            .init(photoID: photos[0].id, keep: true, reason: "The clearest view of this moment."),
            .init(photoID: photos[1].id, keep: false, equivalentKeeperID: photos[0].id, reason: "A very similar view, already covered by your keeper."),
            .init(photoID: photos[2].id, keep: true, reason: "A favourite. Always protected.")
        ], summary: "Two similar views and a favourite. Keep the moments you want to remember.", preferences: Preferences())
        try store.checkpoint(photos, preferences: Preferences(), group: group)
        return try AppModel(store: store, library: FixtureLibrary(photos: photos), readinessProvider: { .ready },
                            authorizationProvider: { .authorized }, observeLibrary: false)
    }
}

actor FixtureInventory: PhotoInventoryReading {
    var photos: [PhotoRecord]
    let count: Int
    init(_ photos: [PhotoRecord]) { self.photos = photos; count = photos.count }
    func nextBatch(limit: Int) -> [PhotoRecord] {
        let batch = Array(photos.prefix(limit)); photos.removeFirst(batch.count); return batch
    }
}

actor FixtureLibrary: PhotoLibraryAccess {
    var photos: [PhotoRecord]
    init(photos: [PhotoRecord]) { self.photos = photos }
    func inventory() -> any PhotoInventoryReading { FixtureInventory(photos) }
    func records(for ids: [String]) -> [PhotoRecord] { photos.filter { ids.contains($0.id) } }
    func image(for id: String, dimension: Int, network: Bool) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PhotoAccessError.unavailable }
        context.setFillColor(CGColor(red: 0.75, green: 0.86, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        context.setFillColor(CGColor(red: 0.18, green: 0.42, blue: 0.32, alpha: 1))
        context.move(to: CGPoint(x: 0, y: 0)); context.addLine(to: CGPoint(x: 260, y: id == "fixture-c" ? 240 : 350))
        context.addLine(to: CGPoint(x: 512, y: 0)); context.closePath(); context.fillPath()
        context.setFillColor(CGColor(red: 0.99, green: 0.79, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: 350, y: 340, width: 80, height: 80))
        guard let image = context.makeImage() else { throw PhotoAccessError.unavailable }
        return image
    }
    func delete(_ groups: [ReviewGroup]) throws {
        let ids = try ReviewSafety.deletionIDs(groups: groups, current: photos)
        photos.removeAll { ids.contains($0.id) }
    }
}
#endif
