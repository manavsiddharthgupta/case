import AppKit
import SwiftUI

/// One of the Case mark's three pieces, measured from the makemvp logo.
nonisolated struct MarkPiece: Shape {
    nonisolated enum Kind: CaseIterable {
        case band, topLeft, bottomRight
    }

    let kind: Kind

    /// The logo's shapes, in units on a 744-wide square centred on the origin (y down).
    private static let extent: CGFloat = 744
    private static let radius: CGFloat = 130

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / Self.extent
        return Self.basePath(kind).applying(
            CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: unit, y: unit)
        )
    }

    /// The piece in a square from -1 to 1 (y down), the units the 3D sculpture uses.
    static func unitPath(_ kind: Kind) -> Path {
        let unit = 2 / extent
        return basePath(kind).applying(CGAffineTransform(scaleX: unit, y: unit))
    }

    private static func basePath(_ kind: Kind) -> Path {
        switch kind {
        case .band:
            // Rounded ends 665 apart, running bottom-left to top-right.
            let length: CGFloat = 665 + 2 * radius
            let capsule = CGRect(x: -length / 2, y: -radius, width: length, height: 2 * radius)
            return Path(roundedRect: capsule, cornerRadius: radius).applying(CGAffineTransform(rotationAngle: -.pi / 4))
        case .topLeft:
            return cornerPath()
        case .bottomRight:
            return cornerPath().applying(CGAffineTransform(rotationAngle: .pi))
        }
    }

    /// A tall piece with a round top, cut along a line parallel to the band.
    private static func cornerPath() -> Path {
        let left: CGFloat = -372
        let right = left + 2 * radius
        let archY = left + radius
        let cut: CGFloat = -327  // the cut line is x + y = cut
        let joint = CGPoint(x: right, y: cut - right)
        let tip = CGPoint(x: left, y: cut - left)

        var path = Path()
        path.move(to: CGPoint(x: left, y: archY))
        path.addArc(center: CGPoint(x: left + radius, y: archY), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        // Rounded a little more than the bevel, so the 3D edges stay clean.
        path.addArc(tangent1End: joint, tangent2End: tip, radius: 26)
        path.addArc(tangent1End: tip, tangent2End: CGPoint(x: left, y: archY), radius: 26)
        path.closeSubpath()
        return path
    }
}

/// The flat mark, for places that can't animate.
struct MarkGlyph: View {
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        ZStack {
            ForEach(MarkPiece.Kind.allCases, id: \.self) { MarkPiece(kind: $0).fill(color) }
        }
        .frame(width: size, height: size)
    }
}

extension NSImage {
    /// The mark as a template image for the menu bar, so macOS tints it for light and dark.
    static let menuBarMark: NSImage = {
        let renderer = ImageRenderer(content: MarkGlyph(size: 16, color: .black))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }()
}
