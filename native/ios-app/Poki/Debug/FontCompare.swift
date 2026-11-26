#if DEBUG
import SwiftUI

/// Debug only, `-pokiScreen fonts`: every text style at each weight in SF and in Allo side by side,
/// in English and Chinese, and a List section whose header and footer the system draws, so Allo's
/// weights and sizes can be matched against SF's by eye (the owner, Nov 20 2026: weights looked off
/// beside San Francisco, and headers had no weight).
struct FontCompare: View {
    private let styles: [(String, Font.TextStyle)] = [
        ("Large Title", .largeTitle), ("Title", .title), ("Title 2", .title2), ("Title 3", .title3),
        ("Headline", .headline), ("Body", .body), ("Callout", .callout), ("Subheadline", .subheadline),
        ("Footnote", .footnote), ("Caption", .caption), ("Caption 2", .caption2),
    ]
    private let weights: [(String, Font.Weight)] = [("Regular", .regular), ("Medium", .medium), ("Semibold", .semibold), ("Bold", .bold)]

    var body: some View {
        List {
            Section {
                ForEach(styles, id: \.0) { name, style in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: name).font(.system(.caption2)).foregroundStyle(.secondary)
                        ForEach(weights, id: \.0) { weightName, weight in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: "\(weightName) 设置").font(.system(style, weight: weight))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: "\(weightName) 设置").font(.allo(style, weight))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .lineLimit(1).minimumScaleFactor(0.5)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: "Default .bold()").font(.system(style)).bold().frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: "Default .bold()").font(.allo(style)).bold().frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .lineLimit(1).minimumScaleFactor(0.5)
                    }
                }
            } header: {
                Group {
                    Text(verbatim: "SF left, Allo right").font(nil)
                }
                .settingsHeader()
            }
            Section {
                Text(verbatim: "Row in the root font")
            } header: {
                Group {
                    Text(verbatim: "System header 系统标题").font(nil)
                }
                .settingsHeader()
            } footer: {
                Text(verbatim: "System footer 系统脚注").font(nil)
            }
            Section {
                Text(verbatim: "Row in the root font")
            } header: {
                Group {
                    SettingsHeader("Settings Header")
                }
                .settingsHeader()
            } footer: {
                Text(verbatim: "Poki footer 脚注").settingsFooter()
            }
            // As the app draws it, under the root font.
            .font(.allo(.body))
            Section {
                Text(verbatim: "Poki").font(Prominent.font(size: 28, relativeTo: .title, .bold))
                Text(verbatim: "Good evening. 晚上好").font(Prominent.font(size: 28, relativeTo: .title, .bold))
            } header: {
                Group {
                    Text(verbatim: "Prominent").font(nil)
                }
                .settingsHeader()
            }
        }
        .font(nil)
    }
}
#endif
