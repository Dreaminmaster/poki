import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// A photo or a PDF sent with a message. The model reads `images`; the message keeps `thumbnail` to
/// show what went with it.
struct ChatAttachment: Identifiable, Equatable {
    enum Kind: Equatable { case photo, pdf(name: String) }
    let id = UUID()
    var kind: Kind
    /// JPEG, a small square-ish picture for the field and the bubble.
    var thumbnail: Data
    /// JPEG for the model: the photo, or the PDF's first pages, one picture each.
    var images: [Data]
}

/// Turns what the owner picked into an attachment. Pictures go to the model as JPEG at most 1568
/// pixels on the longer side (larger ones are scaled down by the providers anyway); a PDF goes as
/// pictures of its first four pages, so every model that reads screenshots reads it.
enum AttachmentReader {
    enum Failure: Error { case unsupported, unreadable }

    static let modelSide = 1568
    static let thumbnailSide = 240
    static let pdfPages = 4

    static func photo(_ data: Data) throws -> ChatAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = jpeg(source, side: modelSide, quality: 0.82),
              let small = jpeg(source, side: thumbnailSide, quality: 0.7) else { throw Failure.unreadable }
        return ChatAttachment(kind: .photo, thumbnail: small, images: [full])
    }

    static func photo(_ image: UIImage) throws -> ChatAttachment {
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw Failure.unreadable }
        return try photo(data)
    }

    /// A file from Files: a picture or a PDF; anything else is not supported yet.
    static func file(_ url: URL) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .pdf) { return try pdf(url) }
        guard type.conforms(to: .image) else { throw Failure.unsupported }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return try photo(data)
    }

    private static func pdf(_ url: URL) throws -> ChatAttachment {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw Failure.unreadable }
        let pages = (0..<min(pdfPages, document.pageCount)).compactMap { document.page(at: $0) }
        let images = pages.compactMap { page -> Data? in
            let box = page.bounds(for: .mediaBox).size
            let scale = CGFloat(modelSide) / max(box.width, box.height, 1)
            return page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox).jpegData(compressionQuality: 0.8)
        }
        guard let first = images.first, let source = CGImageSourceCreateWithData(first as CFData, nil),
              let small = jpeg(source, side: thumbnailSide, quality: 0.7) else { throw Failure.unreadable }
        return ChatAttachment(kind: .pdf(name: url.deletingPathExtension().lastPathComponent), thumbnail: small, images: images)
    }

    private static func jpeg(_ source: CGImageSource, side: Int, quality: Double) -> Data? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Simulator test runs only: `SIMCTL_CHILD_POKI_TEST_ATTACHMENT=<file>` names a picture or a PDF that
/// goes with the first message sent, the way the plus menu's will, before the menu has its screen.
@MainActor
enum TestAttachment {
    private static var taken = false

    static func take() -> ChatAttachment? {
        guard !taken, let path = ProcessInfo.processInfo.environment["POKI_TEST_ATTACHMENT"] else { return nil }
        taken = true
        do {
            let item = try AttachmentReader.file(URL(fileURLWithPath: path))
            AppLog.shared.add("chat", "test attachment: \(item.images.count) picture(s), \(item.images.map(\.count).reduce(0, +)) bytes")
            return item
        } catch {
            AppLog.shared.add("chat", "test attachment unreadable: \(error)")
            return nil
        }
    }
}
#endif
