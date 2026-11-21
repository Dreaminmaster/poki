import RealityKit
import SwiftUI

enum BearOutfit: Int, CaseIterable, Codable, Identifiable {
    case winterKnit = 1, fieldAgent, artist, scholar, chef, party, king, baseball, apprentice, vacation, pilot, sweetheart

    var id: Int { rawValue }

    struct Piece {
        let asset: String
        let name: LocalizedStringResource
    }

    var name: LocalizedStringResource {
        switch self {
        case .winterKnit: "Winter Knit"
        case .fieldAgent: "Field Agent"
        case .artist: "Artist"
        case .scholar: "Scholar"
        case .chef: "Little Chef"
        case .party: "Birthday Party"
        case .king: "Little King"
        case .baseball: "Baseball"
        case .apprentice: "Magic Apprentice"
        case .vacation: "Summer Holiday"
        case .pilot: "Pilot"
        case .sweetheart: "Sweetheart"
        }
    }

    func piece(_ slot: BearOutfitSlot) -> Piece {
        switch (self, slot) {
        case (.winterKnit, .headwear): Piece(asset: "beanie", name: "Knit Hat")
        case (.fieldAgent, .headwear): Piece(asset: "headphones", name: "Headset")
        case (.artist, .headwear): Piece(asset: "beret", name: "Beret")
        case (.scholar, .headwear): Piece(asset: "glasses", name: "Round Glasses")
        case (.chef, .headwear): Piece(asset: "chef_hat", name: "Chef Hat")
        case (.party, .headwear): Piece(asset: "party_hat", name: "Party Hat")
        case (.king, .headwear): Piece(asset: "crown", name: "Crown")
        case (.baseball, .headwear): Piece(asset: "cap", name: "Baseball Cap")
        case (.apprentice, .headwear): Piece(asset: "wizard_hat", name: "Wizard Hat")
        case (.vacation, .headwear): Piece(asset: "sunglasses", name: "Sunglasses")
        case (.pilot, .headwear): Piece(asset: "goggles", name: "Flying Cap")
        case (.sweetheart, .headwear): Piece(asset: "hair_bow", name: "Hair Bow")

        case (.winterKnit, .clothes): Piece(asset: "sweater", name: "Knit Sweater")
        case (.fieldAgent, .clothes): Piece(asset: "tech_hoodie", name: "Field Jacket")
        case (.artist, .clothes): Piece(asset: "artist_smock", name: "Painter’s Smock")
        case (.scholar, .clothes): Piece(asset: "cardigan", name: "School Cardigan")
        case (.chef, .clothes): Piece(asset: "chef_coat", name: "Chef Coat")
        case (.party, .clothes): Piece(asset: "party_vest", name: "Party Sweater")
        case (.king, .clothes): Piece(asset: "royal_cape", name: "Royal Cape")
        case (.baseball, .clothes): Piece(asset: "varsity", name: "Varsity Jacket")
        case (.apprentice, .clothes): Piece(asset: "mage_robe", name: "Wizard Robe")
        case (.vacation, .clothes): Piece(asset: "aloha_shirt", name: "Holiday Shirt")
        case (.pilot, .clothes): Piece(asset: "flight_jacket", name: "Flight Jacket")
        case (.sweetheart, .clothes): Piece(asset: "sweet_cardigan", name: "Heart Cardigan")
        }
    }

    var defaultColors: BearOutfitColors {
        switch self {
        case .winterKnit: BearOutfitColors(primary: 0xFA8C6E, accent: 0xEB6B57)
        case .fieldAgent: BearOutfitColors(primary: 0x3D475C, accent: 0x57E0BD)
        case .artist: BearOutfitColors(primary: 0x75BD7A, accent: 0xF58F70)
        case .scholar: BearOutfitColors(primary: 0x6173D9, accent: 0xFFD157)
        case .chef: BearOutfitColors(primary: 0xFCF5E8, accent: 0xF0737D)
        case .party: BearOutfitColors(primary: 0xFFCF57, accent: 0xF580A6)
        case .king: BearOutfitColors(primary: 0xD14D70, accent: 0xFAC752)
        case .baseball: BearOutfitColors(primary: 0x42BADA, accent: 0xFFD15C)
        case .apprentice: BearOutfitColors(primary: 0x7557B8, accent: 0xFAB842)
        case .vacation: BearOutfitColors(primary: 0xFA7A6E, accent: 0xFFD16B)
        case .pilot: BearOutfitColors(primary: 0xA8734F, accent: 0xFCF5E8)
        case .sweetheart: BearOutfitColors(primary: 0xF58FB3, accent: 0xE0578A)
        }
    }

