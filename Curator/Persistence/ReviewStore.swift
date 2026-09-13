import SwiftData
import Foundation
import CuratorCore

@Model
final class ScanRecord {
    @Attribute(.unique) var id: String
    var fingerprint: String
    var memberIDs: [String]
    var proposal: Data?
    init(id: String, fingerprint: String, memberIDs: [String], proposal: Data?) {
        self.id = id; self.fingerprint = fingerprint; self.memberIDs = memberIDs; self.proposal = proposal
    }
}

@Model
final class SettingsRecord {
    @Attribute(.unique) var id: String = "settings"
    var preferences: Data
    var hasCleanedUp = false
    var reminderEnabled = false
    var reminderWeekday = 1
    var reminderHour = 18
    var reminderMinute = 0
    init(preferences: Data) { self.preferences = preferences }
}

@MainActor
final class ReviewStore {
    let context: ModelContext
    private(set) var records: [String: ScanRecord]
    let settings: SettingsRecord
    init(container: ModelContainer) throws {
        context = ModelContext(container)
        context.autosaveEnabled = false
        records = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ScanRecord>()).map { ($0.id, $0) })
        if let existing = try context.fetch(FetchDescriptor<SettingsRecord>()).first { settings = existing }
        else {
            settings = SettingsRecord(preferences: try JSONEncoder().encode(Preferences()))
            context.insert(settings)
            try context.save()
        }
    }
    func groups() throws -> [ReviewGroup] {
        try records.values.compactMap { record in
            try record.proposal.map { try JSONDecoder().decode(ReviewGroup.self, from: $0) }
        }
    }
    func preferences() throws -> Preferences { try JSONDecoder().decode(Preferences.self, from: settings.preferences) }
    func savePreferences(_ preferences: Preferences) throws {
        settings.preferences = try JSONEncoder().encode(preferences)
        try context.save()
    }
    static func fingerprint(_ photos: [PhotoRecord], preferences: Preferences) -> String {
        StableID.make(Data((photos.map(\.fingerprint).joined() + preferences.analysisKey + CandidateBuilder.pipelineVersion).utf8))
    }
    func isCompleted(_ photos: [PhotoRecord], preferences: Preferences) -> Bool {
        records[StableID.group(photos)]?.fingerprint == Self.fingerprint(photos, preferences: preferences)
    }
    func checkpoint(_ photos: [PhotoRecord], preferences: Preferences, group: ReviewGroup?) throws {
        let id = StableID.group(photos)
        let data = try group.map { try JSONEncoder().encode($0) }
        if let existing = records[id] {
            existing.fingerprint = Self.fingerprint(photos, preferences: preferences)
            existing.proposal = data
        } else {
            let record = ScanRecord(id: id, fingerprint: Self.fingerprint(photos, preferences: preferences),
                                    memberIDs: photos.map(\.id), proposal: data)
            context.insert(record); records[id] = record
        }
        try context.save()
    }
    func update(_ group: ReviewGroup) throws {
        guard let record = records[group.id] else { throw SafetyError.staleGroup }
        record.proposal = try JSONEncoder().encode(group)
        try context.save()
    }
    func remove(_ ids: Set<String>) throws {
        for id in ids {
            if let record = records.removeValue(forKey: id) { context.delete(record) }
        }
        try context.save()
    }
    func clear() throws { try remove(Set(records.keys)) }
    func saveSettings() throws { try context.save() }
}
