import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

protocol SessionClock: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

struct SystemSessionClock: SessionClock {
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// All platform-facing collaborators owned by a DeviceSession. The default
/// bundle uses the production AVFoundation, IORegistry, and direct-UVC paths;
/// the internal initializer lets the M0 test target replace every operation
/// that could otherwise touch hardware or TCC.
@MainActor
struct DeviceSessionDependencies {
    let makeMonitor: (@escaping @MainActor (PocketDevice?) -> Void) -> any DeviceMonitoring
    let camera: any CameraAccessing
    /// The live app supplies its one preview renderer. Tests use `nil` and a
    /// fake `PreviewControlling`, so no AVCaptureSession is constructed.
    let previewController: CameraPreviewController?
    let preview: any PreviewControlling
    let transport: any UVCTransporting
    let standardControls: any StandardControlInspecting
    let extensionUnit: any ExtensionUnitInspecting
    let clock: any SessionClock

    static func live() -> DeviceSessionDependencies {
        let transport = DirectUVCTransport()
        let previewController = CameraPreviewController()
        return DeviceSessionDependencies(
            makeMonitor: { onChange in
                PocketUSBRegistryMonitor(onChange: onChange)
            },
            camera: LiveCameraAccess(),
            previewController: previewController,
            preview: previewController,
            transport: transport,
            standardControls: UVCStandardControls(transport: transport),
            extensionUnit: DJIExtensionUnitInspector(transport: transport),
            clock: SystemSessionClock()
        )
    }
}

/// Thread-safe write lease used by `DirectUVCTransport` immediately before a
/// SET_CUR. Revocation and the bridge operation share one mutex, so an
/// explicit lock completes only after an already-authorized bridge call has
/// finished, or blocks the bridge call entirely.
private final class SessionWriteAuthorizer: @unchecked Sendable, UVCWriteAuthorizing {
    private let lock = NSLock()
    private var permittedConnection: UVCTransportConnection?

    func grant(for connection: UVCTransportConnection) {
        lock.lock()
        defer { lock.unlock() }
        permittedConnection = connection
    }

    func revoke() {
        lock.lock()
        defer { lock.unlock() }
        permittedConnection = nil
    }

    func revoke(ifMatches connection: UVCTransportConnection) {
        lock.lock()
        defer { lock.unlock() }
        guard permittedConnection == connection else {
            return
        }
        permittedConnection = nil
    }

    func performIfPermitted(
        for connection: UVCTransportConnection,
        operation: @Sendable () -> UVCRequestResult
    ) -> UVCRequestResult? {
        lock.lock()
        defer { lock.unlock() }
        guard permittedConnection == connection else {
            return nil
        }
        return operation()
    }
}

@MainActor
@Observable
final class DeviceSession {
    private enum PanTiltAxis: Hashable {
        case pan
        case tilt
    }

    var device: PocketDevice?
    var cameraAuthorization: CameraAuthorization = .notDetermined
    private(set) var passiveDiscoveryPhase: PassiveDiscoveryPhase = .starting
    private(set) var cameraMatchStatus: CameraMatchStatus = .notChecked
    private(set) var directUVCAvailability: DirectUVCAvailability = .unknown
    var cameraInfo: CameraDeviceInfo?
    var standardControls = UVCControlID.allCases.map { UVCStandardControlState.idle(control: $0) }
    var extensionUnitSelectors = (UInt8(1)...UInt8(3)).map { ExtensionUnitSelectorState.idle(selector: $0) }
    var snapshotA: ExtensionUnitSnapshot?
    var snapshotB: ExtensionUnitSnapshot?
    var isInspecting = false
    var isCapturingSnapshot = false
    var previewStatus = "Searching for a DJI Osmo Pocket"
    var includeRawExtensionUnitDataInExports = false
    var requestedZoom: Double?
    var requestedPan: Double?
    var requestedTilt: Double?
    var requestedRoll: Double?
    private(set) var isWriteModeEnabled = false
    private(set) var isPreviewRunning = false

    let logger = InvestigationLogger()
    let previewController: CameraPreviewController?

    @ObservationIgnored private let dependencies: DeviceSessionDependencies
    @ObservationIgnored private let directTransport: any UVCTransporting
    @ObservationIgnored private let standardControlService: any StandardControlInspecting
    @ObservationIgnored private let extensionUnitService: any ExtensionUnitInspecting
    @ObservationIgnored private let preview: any PreviewControlling
    @ObservationIgnored private let writeAuthorizer = SessionWriteAuthorizer()
    @ObservationIgnored private var usbMonitor: (any DeviceMonitoring)?
    @ObservationIgnored private var matchedPreviewSource: (any CameraPreviewSource)?
    @ObservationIgnored private var passiveDiscoveryGeneration: UInt64 = 0
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionTaskID: UUID?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTaskID: UUID?
    @ObservationIgnored private var selectorRefreshTasks: [UInt8: Task<Void, Never>] = [:]
    @ObservationIgnored private var selectorRefreshTaskIDs: [UInt8: UUID] = [:]
    @ObservationIgnored private var writeTasks: [UVCControlID: Task<Void, Never>] = [:]
    @ObservationIgnored private var writeTaskIDs: [UVCControlID: UUID] = [:]
    @ObservationIgnored private var writeModeTask: Task<Void, Never>?
    @ObservationIgnored private var writeModeTaskID: UUID?
    @ObservationIgnored private var transportSafetyTask: Task<Void, Never>?
    @ObservationIgnored private var transportSafetyTaskID: UUID?
    @ObservationIgnored private var pendingPanTiltAxes: Set<PanTiltAxis> = []
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    @ObservationIgnored private var directUVCAvailabilityGeneration: UInt64?
    @ObservationIgnored private var hasConnectedDeviceDuringDiscovery = false
    @ObservationIgnored private var hasPendingDeviceTransition = false
    @ObservationIgnored private var pendingDeviceTransition: PocketDevice?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var previewStartRequestedWhilePermissionPending = false
    @ObservationIgnored private var hasLoggedSessionStart = false

