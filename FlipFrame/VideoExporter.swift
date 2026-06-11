@preconcurrency import AVFoundation
import CoreImage
import Photos
import UIKit

enum FrameFormat: String, CaseIterable, Identifiable {
    case landscape
    case portrait
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape:
            NSLocalizedString("Landscape", comment: "")
        case .portrait:
            NSLocalizedString("Portrait", comment: "")
        case .square:
            NSLocalizedString("Square", comment: "")
        }
    }

    var subtitle: String {
        switch self {
        case .landscape:
            "16:9"
        case .portrait:
            "9:16"
        case .square:
            "1:1"
        }
    }

    var iconName: String {
        switch self {
        case .landscape:
            "rectangle"
        case .portrait:
            "rectangle.portrait"
        case .square:
            "square"
        }
    }

    var aspectRatio: CGFloat {
        switch self {
        case .landscape:
            16.0 / 9.0
        case .portrait:
            9.0 / 16.0
        case .square:
            1.0
        }
    }

    var renderSize: CGSize {
        ExportQuality.medium.renderSize(for: self)
    }

    func renderSize(longSide: CGFloat) -> CGSize {
        let evenLongSide = longSide.rounded(.down).nearestEven

        switch self {
        case .landscape:
            return CGSize(width: evenLongSide, height: (evenLongSide * 9 / 16).nearestEven)
        case .portrait:
            return CGSize(width: (evenLongSide * 9 / 16).nearestEven, height: evenLongSide)
        case .square:
            return CGSize(width: evenLongSide, height: evenLongSide)
        }
    }
}

private extension CGFloat {
    var nearestEven: CGFloat {
        let value = Int(self.rounded())
        return CGFloat(value.isMultiple(of: 2) ? value : value - 1)
    }
}

enum ExportQuality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            NSLocalizedString("Standard", comment: "")
        case .medium:
            NSLocalizedString("High", comment: "")
        case .high:
            NSLocalizedString("Maximum", comment: "")
        }
    }

    var presetName: String {
        switch self {
        case .low:
            AVAssetExportPresetMediumQuality
        case .medium:
            AVAssetExportPresetHighestQuality
        case .high:
            AVAssetExportPresetHighestQuality
        }
    }

    func renderSize(for format: FrameFormat) -> CGSize {
        renderSize(for: format, sourceSize: nil)
    }

    func renderSize(for format: FrameFormat, sourceSize: CGSize?) -> CGSize {
        let maxSourceSide = sourceSize.map { max($0.width, $0.height) } ?? 1920
        let targetLongSide: CGFloat

        switch self {
        case .low:
            targetLongSide = min(maxSourceSide, 1280)
        case .medium:
            targetLongSide = min(maxSourceSide, 1920)
        case .high:
            if maxSourceSide >= 2160 {
                targetLongSide = min(maxSourceSide, 3840)
            } else {
                targetLongSide = min(maxSourceSide, 1920)
            }
        }

        return format.renderSize(longSide: targetLongSide)
    }

    func estimatedVideoBitrateMbps(for sourceSize: CGSize?) -> Double {
        let maxSourceSide = sourceSize.map { max($0.width, $0.height) } ?? 1920

        if maxSourceSide >= 2160 {
            switch self {
            case .low:
                return 8
            case .medium:
                return 16
            case .high:
                return 45
            }
        }

        if maxSourceSide >= 1280 {
            switch self {
            case .low:
                return 4.5
            case .medium:
                return 9
            case .high:
                return 16
            }
        }

        switch self {
        case .low:
            return 2.5
        case .medium:
            return 5
        case .high:
            return 8
        }
    }

}

enum VideoExportError: LocalizedError {
    case cannotCreateExporter
    case exportFailed
    case exportedFileMissing

    var errorDescription: String? {
        switch self {
        case .cannotCreateExporter:
            "Could not start the video exporter."
        case .exportFailed:
            "The video could not be converted."
        case .exportedFileMissing:
            "The exported video file could not be found."
        }
    }
}

