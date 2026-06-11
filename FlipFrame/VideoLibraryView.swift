import Photos
import SwiftUI

@MainActor
final class VideoLibraryViewModel: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var isLoading = true

    let imageManager = PHCachingImageManager()
    
    static let cacheSize = CGSize(width: 250, height: 250)
    static let cacheContentMode = PHImageContentMode.aspectFill

    private static var cachedAllAssets: PHFetchResult<PHAsset>?
    private var allAssets: PHFetchResult<PHAsset>?
    private var isLoadingMore = false
    private let pageSize = 60

    static func prewarmIfAllowed() async {
        guard cachedAllAssets == nil else { return }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        cachedAllAssets = fetchRecentVideosResult()
    }

    func loadVideos() {
        if let cached = Self.cachedAllAssets {
            self.allAssets = cached
            self.loadFirstPage(from: cached)
            self.isLoading = false
        } else {
            self.isLoading = true
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.authorizationStatus = status

        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                DispatchQueue.main.async {
                    self?.authorizationStatus = newStatus
                    if newStatus == .authorized || newStatus == .limited {
                        self?.fetchAndCacheVideos()
                    } else {
                        self?.isLoading = false
                    }
                }
            }
        } else if status == .authorized || status == .limited {
            fetchAndCacheVideos()
        } else {
            isLoading = false
        }
    }

    private func loadFirstPage(from result: PHFetchResult<PHAsset>) {
        let firstPageSize = min(pageSize, result.count)
        var firstPageAssets: [PHAsset] = []
        for i in 0..<firstPageSize {
            firstPageAssets.append(result.object(at: i))
        }
        self.assets = firstPageAssets

        // Cache the first page thumbnails in the background
        let cacheManager = self.imageManager
        let targetSize = Self.cacheSize
        let contentMode = Self.cacheContentMode

        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            cacheManager.startCachingImages(
                for: firstPageAssets,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            )
        }
    }

    private func fetchAndCacheVideos() {
        let result = Self.fetchRecentVideosResult()
        self.allAssets = result
        Self.cachedAllAssets = result

        // If we already have loaded some assets and the new query count matches,
        // check if we can skip the reload to avoid flickering.
        if !assets.isEmpty && result.count > 0 {
            if assets[0].localIdentifier == result.firstObject?.localIdentifier {
                self.isLoading = false
                return
            }
        }

        loadFirstPage(from: result)
        self.isLoading = false
    }

    func loadMoreIfNeeded(currentAsset: PHAsset) {
        guard let allAssets = allAssets else { return }
        guard !isLoadingMore else { return }

        let thresholdIndex = assets.count - 15
        guard let currentIndex = assets.firstIndex(where: { $0.localIdentifier == currentAsset.localIdentifier }),
              currentIndex >= thresholdIndex else { return }

        loadNextPage()
    }

    private func loadNextPage() {
        guard let allAssets = allAssets else { return }
        let currentLoaded = assets.count
        guard currentLoaded < allAssets.count else { return }

        isLoadingMore = true

        let nextLimit = min(currentLoaded + pageSize, allAssets.count)
        var newAssets: [PHAsset] = []
        for i in currentLoaded..<nextLimit {
            newAssets.append(allAssets.object(at: i))
        }

        self.assets.append(contentsOf: newAssets)
        self.isLoadingMore = false

        // Cache the new page thumbnails in the background
        let cacheManager = self.imageManager
        let targetSize = Self.cacheSize
        let contentMode = Self.cacheContentMode

        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            cacheManager.startCachingImages(
                for: newAssets,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            )
        }
    }

    private nonisolated static func fetchRecentVideosResult() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .video, options: options)
    }

    var thumbnailOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        return options
    }
}

