import Foundation
import simd

/// Both pupils share a gaze displacement from their authored pose. Both eye pads limit that displacement.
enum BearEyeBounds {
    enum Side { case right, left }

    struct EyeGeometry {
        /// Visible EyePad ellipse center and semi-axes (mask >= 0.50, measured from PokiBear.usdz frame 95).
        let scleraCenter: SIMD2<Float>
        let scleraRadii: SIMD2<Float>
        /// Authored rest Pupil center and semi-axes in model space (frame 95).
        let pupilRestCenter: SIMD2<Float>
        let pupilRadii: SIMD2<Float>
        /// Bone origin in Head-relative model space (X right, Y up, Z forward).
        let boneOrigin: SIMD3<Float>
    }

    struct SphericalTransform: Equatable {
        /// Shared gaze displacement from the authored pose.
        var gazeDelta: SIMD2<Float>
        /// Joint translation delta to rotate smoothly over the head surface.
        var translation: SIMD3<Float>
        /// Joint rotation aligning the curved pupil patch with the head curvature.
        var rotation: simd_quatf
    }

    /// Head sphere center in model space (Y up, Z forward), fitted to `Head_001` front face.
    static let headCenter = SIMD3<Float>(-0.015, 0.895, 0.010)

    static let right = EyeGeometry(
        scleraCenter: SIMD2(-0.18083, 0.90705),
        scleraRadii: SIMD2(0.13107, 0.14747),
        pupilRestCenter: SIMD2(-0.13633, 0.91185),
        pupilRadii: SIMD2(0.08486, 0.08862),
        boneOrigin: SIMD3(-0.1833, 0.9107, 0.4224)
    )

    static let left = EyeGeometry(
        scleraCenter: SIMD2(0.17619, 0.90072),
        scleraRadii: SIMD2(0.13008, 0.14743),
        pupilRestCenter: SIMD2(0.13239, 0.90876),
        pupilRadii: SIMD2(0.08494, 0.08923),
        boneOrigin: SIMD3(0.1787, 0.9054, 0.4075)
    )

    static func geometry(for side: Side) -> EyeGeometry {
        side == .right ? right : left
    }

    /// Computes strictly synchronized, strictly contained spherical eye transforms for both eyes.
    /// Both returned transforms always carry the exact same `gazeDelta`.
    static func transforms(
        desiredGaze: SIMD2<Float>,
        headYaw: Float,
        headPitch: Float
    ) -> (right: SphericalTransform, left: SphericalTransform) {
        let shared = clampSharedGaze(
            desired: desiredGaze,
            headYaw: headYaw,
            headPitch: headPitch
        )
        return (
            right: spherical(side: .right, gazeDelta: shared),
            left: spherical(side: .left, gazeDelta: shared)
        )
    }

    /// Limits both pupils to the common space inside the eye pads.
    static func clampSharedGaze(
        desired: SIMD2<Float>,
        headYaw: Float,
        headPitch: Float
    ) -> SIMD2<Float> {
        // The authored pupils sit near the inner edges, leaving more room vertically than horizontally.
        let inset = SIMD2<Float>(0.0004 + 0.001 * min(abs(headYaw), 0.35), 0.004 + 0.006 * abs(headPitch))

        func span(in eye: EyeGeometry, along axis: Int, at cross: Float) -> SIMD2<Float> {
            let other = 1 - axis
            let radii = eye.scleraRadii - eye.pupilRadii - inset
            let center = eye.scleraCenter - eye.pupilRestCenter
            let offset = (cross - center[other]) / radii[other]
            let extent = radii[axis] * sqrt(max(0, 1 - offset * offset))
            return [center[axis] - extent, center[axis] + extent]
        }

        // Limit height at the authored X first, so a small horizontal motion cannot throw the pupils vertically.
        let rightY = span(in: right, along: 1, at: 0)
        let leftY = span(in: left, along: 1, at: 0)
        let y = min(max(desired.y, max(rightY.x, leftY.x)), min(rightY.y, leftY.y))
        let rightX = span(in: right, along: 0, at: y)
        let leftX = span(in: left, along: 0, at: y)
        let x = min(max(desired.x, max(rightX.x, leftX.x)), min(rightX.y, leftX.y))
        return [x, y]
    }

    /// Rotates each pupil around the head center to follow the curved eye pad.
    static func spherical(side: Side, gazeDelta: SIMD2<Float>) -> SphericalTransform {
        let mag = simd_length(gazeDelta)
        if mag < 1e-6 {
            return SphericalTransform(
                gazeDelta: gazeDelta,
                translation: .zero,
                rotation: simd_quatf(angle: 0, axis: [0, 1, 0])
            )
        }
        let r = geometry(for: side).boneOrigin - headCenter
        let radiusXZ = hypot(r.x, r.z)
        let radiusYZ = hypot(r.y, r.z)
        let yaw = gazeDelta.x / radiusXZ
        let pitch = -gazeDelta.y / radiusYZ
        let rot = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        let rotated = rot.act(r)
        let outward = simd_normalize(rotated)
        let clearance = min(mag / 0.010, 1) * Float(0.0046)
        let dt = (rotated - r) + outward * clearance
        return SphericalTransform(gazeDelta: gazeDelta, translation: dt, rotation: rot)
    }
}
