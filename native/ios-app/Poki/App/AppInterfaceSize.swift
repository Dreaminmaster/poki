import SwiftUI
import UIKit

/// One native content-size category for this window, including UIKit presentations and editors.
/// Removing the override restores iOS's current per-app preference immediately.
enum AppInterfaceSize {
    static let defaultsKey = "appInterfaceSize"
    static let system = "system"
    static let categories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    static func category(for preference: String) -> UIContentSizeCategory? {
        categories.first { $0.rawValue == preference }
    }

    static func apply(_ preference: String, to window: UIWindow) {
        if let category = category(for: preference) {
            if !window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self)
                || window.traitCollection.preferredContentSizeCategory != category {
                window.traitOverrides.preferredContentSizeCategory = category
            }
        } else if window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
            window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
    }

    /// The navigation bars use Poki's custom fonts, which must resolve against this window's traits.
    static func updateNavigationFonts(in window: UIWindow) {
        let traits = window.traitCollection
        let systemLarge = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traits)
        let bold = systemLarge.fontDescriptor.withSymbolicTraits(.traitBold) ?? systemLarge.fontDescriptor
        let large = Prominent.uiFont(.largeTitle, .bold, compatibleWith: traits) ?? UIFont(descriptor: bold, size: systemLarge.pointSize)
        let inline = Prominent.uiFont(.headline, .semibold, compatibleWith: traits) ?? UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        func apply(_ bar: UINavigationBar) {
            var largeAttributes = bar.largeTitleTextAttributes ?? [:]
            var inlineAttributes = bar.titleTextAttributes ?? [:]
            largeAttributes[.font] = large
            inlineAttributes[.font] = inline
            bar.largeTitleTextAttributes = largeAttributes
            bar.titleTextAttributes = inlineAttributes
        }
        apply(UINavigationBar.appearance())
        func visit(_ controller: UIViewController) {
            if let navigation = controller as? UINavigationController { apply(navigation.navigationBar) }
            controller.children.forEach(visit)
            if let presented = controller.presentedViewController { visit(presented) }
        }
        if let root = window.rootViewController { visit(root) }
    }

}

struct InterfaceSizeSettingsView: View {
    @AppStorage(AppInterfaceSize.defaultsKey) private var preference = AppInterfaceSize.system
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toggleHeight: CGFloat = 52
    @State private var previewTitleHeight: CGFloat = 18

    private let sliderHeight: CGFloat = 52
    private let sectionSpacing: CGFloat = 20
    private let previewSpacing: CGFloat = 8
    private let topInset: CGFloat = 20
    private let bottomInset: CGFloat = 12

    private var followsSystem: Bool { AppInterfaceSize.category(for: preference) == nil }
    private var index: Int {
        let category = AppInterfaceSize.category(for: preference) ?? UIContentSizeCategory(typeSize)
        return AppInterfaceSize.categories.firstIndex(of: category) ?? 3
    }

    var body: some View {
        GeometryReader { geometry in
            let controlsHeight = toggleHeight + (followsSystem ? 0 : sliderHeight)
            let reservedHeight = topInset + controlsHeight + sectionSpacing + previewTitleHeight + previewSpacing + bottomInset
            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    VStack(spacing: 0) {
                        controls
                    }
                    .padding(.horizontal, 20)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 25))

                    VStack(alignment: .leading, spacing: previewSpacing) {
                        SettingsHeader("Preview")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewTitleHeight = $0 }
                        InterfaceSizePreview()
                            .frame(height: max(520, geometry.size.height - reservedHeight))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: followsSystem)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle(AppLocalization.text(LocalizedStringResource("Interface Size")))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var controls: some View {
        Toggle("Follow System", isOn: Binding(
            get: { followsSystem },
            set: { followsSystem in
                preference = followsSystem ? AppInterfaceSize.system : UIContentSizeCategory(typeSize).rawValue
            }
        ))
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toggleHeight = $0 }
        .accessibilityIdentifier("interfaceSize.followSystem")
        VStack(spacing: 0) {
            Divider()
            Slider(value: Binding(
                get: { Double(index) },
                set: { value in
                    let step = Int(value.rounded())
                    let selected = AppInterfaceSize.categories[step].rawValue
                    if preference != selected {
                        preference = selected
                    }
                }
            ), in: 0...Double(AppInterfaceSize.categories.count - 1), step: 1) {
                Text("Interface Size")
            } minimumValueLabel: {
                endpoint("Interface Size Minimum", size: 14)
            } maximumValueLabel: {
                endpoint("Interface Size Maximum", size: 18)
            }
            .sensoryFeedback(.selection, trigger: index)
            .tint(Color(.secondaryLabel))
            .accessibilityValue(Text("Size \(index + 1) of \(AppInterfaceSize.categories.count)"))
            .accessibilityIdentifier("interfaceSize.slider")
            .frame(maxHeight: .infinity)
        }
        .frame(height: sliderHeight)
        .opacity(followsSystem ? 0 : 1)
        .frame(height: followsSystem ? 0 : sliderHeight, alignment: .top)
        .clipped()
        .allowsHitTesting(!followsSystem)
        .accessibilityHidden(followsSystem)
    }

    private func endpoint(_ label: LocalizedStringKey, size: CGFloat) -> some View {
        Text(label)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28)
            .dynamicTypeSize(.large)
            .accessibilityHidden(true)
    }

}

/// Sample data rendered by the production chat components so their appearance stays in sync.
private struct InterfaceSizePreview: View {
    private let started = Date(timeIntervalSince1970: 0)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    MessageBubble(direction: .outgoing, text: AppLocalization.text(LocalizedStringResource("Help me plan tomorrow.")), tail: true)
                    MessageBubble(direction: .incoming, text: AppLocalization.text(LocalizedStringResource("Start with your most important task in the morning. Leave time for lunch and a short walk.\n\nI can also help you set a reminder.")), tail: true)
                    TaskCard(title: AppLocalization.text(LocalizedStringResource("Reminder created")),
                             steps: [PlanStep(AppLocalization.text(LocalizedStringResource("Tomorrow at 9:00 AM")), state: .done)],
                             state: .done, app: AppIconStore.name("com.apple.reminders") ?? "Reminders", started: started,
                             ended: started.addingTimeInterval(2), plannedTotal: 1)
                    MessageBubble(direction: .outgoing, text: AppLocalization.text(LocalizedStringResource("Show me the full plan.")), tail: true)
                    MessageBubble(direction: .incoming, text: AppLocalization.text(LocalizedStringResource("Tomorrow’s plan  \n9:00 — Start with your most important task.  \n12:00 — Take a lunch break.  \n12:45 — Go for a short walk.  \n14:00 — Catch up on messages.  \n16:30 — Review today’s progress.")), tail: true)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top, for: .initialOffset)
        }
        .topBar {
            ChatTopBar(status: PokiStatus(.ready), home: false, busy: false,
                       openThreads: {}, newConversation: {}, openDetails: {})
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Poki"))
        }
        .bottomBar(softEdge: true) {
            ComposerInputView(input: .constant(""), focused: .constant(false), running: false,
                              send: { _, _ in }, stop: {}, openVoice: {})
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Message Poki"))
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
                .frame(maxWidth: 720)
        }
        .background { HomeBackdrop(home: false, working: false, frozen: true) }
        .overlayPreferenceValue(PicturePlaceKey.self) { anchors in
            GeometryReader { proxy in
                PokiFlight(status: PokiStatus(.ready), home: false, writing: false,
                           places: anchors.mapValues { proxy[$0] }, pokes: 0, tap: {})
            }
            .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .accessibilityIdentifier("interfaceSize.preview")
    }
}
