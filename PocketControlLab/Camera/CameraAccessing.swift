import Foundation

/// The result of a read-only AVFoundation match against a verified USB
/// device. A source is retained only when discovery found exactly one safe
/// candidate; ambiguity must remain fail-closed until a future chooser owns
/// selection.
@MainActor
enum CameraMatch {
    case none
    case single(any CameraPreviewSource)
    case multiple
}

/// Main-actor adapter around AVFoundation and CoreMediaIO discovery. The
/// production implementation preserves the existing static helpers; fakes
/// keep tests away from TCC and camera hardware.
@MainActor
protocol CameraAccessing: AnyObject {
    func requestVideoAccess() async -> CameraAuthorization
    func currentVideoAuthorization() -> CameraAuthorization
    func cameraMatch(for pocket: PocketDevice) -> CameraMatch
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

    func currentVideoAuthorization() -> CameraAuthorization {
        CameraDiscovery.currentVideoAuthorization()
    }

    func cameraMatch(for pocket: PocketDevice) -> CameraMatch {
        CameraDiscovery.cameraMatch(for: pocket)
    }

    func inspectStandardControls(
        camera: CameraDeviceInfo?,
        pocket: PocketDevice
    ) -> [UVCControlID: CMIOControlObservation] {
        CMIOStandardControlInspector.inspect(camera: camera, pocket: pocket)
    }
}
