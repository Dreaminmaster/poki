import Metal
import QuartzCore
import RealityKit
import SwiftUI
import UIKit

// RealityKit draws the bear under its authored environment light.

/// The model's files in Bear/Model:
/// - PokiBear.usdz: the bear, unchanged, with one timeline that holds every base gesture;
/// - PokiBear-expressions.usdz: optional mouth expressions aligned to Head;
/// - PokiBear-clips.json: where on that timeline each gesture is, in frames;
/// - PokiBear-light.png: the environment light used to colour the bear.
@MainActor
@Observable
final class BearModel {
    static let shared = BearModel()

    struct Loaded {
        let entity: Entity
        let expressions: Entity?
        let clips: BearClips
        let light: EnvironmentResource
        let outfitLight: EnvironmentResource?
    }

    private(set) var loaded: Loaded?
    private(set) var failed = false
    @ObservationIgnored private var started = false

    /// Starts loading once; at launch, so the home page usually has the bear before it shows.
    func load() {
        guard !started else { return }
        started = true
        Task {
            do {
                let test = UserDefaults.standard.string(forKey: "pokiBearLoad")
                if test == "slow" { try await Task.sleep(for: .seconds(5)) }
                guard test != "fail",
                      let model = Bundle.main.url(forResource: "PokiBear", withExtension: "usdz"),
                      let clipsURL = Bundle.main.url(forResource: "PokiBear-clips", withExtension: "json"),
                      let lightURL = Bundle.main.url(forResource: "PokiBear-light", withExtension: "png"),
                      let source = CGImageSourceCreateWithURL(lightURL as CFURL, nil),
                      let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { throw CocoaError(.fileNoSuchFile) }
                let clips = try BearClips(json: Data(contentsOf: clipsURL))
                let light = try await EnvironmentResource(equirectangular: picture, withName: "PokiBear-light")
                let entity = try await Entity(contentsOf: model)
                let expressions: Entity?
                if let exprURL = Bundle.main.url(forResource: "PokiBear-expressions", withExtension: "usdz") {
                    expressions = try? await Entity(contentsOf: exprURL)
                } else {
                    expressions = nil
                }
                let outfitLight: EnvironmentResource?
                if let url = Bundle.main.url(forResource: "BearOutfit-light", withExtension: "png"),
                   let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    outfitLight = try? await EnvironmentResource(equirectangular: image, withName: "BearOutfit-light")
                } else {
                    outfitLight = nil
                }
                loaded = Loaded(entity: entity, expressions: expressions, clips: clips, light: light, outfitLight: outfitLight)
            } catch {
                failed = true
            }
        }
    }
}

/// The gestures on the model's timeline, in seconds.
struct BearClips {
    let idle, wave, blink: ClosedRange<TimeInterval>
    /// The top of the wave, where it matches the design's hello picture.
    let hello: TimeInterval
    /// Frames a second on the model's timeline.
    let fps: Double

    init(json: Data) throws {
        struct File: Decodable {
            let fps: Double
            let clips: [String: [Int]]
            let design_hello_frame: Int?
        }
        let file = try JSONDecoder().decode(File.self, from: json)
        func span(_ name: String) throws -> ClosedRange<TimeInterval> {
            guard let frames = file.clips[name], frames.count == 2, frames[0] <= frames[1], file.fps > 0 else {
                throw CocoaError(.coderReadCorrupt)
            }
            return Double(frames[0]) / file.fps...Double(frames[1]) / file.fps
        }
        fps = file.fps
        idle = try span("idle")
        wave = try span("wave")
        blink = try span("blink")
        let top = file.design_hello_frame.map { Double($0) / file.fps } ?? (wave.lowerBound + wave.upperBound) / 2
        hello = min(max(top, wave.lowerBound), wave.upperBound)
    }

    func length(_ move: BearMove) -> TimeInterval {
        switch move {
        case .idle: .infinity
        case .blink: BearBlink.length
        case .hi: 2 * (hello - wave.lowerBound) / BearMove.hiPace
        }
    }

