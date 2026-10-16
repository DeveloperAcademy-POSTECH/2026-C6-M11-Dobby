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
    var exposureRange: CameraExposureRange? = nil
    var availableZooms: [CameraZoom] = [.standard]

    static let unavailable = Self(focusSupported: false, exposureRange: nil, availableZooms: [])
}

nonisolated enum CameraFocusStatus: String, Codable, Sendable, Equatable {
    case idle, requested, accepted, unavailable, failed
}

/// Presentation facts only. `accepted` means a supported configuration request
/// succeeded; it does not certify that autofocus finished or the photo is sharp.
nonisolated struct CameraControlState: Sendable, Equatable {
    var focusPoint: ImagePoint? = nil
    var focusRequestID: UUID? = nil
    var focusStatus: CameraFocusStatus = .idle
    var exposureBias: Double = 0
    var requestedExposureBias: Double = 0
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
