import AVKit
import Combine
import Photos
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
    @Published var selectedAsset: PHAsset?
    @Published var previewImage: UIImage?
    @Published var selectedFormat: FrameFormat = .landscape
    @Published var selectedQuality: ExportQuality = .medium
    @Published var exportProgress = 0.0
    @Published var isProcessing = false
    @Published var statusMessage = NSLocalizedString("Choose a video to begin.", comment: "")
    @Published var errorMessage: String?
    @Published var exportedURL: URL?
    @Published var exportedPlayer: AVPlayer?
    @Published var savePopup = SavePopupState.idle
    @Published var removesWatermark = StoreManager.shared.isPurchased
    @Published var selectedVideoAsset: AVAsset?
    @Published var originalAspectRatio: CGFloat = 1
    @Published var didFinishExportAction = false

    private var cancellables = Set<AnyCancellable>()
    private let exporter = VideoExporter()

    var canExport: Bool {
        selectedAsset != nil && !isProcessing
    }

    init() {
        StoreManager.shared.$isPurchased
            .receive(on: RunLoop.main)
            .sink { [weak self] isPurchased in
                self?.removesWatermark = isPurchased
            }
            .store(in: &cancellables)
    }

    func selectVideo(_ asset: PHAsset, posterImage: UIImage?) {
        selectedAsset = asset
        previewImage = posterImage
        selectedVideoAsset = nil // Reset cache
        exportedURL = nil
        exportedPlayer = nil
        exportProgress = 0
        savePopup = .idle
        originalAspectRatio = asset.sourceDisplaySize.width / max(asset.sourceDisplaySize.height, 1)
        didFinishExportAction = false
        errorMessage = nil
        statusMessage = NSLocalizedString("Choose an aspect ratio and quality.", comment: "")
        isProcessing = false

        Task {
            do {
                // Fetch high-quality AVAsset exactly ONCE in background
                let videoAsset = try await exporter.videoAsset(for: asset)
                
                // Get size once from videoAsset track transform
                if let size = exporter.sourceDisplaySize(for: videoAsset) {
                    originalAspectRatio = size.width / max(size.height, 1)
                } else {
                    originalAspectRatio = asset.sourceDisplaySize.width / max(asset.sourceDisplaySize.height, 1)
                }
                
                // Generate poster image only if not already passed
                if previewImage == nil {
                    previewImage = try? await exporter.generatePosterImage(for: videoAsset)
                }
                
                // Cache the videoAsset
                self.selectedVideoAsset = videoAsset
            } catch {
                // Background loading failed, but we will retry/handle on Export
                print("Background asset loading failed: \(error.localizedDescription)")
            }
        }
    }

    func clearSelection() {
        selectedAsset = nil
        selectedVideoAsset = nil // Clear cache
        previewImage = nil
        exportedURL = nil
        exportedPlayer = nil
        exportProgress = 0
        savePopup = .idle
        originalAspectRatio = 1
        didFinishExportAction = false
        errorMessage = nil
        statusMessage = NSLocalizedString("Choose a video to begin.", comment: "")
    }

    func resetExportedVideo() {
        exportedURL = nil
        exportedPlayer = nil
        exportProgress = 0
        savePopup = .idle
        didFinishExportAction = false
    }

    func exportVideo() async {
        guard let selectedAsset else {
            statusMessage = NSLocalizedString("Choose a video first.", comment: "")
            return
        }

        isProcessing = true
        exportProgress = 0
        errorMessage = nil
        didFinishExportAction = false
        statusMessage = String(format: NSLocalizedString("Converting video... %d%%", comment: ""), 0)

        do {
            let asset: AVAsset
            if let cached = selectedVideoAsset {
                asset = cached
            } else {
                statusMessage = NSLocalizedString("Loading video details...", comment: "")
                asset = try await exporter.videoAsset(for: selectedAsset)
                self.selectedVideoAsset = asset
            }
            let url = try await exporter.export(
                asset: asset,
                format: selectedFormat,
                quality: selectedQuality,
                includeWatermark: !removesWatermark
            ) { [weak self] progress in
                self?.exportProgress = progress
                self?.statusMessage = String(format: NSLocalizedString("Converting video... %d%%", comment: ""), Int(progress * 100))
            }

            exportedURL = url
            exportedPlayer = AVPlayer(url: url)
            exportProgress = 1
            statusMessage = NSLocalizedString("Video is ready.", comment: "")
            savePopup = .actions
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = NSLocalizedString("Conversion failed.", comment: "")
        }

        isProcessing = false
    }

    func saveExportedVideo() async {
        guard let exportedURL else {
            statusMessage = NSLocalizedString("There is no video to save.", comment: "")
            savePopup = .failed(NSLocalizedString("There is no video to save.", comment: ""))
            return
        }

        isProcessing = true
        savePopup = .saving
        errorMessage = nil
        statusMessage = NSLocalizedString("Saving to Photos...", comment: "")

        do {
            try await exporter.saveToPhotoLibrary(exportedURL)
            didFinishExportAction = true
            statusMessage = NSLocalizedString("Video saved to Photos.", comment: "")
            savePopup = .saved
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = NSLocalizedString("Save failed.", comment: "")
            savePopup = .failed(error.localizedDescription)
        }

        isProcessing = false
    }

    func showExportActions() {
        guard exportedURL != nil else {
            statusMessage = NSLocalizedString("Export the video first.", comment: "")
            savePopup = .failed(NSLocalizedString("There is no video to save.", comment: ""))
            return
        }

        savePopup = .actions
    }

    func markShared() {
        didFinishExportAction = true
        statusMessage = NSLocalizedString("Video is ready to share.", comment: "")
    }

    func requestWatermarkRemoval() {
        statusMessage = "Watermark removal purchase will be connected with StoreKit."
    }
}

enum SavePopupState: Equatable {
    case idle
    case actions
    case saving
    case saved
    case failed(String)

    var isPresented: Bool {
        self != .idle
    }

    var title: String {
        switch self {
        case .idle:
            ""
        case .actions:
            NSLocalizedString("Video Ready", comment: "")
        case .saving:
            NSLocalizedString("Saving", comment: "")
        case .saved:
            NSLocalizedString("Saved", comment: "")
        case .failed:
            NSLocalizedString("Could Not Save", comment: "")
        }
    }