    func time(_ move: BearMove, after elapsed: TimeInterval) -> TimeInterval {
        switch move {
        case .idle:
            #if DEBUG
            if let frame = UserDefaults.standard.string(forKey: "pokiBearFrame").flatMap(Double.init) { return frame / fps }
            #endif
            return idle.lowerBound
        case .blink:
            return ((blink.lowerBound * fps).rounded() + BearBlink.at(elapsed).frame) / fps
        case .hi:
            let rise = hello - wave.lowerBound, x = min(max(elapsed * BearMove.hiPace, 0), 2 * rise)
            return wave.lowerBound + (x <= rise ? x : 2 * rise - x)
        }
    }
}

/// The blink, at the pace the bear has always blinked: the lids come down over 0.14 s to a thin line,
/// stay shut for 0.06 s as a low arc no taller than that line, and go up over 0.2 s, easing in and
/// out each way: 0.4 s in all. The model's frames still give the shapes (open to half shut, its first
/// two steps; the closed eye, its middle two; half open to open, its last two), and between the pupil
/// and the arc the eyes are swapped at a whole frame only, since between two of them neither shows
/// and the eye pads were blank and white.
enum BearBlink {
    static let closing: TimeInterval = 0.14, shut: TimeInterval = 0.06, opening: TimeInterval = 0.2
    static var length: TimeInterval { closing + shut + opening }
    static let thin: Float = 0.12
    static let flat: Float = 0.3
    /// Seconds of open eyes between one blink and the next, drawn at random. The bear blinks once every
    /// 5.9 s on average (4 to 7 s of open eyes and the 0.4 s blink), and now and then twice: the
    /// second blink comes `doubleGap` after the first and is on top of that rate, so the open stretch
    /// after a pair is lengthened to make up for it, 6.3 s on average:
    /// (6.3 + 0.4 + 0.15 * (0.13 + 0.4)) / 1.15 = 5.9.
    static let gap: ClosedRange<TimeInterval> = 4.6...8.0
    /// Short pause between the first and second blink in an occasional double blink.
    static let doubleGap: ClosedRange<TimeInterval> = 0.10...0.16
    /// Probability that a blink is followed immediately by a second blink.
    static let doubleChance: Double = 0.15

    struct Moment: Equatable {
        var frame: Double
        var pupils: Float?
        var arcs: Float?
    }

    static func at(_ elapsed: TimeInterval) -> Moment {
        let x = min(max(elapsed, 0), length)
        if x < closing {
            let down = BearIdle.ease(Float(x / closing))
            return Moment(frame: 2 * Double(down), pupils: 1 - (1 - thin) * down, arcs: nil)
        }
        if x < closing + shut {
            return Moment(frame: (x - closing) / shut < 0.5 ? 3 : 4, pupils: nil, arcs: flat)
        }
        let up = BearIdle.ease(Float((x - closing - shut) / opening))
        return Moment(frame: 5 + 2 * Double(up), pupils: thin + (1 - thin) * up, arcs: nil)
    }
}

enum BearMove {
    case idle, blink, hi
    static let hiPace = 1.5
}

/// Explicit blink state machine: random intervals, occasional natural double-blinks, without firing
/// while the head is turning rapidly.
struct BearPlayback {
    enum BlinkCycle: Equatable {
        case single
        case pendingFollowUp
    }

    private(set) var move: BearMove = .idle
    private var since: TimeInterval = 0
    private var queued: [BearMove] = []
    private(set) var nextBlink: TimeInterval = 0
    private(set) var blinkCycle: BlinkCycle = .single

    var free: Bool { move != .hi }

    func blink(at now: TimeInterval) -> BearBlink.Moment? { move == .blink ? BearBlink.at(now - since) : nil }

    mutating func play(_ moves: [BearMove], at now: TimeInterval) {
        queued = Array(moves.dropFirst())
        move = moves.first ?? .idle
        since = now
        if move == .idle {
            blinkCycle = .single
            scheduleBlink(after: now)
        }
    }

    mutating func greet(at now: TimeInterval) {
        blinkCycle = .single
        if move == .blink { queued = [.hi] } else { play([.hi], at: now) }
    }

    mutating func time(at now: TimeInterval, clips: BearClips, steady: Bool = true) -> TimeInterval {
        while move != .idle, now - since > clips.length(move) {
            let finished = move
            since += clips.length(move)
            move = queued.isEmpty ? .idle : queued.removeFirst()
            if move == .idle {
                if finished == .blink, blinkCycle == .single, Double.random(in: 0..<1) < BearBlink.doubleChance {
                    blinkCycle = .pendingFollowUp
                    nextBlink = since + .random(in: BearBlink.doubleGap)
                } else {
                    blinkCycle = .single
                    scheduleBlink(after: since)
                }
            }
        }
        if move == .idle, now >= nextBlink, (steady || blinkCycle == .pendingFollowUp) {
            let nextCycle = blinkCycle
            play([.blink], at: now)
            blinkCycle = nextCycle
        }
        return clips.time(move, after: now - since)
    }

