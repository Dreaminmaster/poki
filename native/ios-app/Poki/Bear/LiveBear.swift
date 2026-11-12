import Metal
import QuartzCore
import RealityKit
import SwiftUI
import UIKit

// The three-dimensional bear, drawn live by RealityKit. The renderer's setup (RealityRenderer, the
// camera, light only from the model's own picture at exponent 0, no other light, no tone mapping,
// four-times multisampling, the paused animations scrubbed by time) is the modelling's own check
// renderer, rkrender.swift, with which the bear's colours were matched to the design. Any other light
// greys it.

/// The model's three files in Bear/Model, as the modelling hands them over. A new version of the bear
/// is these three files replaced; nothing in the code names a frame or a size of its own.
/// - PokiBear.usdz: the bear, with one timeline that holds every gesture;
/// - PokiBear-clips.json: where on that timeline each gesture is, in frames;
/// - PokiBear-light.png: the light it was coloured under.
@MainActor
@Observable
final class BearModel {
    static let shared = BearModel()

    struct Loaded {
        let entity: Entity
        let clips: BearClips
        let light: EnvironmentResource
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
                // `-pokiBearLoad slow` or `fail`: the late and the broken model, to see the flat bear stand in.
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
                loaded = Loaded(entity: entity, clips: clips, light: light)
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

    /// Reads `{"fps": 30, "clips": {"idle": [95, 105], "wave": [20, 94], "blink": [5, 12]},
    /// "design_hello_frame": 42}`. A file without the three gestures is not a bear; without the hello
    /// frame, the wave's middle stands in.
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

    /// How long a move takes; idle lasts until the next one.
    func length(_ move: BearMove) -> TimeInterval {
        switch move {
        case .idle: .infinity
        case .blink: blink.upperBound - blink.lowerBound
        case .hi: 2 * (hello - wave.lowerBound) / BearMove.hiPace
        }
    }

    /// The time on the timeline `elapsed` seconds into a move.
    func time(_ move: BearMove, after elapsed: TimeInterval) -> TimeInterval {
        switch move {
        case .idle:
            // The idle clip is the bear standing still: its frames differ by less than a pixel at the
            // picture's size, so it holds the first one and draws nothing until it blinks.
            #if DEBUG
            // `-pokiBearFrame <frame>` holds that frame of the timeline instead, to look at one pose.
            if let frame = UserDefaults.standard.string(forKey: "pokiBearFrame").flatMap(Double.init) { return frame / fps }
            #endif
            return idle.lowerBound
        case .blink:
            // Whole frames only: the eyes are swapped between frames (the open pupils, the line, the
            // smile), and between two of them neither shows, which left the eye pads blank and white.
            // The time is a frame's number over the rate, as the modeller's renderer has it: an eye
            // shape is there at its frame exactly, and a sum of frame lengths may fall a hair short.
            let x = min(max(elapsed, 0), length(.blink))
            return ((blink.lowerBound * fps).rounded() + (x * fps + 1e-6).rounded(.down)) / fps
        case .hi:
            let rise = hello - wave.lowerBound, x = min(max(elapsed * BearMove.hiPace, 0), 2 * rise)
            return wave.lowerBound + (x <= rise ? x : 2 * rise - x)
        }
    }
}

/// What the bear does. `hi` answers a tap: the wave's rise to its top and back down, half as fast
/// again, about a second in all, so it is over before what the tap opens has come up.
enum BearMove {
    case idle, blink, hi
    static let hiPace = 1.5
}

/// What the bear is doing and since when: a move plays once, then the next one queued, then idle,
/// which holds. Every few seconds of idle it blinks, now and then twice (as `BlinkingFace` does).
struct BearPlayback {
    private(set) var move: BearMove = .idle
    private var since: TimeInterval = 0
    private var queued: [BearMove] = []
    private(set) var nextBlink: TimeInterval = 0

    /// Nothing but idle and blinks: a tap may start a move.
    var free: Bool { move != .hi }

    mutating func play(_ moves: [BearMove], at now: TimeInterval) {
        queued = Array(moves.dropFirst())
        move = moves.first ?? .idle
        since = now
        if move == .idle { scheduleBlink(after: now) }
    }

