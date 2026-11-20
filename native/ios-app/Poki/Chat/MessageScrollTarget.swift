import Foundation

enum MessageScrollTarget {
    private static let digits = #"[0-9]+(?:,[0-9]{3})*"#
    private static let chineseNumber = "[零〇一二两兩三四五六七八九十百千万萬亿億]+"
    private static let englishWord = #"one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|and"#
    private static let englishNumber = "(?:\(englishWord))(?:[ -]+(?:\(englishWord)))*"
    private static let chineseMotion = #"(?:(?:往|向)[上回前](?:\s*(?:翻|滑[动動]?|[滚滾][动動]))?|翻[到回看阅閱]?|滑[到动動]?|[滚滾][动動]|[回返]到|去|看|查看)"#
    private static let chinesePrefix = #"(?:最近的?|最新的?|前(?:面的?)?|往上|向上)"#
    private static let chineseUnit = #"[条條则則](?:\s*(?:消息|信息|[讯訊]息|(?:聊天)?[记記][录錄])|(?=$|[\s，。！？,.!?]|[吧前]))"#
    private static let englishMotion = #"\b(?:scroll|go|move|jump|swipe|show|read|review)"#
    private static let englishPrefix = #"(?:(?:up|back(?:wards?)?|to|by|through|the|last|latest|previous|past|first|most recent|message)\s+)*"#
    private static let englishUnit = #"(?:older\s+|previous\s+)?messages?\b"#

    private static let patterns: [(NSRegularExpression, String)] = [
        ("\(chineseMotion)\\s*\(chinesePrefix)?\\s*(\(digits)|\(chineseNumber))\\s*\(chineseUnit)", "zh_CN"),
        ("^\\s*\(chinesePrefix)\\s*(\(digits)|\(chineseNumber))\\s*\(chineseUnit)\\s*[。！!]?\\s*$", "zh_CN"),
        ("\(englishMotion)\\s+\(englishPrefix)(\(digits)|\(englishNumber))\\s+\(englishUnit)", "en_US"),
        ("^\\s*(?:the )?(?:last|latest|previous)\\s+(\(digits)|\(englishNumber))\\s+\(englishUnit)\\s*[.!]?\\s*$", "en_US"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }

    static func parse(_ request: String) -> Int? {
        let text = request.folding(options: .widthInsensitive, locale: nil)
        let range = NSRange(text.startIndex..., in: text)
        for (pattern, locale) in patterns {
            guard let match = pattern.firstMatch(in: text, range: range),
                  let count = Range(match.range(at: 1), in: text) else { continue }
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
