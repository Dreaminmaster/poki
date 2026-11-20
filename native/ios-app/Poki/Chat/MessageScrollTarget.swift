import Foundation

enum MessageScrollTarget {
    private static let digits = #"[0-9]+(?:,[0-9]{3})*"#
    private static let chineseNumber = "[零〇一二两兩三四五六七八九十百千万萬亿億]+"
    private static let englishWord = #"one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million"#
    private static let englishNumber = "(?:\(englishWord))(?:[ -]+(?:\(englishWord)|and))*"
    private static let countBoundary = #"(?<![0-9+-])(?<![0-9][.,])"#
    private static let englishModifiers = #"(?:[a-z]+(?:[-'][a-z]+)*\s+)*"#

    private static let patterns: [(NSRegularExpression, String)] = [
        ("\(countBoundary)(\(digits)|\(chineseNumber))\\s*[条條则則]", "zh_CN"),
        ("\(countBoundary)(?<![a-z])(\(digits)|\(englishNumber))\\s*\(englishModifiers)(?:messages?|msgs?)\\b", "en_US"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }

    static func parse(_ request: String) -> Int? {
        let text = request.folding(options: .widthInsensitive, locale: nil)
        let range = NSRange(text.startIndex..., in: text)
        let counts = patterns.flatMap { pattern, locale in
            pattern.matches(in: text, range: range).map { (range: $0.range(at: 1), locale: locale) }
        }.sorted { $0.range.location < $1.range.location }
        for (matchedRange, locale) in counts {
            guard let count = Range(matchedRange, in: text) else { continue }
            let words = String(text[count]).lowercased()
            if let digits = Int(words.replacingOccurrences(of: ",", with: "")), digits > 0 { return digits }
            let spelling = words.replacingOccurrences(of: "两", with: "二")
                .replacingOccurrences(of: "兩", with: "二")
                .replacingOccurrences(of: "〇", with: "零")
                .replacingOccurrences(of: "萬", with: "万")
                .replacingOccurrences(of: "億", with: "亿")
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: locale)
            formatter.numberStyle = .spellOut
            if let number = formatter.number(from: spelling),
               let value = Int(number.stringValue), value > 0 { return value }
        }
        return nil
    }
}