struct VideoLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VideoLibraryViewModel()
    @State private var selectedAsset: PHAsset?
    @State private var selectedImage: UIImage?

    let onSelect: (PHAsset, UIImage?) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        GeometryReader { proxy in
            let scale = min(max(proxy.size.height / 852, 0.78), 1.0)
            let bottomInset = proxy.safeAreaInsets.bottom

            ZStack(alignment: .bottom) {
                // Background deep dark theme
                Color(red: 0.03, green: 0.03, blue: 0.08)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Custom Premium Header
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15 * scale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 36 * scale, height: 36 * scale)
                                .background(.white.opacity(0.08), in: Circle())
                                .overlay {
                                    Circle()
                                        .stroke(.white.opacity(0.12), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text("Select Video")
                            .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Spacer()

                        // Balanced empty element
                        Color.clear
                            .frame(width: 36 * scale, height: 36 * scale)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14 * scale)
                    .background(Color(red: 0.05, green: 0.05, blue: 0.12).opacity(0.92))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.15), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 1)
                    }

                    // Main Content
                    Group {
                        if viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted {
                            permissionView(scale: scale)
                        } else if viewModel.isLoading {
                            loadingView
                        } else if viewModel.assets.isEmpty {
                            emptyView
                        } else {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(viewModel.assets, id: \.localIdentifier) { asset in
                                        VideoThumbnailView(
                                            asset: asset,
                                            imageManager: viewModel.imageManager,
                                            options: viewModel.thumbnailOptions,
                                            isSelected: selectedAsset?.localIdentifier == asset.localIdentifier
                                        ) { image in
                                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                                selectedAsset = asset
                                                selectedImage = image
                                            }
                                        }
                                        .onAppear {
                                            viewModel.loadMoreIfNeeded(currentAsset: asset)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, selectedAsset == nil ? 16 : 94)
                            }
                        }
                    }
                }

                // Wide Floating Gradient "Add" Button
                if let selectedAsset {
                    VStack {
                        Spacer()

                        Button {
                            dismiss()
                            onSelect(selectedAsset, selectedImage)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18 * scale, weight: .bold))
                                Text("Add Video")
                                    .font(.system(size: 16 * scale, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15 * scale)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.05, green: 0.55, blue: 1.0),
                                        Color(red: 0.46, green: 0.22, blue: 1.0),
                                        Color(red: 1.0, green: 0.18, blue: 0.86)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(
                                        LinearGradient(
                                            colors: [.white.opacity(0.4), .clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 1
                                    )
                            }
                            .shadow(color: .blue.opacity(0.35), radius: 12, y: 5)
                            .shadow(color: .pink.opacity(0.25), radius: 12, y: 5)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .padding(.bottom, max(16, bottomInset))
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            viewModel.loadVideos()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            viewModel.loadVideos()
        }
    }

    private func permissionView(scale: CGFloat) -> some View {
        VStack(spacing: 24 * scale) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.pink.opacity(0.12), Color.purple.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 120 * scale, height: 120 * scale)
                    .overlay {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.pink.opacity(0.24), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.5
                            )
                    }
                
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 44 * scale))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.20, blue: 0.85),
                                Color(red: 0.46, green: 0.22, blue: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .offset(x: -5 * scale, y: -5 * scale)
                
                Image(systemName: "lock.fill")
                    .font(.system(size: 20 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8 * scale)
                    .background(Color.pink, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.white, lineWidth: 2 * scale)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .offset(x: 24 * scale, y: 24 * scale)
            }
            .padding(.bottom, 8 * scale)
            
            VStack(spacing: 8 * scale) {
                Text("Photos Access Required")
                    .font(.system(size: 22 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                
                Text("FlipFrame needs access to your library to import and convert videos. Please enable photo library permissions in Settings.")
                    .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4 * scale)
                    .padding(.horizontal, 40)
            }
            
            Button {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            } label: {
                HStack(spacing: 8 * scale) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15 * scale, weight: .bold))
                    Text("Open Settings")
                        .font(.system(size: 15 * scale, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32 * scale)
                .padding(.vertical, 14 * scale)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.65, blue: 1.0),
                            Color(red: 0.46, green: 0.22, blue: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: Color.blue.opacity(0.35), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.white)
            Text("Loading videos...")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.3))
            Text("No Videos Found")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("There are no videos in your photo library.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VideoThumbnailView: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager
    let options: PHImageRequestOptions
    let isSelected: Bool
    let onTap: (UIImage?) -> Void

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Button {
            onTap(image)
        } label: {
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height

                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(white: 0.12))
                        .frame(width: w, height: h)

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: w, height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(durationText)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .foregroundStyle(.white)
                    .background(.ultraThinMaterial.opacity(0.68), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                    .padding(6)
                }
                .frame(width: w, height: h)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(isSelected ? 0.94 : 1.0)
            .shadow(color: isSelected ? .blue.opacity(0.24) : .clear, radius: 8, y: 4)
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(red: 1.0, green: 0.20, blue: 0.85))
                        .padding(7)
                        .shadow(color: .black.opacity(0.25), radius: 4)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ?
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.65, blue: 1.0),
                                Color(red: 1.0, green: 0.20, blue: 0.85)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ) : LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: isSelected ? 3 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            if let requestID {
                imageManager.cancelImageRequest(requestID)
                self.requestID = nil
            }
        }
    }

    private var durationText: String {
        let totalSeconds = max(0, Int(asset.duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func loadThumbnail() {
        guard requestID == nil, image == nil else { return }

        requestID = imageManager.requestImage(
            for: asset,
            targetSize: VideoLibraryViewModel.cacheSize,
            contentMode: VideoLibraryViewModel.cacheContentMode,
            options: options
        ) { result, info in
            guard let result = result else { return }

            let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            guard !isCancelled else { return }

            if Thread.isMainThread {
                self.image = result
            } else {
                DispatchQueue.main.async {
                    self.image = result
                }
            }
        }
    }
}
