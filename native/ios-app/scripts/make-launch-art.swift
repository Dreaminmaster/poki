// Draws the launch screen's word and bear at 3x (see Poki/LaunchArt/README.md) and writes two PNGs.
//   swift make-launch-art.swift <Geist-SemiBold.ttf> <LaunchBear.png> <wordmark out.png> <bear out.png>
// The launch screen is drawn by iOS before Poki runs, so it cannot set Geist or a shadow itself: both are
// drawn here, at build time, from the design's values.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// "Poki" over the light: the design's colour and weight. The font file passed in must be this weight.
enum Word {
  static let text = "Poki"
  static let colour: UInt32 = 0x3A3C41
  static let weight = "SemiBold"
  static let size: CGFloat = 60
  static let lineHeight: CGFloat = 64
  static let tracking: CGFloat = -0.045
}

/// The bear along the bottom edge: 418 points wide on a 402-point screen, under a soft blue light
/// thrown up from it (the design's drop shadow: 22 % of 0x073AA2, 8 points up, 30 points of blur).
enum Bear {
  static let width: CGFloat = 418
  static let shadowColour: UInt32 = 0x073AA2
  static let shadowAlpha: CGFloat = 0x38 / 255
  static let shadowRise: CGFloat = 8
  static let shadowBlur: CGFloat = 30
  /// Room round the bear for its shadow, on the sides and above; the picture is this much wider and
  /// taller than the bear, and the launch screen and `LaunchCurtain` place it by the bear.
  static let margin: CGFloat = 45
}

let scale: CGFloat = 3
let args = CommandLine.arguments
guard args.count == 5 else {
  FileHandle.standardError.write("usage: make-launch-art.swift Geist-SemiBold.ttf LaunchBear.png wordmark.png bear.png\n".data(using: .utf8)!); exit(2)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, alpha])!
}

func canvas(_ width: CGFloat, _ height: CGFloat) -> CGContext {
  CGContext(data: nil, width: Int((width * scale).rounded(.up)), height: Int((height * scale).rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ context: CGContext, _ path: String) {
  guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { exit(1) }
}

// The word, in its line box as the design lays it out: the font's ascent and descent centred in the
// line height, letter spacing after every letter, the last included, and a few points either side
// for letters that reach past their advance.
do {
  guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: args[1]) as CFURL) as? [CTFontDescriptor],
        let descriptor = descriptors.first else { FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!); exit(1) }
  let font = CTFontCreateWithFontDescriptor(descriptor, Word.size, nil)
  let style = CTFontCopyName(font, kCTFontStyleNameKey) as String? ?? ""
  guard style == Word.weight else { FileHandle.standardError.write("\(args[1]) is Geist \(style), not \(Word.weight)\n".data(using: .utf8)!); exit(1) }
  let kern = Word.tracking * Word.size
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: Word.text, attributes: [
    kCTFontAttributeName as NSAttributedString.Key: font,
    kCTKernAttributeName as NSAttributedString.Key: kern,
    kCTForegroundColorAttributeName as NSAttributedString.Key: colour(Word.colour),
  ]))
  let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
  let side: CGFloat = 8
  let context = canvas(advance + 2 * side, Word.lineHeight)
  context.scaleBy(x: scale, y: scale)
  let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
  context.textPosition = CGPoint(x: side, y: (Word.lineHeight - ascent - descent) / 2 + descent)
  CTLineDraw(line, context)
  write(context, args[3])
}

// The bear with its shadow baked in, the bear's bottom on the picture's bottom.
do {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
        let bear = CGImageSourceCreateImageAtIndex(source, 0, nil) else { FileHandle.standardError.write("cannot read \(args[2])\n".data(using: .utf8)!); exit(1) }
  let height = Bear.width * CGFloat(bear.height) / CGFloat(bear.width)
  let context = canvas(Bear.width + 2 * Bear.margin, height + Bear.margin)
  context.interpolationQuality = .high
  // Shadow offsets and blur are in pixels, not in the scaled points; y grows upwards here.
  context.setShadow(offset: CGSize(width: 0, height: Bear.shadowRise * scale), blur: Bear.shadowBlur * scale,
                    color: colour(Bear.shadowColour, Bear.shadowAlpha))
  context.draw(bear, in: CGRect(x: Bear.margin * scale, y: 0, width: Bear.width * scale, height: height * scale))
  write(context, args[4])
}
