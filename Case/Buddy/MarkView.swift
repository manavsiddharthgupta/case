import SceneKit
import SwiftUI
import Synchronization

/// The Case mark as the makemvp website shows it: three pieces of polished ceramic.
/// While `active` (listening or working) the pieces come apart and keep moving on their own;
/// when it's done they come back together.
struct MarkView: View {
    var active = false
    var size: CGFloat = 24

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The 3D view is drawn larger than its slot, so drifting pieces aren't cut off.
        MarkSceneView(active: active && !reduceMotion, dark: colorScheme == .dark)
            .frame(width: size * MarkSculpture.overscan, height: size * MarkSculpture.overscan)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .opacity(reduceMotion && active ? 0.55 : 1)
    }
}

private struct MarkSceneView: NSViewRepresentable {
    let active: Bool
    let dark: Bool

    func makeCoordinator() -> MarkSculpture { MarkSculpture() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.delegate = context.coordinator
        view.isPlaying = false
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.setDark(dark)
        context.coordinator.setActive(active)
    }
}

/// A port of makemvp's `sculpture.tsx`: same shapes, ceramic and motion, in SceneKit.
/// It only renders while moving.
nonisolated final class MarkSculpture: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    /// How much bigger the 3D view is than the mark.
    static let overscan: CGFloat = 1.6

    let scene = SCNScene()
    let camera = SCNNode()
    @MainActor weak var view: SCNView?

    private let mark = SCNNode()
    private let material = SCNMaterial()
    private let pieces: [Piece]

    private struct Piece {
        let node: SCNNode
        let direction: SIMD3<Float>
        let distance: Float
        let phase: Float
        let baseZ: Float
    }

    private struct Motion {
        var active = false
        var apart: Float = 0
        var rotation = MarkSculpture.restRotation
        var lastTime: TimeInterval?
    }

    private let motion = Mutex(Motion())

    /// It rests turned a little, so its depth always shows.
    private static let restRotation = SIMD2<Float>(0.16, -0.3)

    @MainActor override init() {
        let out = simd_normalize(SIMD3<Float>(-1, 1, 0))
        func node(_ kind: MarkPiece.Kind, material: SCNMaterial) -> SCNNode {
            SCNNode(geometry: Self.extrude(kind, material: material))
        }
        pieces = [
            Piece(node: node(.band, material: material), direction: [0, 0, 1], distance: 0.35, phase: 0, baseZ: 0),
            Piece(node: node(.topLeft, material: material), direction: out, distance: 0.42, phase: 2.1, baseZ: 0),
            Piece(node: node(.bottomRight, material: material), direction: -out, distance: 0.42, phase: 4.2, baseZ: 0),
        ]
        super.init()

        material.lightingModel = .physicallyBased
        material.metalness.contents = 0
        material.clearCoat.contents = 1
        material.clearCoatRoughness.contents = 0.06
        setDark(false)

        pieces.forEach { mark.addChildNode($0.node) }
        scene.rootNode.addChildNode(mark)

        scene.lightingEnvironment.contents = Self.studio()
        scene.lightingEnvironment.intensity = 1.15
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1200
        key.position = SCNVector3(3, 4, 5)
        key.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(key)

        // Frame the mark so it fills the slot, with room around it to drift.
        let fov: CGFloat = 28
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = fov
        camera.position = SCNVector3(0, 0, Float(Self.overscan) / Float(tan(fov / 2 * .pi / 180)))
        scene.rootNode.addChildNode(camera)

        apply(apart: 0, rotation: Self.restRotation, time: 0)
    }

    @MainActor func setDark(_ dark: Bool) {
        // Light ceramic in dark mode so it still reads, as on the site.
        material.diffuse.contents = dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.045, alpha: 1)
        material.roughness.contents = dark ? 0.32 : 0.2
    }

    @MainActor func setActive(_ active: Bool) {
        let changed = motion.withLock { motion in
            defer { motion.active = active }
            return motion.active != active
        }
        // Start the clock; it stops itself once everything has settled.
        if changed && active { view?.isPlaying = true }
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let (apart, rotation, settled) = motion.withLock { motion in
            // Frame-rate independent versions of the site's per-frame easing.
            let frames = Float(min(time - (motion.lastTime ?? time - 1 / 60), 0.1) * 60)
            motion.lastTime = time
            func ease(_ rate: Float) -> Float { 1 - pow(1 - rate, frames) }

            // Coming apart is slow and deliberate; coming back is quicker.
            let target: Float = motion.active ? 1 : 0
            motion.apart += (target - motion.apart) * ease(motion.active ? 0.018 : 0.06)

            // When apart it sways on its own; together it returns to rest.
            let t = Float(time)
            let sway = SIMD2<Float>(sin(t * 0.27) * 0.18, sin(t * 0.35) * 0.45)
            let goal = Self.restRotation + sway * motion.apart
            motion.rotation += (goal - motion.rotation) * ease(0.05)

            let settled = !motion.active && motion.apart < 0.002
                && simd_length(motion.rotation - Self.restRotation) < 0.002
            if settled { motion.lastTime = nil }
            return (motion.apart, motion.rotation, settled)
        }

        apply(apart: settled ? 0 : apart, rotation: settled ? Self.restRotation : rotation, time: time)
        if settled {
            Task { @MainActor [weak self] in self?.view?.isPlaying = false }
        }
    }

    /// Places every piece for one frame.
    func apply(apart: Float, rotation: SIMD2<Float>, time: TimeInterval) {
        let t = Float(time)
        mark.eulerAngles = SCNVector3(rotation.x, rotation.y, 0)
        mark.position = SCNVector3(0, sin(t * 0.8) * 0.05 * apart, 0)
        for piece in pieces {
            let wobble = sin(t * 0.9 + piece.phase)
            let offset = piece.direction * piece.distance * apart * (1 + wobble * 0.12)
            piece.node.simdPosition = offset
            piece.node.eulerAngles = SCNVector3(
                apart * sin(t * 0.6 + piece.phase) * 0.35,
                apart * cos(t * 0.5 + piece.phase) * 0.3,
                piece.baseZ + apart * wobble * 0.08
            )
        }
    }

    /// The flat logo shape, given depth and rounded edges.
    private static func extrude(_ kind: MarkPiece.Kind, material: SCNMaterial) -> SCNShape {
        let path = NSBezierPath(cgPath: MarkPiece.unitPath(kind).cgPath)
        path.transform(using: AffineTransform(scaleByX: 1, byY: -1))  // SceneKit's y points up
        path.flatness = 0.002

        let shape = SCNShape(path: path, extrusionDepth: 0.34)
        shape.chamferMode = .both
        shape.chamferRadius = 0.06
        let profile = NSBezierPath()
        profile.move(to: NSPoint(x: 0, y: 1))
        profile.curve(to: NSPoint(x: 1, y: 0), controlPoint1: NSPoint(x: 0.55, y: 1), controlPoint2: NSPoint(x: 1, y: 0.55))
        profile.flatness = 0.01
        shape.chamferProfile = profile
        shape.materials = [material]
        return shape
    }

    /// A soft studio to reflect: bright above, dark below, two soft boxes for highlights.
    private static func studio() -> CGImage? {
        let width = 1024, height = 512
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let colors = [CGColor(gray: 0.08, alpha: 1), CGColor(gray: 0.35, alpha: 1), CGColor(gray: 0.85, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.5, 1]) {
            // CGContext's origin is bottom left, so this runs dark (floor) to bright (ceiling).
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 180, y: 330, width: 220, height: 110))
        context.fill(CGRect(x: 640, y: 300, width: 160, height: 150))
        return context.makeImage()
    }
}