    var message: String {
        switch self {
        case .idle:
            ""
        case .actions:
            NSLocalizedString("Save the video to Photos or share it now.", comment: "")
        case .saving:
            NSLocalizedString("Saving video to Photos.", comment: "")
        case .saved:
            NSLocalizedString("Video saved to Photos.", comment: "")
        case .failed(let message):
            message
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @State private var isLibraryPresented = false
    @State private var isPaywallPresented = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    private let privacyPolicyURL = URL(string: "https://flipframe.app/privacy")!
    private let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        Group {
            if !hasSeenOnboarding {
                OnboardingView {
                    hasSeenOnboarding = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        isLibraryPresented = true
                    }
                }
            } else if viewModel.selectedAsset == nil {
                startView
            } else {
                exportView
            }
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $isLibraryPresented) {
            VideoLibraryView { asset, image in
                isLibraryPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    viewModel.selectVideo(asset, posterImage: image)
                }
            }
        }
        .sheet(isPresented: $isPaywallPresented) {
            PremiumPaywallView(viewModel: viewModel)
        }
        .overlay {
            savePopupOverlay
        }
        .task {
            await VideoLibraryViewModel.prewarmIfAllowed()
        }
    }

    @ViewBuilder
    private var savePopupOverlay: some View {
        if viewModel.savePopup.isPresented {
            ZStack {
                Color.black.opacity(0.58)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if viewModel.savePopup != .saving {
                            viewModel.savePopup = .idle
                        }
                    }

                SaveStatusView(
                    state: viewModel.savePopup,
                    exportedURL: viewModel.exportedURL,
                    save: {
                        Task { await viewModel.saveExportedVideo() }
                    },
                    share: {
                        viewModel.markShared()
                    },
                    dismiss: {
                        viewModel.savePopup = .idle
                    }
                )
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
    }

    private var startView: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let compactScale = min(max(height / 852, 0.78), 1.0)
            let horizontalPadding: CGFloat = 24
            let topPadding: CGFloat = 14
            let bottomPadding: CGFloat = 12

            ZStack {
                PremiumHomeBackground()
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 12 * compactScale) {
                    VStack(alignment: .leading, spacing: 10 * compactScale) {
                        // Advanced Rotator Pro Tag
                        HStack(spacing: 5 * compactScale) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11 * compactScale, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.cyan, .pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Text("ADVANCED ROTATOR")
                                .font(.system(size: 10 * compactScale, weight: .black, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.cyan, .purple, .pink],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .tracking(1.8)
                        }
                        .padding(.horizontal, 9 * compactScale)
                        .padding(.vertical, 4 * compactScale)
                        .background(.ultraThinMaterial.opacity(0.42), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.15), .clear, .white.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        }

                        // Combined bold/neon title
                        (Text("Flip")
                            .foregroundStyle(.white) +
                         Text("Frame")
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.12, green: 0.65, blue: 1.0),
                                        Color(red: 0.60, green: 0.30, blue: 1.0),
                                        Color(red: 1.0, green: 0.20, blue: 0.85)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                        .font(.system(size: 50 * compactScale, weight: .black, design: .rounded))
                        .shadow(color: .pink.opacity(0.35), radius: 12, x: 0, y: 4)
                        .shadow(color: .blue.opacity(0.25), radius: 12, x: 0, y: 4)
                        
                        // Sleek subtitle with indicator dot
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6 * compactScale, height: 6 * compactScale)
                                .shadow(color: .green.opacity(0.8), radius: 3)
                            
                            Text("Rotate videos. Expand your story.")
                                .font(.system(size: 16 * compactScale, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.64))
                        }
                        .padding(.leading, 2)
                    }

                    FlipFrameHeroView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 268 * compactScale)
                        .padding(.bottom, 22 * compactScale)

                    HomeActionCard(scale: compactScale) {
                        isLibraryPresented = true
                    }

                    Spacer(minLength: 8 * compactScale)

                    VStack(alignment: .leading, spacing: 10 * compactScale) {
                        Text("Quick Features")
                            .font(.system(size: 18 * compactScale, weight: .semibold))
                            .foregroundStyle(.white)

                        HStack(spacing: 10) {
                            HomeFeatureCard(
                                iconName: "bolt.fill",
                                title: "Fast Conversion",
                                subtitle: "Convert in seconds",
                                scale: compactScale
                            )

                            HomeFeatureCard(
                                iconName: "movieclapper.fill",
                                title: "HD Quality",
                                subtitle: "No quality loss",
                                scale: compactScale
                            )

                            HomeFeatureCard(
                                iconName: "lock.shield.fill",
                                title: "Private & Secure",
                                subtitle: "On your device",
                                scale: compactScale
                            )
                        }

                        HStack(spacing: 14 * compactScale) {
                            Link(destination: privacyPolicyURL) {
                                Label("Privacy Policy", systemImage: "lock.shield")
                            }

                            Circle()
                                .fill(.white.opacity(0.28))
                                .frame(width: 3 * compactScale, height: 3 * compactScale)

                            Link(destination: termsOfUseURL) {
                                Label("Terms of Use", systemImage: "doc.text")
                            }
                        }
                        .font(.system(size: 12 * compactScale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2 * compactScale)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .top
                )
            }
        }
    }

    private var exportView: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let scale = min(max(height / 852, 0.78), 1.0)

            Group {
                if viewModel.isProcessing && viewModel.exportedURL == nil {
                    conversionProgressView(proxy: proxy, scale: scale)
                } else {
                    ZStack {
                        PremiumHomeBackground()
                            .ignoresSafeArea()

                        VStack(spacing: 0) {
                            exportHeader(scale: scale, topInset: 12 * scale)
                                .padding(.bottom, 12 * scale)
                                .zIndex(2)

                            premiumVideoPreview(
                                maxWidth: proxy.size.width - 40,
                                maxHeight: 320 * scale,
                                scale: scale
                            )
                            .allowsHitTesting(false)
                            .zIndex(0)

                            Spacer(minLength: 12 * scale)

                            VStack(alignment: .leading, spacing: 14 * scale) {
                                premiumFormatPicker(scale: scale)
                                premiumQualityPicker(scale: scale)
                                premiumInfoRow(scale: scale)
                                premiumWatermarkRemovalButton(scale: scale)
                                premiumPrimaryAction(scale: scale)
                                premiumPrivacyFooter(scale: scale)
                                statusArea
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 10))
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    }
                }
            }
        }
    }

    private func conversionProgressView(proxy: GeometryProxy, scale: CGFloat) -> some View {
        let progress = min(max(viewModel.exportProgress, 0), 1)

        return ZStack {
            PremiumHomeBackground()
                .ignoresSafeArea()

            VStack(spacing: 18 * scale) {
                progressHeader(scale: scale, topInset: 12 * scale)

                ConversionHeroView(
                    image: viewModel.previewImage,
                    inputAspectRatio: viewModel.originalAspectRatio,
                    outputFormat: viewModel.selectedFormat,
                    scale: scale
                )
                .frame(maxWidth: .infinity)
                .frame(height: 360 * scale)
                .padding(.top, 8 * scale)
                .padding(.bottom, 4 * scale)

                VStack(spacing: 9 * scale) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 76 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(premiumSelectedGradient)
                        .shadow(color: .purple.opacity(0.4), radius: 18, y: 8)

                    Text("Converting your video...")
                        .font(.system(size: 24 * scale, weight: .bold))
                        .foregroundStyle(.white)

                    Text("This may take a few seconds.")
                        .font(.system(size: 16 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }

                PremiumProgressBar(progress: progress, scale: scale)
                    .frame(height: 30 * scale)
                    .padding(.top, 8 * scale)

                LocalProcessingCard(scale: scale)
                    .padding(.top, 10 * scale)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private func progressHeader(scale: CGFloat, topInset: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 5 * scale) {
                Text("Converting")
                    .font(.system(size: 34 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(premiumSelectedGradient)

                Text("Please don't close the app")
                    .font(.system(size: 16 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .allowsHitTesting(false)

            HStack {
                Button {
                    viewModel.clearSelection()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 21 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 54 * scale, height: 54 * scale)
                        .background(.ultraThinMaterial.opacity(0.46), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(true)

                Spacer()
            }
        }
        .padding(.top, topInset)
    }

    private func exportHeader(scale: CGFloat, topInset: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 3 * scale) {
                (Text("Flip")
                    .foregroundStyle(.white) +
                 Text("Frame")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.65, blue: 1.0),
                                Color(red: 0.60, green: 0.30, blue: 1.0),
                                Color(red: 1.0, green: 0.20, blue: 0.85)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                )
                .font(.system(size: 28 * scale, weight: .black, design: .rounded))
                .shadow(color: .pink.opacity(0.25), radius: 8, x: 0, y: 3)

                Text("Rotate videos. Expand your story.")
                    .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .allowsHitTesting(false)

            HStack {
                Button {
                    isLibraryPresented = true
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 50 * scale, height: 50 * scale)
                        .background(.ultraThinMaterial.opacity(0.65), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.24), .clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                    }
                    .shadow(color: .black.opacity(0.25), radius: 6)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isProcessing)

                Spacer()
            }
        }
        .padding(.top, topInset)
    }

    private func premiumVideoPreview(maxWidth: CGFloat, maxHeight: CGFloat, scale: CGFloat) -> some View {
        let size = previewSize(maxWidth: maxWidth, maxHeight: maxHeight)

        return ZStack {
            ZStack {
                // Metallic bezeled frame background
                RoundedRectangle(cornerRadius: 30 * scale, style: .continuous)
                    .fill(Color(white: 0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 30 * scale, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color(white: 0.95),
                                        Color(white: 0.45),
                                        Color(white: 0.85),
                                        Color(white: 0.30),
                                        Color(white: 0.95)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 3 * scale
                            )
                    }
                    .shadow(color: .blue.opacity(0.35), radius: 18, x: -6, y: 8)
                    .shadow(color: .pink.opacity(0.25), radius: 20, x: 6, y: 8)

                // Inner video/image content
                ZStack {
                    if let player = viewModel.exportedPlayer {
                        VideoPlayer(player: player)
                    } else if let image = viewModel.previewImage {
                        OutputPreview(image: image, originalAspectRatio: currentOriginalAspectRatio)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 26 * scale, style: .continuous))
                .padding(4.5 * scale) // Sit inside the metal bezel

                // Play Button: Glassmorphic and glowing
                ZStack {
                    // Glow
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.cyan, .purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58 * scale, height: 58 * scale)
                        .blur(radius: 12 * scale)
                        .opacity(0.70)
                    
                    // Base
                    Circle()
                        .fill(.ultraThinMaterial.opacity(0.70))
                        .overlay {
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.8), .cyan.opacity(0.4), .pink.opacity(0.6)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.8 * scale
                                )
                        }
                        .frame(width: 60 * scale, height: 60 * scale)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    
                    Image(systemName: "play.fill")
                        .font(.system(size: 22 * scale, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(red: 0.8, green: 0.95, blue: 1.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .offset(x: 2 * scale)
                }

                // Aspect ratio pill (bottom-left)
                HStack(spacing: 8 * scale) {
                    Image(systemName: viewModel.selectedFormat.iconName)
                        .font(.system(size: 16 * scale, weight: .bold))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatLabel)
                            .font(.system(size: 13 * scale, weight: .black, design: .rounded))

                        Text(viewModel.selectedFormat.subtitle)
                            .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14 * scale)
                .padding(.vertical, 8 * scale)
                .background(.ultraThinMaterial.opacity(0.65), in: RoundedRectangle(cornerRadius: 16 * scale, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(18 * scale)

                // Duration pill (bottom-right)
                Text(durationText)
                    .font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12 * scale)
                    .padding(.vertical, 8 * scale)
                    .background(.ultraThinMaterial.opacity(0.65), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(18 * scale)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: maxWidth, height: maxHeight)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func previewMaxHeight(for screenHeight: CGFloat) -> CGFloat {
        min(screenHeight * 0.34, 290)
    }

    private func previewSize(maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let aspectRatio = viewModel.selectedFormat.aspectRatio
        var width = maxWidth
        var height = width / aspectRatio

        if height > maxHeight {
            height = maxHeight
            width = height * aspectRatio
        }

        return CGSize(width: width, height: height)
    }

    private var currentOriginalAspectRatio: CGFloat {
        guard let asset = viewModel.selectedAsset else { return 1 }

        let width = CGFloat(max(asset.pixelWidth, 1))
        let height = CGFloat(max(asset.pixelHeight, 1))
        return width / height
    }

    private var durationText: String {
        guard let asset = viewModel.selectedAsset else { return "00:00" }

        let totalSeconds = max(0, Int(asset.duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var formatLabel: String {
        switch viewModel.selectedFormat {
        case .landscape:
            "Landscape"
        case .portrait:
            "Portrait"
        case .square:
            "Square"
        }
    }

    private func premiumFormatPicker(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text("Aspect Ratio")
                .font(.system(size: 17 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, 4 * scale)

            HStack(spacing: 0) {
                ForEach(FrameFormat.allCases) { format in
                    Button {
                        viewModel.selectedFormat = format
                        viewModel.resetExportedVideo()
                    } label: {
                        HStack(spacing: 8 * scale) {
                            Image(systemName: format.iconName)
                                .font(.system(size: 16 * scale, weight: .bold))

                            Text(format.subtitle)
                                .font(.system(size: 16 * scale, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14 * scale)
                        .background {
                            if viewModel.selectedFormat == format {
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.05, green: 0.55, blue: 1.0),
                                        Color(red: 0.46, green: 0.22, blue: 1.0),
                                        Color(red: 1.0, green: 0.18, blue: 0.86)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 18 * scale, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                                        .stroke(
                                            LinearGradient(
                                                colors: [.white.opacity(0.4), .clear],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 1
                                        )
                                }
                                .shadow(color: .blue.opacity(0.4), radius: 12, y: 4)
                            }
                        }
                        .foregroundStyle(viewModel.selectedFormat == format ? .white : .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6 * scale)
            .background(.ultraThinMaterial.opacity(0.58), in: RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func premiumQualityPicker(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text("Quality")
                .font(.system(size: 17 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, 4 * scale)

            HStack(spacing: 0) {
                ForEach(ExportQuality.allCases) { quality in
                    Button {
                        viewModel.selectedQuality = quality
                        viewModel.resetExportedVideo()
                    } label: {
                        VStack(spacing: 3 * scale) {
                            Text(quality.title)
                                .font(.system(size: 15 * scale, weight: .bold, design: .rounded))

                            Text(estimatedOutputSizeText(for: quality))
                                .font(.system(size: 10 * scale, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .foregroundStyle(viewModel.selectedQuality == quality ? .white.opacity(0.78) : .white.opacity(0.42))
                        }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10 * scale)
                            .background {
                                if viewModel.selectedQuality == quality {
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.05, green: 0.55, blue: 1.0),
                                            Color(red: 0.46, green: 0.22, blue: 1.0),
                                            Color(red: 1.0, green: 0.18, blue: 0.86)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 18 * scale, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                                            .stroke(
                                                LinearGradient(
                                                    colors: [.white.opacity(0.4), .clear],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                ),
                                                lineWidth: 1
                                            )
                                    }
                                    .shadow(color: .purple.opacity(0.38), radius: 12, y: 4)
                                }
                            }
                            .foregroundStyle(viewModel.selectedQuality == quality ? .white : .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6 * scale)
            .background(.ultraThinMaterial.opacity(0.58), in: RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func premiumInfoRow(scale: CGFloat) -> some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "wand.and.stars")
            Text("High quality with no noticeable loss.")
        }
        .font(.system(size: 14 * scale, weight: .medium))
        .foregroundStyle(.white.opacity(0.62))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func premiumWatermarkRemovalButton(scale: CGFloat) -> some View {
        if !viewModel.removesWatermark {
            Button {
                isPaywallPresented = true
            } label: {
                HStack(spacing: 12 * scale) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial.opacity(0.72))
                            .frame(width: 38 * scale, height: 38 * scale)

                        Image(systemName: "sparkles")
                            .font(.system(size: 16 * scale, weight: .bold))
                            .foregroundStyle(premiumSelectedGradient)
                    }

                    VStack(alignment: .leading, spacing: 2 * scale) {
                        Text("Remove Watermark")
                            .font(.system(size: 15 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("One-time purchase")
                            .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.56))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13 * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .padding(.horizontal, 14 * scale)
                .padding(.vertical, 10 * scale)
                .background(.ultraThinMaterial.opacity(0.54), in: RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.blue.opacity(0.45), .purple.opacity(0.3), .pink.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1
                        )
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func premiumPrimaryAction(scale: CGFloat) -> some View {
        Button {
            if viewModel.exportedURL == nil {
                Task { await viewModel.exportVideo() }
            } else {
                viewModel.showExportActions()
            }
        } label: {
            Label(primaryActionTitle, systemImage: primaryActionIcon)
                .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18 * scale)
                .background {
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.55, blue: 1.0),
                            Color(red: 0.46, green: 0.22, blue: 1.0),
                            Color(red: 1.0, green: 0.18, blue: 0.86)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.45), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.5 * scale
                        )
                }
                .shadow(color: .blue.opacity(0.45), radius: 16, y: 6)
                .shadow(color: .pink.opacity(0.32), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isProcessing || (viewModel.selectedAsset == nil))
        .opacity(viewModel.isProcessing ? 0.78 : 1)
    }

    private func premiumPrivacyFooter(scale: CGFloat) -> some View {
        HStack(spacing: 14 * scale) {
            ZStack {
                Circle()
                    .fill(Color(white: 0.08))
                    .overlay {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5 * scale
                            )
                    }
                
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18 * scale, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 44 * scale, height: 44 * scale)
            .shadow(color: .blue.opacity(0.2), radius: 6)

            VStack(alignment: .leading, spacing: 3 * scale) {
                Text("Processed locally on your device.")
                    .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                
                Text("No upload. No waiting.")
                    .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isProcessing {
                ProgressView(value: viewModel.exportProgress)
            }

            if viewModel.statusMessage != "Choose an aspect ratio and quality." && viewModel.statusMessage != "Choose a video to begin." {
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var premiumSelectedGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.55, blue: 1.0),
                Color(red: 0.43, green: 0.23, blue: 1.0),
                Color(red: 1.0, green: 0.13, blue: 0.86)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var primaryActionTitle: String {
        if viewModel.isProcessing {
            let percentage = Int(viewModel.exportProgress * 100)
            let format = NSLocalizedString("Exporting %d%%", comment: "")
            return String(format: format, percentage)
        }

        if viewModel.exportedURL == nil {
            return NSLocalizedString("Export Video", comment: "")
        }

        return NSLocalizedString("Save / Share", comment: "")
    }

    private var primaryActionIcon: String {
        if viewModel.exportedURL == nil {
            return "wand.and.stars"
        }

        return "square.and.arrow.up"
    }

    private func estimatedOutputSizeText(for quality: ExportQuality) -> String {
        guard let asset = viewModel.selectedAsset else {
            return "~-- MB"
        }

        let audioBitrateMbps = 0.16
        let totalMegabits = asset.duration * (quality.estimatedVideoBitrateMbps(for: asset.sourceDisplaySize) + audioBitrateMbps)
        let megabytes = max(1, totalMegabits / 8)

        if megabytes >= 100 {
            return "~\(Int(megabytes.rounded())) MB"
        }

        return String(format: "~%.1f MB", megabytes)
    }
}

private extension PHAsset {
    var sourceDisplaySize: CGSize {
        CGSize(width: CGFloat(max(pixelWidth, 1)), height: CGFloat(max(pixelHeight, 1)))
    }
}

private struct OnboardingView: View {
    let finish: () -> Void

    @State private var pageIndex = 0

    private let pages: [OnboardingPage] = [
        .init(titlePrefix: "Select Your ", titleSuffix: "Video_Suffix", subtitle: "Import any video from your Photo Library in one tap.", visual: .logo, actionTitle: "Next"),
        .init(titlePrefix: "Smart ", titleSuffix: "Analysis", subtitle: "FlipFrame automatically scans the aspect ratio and frame rate.", visual: .wrongAspect, actionTitle: "Next"),
        .init(titlePrefix: "Choose Your ", titleSuffix: "Format_Suffix", subtitle: "Toggle between portrait for TikTok and landscape for YouTube instantly.", visual: .portraitToLandscape, actionTitle: "Next"),
        .init(titlePrefix: "Select ", titleSuffix: "Quality_Suffix", subtitle: "Choose between Standard, High, or Maximum clarity for your output.", visual: .landscapeToPortrait, actionTitle: "Next"),
        .init(titlePrefix: "Fast ", titleSuffix: "Export_Suffix", subtitle: "Save high-quality videos directly to your Photos or share anywhere.", visual: .ready, actionTitle: "Get Started")
    ]

    var body: some View {
        GeometryReader { proxy in
            let scale = min(max(proxy.size.height / 852, 0.82), 1.0)
            let pageWidth = proxy.size.width - 40

            ZStack {
                PremiumHomeBackground()
                    .ignoresSafeArea()

                let selectionBinding = Binding<Int>(
                    get: { pageIndex },
                    set: { newValue in
                        if newValue >= pageIndex {
                            pageIndex = newValue
                        }
                    }
                )

                TabView(selection: selectionBinding) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        OnboardingPageView(
                            page: page,
                            pageIndex: index,
                            totalPages: pages.count,
                            scale: scale,
                            next: { goForward() },
                            finish: finish
                        )
                        .tag(index)
                        .frame(width: pageWidth)
                        .padding(.horizontal, 20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .highPriorityGesture(DragGesture())
            }
        }
    }

    private func goForward() {
        guard pageIndex < pages.count - 1 else {
            finish()
            return
        }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            pageIndex += 1
        }
    }
}

private struct OnboardingPage {
    let titlePrefix: LocalizedStringKey
    let titleSuffix: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let visual: OnboardingVisual
    let actionTitle: LocalizedStringKey?
}

private enum OnboardingVisual {
    case logo
    case wrongAspect
    case oneTap
    case portraitToLandscape
    case landscapeToPortrait
    case quality
    case privacy
    case speed
    case share
    case ready
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let pageIndex: Int
    let totalPages: Int
    let scale: CGFloat
    let next: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Skip button at the top
            HStack {
                Spacer()
                Button("Skip") {
                    finish()
                }
                .font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(pageIndex == totalPages - 1 ? 0 : 1)
                .disabled(pageIndex == totalPages - 1)
            }
            .padding(.top, 10 * scale)
            
            Spacer(minLength: 12 * scale)

            // Centered Title & Subtitle
            VStack(spacing: 10 * scale) {
                (Text(page.titlePrefix)
                    .foregroundStyle(.white) +
                 Text(page.titleSuffix)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.65, blue: 1.0),
                                Color(red: 0.60, green: 0.30, blue: 1.0),
                                Color(red: 1.0, green: 0.20, blue: 0.85)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                )
                .font(.system(size: 34 * scale, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)

                Text(page.subtitle)
                    .font(.system(size: 15 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4 * scale)
                    .lineLimit(nil)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: UIScreen.main.bounds.width - 56)
            .padding(.horizontal, 28 * scale)
            
            Spacer(minLength: 16 * scale)

            // Visual View
            OnboardingVisualView(visual: page.visual, scale: scale)
                .frame(maxWidth: .infinity)
                .frame(height: 460 * scale)
            
            Spacer(minLength: 16 * scale)

            // Action Button
            if let actionTitle = page.actionTitle {
                Button {
                    if pageIndex == totalPages - 1 {
                        finish()
                    } else {
                        next()
                    }
                } label: {
                    GeometryReader { buttonProxy in
                        let filmstripAssets = ["onboarding_video_1", "onboarding_video_6", "format_portrait", "quality_max", "export_video"]
                        let imgWidth = (buttonProxy.size.width - 8 * scale) / 5
                        let progressWidth = buttonProxy.size.width * CGFloat(pageIndex + 1) / CGFloat(totalPages)
                        
                        ZStack(alignment: .leading) {
                            // Base slate glass container with outline
                            RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                                .fill(Color(red: 0.05, green: 0.06, blue: 0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1.5 * scale)
                                )
                            
                            // 1. Unlit/dimmed background film strip
                            HStack(spacing: 2 * scale) {
                                ForEach(0..<5, id: \.self) { idx in
                                    Image(filmstripAssets[idx])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: imgWidth, height: 52 * scale)
                                        .clipped()
                                        .saturation(0.15)
                                        .opacity(0.25)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16 * scale, style: .continuous))
                            
                            // 2. Fully lit color film strip (masked by progress)
                            HStack(spacing: 2 * scale) {
                                ForEach(0..<5, id: \.self) { idx in
                                    Image(filmstripAssets[idx])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: imgWidth, height: 52 * scale)
                                        .clipped()
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16 * scale, style: .continuous))
                            .mask(
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .frame(width: progressWidth)
                                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: pageIndex)
                                    Spacer(minLength: 0)
                                }
                            )
                            
                            // 3. Black borders at top and bottom representing the film margins
                            VStack {
                                Rectangle()
                                    .fill(Color.black.opacity(0.75))
                                    .frame(height: 9 * scale)
                                Spacer()
                                Rectangle()
                                    .fill(Color.black.opacity(0.75))
                                    .frame(height: 9 * scale)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16 * scale, style: .continuous))
                            
                            // 4. Sprocket holes (perforations) overlaid on the black borders
                            // Top sprockets
                            VStack {
                                HStack(spacing: 8 * scale) {
                                    ForEach(0..<18, id: \.self) { _ in
                                        RoundedRectangle(cornerRadius: 1.2 * scale)
                                            .fill(Color.white.opacity(0.35))
                                            .frame(width: 8 * scale, height: 4.5 * scale)
                                    }
                                }
                                .padding(.horizontal, 10 * scale)
                                .frame(height: 9 * scale)
                                Spacer()
                            }
                            
                            // Bottom sprockets
                            VStack {
                                Spacer()
                                HStack(spacing: 8 * scale) {
                                    ForEach(0..<18, id: \.self) { _ in
                                        RoundedRectangle(cornerRadius: 1.2 * scale)
                                            .fill(Color.white.opacity(0.35))
                                            .frame(width: 8 * scale, height: 4.5 * scale)
                                    }
                                }
                                .padding(.horizontal, 10 * scale)
                                .frame(height: 9 * scale)
                            }
                            
                            // 5. Playhead scrubber vertical line
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 1.0, green: 0.20, blue: 0.35),
                                            Color(red: 1.0, green: 0.55, blue: 0.15)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 2.5 * scale, height: 52 * scale)
                                .shadow(color: Color.red.opacity(0.8), radius: 3 * scale)
                                .offset(x: progressWidth - 1.25 * scale)
                                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: pageIndex)
                            
                            // 6. Playhead Scrubber Diamond Pin/Cap at the top
                            VStack(spacing: 0) {
                                RoundedRectangle(cornerRadius: 1.5 * scale)
                                    .fill(Color(red: 1.0, green: 0.20, blue: 0.35))
                                    .frame(width: 7 * scale, height: 7 * scale)
                                    .rotationEffect(.degrees(45))
                                    .offset(y: 5.5 * scale) // aligned with top border boundary
                                    .shadow(color: Color.red.opacity(0.8), radius: 2 * scale)
                                Spacer()
                            }
                            .offset(x: progressWidth - 3.5 * scale)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: pageIndex)
                            
                            // 7. Floating Glass Pill (Capsule) in the center containing the action label
                            HStack {
                                Spacer()
                                HStack(spacing: 8 * scale) {
                                    Text(actionTitle)
                                        .font(.system(size: 15 * scale, weight: .black, design: .rounded))
                                        .kerning(1.2)
                                        .textCase(.uppercase)
                                    Image(systemName: pageIndex == totalPages - 1 ? "checkmark.circle.fill" : "play.fill")
                                        .font(.system(size: 13 * scale, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18 * scale)
                                .padding(.vertical, 6 * scale)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.68))
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.white.opacity(0.25), lineWidth: 1.2 * scale)
                                        )
                                        .shadow(color: Color.black.opacity(0.45), radius: 6 * scale, y: 3 * scale)
                                )
                                Spacer()
                            }
                        }
                    }
                    .frame(height: 52 * scale)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .shadow(color: .purple.opacity(0.2), radius: 10, y: 5)
                
                Spacer(minLength: 16 * scale)
            }

            // Page Indicator Dots
            OnboardingDots(current: pageIndex, total: totalPages, scale: scale)
                .padding(.bottom, 12 * scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleSize: CGFloat {
        if page.visual == .logo {
            return 38 * scale
        }

        return 24 * scale
    }
}

private struct OnboardingDots: View {
    let current: Int
    let total: Int
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8 * scale) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white.opacity(0.9) : Color.white.opacity(0.18))
                    .frame(width: index == current ? 18 * scale : 7 * scale, height: 7 * scale)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
            }
        }
    }
}

private struct OnboardingVisualView: View {
    let visual: OnboardingVisual
    let scale: CGFloat

    var body: some View {
        ZStack {
            switch visual {
            case .logo:
                ImportStepVisual(scale: scale)
            case .wrongAspect:
                AnalyzeStepVisual(scale: scale)
            case .portraitToLandscape:
                FormatStepVisual(scale: scale)
            case .landscapeToPortrait:
                QualityStepVisual(scale: scale)
            case .ready:
                ExportStepVisual(scale: scale)
            default:
                EmptyView()
            }
        }
    }
}

private struct PremiumHomeBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.03, blue: 0.09)

            RadialGradient(
                colors: [
                    Color(red: 0.11, green: 0.18, blue: 0.55).opacity(0.7),
                    .clear
                ],
                center: .leading,
                startRadius: 40,
                endRadius: 360
            )

            RadialGradient(
                colors: [
                    Color(red: 0.86, green: 0.1, blue: 0.98).opacity(0.42),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )

            VStack(spacing: 18) {
                ForEach(0..<8, id: \.self) { index in
                    LinearGradient(
                        colors: [.clear, Color.cyan.opacity(0.13), Color.pink.opacity(0.2), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 1)
                    .rotationEffect(.degrees(Double(index) * 5 - 18))
                    .offset(x: CGFloat(index * 18) - 70, y: CGFloat(index * 20))
                }
            }
            .blur(radius: 0.6)
            .opacity(0.75)
        }
    }
}

private struct TopOuterArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        // Start near top-right of the vertical phone
        let start = CGPoint(x: w * 0.32, y: h * 0.22)
        // End pointing downwards-left at top of the horizontal phone
        let end = CGPoint(x: w * 0.80, y: h * 0.52)
        // Control point arching high up and to the right
        let control = CGPoint(x: w * 0.68, y: h * 0.04)
        
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        
        // Add arrowhead pointing down-left at the end point
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - 16, y: end.y - 4))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - 4, y: end.y - 16))
        
        return path
    }
}