    /// The time on the model's timeline to show at `now`.
    mutating func time(at now: TimeInterval, clips: BearClips) -> TimeInterval {
        while move != .idle, now - since > clips.length(move) {
            since += clips.length(move)
            move = queued.isEmpty ? .idle : queued.removeFirst()
            if move == .idle { scheduleBlink(after: since) }
        }
        if move == .idle, now >= nextBlink {
            play(Int.random(in: 0..<4) == 0 ? [.blink, .blink] : [.blink], at: now)
        }
        return clips.time(move, after: now - since)
    }

    private mutating func scheduleBlink(after now: TimeInterval) {
        nextBlink = now + .random(in: 2.5...5.5)
    }
}

/// The white pads behind the bear's eyes, shut with the eyes. In the model they are fixed to the head,
/// so a blink drew its line, and the smile its arc, on two whole white discs: the white-painted eyes
/// the flat bear was faulted for. Here each pad is drawn apart from the bear and follows its eye's
/// joint, which squeezes it with the pupil as the eye shuts, and it fades as it shuts, so a shut eye
/// leaves a faint trace of its pad round the line, as the flat bear's does. The model is unchanged:
/// its own pads are only not drawn. A bear without parts named `EyePad_L…` and `EyePad_R…` and joints
/// ending in `Eye_L` and `Eye_R` keeps its pads as they are.
@MainActor
private struct EyePads {
    /// How much of a pad shows once its eye is shut.
    static let shut: Float = 0.3

    private let pads: [(entity: ModelEntity, joint: Int)]
    private let bear: ModelEntity
    private let parents: [Int?]
    private let inverseBind: [simd_float4x4]
    private let material: PhysicallyBasedMaterial

    init?(bear: ModelEntity) {
        guard var model = bear.model, let skeleton = model.mesh.contents.skeletons.first else { return nil }
        let contents = model.mesh.contents
        let names = skeleton.joints.map(\.name)
        var pads: [(entity: ModelEntity, joint: Int)] = []
        var padMaterial: Int?
        for side in ["L", "R"] {
            let models = contents.models.filter { $0.id.hasPrefix("EyePad_\(side)") }
            guard let joint = names.firstIndex(where: { $0.hasSuffix("Eye_\(side)") }),
                  let index = models.first?.parts.first?.materialIndex,
                  let material = model.materials[index] as? PhysicallyBasedMaterial else { return nil }
            var pad = MeshResource.Contents()
            pad.models = MeshModelCollection(models.map { model in
                var model = model
                model.parts = MeshPartCollection(model.parts.map { part in
                    var part = part
                    part.skeletonID = nil
                    part.jointInfluences = nil
                    part.materialIndex = 0
                    return part
                })
                return model
            })
            pad.instances = MeshInstanceCollection(contents.instances.filter { instance in models.contains { $0.id == instance.model } })
            guard let mesh = try? MeshResource.generate(from: pad) else { return nil }
            pads.append((ModelEntity(mesh: mesh, materials: [material]), joint))
            padMaterial = index
        }
        guard let padMaterial, var hidden = model.materials[padMaterial] as? PhysicallyBasedMaterial else { return nil }
        material = hidden
        // The model's own pads are kept but not drawn, not even into depth.
        hidden.blending = .transparent(opacity: .init(scale: 0))
        hidden.opacityThreshold = 0.5
        model.materials[padMaterial] = hidden
        bear.model = model
        pads.forEach { bear.addChild($0.entity) }
        self.pads = pads
        self.bear = bear
        parents = skeleton.joints.map(\.parentIndex)
        inverseBind = skeleton.joints.map(\.inverseBindPoseMatrix)
    }

