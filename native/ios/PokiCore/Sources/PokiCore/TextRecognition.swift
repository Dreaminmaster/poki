import Foundation
#if canImport(Vision) && canImport(ImageIO)
import Vision
import ImageIO
#endif

/// A line of text read from the screenshot. `box` is in parts of the picture (0 to 1, from the top
/// left), so it maps to screen points by multiplying with the screen size.
public struct RecognizedText: Sendable, Equatable {
    public var text: String
    public var box: Rect
    public init(text: String, box: Rect) {
        self.text = text
        self.box = box
    }
}

/// Text recognition on the phone (Vision). Nil where Vision is missing (Linux) or the picture cannot
/// be read.
enum TextRecognizer {
    static func recognize(png: Data, in region: Rect? = nil) -> [RecognizedText]? {
        #if canImport(Vision) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let input: CGImage
        let area: Rect
        if let region {
            let width = Double(image.width), height = Double(image.height)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let pixels = CGRect(x: region.x * width, y: region.y * height,
                                width: region.width * width, height: region.height * height).integral.intersection(bounds)
            guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return nil }
            input = crop
            area = Rect(x: pixels.minX / width, y: pixels.minY / height,
                        width: pixels.width / width, height: pixels.height / height)
        } else {
            input = image
            area = Rect(x: 0, y: 0, width: 1, height: 1)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = region == nil ? .accurate : .fast
        request.usesLanguageCorrection = false
        if #available(iOS 16, macOS 13, *), region == nil {
            request.automaticallyDetectsLanguage = true
        }
        do { try VNImageRequestHandler(cgImage: input, options: [:]).perform([request]) } catch { return nil }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, !best.string.isEmpty else { return nil }
            let b = observation.boundingBox
            let box = Rect(x: area.x + Double(b.minX) * area.width, y: area.y + Double(1 - b.maxY) * area.height,
                           width: Double(b.width) * area.width, height: Double(b.height) * area.height)
            return RecognizedText(text: best.string, box: box)
        }
        #else
        return nil
        #endif
    }
}

extension CoreHost {
    /// Vision on the phone; a host may answer differently (tests do).
    public func recognizeText(inPNG png: Data) async -> [RecognizedText]? { TextRecognizer.recognize(png: png) }
    /// Nothing to prepare by default.
    public func warmUp() {}
}
