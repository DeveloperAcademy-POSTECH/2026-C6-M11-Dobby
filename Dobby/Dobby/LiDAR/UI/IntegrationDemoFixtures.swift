import Foundation

// Explicit synthetic providers for the lab. Never installed as a live model.
@MainActor
final class IntegrationDemoCamera: CaptureSnapshotProviding {
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        try Task.checkCancellation()
        var snapshot = DemoSnapshotFactory.make(.flat).snapshot
        snapshot.frame.frameID = UUID()
        snapshot.frame.capturedAt = .now
        return snapshot
    }
}

nonisolated struct IntegrationDemoLandmarks: GarmentLandmarkProviding {
    static let definitions: [MeasurementDefinition] = [
        .testDistance,
        .init(id: "half", title: "절반 구간", landmarkIDs: ["A", "M"]),
        .init(id: "missing", title: "미검출 점 처리", landmarkIDs: ["A", "missing"])
    ]
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        try Task.checkCancellation()
        var points = SyntheticFixtures.scene().landmarks
        points.sessionID = snapshot.frame.sessionID
        points.frameID = snapshot.frame.frameID
        points.origin = .synthetic
        points.modelVersion = "integration-fixture-v1"
        let a = points.points[0].point, b = points.points[1].point
        points.points.append(.init(id: "M", point: .init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), confidence: nil))
        return points
    }
}