    private mutating func scheduleBlink(after now: TimeInterval) {
        nextBlink = now + .random(in: BearBlink.gap)
    }
}

/// Fades the white eye pads and hides the highlights as the eyes shut, using the original mesh.
/// Never regenerates the skinned mesh (which triggers a CoreRE assertion on physical iOS 27.0).
@MainActor
private struct EyePads {
    static let shutting: Float = 0.75

    private let bear: ModelEntity
    private let eyes: [Int]
    private let pad: Int, highlight: Int
    private let white: PhysicallyBasedMaterial
    private let shown: PhysicallyBasedMaterial
    private let hidden: PhysicallyBasedMaterial
    private var drawnOpen: Float = 1

    init?(bear: ModelEntity) {
        guard let model = bear.model, let skeleton = model.mesh.contents.skeletons.first else { return nil }
        let contents = model.mesh.contents
        let names = skeleton.joints.map(\.name)
        func materialIndex(_ prefix: String) -> Int? {
            let indices = Set(contents.models.filter { $0.id.hasPrefix(prefix) }.flatMap { $0.parts.map(\.materialIndex) })
            return indices.count == 1 ? indices.first : nil
        }
        guard let pad = materialIndex("EyePad_"), let highlight = materialIndex("Catchlight_"),
              let white = model.materials[pad] as? PhysicallyBasedMaterial,
              let highlightMaterial = model.materials[highlight] as? PhysicallyBasedMaterial else { return nil }
        var eyes: [Int] = []
        for part in contents.models {
            if part.id.hasPrefix("EyePad_") {
                let side = part.id.dropFirst("EyePad_".count).prefix(1)
                guard let eye = names.firstIndex(where: { $0 == "Eye_\(side)" || $0.hasSuffix("/Eye_\(side)") }) else { return nil }
                eyes.append(eye)
            }
        }
        guard eyes.count == 2 else { return nil }
        self.bear = bear
        self.eyes = eyes
        self.pad = pad
        self.highlight = highlight
        self.white = white
        shown = highlightMaterial
        var hidden = highlightMaterial
        hidden.blending = .transparent(opacity: .init(scale: 0))
        hidden.writesDepth = false
        self.hidden = hidden
    }

    mutating func follow() {
        let transforms = bear.jointTransforms
        var open: Float = 1
        for eye in eyes where eye < transforms.count {
            let x = min(max((transforms[eye].scale.y - Self.shutting) / (1 - Self.shutting), 0), 1)
            open = min(open, x * x * (3 - 2 * x))
        }
        guard open != drawnOpen, var model = bear.model else { return }
        drawnOpen = open
        var pads = white
        if case .transparent(let opacity) = white.blending {
            pads.blending = .transparent(opacity: .init(scale: opacity.scale * open, texture: opacity.texture))
        }
        model.materials[pad] = pads
        model.materials[highlight] = open == 1 ? shown : hidden
        bear.model = model
    }
}

/// Keeps the mouth expressions aligned with the bear's skinned head.
@MainActor
private struct BearExpressionOverlay {
    private struct Part {
        let face: BearFace
        let entity: Entity
    }

    let root: Entity
    private let parts: [Part]
    private let headChain: [Int]
    private let headBindInverse: simd_float4x4