    /// Puts each pad where its eye's joint has it at the pose just updated, and fades it as it shuts.
    func follow() {
        let local = bear.jointTransforms.map(\.matrix)
        guard local.count == parents.count else { return }
        func placed(_ joint: Int) -> simd_float4x4 { parents[joint].map { placed($0) * local[joint] } ?? local[joint] }
        for (entity, joint) in pads {
            entity.transform = Transform(matrix: placed(joint) * inverseBind[joint])
            let open = min(max((bear.jointTransforms[joint].scale.y - 0.1) / 0.9, 0), 1)
            var material = material
            if case .transparent(let opacity) = material.blending {
                material.blending = .transparent(opacity: .init(scale: opacity.scale * (Self.shut + (1 - Self.shut) * open), texture: opacity.texture))
            }
            entity.model?.materials = [material]
        }
    }
}

/// Where the chat is covered (the conversations drawer, Poki's profile over it): the bear holds still.
extension EnvironmentValues {
    @Entry var bearCovered = false
}

/// The bear for a face the model has, over the flat picture that stands in for it. The flat picture
/// shows when the face is not the model's, with Reduce Motion or Low Power Mode, when the model failed
/// to load, and when it is not drawn within 0.3 seconds; the model then fades in once it is. The square
/// is never empty past those 0.3 seconds, and a change of face is just there, with no fade.
///
/// A poke makes it say hi (`BearMove.hi`), with a small hop and a tap you feel; a poke while it still
/// does only gets the feel, so moves never pile up. The flat picture hops.
struct ModelBear<Flat: View>: View {
    /// The face is one the model has.
    var modelled: Bool
    /// The square's side at rest, in points: the bear is drawn at that size and scaled from it.
    var side: CGFloat
    /// The bear is in sight: otherwise it holds its last frame and draws nothing. Leaving the screen,
    /// the drawer or the profile over it, and the background count too, without being told.
    var live = true
    /// Counts the touches on the bear.
    var pokes = 0
    @ViewBuilder var flat: () -> Flat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.bearCovered) private var covered
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var shown = false
    @State private var drawn = false
    @State private var waited = false
    @State private var handle = BearHandle()
    @State private var hops = 0
    @State private var hopped = Date.distantPast
    private var store: BearModel { BearModel.shared }

    private var usable: Bool { !reduceMotion && !lowPower && !store.failed }
    private var showsModel: Bool { modelled && usable && drawn }

    var body: some View {
        ZStack {
            flat().opacity(showsModel || (modelled && usable && !waited) ? 0 : 1)
            if usable, let loaded = store.loaded {
                LiveBear(loaded: loaded, pixels: Int((side * displayScale).rounded()), handle: handle,
                         live: live && modelled && shown && !covered && scenePhase == .active) {
                    withAnimation(waited ? .easeOut(duration: 0.3) : nil) { drawn = true }
                }
                .aspectRatio(1, contentMode: .fit)
                .opacity(showsModel ? 1 : 0)
            }
        }
        // A change of face fades between the model and the flat picture.
        .animation(.easeInOut(duration: 0.25), value: modelled)
        .keyframeAnimator(initialValue: 1.0, trigger: hops) { content, scale in
            content.scaleEffect(x: 2 - scale, y: scale, anchor: .bottom)
        } keyframes: { _ in
            CubicKeyframe(0.93, duration: 0.08)
            CubicKeyframe(1.06, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy(duration: 0.35, extraBounce: 0.15))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pokes)
        .onChange(of: pokes) {
            // With Reduce Motion the picture stays still: only the feel of the tap answers.
            if reduceMotion { return }
            if showsModel { if handle.sayHi() { hops += 1 } } else if -hopped.timeIntervalSinceNow > 0.55 { hopped = .now; hops += 1 }
        }
        .task {
            store.load()
            try? await Task.sleep(for: .milliseconds(300))
            waited = true
        }
        .onAppear { shown = true }
        .onDisappear { shown = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// The renderer in a view of its own.
private struct LiveBear: UIViewRepresentable {
    let loaded: BearModel.Loaded
    let pixels: Int
    let handle: BearHandle
    let live: Bool
    let drawn: () -> Void

    func makeUIView(context: Context) -> BearCanvas {
        let canvas = BearCanvas(loaded: loaded, pixels: pixels, drawn: drawn)
        handle.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: BearCanvas, context: Context) { canvas.live = live }

    static func dismantleUIView(_ canvas: BearCanvas, coordinator: ()) { canvas.live = false }
}

/// The way from a touch to the renderer.
@MainActor
final class BearHandle {
    fileprivate weak var canvas: BearCanvas?

    /// Says hi, unless it still is; says whether it does.
    func sayHi() -> Bool { canvas?.sayHi() ?? false }
}

/// A transparent Metal layer the bear is rendered into, 30 times a second while it moves. Once a
/// frame shows the same pose as the last (the idle pose holding still), it stops until the next blink.
private final class BearCanvas: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let renderer: RealityRenderer?
    private let clips: BearClips
    private let drawn: () -> Void
    private var controllers: [AnimationPlaybackController] = []
    private var skins: [ModelEntity] = []
    private var pads: EyePads?
    private var playback = BearPlayback()
    private var link: CADisplayLink?
    private var wake: Task<Void, Never>?
    private var lastPose: [simd_float4x4] = []
    /// Frames still to draw after the pose last changed: the skinning on screen trails the pose by a
    /// frame or two (the check renderer draws three passes for one picture), so the pose a gesture
    /// ends on is drawn a few times before the bear holds still.
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
        // Linear half floats: RealityRenderer premultiplies its edges in linear light, and a layer
        // in linear light blends them so. In an sRGB layer the compositor took those edges for
        // premultiplied in sRGB, and they came out as a bright, stepped rim against the circle.
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = false
        layer.isOpaque = false
        // RealityRenderer writes Display P3 values, as the phone's screen shows them.
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.drawableSize = CGSize(width: max(pixels, 1), height: max(pixels, 1))
        guard let renderer else { return }

        let entity = loaded.entity.clone(recursive: true)
        // The eye pads go in before the bear goes to the renderer: an entity added after it is drawn,
        // but where it was added, whatever it is moved to.
        func skin(_ e: Entity) -> ModelEntity? {
            if let model = e as? ModelEntity, !model.jointNames.isEmpty { return model }
            return e.children.lazy.compactMap(skin).first
        }
        pads = skin(entity).flatMap(EyePads.init)
        renderer.entities.append(entity)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 19.458
        camera.camera.fieldOfViewOrientation = .vertical
        camera.camera.near = 0.05
        camera.camera.far = 100
        // The design's frame: the flat pictures and the model line up in it, the head at the same height.
        camera.look(at: SIMD3(0, 0.9, 0), from: SIMD3(0, 0.9, 3.5), relativeTo: nil)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.lighting.resource = loaded.light
        renderer.lighting.intensityExponent = 0
        renderer.cameraSettings.isToneMappingEnabled = false
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))

