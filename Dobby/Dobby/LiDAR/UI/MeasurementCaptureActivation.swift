import AVFoundation
import SwiftUI

/// A home pull may prepare the real capture flow before navigation commits.
/// Only the committed flow may ask for a new system camera permission.
nonisolated enum MeasurementCaptureActivation: Equatable, Sendable {
    case previewIfAuthorized
    case active

    func permitsCameraStartup(authorization: AVAuthorizationStatus) -> Bool {
        self == .active || authorization == .authorized
    }
}

extension EnvironmentValues {
    @Entry var measurementCaptureActivation: MeasurementCaptureActivation = .active
    @Entry var measurementCaptureChromeOpacity: Double = 1
    @Entry var measurementCaptureCover: MeasurementCaptureCover? = nil
}

/// The native progress bar shares the round Home cover's window coordinates,
/// so it stays covered without painting through the moving reel.
nonisolated struct MeasurementCaptureCover: Equatable, Sendable {
    let center: CGPoint
    let diameter: CGFloat
    let revealOpacity: Double
}

/// An inline home capture reports its visible screen's scheme to the window
/// owner, while ordinary full-screen flows retain their own presentation style.
nonisolated struct MeasurementCaptureColorSchemePreferenceKey: PreferenceKey {
    static var defaultValue: ColorScheme? { nil }

    static func reduce(value: inout ColorScheme?, nextValue: () -> ColorScheme?) {
        if let next = nextValue() { value = next }
    }
}