private struct BottomOuterArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        // Start near bottom-left of the horizontal phone
        let start = CGPoint(x: w * 0.64, y: h * 0.78)
        // End pointing upwards-right at bottom of the vertical phone
        let end = CGPoint(x: w * 0.18, y: h * 0.48)
        // Control point arching low down and to the left
        let control = CGPoint(x: w * 0.30, y: h * 0.96)
        
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        
        // Add arrowhead pointing up-left at the end point
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 16, y: end.y + 4))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 4, y: end.y + 16))
        
        return path
    }
}

private struct FlipFrameHeroView: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let scale = width / 393.0 // scale normalized to standard screen width

            ZStack {
                // Background Glow
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.blue.opacity(0.32),
                                Color.purple.opacity(0.20),
                                .clear
                            ],
                            center: .center,
                            startRadius: 20 * scale,
                            endRadius: 190 * scale
                        )
                    )
                    .frame(width: width * 0.94, height: height * 0.36)
                    .blur(radius: 20 * scale)
                    .offset(y: height * 0.32)

                // 1. Vertical Phone Mockup
                PremiumDeviceMockup(isLandscape: false)
                    .frame(width: width * 0.28)
                    .rotation3DEffect(.degrees(-10), axis: (x: 0, y: 1, z: 0))
                    .rotationEffect(.degrees(-2))
                    .offset(x: -width * 0.20, y: -height * 0.02)
                    .shadow(color: .black.opacity(0.35), radius: 10 * scale, x: -5 * scale, y: 6 * scale)

                // 2. Horizontal Phone Mockup
                PremiumDeviceMockup(isLandscape: true)
                    .frame(width: width * 0.46)
                    .rotation3DEffect(.degrees(9), axis: (x: 0, y: 1, z: 0))
                    .rotationEffect(.degrees(2))
                    .offset(x: width * 0.17, y: height * 0.18)
                    .shadow(color: .black.opacity(0.35), radius: 10 * scale, x: 5 * scale, y: 6 * scale)
            }
            .frame(width: width, height: height)
        }
    }
}

private struct PremiumFlowingArrow<S: Shape>: View {
    let shape: S
    let colors: [Color]
    let scale: CGFloat
    let dashPhase: CGFloat
    let clockwise: Bool
    
    var body: some View {
        ZStack {
            // Glow layer (thin & blurred)
            shape
                .stroke(
                    LinearGradient(
                        colors: colors,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 4.5 * scale, lineCap: .round)
                )
                .blur(radius: 4 * scale)
                .opacity(0.80)
            
            // Solid Core Arrow
            shape
                .stroke(
                    LinearGradient(
                        colors: colors,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.0 * scale, lineCap: .round)
                )
                .shadow(color: colors[colors.count / 2].opacity(0.5), radius: 2 * scale)
            
            // Flowing Neon Light Dash (animates along the path)
            shape
                .stroke(
                    LinearGradient(
                        colors: [.white, .cyan, .white, .pink, .white],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(
                        lineWidth: 2.2 * scale,
                        lineCap: .round,
                        dash: [20 * scale, 30 * scale],
                        dashPhase: clockwise ? dashPhase : -dashPhase
                    )
                )
                .shadow(color: .white.opacity(0.95), radius: 2 * scale)
                .shadow(color: colors[colors.count / 2].opacity(0.9), radius: 4 * scale)
        }
    }
}

private extension Color {
    static let emerald = Color(red: 0.0, green: 0.78, blue: 0.48)
}

private struct MiniVideoThumbnail: View {
    let type: Int
    let scale: CGFloat
    
    var body: some View {
        Image("onboarding_video_\(type)")
            .resizable()
            .scaledToFill()
            .clipped()
    }
}

private struct ImportStepVisual: View {
    let scale: CGFloat
    
    @State private var isAnimating = false
    @State private var spinAngle = 0.0
    
    var body: some View {
        VideoProductionEnvironmentView(scale: scale) {
            ZStack {
                // Background Glow
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 260 * scale, height: 260 * scale)
                    .blur(radius: 40 * scale)
                
                // Frosted glass grid of thumbnails
                VStack(spacing: 8 * scale) {
                    HStack(spacing: 8 * scale) {
                        thumbnailTile(type: 1, delay: 0.0)
                        thumbnailTile(type: 2, delay: 0.2)
                        thumbnailTile(type: 3, delay: 0.4)
                    }
                    HStack(spacing: 8 * scale) {
                        thumbnailTile(type: 4, delay: 0.6)
                        thumbnailTile(type: 5, delay: 0.8)
                        thumbnailTile(type: 6, delay: 1.0)
                    }
                }
                .padding(.horizontal, 14 * scale)
                .padding(.vertical, 18 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1.5 * scale)
                        )
                )
                .frame(width: 332 * scale, height: 324 * scale)
                // 3D rotation effect for the grid
                .rotation3DEffect(
                    .degrees(isAnimating ? 4 : -4),
                    axis: (x: 1.0, y: 1.0, z: 0.0)
                )
                
                // Overlaying Center Glass Card with pulsing '+' button
                ZStack {
                    RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        .fill(.thinMaterial)
                        .frame(width: 100 * scale, height: 100 * scale)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.4), .clear, .blue.opacity(0.4)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5 * scale
                                )
                        )
                        .shadow(color: .blue.opacity(0.3), radius: 10 * scale, y: 5 * scale)
                    
                    // Outer rotating ring
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.blue, .purple, .clear, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 4.5 * scale, lineCap: .round, dash: [10 * scale, 15 * scale])
                        )
                        .frame(width: 76 * scale, height: 76 * scale)
                        .rotationEffect(.degrees(spinAngle))
                    
                    // Pulsing Plus Button inside
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 54 * scale, height: 54 * scale)
                        .scaleEffect(isAnimating ? 1.12 : 0.95)
                        .shadow(color: .blue.opacity(0.5), radius: 8 * scale)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 24 * scale, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
                .offset(y: 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
            withAnimation(.linear(duration: 5.0).repeatForever(autoreverses: false)) {
                spinAngle = 360.0
            }
        }
    }
    
    private func thumbnailTile(type: Int, delay: Double) -> some View {
        RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                // Mini landscape scene
                MiniVideoThumbnail(type: type, scale: scale)
                    .frame(width: 96 * scale, height: 140 * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1 * scale)
            )
            .overlay(
                // Small video visual inside thumbnail
                VStack(alignment: .leading, spacing: 4 * scale) {
                    Spacer()
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8 * scale, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                        Spacer()
                        // Time indicator representation
                        Text("0:\(type * 7 + 10)")
                            .font(.system(size: 7 * scale, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4 * scale)
                            .padding(.vertical, 2 * scale)
                            .background(Color.black.opacity(0.55), in: Capsule())
                    }
                    .padding(6 * scale)
                }
            )
            .frame(width: 96 * scale, height: 140 * scale)
    }
}

private struct AnalyzeStepVisual: View {
    let scale: CGFloat
    
    @State private var scanYOffset: CGFloat = -110
    @State private var pulseData = false
    
    var body: some View {
        VideoProductionEnvironmentView(scale: scale) {
            ZStack {
                // Background glow
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 260 * scale, height: 260 * scale)
                    .blur(radius: 40 * scale)
                
                // Outer Frame (representing video container)
                ZStack {
                    RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 260 * scale, height: 260 * scale)
                        .overlay(
                            Image("analysis_video")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 260 * scale, height: 260 * scale)
                                .clipShape(RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.25), .orange.opacity(0.45), .white.opacity(0.15)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2 * scale
                                )
                        )
                    
                    // Crosshairs / Corner Reticles inside the frame
                    cornerReticles(scale: scale)
                    
