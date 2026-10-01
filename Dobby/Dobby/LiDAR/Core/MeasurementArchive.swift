import Foundation

nonisolated struct SavedMeasurement: Codable, Sendable, Identifiable {
    var id: UUID
    var savedAt: Date
    var snapshot: CaptureSnapshot
    var landmarks: GarmentLandmarkSet
    var definitions: [MeasurementDefinition]
    var result: GarmentMeasurementResult
    var referenceCentimeters: Double?
    var options: MeasurementOptions
    var schemaVersion = 1
    var testContext: MeasurementTestContext? = nil
    /// Per-item tape references for multi-item automatic validation. The legacy
    /// scalar remains supported only for records with a single definition.
    var referenceByDefinitionCentimeters: [String: Double]? = nil
}

nonisolated struct MeasurementSummary: Codable, Sendable, Identifiable {
    var id: UUID
    var savedAt: Date
    var source: DepthSource
    var title: String
    var centimeters: Double?
    var status: MeasurementStatus
}

actor MeasurementArchive {
    private let folder: URL
    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiDARMeasurements", isDirectory: true)
    }

    func save(_ record: SavedMeasurement) throws -> URL {
        let directory = folder.appendingPathComponent(record.id.uuidString, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let recordData = try encoder.encode(record)
        let first = record.result.values.first
        let summary = MeasurementSummary(id: record.id, savedAt: record.savedAt,
            source: record.snapshot.frame.source, title: first?.title ?? "측정",
            centimeters: first?.meters.map { $0 * 100 }, status: first?.status ?? .unavailable)
        let summaryData = try encoder.encode(summary)
        // Saved IDs are immutable. Edits receive a new ID in the session model;
        // never overwrite a previous record or expose a half-written new one.
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ArchiveError.existingRecord }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try recordData.write(to: staging.appendingPathComponent("measurement.json"), options: .atomic)
        try summaryData.write(to: staging.appendingPathComponent("summary.json"), options: .atomic)
        // A same-volume directory rename publishes both files together.
        try FileManager.default.moveItem(at: staging, to: directory)
        return directory.appendingPathComponent("measurement.json")
    }

    func summaries() throws -> [MeasurementSummary] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .compactMap { directory in
                guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
                // Interrupted writes without a summary never appear as completed records.
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("summary.json")) else { return nil }
                guard let summary = try? JSONDecoder().decode(MeasurementSummary.self, from: data),
                      summary.id.uuidString == directory.lastPathComponent else { return nil }
                return summary
            }.sorted { $0.savedAt > $1.savedAt }
    }

    func baselineReport() throws -> BaselineReport {
        var builder = BaselineReportBuilder()
        guard FileManager.default.fileExists(atPath: folder.path) else { return builder.report() }
        let directories = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent("measurement.json")
            do {
                let summary = try JSONDecoder().decode(MeasurementSummary.self,
                    from: Data(contentsOf: directory.appendingPathComponent("summary.json")))
                let record = try Self.decode(from: url)
                guard record.id == summary.id, record.id.uuidString == directory.lastPathComponent,
                      record.savedAt == summary.savedAt else { throw ArchiveError.invalidFile }
                builder.add(record)
            }
            catch { builder.addUnreadableRecord() }
        }
        return builder.report()
    }

    func validationReport() throws -> MeasurementValidationReport {
        var builder = MeasurementValidationReportBuilder()
        guard FileManager.default.fileExists(atPath: folder.path) else { return builder.report() }
        let directories = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            try Task.checkCancellation()
            do {
                let summary = try JSONDecoder().decode(MeasurementSummary.self,
                    from: Data(contentsOf: directory.appendingPathComponent("summary.json")))
                let record = try Self.decode(from: directory.appendingPathComponent("measurement.json"))
                guard record.id == summary.id, record.id.uuidString == directory.lastPathComponent,
                      record.savedAt == summary.savedAt else { throw ArchiveError.invalidFile }
                builder.add(record)
            } catch { builder.addUnreadableRecord() }
        }
        return builder.report()
    }

    func exportValidation(_ report: MeasurementValidationReport, markdown: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DobbyValidationExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("lidar-validation-\(UUID().uuidString)." + (markdown ? "md" : "csv"))
        try (markdown ? report.markdown : report.csv).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func exportBaselineCSV(_ report: BaselineReport) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DobbyBaselineExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("lidar-baseline-\(UUID().uuidString).csv")
        try report.csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func load(_ id: UUID) throws -> SavedMeasurement {
        let url = folder.appendingPathComponent(id.uuidString).appendingPathComponent("measurement.json")
        return try Self.decode(from: url)
    }

    func importRecord(from url: URL) throws -> SavedMeasurement {
        try Self.decode(from: url)
    }

    private static func decode(from url: URL) throws -> SavedMeasurement {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < 50_000_000 else { throw ArchiveError.invalidFile }
        let record = try JSONDecoder().decode(SavedMeasurement.self, from: Data(contentsOf: url))
        guard record.schemaVersion == 1,
              record.snapshot.imageJPEG.count < 20_000_000,
              record.snapshot.frame.imageSize.isValid,
              record.landmarks.points.count <= 200,
              record.definitions.count <= 100 else { throw ArchiveError.invalidFile }
        return record
    }
}

nonisolated enum ArchiveError: LocalizedError {
    case invalidFile
    case existingRecord
    var errorDescription: String? {
        switch self {
        case .invalidFile: "지원하는 측정 기록 파일이 아닙니다. 50MB 이하의 버전 1 JSON 파일을 선택하세요."
        case .existingRecord: "같은 ID의 기록이 이미 있습니다. 기존 기록을 보존했습니다. 새 테스트 기록으로 저장해 주세요."
        }
    }
}

/// Camera and ML adapters converge here; the engine never starts a camera session.
actor MeasurementPipeline {
    /// Keep model work on the pipeline executor, never the camera/UI actor.
    /// The workflow applies the identity check before exposing model points.
    func detectLandmarks(snapshot: CaptureSnapshot, provider: any GarmentLandmarkProviding) async throws -> GarmentLandmarkSet {
        try Task.checkCancellation()
        let landmarks = try await provider.landmarks(for: snapshot)
        try Task.checkCancellation()
        return landmarks
    }

    func measure(snapshot: CaptureSnapshot, landmarks: GarmentLandmarkSet,
                 definitions: [MeasurementDefinition], options: MeasurementOptions) -> GarmentMeasurementResult {
        LiDARMeasurementEngine(options: options).measure(frame: snapshot.frame, landmarks: landmarks, definitions: definitions)
    }

    func measure(snapshot: CaptureSnapshot, provider: any GarmentLandmarkProviding,
                 definitions: [MeasurementDefinition], options: MeasurementOptions = .init()) async throws -> GarmentMeasurementResult {
        let landmarks = try await detectLandmarks(snapshot: snapshot, provider: provider)
        return LiDARMeasurementEngine(options: options).measure(frame: snapshot.frame, landmarks: landmarks, definitions: definitions)
    }
}