    convenience init() {
        self.init(dependencies: .live())
    }

    init(dependencies: DeviceSessionDependencies) {
        self.dependencies = dependencies
        previewController = dependencies.previewController
        preview = dependencies.preview
        directTransport = dependencies.transport
        standardControlService = dependencies.standardControls
        extensionUnitService = dependencies.extensionUnit
        cameraAuthorization = dependencies.camera.currentVideoAuthorization()
    }

    /// Passive: starts only the IORegistry monitor. It never requests camera
    /// permission, starts preview, activates direct UVC, or sends SET_CUR.
    func startPassiveDiscovery() {
        guard usbMonitor == nil else {
            return
        }

        passiveDiscoveryPhase = .starting
        hasConnectedDeviceDuringDiscovery = false
        cameraMatchStatus = .notChecked
        matchedPreviewSource = nil
        directUVCAvailability = .unknown
        directUVCAvailabilityGeneration = nil
        cameraAuthorization = dependencies.camera.currentVideoAuthorization()

        if !hasLoggedSessionStart {
            hasLoggedSessionStart = true
            logger.log("SESSION_STARTED", "Passive discovery starts without camera permission, preview, UVC I/O, or SET_CUR.")
        }

        passiveDiscoveryGeneration &+= 1
        let discoveryGeneration = passiveDiscoveryGeneration
        let monitor = dependencies.makeMonitor { [weak self] device in
            self?.handleUSBDeviceChange(device, discoveryGeneration: discoveryGeneration)
        }
        usbMonitor = monitor
        logger.log("USB_REGISTRY_MONITOR_STARTED", "Polling cached IORegistry properties every 1.5 seconds; no USB interface is opened.")
        monitor.start()
    }

    /// Safety: stops passive monitoring and tears down the active hardware
    /// session. A later wake/restart remains passive until the user acts.
    func stopPassiveDiscovery() {
        // Retire callbacks from this monitor before another wake can create a
        // replacement monitor. A queued old callback then has no owner.
        passiveDiscoveryGeneration &+= 1
        usbMonitor?.stop()
        usbMonitor = nil
        transitionTask?.cancel()
        hasPendingDeviceTransition = false
        pendingDeviceTransition = nil
        hasConnectedDeviceDuringDiscovery = false
        passiveDiscoveryPhase = .starting
        enterSafeState(
            reason: "PASSIVE_DISCOVERY_STOPPED",
            clearDevice: true,
            stopPreview: true
        )
        previewStatus = "Passive discovery stopped"
    }

    /// User-initiated and passive: asks the existing monitor for another
    /// IORegistry snapshot. It never requests permission, starts preview, or
    /// opens the UVC transport.
    func refreshPassiveDetection() {
        usbMonitor?.refresh()
    }

    var isPocketConnected: Bool {
        device != nil
    }

    var canEnableUVCWrites: Bool {
        device?.supportsPocket4ControlProfile == true
            && cameraMatchStatus != .multiple
            && standardControls.contains(where: \.isWriteReady)
            && device?.locationID != nil
    }

    var connectionPresentation: PocketConnectionPresentationState {
        PocketConnectionPresentationState(
            evidence: PocketConnectionEvidence(
                discoveryPhase: passiveDiscoveryPhase,
                identification: device?.identification,
                didDisconnectAfterConnection: hasConnectedDeviceDuringDiscovery && device == nil,
                cameraAuthorization: cameraAuthorization,
                cameraMatchStatus: cameraMatchStatus,
                directUVCAvailability: directUVCAvailability,
                connectionGeneration: connectionGeneration,
                directUVCAvailabilityGeneration: directUVCAvailabilityGeneration
            )
        )
    }

    var writeAvailabilityDescription: String {
        guard let device else {
            return "Connect a supported DJI Osmo Pocket 4 to inspect UVC controls."
        }

        guard device.supportsPocket4ControlProfile else {
            return "\(device.displayName) was detected automatically, but its UVC control profile has not been validated. Inspection and writes are blocked."
        }

        guard cameraMatchStatus != .multiple else {
            return "More than one matching camera is connected. Choose a camera before enabling direct UVC writes."
        }

        guard device.locationID != nil else {
            return "No usable USB Location ID is currently available."
        }

        if standardControls.contains(where: \.isWriteReady) {
            return "At least one control has a complete live GET_INFO/GET_MIN/GET_MAX/GET_RES/GET_DEF/GET_CUR validation."
        }

        return "Writes remain disabled until a direct UVC transport and a complete validated range are available."
    }

    var extensionDiff: ExtensionUnitDiff? {
        guard let snapshotA, let snapshotB else {
            return nil
        }
        return SnapshotService.diff(source: snapshotA, destination: snapshotB)
    }

    private var activeTransportConnection: UVCTransportConnection? {
        guard let device,
              device.supportsPocket4ControlProfile,
              let locationID = device.locationID
        else {
            return nil
        }

        return UVCTransportConnection(
            locationID: locationID,
            registryID: device.registryID,
            generation: connectionGeneration
        )
    }

    /// User-initiated: requests TCC video access only. It does not start
    /// preview or issue a UVC request by itself.
    func requestCameraPermission() {
        requestCameraPermission(startPreviewWhenAuthorized: false)
    }

