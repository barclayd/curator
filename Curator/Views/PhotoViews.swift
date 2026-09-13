import SwiftUI
import PhotosUI
import CuratorCore

struct PhotoThumbnail: View {
    let id: String
    let library: any PhotoLibraryAccess
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .task(id: id) {
            image = nil
            if let cgImage = try? await library.image(for: id, dimension: 384, network: false), !Task.isCancelled {
                image = UIImage(cgImage: cgImage)
            }
        }
    }
}

struct PhotoInspector: View {
    let photos: [PhotoRecord]
    @State var selectedID: String
    let library: any PhotoLibraryAccess
    let network: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var compare = false
    var body: some View {
        NavigationStack {
            Group {
                if compare {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))]) {
                            ForEach(photos) { photo in
                                InspectionImage(photo: photo, library: library, network: network).frame(height: 320)
                            }
                        }.padding()
                    }
                } else {
                    TabView(selection: $selectedID) {
                        ForEach(photos) { photo in
                            InspectionImage(photo: photo, library: library, network: network).tag(photo.id)
                        }
                    }.tabViewStyle(.page)
                }
            }
            .navigationTitle(compare ? "Compare photos" : "Photo \((photos.firstIndex(where: { $0.id == selectedID }) ?? 0) + 1) of \(photos.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(compare ? "Single photo" : "Compare") { compare.toggle() } }
            }
        }
    }
}

private struct InspectionImage: View {
    let photo: PhotoRecord
    let library: any PhotoLibraryAccess
    let network: Bool
    @State private var image: UIImage?
    @State private var error: String?
    @State private var playing = false
    var body: some View {
        VStack(spacing: 12) {
            if playing { LivePlayback(id: photo.id, network: network) }
            else if let image { ZoomablePhoto(image: image).accessibilityLabel("Photo. Pinch to zoom.") }
            else if let error { ContentUnavailableView("Photo isn't ready", systemImage: "icloud", description: Text(error)) }
            else { ProgressView("Loading photo") }
            if photo.isLive {
                Button(playing ? "Show still photo" : "Play Live Photo with sound", systemImage: "livephoto") { playing.toggle() }
                    .buttonStyle(.bordered).padding(.bottom)
            }
        }
        .task(id: photo.id) {
            do { image = UIImage(cgImage: try await library.image(for: photo.id, dimension: 2048, network: network)) }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.delegate = context.coordinator
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit; view.tag = 1
        scroll.addSubview(view)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let view = scroll.viewWithTag(1) as? UIImageView else { return }
        view.image = image
        if scroll.zoomScale == 1 { view.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
        DispatchQueue.main.async {
            if scroll.zoomScale == 1 { view.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { scrollView.viewWithTag(1) }
    }
}

private struct LivePlayback: UIViewRepresentable {
    let id: String
    let network: Bool
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return view }
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = network
        options.deliveryMode = .highQualityFormat
        context.coordinator.request = PHImageManager.default().requestLivePhoto(for: asset,
            targetSize: CGSize(width: 1600, height: 1600), contentMode: .aspectFit, options: options) { [weak view] photo, info in
                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                Task { @MainActor in
                    view?.livePhoto = photo; view?.isMuted = false; view?.startPlayback(with: .full)
                }
            }
        return view
    }
    func updateUIView(_ view: PHLivePhotoView, context: Context) {}
    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        if let id = coordinator.request { PHImageManager.default().cancelImageRequest(id) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var request: PHImageRequestID? }
}
