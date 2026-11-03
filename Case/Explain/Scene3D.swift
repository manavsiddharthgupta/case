import AppKit
import SceneKit

/// A simple 3D picture Claude describes to explain something: shapes placed in space, and labels
/// that point at them. Units are roughly metres, y points up, and the ground is at y = 0.
nonisolated struct Scene3D: Decodable, Sendable {
    nonisolated struct Part: Decodable, Sendable {
        var id: String
        /// box, sphere, cylinder, cone, capsule, torus or pyramid.
        var shape: String
        /// Width, height and depth. Round shapes use the first as their width.
        var size: [Double]
        var position: [Double]?
        /// Degrees around x, y and z.
        var rotation: [Double]?
        /// A colour name like "grey" or "wood", or a hex code like "#3366FF".
        var color: String?
    }

    nonisolated struct Label: Decodable, Sendable {
        var text: String
        /// The part it points at.
        var part: String
    }

    var title: String?
    var parts: [Part]
    var labels: [Label]?

    static let maxParts = 40
    static let maxLabels = 10

    /// Reads what Claude sent. Nil when it isn't a scene that can be drawn.
    static func decode(_ arguments: [String: Any]) -> Scene3D? {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              var scene = try? JSONDecoder().decode(Scene3D.self, from: data),
              !scene.parts.isEmpty else { return nil }
        scene.parts = Array(scene.parts.prefix(maxParts))
        let ids = Set(scene.parts.map(\.id))
        scene.labels = Array((scene.labels ?? []).filter { ids.contains($0.part) }.prefix(maxLabels))
        return scene
    }
}

/// Builds the SceneKit scene for a `Scene3D`: the parts on a turntable, soft studio light and a shadow.
@MainActor
final class SceneBuilder {
    let scene = SCNScene()
    /// Everything that turns.
    let turntable = SCNNode()
    let camera = SCNNode()
    /// Where each label points, by part id.
    private(set) var anchors: [String: SCNNode] = [:]

    init(_ description: Scene3D) {
        for part in description.parts {
            let node = SCNNode(geometry: Self.geometry(for: part))
            let position = part.position ?? []
            node.position = SCNVector3(Self.value(position, 0), Self.value(position, 1), Self.value(position, 2))
            let rotation = (part.rotation ?? []).map { $0 * .pi / 180 }
            node.eulerAngles = SCNVector3(Self.value(rotation, 0), Self.value(rotation, 1), Self.value(rotation, 2))
            turntable.addChildNode(node)
            anchors[part.id] = node
        }

        // Centre what was drawn, sitting on its floor, so any coordinates Claude picked look right.
        let (low, high) = turntable.boundingBox
        let centre = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
        turntable.pivot = SCNMatrix4MakeTranslation(centre.x, centre.y, centre.z)
        scene.rootNode.addChildNode(turntable)
        turntable.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 40)))

        let radius = max(Float(max(high.x - low.x, high.y - low.y, high.z - low.z)) * 0.5, 0.1)
        addLights(radius: radius, floor: Float(low.y - centre.y))

        // Looking down a little from the front, far enough back that the whole thing fits while it turns.
        let fov: CGFloat = 32
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = fov
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = Double(radius) * 40
        let distance = radius * 1.1 / Float(tan(fov / 2 * .pi / 180))
        camera.position = SCNVector3(0, distance * 0.42, distance)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
    }

    private func addLights(radius: Float, floor: Float) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 8
        key.light?.shadowSampleCount = 16
        key.light?.shadowColor = NSColor(white: 0, alpha: 0.35)
        key.position = SCNVector3(radius * 2, radius * 4, radius * 3)
        key.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(key)

        // An invisible floor that only catches the shadow.
        let floorNode = SCNNode(geometry: SCNFloor())
        floorNode.geometry?.firstMaterial?.colorBufferWriteMask = []
        floorNode.geometry?.firstMaterial?.lightingModel = .shadowOnly
        (floorNode.geometry as? SCNFloor)?.reflectivity = 0
        floorNode.position = SCNVector3(0, floor, 0)
        scene.rootNode.addChildNode(floorNode)
    }

    private static func geometry(for part: Scene3D.Part) -> SCNGeometry {
        let width = CGFloat(clamped(value(part.size, 0, or: 1)))
        let height = CGFloat(clamped(value(part.size, 1, or: Double(width))))
        let depth = CGFloat(clamped(value(part.size, 2, or: Double(width))))
        let geometry: SCNGeometry = switch part.shape.lowercased() {
        case "sphere": SCNSphere(radius: width / 2)
        case "cylinder": SCNCylinder(radius: width / 2, height: height)
        case "cone": SCNCone(topRadius: part.size.count > 2 ? depth / 2 : 0, bottomRadius: width / 2, height: height)
        case "capsule": SCNCapsule(capRadius: width / 2, height: max(height, width))
        case "torus": SCNTorus(ringRadius: width / 2, pipeRadius: max(min(height, width) / 2, 0.005))
        case "pyramid": SCNPyramid(width: width, height: height, length: depth)
        default: SCNBox(width: width, height: height, length: depth, chamferRadius: min(width, height, depth) * 0.04)
        }
        geometry.materials = [material(part.color)]
        return geometry
    }

    private static func material(_ name: String?) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.55
        material.metalness.contents = 0
        let key = (name ?? "grey").lowercased().trimmingCharacters(in: .whitespaces)
        switch key {
        case "metal", "steel", "silver":
            material.metalness.contents = 0.9
            material.roughness.contents = 0.3
        case "glass":
            material.transparency = 0.35
            material.roughness.contents = 0.05
        default: break
        }
        material.diffuse.contents = color(key)
        return material
    }

    private static func color(_ name: String) -> NSColor {
        if name.hasPrefix("#"), name.count == 7, let hex = UInt32(name.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let named: [String: UInt32] = [
            "white": 0xF2F2F0, "black": 0x1C1C1E, "grey": 0x9A9A9E, "gray": 0x9A9A9E, "dark grey": 0x4A4A4E, "dark gray": 0x4A4A4E,
            "light grey": 0xC8C8CC, "light gray": 0xC8C8CC, "red": 0xD9483B, "orange": 0xE8893A, "yellow": 0xF0C43C,
            "green": 0x4FA86B, "blue": 0x3D7BE0, "purple": 0x8B5FD0, "pink": 0xE87AA6, "brown": 0x8A5A3C, "wood": 0xB07F52,
            "skin": 0xE0B48E, "metal": 0xB8BCC2, "steel": 0xB8BCC2, "silver": 0xC9CCD1, "gold": 0xD4AF37, "glass": 0xBFD9F2,
        ]
        return color("#" + String(format: "%06X", named[name] ?? 0x9A9A9E))
    }

    private static func value(_ list: [Double], _ index: Int, or fallback: Double = 0) -> Float {
        Float(list.indices.contains(index) ? list[index] : fallback)
    }

    private static func clamped(_ size: Float) -> Float {
        min(max(size.isFinite ? size : 1, 0.01), 100)
    }
}
