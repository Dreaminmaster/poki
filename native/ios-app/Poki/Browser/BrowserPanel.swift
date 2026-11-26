import SwiftUI
import WebKit

/// The same browser mark on a visit and on the task that used it.
struct BrowserIcon: View {
    @ScaledMetric(relativeTo: .subheadline) private var size = 30.0

    var body: some View {
        let side = min(44, size)
        return Image(systemName: "globe")
            .font(.system(size: side / 2, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Color.accentColor, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Poki's browser in the conversation, where a task began using it, above the answer the task gives:
/// the live page while it is this conversation's page in use, otherwise the site it showed.
struct BrowserCard: View {
    var id: UUID
    var visit: BrowserVisit
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(ChatModel.self) private var chat
    private var browser: PokiBrowser { PokiBrowser.shared }

    var body: some View {
        if chat.liveBrowser == id, browser.isOpen {
            BrowserPanel()
        } else {
            HStack(spacing: 10) {
                BrowserIcon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(visit.host.isEmpty ? AppLocalization.text(LocalizedStringResource("Poki’s Browser")) : visit.host)
                        .font(.allo(.subheadline, .semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Text(visit.title.isEmpty ? AppLocalization.text(LocalizedStringResource("Done")) : visit.title)
                        .font(.allo(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Poki's browser in the chat (ESP-145): the live page and the latest steps, in the card of the task
/// using it. Take Over moves the page into a sheet the owner can use; Stop ends the task. Close, when no
/// task is running, puts the page away and leaves the card with the site it showed.
struct BrowserPanel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(ChatModel.self) private var chat
    @Bindable private var browser = PokiBrowser.shared

    var body: some View {
        if browser.isOpen {
            VStack(alignment: .leading, spacing: 10) {
                header
                page
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5) }
                BrowserStepList(steps: Array(browser.steps.suffix(3)))
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .sheet(isPresented: $browser.sheetShown, onDismiss: browser.handBack) {
                BrowserTakeOverSheet(running: chat.running, stop: stopTask)
            }
        }
    }

    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            HStack(spacing: 10) {
                BrowserIcon()
                headerText
                Spacer(minLength: 4)
                if browser.isLoading { ProgressView().controlSize(.small) }
            }
            headerActions
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(browser.host.isEmpty ? AppLocalization.text(LocalizedStringResource("Poki’s Browser")) : browser.host)
                .accessibilityIdentifier("browser.header.title")
                .font(.allo(.subheadline, .semibold))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            Text(status)
                .font(.allo(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button("Take Over", systemImage: "hand.raised") { browser.takeOver() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("Take Over"))
                .accessibilityShowsLargeContentViewer {
                    Label("Take Over", systemImage: "hand.raised")
                }
            if chat.running {
                Button("Stop", systemImage: "stop.fill", action: stopTask)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(.red)
                    .accessibilityLabel(Text("Stop"))
                    .accessibilityShowsLargeContentViewer {
                        Label("Stop", systemImage: "stop.fill")
                    }
            } else {
                Button("Close Browser", systemImage: "xmark") { withAnimation(.snappy) { browser.close() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(Text("Close Browser"))
                    .accessibilityIdentifier("browser.close")
                    .accessibilityShowsLargeContentViewer {
                        Label("Close Browser", systemImage: "xmark")
                    }
            }
        }
        .controlSize(.large)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private var page: some View {
        if browser.sheetShown {
            VStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.alloRounded(.title2)).foregroundStyle(.secondary)
                Text("You have the page").font(.allo(.subheadline, .medium))
                Text("Poki waits until you hand it back.").font(.allo(.caption)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 230)
            .background(Color(.tertiarySystemBackground))
        } else {
            // The owner watches; taps go to Take Over, so a stray tap cannot change the page under Poki.
            BrowserWebView(interactive: false)
                .frame(height: 230)
                .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { browser.takeOver() } }
                .accessibilityLabel(Text("The page Poki is using. Double-tap to take over."))
        }
    }

    private var status: String {
        if case .person(let reason?) = browser.owner, !reason.isEmpty { return AppLocalization.text(LocalizedStringResource("Waiting for you: \(reason)")) }
        if browser.ownerHasIt { return AppLocalization.text(LocalizedStringResource("You have the page")) }
        if chat.running { return browser.steps.last?.text ?? AppLocalization.text(LocalizedStringResource("Poki is browsing")) }
        return browser.title.isEmpty ? AppLocalization.text(LocalizedStringResource("Done")) : browser.title
    }

    private func stopTask() {
        chat.stop()
        browser.taskStopped()
    }
}

/// The latest steps, newest last, each with its state.
struct BrowserStepList: View {
    var steps: [BrowserStep]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    icon(step.state)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.text)
                            .font(.allo(.footnote))
                            .foregroundStyle(step.state == .working ? .primary : .secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        if typeSize.isAccessibilitySize, step.state == .done, step.ms > 0 {
                            elapsed(step.ms)
                        }
                    }
                    Spacer(minLength: 0)
                    if !typeSize.isAccessibilitySize, step.state == .done, step.ms > 0 {
                        elapsed(step.ms)
                    }
                }
            }
        }
        .animation(.snappy, value: steps)
    }

    private func elapsed(_ milliseconds: Int) -> some View {
        Text(String(format: "%.1f s", Double(milliseconds) / 1000))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder private func icon(_ state: BrowserStep.State) -> some View {
        switch state {
        case .working: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.allo(.footnote))
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.allo(.footnote))
        case .waiting: Image(systemName: "hand.raised.circle.fill").foregroundStyle(Color.accentColor).font(.allo(.footnote))
        }
    }
}

/// The page, in the owner's hands: they can sign in, pass a check or browse; Done gives it back to Poki.
struct BrowserTakeOverSheet: View {
    var running: Bool
    var stop: () -> Void
    @Bindable private var browser = PokiBrowser.shared
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            // Above the bottom toolbar, so a page's own bottom buttons stay reachable.
            BrowserWebView(interactive: true)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if case .person(let reason?) = browser.owner, !reason.isEmpty {
                        BrowserInstructionBanner(reason: reason)
                    }
                }
                .navigationTitle(browser.host.isEmpty ? AppLocalization.text(LocalizedStringResource("Poki’s Browser")) : browser.host)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(running ? AppLocalization.text(LocalizedStringResource("Hand Back")) : AppLocalization.text(LocalizedStringResource("Done"))) { browser.handBack() }
                    }
                    if running {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Stop Task", role: .destructive) { stop() }
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Back", systemImage: "chevron.backward") { browser.webView.goBack() }
                        Button("Forward", systemImage: "chevron.forward") { browser.webView.goForward() }
                        Spacer()
                        Button("Reload", systemImage: "arrow.clockwise") { browser.webView.reload() }
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }
}

private struct BrowserInstructionBanner: View {
    var reason: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label {
                    Text("Poki asks")
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .font(.allo(.caption, .semibold))
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = reason
                    copied = true
                    resetTask?.cancel()
                    resetTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.allo(.caption, .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("browser.instruction.copy")
            }
            SelectableInstructionText(text: reason)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: reason) { _, _ in
            resetTask?.cancel()
            copied = false
        }
        .onDisappear { resetTask?.cancel() }
    }
}

private struct SelectableInstructionText: UIViewRepresentable {
    var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .preferredFont(forTextStyle: .footnote)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "browser.instruction.text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let maxHeight: CGFloat = 140
        let shouldScroll = fitted.height > maxHeight
        if uiView.isScrollEnabled != shouldScroll { uiView.isScrollEnabled = shouldScroll }
        return CGSize(width: width, height: min(ceil(fitted.height), maxHeight))
    }
}

/// Puts the one shared web view where it is shown: in the card, or in the take-over sheet.
struct BrowserWebView: UIViewRepresentable {
    var interactive: Bool

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.clipsToBounds = true
        host.backgroundColor = .systemBackground
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        let web = PokiBrowser.shared.webView
        web.isUserInteractionEnabled = interactive
        guard web.superview !== host else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