struct VideoExporter {
    func bestPreset(for asset: AVAsset, targetSize: CGSize) -> String {
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let targetLongSide = max(targetSize.width, targetSize.height)

        if targetLongSide >= 3840 {
            if compatiblePresets.contains(AVAssetExportPreset3840x2160) {
                return AVAssetExportPreset3840x2160
            }
            if compatiblePresets.contains(AVAssetExportPresetHEVC3840x2160) {
                return AVAssetExportPresetHEVC3840x2160
            }
        }

        if targetLongSide >= 1920 {
            if compatiblePresets.contains(AVAssetExportPreset1920x1080) {
                return AVAssetExportPreset1920x1080
            }
            if compatiblePresets.contains(AVAssetExportPresetHEVC1920x1080) {
                return AVAssetExportPresetHEVC1920x1080
            }
        }

        if targetLongSide >= 1280 {
            if compatiblePresets.contains(AVAssetExportPreset1280x720) {
                return AVAssetExportPreset1280x720
            }
        }

        if compatiblePresets.contains(AVAssetExportPreset960x540) {
            return AVAssetExportPreset960x540
        }

        return AVAssetExportPresetMediumQuality
    }

    func export(
        asset: AVAsset,
        format: FrameFormat,
        quality: ExportQuality,
        includeWatermark: Bool,
        progressHandler: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipFrame-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        let sourceSize = sourceDisplaySize(for: asset)
        let renderSize = quality.renderSize(for: format, sourceSize: sourceSize)
        let preset = bestPreset(for: asset, targetSize: renderSize)

        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoExportError.cannotCreateExporter
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        exporter.videoComposition = makeVideoComposition(
            for: asset,
            renderSize: renderSize,
            includeWatermark: includeWatermark
        )

        return try await withCheckedThrowingContinuation { continuation in
            let progressTask = Task {
                while !Task.isCancelled {
                    await progressHandler(Double(exporter.progress))
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }

            exporter.exportAsynchronously {
                progressTask.cancel()

                switch exporter.status {
                case .completed:
                    Task { await progressHandler(1) }
                    continuation.resume(returning: outputURL)
                case .failed:
                    continuation.resume(throwing: exporter.error ?? VideoExportError.exportFailed)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: exporter.error ?? VideoExportError.exportFailed)
                }
            }
        }
    }

