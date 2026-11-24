import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A screenshot as the image_url of a Realtime input_image. The event goes over the WebRTC data
/// channel, whose messages stop at 64 KiB when the far end names no larger size, so a picture whose
/// base64 would not fit is encoded again, smaller, until it does.
enum VoiceScreen {
    enum DataURLResult: Equatable {
        case ok(String)
        case empty
        case invalidImage(bytes: Int)
        case tooLarge(bytes: Int)
    }

    /// Characters of base64 an image may take, leaving room for the rest of the event.
    static let limit = 60_000

    static func dataURL(_ jpeg: Data) -> String? {
        if case .ok(let url) = encodeDataURL(jpeg) { return url }
        return nil
    }

    static func encodeDataURL(_ jpeg: Data) -> DataURLResult {
        guard !jpeg.isEmpty else { return .empty }
        if let url = fitting(jpeg) { return .ok(url) }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return .invalidImage(bytes: jpeg.count)
        }
        // PokiCore's pictures are one pixel per point (402 × 874 on a 6.3-inch iPhone) at quality 0.6;
        // a busy screen comes to 50 KB, 66 000 characters of base64.
        var encodedAny = false
        for (side, quality) in [(874, 0.45), (700, 0.4), (560, 0.35)] {
            if let smaller = encode(source, side: side, quality: quality) {
                encodedAny = true
                if let url = fitting(smaller) { return .ok(url) }
            }
        }
        return encodedAny ? .tooLarge(bytes: jpeg.count) : .invalidImage(bytes: jpeg.count)
    }

    private static func fitting(_ data: Data) -> String? {
        let base64 = data.base64EncodedString()
        return base64.count <= limit ? "data:image/jpeg;base64," + base64 : nil
    }

    private static func encode(_ source: CGImageSource, side: Int, quality: Double) -> Data? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