    init?(
        template: Entity,
        skin: ModelEntity,
        bindJoints: [Transform]
    ) {
        let names = skin.jointNames
        guard let headIndex = names.firstIndex(where: { $0 == "Head" || $0.hasSuffix("/Head") }) else { return nil }
        var chain: [Int] = []
        var cursor: Int? = headIndex
        while let idx = cursor {
            chain.append(idx)
            let path = names[idx]
            if let slash = path.lastIndex(of: "/") {
                let parentPath = String(path[..<slash])
                cursor = names.firstIndex(of: parentPath)
            } else {
                cursor = nil
            }
        }
        chain.reverse()
        guard !chain.isEmpty else { return nil }

        let root = Entity()
        let content = template.clone(recursive: true)
        root.addChild(content)

        var parts: [Part] = []
        func collect(_ entity: Entity) {
            if let model = entity as? ModelEntity, model.model != nil {
                model.isEnabled = false
                if let face = BearFace.allCases.first(where: {
                    model.name.hasPrefix($0.prefix + "Mouth") || model.name.hasPrefix($0.prefix + "Tongue")
                }) {
                    parts.append(Part(face: face, entity: model))
                }
            }
            for child in entity.children { collect(child) }
        }
        collect(content)

        let skinWorld = skin.transformMatrix(relativeTo: nil)
        let bindHeadWorld = skinWorld * Self.chainMatrix(chain, in: bindJoints)

        self.root = root
        self.parts = parts
        self.headChain = chain
        self.headBindInverse = bindHeadWorld.inverse
    }

    private static func chainMatrix(_ chain: [Int], in joints: [Transform]) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        for idx in chain where idx < joints.count {
            m = m * joints[idx].matrix
        }
        return m
    }

    func update(
        skin: ModelEntity,
        joints: [Transform],
        faces: SIMD8<Float>,
        mouthOpen: Float
    ) {
        let skinWorld = skin.transformMatrix(relativeTo: nil)
        let headWorld = skinWorld * Self.chainMatrix(headChain, in: joints)
        root.transform = Transform(matrix: headWorld * headBindInverse)

        for part in parts {
            part.entity.isEnabled = faces[part.face.rawValue] > 0.35 && mouthOpen < 0.25
        }
    }
}

/// Where the chat is covered (the conversations drawer, Poki's profile over it): the bear holds still.
extension EnvironmentValues {
    @Entry var bearCovered = false
    @Entry var bearOutfitPreview = false
}

struct ModelBear<Flat: View>: View {
    private struct DressResponse {
        var x: CGFloat = 1
        var y: CGFloat = 1
    }

