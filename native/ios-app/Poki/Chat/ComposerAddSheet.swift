import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Plus in the message field: a sheet that rises from the bottom. Recent photos to tap, the ways to
/// add a photo or a file, the apps and connectors to mention, and how this chat runs (the model, how
/// approvals ask and how strict they are). Everything here changes in place, with native menus.
struct ComposerAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// How many more photos and files fit in the message.
    var room: Int
    /// Recent photos already in the message, by their library id.
    var picked: Set<String>
    var togglePhoto: (PHAsset) -> Void
    var choosePhotos: () -> Void
    var takePhoto: () -> Void
    var chooseFiles: () -> Void
    var mention: (MentionMatch) -> Void

    @State private var photos = RecentPhotos()
    @State private var connectors = MCPConnectors.shared
    @State private var modelVersion = 0
    @State private var path = NavigationPath()
    @ScaledMetric(relativeTo: .body) private var tile = 96.0

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { strip }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listSectionSeparator(.hidden)

                Section {
                    Button(action: takePhoto) { SettingsLabel("Camera", systemImage: "camera") }
                        .disabled(room == 0 || !UIImagePickerController.isSourceTypeAvailable(.camera))
                        .accessibilityIdentifier("composer.camera")
                    Button(action: chooseFiles) { SettingsLabel("Files", systemImage: "folder") }
                        .disabled(room == 0)
                        .accessibilityIdentifier("composer.files")
                }
                .foregroundStyle(Color(.label))

                Section {
                    chips(MentionRecents.apps.prefix(10).map { MentionMatch(capsule: $0, insert: $0.name) })
                } header: { SettingsHeader("Apps") }

                Section {
                    let connected = ConnectorCapsules.current.map { MentionMatch(capsule: $0, insert: $0.names[0]) }
                    if !connected.isEmpty { chips(connected) }
                    NavigationLink(value: AddRoute.connectors) {
                        SettingsRow(title: connected.isEmpty ? "Add Connectors" : "Manage Connectors", symbol: "puzzlepiece.extension")
                    }
                } header: { SettingsHeader("Connectors") }

                Section { modelPicker; approvalPicker; sensitivityPicker }
                    .id(modelVersion)
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalization.text("Add to Message"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("composer.add.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("All Photos", action: choosePhotos)
                        .disabled(room == 0)
                        .accessibilityIdentifier("composer.photos")
                }
            }
            .navigationDestination(for: AddRoute.self) { route in
                switch route {
                case .connectors: ConnectorsView().settingsPage()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await photos.load() }
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in modelVersion += 1 }
    }

    // MARK: Recent photos

    @ViewBuilder private var strip: some View {
        switch photos.access {
        case .unknown:
            Color.clear.frame(height: tile)
        case .ask:
            Button { Task { await photos.ask() } } label: {
                Label("Show Recent Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: tile)
            }
            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 18))
        case .denied:
            Button(action: choosePhotos) {
                Label("Choose Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: tile)
            }
            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 18))
        case .granted:
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(photos.assets, id: \.localIdentifier) { asset in
                        let on = picked.contains(asset.localIdentifier)
                        Button { togglePhoto(asset) } label: {
                            RecentPhotoTile(asset: asset, photos: photos, side: tile, on: on)
                        }
                        .buttonStyle(.plain)
                        .disabled(!on && room == 0)
                        .accessibilityLabel(Text("Photo"))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: tile)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    // MARK: Apps and connectors

    private func chips(_ matches: [MentionMatch]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(matches) { match in
                    Button { mention(match); dismiss() } label: {
                        HStack(spacing: 6) {
                            MentionIcon(capsule: match.capsule, size: 22)
                            Text(verbatim: match.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(1)
                        }
                        .padding(.leading, 5).padding(.trailing, 12).frame(minHeight: 34)
                        .background(Color(.label).opacity(0.07), in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                                                               bottomTrailingRadius: 17, topTrailingRadius: 17,
                                                                                               style: .continuous))
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

    // MARK: How this chat runs

    private var providers: [ModelProvider] {
        ModelProvider.allCases.filter { ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }
    }

    /// "provider|model", the one that answers.
    private var modelSelection: Binding<String> {
        Binding(get: { "\(ModelKeys.selectedProvider.rawValue)|\(ModelKeys.selectedModel)" }, set: { value in
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let provider = ModelProvider(rawValue: parts[0]) else { return }
            ModelKeys.selectedProvider = provider
            ModelKeys.selectedModel = parts[1]
            ModelKeys.saved += 1
        })
    }

    @ViewBuilder private var modelPicker: some View {
        if ModelKeys.hasUsableKey {
            Picker(selection: modelSelection) {
                ForEach(providers) { provider in
                    if provider == .custom {
                        ForEach(CustomProviders.all) { custom in
                            Section(custom.displayName) {
                                ForEach(ModelCatalog.available(.custom).filter { CustomProviders.parse($0.id)?.provider == custom.id }) { choice in
                                    Text(verbatim: CustomProviders.parse(choice.id)?.model ?? choice.name).tag("\(provider.rawValue)|\(choice.id)")
                                }
                            }
                        }
                    } else {
                        Section(provider.name) {
                            ForEach(ModelCatalog.available(provider)) { choice in
                                Text(verbatim: choice.name).tag("\(provider.rawValue)|\(choice.id)")
                            }
                        }
                    }
                }
            } label: {
                SettingsLabel("Model", systemImage: "sparkles")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("composer.model")
        }
    }

    private var approvalPicker: some View {
        Picker(selection: Binding(get: { model.approvalMode }, set: { model.approvalMode = $0 })) {
            ForEach(ApprovalClassifier.Mode.allCases) { Text(verbatim: $0.title).tag($0) }
        } label: {
            SettingsLabel("Approvals", systemImage: "checkmark.shield")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("composer.approvals")
    }

    @ViewBuilder private var sensitivityPicker: some View {
        if model.approvalMode != .off {
            Picker(selection: Binding(get: { model.classifierLevel }, set: { model.classifierLevel = $0 })) {
                ForEach(ApprovalClassifier.Level.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                SettingsLabel("Sensitivity", systemImage: "dial.medium")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("composer.sensitivity")
        }
    }
}

private enum AddRoute: Hashable { case connectors }

/// One recent photo: a square, with a tick when it is in the message.
private struct RecentPhotoTile: View {
    let asset: PHAsset
    let photos: RecentPhotos
    let side: CGFloat
    let on: Bool
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(.secondarySystemFill) }
            }
            .frame(width: side, height: side).clipped()
            if on {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, Tint.blue)
                    .padding(6).transition(.scale.combined(with: .opacity))
            }
        }
        .overlay { if on { Rectangle().strokeBorder(Tint.blue, lineWidth: 3) } }
        .animation(.snappy, value: on)
        .task(id: asset.localIdentifier) { image = await photos.thumbnail(asset, side: side * scale) }
    }
}

/// The photo library's most recent pictures, for the strip; asked for only once the sheet shows it.
@MainActor
@Observable
final class RecentPhotos {
    enum Access { case unknown, ask, denied, granted }
    private(set) var access: Access = .unknown
    private(set) var assets: [PHAsset] = []
    @ObservationIgnored private let manager = PHCachingImageManager()

    func load() async {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: access = .ask
        case .authorized, .limited: fetch()
        default: access = .denied
        }
    }

    func ask() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if status == .authorized || status == .limited { fetch() } else { access = .denied }
    }

    private func fetch() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 30
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var list: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
        access = .granted
    }

    func thumbnail(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        // One answer: the picture at this size.
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

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
