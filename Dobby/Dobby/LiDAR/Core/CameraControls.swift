import Foundation

nonisolated enum CameraZoom: Double, Codable, Sendable, CaseIterable, Identifiable {
    case ultraWide = 0.5
    case standard = 1
    case double = 2

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .ultraWide: "0.5×"
        case .standard: "1×"
        case .double: "2×"
        }
    }
}

/// The adapter supplies the current camera's limits. A valid range is not a
/// claim that the hardware has accepted any particular exposure request.
nonisolated struct CameraExposureRange: Codable, Sendable, Equatable {
    let minimum: Double
    let maximum: Double

    init?(minimum: Double, maximum: Double) {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum else { return nil }
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Shared by measurement and detail capture, including menu and preview
    /// controls. Never advertise a bias outside either the device or ±2 EV.
    static func captureRange(minimum: Double, maximum: Double) -> Self? {
        guard let deviceRange = Self(minimum: minimum, maximum: maximum) else { return nil }
        return Self(minimum: max(-2, deviceRange.minimum), maximum: min(2, deviceRange.maximum))
    }

    func clamp(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(maximum, max(minimum, value))
    }

    private enum CodingKeys: String, CodingKey { case minimum, maximum }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let minimum = try values.decode(Double.self, forKey: .minimum)
        let maximum = try values.decode(Double.self, forKey: .maximum)
        guard let range = Self(minimum: minimum, maximum: maximum) else {
            throw DecodingError.dataCorruptedError(forKey: .maximum, in: values,
                debugDescription: "Exposure limits must be finite and ordered.")
        }
        self = range
    }
}

/// Supported controls come from the actual running capture device. In
/// particular, an enum case does not establish an available camera/lens.
nonisolated struct CameraControlCapabilities: Sendable, Equatable {
    var focusSupported = false
    var meteringSupported = false
    var aeafLockSupported = false
    var exposureRange: CameraExposureRange? = nil
    var availableZooms: [CameraZoom] = [.standard]

    static let unavailable = Self(focusSupported: false, exposureRange: nil, availableZooms: [])

    var pointAdjustmentSupported: Bool { focusSupported || meteringSupported }
}

nonisolated enum CameraFocusStatus: String, Codable, Sendable, Equatable {
    case idle, requested, accepted, unavailable, failed
}

nonisolated enum CameraAEAFStatus: String, Codable, Sendable, Equatable {
    case unlocked, locking, locked, failed
}

nonisolated enum CameraObservedFocusMode: String, Codable, Sendable, Equatable {
    case continuous, single, locked, unavailable
}

nonisolated enum CameraObservedExposureMode: String, Codable, Sendable, Equatable {
    case continuous, single, locked, custom, unavailable
}

/// This observation is read from the configured device, independently of the
/// copied ARFrame. Its uptime is not an ARFrame timestamp or a sharpness test.
nonisolated struct CameraHardwareObservation: Codable, Sendable, Equatable {
    var observedAtUptime: Double
    var focusMode: CameraObservedFocusMode
    var exposureMode: CameraObservedExposureMode
    var isAdjustingFocus: Bool
    var isAdjustingExposure: Bool
    var lensPosition: Double?
    var exposureDurationSeconds: Double?
    var iso: Double?
    var exposureTargetBias: Double?

    var hasObservedAEAFLock: Bool {
        focusMode == .locked && exposureMode == .locked && !isAdjustingFocus && !isAdjustingExposure
    }
}

/// A translation from an on-screen drag, independent of preview zoom or sensor
/// orientation. Moving up brightens. Cap sensitivity at four EV per visible
/// preview height so wide-range devices do not turn a small drag into a huge
/// brightness jump. Repeated drags remain within the supplied control range.
nonisolated enum CameraExposureGesture {
    static func bias(start: Double, translationY: Double, viewportHeight: Double,
                     range: CameraExposureRange) -> Double? {
        guard start.isFinite, translationY.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        let gestureSpan = min(4, range.maximum - range.minimum)
        return range.clamp(start - translationY / max(120, viewportHeight) * gestureSpan)
    }
}

/// Presentation facts only. `accepted` means a supported configuration request
/// succeeded; it does not certify that autofocus finished or the photo is sharp.
nonisolated struct CameraControlState: Sendable, Equatable {
    var focusPoint: ImagePoint? = nil
    var focusRequestID: UUID? = nil
    var focusStatus: CameraFocusStatus = .idle
    var aeafStatus: CameraAEAFStatus = .unlocked
    var hardwareObservation: CameraHardwareObservation? = nil
    var exposureBias: Double = 0
    var requestedExposureBias: Double = 0
    /// Also changes when a failed request returns to the same published EV.
    var requestedExposureRevision: UInt64 = 0
    var selectedZoom: CameraZoom = .standard
    var settingsRevision: UInt64 = 0
    var sessionID: UUID? = nil
}

/// Completion receipts must match both the live session and the latest request.
/// A stale completion cannot update a restarted or more recently adjusted camera.
nonisolated struct CameraControlRequest: Sendable, Equatable {
    let sessionID: UUID
    let requestID: UUID
    let revision: UInt64

    func matches(sessionID: UUID?, requestID: UUID?, revision: UInt64) -> Bool {
        guard let sessionID, let requestID else { return false }
        return self.sessionID == sessionID && self.requestID == requestID && self.revision == revision
    }
}