    var act: BearAct?
    var side: CGFloat
    var live = true
    var pokes = 0
    @ViewBuilder var flat: () -> Flat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.bearCovered) private var covered
    @Environment(\.bearOutfitPreview) private var outfitPreview
    @State private var shown = false
    @State private var drawn = false
    @State private var waited = false
    @State private var handle = BearHandle()
    @State private var hops = 0
    @State private var hopped = Date.distantPast
    @State private var outfit = BearOutfitModels()
    @State private var fadingToBare = false
    @State private var dressChanges = 0
    @State private var dressDelay = 0.0
    private var store: BearModel { BearModel.shared }
    private var wardrobe: BearWardrobe { BearWardrobe.shared }
    private var modelled: Bool { act != nil }
    private var resting: Bool { DeviceStrain.shared.resting }
    private var outfitMotion: BearDressing.Motion { resting ? .immediate : (reduceMotion ? .fade : .animated) }

    private var usable: Bool {
        guard !store.failed else { return false }
        if resting { return outfitPreview }
        return !reduceMotion || outfit.selection != .bare || fadingToBare
    }
    private var showsModel: Bool { modelled && usable && drawn }

    var body: some View {
        ZStack {
            flat().opacity(showsModel || (modelled && usable && !waited) ? 0 : 1)
            if usable, let loaded = store.loaded {
                LiveBear(loaded: loaded, pixels: Int((side * displayScale).rounded()), handle: handle, act: act ?? .ready,
                         live: live && modelled && shown && !covered && scenePhase == .active,
                         outfitMotion: outfitMotion, outfit: outfit,
                         colorOverride: outfit.selection == wardrobe.selection ? wardrobe.wornColors : nil) {
                    withAnimation(waited ? .easeOut(duration: 0.3) : nil) { drawn = true }
                }
                .aspectRatio(1, contentMode: .fit)
                .opacity(showsModel ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: modelled)
        .keyframeAnimator(initialValue: DressResponse(), trigger: dressChanges) { content, size in
            content.scaleEffect(x: size.x, y: size.y, anchor: .bottom)
        } keyframes: { _ in
            let wearing = outfit.selection != .bare
            KeyframeTrack(\.x) {
                LinearKeyframe(1, duration: dressDelay)
                CubicKeyframe(wearing ? 1.03 : 0.985, duration: wearing ? 0.09 : 0.1)
                SpringKeyframe(1, duration: wearing ? 0.36 : 0.34, spring: .bouncy(duration: 0.36, extraBounce: 0.4))
            }
            KeyframeTrack(\.y) {
                LinearKeyframe(1, duration: dressDelay)
                CubicKeyframe(wearing ? 0.955 : 1.035, duration: wearing ? 0.09 : 0.1)
                SpringKeyframe(1, duration: wearing ? 0.36 : 0.34, spring: .bouncy(duration: 0.36, extraBounce: 0.4))
            }
        }
        .keyframeAnimator(initialValue: 1.0, trigger: hops) { content, scale in
            content.scaleEffect(x: 2 - scale, y: scale, anchor: .bottom)
        } keyframes: { _ in
            CubicKeyframe(0.93, duration: 0.08)
            CubicKeyframe(1.06, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy(duration: 0.35, extraBounce: 0.15))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pokes)
        .onChange(of: pokes) {
            if reduceMotion { return }
            if showsModel { if handle.sayHi() { hops += 1 } } else if -hopped.timeIntervalSinceNow > 0.55 { hopped = .now; hops += 1 }
        }
        .task {
            store.load()
            try? await Task.sleep(for: .milliseconds(300))
            waited = true
        }
        .task(id: wardrobe.selection) {
            let selection = wardrobe.selection
            async let headwear = wardrobe.load(selection.headwear, for: .headwear)
            async let clothes = wardrobe.load(selection.clothes, for: .clothes)
            let models = await BearOutfitModels(selection: selection, headwear: headwear, clothes: clothes)
            guard !Task.isCancelled else { return }
            fadingToBare = outfitMotion == .fade && selection == .bare && outfit.selection != .bare && showsModel
            if showsModel, outfitMotion == .animated, selection != outfit.selection {
                let changing = BearOutfitSlot.allCases.filter { selection[$0] != outfit.selection[$0] }
                dressDelay = changing.enumerated().compactMap { index, slot in
                    selection[slot].map { _ in
                        Double(index) * 0.08 + (outfit.selection[slot] == nil ? 0 : 0.08) + (slot == .headwear ? 0.12 : 0.08)
                    }
                }.max() ?? 0.04
                dressChanges += 1
            }
            outfit = models
            if fadingToBare {
                try? await Task.sleep(for: .milliseconds(180))
                if !Task.isCancelled { fadingToBare = false }
            }
        }
        .onChange(of: usable) { _, usable in if !usable { drawn = false } }
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }
}

private struct LiveBear: UIViewRepresentable {
    let loaded: BearModel.Loaded
    let pixels: Int
    let handle: BearHandle
    let act: BearAct
    let live: Bool
    let outfitMotion: BearDressing.Motion
    let outfit: BearOutfitModels
    let colorOverride: BearWornColors?
    let drawn: () -> Void

    func makeUIView(context: Context) -> BearCanvas {
        let canvas = BearCanvas(loaded: loaded, pixels: pixels, drawn: drawn)
        handle.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: BearCanvas, context: Context) {
        canvas.animated = outfitMotion == .animated
        canvas.act = act
        canvas.live = live
        if let colorOverride { canvas.wear(outfit, colors: colorOverride, motion: outfitMotion) }
    }

    static func dismantleUIView(_ canvas: BearCanvas, coordinator: ()) { canvas.live = false }
}

@MainActor
final class BearHandle {
    fileprivate weak var canvas: BearCanvas?

    func sayHi() -> Bool { canvas?.sayHi() ?? false }
}

/// Draws the skinned bear into a transparent Metal layer.
private final class BearCanvas: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let renderer: RealityRenderer?
    private let clips: BearClips
    private let drawn: () -> Void
    private var skins: [ModelEntity] = []
    private var poses: [Int: [[Transform]]] = [:]
    private var idle = BearIdle(now: CACurrentMediaTime())
    private var poseFilter = BearPoseFilter()
    private var idleSkin: (index: Int, joints: BearIdleJoints)?
    private var faceSkin: (index: Int, joints: BearIdleJoints)?
    private var expressionOverlay: BearExpressionOverlay?
    private var dressing: BearDressing?
    private var rate = 60
    private var reaction: BearReaction?
    private var stance = BearStanceChange(.ready, at: CACurrentMediaTime())
    private var aside: (from: TimeInterval, to: TimeInterval)?
    private var helloPose: [[Transform]]?

    var act: BearAct = .ready {
        didSet {
            guard act != oldValue else { return }
            let now = CACurrentMediaTime()
            stance.go(to: act, at: now)
            idle.calm = ![.ready, .done, .failed].contains(act)
            if live { resume() }
            guard let next = BearReaction(act, at: now) else { return }
            reaction = next
            idle.attend(at: now)
            idle.rest(until: next.end)
            if live { resume() }
        }
    }

    private func reacting(at now: TimeInterval) -> Bool { reaction.map { now < $0.end } ?? false }

    private var eyesBusy = false

    private func stepAside(at now: TimeInterval) -> Float {
        guard let (from, to) = aside else { return 1 }
        if now >= to + 0.3 { aside = nil; return 1 }
        if now < from + 0.2 { return 1 - BearIdle.ease(Float((now - from) / 0.2)) }
        if now < to { return 0 }
        return BearIdle.ease(Float((now - to) / 0.3))
    }

    private var pads: EyePads?
    private var playback = BearPlayback()
    private var link: CADisplayLink?
    private var wake: Task<Void, Never>?
    private var lastPose: [simd_float4x4] = []
    private var settling = 0
    private var rendering = false
    private var presented = false

    var live = false {
        didSet {
            guard live != oldValue else { return }
            if live {
                playback.play([.idle], at: CACurrentMediaTime())
                resume()
            } else {
                link?.isPaused = true
                wake?.cancel()
            }
        }
    }

    var animated = true {
        didSet {
            guard animated != oldValue, live else { return }
            playback.play([.idle], at: CACurrentMediaTime())
            resume()
        }
    }

    func wear(_ outfit: BearOutfitModels, colors: BearWornColors, motion: BearDressing.Motion) {
        if dressing?.wear(outfit, colors: colors, motion: presented ? motion : .immediate, now: CACurrentMediaTime()) == true, live {
            resume()
        }
    }

    init(loaded: BearModel.Loaded, pixels: Int, drawn: @escaping () -> Void) {
        clips = loaded.clips
        self.drawn = drawn
        renderer = try? RealityRenderer()
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let layer = layer as! CAMetalLayer
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = false
        layer.isOpaque = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.drawableSize = CGSize(width: max(pixels, 1), height: max(pixels, 1))
        guard let renderer else { return }

        let entity = loaded.entity.clone(recursive: true)
        func skin(_ e: Entity) -> ModelEntity? {
            if let model = e as? ModelEntity, !model.jointNames.isEmpty { return model }
            return e.children.lazy.compactMap(skin).first
        }
        let primarySkin = skin(entity)
        pads = primarySkin.flatMap(EyePads.init)
        renderer.entities.append(entity)

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 19.458
        camera.camera.fieldOfViewOrientation = .vertical
        camera.camera.near = 0.05
        camera.camera.far = 100
        camera.look(at: SIMD3(0, 0.9, 0), from: SIMD3(0, 0.9, 3.5), relativeTo: nil)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        renderer.lighting.resource = loaded.light
        renderer.lighting.intensityExponent = 0
        renderer.cameraSettings.isToneMappingEnabled = false
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))

        var controllers: [AnimationPlaybackController] = []
        func walk(_ e: Entity) {
            for animation in e.availableAnimations {
                controllers.append(e.playAnimation(animation, transitionDuration: 0, startsPaused: true))
            }
            if let model = e as? ModelEntity, !model.jointNames.isEmpty { skins.append(model) }
            e.children.forEach(walk)
        }
        walk(entity)
        var frames = Set<Int>()
        func add(_ span: ClosedRange<TimeInterval>) {
            frames.formUnion(Int((span.lowerBound * clips.fps).rounded(.down))...Int((span.upperBound * clips.fps).rounded(.up)))
        }
        add(clips.idle.lowerBound...clips.idle.lowerBound)
        add(clips.blink)
        add(clips.wave.lowerBound...clips.hello)
        let held = clips.time(.idle, after: 0)
        add(held...held)
        for frame in frames.sorted() {
            controllers.forEach { $0.time = Double(frame) / clips.fps }
            try? renderer.update(0)
            poses[frame] = skins.map(\.jointTransforms)
        }
        controllers.forEach { $0.stop() }
        helloPose = poses[Int((clips.hello * clips.fps).rounded())]
        faceSkin = skins.indices.lazy.compactMap { i in BearIdleJoints(names: self.skins[i].jointNames).map { (i, $0) } }.first
        if held == clips.idle.lowerBound { idleSkin = faceSkin }

        let idleFrame = Int((clips.idle.lowerBound * clips.fps).rounded())
        if let (index, _) = faceSkin {
            let dressing = BearDressing(names: skins[index].jointNames, light: loaded.outfitLight)
            renderer.entities.append(dressing.root)
            self.dressing = dressing
        }
        if let exprTemplate = loaded.expressions,
           let (idx, _) = faceSkin,
           let bindSet = poses[idleFrame], idx < bindSet.count {
            if let overlay = BearExpressionOverlay(
                template: exprTemplate,
                skin: skins[idx],
                bindJoints: bindSet[idx]
            ) {
                renderer.entities.append(overlay.root)
                expressionOverlay = overlay
            }
        }
    }

    private var moving: Bool {
        idleSkin != nil && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    private func pose(at frame: Double) -> [[Transform]]? {
        let frame = abs(frame - frame.rounded()) < 1e-6 ? frame.rounded() : frame
        let below = Int(frame.rounded(.down)), x = Float(frame - Double(below))
        guard let a = poses[below] ?? poses.min(by: { abs(Double($0.key) - frame) < abs(Double($1.key) - frame) })?.value else { return nil }
        guard x > 1e-4, let b = poses[below + 1] else { return a }
        return zip(a, b).map { a, b in
            zip(a, b).map { a, b in
                Transform(scale: simd_mix(a.scale, b.scale, SIMD3(repeating: x)), rotation: simd_slerp(a.rotation, b.rotation, x),
                          translation: simd_mix(a.translation, b.translation, SIMD3(repeating: x)))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        link?.invalidate()
        wake?.cancel()
    }

    fileprivate func sayHi() -> Bool {
        guard live, animated, presented, playback.free, !reacting(at: CACurrentMediaTime()) else { return false }
        let now = CACurrentMediaTime()
        idle.attend(at: now)
        playback.greet(at: now)
        aside = (now, now + clips.length(.hi) + 0.2)
        resume()
        return true
    }

    private func resume() {
        wake?.cancel()
        if link == nil {
            let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    private static let lead: TimeInterval = 0.2

    fileprivate func tick() {
        guard live, !rendering, let renderer, let layer = layer as? CAMetalLayer else { return }
        let now = CACurrentMediaTime()
        let time = animated ? playback.time(
            at: now,
            clips: clips,
            steady: !moving || !(idle.busy(at: now) || reacting(at: now) || stance.changing(at: now) || eyesBusy)
        ) : clips.idle.lowerBound
        guard var standing = pose(at: time * clips.fps) else { return }
        let blinkMoment = playback.blink(at: now)
        if let blink = blinkMoment, let (index, joints) = faceSkin, index < standing.count {
            joints.shut(blink, in: &standing[index])
        }

        var finalMove = BearIdle.Pose()
        if animated, moving, let (index, joints) = idleSkin, index < standing.count {
            var target = idle.pose(at: now, blinking: playback.move == .blink)
            #if DEBUG
            if let side = UserDefaults.standard.string(forKey: "pokiBearLook").flatMap(Float.init) {
                target = BearIdle.farthest(side)
                poseFilter.reset(to: target, at: now)
            }
            #endif
            target = target + stance.pose(at: now) * stepAside(at: now)
            if let reaction, reacting(at: now) { target = target + reaction.pose(at: now) }

            finalMove = poseFilter.filter(target, at: now)
            if let hello = helloPose, index < hello.count { joints.show(finalMove, from: hello[index], in: &standing[index]) }
            joints.apply(finalMove, to: &standing[index])
            eyesBusy = finalMove.shut > 0.05 || finalMove.smile > 0.05
        }
        if let reaction, !reacting(at: now) { self.reaction = nil }
        var outfitChanged = false
        if let dressing, let (index, _) = faceSkin {
            let gesture = playback.move == .idle || playback.move == .blink
                ? min(1, max(finalMove.raise, finalMove.arms, finalMove.scratch, finalMove.work)) : 1
            dressing.poseArms(&standing[index], at: now, gesture: gesture)
            outfitChanged = dressing.update(standing[index], at: now)
        }
        for (skin, joints) in zip(skins, standing) { skin.jointTransforms = joints }

        if let overlay = expressionOverlay, let (index, _) = faceSkin, index < skins.count, index < standing.count {
            overlay.update(
                skin: skins[index],
                joints: standing[index],
                faces: finalMove.faces,
                mouthOpen: finalMove.mouth
            )
        }

        // Smooth 60 fps during blinks, saccades, spring overshoots, and state changes; 30 fps during
        // calm breathing and weight shifts (replaces old choppy 10 fps idle cadence).
        let still: Set<BearAct> = [.ready, .done, .failed, .waiting, .paused]
        let needsHighRate = playback.move != .idle || idle.busy(at: now) || reaction != nil
            || stance.changing(at: now) || poseFilter.active || !still.contains(stance.act) || idle.darting(at: now)
            || playback.nextBlink - now <= Self.lead
        let wanted = needsHighRate || outfitChanged ? 60 : 30
        if wanted != rate {
            rate = wanted
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(wanted), maximum: Float(wanted), preferred: Float(wanted))
        }
        do {
            if !presented {
                try renderer.update(0)
                try renderer.update(0)
                try renderer.update(0)
            }
            let pose = skins.flatMap { $0.jointTransforms.map(\.matrix) }
            if presented, !outfitChanged, Self.same(pose, lastPose) {
                if settling == 0 {
                    if !animated { link?.isPaused = true }
                    else if playback.move == .idle, !moving { sleepUntilBlink() }
                    return
                }
                settling -= 1
            } else {
                settling = 3
            }
            guard let drawable = layer.nextDrawable() else { return }
            pads?.follow()
            BearLog.note(now, playback.move, time * clips.fps)
            lastPose = pose
            rendering = true
            nonisolated(unsafe) let shown = drawable
            if playback.move != .idle, let spare = spare(like: drawable.texture) {
                let warm = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: spare))
                try renderer.updateAndRender(deltaTime: 0, cameraOutput: warm, onComplete: { [weak self] _ in
                    DispatchQueue.main.async { self?.draw(into: shown) }
                })
            } else {
                draw(into: shown)
            }
        } catch {
            rendering = false
        }
    }

    private func draw(into drawable: CAMetalDrawable) {
        guard let renderer else { rendering = false; return }
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.texture))
            nonisolated(unsafe) let shown = drawable
            try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { [weak self] _ in
                shown.present()
                DispatchQueue.main.async { self?.finished() }
            })
        } catch {
            rendering = false
        }
    }

    private var spareTexture: MTLTexture?

    private func spare(like texture: MTLTexture) -> MTLTexture? {
        if let spareTexture, spareTexture.width == texture.width, spareTexture.height == texture.height { return spareTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        spareTexture = texture.device.makeTexture(descriptor: descriptor)
        return spareTexture
    }

    private static func same(_ a: [simd_float4x4], _ b: [simd_float4x4]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let d = x - y
            if max(simd_reduce_max(simd_abs(d.columns.0)), simd_reduce_max(simd_abs(d.columns.1)),
                   simd_reduce_max(simd_abs(d.columns.2)), simd_reduce_max(simd_abs(d.columns.3))) > 1e-4 { return false }
        }
        return true
    }

    private func finished() {
        rendering = false
        if !presented {
            presented = true
            drawn()
        }
    }

    private func sleepUntilBlink() {
        link?.isPaused = true
        let delay = max(0, playback.nextBlink - Self.lead - CACurrentMediaTime())
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.live else { return }
            self.link?.isPaused = false
        }
    }
}

private final class Ticker {
    weak var canvas: BearCanvas?
    init(_ canvas: BearCanvas) { self.canvas = canvas }
    @objc func tick() { MainActor.assumeIsolated { canvas?.tick() } }
}

enum BearLog {
    #if DEBUG
    private static let on = UserDefaults.standard.bool(forKey: "pokiBearLog")
    private static var lines: [String] = []
    static func note(_ now: TimeInterval, _ move: BearMove, _ frame: Double) {
        guard on else { return }
        lines.append(String(format: "%.4f %@ %.3f", now, String(describing: move), frame))
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("bear.log"), atomically: true, encoding: .utf8)
    }
    #else
    @inline(__always) static func note(_ now: TimeInterval, _ move: BearMove, _ frame: Double) {}
    #endif
}
