import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import simd

/// All coordinates stay in the unrotated sensor raster. AVFoundation buffers
/// are retained read-only, never mutated or cached beyond the latest frame.
nonisolated final class MultiCameraFrame: @unchecked Sendable {
    static let maximumSynchronizationSkew: TimeInterval = 1.0 / 60.0

    let sessionID: UUID
    let timestamp: TimeInterval
    let wideImage: CVPixelBuffer
    let ultraWideImage: CVPixelBuffer
    let depthData: AVDepthData
    let wideIntrinsics: simd_float3x3
    let ultraWideIntrinsics: simd_float3x3
    /// A physical wide-camera point maps to ultra-wide coordinates as R * X + t.
    /// Factory translation is converted from millimetres to METRES by the owner.
    let wideToUltra: simd_float4x3
    let wideCalibration: MultiCameraLensCalibration
    let synchronizationSkew: TimeInterval

    private init(sessionID: UUID, timestamp: TimeInterval, wideImage: CVPixelBuffer,
                 ultraWideImage: CVPixelBuffer, depthData: AVDepthData,
                 wideIntrinsics: simd_float3x3, ultraWideIntrinsics: simd_float3x3,
                 wideToUltra: simd_float4x3, wideCalibration: MultiCameraLensCalibration,
                 synchronizationSkew: TimeInterval) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.wideImage = wideImage
        self.ultraWideImage = ultraWideImage
        self.depthData = depthData
        self.wideIntrinsics = wideIntrinsics
        self.ultraWideIntrinsics = ultraWideIntrinsics
        self.wideToUltra = wideToUltra
        self.wideCalibration = wideCalibration
        self.synchronizationSkew = synchronizationSkew
    }

    static func make(sessionID: UUID, wide: CMSampleBuffer, wideTimestamp: CMTime,
                     ultraWide: CMSampleBuffer, ultraWideTimestamp: CMTime,
                     depth: AVDepthData, depthTimestamp: CMTime,
                     wideToUltra: simd_float4x3) throws -> MultiCameraFrame {
        guard CMSampleBufferIsValid(wide), CMSampleBufferDataIsReady(wide),
              CMSampleBufferIsValid(ultraWide), CMSampleBufferDataIsReady(ultraWide),
              let wideImage = CMSampleBufferGetImageBuffer(wide),
              let ultraImage = CMSampleBufferGetImageBuffer(ultraWide) else {
            throw MultiCameraFrameError.invalidImage
        }
        // Synchronized timestamps explicitly share the capture session's
        // synchronization clock even when members arrive in separate callbacks.
        let wideTime = wideTimestamp.seconds
        let ultraTime = ultraWideTimestamp.seconds
        let depthTime = depthTimestamp.seconds
        let skew = try validatedSkew(wide: wideTime, ultraWide: ultraTime, depth: depthTime)
        try validateDepthAccuracy(depth.depthDataAccuracy)
        let converted = depth.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depth : depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let calibration = converted.cameraCalibrationData else {
            throw MultiCameraFrameError.missingCalibration
        }
        let imageSize = PixelSize(width: CVPixelBufferGetWidth(wideImage), height: CVPixelBufferGetHeight(wideImage))
        let ultraSize = PixelSize(width: CVPixelBufferGetWidth(ultraImage), height: CVPixelBufferGetHeight(ultraImage))
        let ultraK = try deliveredIntrinsics(ultraWide, imageSize: ultraSize)
        let lens = try MultiCameraLensCalibration(calibration, imageSize: imageSize)
        // The synchronized depth calibration describes its accompanying wide
        // RGB grid. Apple's LiDAR streaming sample uses that K directly. Video
        // K delivery is an optional cross-check for wide, not a second source
        // of calibration that must exist on this virtual capture connection.
        let wideK = try validatedWideIntrinsics(calibration: lens,
            deliveredData: intrinsicMatrixAttachment(wide))
        try validateExtrinsics(wideToUltra)
        let depthSize = PixelSize(width: CVPixelBufferGetWidth(converted.depthDataMap),
                                  height: CVPixelBufferGetHeight(converted.depthDataMap))
        guard depthSize.isValid, depthSize.width <= 2_048, depthSize.height <= 2_048,
              depthSize.width * imageSize.height == depthSize.height * imageSize.width else {
            throw MultiCameraFrameError.invalidDepth
        }
        return MultiCameraFrame(sessionID: sessionID, timestamp: wideTime, wideImage: wideImage,
            ultraWideImage: ultraImage, depthData: converted, wideIntrinsics: wideK,
            ultraWideIntrinsics: ultraK, wideToUltra: wideToUltra,
            wideCalibration: lens, synchronizationSkew: skew)
    }

    static func validatedSkew(wide: TimeInterval, ultraWide: TimeInterval, depth: TimeInterval) throws -> TimeInterval {
        guard [wide, ultraWide, depth].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw MultiCameraFrameError.invalidTimestamp
        }
        let skew = max(wide, max(ultraWide, depth)) - min(wide, min(ultraWide, depth))
        guard skew <= maximumSynchronizationSkew else { throw MultiCameraFrameError.unsynchronizedFrames }
        return skew
    }

    static func validateDepthAccuracy(_ accuracy: AVDepthData.Accuracy) throws {
        guard accuracy == .absolute else { throw MultiCameraFrameError.relativeDepth }
    }

    static func validateExtrinsics(_ matrix: simd_float4x3) throws {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        guard columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              simd_length(matrix.columns.3) < 0.25 else { throw MultiCameraFrameError.invalidExtrinsics }
        let r = simd_float3x3(columns: (matrix.columns.0, matrix.columns.1, matrix.columns.2))
        let identity = r.transpose * r
        let error = max(simd_length(identity.columns.0 - SIMD3<Float>(1, 0, 0)),
                        max(simd_length(identity.columns.1 - SIMD3<Float>(0, 1, 0)),
                            simd_length(identity.columns.2 - SIMD3<Float>(0, 0, 1))))
        guard error < 0.01, abs(simd_determinant(r) - 1) < 0.01 else {
            throw MultiCameraFrameError.invalidExtrinsics
        }
    }

    /// Absence is allowed only for the paired wide RGB: the absolute depth
    /// packet already supplies its validated factory K and distortion model.
    /// Present-but-malformed or contradictory video calibration never falls
    /// back silently, and the canonical K stays identical for RGB and depth.
    static func validatedWideIntrinsics(calibration: MultiCameraLensCalibration,
                                        deliveredData: Data?) throws -> simd_float3x3 {
        if let deliveredData {
            let delivered = try decodedIntrinsics(deliveredData,
                imageSize: calibration.intrinsics.referenceSize)
            guard calibration.matchesDeliveredIntrinsics(delivered) else {
                throw MultiCameraFrameError.invalidCalibration
            }
        }
        return calibration.intrinsicMatrix
    }

    private static func intrinsicMatrixAttachment(_ sample: CMSampleBuffer) throws -> Data? {
        guard let attachment = CMGetAttachment(sample,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) else { return nil }
        guard let data = attachment as? Data else { throw MultiCameraFrameError.invalidCalibration }
        return data
    }

    private static func deliveredIntrinsics(_ sample: CMSampleBuffer, imageSize: PixelSize) throws -> simd_float3x3 {
        // Ultra Wide has no paired AVDepthData calibration; its delivered K
        // remains mandatory for geometrically registered peripheral pixels.
        guard let data = try intrinsicMatrixAttachment(sample) else { throw MultiCameraFrameError.missingCalibration }
        return try decodedIntrinsics(data, imageSize: imageSize)
    }

    private static func decodedIntrinsics(_ data: Data, imageSize: PixelSize) throws -> simd_float3x3 {
        guard data.count == MemoryLayout<simd_float3x3>.size else { throw MultiCameraFrameError.invalidCalibration }
        let matrix = data.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) }
        _ = try MultiCameraLensCalibration.intrinsics(matrix, imageSize: imageSize)
        return matrix
    }
}

