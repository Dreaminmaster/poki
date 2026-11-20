import Foundation

public struct ItemPictureRequest: Sendable {
    public let screenshotID: String
    public let box: Rect

    public init(screenshotID: String, box: Rect) {
        self.screenshotID = screenshotID
        self.box = box
    }
}

/// All item pictures to cut from a single screenshot, with the screen size and frames in points.
/// The app cuts them (PokiCore has no image library on Linux).
public struct ItemPictures: Sendable {
    public var png: Data
    public var screen: ScreenSize
    public var frames: [String: Rect]
}

struct ItemPictureSource: Sendable {
    let png: Data
    let screen: ScreenSize
    let images: [Rect]
}

struct ItemPictureSources {
    private struct Capture {
        let id: String
        let task: String
        let at: Double
        let source: ItemPictureSource
    }

    private var recent: [Capture] = []
    private static let lifetime: Double = 120
    private static let limit = 8

    mutating func record(_ source: ItemPictureSource, task: String) -> String {
        let at = now()
        recent.removeAll { at - $0.at >= Self.lifetime }
        if recent.count == Self.limit { recent.removeFirst() }
        let id = UUID().uuidString.lowercased()
        recent.append(Capture(id: id, task: task, at: at, source: source))
        return id
    }

    func pictures(_ requests: [String: ItemPictureRequest], task: String) -> [ItemPictures] {
        let at = now()
        let byScreenshot = Dictionary(grouping: requests) { $0.value.screenshotID }
        return recent.compactMap { capture in
            guard capture.task == task, at - capture.at < Self.lifetime,
                  let requests = byScreenshot[capture.id] else { return nil }
            let source = capture.source
            var frames: [String: Rect] = [:]
            for (id, request) in requests {
                frames[id] = ItemPictureFit.frame(for: request.box, images: source.images, screen: source.screen)
            }
            return frames.isEmpty ? nil : ItemPictures(png: source.png, screen: source.screen, frames: frames)
        }
    }
}

enum ItemPictureFit {
    /// Where an item's picture is, from the box the model gave in the picture's points: the image
    /// element that matches the box best, so a rough box still cuts the whole picture, else the box
    /// itself. Nil for a picture the screen's edge cuts, a box too small to show anything, or a strip
    /// (a picture half under a bar or off the screen reads as one: a model gives the part it sees).
    static func frame(for box: Rect, images: [Rect], screen: ScreenSize) -> Rect? {
        guard box.width >= 32, box.height >= 32 else { return nil }
        let match = images.map { ($0, overlap($0, box)) }.filter { $0.1 >= 0.6 }.max { $0.1 < $1.1 }?.0
        if let match {
            let inside = match.x >= -1 && match.y >= -1 && match.maxX <= screen.width + 1 && match.maxY <= screen.height + 1
            return inside ? match : nil
        }
        let shown = box.intersection(Rect(x: 0, y: 0, width: screen.width, height: screen.height))
        guard shown.area >= box.area * 0.95 else { return nil }
        let ratio = box.width / box.height
        return ratio >= 0.6 && ratio <= 1.7 ? box : nil
    }

    /// Intersection over union.
    static func overlap(_ a: Rect, _ b: Rect) -> Double {
        let both = a.intersection(b).area
        let either = a.area + b.area - both
        return either > 0 ? both / either : 0
    }
}