                    // Scanning Laser Line
                    ZStack {
                        // Laser glow
                        LinearGradient(
                            colors: [.clear, .orange.opacity(0.5), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: 240 * scale, height: 20 * scale)
                        
                        // Laser bright core line
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .yellow, .orange, .yellow, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 230 * scale, height: 2 * scale)
                            .shadow(color: .orange, radius: 4 * scale)
                    }
                    .offset(y: scanYOffset * scale)
                }
                
                // Futuristic Data HUD overlays
                VStack {
                    HStack {
                        hudTile(title: "1080x1920", subtitle: "RESOLUTION", icon: "arrow.up.and.down.square.fill", color: .orange)
                            .offset(x: -30 * scale, y: -25 * scale)
                        Spacer()
                        hudTile(title: "60 FPS", subtitle: "FRAME RATE", icon: "bolt.horizontal.fill", color: .yellow)
                            .offset(x: 30 * scale, y: -25 * scale)
                    }
                    Spacer()
                    HStack {
                        hudTile(title: "HEVC", subtitle: "CODEC", icon: "video.fill", color: .cyan)
                            .offset(x: -30 * scale, y: 25 * scale)
                        Spacer()
                        hudTile(title: "45 Mbps", subtitle: "BITRATE", icon: "waveform.path", color: .purple)
                            .offset(x: 30 * scale, y: 25 * scale)
                    }
                }
                .frame(width: 320 * scale, height: 280 * scale)
                .opacity(pulseData ? 1.0 : 0.75)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                scanYOffset = 110
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseData = true
            }
        }
    }
    
    private func cornerReticles(scale: CGFloat) -> some View {
        ZStack {
            // Top-Left
            Path { path in
                path.move(to: CGPoint(x: 20 * scale, y: 35 * scale))
                path.addLine(to: CGPoint(x: 20 * scale, y: 20 * scale))
                path.addLine(to: CGPoint(x: 35 * scale, y: 20 * scale))
            }
            .stroke(Color.white.opacity(0.65), lineWidth: 2.5 * scale)
            
            // Top-Right
            Path { path in
                path.move(to: CGPoint(x: 240 * scale, y: 35 * scale))
                path.addLine(to: CGPoint(x: 240 * scale, y: 20 * scale))
                path.addLine(to: CGPoint(x: 225 * scale, y: 20 * scale))
            }
            .stroke(Color.white.opacity(0.65), lineWidth: 2.5 * scale)
            
            // Bottom-Left
            Path { path in
                path.move(to: CGPoint(x: 20 * scale, y: 225 * scale))
                path.addLine(to: CGPoint(x: 20 * scale, y: 240 * scale))
                path.addLine(to: CGPoint(x: 35 * scale, y: 240 * scale))
            }
            .stroke(Color.white.opacity(0.65), lineWidth: 2.5 * scale)
            
            // Bottom-Right
            Path { path in
                path.move(to: CGPoint(x: 240 * scale, y: 225 * scale))
                path.addLine(to: CGPoint(x: 240 * scale, y: 240 * scale))
                path.addLine(to: CGPoint(x: 225 * scale, y: 240 * scale))
            }
            .stroke(Color.white.opacity(0.65), lineWidth: 2.5 * scale)
        }
        .frame(width: 260 * scale, height: 260 * scale)
    }
    
    private func hudTile(title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: icon)
                .font(.system(size: 12 * scale))
                .foregroundStyle(color)
            
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(title)
                    .font(.system(size: 11 * scale, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 7 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
        .background(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.15), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1 * scale
                        )
                )
        )
        .shadow(color: color.opacity(0.15), radius: 6 * scale)
    }
}

struct CameraViewfinderOverlay: View {
    let scale: CGFloat
    @State private var recPulse = false
    @State private var frameCount = 0
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            // Viewfinder Corner Brackets
            VStack {
                HStack {
                    bracket(horizontal: .left, vertical: .top)
                    Spacer()
                    bracket(horizontal: .right, vertical: .top)
                }
                Spacer()
                HStack {
                    bracket(horizontal: .left, vertical: .bottom)
                    Spacer()
                    bracket(horizontal: .right, vertical: .bottom)
                }
            }
            .padding(.horizontal, 30 * scale)
            .padding(.vertical, 10 * scale)
            
            // Viewfinder HUD overlay info
            VStack {
                HStack {
                    // Pulsing REC light
                    HStack(spacing: 5 * scale) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8 * scale, height: 8 * scale)
                            .opacity(recPulse ? 1.0 : 0.2)
                        Text("REC")
                            .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    Text("1080P 60")
                        .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 40 * scale)
                .padding(.top, 10 * scale)
                
                Spacer()
                
                HStack {
                    // Timecode indicator
                    Text(timecodeString)
                        .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    
                    // Audio levels visualizer
                    HStack(spacing: 2 * scale) {
                        ForEach(0..<6, id: \.self) { index in
                            bar(index: index)
                        }
                    }
                }
                .padding(.horizontal, 40 * scale)
                .padding(.bottom, 10 * scale)
            }
        }
        .frame(height: 460 * scale)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                recPulse = true
            }
        }
        .onReceive(timer) { _ in
            frameCount += 1
        }
    }
    
    @ViewBuilder
    private func bar(index: Int) -> some View {
        let heights: [CGFloat] = [6, 12, 18, 14, 8, 4]
        RoundedRectangle(cornerRadius: 1)
            .fill(index == 4 ? Color.red.opacity(0.7) : Color.green.opacity(0.7))
            .frame(width: 3 * scale, height: heights[index] * scale)
            .scaleEffect(y: recPulse ? 0.6 : 1.2, anchor: .bottom)
            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(index) * 0.05), value: recPulse)
    }
    
    private var timecodeString: String {
        let totalSeconds = frameCount / 10
        let frames = frameCount % 10
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "00:%02d:%02d:%d", minutes, seconds, frames)
    }
    
    enum Horizontal { case left, right }
    enum Vertical { case top, bottom }
    
    private func bracket(horizontal: Horizontal, vertical: Vertical) -> some View {
        let bracketSize: CGFloat = 16 * scale
        let lineWidth: CGFloat = 1.5 * scale
        
        return Path { path in
            if horizontal == .left && vertical == .top {
                path.move(to: CGPoint(x: bracketSize, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: bracketSize))
            } else if horizontal == .right && vertical == .top {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: bracketSize, y: 0))
                path.addLine(to: CGPoint(x: bracketSize, y: bracketSize))
            } else if horizontal == .left && vertical == .bottom {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: bracketSize))
                path.addLine(to: CGPoint(x: bracketSize, y: bracketSize))
            } else {
                path.move(to: CGPoint(x: bracketSize, y: 0))
                path.addLine(to: CGPoint(x: bracketSize, y: bracketSize))
                path.addLine(to: CGPoint(x: 0, y: bracketSize))
            }
        }
        .stroke(Color.white.opacity(0.25), lineWidth: lineWidth)
        .frame(width: bracketSize, height: bracketSize)
    }
}

struct VideoTimelineTrackOverlay: View {
    let scale: CGFloat
    @State private var animateOffset = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Keyframe Track (diamond icons moving across)
            ZStack(alignment: .leading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 500 * scale, y: 0))
                }
                .stroke(style: StrokeStyle(lineWidth: 1 * scale, dash: [4 * scale, 4 * scale]))
                .foregroundStyle(Color.white.opacity(0.12))
                
                HStack(spacing: 40 * scale) {
                    ForEach(0..<12) { i in
                        Image(systemName: "rhombus.fill")
                            .font(.system(size: 8 * scale))
                            .foregroundStyle(i % 3 == 0 ? Color.cyan.opacity(0.5) : Color.white.opacity(0.2))
                            .scaleEffect(animateOffset && i % 3 == 0 ? 1.2 : 1.0)
                    }
                }
                .offset(x: animateOffset ? -40 * scale : 0)
            }
            .frame(height: 10 * scale)
            .padding(.top, 24 * scale)
            
            Spacer()
            
            // Bottom Timeline Ruler Tick Marks (moving across)
            ZStack(alignment: .bottomLeading) {
                HStack(spacing: 8 * scale) {
                    ForEach(0..<50) { i in
                        Rectangle()
                            .fill(Color.white.opacity(i % 5 == 0 ? 0.22 : 0.1))
                            .frame(width: 1 * scale, height: i % 5 == 0 ? 10 * scale : 6 * scale)
                    }
                }
                .offset(x: animateOffset ? -40 * scale : 0)
                
                HStack(spacing: 40 * scale) {
                    ForEach(0..<10) { i in
                        Text("0:\(String(format: "%02d", i * 2))")
                            .font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.18))
                    }
                }
                .offset(x: animateOffset ? -40 * scale : 0)
                .padding(.bottom, 12 * scale)
            }
            .frame(height: 24 * scale)
            .padding(.bottom, 24 * scale)
        }
        .frame(height: 460 * scale)
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 5.0).repeatForever(autoreverses: false)) {
                animateOffset = true
            }
        }
    }
}

struct VideoProductionEnvironmentView<Content: View>: View {
    let scale: CGFloat
    let content: Content
    
    init(scale: CGFloat, @ViewBuilder content: () -> Content) {
        self.scale = scale
        self.content = content()
    }
    
    var body: some View {
        ZStack {
            // Viewfinder HUD
            CameraViewfinderOverlay(scale: scale)
            
            // Keyframe timeline tracks
            VideoTimelineTrackOverlay(scale: scale)
            
            // Center visual content
            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: 460 * scale)
        .clipped()
    }
}

private struct FormatStepVisual: View {
    let scale: CGFloat
    
    @State private var isPortraitSelected = true
    @State private var rotationAngle = 0.0
    
    var body: some View {
        VideoProductionEnvironmentView(scale: scale) {
            ZStack {
                // Background glow matching selection
                Circle()
                    .fill(isPortraitSelected ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
                    .frame(width: 260 * scale, height: 260 * scale)
                    .blur(radius: 40 * scale)
                
                HStack(spacing: 12 * scale) {
                    // Portrait Card (TikTok)
                    VStack(spacing: 8 * scale) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                .fill(Color.black.opacity(0.3))
                                .frame(width: 115 * scale, height: 204 * scale)
                                .overlay(
                                    Image("format_portrait")
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 115 * scale, height: 204 * scale)
                                        .clipShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                                        .opacity(isPortraitSelected ? 1.0 : 0.45)
                                )
                                .overlay(
                                    // Overlay HUD badge
                                    VStack {
                                        Spacer()
                                        HStack(spacing: 6 * scale) {
                                            TikTokLogoBadge(scale: scale * 0.8)
                                                .frame(width: 22 * scale, height: 22 * scale)
                                            Text("9:16")
                                                .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white)
                                        }
                                        .padding(.horizontal, 8 * scale)
                                        .padding(.vertical, 4 * scale)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(.bottom, 8 * scale)
                                    }
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                        .stroke(
                                            isPortraitSelected ?
                                            LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing) :
                                            LinearGradient(colors: [.white.opacity(0.1)], startPoint: .top, endPoint: .bottom),
                                            lineWidth: 2 * scale
                                        )
                                )
                                .shadow(color: isPortraitSelected ? .purple.opacity(0.4) : .clear, radius: 12 * scale)
                        }
                        .frame(width: 115 * scale, height: 204 * scale)
                        .scaleEffect(isPortraitSelected ? 1.04 : 0.96)
                        
                        Text("Portrait")
                            .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(isPortraitSelected ? .white : .white.opacity(0.4))
                    }
                    
                    // Rotating Arrow Centerpiece
                    ZStack {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: 2 * scale
                            )
                            .background(Circle().fill(.ultraThinMaterial))
                            .frame(width: 44 * scale, height: 44 * scale)
                        
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 20 * scale, weight: .black))
                            .foregroundStyle(LinearGradient(colors: [.white, .blue], startPoint: .top, endPoint: .bottom))
                            .rotationEffect(.degrees(rotationAngle))
                    }
                    
                    // Landscape Card (YouTube)
                    VStack(spacing: 8 * scale) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                .fill(Color.black.opacity(0.3))
                                .frame(width: 204 * scale, height: 115 * scale)
                                .overlay(
                                    Image("format_landscape")
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 204 * scale, height: 115 * scale, alignment: .top)
                                        .clipShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                                        .opacity(!isPortraitSelected ? 1.0 : 0.45)
                                )
                                .overlay(
                                    // Overlay HUD badge
                                    VStack {
                                        Spacer()
                                        HStack(spacing: 6 * scale) {
                                            YouTubeLogoBadge(scale: scale * 0.8)
                                                .frame(width: 22 * scale, height: 22 * scale)
                                            Text("16:9")
                                                .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white)
                                        }
                                        .padding(.horizontal, 8 * scale)
                                        .padding(.vertical, 4 * scale)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(.bottom, 8 * scale)
                                    }
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                        .stroke(
                                            !isPortraitSelected ?
                                            LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing) :
                                            LinearGradient(colors: [.white.opacity(0.1)], startPoint: .top, endPoint: .bottom),
                                            lineWidth: 2 * scale
                                        )
                                )
                                .shadow(color: !isPortraitSelected ? .blue.opacity(0.4) : .clear, radius: 12 * scale)
                        }
                        .frame(width: 204 * scale, height: 115 * scale)
                        .scaleEffect(!isPortraitSelected ? 1.04 : 0.96)
                        
                        Text("Landscape")
                            .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(!isPortraitSelected ? .white : .white.opacity(0.4))
                    }
                }
                .padding(.top, 20 * scale)
            }
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                        isPortraitSelected.toggle()
                        rotationAngle += 180.0
                    }
                }
            }
        }
    }
}

private struct QualityStepVisual: View {
    let scale: CGFloat
    
    @State private var pulseMaximum = false
    
    var body: some View {
        VideoProductionEnvironmentView(scale: scale) {
            ZStack {
                // Background glow matching the selection
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 260 * scale, height: 260 * scale)
                    .blur(radius: 40 * scale)
                
                HStack(spacing: 14 * scale) {
                    // 1. Standard Quality Card
                    VStack(spacing: 8 * scale) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                .fill(Color.black.opacity(0.3))
                                .frame(width: 110 * scale, height: 196 * scale)
                                .overlay(
                                    Image("quality_standard")
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110 * scale, height: 196 * scale)
                                        .clipShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                                        .opacity(0.6)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1.5 * scale)
                                )
                        }
                        .frame(width: 110 * scale, height: 196 * scale)
                        .scaleEffect(0.9)
                        