    /// User-initiated: starts a local preview for the current verified Pocket
    /// 4. If camera access is undecided, this explicit action requests it
    /// first; passive discovery never does.
    func requestPreviewStart() {
        guard let device, device.supportsPocket4ControlProfile else {
            previewStatus = "Connect a verified Pocket 4 before starting preview"
            logger.log("PREVIEW_SKIPPED", "A verified Pocket 4 USB profile is required.")
            return
        }

        cameraAuthorization = dependencies.camera.currentVideoAuthorization()
        switch cameraAuthorization {
        case .authorized:
            configurePreview(for: device)
        case .notDetermined:
            previewStartRequestedWhilePermissionPending = true
            requestCameraPermission(startPreviewWhenAuthorized: true)
        case .denied, .restricted:
            previewStatus = "Camera permission \(cameraAuthorization.displayName.lowercased())"
            logger.log("PREVIEW_NOT_STARTED", "Camera permission is \(cameraAuthorization.displayName).")
        }
    }

    /// User-initiated: stops only the visible preview and leaves passive
    /// discovery intact.
    func stopPreview() {
        // Permission itself is user-initiated and may continue resolving, but
        // a stop cancels the pending request to start preview afterward.
        previewStartRequestedWhilePermissionPending = false
        preview.stop()
        isPreviewRunning = false
        previewStatus = "Preview stopped"
        logger.log("PREVIEW_STOPPED")
    }

    /// User-initiated and read-only: performs the validated UVC GET sequence
    /// for the current verified connection. It never sends SET_CUR.
    func refreshReadOnlyInspection() {
        guard let device, device.supportsPocket4ControlProfile,
              cameraMatchStatus != .multiple,
              let connection = activeTransportConnection
        else {
            logger.log("INSPECTION_SKIPPED", "A verified Pocket 4 USB control profile, an unambiguous camera match, and a Location ID are required.")
            return
        }

        startInspection(for: device, connection: connection)
    }

    /// Compatibility for the existing command surface. New callers should use
    /// the explicit read-only intent above.
    func refreshInspection() {
        refreshReadOnlyInspection()
    }

    /// Semantic write-mode entry point for SwiftUI controls. Enabling the
    /// latch is never a write; a later, deliberate control interaction is.
    func setWriteModeEnabled(_ enabled: Bool) {
        enabled ? unlockWrites() : lockWrites()
    }

    func unlockWrites() {
        guard canEnableUVCWrites, let connection = activeTransportConnection else {
            isWriteModeEnabled = false
            logger.log("UVC_WRITE_MODE_REJECTED", writeAvailabilityDescription)
            return
        }

        writeModeTask?.cancel()
        let taskID = UUID()
        let precedingSafetyTask = transportSafetyTask
        writeModeTaskID = taskID
        isWriteModeEnabled = true
        writeModeTask = Task { [weak self, directTransport] in
            await precedingSafetyTask?.value
            guard let self,
                  !Task.isCancelled,
                  self.isWriteModeEnabled,
                  self.activeTransportConnection == connection,
                  self.writeModeTaskID == taskID
            else {
                return
            }

            await directTransport.activate(connection)
            guard !Task.isCancelled,
                  self.isWriteModeEnabled,
                  self.activeTransportConnection == connection,
                  self.writeModeTaskID == taskID
            else {
                // This condition only changes the latch if this stale task
                // still owns the active connection; it cannot disable a newer
                // connection that was activated after re-enumeration.
                await directTransport.setWritesEnabled(false, for: connection)
                return
            }
            self.writeAuthorizer.grant(for: connection)
            await directTransport.setWritesEnabled(true, for: connection)
            guard !Task.isCancelled,
                  self.isWriteModeEnabled,
                  self.activeTransportConnection == connection,
                  self.writeModeTaskID == taskID
            else {
                self.writeAuthorizer.revoke(ifMatches: connection)
                await directTransport.setWritesEnabled(false, for: connection)
                return
            }
            self.writeModeTask = nil
            self.writeModeTaskID = nil
        }
        logger.log("UVC_WRITE_MODE_ENABLED", "Only validated Camera Terminal Zoom, Pan/Tilt, and Roll SET_CUR requests are allowed.")
    }

    /// Explicit lock is idempotent. It shares the cancellation and transport
    /// latch cleanup primitive with disconnect and lifecycle teardown while
    /// retaining the current passive connection and preview.
    func lockWrites() {
        enterSafeState(
            reason: "UVC_WRITE_MODE_DISABLED",
            clearDevice: false,
            stopPreview: false
        )
    }

    func refreshExtensionSelector(_ selector: UInt8) {
        guard let device, device.supportsPocket4ControlProfile,
              cameraMatchStatus != .multiple,
              let connection = activeTransportConnection
        else {
            logger.log("XU_REFRESH_SKIPPED", "A verified Pocket 4 USB control profile and an unambiguous camera match are required.")
            return
        }

        selectorRefreshTasks[selector]?.cancel()
        let taskID = UUID()
        selectorRefreshTaskIDs[selector] = taskID
        selectorRefreshTasks[selector] = Task { [weak self] in
            guard let self else {
                return
            }

            guard !Task.isCancelled,
                  self.activeTransportConnection == connection,
                  self.selectorRefreshTaskIDs[selector] == taskID
            else {
                return
            }
            await directTransport.activate(connection)
            guard !Task.isCancelled, self.activeTransportConnection == connection,
                  self.selectorRefreshTaskIDs[selector] == taskID
            else {
                return
            }

            let refreshed = await extensionUnitService.refresh(selector: selector, connection: connection)
            guard !Task.isCancelled,
                  self.activeTransportConnection == connection,
                  self.selectorRefreshTaskIDs[selector] == taskID
            else {
                return
            }

            if let index = extensionUnitSelectors.firstIndex(where: { $0.selector == selector }) {
                extensionUnitSelectors[index] = refreshed
            }
            logExtensionSelector(refreshed)
            selectorRefreshTasks[selector] = nil
            selectorRefreshTaskIDs[selector] = nil
        }
    }

