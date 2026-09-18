import AVFoundation
import CoreMedia
import Foundation

enum CameraAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    init(status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .denied
        }
    }

    var displayName: String {
        switch self {
        case .notDetermined:
            "Not determined"
        case .authorized:
            "Authorized"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        }
    }
}

enum CameraDiscovery {
    /// Reads the process's existing TCC state without presenting a permission
    /// prompt. Passive discovery uses this only to describe availability; the
    /// explicit preview action remains the sole permission-request path.
    @MainActor
    static func currentVideoAuthorization() -> CameraAuthorization {
        CameraAuthorization(status: AVCaptureDevice.authorizationStatus(for: .video))
    }

    @MainActor
    static func requestVideoAccess() async -> CameraAuthorization {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .notDetermined else {
            return CameraAuthorization(status: status)
        }

        _ = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }

        return CameraAuthorization(status: AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// Finds an unambiguous AVFoundation source for the observed USB Pocket.
    /// This never requests TCC access or constructs an AVCaptureSession.
    ///
    /// An exact Pocket token is preferred over the intentionally narrower
    /// generic-DJI fallback, but multiple candidates at either confidence
    /// level are reported as ambiguous rather than selecting the first one.
    @MainActor
    static func cameraMatch(for pocket: PocketDevice) -> CameraMatch {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        let devicesWithNormalizedIdentity = discovery.devices.map { device in
            let candidate = [
                device.localizedName,
                device.modelID,
                device.manufacturer,
                device.uniqueID,
            ]
            .map(normalize)
            .joined(separator: " ")

            return (device, candidate)
        }

        let exactMatches = devicesWithNormalizedIdentity.filter {
            $0.1.contains(pocket.cameraMatchingToken)
        }

        switch exactMatches.count {
        case 1:
            return .single(previewSource(for: exactMatches[0].0))
        case 2...:
            return .multiple
        default:
            break
        }

        // Some UVC drivers publish a generic DJI camera name. It is safe to
        // use that fallback for preview only when the USB identity is the
        // exact validated Pocket 4 profile and it produces one unambiguous
        // external-camera candidate. It never broadens UVC control matching.
        guard pocket.supportsPocket4ControlProfile else {
            return .none
        }

        let djiCandidates = devicesWithNormalizedIdentity.filter { $0.1.contains("dji") }
        switch djiCandidates.count {
        case 0:
            return .none
        case 1:
            return .single(previewSource(for: djiCandidates[0].0))
        default:
            return .multiple
        }
    }

    static func describe(_ device: AVCaptureDevice) -> CameraDeviceInfo {
        let formats = device.formats.enumerated().map { index, format in
            formatInfo(format, index: index)
        }

        return CameraDeviceInfo(
            localizedName: device.localizedName,
            uniqueID: device.uniqueID,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            deviceType: device.deviceType.rawValue,
            transportType: fourCC(UInt32(truncatingIfNeeded: device.transportType)),
            activeFormat: formatInfo(device.activeFormat, index: -1),
            activeMinimumFrameDuration: timeDescription(device.activeVideoMinFrameDuration),
            activeMaximumFrameDuration: timeDescription(device.activeVideoMaxFrameDuration),
            formats: formats
        )
    }

    private static func formatInfo(_ format: AVCaptureDevice.Format, index: Int) -> VideoFormatInfo {
        let description = format.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let frameRates = format.videoSupportedFrameRateRanges.map {
            String(format: "%.3f–%.3f fps", $0.minFrameRate, $0.maxFrameRate)
        }

        return VideoFormatInfo(
            id: "\(index)-\(dimensions.width)x\(dimensions.height)-\(CMFormatDescriptionGetMediaSubType(description))",
            mediaType: fourCC(CMFormatDescriptionGetMediaType(description)),
            mediaSubType: fourCC(CMFormatDescriptionGetMediaSubType(description)),
            width: dimensions.width,
            height: dimensions.height,
            frameRateDescription: frameRates.isEmpty ? "No frame-rate range exposed" : frameRates.joined(separator: ", ")
        )
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        let isPrintable = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }

        if isPrintable, let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }

        return String(format: "0x%08X", value)
    }

    private static func timeDescription(_ time: CMTime) -> String {
        guard time.isValid, time.timescale != 0 else {
            return "Not exposed"
        }
        return String(format: "%.6f s", CMTimeGetSeconds(time))
    }

    private static func normalize(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    @MainActor
    private static func previewSource(for device: AVCaptureDevice) -> any CameraPreviewSource {
        AVFoundationCameraPreviewSource(
            device: device,
            cameraInfo: describe(device)
        )
    }
}