                        Text("Standard")
                            .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    
                    // 2. High Quality Card
                    VStack(spacing: 8 * scale) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                .fill(Color.black.opacity(0.3))
                                .frame(width: 110 * scale, height: 196 * scale)
                                .overlay(
                                    Image("quality_high")
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110 * scale, height: 196 * scale)
                                        .clipShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                                        .opacity(0.8)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1.5 * scale)
                                )
                        }
                        .frame(width: 110 * scale, height: 196 * scale)
                        .scaleEffect(0.95)
                        
                        Text("High")
                            .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    
                    // 3. Maximum Quality Card
                    VStack(spacing: 8 * scale) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                .fill(Color.black.opacity(0.3))
                                .frame(width: 110 * scale, height: 196 * scale)
                                .overlay(
                                    Image("quality_max")
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110 * scale, height: 196 * scale)
                                        .clipShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                        .stroke(
                                            LinearGradient(
                                                colors: [.orange, .yellow, .red],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 2 * scale
                                        )
                                        .shadow(color: .orange.opacity(pulseMaximum ? 0.6 : 0.2), radius: 6 * scale)
                                )
                        }
                        .frame(width: 110 * scale, height: 196 * scale)
                        .scaleEffect(1.05)
                        
                        Text("Maximum")
                            .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseMaximum = true
            }
        }
    }
}

private struct ExportStepVisual: View {
    let scale: CGFloat
    
    @State private var isAnimating = false
    @State private var arrowOffset: CGFloat = 0.0
    @State private var sheenOffset: CGFloat = -190.0
    
    var body: some View {
        VideoProductionEnvironmentView(scale: scale) {
            ZStack {
                // Background Glow
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 290 * scale, height: 290 * scale)
                    .blur(radius: 40 * scale)
                
                // Background Card (Offset to the left)
                ZStack {
                    RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 190 * scale, height: 245 * scale)
                        .overlay(
                            Image("export_video")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 190 * scale, height: 245 * scale)
                                .clipShape(RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
                                .opacity(0.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.2), .clear, .blue.opacity(0.15)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5 * scale
                                )
                        )
                }
                .offset(x: -35 * scale, y: 15 * scale)
                .rotationEffect(.degrees(-6))
                
                // Central Glassmorphic File Card
                ZStack {
                    RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 190 * scale, height: 245 * scale)
                        .overlay(
                            Image("export_video")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 190 * scale, height: 245 * scale)
                                .clipShape(RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
                                .overlay(
                                    Color.black.opacity(0.3)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.4), .clear, .blue.opacity(0.3)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5 * scale
                                )
                        )
                        .shadow(color: .blue.opacity(0.35), radius: 15 * scale, y: 8 * scale)
                    
                    // Decorative diagonal fold on top-right corner to make it look like a document file
                    fileCornerFold(scale: scale)
                    
                    // File content representation: Video details + play button
                    VStack(spacing: 12 * scale) {
                        Circle()
                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 44 * scale, height: 44 * scale)
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16 * scale, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: 1 * scale)
                            )
                            .shadow(color: .blue.opacity(0.3), radius: 6 * scale)
                        
                        VStack(spacing: 4 * scale) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.4))
                                .frame(width: 60 * scale, height: 6 * scale)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 40 * scale, height: 5 * scale)
                        }
                    }
                    .offset(y: -15 * scale)
                    
                    // Animated Arrow rising up from file
                    Image(systemName: "arrow.up")
                        .font(.system(size: 32 * scale, weight: .black))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .cyan, .blue],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: .cyan.opacity(0.8), radius: 8 * scale)
                        .offset(y: (25 + arrowOffset) * scale)
                    
                    // Glass Card Sheen Overlay
                    RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.15), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 190 * scale, height: 245 * scale)
                        .mask(
                            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                        )
                        .offset(x: sheenOffset * scale)
                }
                .offset(x: 15 * scale, y: -10 * scale)
                .rotationEffect(.degrees(2))
                
                // Floating Social Media Badges (Instagram, TikTok, YouTube)
                floatingBadge(icon: "camera.fill", colors: [.orange, .pink, .purple], offset: CGPoint(x: -115, y: -85), delay: 0.0)
                floatingBadge(icon: "play.fill", colors: [.red, .pink], offset: CGPoint(x: 125, y: -35), delay: 0.3)
                floatingBadge(icon: "music.note", colors: [.cyan, .blue, .purple], offset: CGPoint(x: -105, y: 75), delay: 0.6)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
            
            // Loop vertical arrow animation
            Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
                arrowOffset = 25.0
                withAnimation(.easeOut(duration: 1.0)) {
                    arrowOffset = -25.0
                }
            }
            
            // Sheen loop animation
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                sheenOffset = -190.0
                withAnimation(.linear(duration: 1.5)) {
                    sheenOffset = 190.0
                }
            }
        }
    }
    
    private func fileCornerFold(scale: CGFloat) -> some View {
        VStack {
            HStack {
                Spacer()
                Path { path in
                    path.move(to: CGPoint(x: 15 * scale, y: 0))
                    path.addLine(to: CGPoint(x: 15 * scale, y: 15 * scale))
                    path.addLine(to: CGPoint(x: 0, y: 15 * scale))
                    path.closeSubpath()
                }
                .fill(Color.white.opacity(0.25))
                .frame(width: 15 * scale, height: 15 * scale)
            }
            Spacer()
        }
        .frame(width: 190 * scale, height: 245 * scale)
    }
    
    private func floatingBadge(icon: String, colors: [Color], offset: CGPoint, delay: Double) -> some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 38 * scale, height: 38 * scale)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1 * scale)
                )
            
            Image(systemName: icon)
                .font(.system(size: 14 * scale, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
        .shadow(color: colors[0].opacity(0.3), radius: 8 * scale, y: 4 * scale)
        .offset(x: offset.x * scale, y: (offset.y + (isAnimating ? -8.0 : 8.0)) * scale)
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true).delay(delay), value: isAnimating)
    }
}

private struct WrongAspectStoryboardView: View {
    let scale: CGFloat
    
    @State private var shakeOffset: CGFloat = 0
    @State private var xGlow = false
    
    var body: some View {
        VStack(spacing: 24 * scale) {
            HStack(spacing: 28 * scale) {
                // Portrait Left Device Column
                VStack(spacing: 12 * scale) {
                    PremiumDeviceMockup(
                        isLandscape: false,
                        customGlowColor: Color(red: 0.0, green: 0.6, blue: 1.0),
                        customBezelGradient: LinearGradient(
                            colors: [Color(red: 0.0, green: 0.7, blue: 1.0), .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    ) {
                        ZStack {
                            Color.black
                            SurferVideoView(isLandscape: true)
                                .frame(height: 56 * scale)
                        }
                    }
                    .frame(width: 86 * scale)
                    .overlay(alignment: .topTrailing) {
                        redBadge
                            .offset(x: 6 * scale, y: -6 * scale)
                    }
                    
                    // YouTube label
                    HStack(spacing: 6 * scale) {
                        YouTubeLogoBadge(scale: scale * 0.75)
                            .frame(width: 24 * scale, height: 24 * scale)
                        Text("YouTube")
                            .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                
                // Landscape Right Device Column
                VStack(spacing: 12 * scale) {
                    PremiumDeviceMockup(
                        isLandscape: true,
                        customGlowColor: Color(red: 1.0, green: 0.2, blue: 0.85),
                        customBezelGradient: LinearGradient(
                            colors: [Color(red: 1.0, green: 0.35, blue: 0.9), .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    ) {
                        ZStack {
                            Color.black
                            SurferVideoView(isLandscape: false)
                                .frame(width: 52 * scale)
                        }
                    }
                    .frame(width: 140 * scale)
                    .overlay(alignment: .topTrailing) {
                        redBadge
                            .offset(x: 6 * scale, y: -6 * scale)
                    }
                    
                    // TikTok label
                    HStack(spacing: 6 * scale) {
                        TikTokLogoBadge(scale: scale * 0.75)
                            .frame(width: 24 * scale, height: 24 * scale)
                        Text("TikTok")
                            .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .offset(x: shakeOffset)
            .offset(y: -10 * scale)
        }
        .onAppear {
            withAnimation(.default.repeatForever(autoreverses: true)) {
                xGlow = true
            }
            
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                withAnimation(.linear(duration: 0.05).repeatCount(4, autoreverses: true)) {
                    shakeOffset = 6 * scale
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    shakeOffset = 0
                }
            }
        }
    }
    
    private var redBadge: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 22 * scale, height: 22 * scale)
            .overlay {
                Image(systemName: "xmark")
                    .font(.system(size: 10 * scale, weight: .black))
                    .foregroundStyle(.white)
            }
            .shadow(color: .red.opacity(xGlow ? 0.85 : 0.45), radius: 6 * scale)
    }
}

private struct OneTapStoryboardView: View {
    let scale: CGFloat
    
    @State private var isTapped = false
    @State private var tapPulse: CGFloat = 0.8
    
    var body: some View {
        ZStack {
            HStack(spacing: 44 * scale) {
                PremiumDeviceMockup(isLandscape: false) {
                    DeviceScreenArtwork(isLandscape: false, scale: scale * 0.8, animate: true)
                }
                .frame(width: 100 * scale)
                .scaleEffect(isTapped ? 0.96 : 1.0)
                
                PremiumDeviceMockup(isLandscape: true) {
                    DeviceScreenArtwork(isLandscape: true, scale: scale * 0.8, animate: true)
                }
                .frame(width: 164 * scale)
                .scaleEffect(isTapped ? 1.04 : 1.0)
            }
            
            ZStack {
                Circle()
                    .stroke(LinearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2 * scale)
                    .frame(width: 58 * scale, height: 58 * scale)
                    .scaleEffect(tapPulse)
                    .opacity(Double(2.0 - tapPulse))
                
                Circle()
                    .fill(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32 * scale, height: 32 * scale)
                    .overlay {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 14 * scale, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: .purple.opacity(0.6), radius: 8)
            }
            .offset(x: -8 * scale, y: 10 * scale)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                tapPulse = 1.8
            }
            
            Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isTapped = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isTapped = false
                    }
                }
            }
        }
    }
}

private struct PodiumView: View {
    let scale: CGFloat
    let color: Color
    var customWidth: CGFloat? = nil
    
    var body: some View {
        let baseWidth = customWidth ?? (100 * scale)
        let topWidth = baseWidth * 0.86
        
        return ZStack {
            // Glow
            Ellipse()
                .fill(color.opacity(0.35))
                .frame(width: baseWidth * 1.1, height: 22 * scale)
                .blur(radius: 8 * scale)
            
            // Bottom ring
            Ellipse()
                .fill(Color(white: 0.05))
                .frame(width: baseWidth, height: 20 * scale)
                .overlay {
                    Ellipse()
                        .stroke(color.opacity(0.5), lineWidth: 1.5 * scale)
                }
            
            // Top ring
            Ellipse()
                .fill(Color(white: 0.1))
                .frame(width: topWidth, height: 16 * scale)
                .overlay {
                    Ellipse()
                        .stroke(color.opacity(0.8), lineWidth: 1.5 * scale)
                }
                .offset(y: -4 * scale)
        }
    }
}

private struct FlowingHorizontalArrow: View {
    let scale: CGFloat
    let colors: [Color]
    
    @State private var pulseGlow = false
    
    var body: some View {
        ZStack {
            // Glow
            Image(systemName: "arrow.right")
                .font(.system(size: 32 * scale, weight: .black))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .blur(radius: 6 * scale)
                .opacity(pulseGlow ? 0.9 : 0.4)
            
            // Core
            Image(systemName: "arrow.right")
                .font(.system(size: 30 * scale, weight: .black))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .shadow(color: colors.last?.opacity(0.6) ?? .pink, radius: 4 * scale)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseGlow = true
            }
        }
    }
}

private struct PortraitToLandscapeStoryboardView: View {
    let scale: CGFloat
    
    @State private var floatOffset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 20 * scale) {
            // Mockups & Arrow Visual
            HStack(spacing: 20 * scale) {
                // Left Portrait Device
                PremiumDeviceMockup(
                    isLandscape: false,
                    customGlowColor: Color(red: 0.0, green: 0.6, blue: 1.0),
                    customBezelGradient: LinearGradient(
                        colors: [Color(red: 0.0, green: 0.7, blue: 1.0), .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ) {
                    MountainVideoView(isLandscape: false)
                }
                .frame(width: 76 * scale)
                .offset(y: floatOffset)
                
                // Middle Flowing Arrow
                FlowingHorizontalArrow(scale: scale, colors: [.blue, .purple, .pink])
                
                // Right Landscape Device standing on Podium
                ZStack(alignment: .bottom) {
                    // Podium at the base (wider for landscape card)
                    PodiumView(scale: scale, color: .purple, customWidth: 140 * scale)
                        .offset(y: 8 * scale)
                    
                    // Landscape phone
                    PremiumDeviceMockup(
                        isLandscape: true,
                        customGlowColor: Color(red: 1.0, green: 0.2, blue: 0.85),
                        customBezelGradient: LinearGradient(
                            colors: [Color(red: 1.0, green: 0.35, blue: 0.9), .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    ) {
                        MountainVideoView(isLandscape: true)
                    }
                    .frame(width: 124 * scale)
                    .offset(y: -6 * scale)
                }
                .offset(y: -floatOffset)
            }
            .frame(height: 230 * scale)
            .padding(.top, 10 * scale)
            
            // Features Row
            HStack(spacing: 24 * scale) {
                featureItem(iconName: "bolt.fill", title: "Instant\nConversion", color: Color(red: 0.12, green: 0.65, blue: 1.0))
                featureItem(iconName: "lock.shield.fill", title: "100%\nPrivate", color: Color(red: 0.60, green: 0.30, blue: 1.0))
                featureItem(iconName: "checkmark.seal.fill", title: "No Quality\nLoss", color: Color(red: 1.0, green: 0.20, blue: 0.85))
            }
            .padding(.horizontal, 10)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                floatOffset = -6 * scale
            }
        }
    }
    
    private func featureItem(iconName: String, title: String, color: Color) -> some View {
        VStack(spacing: 10 * scale) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 62 * scale, height: 62 * scale)
                
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(0.6), color.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5 * scale
                    )
                    .frame(width: 62 * scale, height: 62 * scale)
                    .shadow(color: color.opacity(0.3), radius: 6 * scale)
                
                Image(systemName: iconName)
                    .font(.system(size: 22 * scale, weight: .bold))
                    .foregroundStyle(color)
            }
            
            Text(title)
                .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 36 * scale, alignment: .top)
        }
    }
}

private struct LandscapeToPortraitStoryboardView: View {
    let scale: CGFloat
    
