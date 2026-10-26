import Foundation
import ImageIO
import SwiftData

extension GarmentStore {
    /// The confirmed archive remains the physical evidence. This adapter copies its
    /// current centimetres into the product; it never derives a pixel/cm scale,
    /// invokes a model, or recalculates a measurement.
    @MainActor
    @discardableResult
    static func importMeasurement(_ record: SavedMeasurement, in context: ModelContext,
                                  photosDirectory directory: URL? = nil,
                                  allowsSynthetic: Bool = false,
                                  allowsUnavailableDraft: Bool = false,
                                  save: (ModelContext) throws -> Void = { try $0.save() }) throws -> Garment {
        let kind = try validateProductMeasurement(record, allowsSynthetic: allowsSynthetic,
            allowsUnavailableDraft: allowsUnavailableDraft)
        let identifier = record.id
        let query = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == identifier })
        if let existing = try context.fetch(query).first {
            guard existing.sourceMeasurementID == record.id else {
                throw MeasurementImportError.identifierConflict
            }
            return existing
        }

        // A dedicated context keeps another screen's unsaved edits out of this
        // transaction and makes rollback local to the newly imported graph.
        let insertionContext = ModelContext(context.container)
        insertionContext.autosaveEnabled = false
        if let existing = try insertionContext.fetch(query).first {
            guard existing.sourceMeasurementID == record.id else {
                throw MeasurementImportError.identifierConflict
            }
            guard let callerModel = try context.fetch(query).first else {
                throw MeasurementImportError.contextUnavailable
            }
            return callerModel
        }
        let photoData = try orientedMeasurementJPEG(record.snapshot)
        let folder = directory ?? photosDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = "\(record.id.uuidString)-\(UUID().uuidString).jpg"
        let fileURL = folder.appendingPathComponent(fileName)
        try writeMeasurementPhoto(photoData, to: fileURL)
        var didSave = false
        defer {
            if !didSave {
                insertionContext.rollback()
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        let garment = Garment(category: kind == .top ? "상의" : "바지",
                              group: kind == .top ? .top : .pants)
        garment.id = record.id
        garment.sourceMeasurementID = record.id
        garment.createdAt = record.savedAt
        insertionContext.insert(garment)
        let originalResult = record.originalAutomaticResult ?? record.result
        for (index, definition) in record.definitions.enumerated() {
            let value = record.result.values[index]
            let usableMeters = value.status == .unavailable ? nil : value.meters.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            }
            // Both bottom7 and bottom8 failures keep the same editable rise cell.
            guard usableMeters != nil || GarmentMeasurementPresentation.isVisibleMeasurementID(definition.id, kind: kind) else { continue }
            // Validation guarantees all definition IDs have an explicit bridge key.
            guard let key = productMeasurementKeys[definition.id] else {
                throw MeasurementImportError.invalidRecord
            }
            let original = originalResult.values[index]
            let originalCm = original.status == .unavailable ? nil : original.meters.flatMap {
                $0.isFinite && $0 > 0 ? $0 * 100 : nil
            }
            let measured = MeasuredValue(key: key, label: value.title, displayOrder: index,
                                         valueCm: usableMeters.map { $0 * 100 } ?? 0, autoValueCm: originalCm)
            measured.sourceStatusRaw = value.status.rawValue
            measured.garment = garment
            insertionContext.insert(measured)
            if !garment.measurements.contains(where: { $0.id == measured.id }) {
                garment.measurements.append(measured)
            }
        }

        let photo = GarmentPhoto(fileName: fileName, role: .thumbnail, order: 0,
                                 isMeasurementSource: true)
        photo.garment = garment
        photo.capturedAt = record.snapshot.frame.capturedAt
        photo.imageWidth = record.snapshot.frame.imageSize.width
        photo.imageHeight = record.snapshot.frame.imageSize.height
        photo.measurementRecordID = record.id
        photo.measurementSessionID = record.snapshot.frame.sessionID
        photo.measurementFrameID = record.snapshot.frame.frameID
        photo.measurementOrientationRaw = record.snapshot.frame.orientation.rawValue
        photo.measurementModelVersion = record.landmarks.modelVersion
        photo.measurementAlgorithmVersion = record.result.algorithmVersion
        photo.measurementDepthSourceRaw = record.snapshot.frame.source.rawValue
        photo.measurementLandmarkOriginRaw = record.landmarks.origin.rawValue
        photo.isSelectedForProduct = true
        // These remain nil: a detection probability and a universal pixel/cm
        // conversion cannot be recovered from the validated LiDAR result.
        photo.garmentScore = nil
        photo.pixelsPerCm = nil
        insertionContext.insert(photo)
        if !garment.photos.contains(where: { $0.id == photo.id }) {
            garment.photos.append(photo)
        }

        for (index, rawCurrent) in record.landmarks.points.enumerated() {
            let point = productLandmark(rawCurrent, index: index, record: record)
            point.photo = photo
            insertionContext.insert(point)
            if !photo.landmarks.contains(where: { $0.id == point.id }) {
                photo.landmarks.append(point)
            }
        }
        garment.syncFilterFields()
        try save(insertionContext)
        didSave = true
        // All subsequent photo and information edits must use the caller's
        // context. Never silently return a model owned by insertionContext.
        guard let callerModel = try context.fetch(query).first else {
            throw MeasurementImportError.contextUnavailable
        }
        return callerModel
    }

    /// A result correction belongs to the same frozen capture and product.
    /// Keep product/photo/measurement IDs so text drafts and selected photos
    /// still reference the same objects after the corrected archive is saved.
    @MainActor
    static func refreshMeasurement(_ record: SavedMeasurement, for garment: Garment,
                                   in context: ModelContext, allowsSynthetic: Bool = false,
                                   allowsUnavailableDraft: Bool = false,
                                   save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        let kind = try validateProductMeasurement(record, allowsSynthetic: allowsSynthetic,
            allowsUnavailableDraft: allowsUnavailableDraft)
        guard garment.modelContext === context, garment.informationCompletedAt == nil, garment.sourceMeasurementID != nil,
              garment.group == (kind == .top ? .top : .pants),
              let photo = garment.measurementPhoto,
              photo.measurementSessionID == record.snapshot.frame.sessionID,
              photo.measurementFrameID == record.snapshot.frame.frameID else {
            throw MeasurementImportError.invalidRecord
        }
        _ = try orientedMeasurementJPEG(record.snapshot)
        let originalResult = record.originalAutomaticResult ?? record.result
        for (index, definition) in record.definitions.enumerated() {
            let result = record.result.values[index]
            let centimeters = result.status == .unavailable ? nil : result.meters.flatMap {
                $0.isFinite && $0 > 0 ? $0 * 100 : nil
            }
            guard let key = productMeasurementKeys[definition.id] else { throw MeasurementImportError.invalidRecord }
            let original = originalResult.values[index]
            let automatic = original.status == .unavailable ? nil : original.meters.flatMap {
                $0.isFinite && $0 > 0 ? $0 * 100 : nil
            }
            if let existing = garment.measurement(key) {
                existing.valueCm = centimeters ?? 0
                existing.autoValueCm = automatic
                existing.isEdited = false
                existing.sourceStatusRaw = result.status.rawValue
                existing.label = result.title
                existing.displayOrder = index
            } else {
                guard centimeters != nil || GarmentMeasurementPresentation.isVisibleMeasurementID(definition.id, kind: kind) else { continue }
                let value = MeasuredValue(key: key, label: result.title, displayOrder: index,
                    valueCm: centimeters ?? 0, autoValueCm: automatic)
                value.sourceStatusRaw = result.status.rawValue
                value.garment = garment
                context.insert(value)
                if !garment.measurements.contains(where: { $0.id == value.id }) { garment.measurements.append(value) }
            }
        }
        for (index, raw) in record.landmarks.points.enumerated() {
            let updated = productLandmark(raw, index: index, record: record)
            if let existing = photo.landmark(updated.name) {
                copyLandmarkEvidence(from: updated, to: existing)
            } else {
                updated.photo = photo
                context.insert(updated)
                if !photo.landmarks.contains(where: { $0.id == updated.id }) { photo.landmarks.append(updated) }
            }
        }
        garment.sourceMeasurementID = record.id
        photo.measurementRecordID = record.id
        photo.measurementModelVersion = record.landmarks.modelVersion
        photo.measurementAlgorithmVersion = record.result.algorithmVersion
        photo.measurementDepthSourceRaw = record.snapshot.frame.source.rawValue
        photo.measurementLandmarkOriginRaw = record.landmarks.origin.rawValue
        garment.syncFilterFields()
        // Like information-input saving, a failure leaves current edits in the
        // flow's private context so the user can retry without losing them.
        try save(context)
    }

    @MainActor
    private static func productLandmark(_ rawCurrent: GarmentLandmark, index: Int,
                                        record: SavedMeasurement) -> LandmarkPoint {
        let originalLandmarks = record.originalAutomaticLandmarks ?? record.landmarks
        let originalResult = record.originalAutomaticResult ?? record.result
        let displayedCurrent = record.landmarks.replacingDerivedImagePoints(with: record.result)
        let displayedAutomatic = originalLandmarks.replacingDerivedImagePoints(with: originalResult)
        // Only contour placeholders use calculated intersections in the graph.
        func productPoint(_ raw: GarmentLandmark, displayed: GarmentLandmarkSet) -> GarmentLandmark {
            guard raw.contourRule != nil else { return raw }
            return displayed.points.first(where: { $0.id == raw.id }) ?? raw
        }
        let current = productPoint(rawCurrent, displayed: displayedCurrent)
        let point = LandmarkPoint(name: current.id, index: index, x: current.point.x, y: current.point.y)
        point.originRaw = (current.origin ?? record.landmarks.origin).rawValue
        point.confidence = current.confidence
        point.isVisible = current.isVisible
        point.derivedFrom = record.landmarks.effectiveDerivedSourceIDs(for: current.id)
        if let rawOriginal = originalLandmarks.points.first(where: { $0.id == current.id }),
           rawOriginal.contourRule == nil || productPoint(rawOriginal, displayed: displayedAutomatic).isVisible {
            let original = productPoint(rawOriginal, displayed: displayedAutomatic)
            point.hasAutomaticObservation = true
            point.autoX = original.point.x
            point.autoY = original.point.y
            point.autoOriginRaw = (original.origin ?? originalLandmarks.origin).rawValue
            point.autoConfidence = original.confidence
            point.autoIsVisible = original.isVisible
            point.autoDerivedFrom = originalLandmarks.effectiveDerivedSourceIDs(for: original.id)
            point.isMoved = rawCurrent.contourRule == nil && point.derivedFrom == nil
                && (current.point != original.point || point.originRaw != point.autoOriginRaw)
        } else {
            point.hasAutomaticObservation = false
            point.autoOriginRaw = nil
            point.autoConfidence = nil
            point.autoIsVisible = false
            point.autoDerivedFrom = nil
            point.isMoved = rawCurrent.contourRule == nil && current.origin == .manual
        }
        return point
    }

    @MainActor
    private static func copyLandmarkEvidence(from updated: LandmarkPoint, to existing: LandmarkPoint) {
        existing.index = updated.index
        existing.x = updated.x; existing.y = updated.y
        existing.autoX = updated.autoX; existing.autoY = updated.autoY
        existing.hasAutomaticObservation = updated.hasAutomaticObservation
        existing.isMoved = updated.isMoved
        existing.originRaw = updated.originRaw; existing.autoOriginRaw = updated.autoOriginRaw
        existing.confidence = updated.confidence; existing.autoConfidence = updated.autoConfidence
        existing.isVisible = updated.isVisible; existing.autoIsVisible = updated.autoIsVisible
        existing.derivedFrom = updated.derivedFrom; existing.autoDerivedFrom = updated.autoDerivedFrom
    }

    /// Write a private file, then publish it with a same-directory move that
    /// fails if the destination already exists. Foundation prohibits combining
    /// `.atomic` with `.withoutOverwriting` in Data.write.
    static func writeMeasurementPhoto(_ data: Data, to destination: URL) throws {
        let stagingDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".pending-measurement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        // This directory is owned only after createDirectory succeeds. Even a
        // partial write failure removes our staging file, never another file.
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let staging = stagingDirectory.appendingPathComponent("image.jpg")
        try data.write(to: staging, options: .withoutOverwriting)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private static let productMeasurementKeys: [String: String] = [
        "top.shoulderWidth": "shoulderWidth",
        "top.chestWidth": "chestWidth",
        "top.hemWidth": "hemWidth",
        "top.sleeveLengthLeft": "sleeveLengthLeft",
        "top.sleeveLengthRight": "sleeveLengthRight",
        "top.totalLength": "totalLength",
        "bottom.waist_left.waist_right": "waistWidth",
        "bottom.crotch.waist_center": "frontRise",
        "bottom.crotch.waist_front_center": "frontRise",
        "bottom.thighWidthRight": "thighWidthRight",
        "bottom.hem_left_outer.waist_left": "totalLengthLeft",
        "bottom.hem_left_inner.hem_left_outer": "hemWidthLeft",
        "bottom.crotch.hem_left_inner": "inseamLeft",
        "bottom.hem_right_outer.waist_right": "totalLengthRight",
        "bottom.hem_right_inner.hem_right_outer": "hemWidthRight",
        "bottom.crotch.hem_right_inner": "inseamRight"
    ]

    private static func validateProductMeasurement(_ record: SavedMeasurement,
                                                   allowsSynthetic: Bool,
                                                   allowsUnavailableDraft: Bool = false) throws -> AutomaticGarmentKind {
        let frame = record.snapshot.frame
        guard record.schemaVersion == 1, frame.imageSize.isValid,
              allowsSynthetic || frame.source != .synthetic,
              let kind = record.landmarks.garmentKind,
              record.landmarks.sessionID == frame.sessionID, record.landmarks.frameID == frame.frameID,
              record.result.sessionID == frame.sessionID, record.result.frameID == frame.frameID,
              record.result.source == frame.source,
              record.definitions.map(\.id) == record.result.values.map(\.id),
              Set(record.definitions.map(\.id)).count == record.definitions.count else {
            throw MeasurementImportError.invalidRecord
        }
        let expectedPreviewVersion = kind == .top ? "garment-ui-top-preview-v1" : "garment-ui-preview-v1"
        let isSyntheticPreview = allowsSynthetic && frame.source == .synthetic
            && record.landmarks.origin == .synthetic && record.landmarks.modelVersion == expectedPreviewVersion
        let isCurrentModel = record.landmarks.modelVersion == kind.modelVersion
        let isLegacyModel = record.landmarks.modelVersion == kind.legacyModelVersion
        let isLegacyBottom8 = kind == .bottoms
            && record.landmarks.modelVersion == AutomaticGarmentKind.legacyBottom8ModelVersion
        guard isSyntheticPreview || (record.landmarks.origin == .model
            && (isCurrentModel || isLegacyModel || isLegacyBottom8)) else {
            throw MeasurementImportError.invalidRecord
        }
        let expected: [MeasurementDefinition]
        let physicalPointNames: [String]
        let derived: [String: [String]]
        let usesContourLength: Bool
        let usesContourThigh: Bool
        switch kind {
        case .top:
            usesContourThigh = false
            // Preview records predate the contour contract. They do not grant
            // arbitrary production model/definition combinations.
            usesContourLength = isCurrentModel && !isSyntheticPreview
            if usesContourLength {
                expected = TopLandmarkSchema.canonicalMeasurementDefinitions
            } else if record.definitions.first(where: { $0.id == "top.totalLength" })?.projection != nil {
                expected = TopLandmarkSchema.legacyProjectedMeasurementDefinitions
            } else {
                expected = TopLandmarkSchema.legacyMeasurementDefinitions
            }
            physicalPointNames = TopLandmarkSchema.expectedKeypoints + (usesContourLength ? ["top_length_start"] : [])
            derived = ["neck_center": ["neck_left", "neck_right"]]
        case .bottoms:
            usesContourLength = false
            usesContourThigh = isCurrentModel && !isSyntheticPreview
            let usesFrontCenter = (isCurrentModel || isLegacyBottom8) && !isSyntheticPreview
            expected = BottomLandmarkSchema.measurementPairs(frontWaistCenter: usesFrontCenter).map {
                MeasurementDefinition(id: "bottom." + $0.sorted().joined(separator: "."), title: "", landmarkIDs: $0)
            } + (usesContourThigh ? [BottomLandmarkSchema.thighWidthRightDefinition] : [])
            physicalPointNames = (usesFrontCenter ? BottomLandmarkSchema.expectedBottom8Keypoints
                : BottomLandmarkSchema.expectedBottom7Keypoints) + (usesContourThigh ? ["thigh_right"] : [])
            derived = ["waist_center": ["waist_left", "waist_right"]]
        }
        guard Set(record.definitions.map(\.id)) == Set(expected.map(\.id)),
              record.definitions.allSatisfy({ definition in
                  guard let canonical = expected.first(where: { $0.id == definition.id }) else { return false }
                  return definition.landmarkIDs == canonical.landmarkIDs
                      && definition.projection == canonical.projection
              }) else { throw MeasurementImportError.invalidRecord }

        func validContourRule(_ point: GarmentLandmark) -> Bool {
            let expectedRule: GarmentContourRule?
            if usesContourLength && point.id == "top_length_start" {
                expectedRule = .neckPerpendicularMaskV1
            } else if usesContourThigh && point.id == "thigh_right" {
                expectedRule = .waistParallelRightThighMaskV1
            } else {
                expectedRule = nil
            }
            if let rule = point.contourRule {
                return rule == expectedRule && point.derivedFrom == nil
                    // A manually moved physical parent makes the recomputed
                    // intersection manual-derived, not a direct user override.
                    && point.origin != .synthetic && point.confidence == nil
            }
            // A computed intersection has an explicit rule; only a confirmed
            // manual override may replace it with a direct point.
            if expectedRule != nil {
                return point.origin == .manual && point.derivedFrom == nil
                    && point.confidence == nil && point.isVisible
            }
            return true
        }

        func validateLandmarks(_ set: GarmentLandmarkSet) -> Bool {
            let ids = set.points.map(\.id)
            let known = Set(physicalPointNames + Array(derived.keys))
            return set.sessionID == frame.sessionID && set.frameID == frame.frameID
                && set.origin == record.landmarks.origin && set.garmentKind == kind
                && set.modelVersion == record.landmarks.modelVersion
                && !ids.isEmpty && ids.count <= 200 && Set(ids).count == ids.count
                && Set(ids).isSubset(of: known)
                && set.points.allSatisfy { point in
                    point.point.isValid && (point.confidence.map { $0.isFinite && $0 >= 0 && $0 <= 1 } ?? true)
                        && (point.derivedFrom == nil || point.derivedFrom == derived[point.id])
                        && validContourRule(point)
                }
        }
        guard validateLandmarks(record.landmarks) else { throw MeasurementImportError.invalidRecord }

        func preservesOriginalLandmarkIDs(_ original: GarmentLandmarkSet) -> Bool {
            let originalIDs = Set(original.points.map(\.id))
            let currentIDs = Set(record.landmarks.points.map(\.id))
            // Existing points may be corrected, but no observation may be dropped.
            guard originalIDs.isSubset(of: currentIDs) else { return false }
            let addedIDs = currentIDs.subtracting(originalIDs)
            guard !addedIDs.isEmpty else { return true }
            let endpoints: [String]
            let definitionID: String
            if kind == .top {
                endpoints = usesContourLength ? ["top_length_start", "hem_center"] : ["neck_center", "hem_center"]
                definitionID = "top.totalLength"
            } else if usesContourThigh {
                endpoints = BottomLandmarkSchema.thighWidthRightDefinition.landmarkIDs
                definitionID = BottomLandmarkSchema.thighWidthRightDefinition.id
            } else {
                return false
            }
            guard addedIDs.isSubset(of: Set(endpoints)),
                  let definition = record.definitions.first(where: { $0.id == definitionID }),
                  definition.landmarkIDs == endpoints, definition.projection == nil else { return false }
            // Restoring even one missing endpoint requires confirming both.
            return endpoints.allSatisfy { id in
                record.landmarks.points.contains { point in
                    point.id == id && point.origin == .manual && point.isVisible
                        && point.point.isValid && point.confidence == nil && point.derivedFrom == nil
                        && point.contourRule == nil
                }
            }
        }

        if record.originalAutomaticLandmarks != nil || record.originalAutomaticResult != nil {
            guard let original = record.originalAutomaticLandmarks,
                  let result = record.originalAutomaticResult, validateLandmarks(original),
                  preservesOriginalLandmarkIDs(original),
                  result.sessionID == frame.sessionID, result.frameID == frame.frameID,
                  result.source == frame.source,
                  result.values.map(\.id) == record.definitions.map(\.id),
                  result.values.allSatisfy({ hasUsableCentimeters($0) }) else {
                throw MeasurementImportError.invalidRecord
            }
        }
        guard allowsUnavailableDraft || record.result.values.contains(where: {
            $0.status != .unavailable && ($0.meters.map { $0.isFinite && $0 > 0 && ($0 * 100).isFinite } ?? false)
        }) else { throw MeasurementImportError.noAvailableMeasurements }
        guard record.result.values.allSatisfy({ hasUsableCentimeters($0) }) else {
            throw MeasurementImportError.invalidRecord
        }
        return kind
    }

    private static func hasUsableCentimeters(_ value: MeasurementValue) -> Bool {
        value.status == .unavailable || (value.meters.map {
            $0.isFinite && $0 > 0 && ($0 * 100).isFinite
        } ?? (value.status != .valid))
    }

    /// Add display orientation without rotating the source pixels or recompressing
    /// the JPEG. Landmark coordinates and depth still refer to the original RGB.
    private static func orientedMeasurementJPEG(_ snapshot: CaptureSnapshot) throws -> Data {
        guard !snapshot.imageJPEG.isEmpty, snapshot.imageJPEG.count < 20_000_000,
              let source = CGImageSourceCreateWithData(snapshot.imageJPEG as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), type as String == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == snapshot.frame.imageSize.width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == snapshot.frame.imageSize.height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw MeasurementImportError.invalidImage
        }
        let exif: Int
        switch snapshot.frame.orientation {
        case .up: exif = 1
        case .right: exif = 6
        case .down: exif = 3
        case .left: exif = 8
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil),
              CGImageDestinationCopyImageSource(destination, source,
                  [kCGImageDestinationOrientation: exif] as CFDictionary, nil) else {
            throw MeasurementImportError.invalidImage
        }
        return data as Data
    }

    enum MeasurementImportError: LocalizedError {
        case invalidRecord, invalidImage, noAvailableMeasurements, identifierConflict, contextUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidRecord: "확인한 실측 기록과 촬영 정보가 일치하지 않습니다. 실측 결과를 다시 확인해 주세요."
            case .invalidImage: "실측에 사용한 사진을 저장하지 못했습니다. 원본 촬영을 다시 확인해 주세요."
            case .noAvailableMeasurements: "제품에 전달할 실측값이 없습니다. 측정점을 확인하거나 다시 촬영해 주세요."
            case .identifierConflict: "같은 식별자의 다른 제품이 있습니다. 기존 제품은 변경하지 않았습니다."
            case .contextUnavailable: "저장한 제품을 화면에 불러오지 못했습니다. 실측 결과에서 확인을 다시 눌러 주세요."
            }
        }
    }
}
