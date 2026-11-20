import Foundation

enum MessageScrollTarget {
    case messages(Int)
    case screens(Int)

    var messageCount: Int? {
        if case .messages(let count) = self { return count }
        return nil
    }

    private static let digits = #"[0-9]+(?:,[0-9]{3})*"#
    private static let chineseNumber = "[0-9零〇一二两兩三四五六七八九十百千万萬亿億]+"
    private static let englishWord = #"one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million"#
    private static let englishNumber = "(?:\(englishWord))(?:[ -]+(?:\(englishWord)|and))*"
    private static let countBoundary = #"(?<![0-9+-])(?<![0-9][.,])"#
    private static let englishModifiers = #"(?:\s+[a-z]+(?:[-'][a-z]+)*)*?\s*"#
    private static let messageUnits: Set<String> = ["条", "條", "则", "則", "message", "messages", "msg", "msgs"]

    private static let patterns = [
        "\(countBoundary)(\(digits)|\(chineseNumber))\\s*([条條则則页頁屏])",
        "\(countBoundary)(?<![a-z])(\(digits)|\(chineseNumber)|\(englishNumber))\(englishModifiers)(messages?|msgs?|pages?|screens?)\\b",
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static func parse(_ request: String) -> MessageScrollTarget? {
        let text = request.folding(options: .widthInsensitive, locale: nil).lowercased()
        let range = NSRange(text.startIndex..., in: text)
        let matches = patterns.flatMap { $0.matches(in: text, range: range) }
            .sorted { $0.range.location < $1.range.location }
        for match in matches {
            guard let number = Range(match.range(at: 1), in: text),
                  let unit = Range(match.range(at: 2), in: text),
                  let count = integer(text[number]), count > 0 else { continue }
            return messageUnits.contains(String(text[unit])) ? .messages(count) : .screens(count)
        }
        return nil
    }

    private static func integer(_ words: Substring) -> Int? {
        if let value = Int(words.replacingOccurrences(of: ",", with: "")) { return value }
        if let first = words.first, first.isASCII, first.isLetter {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .spellOut
            return formatter.number(from: String(words)).flatMap { Int($0.stringValue) }
        }
        let normalized = words.replacingOccurrences(of: "萬", with: "万").replacingOccurrences(of: "億", with: "亿")
        return chineseInteger(normalized[...], largePlaces: chineseLargePlaces[...])
    }

    private static let chineseDigits: [Character: Character] = [
        "零": "0", "〇": "0", "一": "1", "二": "2", "两": "2", "兩": "2",
        "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9",
    ]
    private static let chinesePlaces: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let chineseLargePlaces: [(Character, Int)] = [("亿", 100_000_000), ("万", 10_000)]

    private static func chineseInteger(_ words: Substring, largePlaces: ArraySlice<(Character, Int)>) -> Int? {
        guard let (symbol, scale) = largePlaces.first else { return chineseSection(words) }
        let smallerPlaces = largePlaces.dropFirst()
        guard let divider = words.firstIndex(of: symbol) else { return chineseInteger(words, largePlaces: smallerPlaces) }
        let remainder = words[words.index(after: divider)...]
        guard let leading = chineseInteger(words[..<divider], largePlaces: smallerPlaces), leading > 0,
              let trailing = remainder.isEmpty ? 0 : chineseInteger(remainder, largePlaces: smallerPlaces),
              trailing < scale else { return nil }
        let (scaled, overflow) = leading.multipliedReportingOverflow(by: scale)
        let (sum, sumOverflow) = scaled.addingReportingOverflow(trailing)
        return overflow || sumOverflow ? nil : sum
    }

    // Consecutive digits are read in order. A place marker multiplies the digits just before it.
    private static func chineseSection(_ words: Substring) -> Int? {
        guard !words.isEmpty else { return nil }
        var digits = ""
        var total = 0
        var previousPlace = 10_000
        for character in words {
            if let digit = chineseDigits[character] {
                digits.append(digit)
            } else if character.isASCII, character.isNumber {
                digits.append(character)
            } else {
                guard let place = chinesePlaces[character], place < previousPlace else { return nil }
                let coefficient = digits.isEmpty && place == 10 ? 1 : Int(digits)
                guard let coefficient, coefficient > 0 else { return nil }
                let (scaled, overflow) = coefficient.multipliedReportingOverflow(by: place)
                let (sum, sumOverflow) = total.addingReportingOverflow(scaled)
                guard !overflow, !sumOverflow else { return nil }
                total = sum
                previousPlace = place
                digits = ""
            }
        }
        guard let units = digits.isEmpty ? 0 : Int(digits) else { return nil }
        let (value, overflow) = total.addingReportingOverflow(units)
        return overflow ? nil : value
    }
}