    @State private var floatOffset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 20 * scale) {
            // Mockups & Arrow Visual
            HStack(spacing: 20 * scale) {
                // Left Landscape Device
                PremiumDeviceMockup(
                    isLandscape: true,
                    customGlowColor: Color(red: 0.0, green: 0.6, blue: 1.0),
                    customBezelGradient: LinearGradient(
                        colors: [Color(red: 0.0, green: 0.7, blue: 1.0), .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ) {
                    MountainVideoView(isLandscape: true)
                }
                .frame(width: 124 * scale)
                .offset(y: floatOffset)
                
                // Middle Flowing Arrow
                FlowingHorizontalArrow(scale: scale, colors: [.blue, .purple, .pink])
                
                // Right Portrait Device standing on Podium
                ZStack(alignment: .bottom) {
                    // Podium at the base
                    PodiumView(scale: scale, color: .purple, customWidth: 100 * scale)
                        .offset(y: 8 * scale)
                    
                    // Portrait phone
                    PremiumDeviceMockup(
                        isLandscape: false,
                        customGlowColor: Color(red: 1.0, green: 0.2, blue: 0.85),
                        customBezelGradient: LinearGradient(
                            colors: [Color(red: 1.0, green: 0.35, blue: 0.9), .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    ) {
                        MountainVideoView(isLandscape: false)
                    }
                    .frame(width: 76 * scale)
                    .offset(y: -6 * scale)
                }
                .offset(y: -floatOffset)
            }
            .frame(height: 230 * scale)
            .padding(.top, 10 * scale)
            
            // Features Row
            HStack(spacing: 24 * scale) {
                featureItem(iconName: "bolt.fill", title: "Instant\nConversion", color: Color(red: 0.12, green: 0.65, blue: 1.0))
                featureItem(iconName: "lock.shield.fill", title: "100%\nPrivate", color: Color(red: 0.60, green: 0.30, blue: 1.0))
                featureItem(iconName: "checkmark.seal.fill", title: "No Quality\nLoss", color: Color(red: 1.0, green: 0.20, blue: 0.85))
            }
            .padding(.horizontal, 10)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                floatOffset = -6 * scale
            }
        }
    }
    
    private func featureItem(iconName: String, title: String, color: Color) -> some View {
        VStack(spacing: 10 * scale) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 62 * scale, height: 62 * scale)
                
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(0.6), color.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5 * scale
                    )
                    .frame(width: 62 * scale, height: 62 * scale)
                    .shadow(color: color.opacity(0.3), radius: 6 * scale)
                
                Image(systemName: iconName)
                    .font(.system(size: 22 * scale, weight: .bold))
                    .foregroundStyle(color)
            }
            
            Text(title)
                .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 36 * scale, alignment: .top)
        }
    }
}

private struct QualityStoryboardView: View {
    let scale: CGFloat
    
    @State private var floatOffset: CGFloat = 0
    @State private var badgeRotation: Double = 0.0
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.purple.opacity(0.12))
                .frame(width: 260 * scale, height: 260 * scale)
                .blur(radius: 24 * scale)
            
            HStack(spacing: 20 * scale) {
                qualityToken(title: "HD", subtitle: "1080p", color: .blue, angle: -10)
                    .offset(y: floatOffset - 12 * scale)
                
                qualityToken(title: "4K", subtitle: "Ultra HD", color: .purple, angle: 0)
                    .offset(y: -floatOffset)
                
                qualityToken(title: "MAX", subtitle: "Original", color: .pink, angle: 10)
                    .offset(y: floatOffset + 12 * scale)
            }
            .offset(y: -10 * scale)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                floatOffset = 14 * scale
            }
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                badgeRotation = 360
            }
        }
    }
    
    private func qualityToken(title: String, subtitle: String, color: Color, angle: Double) -> some View {
        VStack(spacing: 8 * scale) {
            ZStack {
                RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                    .fill(Color(white: 0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [color, color.opacity(0.3), color, color.opacity(0.9)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2.5 * scale
                            )
                    }
                    .shadow(color: color.opacity(0.45), radius: 12)
                
                VStack(spacing: 4 * scale) {
                    Text(title)
                        .font(.system(size: 26 * scale, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [.white, color], startPoint: .top, endPoint: .bottom)
                        )
                    
                    Text(subtitle)
                        .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 86 * scale, height: 92 * scale)
            .rotation3DEffect(.degrees(angle + (floatOffset * 0.4)), axis: (x: 0, y: 1, z: 0))
        }
    }
}

private struct PrivacyStoryboardView: View {
    let scale: CGFloat
    
    @State private var lockScale: CGFloat = 1.0
    @State private var lockClosed = false
    @State private var pulseRadial = false
    
    var body: some View {
        ZStack {
            Image(systemName: "shield.fill")
                .font(.system(size: 180 * scale, weight: .thin))
                .foregroundStyle(
                    LinearGradient(colors: [.cyan.opacity(0.15), .blue.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom)
                )
                .overlay {
                    Image(systemName: "shield")
                        .font(.system(size: 180 * scale, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }
                .shadow(color: .cyan.opacity(pulseRadial ? 0.6 : 0.3), radius: 20)
                .scaleEffect(pulseRadial ? 1.02 : 0.98)
                .offset(y: -20 * scale)
            
            ZStack {
                RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.8))
                    .frame(width: 90 * scale, height: 90 * scale)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                            .stroke(
                                LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1.5 * scale
                            )
                    }
                    .shadow(color: .purple.opacity(0.4), radius: 14)
                
                Image(systemName: lockClosed ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 40 * scale, weight: .black))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .scaleEffect(lockScale)
            .offset(y: -15 * scale)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulseRadial = true
            }
            
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    lockClosed.toggle()
                    lockScale = 1.15
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                        lockScale = 1.0
                    }
                }
            }
        }
    }
}

private struct SpeedStoryboardView: View {
    let scale: CGFloat
    
    @State private var speedPercent = 0.0
    @State private var boltGlow = false
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 12 * scale)
                .frame(width: 210 * scale, height: 210 * scale)
            
            Circle()
                .trim(from: 0.0, to: CGFloat(speedPercent / 100.0))
                .stroke(
                    LinearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 12 * scale, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 210 * scale, height: 210 * scale)
                .shadow(color: .purple.opacity(0.65), radius: 18)
            
            VStack(spacing: 8 * scale) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 38 * scale, weight: .black))
                    .foregroundStyle(
                        LinearGradient(colors: [.yellow, .orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .shadow(color: .orange.opacity(boltGlow ? 0.8 : 0.4), radius: 10)
                    .scaleEffect(boltGlow ? 1.1 : 0.95)
                
                Text("\(Int(speedPercent))%")
                    .font(.system(size: 38 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .offset(y: -5 * scale)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                boltGlow = true
            }
            
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                speedPercent = 0.0
                withAnimation(.easeOut(duration: 1.5)) {
                    speedPercent = 100.0
                }
            }
        }
    }
}

private struct ShareStoryboardView: View {
    let scale: CGFloat
    
    @State private var pulseIcons = false
    @State private var waveProgress: CGFloat = 0.0
    
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 120 * scale, y: 180 * scale))
                path.addLine(to: CGPoint(x: 40 * scale, y: 70 * scale))
                path.move(to: CGPoint(x: 120 * scale, y: 180 * scale))
                path.addLine(to: CGPoint(x: 200 * scale, y: 70 * scale))
                path.move(to: CGPoint(x: 120 * scale, y: 180 * scale))
                path.addLine(to: CGPoint(x: 40 * scale, y: 290 * scale))
                path.move(to: CGPoint(x: 120 * scale, y: 180 * scale))
                path.addLine(to: CGPoint(x: 200 * scale, y: 290 * scale))
            }
            .stroke(
                LinearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round, dash: [6 * scale, 6 * scale], dashPhase: waveProgress)
            )
            .frame(width: 240 * scale, height: 360 * scale)
            .offset(y: -20 * scale)
            
            Circle()
                .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 62 * scale, height: 62 * scale)
                .overlay {
                    Image(systemName: "square.and.arrow.up.fill")
                        .font(.system(size: 20 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(y: -2 * scale)
                }
                .shadow(color: .purple.opacity(0.65), radius: 14)
                .offset(y: -20 * scale)
                .scaleEffect(pulseIcons ? 1.06 : 0.94)
            
            Group {
                shareTile(title: "Photos", symbol: "photo.fill", colors: [.yellow, .pink])
                    .offset(x: -80 * scale, y: -110 * scale)
                
                shareTile(title: "Instagram", symbol: "camera.fill", colors: [.orange, .pink])
                    .offset(x: 80 * scale, y: -110 * scale)
                
                shareTile(title: "TikTok", symbol: "music.note", colors: [.cyan, .pink])
                    .offset(x: -80 * scale, y: 110 * scale)
                
                shareTile(title: "YouTube", symbol: "play.fill", colors: [.red, .red])
                    .offset(x: 80 * scale, y: 110 * scale)
            }
            .scaleEffect(pulseIcons ? 1.02 : 0.98)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseIcons = true
            }
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                waveProgress = -40 * scale
            }
        }
    }
    
    private func shareTile(title: String, symbol: String, colors: [Color]) -> some View {
        VStack(spacing: 6 * scale) {
            RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.7))
                .frame(width: 54 * scale, height: 54 * scale)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 20 * scale, weight: .black))
                        .foregroundStyle(
                            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1.2 * scale)
                }
                .shadow(color: colors[0].opacity(0.3), radius: 8)
            
            Text(title)
                .font(.system(size: 10 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct Page5TopArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        let start = CGPoint(x: w * 0.29, y: h * 0.12)
        let end = CGPoint(x: w * 0.87, y: h * 0.225)
        let control = CGPoint(x: w * 0.58, y: h * -0.16)
        
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        
        // Arrowhead pointing down-right
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - 12, y: end.y - 3))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - 3, y: end.y - 12))
        
        return path
    }
}

private struct Page5BottomArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        let start = CGPoint(x: w * 0.69, y: h * 0.80)
        let end = CGPoint(x: w * 0.13, y: h * 0.74)
        let control = CGPoint(x: w * 0.41, y: h * 1.13)
        
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        
        // Arrowhead pointing up-left
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 12, y: end.y + 3))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 3, y: end.y + 12))
        
        return path
    }
}

private struct ReadyStoryboardView: View {
    let scale: CGFloat
    
    @State private var floatOffset: CGFloat = 0
    @State private var dashPhase: CGFloat = 0.0
    @State private var rotationAngle: Double = 0.0
    
    var body: some View {
        VStack(spacing: 20 * scale) {
            // Orbit & Glass Phones Visual
            ZStack {
                // Orbit concentric circles
                OrbitCircle(radius: 125 * scale, dots: [30, 150, 270], dotColor: .pink, scale: scale)
                    .rotationEffect(.degrees(rotationAngle * 0.5))
                
                OrbitCircle(radius: 105 * scale, dots: [90, 210, 330], dotColor: .purple, scale: scale)
                    .rotationEffect(.degrees(-rotationAngle * 0.8))
                
                OrbitCircle(radius: 85 * scale, dots: [0, 120, 240], dotColor: .cyan, scale: scale)
                    .rotationEffect(.degrees(rotationAngle))
                
                ZStack {
                    // Top Flowing Arrow
                    PremiumFlowingArrow(
                        shape: Page5TopArrowShape(),
                        colors: [.blue, .purple, .pink],
                        scale: scale,
                        dashPhase: dashPhase,
                        clockwise: true
                    )
                    .frame(width: 224 * scale, height: 124 * scale)
                    
                    // Bottom Flowing Arrow
                    PremiumFlowingArrow(
                        shape: Page5BottomArrowShape(),
                        colors: [.pink, .purple, .cyan],
                        scale: scale,
                        dashPhase: dashPhase,
                        clockwise: true
                    )
                    .frame(width: 224 * scale, height: 124 * scale)
                    
                    // Glassmorphic Devices HStack
                    HStack(spacing: 24 * scale) {
                        // Portrait Left Glass Card
                        ZStack {
                            RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                                .fill(.ultraThinMaterial.opacity(0.15))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color(red: 0.0, green: 0.7, blue: 1.0), .blue.opacity(0.2)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 2 * scale
                                        )
                                }
                                .shadow(color: Color.blue.opacity(0.45), radius: 10 * scale)
                            
                            // play icon in center
                            playIcon(scale: scale)
                        }
                        .frame(width: 76 * scale, height: 124 * scale)
                        
                        // Landscape Right Glass Card
                        ZStack {
                            RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                                .fill(.ultraThinMaterial.opacity(0.15))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color(red: 1.0, green: 0.35, blue: 0.9), .pink.opacity(0.2)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 2 * scale
                                        )
                                }
                                .shadow(color: Color.pink.opacity(0.45), radius: 10 * scale)
                            
                            // play icon in center
                            playIcon(scale: scale)
                        }
                        .frame(width: 124 * scale, height: 76 * scale)
                    }
                }
                .offset(y: floatOffset)
            }
            .frame(height: 230 * scale)
            .padding(.top, 10 * scale)
            
            // Features Row
            HStack(spacing: 24 * scale) {
                featureItem(iconName: "bolt.fill", title: "Instant\nConversion", color: Color(red: 0.12, green: 0.65, blue: 1.0))
                featureItem(iconName: "lock.shield.fill", title: "100%\nPrivate", color: Color(red: 0.60, green: 0.30, blue: 1.0))
                featureItem(iconName: "checkmark.seal.fill", title: "No Quality\nLoss", color: Color(red: 1.0, green: 0.20, blue: 0.85))
            }
            .padding(.horizontal, 10)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                floatOffset = -6 * scale
            }
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                dashPhase = 100
            }
            withAnimation(.linear(duration: 25.0).repeatForever(autoreverses: false)) {
                rotationAngle = 360
            }
        }
    }
    
    private func playIcon(scale: CGFloat) -> some View {
        Image(systemName: "play.fill")
            .font(.system(size: 26 * scale, weight: .bold))
            .foregroundStyle(
                LinearGradient(
                    colors: [.white, Color(red: 0.85, green: 0.95, blue: 1.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .shadow(color: .cyan.opacity(0.5), radius: 6 * scale)
            .offset(x: 1.5 * scale)
    }
    
    private func featureItem(iconName: String, title: String, color: Color) -> some View {
        VStack(spacing: 10 * scale) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 62 * scale, height: 62 * scale)
                
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(0.6), color.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5 * scale
                    )
                    .frame(width: 62 * scale, height: 62 * scale)
                    .shadow(color: color.opacity(0.3), radius: 6 * scale)
                
                Image(systemName: iconName)
                    .font(.system(size: 22 * scale, weight: .bold))
                    .foregroundStyle(color)
            }
            
            Text(title)
                .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 36 * scale, alignment: .top)
        }
    }
}

private struct OrbitCircle: View {
    let radius: CGFloat
    let dots: [Double]
    let dotColor: Color
    let scale: CGFloat
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .clear, .white.opacity(0.04), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1 * scale
                )
                .frame(width: radius * 2, height: radius * 2)
            
            ForEach(dots, id: \.self) { angle in
                Circle()
                    .fill(dotColor)
                    .frame(width: 5 * scale, height: 5 * scale)
                    .shadow(color: dotColor, radius: 4 * scale)
                    .offset(x: radius)
                    .rotationEffect(.degrees(angle))
            }
        }
    }
}

private struct TikTokLogoBadge: View {
    let scale: CGFloat
    
    var body: some View {
        RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
            .fill(Color.black)
            .frame(width: 34 * scale, height: 34 * scale)
            .overlay {
                ZStack {
                    Image(systemName: "music.note")
                        .font(.system(size: 15 * scale, weight: .black))
                        .foregroundStyle(Color.red)
                        .offset(x: -1, y: -1)
                    
                    Image(systemName: "music.note")
                        .font(.system(size: 15 * scale, weight: .black))
                        .foregroundStyle(Color.cyan)
                        .offset(x: 1, y: 1)
                    
                    Image(systemName: "music.note")
                        .font(.system(size: 15 * scale, weight: .black))
                        .foregroundStyle(Color.white)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 3)
    }
}

private struct YouTubeLogoBadge: View {
    let scale: CGFloat
    