    func captureSnapshotA() {
        captureSnapshot(label: "A")
    }

    func captureSnapshotB() {
        captureSnapshot(label: "B")
    }

    func scheduleZoom(_ value: Double) {
        requestedZoom = value
        scheduleWrite(for: .zoom)
    }

    func schedulePan(_ value: Double) {
        requestedPan = value
        pendingPanTiltAxes.insert(.pan)
        scheduleWrite(for: .panTilt)
    }

    func scheduleTilt(_ value: Double) {
        requestedTilt = value
        pendingPanTiltAxes.insert(.tilt)
        scheduleWrite(for: .panTilt)
    }

    func scheduleRoll(_ value: Double) {
        requestedRoll = value
        scheduleWrite(for: .roll)
    }

    func resetZoom() {
        guard case let .scalar(range)? = controlState(for: .zoom)?.range else {
            logger.log("RESET_ZOOM_SKIPPED", "GET_DEF is not available.")
            return
        }
        scheduleZoom(Double(range.defaultValue))
    }

    func resetPanTilt() {
        guard case let .vector(range)? = controlState(for: .panTilt)?.range else {
            logger.log("RESET_PANTILT_SKIPPED", "GET_DEF is not available.")
            return
        }

        requestedPan = Double(range.defaultValue.first)
        requestedTilt = Double(range.defaultValue.second)
        pendingPanTiltAxes = [.pan, .tilt]
        scheduleWrite(for: .panTilt)
    }

    func resetRoll() {
        guard case let .scalar(range)? = controlState(for: .roll)?.range else {
            logger.log("RESET_ROLL_SKIPPED", "GET_DEF is not available.")
            return
        }
        scheduleRoll(Double(range.defaultValue))
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportedLogText, forType: .string)
        let privacyMode = includeRawExtensionUnitDataInExports
            ? "including raw Extension Unit data and sensitive diagnostic details"
            : "with raw Extension Unit data and sensitive diagnostic details redacted"
        logger.log("LOG_COPIED", "\(logger.entries.count) line(s) copied to the clipboard \(privacyMode).")
    }

    func saveInvestigation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "PocketControlLab-\(fileSafeTimestamp()).txt"
        panel.message = "Save a local investigation log. Raw Extension Unit data and sensitive diagnostic details are redacted unless explicitly enabled."

        guard panel.runModal() == .OK, let url = panel.url else {
            logger.log("SAVE_INVESTIGATION_CANCELLED")
            return
        }

