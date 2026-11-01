import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech

/// The Mac permissions Case needs, and whether each one is granted.
@Observable
final class Permissions {
    nonisolated enum Kind: String, CaseIterable, Identifiable {
        case screenRecording, accessibility, microphone, speechRecognition

        var id: String { rawValue }

        var title: String {
            switch self {
            case .screenRecording: "Screen Recording"
            case .accessibility: "Accessibility"
            case .microphone: "Microphone"
            case .speechRecognition: "Speech Recognition"
            }
        }

        var reason: String {
            switch self {
            case .screenRecording: "To see your screen when you ask, and to hear meetings."
            case .accessibility: "For the hotkey, finding buttons, and clicking or typing for you."
            case .microphone: "To hear you while you hold the hotkey, and in meetings."
            case .speechRecognition: "To turn your voice into text, on your Mac."
            }
        }

        var symbol: String {
            switch self {
            case .screenRecording: "rectangle.dashed.badge.record"
            case .accessibility: "accessibility"
            case .microphone: "mic"
            case .speechRecognition: "waveform"
            }
        }

        /// The matching page in System Settings → Privacy & Security.
        var settingsURL: URL {
            let anchor = switch self {
            case .screenRecording: "Privacy_ScreenCapture"
            case .accessibility: "Privacy_Accessibility"
            case .microphone: "Privacy_Microphone"
            case .speechRecognition: "Privacy_SpeechRecognition"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    private(set) var granted: [Kind: Bool] = [:]

    var allGranted: Bool { Kind.allCases.allSatisfy { granted[$0] == true } }

    func refresh() {
        granted = [
            .screenRecording: CGPreflightScreenCaptureAccess(),
            .accessibility: AXIsProcessTrusted(),
            .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            .speechRecognition: SFSpeechRecognizer.authorizationStatus() == .authorized,
        ]
    }

    /// Shows the system prompt the first time; after that macOS won't ask again,
    /// so we open the right page in System Settings instead.
    func request(_ kind: Kind) async {
        let askedKey = "permissions.asked.\(kind.rawValue)"
        let askedBefore = UserDefaults.standard.bool(forKey: askedKey)
        UserDefaults.standard.set(true, forKey: askedKey)

        switch kind {
        case .screenRecording:
            if askedBefore {
                NSWorkspace.shared.open(kind.settingsURL)
            } else {
                CGRequestScreenCaptureAccess()
            }
        case .accessibility:
            if askedBefore {
                NSWorkspace.shared.open(kind.settingsURL)
            } else {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                NSWorkspace.shared.open(kind.settingsURL)
            }
        case .speechRecognition:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                await Self.requestSpeechAuthorization()
            } else {
                NSWorkspace.shared.open(kind.settingsURL)
            }
        }
        refresh()
    }

    /// Runs off the main actor: the callback arrives on a background queue.
    @concurrent
    @discardableResult
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
