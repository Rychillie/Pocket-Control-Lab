import Foundation

/// The lifecycle stage of passive USB discovery. This deliberately describes
/// only the monitor lifecycle; it never causes a camera or UVC operation.
enum PassiveDiscoveryPhase: Equatable, Sendable {
    case starting
    case active
}

/// A privacy-safe summary of the read-only AVFoundation match result.
/// A preview source is retained elsewhere only for the unambiguous case.
enum CameraMatchStatus: Equatable, Sendable {
    case notChecked
    case single
    case none
    case multiple
}

/// The cached result of an explicit direct-UVC inspection for one connection
/// generation. `unknown` never causes a transport probe by itself.
enum DirectUVCAvailability: Equatable, Sendable {
    case unknown
    case available
    case blocked
}

enum ConnectionSeverity: Equatable, Sendable {
    case neutral
    case attention
    case warning
    case ready
}

enum ConnectionNextAction: Equatable, Sendable {
    case refreshDetection
    case openDiagnostics
}

/// The minimal typed evidence a status surface needs. It intentionally carries
/// no serial numbers, USB addresses, camera identifiers, preview state, or raw
/// transport data.
struct PocketConnectionEvidence: Equatable, Sendable {
    let discoveryPhase: PassiveDiscoveryPhase
    let identification: PocketIdentification?
    let didDisconnectAfterConnection: Bool
    let cameraAuthorization: CameraAuthorization
    let cameraMatchStatus: CameraMatchStatus
    let directUVCAvailability: DirectUVCAvailability
    let connectionGeneration: UInt64
    let directUVCAvailabilityGeneration: UInt64?
}

/// A pure, privacy-safe explanation of the current Pocket connection state.
/// Constructing it is intentionally side-effect free: it never checks USB,
/// touches AVFoundation, requests permission, or opens a UVC transport.
struct PocketConnectionPresentationState: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case lookingForPocket
        case disconnected
        case noPocketConnected
        case unsupportedPocketFamily
        case cameraAccessUnavailable
        case cameraAccessNeeded
        case multipleMatchingCameras
        case cameraNotVisible
        case directUVCUnavailable
        case readyToContinueSetup
    }

    let kind: Kind
    /// The exact user-facing connection status. It is the single wording source
    /// for compact and diagnostic surfaces.
    let title: String
    /// A short supporting explanation that does not expose device identifiers.
    let detail: String
    let severity: ConnectionSeverity
    let systemImage: String
    /// `nil` means no action is useful while the first passive scan is running.
    let nextAction: ConnectionNextAction?

    /// A concise VoiceOver label that includes app identity and connection
    /// state without leaking hardware identifiers or technical diagnostics.
    var accessibilityLabel: String {
        "Pocket Control Lab: \(title)"
    }

    private init(
        kind: Kind,
        title: String,
        detail: String,
        severity: ConnectionSeverity,
        systemImage: String,
        nextAction: ConnectionNextAction?
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.severity = severity
        self.systemImage = systemImage
        self.nextAction = nextAction
    }

    init(evidence: PocketConnectionEvidence) {
        if evidence.discoveryPhase == .starting {
            self = Self(
                kind: .lookingForPocket,
                title: "Looking for a DJI Osmo Pocket…",
                detail: "Passive USB detection is in progress.",
                severity: .neutral,
                systemImage: "magnifyingglass",
                nextAction: nil
            )
            return
        }

        guard let identification = evidence.identification else {
            if evidence.didDisconnectAfterConnection {
                self = Self(
                    kind: .disconnected,
                    title: "Pocket disconnected.",
                    detail: "Reconnect the camera, then refresh detection.",
                    severity: .attention,
                    systemImage: "cable.connector.slash",
                    nextAction: .refreshDetection
                )
            } else {
                self = Self(
                    kind: .noPocketConnected,
                    title: "No Pocket connected",
                    detail: "Connect a DJI Osmo Pocket by USB-C, then refresh detection.",
                    severity: .neutral,
                    systemImage: "camera",
                    nextAction: .refreshDetection
                )
            }
            return
        }

        guard identification.supportsPocket4ControlProfile else {
            self = Self(
                kind: .unsupportedPocketFamily,
                title: "DJI Osmo Pocket detected. This model is not supported for control yet.",
                detail: "Detection remains informational; controls are unavailable for this profile.",
                severity: .warning,
                systemImage: "exclamationmark.triangle",
                nextAction: .openDiagnostics
            )
            return
        }

        switch evidence.cameraAuthorization {
        case .denied, .restricted:
            self = Self(
                kind: .cameraAccessUnavailable,
                title: "Camera access is unavailable. USB detection still works, but preview cannot start.",
                detail: "Open Diagnostics to review the current connection.",
                severity: .warning,
                systemImage: "camera.badge.exclamationmark",
                nextAction: .openDiagnostics
            )
            return

        case .notDetermined:
            self = Self(
                kind: .cameraAccessNeeded,
                title: "Pocket 4 detected. Allow camera access to use preview.",
                detail: "Camera access is requested only from an explicit Diagnostics action.",
                severity: .attention,
                systemImage: "camera.badge.ellipsis",
                nextAction: .openDiagnostics
            )
            return

        case .authorized:
            break
        }

        switch evidence.cameraMatchStatus {
        case .multiple:
            self = Self(
                kind: .multipleMatchingCameras,
                title: "More than one matching camera is connected. Choose a camera before preview or control.",
                detail: "Preview and direct inspection remain unavailable until selection is unambiguous.",
                severity: .warning,
                systemImage: "camera.badge.ellipsis",
                nextAction: .openDiagnostics
            )
            return

        case .none:
            self = Self(
                kind: .cameraNotVisible,
                title: "Pocket 4 USB device detected, but a video device is not visible. Confirm Webcam Mode on the camera.",
                detail: "USB detection remains active while macOS looks for a video device.",
                severity: .attention,
                systemImage: "video.slash",
                nextAction: .openDiagnostics
            )
            return

        case .notChecked, .single:
            break
        }

        // A blocked result belongs only to the connection generation that was
        // explicitly inspected. Stale results must never affect a replacement
        // or re-enumerated camera. A direct-UVC block is relevant only after a
        // single camera has been matched.
        if evidence.cameraMatchStatus == .single,
           evidence.directUVCAvailability == .blocked,
           evidence.directUVCAvailabilityGeneration == evidence.connectionGeneration
        {
            self = Self(
                kind: .directUVCUnavailable,
                title: "Camera is connected, but macOS did not provide safe direct UVC control access.",
                detail: "Preview availability is separate from direct control availability.",
                severity: .warning,
                systemImage: "slider.horizontal.3",
                nextAction: .openDiagnostics
            )
            return
        }

        self = Self(
            kind: .readyToContinueSetup,
            title: "Pocket 4 connected and ready to continue setup.",
            detail: "Open Diagnostics to continue setup; preview and control never start automatically.",
            severity: .ready,
            systemImage: "checkmark.circle.fill",
            nextAction: .openDiagnostics
        )
    }
}