    func videoAsset(for photoAsset: PHAsset) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: photoAsset, options: options) { asset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                if let asset {
                    continuation.resume(returning: asset)
                } else {
                    continuation.resume(throwing: VideoExportError.exportFailed)
                }
            }
        }
    }

    func generatePosterImage(for asset: AVAsset) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 900, height: 900)

                do {
                    let image = try generator.copyCGImage(at: .zero, actualTime: nil)
                    continuation.resume(returning: UIImage(cgImage: image))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func posterImage(for photoAsset: PHAsset) async throws -> UIImage {
        let asset = try await videoAsset(for: photoAsset)
        return try await generatePosterImage(for: asset)
    }

    func playerItem(for photoAsset: PHAsset) async throws -> AVPlayerItem {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .mediumQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: photoAsset, options: options) { item, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                if let item {
                    continuation.resume(returning: item)
                } else {
                    continuation.resume(throwing: VideoExportError.exportFailed)
                }
            }
        }
    }

    func displaySize(for photoAsset: PHAsset) async throws -> CGSize {
        let asset = try await videoAsset(for: photoAsset)
        return sourceDisplaySize(for: asset) ?? CGSize(
            width: CGFloat(max(photoAsset.pixelWidth, 1)),
            height: CGFloat(max(photoAsset.pixelHeight, 1))
        )
    }

    func saveToPhotoLibrary(_ url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VideoExportError.exportedFileMissing
        }

        try await requestPhotoLibraryAccess()

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? VideoExportError.exportFailed)
                }
            }
        }
    }

    private func requestPhotoLibraryAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        if status == .authorized || status == .limited {
            return
        }

        let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard newStatus == .authorized || newStatus == .limited else {
            throw PHPhotosError(.accessUserDenied)
        }
    }

    func sourceDisplaySize(for asset: AVAsset) -> CGSize? {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            return nil
        }

        let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        return CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
    }

    private func makeVideoComposition(
        for asset: AVAsset,
        renderSize: CGSize,
        includeWatermark: Bool
    ) -> AVMutableVideoComposition {
        let watermark = includeWatermark ? watermarkOverlay(for: renderSize) : nil

        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let normalized = source.transformed(
                by: CGAffineTransform(
                    translationX: -source.extent.origin.x,
                    y: -source.extent.origin.y
                )
            )

            let outputRect = CGRect(origin: .zero, size: renderSize)
            let sourceSize = normalized.extent.size

            let fillScale = max(renderSize.width / sourceSize.width, renderSize.height / sourceSize.height)
            let fitScale = min(renderSize.width / sourceSize.width, renderSize.height / sourceSize.height)

            // Downscale background for 25x faster blur processing (5x downscale)
            let downscaleFactor = 0.2
            let backgroundScale = fillScale * downscaleFactor
            let backgroundSize = CGSize(
                width: (sourceSize.width * backgroundScale).rounded(.down).nearestEven,
                height: (sourceSize.height * backgroundScale).rounded(.down).nearestEven
            )
            let backgroundRect = CGRect(origin: .zero, size: backgroundSize)
            
            // Crop with padding before blur to restrict processing size and avoid infinite extent overhead
            let padding: CGFloat = 16.0
            let backgroundRectWithPadding = backgroundRect.insetBy(dx: -padding, dy: -padding)
            
            let smallBackground = normalized
                .clampedToExtent()
                .transformed(by: transform(for: sourceSize, in: backgroundSize, scale: backgroundScale))
                .cropped(to: backgroundRectWithPadding)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4.0]) // smaller blur radius on smaller size
                .cropped(to: backgroundRect)
            
            // Upscale the blurred background back to original render size
            let upscaleScale = 1.0 / downscaleFactor
            let background = smallBackground
                .transformed(by: CGAffineTransform(scaleX: upscaleScale, y: upscaleScale))
                .cropped(to: outputRect)

            let foreground = normalized
                .transformed(by: transform(for: sourceSize, in: renderSize, scale: fitScale))
                .cropped(to: outputRect)

            let finishedImage = foreground
                .composited(over: background)
                .cropped(to: outputRect)

            let outputImage: CIImage
            if let watermark {
                outputImage = watermark
                    .composited(over: finishedImage)
                    .cropped(to: outputRect)
            } else {
                outputImage = finishedImage
            }

            request.finish(with: outputImage, context: nil)
        }

        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        return videoComposition
    }

    private func watermarkOverlay(for renderSize: CGSize) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let image = renderer.image { context in
            let fontSize = max(42, min(renderSize.width, renderSize.height) * 0.14)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = fontSize * 0.12
            shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.04)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .black),
                .foregroundColor: UIColor.white.withAlphaComponent(0.24),
                .paragraphStyle: paragraph,
                .shadow: shadow
            ]

            let text = "FlipFrame" as NSString
            let textHeight = fontSize * 1.25
            let textRect = CGRect(
                x: -renderSize.width * 0.18,
                y: (renderSize.height - textHeight) / 2,
                width: renderSize.width * 1.36,
                height: textHeight
            )

            context.cgContext.setBlendMode(.normal)
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: renderSize.width / 2, y: renderSize.height / 2)
            context.cgContext.rotate(by: -.pi / 5.5)
            context.cgContext.translateBy(x: -renderSize.width / 2, y: -renderSize.height / 2)
            text.draw(in: textRect, withAttributes: attributes)
            context.cgContext.restoreGState()
        }

        guard let cgImage = image.cgImage else {
            return nil
        }

        return CIImage(cgImage: cgImage)
    }

    private func transform(for sourceSize: CGSize, in renderSize: CGSize, scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: (renderSize.width - sourceSize.width * scale) / 2,
            ty: (renderSize.height - sourceSize.height * scale) / 2
        )
    }
}