    var body: some View {
        RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
            .fill(Color.red)
            .frame(width: 34 * scale, height: 34 * scale)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 14 * scale, weight: .black))
                    .foregroundStyle(.white)
            }
            .shadow(color: .red.opacity(0.3), radius: 4)
    }
}

private struct WaveShape: Shape {
    let offset: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        path.move(to: CGPoint(x: 0, y: h * 0.5))
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.5),
            control1: CGPoint(x: w * 0.3, y: h * 0.4 + offset),
            control2: CGPoint(x: w * 0.7, y: h * 0.6 + offset)
        )
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
        
        return path
    }
}

private struct SurferVideoView: View {
    let isLandscape: Bool
    
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let scale = w / (isLandscape ? 154.0 : 92.0)
            
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.15, green: 0.22, blue: 0.45), Color(red: 0.85, green: 0.45, blue: 0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                Circle()
                    .fill(Color(red: 1.0, green: 0.80, blue: 0.40))
                    .frame(width: 48 * scale, height: 48 * scale)
                    .blur(radius: 2)
                    .offset(x: w * 0.15, y: -h * 0.05)
                
                WaveShape(offset: -10)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.0, green: 0.45, blue: 0.65), Color(red: 0.0, green: 0.25, blue: 0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .offset(y: h * 0.2)
                
                WaveShape(offset: 15)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.0, green: 0.55, blue: 0.75).opacity(0.8), Color(red: 0.0, green: 0.15, blue: 0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .offset(y: h * 0.25)
                
                VStack(spacing: 0) {
                    Image(systemName: "figure.surfing")
                        .font(.system(size: 24 * scale, weight: .bold))
                        .foregroundStyle(Color(red: 0.05, green: 0.05, blue: 0.15))
                        .shadow(color: .black.opacity(0.3), radius: 2)
                    
                    Ellipse()
                        .fill(Color(red: 0.05, green: 0.05, blue: 0.15))
                        .frame(width: 28 * scale, height: 4 * scale)
                        .offset(y: -2 * scale)
                }
                .offset(x: -w * 0.1, y: h * 0.16)
            }
            .frame(width: w, height: h)
        }
    }
}

private struct MountainVideoView: View {
    let isLandscape: Bool
    
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let scale = w / (isLandscape ? 150.0 : 92.0)
            
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.04, blue: 0.18), Color(red: 0.1, green: 0.15, blue: 0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                RadialGradient(
                    colors: [Color(red: 0.1, green: 0.8, blue: 0.4).opacity(0.35), Color.clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 90 * scale
                )
                .blendMode(.screen)
                
                Group {
                    Circle().fill(Color.white).frame(width: 1.5).offset(x: -w * 0.25, y: -h * 0.25)
                    Circle().fill(Color.white).frame(width: 1).offset(x: w * 0.1, y: -h * 0.35)
                    Circle().fill(Color.white).frame(width: 1.5).offset(x: w * 0.3, y: -h * 0.15)
                    Circle().fill(Color.white).frame(width: 1).offset(x: -w * 0.15, y: -h * 0.1)
                }
                
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w * 0.25, y: h * 0.55))
                    path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.8))
                    path.addLine(to: CGPoint(x: w * 0.75, y: h * 0.45))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.05, green: 0.05, blue: 0.15), Color(red: 0.02, green: 0.02, blue: 0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.65))
                    path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.75))
                    path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.6))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.08, blue: 0.2).opacity(0.8), Color(red: 0.03, green: 0.03, blue: 0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                PlayButtonView(scale: scale * 0.8, animate: true)
            }
            .frame(width: w, height: h)
        }
    }
}

private struct PineTree: View {
    let scale: CGFloat
    
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: -18 * scale))
            path.addLine(to: CGPoint(x: 6 * scale, y: -6 * scale))
            path.addLine(to: CGPoint(x: 3 * scale, y: -6 * scale))
            path.addLine(to: CGPoint(x: 8 * scale, y: 4 * scale))
            path.addLine(to: CGPoint(x: 4 * scale, y: 4 * scale))
            path.addLine(to: CGPoint(x: 10 * scale, y: 16 * scale))
            path.addLine(to: CGPoint(x: -10 * scale, y: 16 * scale))
            path.addLine(to: CGPoint(x: -4 * scale, y: 4 * scale))
            path.addLine(to: CGPoint(x: -8 * scale, y: 4 * scale))
            path.addLine(to: CGPoint(x: -3 * scale, y: -6 * scale))
            path.addLine(to: CGPoint(x: -6 * scale, y: -6 * scale))
            path.closeSubpath()
        }
        .fill(Color(red: 0.03, green: 0.05, blue: 0.12))
    }
}

private struct HikerVideoView: View {
    let isLandscape: Bool
    
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let scale = w / (isLandscape ? 150.0 : 92.0)
            
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.1, green: 0.1, blue: 0.35),
                        Color(red: 0.8, green: 0.3, blue: 0.5),
                        Color(red: 0.95, green: 0.6, blue: 0.3)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                Circle()
                    .fill(Color(red: 1.0, green: 0.85, blue: 0.5))
                    .frame(width: 38 * scale, height: 38 * scale)
                    .blur(radius: 1.5)
                    .offset(x: -w * 0.15, y: h * 0.1)
                
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.5))
                    path.addLine(to: CGPoint(x: w * 0.6, y: h * 0.72))
                    path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.48))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.08, green: 0.06, blue: 0.18))
                
                Group {
                    PineTree(scale: scale).offset(x: w * 0.1, y: h * 0.68)
                    PineTree(scale: scale * 0.8).offset(x: w * 0.15, y: h * 0.7)
                    PineTree(scale: scale * 1.2).offset(x: w * 0.78, y: h * 0.65)
                    PineTree(scale: scale * 0.9).offset(x: w * 0.85, y: h * 0.68)
                }
                
                HStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 0) {
                        Image(systemName: "figure.hiking")
                            .font(.system(size: 22 * scale, weight: .bold))
                            .foregroundStyle(Color(red: 0.05, green: 0.03, blue: 0.1))
                            .shadow(color: .black.opacity(0.4), radius: 2)
                        
                        Rectangle()
                            .fill(Color(red: 0.05, green: 0.03, blue: 0.1))
                            .frame(width: 32 * scale, height: 40 * scale)
                    }
                    .offset(x: isLandscape ? -w * 0.15 : -w * 0.05, y: h * 0.24)
                }
                
                Circle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 30 * scale, height: 30 * scale)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11 * scale, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 4)
            }
            .frame(width: w, height: h)
        }
    }
}

private struct PremiumMonitorMockup<Content: View>: View {
    let content: Content
    
    @State private var animateGlow = false
    @State private var floatingOffset: CGFloat = 0
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let scale = w / 218.0
            let cornerRadius = 16 * scale
            
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
                    .blur(radius: 12 * scale)
                    .offset(y: 8 * scale)
                    .scaleEffect(animateGlow ? 1.04 : 0.98)
                
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(white: 0.08))
                        .frame(width: w, height: h * 0.86)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color(white: 0.95),
                                            Color(white: 0.50),
                                            Color(white: 0.85),
                                            Color(white: 0.35),
                                            Color(white: 0.90),
                                            Color(white: 0.45),
                                            Color(white: 0.98)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2.8 * scale
                                )
                        }
                        .overlay {
                            ZStack {
                                RoundedRectangle(cornerRadius: cornerRadius - 3.5 * scale, style: .continuous)
                                    .fill(Color(white: 0.04))
                                
                                content
                                
                                GlassSheenOverlay(isLandscape: true, scale: scale)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius - 3.5 * scale, style: .continuous))
                            .padding(4.0 * scale)
                        }
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.35), Color(white: 0.15)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 16 * scale, height: h * 0.10)
                    
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.45), Color(white: 0.18)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 72 * scale, height: 8 * scale)
                        .offset(y: -2 * scale)
                }
            }
            .offset(y: floatingOffset)
        }
        .aspectRatio(1.5, contentMode: .fit)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0...0.5)) {
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    floatingOffset = 4.5
                }
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                animateGlow = true
            }
        }
    }
}

private struct PremiumDeviceMockup: View {
    let isLandscape: Bool
    let content: AnyView
    var customGlowColor: Color? = nil
    var customBezelGradient: LinearGradient? = nil
    
    @State private var animateGlow = false
    @State private var floatingOffset: CGFloat = 0
    
    init(isLandscape: Bool, customGlowColor: Color? = nil, customBezelGradient: LinearGradient? = nil) {
        self.isLandscape = isLandscape
        self.customGlowColor = customGlowColor
        self.customBezelGradient = customBezelGradient
        self.content = AnyView(
            ZStack {
                DeviceScreenArtwork(isLandscape: isLandscape, scale: 1.0, animate: true)
                PlayButtonView(scale: 1.0, animate: true)
            }
        )
    }
    
    init<Content: View>(isLandscape: Bool, customGlowColor: Color? = nil, customBezelGradient: LinearGradient? = nil, @ViewBuilder content: () -> Content) {
        self.isLandscape = isLandscape
        self.customGlowColor = customGlowColor
        self.customBezelGradient = customBezelGradient
        self.content = AnyView(content())
    }
    
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let scale = w / (isLandscape ? 218.0 : 133.0)
            let cornerRadius = (isLandscape ? 26 : 28) * scale
            
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(customGlowColor?.opacity(0.35) ?? (isLandscape ? Color.pink.opacity(0.12) : Color.blue.opacity(0.12)))
                    .blur(radius: (customGlowColor != nil ? 18 : 12) * scale)
                    .offset(y: 8 * scale)
                    .scaleEffect(animateGlow ? 1.04 : 0.98)
                
                SideButtonsView(isLandscape: isLandscape, width: w, height: h, scale: scale)
                
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(white: 0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                customBezelGradient ?? LinearGradient(
                                    colors: [
                                        Color(white: 0.95),
                                        Color(white: 0.50),
                                        Color(white: 0.85),
                                        Color(white: 0.35),
                                        Color(white: 0.90),
                                        Color(white: 0.45),
                                        Color(white: 0.98)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: (customBezelGradient != nil ? 3.2 : 2.8) * scale
                            )
                    }
                
                RoundedRectangle(cornerRadius: cornerRadius - 1.5 * scale, style: .continuous)
                    .stroke(Color.black, lineWidth: 2.0 * scale)
                    .padding(2.0 * scale)
                
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius - 3.5 * scale, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.02, green: 0.04, blue: 0.12),
                                    Color(red: 0.08, green: 0.06, blue: 0.22),
                                    Color(red: 0.04, green: 0.03, blue: 0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    content
                    
                    DynamicIslandView(isLandscape: isLandscape, width: w, height: h, scale: scale)
                    
                    GlassSheenOverlay(isLandscape: isLandscape, scale: scale)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius - 3.5 * scale, style: .continuous))
                .padding(4.0 * scale)
            }
            .offset(y: floatingOffset)
        }
        .aspectRatio(isLandscape ? 1.65 : 0.62, contentMode: .fit)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0...0.5)) {
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    floatingOffset = isLandscape ? 4.5 : -4.5
                }
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                animateGlow = true
            }
        }
    }
}

private struct SideButtonsView: View {
    let isLandscape: Bool
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    
    var body: some View {
        ZStack {
            if !isLandscape {
                // Portrait Buttons (Left: Volume, Right: Power)
                // Volume Up
                RoundedRectangle(cornerRadius: 1 * scale)
                    .fill(Color(white: 0.8))
                    .frame(width: 2 * scale, height: 12 * scale)
                    .offset(x: -width/2 - 1 * scale, y: -height * 0.12)
                
                // Volume Down
                RoundedRectangle(cornerRadius: 1 * scale)
                    .fill(Color(white: 0.8))
                    .frame(width: 2 * scale, height: 12 * scale)
                    .offset(x: -width/2 - 1 * scale, y: -height * 0.04)
                
                // Power
                RoundedRectangle(cornerRadius: 1 * scale)
                    .fill(Color(white: 0.8))
                    .frame(width: 2 * scale, height: 18 * scale)
                    .offset(x: width/2 + 1 * scale, y: -height * 0.08)
            } else {
                // Landscape Buttons (Top: Volume, Bottom: Power)
                // Volume Up
                RoundedRectangle(cornerRadius: 1 * scale)
                    .fill(Color(white: 0.8))
                    .frame(width: 12 * scale, height: 2 * scale)
                    .offset(x: -width * 0.12, y: -height/2 - 1 * scale)
                
                // Volume Down
                RoundedRectangle(cornerRadius: 1 * scale)
                    .fill(Color(white: 0.8))
                    .frame(width: 12 * scale, height: 2 * scale)
                    .offset(x: -width * 0.04, y: -height/2 - 1 * scale)
                
                // Power
                RoundedRectangle(cornerRadius: 1 * scale)
                    .fill(Color(white: 0.8))
                    .frame(width: 18 * scale, height: 2 * scale)
                    .offset(x: -width * 0.08, y: height/2 + 1 * scale)
            }
        }
    }
}

private struct DynamicIslandView: View {
    let isLandscape: Bool
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    
    var body: some View {
        ZStack {
            if !isLandscape {
                Capsule()
                    .fill(Color.black)
                    .frame(width: width * 0.28, height: 7.5 * scale)
                    .overlay {
                        Circle()
                            .fill(Color(red: 0.08, green: 0.08, blue: 0.2))
                            .frame(width: 3 * scale, height: 3 * scale)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 6 * scale)
                    }
                    .offset(y: -height * 0.44)
            } else {
                // Landscape dynamic island on the left frame edge
                Capsule()
                    .fill(Color.black)
                    .frame(width: 7.5 * scale, height: height * 0.28)
                    .overlay {
                        Circle()
                            .fill(Color(red: 0.08, green: 0.08, blue: 0.2))
                            .frame(width: 3 * scale, height: 3 * scale)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 6 * scale)
                    }
                    .offset(x: -width * 0.44)
            }
        }
    }
}

private struct DeviceScreenArtwork: View {
    let isLandscape: Bool
    let scale: CGFloat
    let animate: Bool
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    RadialGradient(
                        colors: [Color.cyan.opacity(0.18), Color.purple.opacity(0.02), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 80 * scale
                    ),
                    lineWidth: 1
                )
                .scaleEffect(animate ? 1.15 : 0.95)
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: animate)
            
            VStack(spacing: 4 * scale) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 2 * scale)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.12 - Double(i) * 0.02),
                                    Color.pink.opacity(0.15 - Double(i) * 0.02)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: (isLandscape ? 120 : 60) * scale, height: 3 * scale)
                        .offset(x: CGFloat(sin(Double(i) * 1.5)) * 8 * scale)
                }
            }
            .rotationEffect(.degrees(isLandscape ? -10 : -25))
            .opacity(0.65)
        }
    }
}

