import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class PocketLabModel {
    private enum PanTiltAxis: Hashable {
        case pan
        case tilt
    }

    var device: PocketDevice?
    var cameraAuthorization: CameraAuthorization = .notDetermined
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
    var isWriteModeEnabled = false {
        didSet {
            guard isWriteModeEnabled else {
                Task { [directTransport] in
                    await directTransport.disableWrites()
                }
                logger.log("UVC_WRITE_MODE_DISABLED")
                return
            }

            guard canEnableUVCWrites, let connection = activeTransportConnection else {
                isWriteModeEnabled = false
                logger.log("UVC_WRITE_MODE_REJECTED", writeAvailabilityDescription)
                return
            }

            Task { [directTransport] in
                await directTransport.setWritesEnabled(true, for: connection)
            }
            logger.log("UVC_WRITE_MODE_ENABLED", "Only validated Camera Terminal Zoom, Pan/Tilt, and Roll SET_CUR requests are allowed.")
        }
    }

    let logger = InvestigationLogger()
    let previewController = CameraPreviewController()

    @ObservationIgnored private let directTransport: DirectUVCTransport
    @ObservationIgnored private let standardControlService: UVCStandardControls
    @ObservationIgnored private let extensionUnitService: DJIExtensionUnitInspector
    @ObservationIgnored private var usbMonitor: PocketUSBRegistryMonitor?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTaskID: UUID?
    @ObservationIgnored private var writeTasks: [UVCControlID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingPanTiltAxes: Set<PanTiltAxis> = []
    @ObservationIgnored private var connectionGeneration: UInt64 = 0

    init() {
        let directTransport = DirectUVCTransport()
        self.directTransport = directTransport
        standardControlService = UVCStandardControls(transport: directTransport)
        extensionUnitService = DJIExtensionUnitInspector(transport: directTransport)
    }

    func start() {
        guard bootstrapTask == nil else {
            return
        }

        logger.log("APP_STARTED", "No UVC SET_CUR request is sent automatically.")
        // USB discovery is intentionally independent of TCC camera access. It
        // only reads published IORegistry properties and lets the app show a
        // connected Pocket even when preview permission is denied.
        startUSBMonitoring()

        bootstrapTask = Task { [weak self] in
            guard let self else {
                return
            }

            logger.log("CAMERA_PERMISSION_REQUESTED")
            let authorization = await CameraDiscovery.requestVideoAccess()
            guard !Task.isCancelled else {
                return
            }

            cameraAuthorization = authorization
            logger.log("CAMERA_PERMISSION_RESULT", authorization.displayName)

            if authorization == .authorized {
                previewStatus = "Searching for a compatible DJI Osmo Pocket camera"
            } else {
                previewStatus = "Camera permission \(authorization.displayName.lowercased())"
            }

            reconcileCameraAuthorization()
        }
    }

    var isPocketConnected: Bool {
        device != nil
    }

    var canEnableUVCWrites: Bool {
        device?.supportsPocket4ControlProfile == true
            && standardControls.contains(where: \.isWriteReady)
            && device?.locationID != nil
    }

    var writeAvailabilityDescription: String {
        guard let device else {
            return "Connect a supported DJI Osmo Pocket 4 to inspect UVC controls."
        }

        guard device.supportsPocket4ControlProfile else {
            return "\(device.displayName) was detected automatically, but its UVC control profile has not been validated. Inspection and writes are blocked."
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

    func refreshInspection() {
        guard let device, device.supportsPocket4ControlProfile,
              let connection = activeTransportConnection
        else {
            logger.log("INSPECTION_SKIPPED", "A verified Pocket 4 USB control profile and Location ID are required.")
            return
        }

        startInspection(for: device, connection: connection)
    }

    func refreshExtensionSelector(_ selector: UInt8) {
        guard let device, device.supportsPocket4ControlProfile,
              let connection = activeTransportConnection
        else {
            logger.log("XU_REFRESH_SKIPPED", "A verified Pocket 4 USB control profile is required.")
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            let refreshed = await extensionUnitService.refresh(selector: selector, connection: connection)
            guard self.activeTransportConnection == connection
            else {
                return
            }

            if let index = extensionUnitSelectors.firstIndex(where: { $0.selector == selector }) {
                extensionUnitSelectors[index] = refreshed
            }
            logExtensionSelector(refreshed)
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

    private func startUSBMonitoring() {
        guard usbMonitor == nil else {
            return
        }

        let monitor = PocketUSBRegistryMonitor { [weak self] device in
            self?.handleUSBDeviceChange(device)
        }
        usbMonitor = monitor
        logger.log("USB_REGISTRY_MONITOR_STARTED", "Polling cached IORegistry properties every 1.5 seconds; no USB interface is opened.")
        monitor.start()
    }

    private func handleUSBDeviceChange(_ device: PocketDevice?) {
        let previousDevice = self.device
        let previousConnectionIdentity = previousDevice?.connectionIdentity
        let newConnectionIdentity = device?.connectionIdentity
        guard previousConnectionIdentity != newConnectionIdentity else {
            self.device = device
            return
        }

        // Invalidate the current transport before publishing a replacement
        // device. All async inspection/write paths carry this generation and
        // will fail closed if a camera re-enumerates at the same USB location.
        connectionGeneration &+= 1
        isWriteModeEnabled = false
        writeTasks.values.forEach { $0.cancel() }
        writeTasks.removeAll()
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotTaskID = nil
        isCapturingSnapshot = false
        pendingPanTiltAxes.removeAll()
        self.device = device

        guard let device else {
            guard previousDevice != nil else {
                return
            }

            logger.log("DEVICE_DISCONNECTED")
            previewController.stop()
            cameraInfo = nil
            previewStatus = "No DJI Osmo Pocket detected"
            resetProtocolState(
                controls: UVCControlID.allCases.map { UVCStandardControlState.idle(control: $0) },
                selectors: (UInt8(1)...UInt8(3)).map { ExtensionUnitSelectorState.idle(selector: $0) }
            )

            Task { [directTransport] in
                await directTransport.invalidate()
            }

            return
        }

        logger.log("DEVICE_CONNECTED", device.identification.label)
        logger.log("USB_IDENTITY", "VID=0x\(device.formattedVendorID) PID=0x\(device.formattedProductID)")
        logger.log("USB_LINK", "\(device.linkSpeed.displayValue) · \(device.deviceState)")

        guard device.supportsPocket4ControlProfile else {
            let reason = "\(device.displayName) was detected automatically, but this build has no validated Pocket 4 UVC control profile for it."
            logger.log("DEVICE_DETECTED_UNSUPPORTED_PROFILE", reason)
            previewController.stop()
            cameraInfo = nil
            previewStatus = "\(device.displayName) detected — controls unavailable"
            resetProtocolState(
                controls: UVCControlID.allCases.map { UVCStandardControlState.unavailable(control: $0, reason: reason) },
                selectors: (UInt8(1)...UInt8(3)).map { ExtensionUnitSelectorState.unavailable(selector: $0, reason: reason) }
            )

            Task { [directTransport] in
                await directTransport.invalidate()
            }

            return
        }

        guard cameraAuthorization != .notDetermined else {
            previewStatus = "Waiting for camera permission"
            logger.log("PREVIEW_WAITING_FOR_PERMISSION")
            return
        }

        activateVerifiedPocket4(device)
    }

    private func reconcileCameraAuthorization() {
        guard let device, device.supportsPocket4ControlProfile else {
            return
        }

        activateVerifiedPocket4(device)
    }

    private func activateVerifiedPocket4(_ device: PocketDevice) {
        guard device.supportsPocket4ControlProfile else {
            return
        }

        if cameraAuthorization == .authorized {
            configurePreview(for: device)
        } else {
            previewStatus = "Camera permission \(cameraAuthorization.displayName.lowercased())"
            logger.log("PREVIEW_NOT_STARTED", "Camera permission is \(cameraAuthorization.displayName).")
        }

        guard let connection = activeTransportConnection else {
            logger.log("INSPECTION_SKIPPED", "IORegistry did not publish a Location ID.")
            return
        }
        startInspection(for: device, connection: connection)
    }

    private func resetProtocolState(
        controls: [UVCStandardControlState],
        selectors: [ExtensionUnitSelectorState]
    ) {
        isWriteModeEnabled = false
        isInspecting = false
        isCapturingSnapshot = false
        inspectionTask?.cancel()
        inspectionTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotTaskID = nil
        writeTasks.values.forEach { $0.cancel() }
        writeTasks.removeAll()
        pendingPanTiltAxes.removeAll()
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
        guard let camera = CameraDiscovery.pocketCamera(for: device) else {
            cameraInfo = nil
            previewStatus = "Pocket 4 video device not visible to AVFoundation"
            logger.log("AVCAPTURE_DEVICE_NOT_FOUND")
            return
        }

        cameraInfo = CameraDiscovery.describe(camera)
        logger.log("AVCAPTURE_DEVICE_FOUND", "Compatible external video device matched.")

        do {
            try previewController.start(device: camera)
            previewStatus = "Preview started"
            logger.log("PREVIEW_STARTED", cameraInfo?.activeFormat.displayName)
        } catch {
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
        isInspecting = true
        let cmioObservations = CMIOStandardControlInspector.inspect(camera: cameraInfo, pocket: device)

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
            await directTransport.invalidate()
            guard !Task.isCancelled, self.activeTransportConnection == connection else {
                return
            }
            await directTransport.activate(connection)
            guard !Task.isCancelled, self.activeTransportConnection == connection else {
                return
            }

            let controls = await standardControlService.inspect(
                connection: connection,
                cmioObservations: cmioObservations
            )
            let extensionUnit = await extensionUnitService.inspectAll(connection: connection)

            guard !Task.isCancelled, self.activeTransportConnection == connection else {
                return
            }

            standardControls = controls
            extensionUnitSelectors = extensionUnit
            pendingPanTiltAxes.removeAll()
            seedRequestedValues(from: controls)
            isInspecting = false
            logStandardControls(controls)
            extensionUnit.forEach(logExtensionSelector)
        }
    }

    private func captureSnapshot(label: String) {
        guard let device, device.supportsPocket4ControlProfile,
              let connection = activeTransportConnection
        else {
            logger.log("SNAPSHOT_\(label)_SKIPPED", "A verified Pocket 4 USB control profile is required.")
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
        guard isWriteModeEnabled else {
            logger.log("UVC_WRITE_SKIPPED", "Enable UVC writes before requesting \(control.displayName).")
            return
        }

        guard controlState(for: control)?.isWriteReady == true else {
            logger.log("UVC_WRITE_SKIPPED", "\(control.displayName) does not have a complete validated live range.")
            return
        }

        writeTasks[control]?.cancel()
        writeTasks[control] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }
            await self?.performScheduledWrite(for: control)
        }
    }

    private func performScheduledWrite(for control: UVCControlID) async {
        guard isWriteModeEnabled,
              let connection = activeTransportConnection,
              let state = controlState(for: control),
              state.isWriteReady
        else {
            return
        }

        // Defence in depth: the transport independently refuses SET_CUR unless
        // this explicit user-controlled mode is still enabled.
        await directTransport.setWritesEnabled(true, for: connection)
        guard isWriteModeEnabled, activeTransportConnection == connection else {
            return
        }

        switch (control, state.range) {
        case let (.zoom, .some(.scalar(range))):
            let requested = quantize(requestedZoom ?? Double(range.currentValue), range: range)
            let outcome = await standardControlService.setScalar(control: .zoom, value: requested, connection: connection)
            applyWriteOutcome(outcome, for: connection)
        case let (.roll, .some(.scalar(range))):
            let requested = quantize(requestedRoll ?? Double(range.currentValue), range: range)
            let outcome = await standardControlService.setScalar(control: .roll, value: requested, connection: connection)
            applyWriteOutcome(outcome, for: connection)
        case let (.panTilt, .some(.vector(range))):
            let changedAxes = pendingPanTiltAxes
            guard !changedAxes.isEmpty else {
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
            let outcome = await standardControlService.setPanTilt(pan: pan, tilt: tilt, connection: connection)
            applyWriteOutcome(outcome, for: connection)
        default:
            logger.log("UVC_WRITE_SKIPPED", "\(control.displayName) has no compatible validated range.")
        }
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
