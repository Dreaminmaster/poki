import RealityKit
import UIKit

struct BearOutfitModels {
    var selection = BearOutfitSelection.bare
    var headwear: Entity?
    var clothes: Entity?

    subscript(_ slot: BearOutfitSlot) -> Entity? { slot == .headwear ? headwear : clothes }
}

@MainActor
final class BearDressing {
    enum Motion { case immediate, fade, animated }

    @MainActor
    private struct Piece {
        struct Skin {
            let model: ModelEntity
            let joints: [Int]
            let paints: [Int: KeyPath<BearOutfitColors, UInt32?>]
            let materials: [any Material]
        }

        let root = Entity()
        let skins: [Skin]
        var start: TimeInterval
        var motion: Motion

        init(template: Entity, slot: BearOutfitSlot, joints: [String], start: TimeInterval, motion: Motion, light: Entity?) {
            self.start = start
            self.motion = motion
            root.addChild(template.clone(recursive: true))
            var skins: [Skin] = []
            func collect(_ entity: Entity) {
                if let model = entity as? ModelEntity, !model.jointNames.isEmpty {
                    let indices = model.jointNames.compactMap { joints.firstIndex(of: $0) }
                    if indices.count == model.jointNames.count, let component = model.model {
                        var paints: [Int: KeyPath<BearOutfitColors, UInt32?>] = [:]
                        if slot == .clothes {
                            // RealityKit groups meshes that share a skeleton into one model entity.
                            for mesh in component.mesh.contents.models {
                                let color: KeyPath<BearOutfitColors, UInt32?>
                                if mesh.id.hasPrefix("Primary_") { color = \.primary }
                                else if mesh.id.hasPrefix("Accent_") { color = \.accent }
                                else { continue }
                                for part in mesh.parts { paints[part.materialIndex] = color }
                            }
                        }
                        skins.append(Skin(model: model, joints: indices, paints: paints, materials: component.materials))
                        if let light { model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light)) }
                    } else {
                        model.isEnabled = false
                    }
                }
                entity.children.forEach(collect)
            }
            collect(root)
            self.skins = skins
        }

        func follow(_ joints: [Transform]) {
            for skin in skins {
                skin.model.jointTransforms = skin.joints.map { joints[$0] }
            }
        }

        func recolor(_ colors: BearOutfitColors) {
            for skin in skins where !skin.paints.isEmpty {
                guard var component = skin.model.model else { continue }
                var materials = skin.materials
                for (index, color) in skin.paints {
                    guard let rgb = colors[keyPath: color], var material = materials[index] as? PhysicallyBasedMaterial else { continue }
                    material.baseColor.tint = UIColor(hex: rgb)
                    materials[index] = material
                }
                component.materials = materials
                skin.model.model = component
            }
        }

        func place(slot: BearOutfitSlot, amount: Float, incoming: Bool, opacity: Float) {
            root.components.set(OpacityComponent(opacity: opacity))
            guard motion == .animated else { return }
            let anchor = SIMD3<Float>(0, slot == .headwear ? 1.13 : 0.57, 0)
            if slot == .headwear {
                let rotation = simd_quatf(angle: amount * (incoming ? -10 : 8) * .pi / 180, axis: SIMD3(0, 0, 1))
                root.transform = Transform(scale: .one, rotation: rotation,
                                           translation: anchor - rotation.act(anchor) + SIMD3(0, amount * (incoming ? 0.32 : 0.13), 0))
            } else {
                let scale = 1 - amount * (incoming ? 0.28 : 0.14)
                root.transform = Transform(scale: SIMD3(repeating: scale), rotation: simd_quatf(), translation: anchor * (1 - scale))
            }
        }
    }

    let root = Entity()
    private var current: [BearOutfitSlot: Piece] = [:]
    private var outgoing: [BearOutfitSlot: Piece] = [:]
    private var armRest: Float = 0
    private var armChange = (from: Float(0), start: TimeInterval(0))
    private var selection = BearOutfitSelection.bare
    private var colors = BearOutfitColors()
    private let names: [String]
    private let arms: [(Int, simd_quatf)]
    private let light: Entity?
    private var pending = false

    init(names: [String], light: EnvironmentResource?) {
        self.names = names
        self.light = light.map { resource in
            let source = Entity()
            source.components.set(ImageBasedLightComponent(source: .single(resource), intensityExponent: 0.55))
            return source
        }
        // Local joint deltas from the standing pose to the garment fitting pose.
        let offsets: [(String, SIMD4<Float>)] = [
            ("UpperArm_R", SIMD4(-0.001750, 0.001576, -0.024753, 0.999691)),
            ("Forearm_R", SIMD4(0.402428, 0, -0.298865, 0.865293)),
            ("UpperArm_L", SIMD4(-0.001750, -0.001576, 0.024753, 0.999691)),
            ("Forearm_L", SIMD4(0.402428, 0, 0.298865, 0.865293))
        ]
        arms = offsets.compactMap { name, offset in
            names.firstIndex { $0 == name || $0.hasSuffix("/" + name) }.map { ($0, simd_normalize(simd_quatf(vector: offset))) }
        }
        if let source = self.light { root.addChild(source) }
    }

    func wear(_ outfit: BearOutfitModels, colors: BearOutfitColors, motion: Motion, now: TimeInterval) -> Bool {
        let next = outfit.selection
        guard next != selection || colors != self.colors else { return false }
        let changes = BearOutfitSlot.allCases.filter { next[$0] != selection[$0] }
        for (index, slot) in changes.enumerated() {
            let start = now + (motion == .animated ? Double(index) * 0.08 : 0)
            outgoing.removeValue(forKey: slot)?.root.removeFromParent()
            if var old = current.removeValue(forKey: slot) {
                if motion != .immediate {
                    old.start = start
                    old.motion = motion
                    outgoing[slot] = old
                } else {
                    old.root.removeFromParent()
                }
            }
            if let template = outfit[slot] {
                let delay = motion == .animated && outgoing[slot] != nil ? 0.08 : 0
                let piece = Piece(template: template, slot: slot, joints: names, start: start + delay, motion: motion, light: light)
                if !piece.skins.isEmpty {
                    root.addChild(piece.root)
                    if motion != .immediate { piece.place(slot: slot, amount: 1, incoming: true, opacity: 0) }
                    current[slot] = piece
                }
            }
        }
        if changes.contains(.clothes) {
            let start: TimeInterval
            switch motion {
            case .animated: start = now
            case .fade: start = next.clothes == nil ? now + 0.15 : -.infinity
            case .immediate: start = -.infinity
            }
            armChange = (armRest, start)
        }
        current[.clothes]?.recolor(colors)
        selection = next
        self.colors = colors
        pending = true
        return true
    }

    func poseArms(_ joints: inout [Transform], at now: TimeInterval, gesture: Float) {
        let target: Float = current[.clothes] == nil ? 0 : 1
        let weight = Float(min(max((now - armChange.start) / 0.28, 0), 1))
        armRest = armChange.from + (target - armChange.from) * BearIdle.ease(weight)
        guard armRest > 0 else { return }
        for (index, offset) in arms {
            joints[index].rotation *= simd_slerp(simd_quatf(), offset, armRest * (1 - gesture))
        }
    }

    func update(_ joints: [Transform], at now: TimeInterval) -> Bool {
        var changed = pending
        pending = false
        for (slot, piece) in current {
            piece.follow(joints)
            guard piece.motion != .immediate else { continue }
            let duration = piece.motion == .fade ? 0.15 : (slot == .headwear ? 0.34 : 0.30)
            let progress = Float(max(0, (now - piece.start) / duration))
            if progress <= 1 {
                let bounce: Float = slot == .headwear ? 0.42 : 0.38
                let decay = (1 - progress) * (1 - progress)
                let spring = decay * cos(progress * .pi * (1.5 + bounce))
                let opacity = piece.motion == .fade ? progress : Float(min(max((now - piece.start) / 0.10, 0), 1))
                piece.place(slot: slot, amount: spring, incoming: true, opacity: opacity)
                pending = true
                changed = true
            } else if piece.root.components.has(OpacityComponent.self) {
                piece.root.transform = Transform()
                piece.root.components.remove(OpacityComponent.self)
                changed = true
            }
        }
        for (slot, piece) in outgoing {
            let duration = piece.motion == .fade ? 0.15 : 0.14
            let progress = Float(max(0, (now - piece.start) / duration))
            changed = true
            if progress >= 1 {
                piece.root.removeFromParent()
                outgoing.removeValue(forKey: slot)
            } else {
                piece.follow(joints)
                piece.place(slot: slot, amount: progress * progress, incoming: false, opacity: 1 - progress)
            }
        }
        return changed
    }
}
