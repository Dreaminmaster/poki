import Foundation

/// The pictures of a result card's items (a product's photo, a hotel's), to cut from the latest
/// screenshot: the screenshot, the screen's size in points and each item's picture frame in points.
/// The app cuts them (PokiCore has no image library on Linux).
public struct ItemPictures: Sendable {
    public var png: Data
    public var screen: ScreenSize
    public var frames: [String: Rect]
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

extension Computer {
    /// The latest screenshot with each item's picture frame, when it was taken in the last two minutes
    /// of a whole screen (not one pane of a split view) and at least one box fits a picture.
    func itemPictures(_ boxes: [String: Rect]) -> ItemPictures? {
        guard !boxes.isEmpty, !paneSelected, let png = lastPNG, let at = lastPNGAt, now() - at < 120, let size else { return nil }
        let images = lastAll.filter { $0.type == "Image" && !$0.fromPicture }.map(\.frame)
        var frames: [String: Rect] = [:]
        for (id, box) in boxes {
            if let frame = ItemPictureFit.frame(for: box, images: images, screen: size) { frames[id] = frame }
        }
        return frames.isEmpty ? nil : ItemPictures(png: png, screen: size, frames: frames)
    }
}