        func walk(_ e: Entity) {
            for animation in e.availableAnimations {
                controllers.append(e.playAnimation(animation, transitionDuration: 0, startsPaused: true))
            }
            if let model = e as? ModelEntity, !model.jointNames.isEmpty { skins.append(model) }
            e.children.forEach(walk)
        }
        walk(entity)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        link?.invalidate()
        wake?.cancel()
    }

    fileprivate func sayHi() -> Bool {
        guard live, presented, playback.free else { return false }
        playback.play([.hi], at: CACurrentMediaTime())
        resume()
        return true
    }

    private func resume() {
        wake?.cancel()
        if link == nil {
            let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
            // The gestures are drawn at 30 frames a second: so they move at the rate they were made.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    fileprivate func tick() {
        guard live, !rendering, let renderer, let layer = layer as? CAMetalLayer else { return }
        let now = CACurrentMediaTime()
        let time = playback.time(at: now, clips: clips)
        controllers.forEach { $0.time = time }
        do {
            try renderer.update(0)
            if !presented {
                // As the check renderer does: a few passes at the first frame let the skinning settle.
                try renderer.update(0)
                try renderer.update(0)
            }
            let pose = skins.flatMap { $0.jointTransforms.map(\.matrix) }
            if presented, Self.same(pose, lastPose) {
                if settling == 0 {
                    if playback.move == .idle { sleepUntilBlink() }
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
            // The eyes' shapes are a flip book in the mesh, and on screen it trails the time by a pass:
            // drawn once, the frame after the blink's line was the white of the eye pads with neither
            // the line nor the smile. One pass into a texture never shown, finished before the picture
            // is drawn, as the modeller's renderer draws three for one picture.
            if let spare = spare(like: drawable.texture) {
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

    /// A texture the size of the picture, never shown, for the pass that lets the mesh catch up.
    private func spare(like texture: MTLTexture) -> MTLTexture? {
        if let spareTexture, spareTexture.width == texture.width, spareTexture.height == texture.height { return spareTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        spareTexture = texture.device.makeTexture(descriptor: descriptor)
        return spareTexture
    }

    /// Two poses a pixel cannot tell apart: the idle clip's frames differ by rounding only.
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

    /// The pose holds: nothing to draw until the next blink.
    private func sleepUntilBlink() {
        link?.isPaused = true
        let delay = max(0, playback.nextBlink - CACurrentMediaTime())
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.live else { return }
            self.link?.isPaused = false
        }
    }
}

/// Holds the canvas weakly: a display link keeps its target alive.
private final class Ticker {
    weak var canvas: BearCanvas?
    init(_ canvas: BearCanvas) { self.canvas = canvas }
    @objc func tick() { MainActor.assumeIsolated { canvas?.tick() } }
}

/// `-pokiBearLog YES` writes each frame the bear draws, with its move, to Caches/bear.log: for checking
/// in the simulator that it draws only while something moves and stops when it is out of sight.
/// Debug builds only.
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
