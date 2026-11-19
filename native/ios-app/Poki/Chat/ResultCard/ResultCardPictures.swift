import ImageIO
import PokiCore
import SwiftUI
import UIKit

/// A result card's item pictures: cut from the phone's screenshot at the frames PokiCore found for the
/// items' `image` boxes, and drawn at the start of each row the way the apps put them (淘宝's product
/// photo, a hotel's front, a dish). Kept small: each is at most 180 pixels on its longer side.
enum ResultCardPictures {
    static let longestSide: CGFloat = 180

    static func cut(_ found: ItemPictures) -> [String: Data] {
        guard let source = CGImageSourceCreateWithData(found.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), found.screen.width > 0 else { return [:] }
        let scale = Double(image.width) / found.screen.width
        var out: [String: Data] = [:]
        for (id, frame) in found.frames {
            let rect = CGRect(x: frame.x * scale, y: frame.y * scale, width: frame.width * scale, height: frame.height * scale).integral
            guard let piece = image.cropping(to: rect) else { continue }
            let fit = min(1, longestSide / CGFloat(max(piece.width, piece.height)))
            let size = CGSize(width: (CGFloat(piece.width) * fit).rounded(), height: (CGFloat(piece.height) * fit).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIImage(cgImage: piece).draw(in: CGRect(origin: .zero, size: size))
            }
            if let jpeg = small.jpegData(compressionQuality: 0.75) { out[id] = jpeg }
        }
        return out
    }
}

/// An item's picture at the start of its row, filled into a square with the app's small rounding.
struct ResultCardPicture: View {
    var data: Data
    var side: CGFloat

    var body: some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: side, height: side)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
        }
    }
}
