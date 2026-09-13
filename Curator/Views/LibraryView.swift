import SwiftUI
import Photos
import CuratorCore

struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showBasket = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            Group {
                if model.readiness != .ready || !model.hasAccess { introduction }
                else { library }
            }
            .navigationTitle("Curator")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(isPresented: $showBasket) { BasketView(model: model) }
            .sheet(isPresented: $showHistory) { HistoryView(model: model) }
            .sheet(isPresented: Binding(get: { model.showReminderOffer && !showBasket },
                                        set: { model.showReminderOffer = $0 })) { ReminderOfferView(model: model) }
            .alert("Let's take another look", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
            // Until physical background inference validation passes, checkpoint and pause on backgrounding.
            if phase == .background { model.pause() }
        }
    }

    private var introduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "photo.stack").font(.system(size: 54)).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.readiness.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(model.readiness.detail).font(.title3).foregroundStyle(.secondary)
                }
                if model.readiness == .ready {
                    Label("Your photos stay on your device", systemImage: "iphone.gen3")
                    Label("Favourites and edits stay protected", systemImage: "heart")
                    Label("You choose what to remove", systemImage: "checkmark.circle")
                    if model.authorization == .denied || model.authorization == .restricted {
                        Text("Allow photo access in Settings to find similar shots.").foregroundStyle(.secondary)
                        Button("Open Settings") { openSettings() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Choose photo access") { Task { await model.requestAccess() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Text("Full access helps Curator find more groups. Selected photos work too. Nothing is removed without your approval.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Check again") { Task { await model.refresh() } }.buttonStyle(.borderedProminent)
                    #if targetEnvironment(simulator)
                    Text("Simulator uses your Mac's Apple Intelligence model. Image analysis needs a compatible macOS 27 model as well as the iOS 27 runtime.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
                }
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("welcome")
    }

    private var library: some View {
        List {
            if model.authorization == .limited {
                Section {
                    Label("Looking through your selected photos", systemImage: "photo.badge.checkmark")
                    Button("Manage selected photos") { presentLimitedLibraryPicker() }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(scanTitle).font(.headline)
                    if model.scanState == .scanning {
                        ProgressView(value: Double(model.scanned), total: Double(max(model.total, 1)))
                        Text("\(model.scanned) of \(model.total) photos checked").font(.subheadline).foregroundStyle(.secondary)
                        Button("Pause", systemImage: "pause") { model.pause() }
                    } else {
                        Text(scanDetail).font(.subheadline).foregroundStyle(.secondary)
                        Button(model.scanState == .idle ? "Find similar photos" : "Scan and resume", systemImage: "sparkle.magnifyingglass") { model.startScan() }
                            .buttonStyle(.borderedProminent).disabled(model.isDeleting)
                    }
                    if model.unavailableCount > 0 {
                        Text("\(model.unavailableCount) photos couldn't be compared yet. Resume to try them again.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }
            if !model.pendingGroups.isEmpty {
                Section {
                    ForEach(model.pendingGroups) { group in
                        NavigationLink { GroupReviewView(model: model, initialGroup: group) } label: {
                            GroupRow(group: group, library: model.library)
                        }
                    }
                } header: { Text("Similar moments") } footer: {
                    Text("Largest estimated removals first. Keep as many variations as you like.")
                }
            } else if model.scanState == .finished {
                Section {
                    ContentUnavailableView(model.total == 0 ? "No photos to review" : "Nothing to suggest right now",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text(model.total == 0 ? "Add photos or change your selected-photo access, then scan again." : "Curator only suggests clear repeats. Your distinct shots are worth keeping."))
                }
            }
            if model.groups.contains(where: { $0.status == .deferred || $0.status == .keptAll }) {
                Button("Past decisions & later", systemImage: "clock.arrow.circlepath") { showHistory = true }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.removalCount > 0 {
                Button { showBasket = true } label: {
                    Label(model.removalCount == 1 ? "Review 1 removal" : "Review \(model.removalCount) removals", systemImage: "tray.full")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).padding().background(.bar)
            }
        }
    }

    private var scanTitle: String {
        switch model.scanState {
        case .idle: "Make room for what comes next"
        case .scanning: "Finding the shots that belong together"
        case .paused: "Your progress is saved"
        case .waitingForWiFi: "Some photos are waiting for Wi-Fi"
        case .finished: model.unavailableCount == 0 ? "You're up to date" : "A few photos still need another look"
        }
    }
    private var scanDetail: String {
        switch model.scanState {
        case .idle: "Curator looks for repeated shots across the photos you allow. You can review groups as they appear."
        case .scanning: ""
        case .paused: "Resume whenever you're ready. Completed comparisons don't need to run again."
        case .waitingForWiFi: "Connect to Wi-Fi and resume, or allow cellular downloads in Settings."
        case .finished: "All accessible photos were checked for groups. You can scan again as your library changes."
        }
    }
}

struct GroupRow: View {
    let group: ReviewGroup
    let library: any PhotoLibraryAccess
    var body: some View {
        HStack(spacing: 14) {
            if let first = group.photos.first {
                PhotoThumbnail(id: first.id, library: library)
                    .frame(width: 68, height: 68).clipShape(.rect(cornerRadius: 12)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.photos.first?.created ?? .now, format: .dateTime.day().month(.abbreviated).year()).font(.headline)
                Text("\(group.photos.count) photos · \(group.removalIDs.count) to remove").font(.subheadline).foregroundStyle(.secondary)
                Text(sizeLabel(group.estimatedBytes)).font(.subheadline.monospacedDigit())
            }
        }.padding(.vertical, 4)
    }
}

func sizeLabel(_ bytes: Int64?) -> String {
    guard let bytes else { return "Size unavailable" }
    return "About \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of media"
}

@MainActor func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

@MainActor func presentLimitedLibraryPicker() {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
          var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
    while let presented = controller.presentedViewController { controller = presented }
    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
}
