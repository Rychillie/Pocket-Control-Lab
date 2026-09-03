import Foundation

/// Main-actor adapter around AVFoundation and CoreMediaIO discovery. The
/// production implementation preserves the existing static helpers; fakes
/// keep tests away from TCC and camera hardware.
@MainActor
protocol CameraAccessing: AnyObject {
    func requestVideoAccess() async -> CameraAuthorization
    func previewSource(for pocket: PocketDevice) -> (any CameraPreviewSource)?
    func inspectStandardControls(
        camera: CameraDeviceInfo?,
        pocket: PocketDevice
    ) -> [UVCControlID: CMIOControlObservation]
}

@MainActor
final class LiveCameraAccess: CameraAccessing {
    func requestVideoAccess() async -> CameraAuthorization {
        await CameraDiscovery.requestVideoAccess()
    }

    func previewSource(for pocket: PocketDevice) -> (any CameraPreviewSource)? {
        guard let device = CameraDiscovery.pocketCamera(for: pocket) else {
            return nil
        }

        return AVFoundationCameraPreviewSource(
            device: device,
            cameraInfo: CameraDiscovery.describe(device)
        )
    }

    func inspectStandardControls(
        camera: CameraDeviceInfo?,
        pocket: PocketDevice
    ) -> [UVCControlID: CMIOControlObservation] {
        CMIOStandardControlInspector.inspect(camera: camera, pocket: pocket)
    }
}
