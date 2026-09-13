import SwiftUI
import CuratorCore

struct GroupReviewView: View {
    @Bindable var model: AppModel
    let initialGroup: ReviewGroup
    @State private var group: ReviewGroup
    @State private var inspect: PhotoRecord?
    @State private var selectionError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: AppModel, initialGroup: ReviewGroup) {
        self.model = model; self.initialGroup = initialGroup
        _group = State(initialValue: initialGroup)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(group.summary).font(.title3)
                Label("Favourites and edited photos are protected", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 20) {
                    ForEach(group.photos) { photo in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { inspect = photo } label: {
                                PhotoThumbnail(id: photo.id, library: model.library)
                                    .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Inspect photo \((group.photos.firstIndex(of: photo) ?? 0) + 1)")
                            HStack {
                                if photo.isFavorite { Image(systemName: "heart.fill").accessibilityLabel("Favourite") }
                                if photo.isEdited { Image(systemName: "slider.horizontal.3").accessibilityLabel("Edited") }
                                if photo.isRAW { Text("RAW") }
                                if photo.isLive { Label("Live", systemImage: "livephoto") }
                            }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 18, alignment: .leading)
                            Button { toggle(photo) } label: {
                                Label(group.removalIDs.contains(photo.id) ? "Remove" : "Keep",
                                      systemImage: photo.isProtected ? "lock.fill" : (group.removalIDs.contains(photo.id) ? "minus.circle" : "checkmark.circle.fill"))
                                    .frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .buttonStyle(.bordered).tint(group.removalIDs.contains(photo.id) ? .orange : .accentColor)
                            .disabled(photo.isProtected)
                            Text(reason(for: photo))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Tap a photo to inspect it. Keep and Remove update your proposal; nothing is deleted yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Keep all") { save(.keptAll) }
                Button("Decide later") { save(.deferred) }
            }.padding()
        }
        .navigationTitle("Choose your keepers").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Text(sizeLabel(group.estimatedBytes)).font(.footnote).foregroundStyle(.secondary)
                Button(group.removalIDs.isEmpty ? "Keep all" : (group.removalIDs.count == 1 ? "Approve 1 removal" : "Approve \(group.removalIDs.count) removals")) { save(.approved) }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                    .disabled(!model.groups.contains(where: { $0.id == group.id }) || model.isDeleting)
            }.padding().frame(maxWidth: .infinity).background(.bar)
        }
        .fullScreenCover(item: $inspect) { photo in
            PhotoInspector(photos: group.photos, selectedID: photo.id, library: model.library, network: model.permitsDownload)
        }
        .onAppear { model.isInspecting = true }
        .onDisappear { model.isInspecting = false }
        .onChange(of: model.groups.map(\.id)) { _, ids in
            if !ids.contains(group.id) { dismiss() }
        }
        .alert("Keep a little more", isPresented: Binding(get: { selectionError != nil }, set: { if !$0 { selectionError = nil } })) {
            Button("OK") { selectionError = nil }
        } message: { Text(selectionError ?? "") }
    }

    private func toggle(_ photo: PhotoRecord) {
        var updated = group.removalIDs
        if updated.contains(photo.id) { updated.remove(photo.id) } else { updated.insert(photo.id) }
        do { try ReviewSafety.validateSelection(photos: group.photos, removalIDs: updated); group.removalIDs = updated }
        catch { selectionError = error.localizedDescription }
    }
    private func reason(for photo: PhotoRecord) -> String {
        guard let decision = group.decisions.first(where: { $0.photoID == photo.id }) else { return "Your choice" }
        if decision.keep == group.removalIDs.contains(photo.id) {
            return group.removalIDs.contains(photo.id) ? "You chose to remove this photo." : "You chose to keep this photo."
        }
        return decision.reason
    }
    private func save(_ status: ReviewGroup.Status) {
        model.saveReview(group, status: status)
        guard model.errorMessage == nil else { return }
        if initialGroup.status == .pending, let next = model.pendingGroups.first {
            group = next
        } else { dismiss() }
    }
}

struct BasketView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("One last look").font(.title2.bold())
                    Text("Removing photos also removes them from iCloud Photos and your other synced devices. Photos in a Shared Library may affect other people.")
                    Text("You can normally recover them in Photos → Recently Deleted for 30 days. Storage may not be freed immediately, and media size can differ from space used on this iPhone.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.basket) { group in
                    Section {
                        NavigationLink { GroupReviewView(model: model, initialGroup: group) } label: {
                            GroupRow(group: group, library: model.library)
                        }
                        Button("Undo approval", systemImage: "arrow.uturn.backward") { model.saveReview(group, status: .pending) }
                            .disabled(model.isDeleting)
                    }
                }
                if model.removalCount == 0 { ContentUnavailableView("Nothing to remove", systemImage: "checkmark.circle") }
            }
            .navigationTitle("Your removals")
            .toolbar { Button("Done") { dismiss() }.disabled(model.isDeleting) }
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive) {
                    Task {
                        await model.deleteBasket()
                        if model.removalCount == 0 && model.errorMessage == nil { dismiss() }
                    }
                } label: {
                    if model.isDeleting { ProgressView() }
                    else { Text(model.removalCount == 1 ? "Remove 1 photo" : "Remove \(model.removalCount) photos").font(.headline) }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.removalCount == 0 || model.isDeleting)
                    .padding().frame(maxWidth: .infinity).background(.bar)
            }
            .interactiveDismissDisabled(model.isDeleting)
        }
    }
}

struct HistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach([ReviewGroup.Status.deferred, .keptAll], id: \.rawValue) { status in
                    Section(status == .deferred ? "Decide later" : "Kept everything") {
                        ForEach(model.groups.filter { $0.status == status }) { group in
                            NavigationLink { GroupReviewView(model: model, initialGroup: group) } label: {
                                GroupRow(group: group, library: model.library)
                            }
                        }
                    }
                }
            }.navigationTitle("Past decisions").toolbar { Button("Done") { dismiss() } }
        }
    }
}
