import SwiftUI
import UIKit
import Combine

@MainActor
final class MeasurementSessionModel: ObservableObject, Identifiable {
    let id = UUID()
    let snapshot: CaptureSnapshot
    let image: UIImage?
    @Published var landmarks: GarmentLandmarkSet
    @Published var definition: MeasurementDefinition
    @Published var result: GarmentMeasurementResult?
    @Published var referenceText = ""
    @Published var testContext: MeasurementTestContext
    @Published var activePointIndex = 0
    @Published var useLocalPlane = true
    @Published var isCalculating = false
    @Published var isSaving = false
    @Published var exportedURL: URL?
    @Published var errorMessage: String?
    let expectedMeters: Double?
    private let pipeline = MeasurementPipeline()
    private let baseOptions: MeasurementOptions
    private var calculationTask: Task<Void, Never>?
    private var revision = 0

    init(snapshot: CaptureSnapshot, landmarks: GarmentLandmarkSet? = nil,
         definition: MeasurementDefinition = .testDistance, expectedMeters: Double? = nil,
         referenceCentimeters: Double? = nil, options: MeasurementOptions = .init(),
         testContext: MeasurementTestContext? = nil) {
        self.snapshot = snapshot
        self.testContext = testContext ?? .init(deviceModel: Self.deviceIdentifier)
        self.image = Self.orientedImage(snapshot)
        self.definition = definition
        self.expectedMeters = expectedMeters
        self.baseOptions = options
        self.useLocalPlane = options.useLocalPlane
        self.landmarks = landmarks ?? .init(sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
            origin: .manual, modelVersion: nil,
            points: [
                .init(id: definition.landmarkIDs[0], point: .init(x: 0.3, y: 0.5), confidence: nil, isVisible: false),
                .init(id: definition.landmarkIDs[1], point: .init(x: 0.7, y: 0.5), confidence: nil, isVisible: false)
            ], mask: nil)
        if let value = referenceCentimeters ?? expectedMeters.map({ $0 * 100 }) {
            referenceText = String(format: "%.2f", value)
        }
    }

    private static var deviceIdentifier: String {
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "Simulator: " + model }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    var availableDefinitions: [MeasurementDefinition] {
        let definitions = testContext.category.definitions
        // Preserve an imported custom definition instead of silently relabelling its points.
        return definitions.contains(where: { $0.id == definition.id }) ? definitions : [definition] + definitions
    }

    func selectCategory(_ category: GarmentCategory) {
        testContext.category = category
        exportedURL = nil
        if !category.definitions.contains(where: { $0.id == definition.id }), let first = category.definitions.first {
            selectDefinition(first)
        }
    }

    private static func orientedImage(_ snapshot: CaptureSnapshot) -> UIImage? {
        guard let base = UIImage(data: snapshot.imageJPEG), let cg = base.cgImage else { return nil }
        let orientation: UIImage.Orientation
        switch snapshot.frame.orientation {
        case .up: orientation = .up
        case .right: orientation = .right
        case .down: orientation = .down
        case .left: orientation = .left
        }
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    var displayedAspectRatio: CGFloat {
        let size = snapshot.frame.imageSize
        let rotated = snapshot.frame.orientation == .right || snapshot.frame.orientation == .left
        return rotated ? CGFloat(size.height) / CGFloat(size.width) : CGFloat(size.width) / CGFloat(size.height)
    }

    var referenceCentimeters: Double? {
        guard let value = Double(referenceText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else { return nil }
        return value
    }

    func selectDefinition(_ newValue: MeasurementDefinition) {
        if definition.id != newValue.id { referenceText = "" }
        definition = newValue
        landmarks.origin = .manual
        landmarks.modelVersion = nil
        landmarks.points = newValue.landmarkIDs.enumerated().map { index, id in
            .init(id: id, point: .init(x: index == 0 ? 0.3 : 0.7, y: 0.5), confidence: nil, isVisible: false)
        }
        activePointIndex = 0
        recalculate()
    }

    func placePoint(displayPoint: ImagePoint, index: Int) {
        guard landmarks.points.indices.contains(index),
              displayPoint.x.isFinite, displayPoint.y.isFinite else { return }
        let original = ImageCoordinateTransform.displayToOriginal(displayPoint, orientation: snapshot.frame.orientation)
        let clamped = ImagePoint(x: min(0.999999, max(0, original.x)), y: min(0.999999, max(0, original.y)))
        guard landmarks.placeManualLandmark(at: index, point: clamped) else { return }
        if let next = landmarks.points.firstIndex(where: { !$0.isVisible }) { activePointIndex = next }
        recalculate()
    }

    func recalculate() {
        calculationTask?.cancel()
        revision += 1
        let token = revision
        result = nil
        exportedURL = nil
        isCalculating = true
        let snapshot = snapshot, points = landmarks, definition = definition
        var options = baseOptions
        options.useLocalPlane = useLocalPlane
        calculationTask = Task { [weak self, pipeline] in
            // Bound calculations while dragging; only the latest revision reaches the UI.
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            let output = await pipeline.measure(snapshot: snapshot, landmarks: points, definitions: [definition], options: options)
            guard !Task.isCancelled, let self, revision == token else { return }
            result = output
            isCalculating = false
        }
    }

    func save(to archive: MeasurementArchive) async {
        guard !isSaving, !isCalculating, let result else { return }
        guard referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || referenceCentimeters != nil else {
            errorMessage = "줄자 기준값은 0보다 큰 숫자로 입력하거나 비워 주세요."
            return
        }
        isSaving = true
        let savedRevision = revision
        let savedReferenceText = referenceText
        let savedContext = testContext
        defer { isSaving = false }
        do {
            let record = SavedMeasurement(id: UUID(), savedAt: .now, snapshot: snapshot, landmarks: landmarks,
                definitions: [definition], result: result, referenceCentimeters: referenceCentimeters,
                options: { var options = baseOptions; options.useLocalPlane = useLocalPlane; return options }(),
                testContext: savedContext)
            let url = try await archive.save(record)
            if revision == savedRevision, referenceText == savedReferenceText, testContext == savedContext { exportedURL = url }
        } catch { errorMessage = error.localizedDescription }
    }
}
