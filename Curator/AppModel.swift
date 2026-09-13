import SwiftUI
import SwiftData
import Photos
import CuratorCore

@MainActor @Observable
final class AppModel {
    enum ScanState: Equatable { case idle, scanning, paused, waitingForWiFi, finished }
    var readiness = ModelReadiness.current()
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var groups: [ReviewGroup] = []
    var preferences = Preferences()
    var scanState: ScanState = .idle
    var scanned = 0
    var total = 0
    var unavailableCount = 0
    var errorMessage: String?
    var isDeleting = false
    var isInspecting = false
    var showReminderOffer = false
    let library: any PhotoLibraryAccess
    let network = NetworkPolicy()
    let store: ReviewStore
    private let analyzer: any RecommendationAnalyzing
    private var scanTask: Task<Void, Never>?
    private var libraryObserver: LibraryObserver?
    private var generation = UUID()
    private var refreshGeneration = UUID()
    private var reviewedPhotoIDs: Set<String> = []
    private var consecutiveFailures = 0
    private let readinessProvider: () -> ModelReadiness
    private let authorizationProvider: () -> PHAuthorizationStatus
    private let observeLibrary: Bool

    init(store: ReviewStore, library: any PhotoLibraryAccess = PhotoLibraryService(),
         analyzer: (any RecommendationAnalyzing)? = nil,
         readinessProvider: @escaping () -> ModelReadiness = ModelReadiness.current,
         authorizationProvider: @escaping () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
         observeLibrary: Bool = true) throws {
        self.store = store; self.library = library
        self.readinessProvider = readinessProvider; self.authorizationProvider = authorizationProvider
        self.observeLibrary = observeLibrary
        readiness = readinessProvider(); authorization = authorizationProvider()
        self.analyzer = analyzer ?? RecommendationAnalyzer(library: library)
        groups = try store.groups(); preferences = try store.preferences()
        updateReviewedIDs()
        registerObserverIfAuthorized()
        network.onRestrictedPath = { [weak self] in
            guard let self, !self.preferences.allowCellular, self.scanState == .scanning else { return }
            self.pause(); self.scanState = .waitingForWiFi
        }
    }
    var hasAccess: Bool { authorization == .authorized || authorization == .limited }
    var isScanRunning: Bool { scanTask != nil }
    var pendingGroups: [ReviewGroup] { groups.filter { $0.status == .pending }.sorted(by: ReviewGroup.ranked) }
    var basket: [ReviewGroup] { groups.filter { $0.status == .approved }.sorted(by: ReviewGroup.ranked) }
    var removalCount: Int { basket.reduce(0) { $0 + $1.removalIDs.count } }
    var permitsDownload: Bool { network.permitsDownload(allowCellular: preferences.allowCellular) }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refresh()
    }

    func refresh() async {
        readiness = readinessProvider()
        authorization = authorizationProvider()
        refreshGeneration = UUID()
        let refreshID = refreshGeneration
        guard hasAccess else {
            pause()
            libraryObserver = nil
            do { try store.clear(); groups = [] } catch { errorMessage = error.localizedDescription }
            updateReviewedIDs()
            return
        }
        registerObserverIfAuthorized()
        let before = generation
        let oldGroups = groups
        let fresh = await library.records(for: oldGroups.flatMap { $0.photos.map(\.id) })
        guard generation == before, refreshGeneration == refreshID else { return }
        let lookup = Dictionary(fresh.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        let stale = Set(oldGroups.filter { group in group.photos.contains { lookup[$0.id] != $0.fingerprint } }.map(\.id))
        do {
            try store.remove(stale)
            groups.removeAll { stale.contains($0.id) }
            // Checkpoints contain IDs only. Purge inaccessible IDs after selected-photo access changes.
            if authorization == .limited {
                let records = Array(store.records.values)
                for chunkStart in stride(from: 0, to: records.count, by: 128) {
                    let chunk = Array(records[chunkStart..<min(chunkStart + 128, records.count)])
                    let accessible = Set(await library.records(for: chunk.flatMap(\.memberIDs)).map(\.id))
                    guard refreshGeneration == refreshID, generation == before else { return }
                    let invalid = Set(chunk.filter { !Set($0.memberIDs).isSubset(of: accessible) }.map(\.id))
                    try store.remove(invalid)
                }
            }
            updateReviewedIDs()
        } catch { errorMessage = error.localizedDescription }
    }

    func startScan() {
        guard scanTask == nil, hasAccess, readiness == .ready, !isDeleting else { return }
        generation = UUID()
        let run = generation
        scanState = .scanning; scanned = 0; unavailableCount = 0; consecutiveFailures = 0
        let preferences = self.preferences
        scanTask = Task {
            do {
                await refresh()
                try Task.checkCancellation()
                let inventory = try await library.inventory()
                total = await inventory.count
                var builder = CandidateBuilder()
                var seen: Set<String> = []
                var needsWiFi = false
                while true {
                    try Task.checkCancellation()
                    let batch = try await inventory.nextBatch(limit: 128)
                    if batch.isEmpty { break }
                    for photo in batch {
                        try Task.checkCancellation()
                        seen.insert(photo.id)
                        if let candidate = builder.append(photo) {
                            if try await process(candidate, preferences: preferences) { needsWiFi = true }
                        }
                        scanned += 1
                    }
                }
                if let candidate = builder.finish() {
                    if try await process(candidate, preferences: preferences) { needsWiFi = true }
                }
                let inaccessible = Set(store.records.values.filter { !Set($0.memberIDs).isSubset(of: seen) }.map(\.id))
                try store.remove(inaccessible)
                groups.removeAll { inaccessible.contains($0.id) }
                scanState = needsWiFi ? .waitingForWiFi : .finished
            } catch is CancellationError {
                if scanState == .scanning { scanState = .paused }
            } catch {
                scanState = .paused; errorMessage = error.localizedDescription
            }
            if generation == run { scanTask = nil }
        }
    }

    /// Returns true when a local-only resource needs a later download. Completed work is checkpointed first.
    private func process(_ photos: [PhotoRecord], preferences: Preferences) async throws -> Bool {
        // Explicit decisions win, even when newly inserted photos change temporal chunk boundaries.
        let candidateIDs = Set(photos.map(\.id))
        guard reviewedPhotoIDs.isDisjoint(with: candidateIDs), !store.isCompleted(photos, preferences: preferences)
        else { return false }
        while isInspecting { try await Task.sleep(for: .milliseconds(200)) }
        let download = permitsDownload
        let group: ReviewGroup?
        do {
            group = try await analyzer.analyze(photos, preferences: preferences, network: download)
            consecutiveFailures = 0
        } catch is CancellationError { throw CancellationError() }
        catch is SafetyError {
            group = nil
        } catch let error as AnalysisError { throw error }
        catch {
            // Leave failed candidates uncheckpointed so Resume can retry; never publish partial decisions.
            unavailableCount += photos.count
            if let photoError = error as? PhotoAccessError, photoError == .needsDownload { return true }
            let cocoa = error as NSError
            if cocoa.domain == PHPhotosErrorDomain && cocoa.code == PHPhotosError.Code.networkAccessRequired.rawValue { return true }
            consecutiveFailures += 1
            if consecutiveFailures >= 3 { throw AnalysisError.inferenceFailed }
            return false
        }
        // Persistence errors are not inference failures: propagate them and pause instead of losing progress silently.
        let fresh = await library.records(for: photos.map(\.id))
        try Task.checkCancellation()
        guard self.preferences.analysisKey == preferences.analysisKey,
              reviewedPhotoIDs.isDisjoint(with: candidateIDs),
              Set(fresh.map(\.fingerprint)) == Set(photos.map(\.fingerprint)) else { return false }
        let obsolete = Set(groups.filter {
            $0.status == .pending && $0.id != StableID.group(photos) &&
            !Set($0.photos.map(\.id)).isDisjoint(with: candidateIDs)
        }.map(\.id))
        try store.remove(obsolete)
        try store.checkpoint(photos, preferences: preferences, group: group)
        groups.removeAll { obsolete.contains($0.id) || $0.id == StableID.group(photos) }
        if let group { groups.append(group) }
        return false
    }

    func pause() {
        scanTask?.cancel()
        if scanState == .scanning { scanState = .paused }
    }

    func savePreferences(_ updated: Preferences) {
        pause()
        do {
            let analysisChanged = updated.analysisKey != preferences.analysisKey
            try store.savePreferences(updated); preferences = updated
            if analysisChanged {
                let ids = Set(groups.filter { $0.status == .pending }.map(\.id))
                try store.remove(ids); groups.removeAll { ids.contains($0.id) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveReview(_ proposed: ReviewGroup, status: ReviewGroup.Status) {
        do {
            guard let index = groups.firstIndex(where: { $0.id == proposed.id }),
                  groups[index].photos == proposed.photos else { throw SafetyError.staleGroup }
            var group = proposed
            if status == .keptAll { group.removalIDs = [] }
            try ReviewSafety.validateSelection(photos: group.photos, removalIDs: group.removalIDs)
            group.status = status
            if status == .approved && group.removalIDs.isEmpty { group.status = .keptAll }
            try store.update(group); groups[index] = group
            updateReviewedIDs()
        } catch { errorMessage = error.localizedDescription }
    }

    private func updateReviewedIDs() {
        reviewedPhotoIDs = Set(groups.filter { $0.status != .pending }.flatMap { $0.photos.map(\.id) })
    }

    private func registerObserverIfAuthorized() {
        // Registering before authorisation can itself trigger a Photos permission alert.
        guard observeLibrary, hasAccess, libraryObserver == nil else { return }
        libraryObserver = LibraryObserver { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func deleteBasket() async {
        guard !isDeleting, removalCount > 0 else { return }
        pause(); isDeleting = true
        let approved = basket
        defer { isDeleting = false }
        do {
            try await library.delete(approved)
            let ids = Set(approved.map(\.id))
            try store.remove(ids); groups.removeAll { ids.contains($0.id) }
            updateReviewedIDs()
            if !store.settings.hasCleanedUp { showReminderOffer = true }
            store.settings.hasCleanedUp = true
            try store.saveSettings()
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }
}

private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let change: @Sendable () -> Void
    init(change: @escaping @Sendable () -> Void) {
        self.change = change
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    func photoLibraryDidChange(_ changeInstance: PHChange) { change() }
}
