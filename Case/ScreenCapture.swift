import AppKit
import ScreenCaptureKit

/// Takes the screenshot that goes along with each question.
enum ScreenCapture {
    nonisolated struct Shot: Sendable {
        let jpeg: Data
        let screen: ScreenGeometry
        var pixelSize: CGSize { screen.pixelSize }
        var cursor: CGPoint { screen.cursor }
    }

    /// The screen under the mouse, and how to convert between its coordinate systems:
    /// AppKit (origin bottom left), accessibility (origin top left of the main display),
    /// and screenshot pixels (origin top left of this screen).
    nonisolated struct ScreenGeometry: Sendable {
        let displayID: CGDirectDisplayID
        /// AppKit coordinates.
        let frame: CGRect
        let scale: CGFloat
        let mainDisplayHeight: CGFloat
        /// Where the mouse is, in screenshot pixels.
        let cursor: CGPoint

        var pixelSize: CGSize {
            CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
        }

        /// This screen in accessibility coordinates.
        var topLeftFrame: CGRect {
            CGRect(x: frame.minX, y: mainDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
        }

        func pixel(fromTopLeft point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - frame.minX) * scale, y: (point.y - topLeftFrame.minY) * scale)
        }

        func pixel(fromAppKit point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - frame.minX) * scale, y: (frame.maxY - point.y) * scale)
        }

        func topLeftPoint(fromPixel pixel: CGPoint) -> CGPoint {
            CGPoint(x: frame.minX + pixel.x / scale, y: topLeftFrame.minY + pixel.y / scale)
        }

        func appKitPoint(fromPixel pixel: CGPoint) -> CGPoint {
            CGPoint(x: frame.minX + pixel.x / scale, y: frame.maxY - pixel.y / scale)
        }

        func topLeftRect(fromPixel rect: CGRect) -> CGRect {
            CGRect(origin: topLeftPoint(fromPixel: rect.origin), size: CGSize(width: rect.width / scale, height: rect.height / scale))
        }

        func appKitRect(fromTopLeft rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noDisplay: "Couldn't find the screen under your mouse."
            case .encodingFailed: "Couldn't prepare the screenshot."
            }
        }
    }

    /// The screen under the mouse. Smaller screenshots reach Claude faster, so the longest side
    /// is shrunk to at most `maxSide` pixels.
    static func screenUnderCursor(maxSide: CGFloat = 1280) throws -> ScreenGeometry {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw CaptureError.noDisplay }

        let frame = screen.frame
        let scale = min(1, maxSide / max(frame.width, frame.height))
        return ScreenGeometry(
            displayID: displayID,
            frame: frame,
            scale: scale,
            mainDisplayHeight: NSScreen.screens.first?.frame.maxY ?? frame.maxY,
            cursor: CGPoint(x: (mouse.x - frame.minX) * scale, y: (frame.maxY - mouse.y) * scale)
        )
    }

    /// Captures that screen without Case's own windows.
    static func capture(_ screen: ScreenGeometry) async throws -> Shot {
        Shot(jpeg: try await capture(displayID: screen.displayID, pixelSize: screen.pixelSize), screen: screen)
    }

    @concurrent
    private nonisolated static func capture(displayID: CGDirectDisplayID, pixelSize: CGSize) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.processID == ownPID },
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.showsCursor = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw CaptureError.encodingFailed }
        return jpeg
    }
}