/// Factory radial calibration, in the RGB reference raster. The forward table
/// maps a RECTIFIED destination point to the corresponding DISTORTED source.
/// This is Apple's AV calibration inverse-rasterization convention; using the
/// inverse table here would distort the picture a second time.
nonisolated struct MultiCameraLensCalibration: Sendable, Equatable {
    let intrinsics: CameraIntrinsics
    let distortionCenter: SIMD2<Float>
    let distortionLookupTable: [Float]

    init(intrinsics: CameraIntrinsics, distortionCenter: SIMD2<Float>, distortionLookupTable: [Float]) throws {
        let size = intrinsics.referenceSize
        guard size.isValid, intrinsics.fx.isFinite, intrinsics.fy.isFinite,
              intrinsics.cx.isFinite, intrinsics.cy.isFinite,
              intrinsics.fx > 0, intrinsics.fy > 0,
              intrinsics.cx >= 0, intrinsics.cy >= 0,
              intrinsics.cx < Double(size.width), intrinsics.cy < Double(size.height),
              distortionCenter.x.isFinite, distortionCenter.y.isFinite,
              distortionCenter.x >= 0, distortionCenter.y >= 0,
              distortionCenter.x <= Float(size.width), distortionCenter.y <= Float(size.height),
              (2...4_096).contains(distortionLookupTable.count),
              distortionLookupTable.allSatisfy({ $0.isFinite && $0 > -1 && abs($0) <= 4 }) else {
            throw MultiCameraFrameError.invalidCalibration
        }
        self.intrinsics = intrinsics
        self.distortionCenter = distortionCenter
        self.distortionLookupTable = distortionLookupTable
    }

    init(_ calibration: AVCameraCalibrationData, imageSize: PixelSize) throws {
        let reference = calibration.intrinsicMatrixReferenceDimensions
        guard reference.width.isFinite, reference.height.isFinite,
              reference.width > 0, reference.height > 0,
              reference.width <= 16_384, reference.height <= 16_384,
              let tableData = calibration.lensDistortionLookupTable,
              tableData.count % MemoryLayout<Float>.size == 0,
              (2...4_096).contains(tableData.count / MemoryLayout<Float>.size) else {
            throw MultiCameraFrameError.missingCalibration
        }
        let referenceSize = PixelSize(width: Int(reference.width.rounded()), height: Int(reference.height.rounded()))
        guard referenceSize.isValid,
              abs(reference.width - CGFloat(referenceSize.width)) < 0.01,
              abs(reference.height - CGFloat(referenceSize.height)) < 0.01,
              referenceSize.width * imageSize.height == referenceSize.height * imageSize.width else {
            throw MultiCameraFrameError.invalidCalibration
        }
        let k = try Self.intrinsics(calibration.intrinsicMatrix, imageSize: referenceSize)
        let table: [Float] = tableData.withUnsafeBytes { bytes in
            (0..<(bytes.count / MemoryLayout<Float>.size)).map {
                bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
            }
        }
        let referenceCalibration = try Self(intrinsics: k,
            distortionCenter: SIMD2(Float(calibration.lensDistortionCenter.x), Float(calibration.lensDistortionCenter.y)),
            distortionLookupTable: table)
        self = try referenceCalibration.scaled(to: imageSize)
    }

    static func intrinsics(_ matrix: simd_float3x3, imageSize: PixelSize) throws -> CameraIntrinsics {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2]
        guard imageSize.isValid,
              columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              abs(matrix.columns.0.y) < 0.001, abs(matrix.columns.0.z) < 0.001,
              abs(matrix.columns.1.x) < 0.001, abs(matrix.columns.1.z) < 0.001,
              abs(matrix.columns.2.z - 1) < 0.001,
              matrix.columns.0.x > 0, matrix.columns.1.y > 0,
              matrix.columns.2.x >= 0, matrix.columns.2.x < Float(imageSize.width),
              matrix.columns.2.y >= 0, matrix.columns.2.y < Float(imageSize.height) else {
            throw MultiCameraFrameError.invalidCalibration
        }
        return CameraIntrinsics(fx: Double(matrix.columns.0.x), fy: Double(matrix.columns.1.y),
            cx: Double(matrix.columns.2.x), cy: Double(matrix.columns.2.y), referenceSize: imageSize)
    }

    func scaled(to size: PixelSize) throws -> Self {
        let reference = intrinsics.referenceSize
        guard size.isValid, reference.width * size.height == reference.height * size.width else {
            throw MultiCameraFrameError.invalidCalibration
        }
        let sx = Double(size.width) / Double(reference.width)
        let sy = Double(size.height) / Double(reference.height)
        return try Self(intrinsics: .init(fx: intrinsics.fx * sx, fy: intrinsics.fy * sy,
            cx: intrinsics.cx * sx, cy: intrinsics.cy * sy, referenceSize: size),
            distortionCenter: distortionCenter * SIMD2(Float(sx), Float(sy)),
            distortionLookupTable: distortionLookupTable)
    }

    /// The same pinhole K is used for live projection and captured measurement.
    /// Delivered video K is checked first, then this depth-camera K is canonical.
    var intrinsicMatrix: simd_float3x3 {
        simd_float3x3(columns: (SIMD3(Float(intrinsics.fx), 0, 0), SIMD3(0, Float(intrinsics.fy), 0),
                               SIMD3(Float(intrinsics.cx), Float(intrinsics.cy), 1)))
    }

    func sourcePoint(forRectifiedPixel point: SIMD2<Float>, in size: PixelSize) -> SIMD2<Float>? {
        guard size.isValid, point.x.isFinite, point.y.isFinite,
              intrinsics.referenceSize.width * size.height == intrinsics.referenceSize.height * size.width else { return nil }
        let scale = Float(size.width) / Float(intrinsics.referenceSize.width)
        let center = distortionCenter * scale
        let farthest = SIMD2(max(center.x, Float(size.width) - center.x), max(center.y, Float(size.height) - center.y))
        let maximumRadius = simd_length(farthest)
        guard maximumRadius.isFinite, maximumRadius > 0 else { return nil }
        let vector = point - center
        let radius = simd_length(vector)
        let tablePosition = min(Float(distortionLookupTable.count - 1),
                                max(0, radius / maximumRadius * Float(distortionLookupTable.count - 1)))
        let index = min(distortionLookupTable.count - 2, Int(tablePosition))
        let fraction = tablePosition - Float(index)
        let magnification = distortionLookupTable[index] * (1 - fraction) + distortionLookupTable[index + 1] * fraction
        let source = center + vector * (1 + magnification)
        return source.x.isFinite && source.y.isFinite ? source : nil
    }

    func matchesDeliveredIntrinsics(_ matrix: simd_float3x3) -> Bool {
        guard let delivered = try? Self.intrinsics(matrix, imageSize: intrinsics.referenceSize) else { return false }
        return abs(delivered.fx - intrinsics.fx) <= max(0.5, intrinsics.fx * 0.005)
            && abs(delivered.fy - intrinsics.fy) <= max(0.5, intrinsics.fy * 0.005)
            && abs(delivered.cx - intrinsics.cx) <= 1
            && abs(delivered.cy - intrinsics.cy) <= 1
    }
}

nonisolated enum MultiCameraFrameError: Error, LocalizedError, Sendable {
    case invalidTimestamp, unsynchronizedFrames, missingCalibration, invalidCalibration
    case relativeDepth, invalidDepth, invalidImage, invalidExtrinsics, rendererUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidTimestamp: "카메라 프레임의 촬영 시각을 확인할 수 없어요."
        case .unsynchronizedFrames: "일반·초광각·LiDAR 프레임의 촬영 시각이 일치하지 않아요."
        case .missingCalibration: "정확한 길이 계산에 필요한 카메라 보정 정보가 없어요."
        case .invalidCalibration: "사진·깊이·카메라 보정 정보의 좌표가 일치하지 않아요."
        case .relativeDepth: "실제 길이를 계산할 수 있는 절대 LiDAR 깊이가 아니에요."
        case .invalidDepth: "LiDAR 깊이 데이터를 읽을 수 없어요."
        case .invalidImage: "카메라 사진을 읽을 수 없어요."
        case .invalidExtrinsics: "일반·초광각 카메라 사이의 보정 정보를 확인할 수 없어요."
        case .rendererUnavailable: "카메라 영상을 보정할 그래픽 장치를 준비하지 못했어요."
        }
    }
}
