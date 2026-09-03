import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FoundationCore

/// An image ready to both display and send.
///
/// The full-resolution decode is kept alongside the downscaled one. That is the
/// whole point of cropping: a region taken from the original recovers detail the
/// downscaled copy has already thrown away, so cropping from `display` would be
/// a picture of a crop rather than a closer look.
public struct LoadedImage: Sendable {
    /// Full-resolution decode, the source for any crop.
    public let original: CGImage
    /// Downscaled copy used for display and for sending the whole frame.
    public let display: CGImage
    /// Downscaled JPEG bytes of the whole frame.
    public let jpegData: Data
    public let sentWidth: Int
    public let sentHeight: Int

    public var originalWidth: Int { original.width }
    public var originalHeight: Int { original.height }
    public var wasDownscaled: Bool { sentWidth != originalWidth || sentHeight != originalHeight }

    public var imageInput: ImageInput { ImageInput(data: jpegData.base64EncodedString()) }

    /// Pixel rect in the original image for a selection given in 0–1 coordinates.
    public func pixelRect(for normalized: CGRect) -> CGRect {
        CGRect(
            x: (normalized.minX * CGFloat(originalWidth)).rounded(.down),
            y: (normalized.minY * CGFloat(originalHeight)).rounded(.down),
            width: max(1, (normalized.width * CGFloat(originalWidth)).rounded()),
            height: max(1, (normalized.height * CGFloat(originalHeight)).rounded())
        )
    }

    /// Re-derives the whole frame at a different size, always from the original
    /// so repeated changes never compound resampling artefacts.
    public func resized(maxDimension: Int) throws -> LoadedImage {
        try ImageLoading.make(from: original, maxDimension: maxDimension)
    }

    /// Crops from the original and re-encodes, downscaling only if the crop is
    /// still larger than `maxDimension`. A small selection is therefore sent at
    /// its native resolution — more pixels on the subject than the full frame
    /// could ever carry.
    public func cropped(to normalized: CGRect, maxDimension: Int = 1024) throws -> LoadedImage {
        let rect = pixelRect(for: normalized).intersection(
            CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
        )
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let cut = original.cropping(to: rect) else {
            throw ImageLoading.Failure.emptySelection
        }
        return try ImageLoading.make(from: cut, maxDimension: maxDimension)
    }
}

public enum ImageLoading {
    public enum Failure: Error, LocalizedError {
        case unreadable
        case encodingFailed
        case emptySelection
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "That file could not be read as an image"
            case .encodingFailed: return "The image could not be re-encoded for sending"
            case .emptySelection: return "That selection is empty"
            }
        }
    }

    /// Decodes and downscales in one pass.
    ///
    /// The longest edge is capped because the model resamples internally anyway:
    /// full-resolution uploads cost time and body size without improving the
    /// answer. This mirrors what `scripts/ask-image.sh` does with `sips`, so a
    /// result seen in the app matches one seen from the shell.
    public static func load(_ data: Data, maxDimension: Int = 1024) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadable
        }
        return try make(from: full, maxDimension: maxDimension)
    }

    public static func load(contentsOf url: URL, maxDimension: Int = 1024) throws -> LoadedImage {
        // Harmless when unsandboxed; required once this ships as a sandboxed app.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try load(try Data(contentsOf: url), maxDimension: maxDimension)
    }

    /// `maxDimension` caps the longest edge. A source already smaller than the cap
    /// is sent untouched — upscaling would invent pixels rather than reveal any,
    /// so the cap can only ever remove detail, never add it.
    static func make(from full: CGImage, maxDimension: Int) throws -> LoadedImage {
        let scaled = max(full.width, full.height) > maxDimension
            ? (downscale(full, to: maxDimension) ?? full)
            : full
        return LoadedImage(
            original: full,
            display: scaled,
            jpegData: try jpeg(scaled),
            sentWidth: scaled.width,
            sentHeight: scaled.height
        )
    }

    private static func downscale(_ image: CGImage, to maxDimension: Int) -> CGImage? {
        let scale = CGFloat(maxDimension) / CGFloat(max(image.width, image.height))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw Failure.encodingFailed }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodingFailed }
        return out as Data
    }
}
