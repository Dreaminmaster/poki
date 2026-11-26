import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Plus in the message field: a sheet that rises from the bottom, with no title and no headers.
/// The apps used most as a row of large icons with More for every app, first (the owner, Nov 21 2026),
/// then three plain ways to add something (Photos, Camera, Files), and the connectors. The model and approvals are under the model button.
struct ComposerAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// How many more photos and files fit in the message.
    var room: Int
    var choosePhotos: () -> Void
    var takePhoto: () -> Void
    var chooseFiles: () -> Void
    var mention: (MentionMatch) -> Void
    /// Every app on this iPhone with search (AllAppsBrowserSheet), in place of the sheet's own list.
    var moreApps: (() -> Void)? = nil
    /// Apps the message already names (lowercased ids), marked with a check in the row, as the app
    /// browser marks them Inserted.
    var mentionedIDs: Set<String> = []

    @State private var connectors = MCPConnectors.shared
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    appRow
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))

                Section {
                    Button(action: choosePhotos) { SettingsLabel("Photos", systemImage: "photo.on.rectangle") }
                        .disabled(room == 0)
                        .accessibilityIdentifier("composer.photos")
                    Button(action: takePhoto) { SettingsLabel("Camera", systemImage: "camera") }
                        .disabled(room == 0 || !UIImagePickerController.isSourceTypeAvailable(.camera))
                        .accessibilityIdentifier("composer.camera")
                    Button(action: chooseFiles) { SettingsLabel("Files", systemImage: "folder") }
                        .disabled(room == 0)
                        .accessibilityIdentifier("composer.files")
                }
                .foregroundStyle(Color(.label))

                Section {
                    let connected = ConnectorCapsules.current.map { MentionMatch(capsule: $0, insert: $0.names[0]) }
                    if !connected.isEmpty { chips(connected) }
                    NavigationLink(value: AddRoute.connectors) {
                        SettingsRow(title: connected.isEmpty ? "Add Connectors" : "Manage Connectors", symbol: "puzzlepiece.extension")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 4, for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("composer.add.close")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AddRoute.self) { route in
                switch route {
                case .connectors: ConnectorsView().settingsPage()
                case .apps: AllAppsView(pick: { match in mention(match); dismiss() })
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Apps and connectors

    /// The apps used most and most recently, as large icons with their names, then More.
    private var appRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(MentionRecents.apps) { app in
                    let inserted = mentionedIDs.contains(app.id.lowercased())
                    Button { mention(MentionMatch(capsule: app, insert: app.name)); dismiss() } label: {
                        AppTile(title: app.name) {
                            MentionIcon(capsule: app, size: 56)
                                .overlay(alignment: .topTrailing) {
                                    if inserted {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Tint.blue)
                                            .background(Circle().fill(Color(.systemBackground)).padding(1))
                                            .offset(x: 6, y: -6)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(inserted ? Text("Inserted") : Text(verbatim: ""))
                    .accessibilityIdentifier("composer.mention.\(app.id)")
                }
                Group {
                    if let moreApps {
                        Button(action: moreApps) { moreTile }
                    } else {
                        NavigationLink(value: AddRoute.apps) { moreTile }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.apps.more")
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var moreTile: some View {
        AppTile(title: AppLocalization.text("More")) {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 56, height: 56)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 56 * 0.225, style: .continuous))
        }
    }

    private func chips(_ matches: [MentionMatch]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(matches) { match in
                    Button { mention(match); dismiss() } label: {
                        HStack(spacing: 6) {
                            MentionIcon(capsule: match.capsule, size: 22)
                            Text(verbatim: match.title).font(.allo(.subheadline, .semibold)).foregroundStyle(Color(.label)).lineLimit(1)
                        }
                        .padding(.leading, 6).padding(.trailing, 12).frame(minHeight: 34)
                        .background(Color(.label).opacity(0.07), in: RoundedRectangle(cornerRadius: 11 + 6, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composer.mention.\(match.capsule.id)")
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}

private enum AddRoute: Hashable { case connectors, apps }

/// One app in the sheet's row: its icon, large, and its name under it on one line.
private struct AppTile<Icon: View>: View {
    let title: String
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(spacing: 6) {
            icon
            Text(verbatim: title)
                .font(.allo(.caption))
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 72)
        .contentShape(.rect)
    }
}

/// Every app Poki can name, searchable the way mentions are (Pinyin included). A tap puts the app in
/// the message and closes the sheet.
struct AllAppsView: View {
    var pick: (MentionMatch) -> Void
    @State private var query = ""

    private var apps: [MentionMatch] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return MentionSearch.matches(typed, pending: false, explicit: false, limit: 60).filter { !$0.isConnector }
        }
        let catalog = AppCapsule.catalog
        let installed = catalog.filter { DynamicApps.name(forID: $0.id) != nil }
        return (installed.isEmpty ? catalog : installed)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { MentionMatch(capsule: $0, insert: $0.name) }
    }

    var body: some View {
        List(apps) { match in
            Button { pick(match) } label: {
                HStack(spacing: 12) {
                    MentionIcon(capsule: match.capsule, size: 32)
                    Text(verbatim: match.title).font(.allo(.body)).foregroundStyle(Color(.label)).lineLimit(1)
                }
            }
            .accessibilityIdentifier("composer.allApps.\(match.capsule.id)")
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search Apps"))
        .navigationTitle(AppLocalization.text("Apps"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A photo from the library, read for the message.
enum RecentPhotos {
    /// The photo itself, for the message.
    static func data(_ asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