private struct PlayButtonView: View {
    let scale: CGFloat
    let animate: Bool
    
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.cyan, Color.purple, Color.pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32 * scale, height: 32 * scale)
                .blur(radius: animate ? 10 * scale : 6 * scale)
                .opacity(0.65)
                .scaleEffect(animate ? 1.08 : 0.96)
            
            Circle()
                .fill(.ultraThinMaterial.opacity(0.65))
                .overlay {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.8), .cyan.opacity(0.4), .pink.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5 * scale
                        )
                }
                .frame(width: 34 * scale, height: 34 * scale)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            
            Image(systemName: "play.fill")
                .font(.system(size: 13 * scale, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.8, green: 0.95, blue: 1.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(x: 1.5 * scale)
        }
    }
}

private struct GlassSheenOverlay: View {
    let isLandscape: Bool
    let scale: CGFloat
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            Path { path in
                path.move(to: CGPoint(x: -w * 0.2, y: 0))
                path.addLine(to: CGPoint(x: w * 0.6, y: 0))
                path.addLine(to: CGPoint(x: w * 0.2, y: h))
                path.addLine(to: CGPoint(x: -w * 0.6, y: h))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(0.12),
                        .white.opacity(0.04),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: w * 0.4, y: 0))
                path.addLine(to: CGPoint(x: 0, y: h * 0.25))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(0.18),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

private struct CurvedArrowShape: Shape {
    let clockwise: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()

        if clockwise {
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.midY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX * 0.92, y: rect.midY + rect.height * 0.12),
                control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.1)
            )
            path.move(to: CGPoint(x: rect.maxX * 0.92, y: rect.midY + rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.maxX * 0.78, y: rect.midY + rect.height * 0.02))
            path.move(to: CGPoint(x: rect.maxX * 0.92, y: rect.midY + rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.maxX * 0.83, y: rect.midY + rect.height * 0.28))
        } else {
            path.move(to: CGPoint(x: rect.maxX * 0.9, y: rect.midY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY - rect.height * 0.08),
                control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.06)
            )
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY - rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.midY - rect.height * 0.2))
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY - rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.midY + rect.height * 0.05))
        }

        return path
    }
}

private struct ConversionHeroView: View {
    let image: UIImage?
    let inputAspectRatio: CGFloat
    let outputFormat: FrameFormat
    let scale: CGFloat

    @State private var dashPhase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let baseHeight = min(height * 0.72, width * 0.62)
            let inputSize = frameSize(aspectRatio: inputAspectRatio, container: proxy.size, baseHeight: baseHeight)
            let outputSize = frameSize(aspectRatio: outputFormat.aspectRatio, container: proxy.size, baseHeight: baseHeight)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.purple.opacity(0.24), .blue.opacity(0.16), .clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 190
                        )
                    )
                    .blur(radius: 22)
                    .frame(width: width * 0.82, height: width * 0.82)

                CurvedArrowShape(clockwise: true)
                    .trim(from: 0.03, to: 0.88)
                    .stroke(
                        LinearGradient(
                            colors: [.blue, .purple, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 6 * scale, lineCap: .round, dash: [6 * scale, 12 * scale], dashPhase: dashPhase)
                    )
                    .frame(width: width * 0.58, height: height * 0.45)
                    .offset(x: width * 0.12, y: -height * 0.12)
                    .shadow(color: .pink.opacity(0.7), radius: 16)

                CurvedArrowShape(clockwise: false)
                    .trim(from: 0.03, to: 0.88)
                    .stroke(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 6 * scale, lineCap: .round, dash: [6 * scale, 12 * scale], dashPhase: -dashPhase)
                    )
                    .frame(width: width * 0.55, height: height * 0.34)
                    .offset(x: -width * 0.04, y: height * 0.2)
                    .shadow(color: .blue.opacity(0.65), radius: 16)

                ForEach(0..<10, id: \.self) { index in
                    Circle()
                        .fill(index.isMultiple(of: 2) ? Color.cyan : Color.pink)
                        .frame(width: 3.5 * scale, height: 3.5 * scale)
                        .blur(radius: 0.2)
                        .opacity(0.75)
                        .offset(
                            x: cos(Double(index) * 0.72) * width * 0.28,
                            y: sin(Double(index) * 0.72) * height * 0.28
                        )
                }

                HStack(alignment: .center, spacing: 22 * scale) {
                    ConversionVideoFrame(
                        image: image,
                        label: inputRatioLabel,
                        scale: scale,
                        isLandscape: inputAspectRatio > 1.1
                    )
                    .frame(width: inputSize.width, height: inputSize.height)

                    ConversionVideoFrame(
                        image: image,
                        label: outputFormat.subtitle,
                        scale: scale,
                        isLandscape: outputFormat == .landscape
                    )
                    .frame(width: outputSize.width, height: outputSize.height)
                }
                .frame(width: width, height: height, alignment: .center)
            }
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                    dashPhase = -18 * scale
                }
            }
        }
    }

    private var inputRatioLabel: String {
        if inputAspectRatio > 1.1 {
            return "16:9"
        }

        if inputAspectRatio < 0.9 {
            return "9:16"
        }

        return "1:1"
    }

    private func frameSize(aspectRatio: CGFloat, container: CGSize, baseHeight: CGFloat) -> CGSize {
        let safeAspectRatio = max(aspectRatio, 0.01)

        if safeAspectRatio > 1.1 {
            let frameWidth = min(container.width * 0.46, baseHeight * 1.34)
            return CGSize(width: frameWidth, height: frameWidth / safeAspectRatio)
        }

        if safeAspectRatio < 0.9 {
            let frameHeight = baseHeight
            return CGSize(width: frameHeight * safeAspectRatio, height: frameHeight)
        }

        let side = min(baseHeight * 0.72, container.width * 0.38)
        return CGSize(width: side, height: side)
    }
}

private struct ConversionVideoFrame: View {
    let image: UIImage?
    let label: String
    let scale: CGFloat
    let isLandscape: Bool

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let cornerRadius: CGFloat = 20 * scale

            ZStack {
                // Device Outer Shadow & Neon Glow
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isLandscape ? Color.pink.opacity(0.12) : Color.blue.opacity(0.12))
                    .blur(radius: 10 * scale)
                    .offset(y: 5 * scale)

                // Side buttons (Power, Volume)
                SideButtonsView(isLandscape: isLandscape, width: w, height: h, scale: scale)

                // Metal Frame Body (3D metal bevel edge)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(white: 0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color(white: 0.95),
                                        Color(white: 0.50),
                                        Color(white: 0.85),
                                        Color(white: 0.35),
                                        Color(white: 0.90),
                                        Color(white: 0.45),
                                        Color(white: 0.98)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2.2 * scale
                            )
                    }

                // Inner Screen Black Bezel
                RoundedRectangle(cornerRadius: cornerRadius - 1.2 * scale, style: .continuous)
                    .stroke(Color.black, lineWidth: 1.5 * scale)
                    .padding(1.5 * scale)

                // Screen Content
                ZStack {
                    // Futuristic screen gradient or Image background
                    RoundedRectangle(cornerRadius: cornerRadius - 2.8 * scale, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.02, green: 0.04, blue: 0.12),
                                    Color(red: 0.08, green: 0.06, blue: 0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: w - 6 * scale, height: h - 6 * scale)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius - 2.8 * scale, style: .continuous))
                            .overlay(.black.opacity(0.15))
                    }

                    // Glowing Glassmorphic Play button
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial.opacity(0.65))
                            .overlay {
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [.white.opacity(0.7), .cyan.opacity(0.3), .pink.opacity(0.5)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.5 * scale
                                    )
                            }
                            .frame(width: 40 * scale, height: 40 * scale)
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

                        Image(systemName: "play.fill")
                            .font(.system(size: 14 * scale, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 1.2 * scale)
                    }

                    // Dynamic Island Camera Cutout
                    DynamicIslandView(isLandscape: isLandscape, width: w, height: h, scale: scale)

                    // Shiny screen glare glass overlay
                    GlassSheenOverlay(isLandscape: isLandscape, scale: scale)

                    // Aspect ratio pill (bottom-right)
                    Text(label)
                        .font(.system(size: 12 * scale, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8 * scale)
                        .padding(.vertical, 5 * scale)
                        .background(.ultraThinMaterial.opacity(0.70), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8 * scale)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius - 2.8 * scale, style: .continuous))
                .padding(3.0 * scale)
            }
        }
    }
}

private struct PremiumProgressBar: View {
    let progress: Double
    let scale: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = max(12, width * min(max(progress, 0), 1))

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(.ultraThinMaterial.opacity(0.40))
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }

                // Progress Fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.65, blue: 1.0),
                                Color(red: 0.60, green: 0.30, blue: 1.0),
                                Color(red: 1.0, green: 0.20, blue: 0.85)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .shadow(color: .blue.opacity(0.45), radius: 8)
                    .shadow(color: .pink.opacity(0.35), radius: 8)

                // Glowing leading edge indicator
                if progress > 0.02 && progress < 0.98 {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12 * scale, height: 12 * scale)
                        .shadow(color: .white, radius: 4)
                        .shadow(color: .pink, radius: 8)
                        .offset(x: fillWidth - (6 * scale))
                }
            }
        }
    }
}

private struct LocalProcessingCard: View {
    let scale: CGFloat

    @State private var animateIcon = false

    var body: some View {
        HStack(spacing: 18 * scale) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 40 * scale, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan, .blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(animateIcon ? 1.05 : 0.95)
                .frame(width: 66 * scale, height: 66 * scale)
                .background(.ultraThinMaterial.opacity(0.4), in: RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 5 * scale) {
                Text("Processed locally")
                    .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Your video stays on your device.\n100% private and secure.")
                    .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.60))
                    .lineSpacing(3)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18 * scale)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.2), .clear, .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.3), radius: 15, y: 10)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                animateIcon = true
            }
        }
    }
}

private struct HomeActionCard: View {
    let scale: CGFloat
    let selectVideo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            HStack(alignment: .center, spacing: 16 * scale) {
                // 3D-bezeled Emblem/Token for the App Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                        .fill(Color(white: 0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color(white: 0.95),
                                            Color(white: 0.45),
                                            Color(white: 0.85),
                                            Color(white: 0.30),
                                            Color(white: 0.95)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2 * scale
                                )
                        }
                    
                    Image("FlipFrameIcon")
                        .resizable()
                        .scaledToFit()
                        .padding(2 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 18 * scale, style: .continuous))
                    
                    // Glass Sheen Highlight on Icon
                    GlassSheenOverlay(isLandscape: false, scale: scale)
                        .clipShape(RoundedRectangle(cornerRadius: 18 * scale, style: .continuous))
                }
                .frame(width: 72 * scale, height: 72 * scale)
                .shadow(color: .blue.opacity(0.35), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 5 * scale) {
                    Text("Choose a video to convert")
                        .font(.system(size: 21 * scale, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text("Vertical or horizontal. FlipFrame handles it instantly.")
                        .font(.system(size: 15 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
                }
            }

            Button(action: selectVideo) {
                Label("Select Video", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16 * scale)
                    .background {
                        LinearGradient(
                            colors: [
                                Color(red: 0.05, green: 0.55, blue: 1.0),
                                Color(red: 0.46, green: 0.22, blue: 1.0),
                                Color(red: 1.0, green: 0.18, blue: 0.86)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
                    .overlay {
                        // Glossy top edge highlight for the button
                        RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.45), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.5 * scale
                            )
                    }
                    .shadow(color: Color(red: 0.25, green: 0.38, blue: 1.0).opacity(0.45), radius: 16, y: 6)
                    .shadow(color: .pink.opacity(0.28), radius: 16, y: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(18 * scale)
        .background(.ultraThinMaterial.opacity(0.65), in: RoundedRectangle(cornerRadius: 30 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30 * scale, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .clear, .white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.36), radius: 24, y: 14)
    }
}

private struct HomeFeatureCard: View {
    let iconName: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 8 * scale) {
            Image(systemName: iconName)
                .font(.system(size: 25 * scale, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan, .blue, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 30 * scale)

            Text(title)
                .font(.system(size: 13 * scale, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            Text(subtitle)
                .font(.system(size: 11 * scale, weight: .regular))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112 * scale)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial.opacity(0.58), in: RoundedRectangle(cornerRadius: 22 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)
                .stroke(Color.purple.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct OutputPreview: View {
    let image: UIImage
    let originalAspectRatio: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let foregroundSize = foregroundSize(
                in: proxy.size,
                aspectRatio: originalAspectRatio
            )

            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 14)
                    .scaleEffect(1.08)
                    .overlay(.black.opacity(0.06))
                    .clipped()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: foregroundSize.width, height: foregroundSize.height)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
    }

    private func foregroundSize(in containerSize: CGSize, aspectRatio: CGFloat) -> CGSize {
        let safeAspectRatio = max(aspectRatio, 0.01)
        let containerAspectRatio = containerSize.width / max(containerSize.height, 1)

        if containerAspectRatio > safeAspectRatio {
            let height = containerSize.height
            return CGSize(width: height * safeAspectRatio, height: height)
        }

        let width = containerSize.width
        return CGSize(width: width, height: width / safeAspectRatio)
    }
}

private struct SaveStatusView: View {
    let state: SavePopupState
    let exportedURL: URL?
    let save: () -> Void
    let share: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if state == .actions {
                actionContent
            } else {
                statusContent
            }
        }
        .padding(24)
        .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.blue.opacity(0.55), .purple.opacity(0.32), .pink.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        }
        .shadow(color: .black.opacity(0.38), radius: 28, y: 16)
        .shadow(color: .purple.opacity(0.26), radius: 24, y: 8)
    }

    private var actionContent: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.05, green: 0.55, blue: 1.0),
                                Color(red: 0.48, green: 0.24, blue: 1.0),
                                Color(red: 1.0, green: 0.18, blue: 0.86)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                    .shadow(color: .purple.opacity(0.35), radius: 14, y: 6)

                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text(state.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(state.message)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.64))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button {
                    save()
                } label: {
                    Label("Save Video", systemImage: "square.and.arrow.down")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.05, green: 0.55, blue: 1.0),
                                    Color(red: 0.46, green: 0.22, blue: 1.0),
                                    Color(red: 1.0, green: 0.18, blue: 0.86)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                }
                .buttonStyle(.plain)

                if let exportedURL {
                    ShareLink(item: exportedURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(.thinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(.white.opacity(0.14), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            share()
                            dismiss()
                        }
                    )
                }
            }
        }
    }

    private var statusContent: some View {
        VStack(spacing: 18) {
            statusIcon

            VStack(spacing: 6) {
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(state.message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
            }

            if state != .saving {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .idle:
            EmptyView()
        case .actions:
            EmptyView()
        case .saving:
            ProgressView()
                .controlSize(.large)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }
}