        do {
            try investigationText().write(to: url, atomically: true, encoding: .utf8)
            logger.log("SAVE_INVESTIGATION_SUCCESS", url.lastPathComponent)
        } catch {
            logger.log("SAVE_INVESTIGATION_FAILED", error.localizedDescription)
        }
    }

    private func requestCameraPermission(startPreviewWhenAuthorized: Bool) {
        if startPreviewWhenAuthorized {
            previewStartRequestedWhilePermissionPending = true
        }

        guard permissionTask == nil else {
            return
        }

        logger.log("CAMERA_PERMISSION_REQUESTED")
        permissionTask = Task { [weak self] in
            guard let self else {
                return
            }

            let authorization = await dependencies.camera.requestVideoAccess()
            guard !Task.isCancelled else {
                return
            }

            cameraAuthorization = authorization
            permissionTask = nil
            logger.log("CAMERA_PERMISSION_RESULT", authorization.displayName)

            let shouldStartPreview = previewStartRequestedWhilePermissionPending
            previewStartRequestedWhilePermissionPending = false
            if authorization == .authorized {
                if let device {
                    refreshCameraEvidence(for: device)
                }
                previewStatus = "Camera permission authorized — choose Start Preview"
                if shouldStartPreview {
                    requestPreviewStart()
                }
            } else {
                previewStatus = "Camera permission \(authorization.displayName.lowercased())"
            }
        }
    }

    private func handleUSBDeviceChange(
        _ replacement: PocketDevice?,
        discoveryGeneration: UInt64
    ) {
        // A monitor callback may already be enqueued when passive discovery
        // stops. It must not resurrect a device after the full safe teardown.
        guard usbMonitor != nil,
              passiveDiscoveryGeneration == discoveryGeneration
        else {
            return
        }

        passiveDiscoveryPhase = .active

        if hasPendingDeviceTransition {
            let pendingIdentity = pendingDeviceTransition?.connectionIdentity
            let replacementIdentity = replacement?.connectionIdentity
            if pendingIdentity == replacementIdentity {
                // A stable polling update arrived while the direct transport
                // invalidation for this same connection is still pending.
                // Keep the newest metadata, but never restart the transition.
                pendingDeviceTransition = replacement
                return
            }

            transitionTask?.cancel()
            hasPendingDeviceTransition = false
            pendingDeviceTransition = nil
        }

        let previousConnectionIdentity = device?.connectionIdentity
        let replacementConnectionIdentity = replacement?.connectionIdentity
        guard previousConnectionIdentity != replacementConnectionIdentity else {
            // A stable passive update may still reflect a TCC, AVFoundation,
            // or published-metadata change. It never restarts preview or UVC.
            device = replacement
            refreshCameraEvidence(for: replacement)
            return
        }

        transitionTask?.cancel()
        let generation = enterSafeState(
            reason: "DEVICE_CONNECTION_CHANGED",
            clearDevice: true,
            stopPreview: true
        )
        hasPendingDeviceTransition = true
        pendingDeviceTransition = replacement

        // Direct transport invalidation is awaited before a replacement is
        // published. That ordering prevents any delayed request from binding
        // to a re-enumerated camera at the same physical USB location.
        transitionTask = Task { [weak self, directTransport] in
            await directTransport.invalidate(upTo: generation)
            guard !Task.isCancelled else {
                return
            }
            self?.finishDeviceTransition(to: replacement, generation: generation)
        }
    }

    private func finishDeviceTransition(to replacement: PocketDevice?, generation: UInt64) {
        guard connectionGeneration == generation else {
            return
        }

        device = replacement
        transitionTask = nil
        hasPendingDeviceTransition = false
        pendingDeviceTransition = nil

        guard let replacement else {
            cameraMatchStatus = .notChecked
            matchedPreviewSource = nil
            previewStatus = "No DJI Osmo Pocket detected"
            logger.log("DEVICE_DISCONNECTED")
            return
        }

        hasConnectedDeviceDuringDiscovery = true
        cameraAuthorization = dependencies.camera.currentVideoAuthorization()

        logger.log("DEVICE_CONNECTED", replacement.identification.label)
        logger.log("USB_IDENTITY", "VID=0x\(replacement.formattedVendorID) PID=0x\(replacement.formattedProductID)")
        logger.log("USB_LINK", "\(replacement.linkSpeed.displayValue) · \(replacement.deviceState)")

        guard replacement.supportsPocket4ControlProfile else {
            cameraMatchStatus = .notChecked
            matchedPreviewSource = nil
            let reason = "\(replacement.displayName) was detected automatically, but this build has no validated Pocket 4 UVC control profile for it."
            logger.log("DEVICE_DETECTED_UNSUPPORTED_PROFILE", reason)
            previewStatus = "\(replacement.displayName) detected — controls unavailable"
            standardControls = UVCControlID.allCases.map {
                UVCStandardControlState.unavailable(control: $0, reason: reason)
            }
            extensionUnitSelectors = (UInt8(1)...UInt8(3)).map {
                ExtensionUnitSelectorState.unavailable(selector: $0, reason: reason)
            }
            return
        }

        refreshCameraEvidence(for: replacement)

        guard cameraMatchStatus != .multiple else {
            // `refreshCameraEvidence` has already retired any active control
            // capability. Do not overwrite its fail-closed Diagnostics state
            // with a generic ready message while matching is ambiguous.
            return
        }

        previewStatus = "Pocket 4 connected — choose Start Preview or Refresh Read-Only Inspection"
        logger.log("DEVICE_READY_FOR_EXPLICIT_ACTION")
    }

    /// Updates presentation evidence only. Both calls are read-only: the
    /// authorization query never prompts, and matching never constructs an
    /// AVCaptureSession, opens USB, or triggers UVC traffic.
    private func refreshCameraEvidence(for candidate: PocketDevice?) {
        cameraAuthorization = dependencies.camera.currentVideoAuthorization()

        guard let candidate, candidate.supportsPocket4ControlProfile else {
            cameraMatchStatus = .notChecked
            matchedPreviewSource = nil
            return
        }

        guard cameraAuthorization == .authorized else {
            cameraMatchStatus = .notChecked
            matchedPreviewSource = nil
            return
        }

        let previousMatchStatus = cameraMatchStatus
        switch dependencies.camera.cameraMatch(for: candidate) {
        case .none:
            cameraMatchStatus = .none
            matchedPreviewSource = nil
        case let .single(source):
            cameraMatchStatus = .single
            matchedPreviewSource = source
        case .multiple:
            cameraMatchStatus = .multiple
            matchedPreviewSource = nil
        }

        // A transition from an unambiguous camera to ambiguity must fail
        // closed: stop preview, revoke writes, cancel direct work, and retire
        // the transport generation. It does not select a candidate.
        if cameraMatchStatus == .multiple, previousMatchStatus != .multiple {
            previewStatus = "More than one matching camera is connected"
            enterSafeState(
                reason: "CAMERA_MATCH_AMBIGUOUS",
                clearDevice: false,
                stopPreview: true
            )
        }
    }

    @discardableResult
    private func enterSafeState(
        reason: String,
        clearDevice: Bool,
        stopPreview: Bool
    ) -> UInt64 {
        // A safe transition always retires the capability token, including an
        // explicit lock on a still-connected device. That makes delayed
        // inspection, snapshot, and write results stale even when the USB
        // registry identity itself has not changed.
        connectionGeneration &+= 1
        let invalidationGeneration = connectionGeneration
        directUVCAvailability = .unknown
        directUVCAvailabilityGeneration = nil

        isWriteModeEnabled = false
        writeAuthorizer.revoke()
        cancelPendingWork()
        transportSafetyTask?.cancel()
        let taskID = UUID()
        transportSafetyTaskID = taskID
        transportSafetyTask = Task { [weak self, directTransport] in
            guard let self,
                  !Task.isCancelled,
                  self.transportSafetyTaskID == taskID
            else {
                return
            }

            // Invalidation also drops the transport's write latch. Passing a
            // generation makes an old teardown a no-op for a newer activation.
            await directTransport.invalidate(upTo: invalidationGeneration)
            guard !Task.isCancelled,
                  self.transportSafetyTaskID == taskID
            else {
                return
            }
            self.transportSafetyTask = nil
            self.transportSafetyTaskID = nil
        }

        if stopPreview {
            preview.stop()
            isPreviewRunning = false
        }

        if clearDevice {
            device = nil
            cameraInfo = nil
            cameraMatchStatus = .notChecked
            matchedPreviewSource = nil
            resetProtocolState(
                controls: UVCControlID.allCases.map { UVCStandardControlState.idle(control: $0) },
                selectors: (UInt8(1)...UInt8(3)).map { ExtensionUnitSelectorState.idle(selector: $0) }
            )
        }

        logger.log(reason)
        return connectionGeneration
    }

    private func cancelPendingWork() {
        permissionTask?.cancel()
        permissionTask = nil
        previewStartRequestedWhilePermissionPending = false
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionTaskID = nil
        selectorRefreshTasks.values.forEach { $0.cancel() }
        selectorRefreshTasks.removeAll()
        selectorRefreshTaskIDs.removeAll()
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotTaskID = nil
        writeTasks.values.forEach { $0.cancel() }
        writeTasks.removeAll()
        writeTaskIDs.removeAll()
        writeModeTask?.cancel()
        writeModeTask = nil
        writeModeTaskID = nil
        isInspecting = false
        isCapturingSnapshot = false
        pendingPanTiltAxes.removeAll()
    }

    private func resetProtocolState(
        controls: [UVCStandardControlState],
        selectors: [ExtensionUnitSelectorState]
    ) {
        requestedZoom = nil
        requestedPan = nil
        requestedTilt = nil
        requestedRoll = nil
        snapshotA = nil
        snapshotB = nil
        standardControls = controls
        extensionUnitSelectors = selectors
    }

    private func configurePreview(for device: PocketDevice) {
        refreshCameraEvidence(for: device)

        guard cameraMatchStatus != .multiple else {
            cameraInfo = nil
            previewStatus = "More than one matching camera is connected"
            logger.log("PREVIEW_SKIPPED", "AVFoundation matching is ambiguous; preview remains fail-closed.")
            return
        }

        guard let source = matchedPreviewSource else {
            cameraInfo = nil
            previewStatus = "Pocket 4 video device not visible to AVFoundation"
            logger.log("AVCAPTURE_DEVICE_NOT_FOUND")
            return
        }

        cameraInfo = source.cameraInfo
        logger.log("AVCAPTURE_DEVICE_FOUND", "Compatible external video device matched.")

        do {
            try preview.start(source: source)
            isPreviewRunning = preview.isRunning
            previewStatus = "Preview started"
            logger.log("PREVIEW_STARTED", cameraInfo?.activeFormat.displayName)
        } catch {
            isPreviewRunning = false
            previewStatus = "Preview failed: \(error.localizedDescription)"
            logger.log("PREVIEW_FAILED", error.localizedDescription)
        }
    }

    private func startInspection(for device: PocketDevice, connection: UVCTransportConnection) {
        guard device.supportsPocket4ControlProfile else {
            logger.log("INSPECTION_SKIPPED", "The detected DJI Osmo Pocket does not have a validated Pocket 4 control profile.")
            return
        }

        inspectionTask?.cancel()
        let taskID = UUID()
        inspectionTaskID = taskID
        isInspecting = true
        // A new explicit inspection supersedes any previous availability
        // result. Rendering this reset remains passive; only the task below
        // is allowed to activate the transport and perform GET requests.
        directUVCAvailability = .unknown
        directUVCAvailabilityGeneration = nil
        let cmioObservations = dependencies.camera.inspectStandardControls(camera: cameraInfo, pocket: device)

        if cmioObservations.isEmpty {
            logger.log("CMIO_CONTROLS_NOT_EXPOSED")
        } else {
            for observation in cmioObservations.values.sorted(by: { $0.controlName < $1.controlName }) {
                logger.log(
                    "CMIO_CONTROL_FOUND",
                    "\(observation.controlName) · \(observation.className) · settable=\(observation.isSettable.map { String($0) } ?? "unknown")"
                )
            }
        }

        inspectionTask = Task { [weak self] in
            guard let self else {
                return
            }

            guard !Task.isCancelled else {
                return
            }
            await directTransport.invalidate(upTo: connection.generation)
            guard !Task.isCancelled,
                  self.activeTransportConnection == connection,
                  self.inspectionTaskID == taskID
            else {
                return
            }
            await directTransport.activate(connection)
            guard !Task.isCancelled,
                  self.activeTransportConnection == connection,
                  self.inspectionTaskID == taskID
            else {
                return
            }

            let controls = await standardControlService.inspect(
                connection: connection,
                cmioObservations: cmioObservations
            )
            let extensionUnit = await extensionUnitService.inspectAll(connection: connection)
            let availability = await directTransport.availability(for: connection)

            guard !Task.isCancelled,
                  self.activeTransportConnection == connection,
                  self.inspectionTaskID == taskID
            else {
                return
            }

            standardControls = controls
            extensionUnitSelectors = extensionUnit
            directUVCAvailability = availability
            directUVCAvailabilityGeneration = connection.generation
            pendingPanTiltAxes.removeAll()
            seedRequestedValues(from: controls)
            isInspecting = false
            inspectionTask = nil
            inspectionTaskID = nil
            logStandardControls(controls)
            extensionUnit.forEach(logExtensionSelector)
        }
    }

    private func captureSnapshot(label: String) {
        guard let device, device.supportsPocket4ControlProfile,
              cameraMatchStatus != .multiple,
              let connection = activeTransportConnection
        else {
            logger.log("SNAPSHOT_\(label)_SKIPPED", "A verified Pocket 4 USB control profile and an unambiguous camera match are required.")
            return
        }

        snapshotTask?.cancel()
        let taskID = UUID()
        snapshotTaskID = taskID
        isCapturingSnapshot = true
        snapshotTask = Task { [weak self] in
            guard let self else {
                return
            }

            guard !Task.isCancelled,
                  self.activeTransportConnection == connection,
                  self.snapshotTaskID == taskID
            else {
                return
            }
            await directTransport.activate(connection)
            guard !Task.isCancelled,
                  self.activeTransportConnection == connection,
                  self.snapshotTaskID == taskID
            else {
                return
            }

            let selectors = await extensionUnitService.inspectAll(connection: connection)
            guard !Task.isCancelled,
                  self.activeTransportConnection == connection,
                  self.snapshotTaskID == taskID
            else {
                return
            }

            extensionUnitSelectors = selectors
            let snapshot = SnapshotService.capture(label: label, selectors: selectors)
            if label == "A" {
                snapshotA = snapshot
            } else {
                snapshotB = snapshot
            }
            isCapturingSnapshot = false
            snapshotTask = nil
            snapshotTaskID = nil
            logger.log("SNAPSHOT_\(label)_CAPTURED", "Captured \(selectors.count) Extension Unit selector state(s).")
            selectors.forEach(logExtensionSelector)
        }
    }

    private func scheduleWrite(for control: UVCControlID) {
        guard isWriteModeEnabled, let connection = activeTransportConnection else {
            logger.log("UVC_WRITE_SKIPPED", "Enable UVC writes before requesting \(control.displayName).")
            return
        }

        guard controlState(for: control)?.isWriteReady == true else {
            logger.log("UVC_WRITE_SKIPPED", "\(control.displayName) does not have a complete validated live range.")
            return
        }

        writeTasks[control]?.cancel()
        let taskID = UUID()
        writeTaskIDs[control] = taskID
        let clock = dependencies.clock
        writeTasks[control] = Task { [weak self, clock] in
            do {
                try await clock.sleep(nanoseconds: 75_000_000)
            } catch {
                self?.finishScheduledWrite(for: control, taskID: taskID)
                return
            }

            guard !Task.isCancelled else {
                self?.finishScheduledWrite(for: control, taskID: taskID)
                return
            }
            await self?.performScheduledWrite(
                for: control,
                connection: connection,
                taskID: taskID
            )
        }
    }

    private func performScheduledWrite(
        for control: UVCControlID,
        connection: UVCTransportConnection,
        taskID: UUID
    ) async {
        guard !Task.isCancelled,
              writeTaskIDs[control] == taskID,
              isWriteModeEnabled,
              activeTransportConnection == connection,
              let state = controlState(for: control),
              state.isWriteReady
        else {
            finishScheduledWrite(for: control, taskID: taskID)
            return
        }

        // Defence in depth: the transport independently refuses SET_CUR unless
        // this explicit user-controlled mode is still enabled.
        await directTransport.setWritesEnabled(true, for: connection)
        guard !Task.isCancelled,
              writeTaskIDs[control] == taskID,
              isWriteModeEnabled,
              activeTransportConnection == connection
        else {
            await directTransport.setWritesEnabled(false, for: connection)
            finishScheduledWrite(for: control, taskID: taskID)
            return
        }

        switch (control, state.range) {
        case let (.zoom, .some(.scalar(range))):
            let requested = quantize(requestedZoom ?? Double(range.currentValue), range: range)
            let outcome = await standardControlService.setScalar(
                control: .zoom,
                value: requested,
                connection: connection,
                writeAuthorization: writeAuthorizer
            )
            guard shouldApplyScheduledWrite(for: control, connection: connection, taskID: taskID) else {
                finishScheduledWrite(for: control, taskID: taskID)
                return
            }
            applyWriteOutcome(outcome, for: connection)
            finishScheduledWrite(for: control, taskID: taskID)
        case let (.roll, .some(.scalar(range))):
            let requested = quantize(requestedRoll ?? Double(range.currentValue), range: range)
            let outcome = await standardControlService.setScalar(
                control: .roll,
                value: requested,
                connection: connection,
                writeAuthorization: writeAuthorizer
            )
            guard shouldApplyScheduledWrite(for: control, connection: connection, taskID: taskID) else {
                finishScheduledWrite(for: control, taskID: taskID)
                return
            }
            applyWriteOutcome(outcome, for: connection)
            finishScheduledWrite(for: control, taskID: taskID)
        case let (.panTilt, .some(.vector(range))):
            let changedAxes = pendingPanTiltAxes
            guard !changedAxes.isEmpty else {
                finishScheduledWrite(for: control, taskID: taskID)
                return
            }

            // Consume the current batch before awaiting USB I/O. A new slider
            // gesture that arrives during the request remains pending for the
            // next debounced write instead of being accidentally discarded.
            pendingPanTiltAxes.subtract(changedAxes)

            let pan = changedAxes.contains(.pan)
                ? quantize(
                    requestedPan ?? Double(range.currentValue.first),
                    minimum: Int64(range.minimum.first),
                    maximum: Int64(range.maximum.first),
                    resolution: Int64(range.resolution.first)
                ).flatMap { Int32(exactly: $0) }
                : nil
            let tilt = changedAxes.contains(.tilt)
                ? quantize(
                    requestedTilt ?? Double(range.currentValue.second),
                    minimum: Int64(range.minimum.second),
                    maximum: Int64(range.maximum.second),
                    resolution: Int64(range.resolution.second)
                ).flatMap { Int32(exactly: $0) }
                : nil
            let outcome = await standardControlService.setPanTilt(
                pan: pan,
                tilt: tilt,
                connection: connection,
                writeAuthorization: writeAuthorizer
            )
            guard shouldApplyScheduledWrite(for: control, connection: connection, taskID: taskID) else {
                finishScheduledWrite(for: control, taskID: taskID)
                return
            }
            applyWriteOutcome(outcome, for: connection)
            finishScheduledWrite(for: control, taskID: taskID)
        default:
            logger.log("UVC_WRITE_SKIPPED", "\(control.displayName) has no compatible validated range.")
            finishScheduledWrite(for: control, taskID: taskID)
        }
    }

    private func shouldApplyScheduledWrite(
        for control: UVCControlID,
        connection: UVCTransportConnection,
        taskID: UUID
    ) -> Bool {
        !Task.isCancelled
            && writeTaskIDs[control] == taskID
            && isWriteModeEnabled
            && activeTransportConnection == connection
    }

    private func finishScheduledWrite(for control: UVCControlID, taskID: UUID) {
        guard writeTaskIDs[control] == taskID else {
            return
        }
        writeTasks[control] = nil
        writeTaskIDs[control] = nil
    }

    private func applyWriteOutcome(
        _ outcome: UVCWriteOutcome,
        for connection: UVCTransportConnection
    ) {
        guard activeTransportConnection == connection else {
            logger.log("UVC_WRITE_RESULT_DISCARDED", "The USB connection changed before the result was applied.")
            return
        }

        logger.log("UVC_GET_CUR \(outcome.control.rawValue)", "old=\(outcome.oldValue.statusDescription)")
        logger.log("UVC_SET_CUR \(outcome.control.rawValue)", "requested=\(outcome.requestedDescription)")

        if let setResult = outcome.setResult {
            logger.log("UVC_SET_CUR_RESULT \(outcome.control.rawValue)", setResult.statusDescription)
        } else {
            logger.log("UVC_SET_CUR_RESULT \(outcome.control.rawValue)", "Not sent.")
        }

        if let resultingValue = outcome.resultingValue {
            logger.log("UVC_GET_CUR_AFTER \(outcome.control.rawValue)", resultingValue.statusDescription)
            updateCurrentValue(for: outcome.control, result: resultingValue)
        }

        if outcome.control == .panTilt || outcome.control == .roll {
            logger.log(
                "PHYSICAL_MOVEMENT_UNVERIFIED",
                "Please visually verify whether the physical gimbal moved. The software does not infer physical movement from SET_CUR acceptance."
            )
        }
    }

    private func logStandardControls(_ controls: [UVCStandardControlState]) {
        for control in controls {
            logger.log("UVC_CAPABILITY \(control.control.rawValue)", control.capability.label)
            logger.log("UVC_GET_INFO \(control.control.rawValue)", control.getInfo.statusDescription)
            logger.log("UVC_GET_MIN \(control.control.rawValue)", control.minimum.statusDescription)
            logger.log("UVC_GET_MAX \(control.control.rawValue)", control.maximum.statusDescription)
            logger.log("UVC_GET_RES \(control.control.rawValue)", control.resolution.statusDescription)
            logger.log("UVC_GET_DEF \(control.control.rawValue)", control.defaultValue.statusDescription)
            logger.log("UVC_GET_CUR \(control.control.rawValue)", control.currentValue.statusDescription)
        }
    }

    private func logExtensionSelector(_ selector: ExtensionUnitSelectorState) {
        logger.log("XU_SELECTOR_\(selector.selector)_CAPABILITY", selector.capability.label)
        logger.log("XU_GET_INFO selector=\(selector.selector)", selector.getInfo.statusDescription)
        logger.log("XU_GET_LEN selector=\(selector.selector)", selector.getLength.statusDescription)
        logger.log("XU_GET_CUR selector=\(selector.selector)", selector.currentValue.statusDescription)
    }

    private func seedRequestedValues(from controls: [UVCStandardControlState]) {
        for control in controls {
            switch control.range {
            case let .scalar(range) where control.control == .zoom:
                requestedZoom = Double(range.currentValue)
            case let .scalar(range) where control.control == .roll:
                requestedRoll = Double(range.currentValue)
            case let .vector(range) where control.control == .panTilt:
                requestedPan = Double(range.currentValue.first)
                requestedTilt = Double(range.currentValue.second)
            default:
                break
            }
        }
    }

    private func updateCurrentValue(for control: UVCControlID, result: UVCRequestResult) {
        guard let index = standardControls.firstIndex(where: { $0.control == control }) else {
            return
        }
        standardControls[index].currentValue = result
    }

    private func controlState(for control: UVCControlID) -> UVCStandardControlState? {
        standardControls.first(where: { $0.control == control })
    }

    private func quantize(_ value: Double, range: UVCScalarRange) -> Int64 {
        quantize(
            value,
            minimum: range.minimum,
            maximum: range.maximum,
            resolution: range.resolution
        ) ?? range.currentValue
    }

    private func quantize(
        _ value: Double,
        minimum: Int64,
        maximum: Int64,
        resolution: Int64
    ) -> Int64? {
        guard resolution > 0 else {
            return nil
        }

        let clamped = min(max(value, Double(minimum)), Double(maximum))
        let steps = ((clamped - Double(minimum)) / Double(resolution)).rounded()
        let quantized = Double(minimum) + steps * Double(resolution)
        return Int64(quantized.rounded())
    }

    private func investigationText() -> String {
        var sections: [String] = [
            "Pocket Control Lab Investigation",
            "Generated: \(Date.now.formatted(date: .abbreviated, time: .standard))",
            "",
            "Device",
        ]

        if let device {
            sections.append("Name: \(device.displayName)")
            sections.append("Identification: \(device.identification.label)")
            sections.append("VID: \(device.formattedVendorID) PID: \(device.formattedProductID)")
            sections.append("USB: \(device.linkSpeed.displayValue)")
        } else {
            sections.append("No DJI Osmo Pocket detected.")
        }

        sections.append("")
        sections.append("Log")
        sections.append(exportedLogText)
        return sections.joined(separator: "\n")
    }

    private var exportedLogText: String {
        logger.renderedText(includeRawExtensionUnitData: includeRawExtensionUnitDataInExports)
    }

    private func fileSafeTimestamp() -> String {
        Date.now.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: ":", with: "")
    }
}
