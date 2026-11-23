import Foundation
import ImageIO
import UIKit

/// Image I/O work must finish before publishing an image to SwiftUI's main actor.
enum ImageDecoding {
    static func image(from data: Data, maximumPixelSize: Int? = nil) async throws -> UIImage {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    throw ImageStorageError.invalidImage
                }
                let image: CGImage?
                if let maximumPixelSize {
                    image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                } else {
                    image = CGImageSourceCreateImageAtIndex(source, 0,
                        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                }
                guard let image else { throw ImageStorageError.invalidImage }
                try Task.checkCancellation()
                let orientation: UIImage.Orientation
                if maximumPixelSize == nil,
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let value = properties[kCGImagePropertyOrientation] as? Int {
                    switch value {
                    case 2: orientation = .upMirrored
                    case 3: orientation = .down
                    case 4: orientation = .downMirrored
                    case 5: orientation = .leftMirrored
                    case 6: orientation = .right
                    case 7: orientation = .rightMirrored
                    case 8: orientation = .left
                    default: orientation = .up
                    }
                } else { orientation = .up }
                return UIImage(cgImage: image, scale: 1, orientation: orientation)
            }
        }
        return try await withTaskCancellationHandler {
            let image = try await work.value
            try Task.checkCancellation()
            return image
        } onCancel: { work.cancel() }
    }

    /// Inspect compressed data without allocating a full decoded page for prefetching.
    static func isValid(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0
    }

    static func read(from url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled, let data = try? Data(contentsOf: url), isValid(data) else { return nil }
            return data
        }.value
    }

    static func validate(_ data: Data) async throws {
        let valid = await Task.detached(priority: .utility) { isValid(data) }.value
        try Task.checkCancellation()
        guard valid else { throw ImageStorageError.invalidImage }
    }
}
