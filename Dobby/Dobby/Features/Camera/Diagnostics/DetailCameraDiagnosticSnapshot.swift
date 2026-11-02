// Created by mason on 10/31/26.
import AVFoundation
import Foundation

extension DetailCameraDiagnostics {
    /// Call on CameraPreviewDriver's serial queue; no settings are changed here.
    nonisolated func recordDevice(_ event: String, device: AVCaptureDevice?, captureID: UUID? = nil,
                      requestedZoom: Double? = nil) {
        guard enabled, let device else { return }
        let gains = device.deviceWhiteBalanceGains
        var fields: [String: Any] = [
            "deviceType": device.deviceType.rawValue,
            "primaryConstituent": device.activePrimaryConstituent?.deviceType.rawValue ?? "unavailable",
            "zoomRaw": Double(device.videoZoomFactor),
            "zoomDisplay": Double(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier),
            "whiteBalanceMode": device.whiteBalanceMode.rawValue,
            "wbRed": gains.redGain, "wbGreen": gains.greenGain, "wbBlue": gains.blueGain,
            "adjustingWhiteBalance": device.isAdjustingWhiteBalance,
            "exposureMode": device.exposureMode.rawValue,
            "iso": device.iso, "exposureSeconds": CMTimeGetSeconds(device.exposureDuration),
            "exposureBias": device.exposureTargetBias, "exposureOffset": device.exposureTargetOffset,
            "adjustingExposure": device.isAdjustingExposure,
            "lensPosition": device.lensPosition, "adjustingFocus": device.isAdjustingFocus,
            "activeColorSpace": device.activeColorSpace.rawValue,
            "videoHDR": device.isVideoHDREnabled,
            "fieldOfView": device.activeFormat.videoFieldOfView
        ]
        fields["requestedZoom"] = requestedZoom
        record(event, captureID: captureID, fields: fields)
    }

    nonisolated func recordPhoto(_ photo: AVCapturePhoto, captureID: UUID?, original: Data?) {
        guard enabled, let captureID else { return }
        // sourceDeviceType can name the virtual camera; it is not proof of the physical lens.
        record("photo_received", captureID: captureID, fields: [
            "photoSourceDeviceType": photo.sourceDeviceType?.rawValue ?? "unavailable",
            "resolvedPhotoID": photo.resolvedSettings.uniqueID,
            "photoTimestampSeconds": CMTimeGetSeconds(photo.timestamp),
            "originalByteCount": original?.count ?? 0
        ])
        if let original { save(original, as: .original, captureID: captureID) }
        if let metadata = try? PropertyListSerialization.data(fromPropertyList: photo.metadata,
                                                              format: .xml, options: 0) {
            save(metadata, as: .metadata, captureID: captureID)
        }
    }
}
