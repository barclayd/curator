import SwiftUI
import UserNotifications
import CuratorCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var preferences: Preferences
    @State private var reminderEnabled: Bool
    @State private var weekday: Int
    @State private var time: Date
    @State private var reminderError: String?
    @State private var saving = false

    init(model: AppModel) {
        self.model = model
        _preferences = State(initialValue: model.preferences)
        _reminderEnabled = State(initialValue: model.store.settings.reminderEnabled)
        _weekday = State(initialValue: model.store.settings.reminderWeekday)
        _time = State(initialValue: Calendar.current.date(from: DateComponents(hour: model.store.settings.reminderHour, minute: model.store.settings.reminderMinute)) ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Variety", selection: $preferences.variety) {
                        ForEach(Preferences.Variety.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("People", selection: $preferences.people) {
                        ForEach(Preferences.People.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Quality", selection: $preferences.quality) {
                        ForEach(Preferences.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } header: { Text("What makes a keeper?") } footer: {
                    Text("Changing these refreshes suggestions you haven't reviewed. Your explicit choices stay saved. Favourites and edited photos always stay protected.")
                }
                Section {
                    Toggle("Allow cellular downloads", isOn: $preferences.allowCellular)
                } header: { Text("iCloud photos") } footer: {
                    Text("Photos already on your iPhone can be compared offline. By default, missing photos and Live Photo motion download only on Wi-Fi.")
                }
                if model.store.settings.hasCleanedUp {
                    Section("A gentle reminder") {
                        Toggle("Weekly reminder", isOn: $reminderEnabled)
                        if reminderEnabled {
                            Picker("Day", selection: $weekday) {
                                ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                            }
                            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        }
                    }
                }
                Section("Privacy & storage") {
                    Label("Analysis stays on your device", systemImage: "iphone.gen3")
                    Text("Curator has no account, cloud AI or analytics service. Review choices and comparison checkpoints stay in the app.")
                    Text("Media estimates include RAW and Live Photo resources when their sizes are available. They aren't a promise of immediately recovered iPhone storage.")
                    ShareLink("Share a diagnostic summary", item: diagnosticSummary)
                    Text("The summary contains only app version, counts and model status. It includes no photos, photo identifiers or descriptions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Manage photo permissions") { openSettings() }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await save() } }.disabled(saving)
                }
            }
            .alert("Reminder couldn't be saved", isPresented: Binding(get: { reminderError != nil }, set: { if !$0 { reminderError = nil } })) {
                Button("OK") { reminderError = nil }
            } message: { Text(reminderError ?? "") }
        }
    }

    private var diagnosticSummary: String {
        """
        Curator \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        Pipeline: \(CandidateBuilder.pipelineVersion)
        Model ready: \(model.readiness == .ready)
        Photos checked this session: \(model.scanned)
        Groups awaiting review: \(model.pendingGroups.count)
        Approved removals: \(model.removalCount)
        Photos unavailable this session: \(model.unavailableCount)
        """
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let components = Calendar.current.dateComponents([.hour, .minute], from: time)
            if model.store.settings.hasCleanedUp {
                try await WeeklyReminder.configure(enabled: reminderEnabled, weekday: weekday,
                                                    hour: components.hour ?? 18, minute: components.minute ?? 0)
                model.store.settings.reminderEnabled = reminderEnabled
                model.store.settings.reminderWeekday = weekday
                model.store.settings.reminderHour = components.hour ?? 18
                model.store.settings.reminderMinute = components.minute ?? 0
                try model.store.saveSettings()
            }
            model.savePreferences(preferences)
            if model.errorMessage == nil { dismiss() }
        } catch { reminderError = error.localizedDescription }
    }
}

enum WeeklyReminder {
    static let identifier = "curator.weekly"
    static func configure(enabled: Bool, weekday: Int, hour: Int, minute: Int) async throws {
        let center = UNUserNotificationCenter.current()
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier]); return
        }
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw ReminderError.permissionDenied }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "A little room for new memories")
        content.body = String(localized: "Whenever you're ready, take a moment to review your similar photos.")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute, weekday: weekday), repeats: true)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
    enum ReminderError: LocalizedError {
        case permissionDenied
        var errorDescription: String? { "Allow notifications for Curator in Settings to use a weekly reminder." }
    }
}

struct ReminderOfferView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var configure = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle").font(.system(size: 52)).foregroundStyle(.tint)
                Text("A little more breathing room").font(.title.bold())
                Text("Your approved photos have been removed. You can recover them in Photos' Recently Deleted album for 30 days.")
                Text("Would a gentle weekly reminder help you keep on top of similar shots?").foregroundStyle(.secondary)
                Button("Choose a reminder") { configure = true }.buttonStyle(.borderedProminent)
                Button("Not now") { dismiss() }
            }.padding(28).multilineTextAlignment(.center)
                .sheet(isPresented: $configure, onDismiss: { dismiss() }) { SettingsView(model: model) }
        }
    }
}
