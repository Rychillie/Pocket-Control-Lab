import Foundation
import Observation

enum OnboardingConnectionStatus: Equatable, Sendable {
    case searching
    case connectCamera
    case disconnected
    case unsupportedPocketFamily
    case cameraPermissionNeeded
    case cameraPermissionUnavailable
    case multipleMatchingCameras
    case videoDeviceNotVisible
    case checkingVideoVisibility
    case videoDeviceVisible
}

/// A beginner-friendly, side-effect-free summary of the existing session
/// evidence. It deliberately excludes identifiers and direct-UVC details.
struct OnboardingConnectionPresentation: Equatable, Sendable {
    let status: OnboardingConnectionStatus
    let title: String
    let detail: String

    var systemImage: String {
        switch status {
        case .searching:
            "magnifyingglass"
        case .connectCamera:
            "camera"
        case .disconnected:
            "cable.connector.slash"
        case .unsupportedPocketFamily:
            "exclamationmark.triangle"
        case .cameraPermissionNeeded:
            "camera.badge.ellipsis"
        case .cameraPermissionUnavailable:
            "camera.badge.exclamationmark"
        case .multipleMatchingCameras:
            "camera.badge.ellipsis"
        case .videoDeviceNotVisible:
            "video.slash"
        case .checkingVideoVisibility:
            "video"
        case .videoDeviceVisible:
            "checkmark.circle.fill"
        }
    }

    var canRefreshDetection: Bool {
        switch status {
        case .connectCamera, .disconnected, .multipleMatchingCameras, .videoDeviceNotVisible:
            true
        case .searching, .unsupportedPocketFamily, .cameraPermissionNeeded,
             .cameraPermissionUnavailable, .checkingVideoVisibility, .videoDeviceVisible:
            false
        }
    }

    init(
        connection: PocketConnectionPresentationState,
        cameraMatchStatus: CameraMatchStatus
    ) {
        switch connection.kind {
        case .lookingForPocket:
            status = .searching
        case .noPocketConnected:
            status = .connectCamera
        case .disconnected:
            status = .disconnected
        case .unsupportedPocketFamily:
            status = .unsupportedPocketFamily
        case .cameraAccessNeeded:
            status = .cameraPermissionNeeded
        case .cameraAccessUnavailable:
            status = .cameraPermissionUnavailable
        case .multipleMatchingCameras:
            status = .multipleMatchingCameras
        case .cameraNotVisible:
            status = .videoDeviceNotVisible
        case .directUVCUnavailable, .readyToContinueSetup:
            switch cameraMatchStatus {
            case .single:
                // A UVC access limitation does not change AVFoundation video
                // visibility and is outside the onboarding result.
                status = .videoDeviceVisible
            case .none:
                status = .videoDeviceNotVisible
            case .multiple:
                status = .multipleMatchingCameras
            case .notChecked:
                status = .checkingVideoVisibility
            }
        }

        switch status {
        case .searching:
            title = "Looking for your camera"
            detail = "Passive USB detection is running. It does not request camera access or start video."
        case .connectCamera:
            title = "Connect your camera"
            detail = "Connect a DJI Osmo Pocket by USB-C, then select Webcam Mode on the camera."
        case .disconnected:
            title = "Camera disconnected"
            detail = "Reconnect the camera by USB-C and select Webcam Mode. USB detection remains active."
        case .unsupportedPocketFamily:
            title = "Pocket camera detected, but not supported"
            detail = "This build verifies only the Pocket 4 USB profile. Other Pocket-family devices remain detection-only."
        case .cameraPermissionNeeded:
            title = "Camera access has not been requested"
            detail = "Allow access only if you want to use local video preview."
        case .cameraPermissionUnavailable:
            title = "Camera access is unavailable"
            detail = "USB detection still works. To allow local preview, open System Settings → Privacy & Security → Camera and enable Pocket Control Lab."
        case .multipleMatchingCameras:
            title = "More than one matching camera is visible"
            detail = "Disconnect other matching cameras, then refresh detection. The app will not choose one automatically."
        case .videoDeviceNotVisible:
            title = "USB camera detected, but video is not visible"
            detail = "Confirm Webcam Mode on the camera, then refresh detection. USB presence does not guarantee video availability."
        case .checkingVideoVisibility:
            title = "Checking video visibility"
            detail = "Camera access is available. Waiting for the current video-device match."
        case .videoDeviceVisible:
            title = "Camera video device is visible"
            detail = "The camera is available to macOS. Onboarding does not start preview or inspect camera controls."
        }
    }
}

/// App-scoped preference state for the one non-sensitive onboarding value.
@MainActor
@Observable
final class OnboardingCompletionState {
    static let storageKey = "hasCompletedCameraOnboarding"

    private(set) var hasCompletedOnboarding: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: Self.storageKey)
    }

    func markCompleted() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Self.storageKey)
    }
}