    var thumbnail: String { String(format: "BearOutfit-%02d", rawValue) }
}

enum BearOutfitSlot: String, CaseIterable {
    case clothes, headwear

    var name: LocalizedStringResource {
        switch self {
        case .clothes: "Clothes"
        case .headwear: "Headwear"
        }
    }
}

struct BearOutfitSelection: Codable, Equatable {
    var headwear: BearOutfit?
    var clothes: BearOutfit?

    static let bare = Self()

    init(_ outfit: BearOutfit? = nil) {
        headwear = outfit
        clothes = outfit
    }

    subscript(_ slot: BearOutfitSlot) -> BearOutfit? {
        get { slot == .headwear ? headwear : clothes }
        set {
            switch slot {
            case .headwear: headwear = newValue
            case .clothes: clothes = newValue
            }
        }
    }

    var matchingSet: BearOutfit? { headwear == clothes ? headwear : nil }

    var displayName: String {
        if let matchingSet { return AppLocalization.text(matchingSet.name) }
        let names = [BearOutfitSlot.headwear, .clothes].compactMap { slot in
            self[slot].map { AppLocalization.text($0.piece(slot).name) }
        }
        if names.isEmpty { return AppLocalization.text("No Outfit") }
        let formatter = ListFormatter()
        formatter.locale = AppLocalization.locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }
}

struct BearOutfitColors: Codable, Equatable {
    var primary: UInt32?
    var accent: UInt32?
}

enum BearOutfitColorChannel: CaseIterable, Hashable {
    case primary, accent

    var name: LocalizedStringResource {
        switch self {
        case .primary: "Main Color"
        case .accent: "Accent Color"
        }
    }

    var storage: WritableKeyPath<BearOutfitColors, UInt32?> {
        switch self {
        case .primary: \.primary
        case .accent: \.accent
        }
    }
}

struct BearWornColors: Equatable {
    var headwear = BearOutfitColors()
    var clothes = BearOutfitColors()

    subscript(_ slot: BearOutfitSlot) -> BearOutfitColors { slot == .headwear ? headwear : clothes }
}

@MainActor
@Observable
final class BearWardrobe {
    private struct Saved: Codable {
        var selection = BearOutfitSelection.bare
        var colors: [BearOutfit: BearOutfitColors] = [:]
        var headwearColors: [BearOutfit: BearOutfitColors]?
    }

    static let shared = BearWardrobe()
    static let defaultsKey = "poki.bear.wardrobe"
    private var saved: Saved {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.defaultsKey) }
    }
    private let models = NSCache<NSString, Entity>()
    private let thumbnails = NSCache<NSString, UIImage>()

    private init() {
        saved = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        models.countLimit = 6
    }

    var selection: BearOutfitSelection {
        get { saved.selection }
        set { if newValue != saved.selection { saved.selection = newValue } }
    }

    var wornColors: BearWornColors {
        BearWornColors(headwear: self[colors: .headwear], clothes: self[colors: .clothes])
    }

    subscript(colors slot: BearOutfitSlot) -> BearOutfitColors {
        get {
            guard let outfit = selection[slot] else { return BearOutfitColors() }
            let colors = slot == .headwear ? saved.headwearColors : saved.colors
            return colors?[outfit] ?? BearOutfitColors()
        }
        set {
            guard let outfit = selection[slot], newValue != self[colors: slot] else { return }
            let override = newValue == BearOutfitColors() ? nil : newValue
            switch slot {
            case .headwear:
                var colors = saved.headwearColors ?? [:]
                colors[outfit] = override
                saved.headwearColors = colors.isEmpty ? nil : colors
            case .clothes:
                saved.colors[outfit] = override
            }
        }
    }

    func thumbnail(_ name: String) -> UIImage? {
        let key = name as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    func load(_ outfit: BearOutfit?, for slot: BearOutfitSlot) async -> Entity? {
        guard let piece = outfit?.piece(slot) else { return nil }
        let key = piece.asset as NSString
        if let model = models.object(forKey: key) { return model }
        guard let url = Bundle.main.url(forResource: "BearOutfit-\(piece.asset)", withExtension: "usdz"),
              let model = try? await Entity(contentsOf: url) else { return nil }
        models.setObject(model, forKey: key)
        return model
    }
}
