import SwiftUI
import SwiftData

@main
struct CuratorApp: App {
    private let model: AppModel?
    private let launchError: String?

    init() {
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting-fixtures") {
                model = try PreviewFixtures.makeModel()
                launchError = nil
                return
            }
            #endif
            let container = try ModelContainer(for: ScanRecord.self, SettingsRecord.self)
            model = try AppModel(store: ReviewStore(container: container))
            launchError = nil
        } catch {
            model = nil
            launchError = "Your review history couldn't be opened. Close Curator and try again. No photos have been removed."
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model { LibraryView(model: model) }
            else {
                ContentUnavailableView("Couldn't open Curator", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(launchError ?? "Please try again."))
            }
        }
    }
}
