import Foundation
import Testing

@testable import PocketControlLab

private enum ExpectedUVCPolicyContract {
    static let videoControlInterfaceNumber: UInt8 = 0
    static let cameraTerminalEntityID: UInt8 = 1
    static let extensionUnitEntityID: UInt8 = 6
    static let maximumExtensionUnitReadLength = 1024

    static let zoomSelector: UInt8 = 0x0B
    static let panTiltSelector: UInt8 = 0x0D
    static let rollSelector: UInt8 = 0x0F

    static let scalarPayloadLength = 2
    static let panTiltPayloadLength = 8
}

struct PocketControlLabTests {
    @Test("Passive discovery is idempotent and never enters the control plane")
    @MainActor
    func passiveDiscoveryIsIdempotentAndPassive() async {
        let fixture = makeFixture()

        fixture.session.startPassiveDiscovery()
        fixture.session.startPassiveDiscovery()

        #expect(fixture.monitorFactory.monitorCount == 1)
        #expect(fixture.monitorFactory.latestMonitor?.startCount == 1)
        #expect(fixture.camera.permissionRequestCount == 0)
        #expect(fixture.preview.startCount == 0)
        #expect(fixture.preview.stopCount == 0)

        let operations = await fixture.transport.operationSnapshot()
        let standardInspectionCount = await fixture.standardInspector?.inspectionCount()
        let extensionInspectionCount = await fixture.extensionInspector?.inspectionCount()
        #expect(operations.isEmpty)
        #expect(standardInspectionCount == 0)
        #expect(extensionInspectionCount == 0)

        fixture.session.stopPassiveDiscovery()
    }

    @Test("An explicit preview request asks for permission, but denial never starts preview")
    @MainActor
    func deniedPreviewRequestLeavesDiscoveryPassive() async {
        let fixture = makeFixture(cameraAuthorization: .denied)
        let device = verifiedPocket(registryID: 101)

        fixture.session.startPassiveDiscovery()
        fixture.monitorFactory.latestMonitor?.emit(device)
        #expect(await waitForDevice(fixture.session, registryID: device.registryID))

        fixture.session.requestPreviewStart()
        #expect(await waitForCameraPermissionRequest(fixture.camera))
        await drainTasks()

        #expect(fixture.camera.permissionRequestCount == 1)
        #expect(fixture.session.cameraAuthorization == .denied)
        #expect(fixture.preview.startCount == 0)
        #expect(fixture.preview.stopCount == 1) // Connection transition, not a preview start.
        #expect(!fixture.session.isPreviewRunning)
        #expect(fixture.session.isPocketConnected)

        let requests = await fixture.transport.requestSnapshot()
        #expect(requests.isEmpty)

        fixture.session.stopPassiveDiscovery()
    }

    @Test("An authorized preview starts only after the explicit preview intent")
    @MainActor
    func authorizedPreviewStartsThroughInjectedPreviewSource() async {
        let fixture = makeFixture(cameraAuthorization: .authorized)
        let device = verifiedPocket(registryID: 102)

        fixture.session.startPassiveDiscovery()
        fixture.monitorFactory.latestMonitor?.emit(device)
        #expect(await waitForDevice(fixture.session, registryID: device.registryID))

        #expect(fixture.preview.startCount == 0)
        fixture.session.requestPreviewStart()
        #expect(await waitForPreviewStart(fixture.preview))

        #expect(fixture.camera.permissionRequestCount == 1)
        #expect(fixture.camera.previewSourceRequestCount == 1)
        #expect(fixture.session.isPreviewRunning)
        #expect(fixture.session.previewStatus == "Preview started")

        fixture.session.stopPreview()
        #expect(!fixture.session.isPreviewRunning)
        #expect(fixture.preview.stopCount >= 2)

        fixture.session.stopPassiveDiscovery()
    }

    @Test("Read-only inspection is gated to a verified device and sends no SET_CUR")
    @MainActor
    func readOnlyInspectionRequiresVerifiedDeviceAndUsesOnlyGets() async {
        let fixture = makeFixture(useProductionReadOnlyInspectors: true)
        let unsupported = unverifiedPocket(registryID: 201)
        let verified = verifiedPocket(registryID: 202)

        fixture.session.startPassiveDiscovery()
        fixture.monitorFactory.latestMonitor?.emit(unsupported)
        #expect(await waitForDevice(fixture.session, registryID: unsupported.registryID))

        fixture.session.refreshReadOnlyInspection()
        await drainTasks()
        let requestsWhileUnsupported = await fixture.transport.requestSnapshot()
        #expect(requestsWhileUnsupported.isEmpty)

        fixture.monitorFactory.latestMonitor?.emit(verified)
        #expect(await waitForDevice(fixture.session, registryID: verified.registryID))

        fixture.session.refreshReadOnlyInspection()
        #expect(await waitForInspectionToFinish(fixture.session, transport: fixture.transport))

        let requests = await fixture.transport.requestSnapshot()
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.request != .setCurrent })
        #expect(fixture.session.standardControls.allSatisfy { $0.getInfo.isSuccess })
        #expect(fixture.session.extensionUnitSelectors.allSatisfy { $0.getInfo.isSuccess })
        #expect(!fixture.session.isInspecting)

        fixture.session.stopPassiveDiscovery()
    }

    @Test("Stable USB metadata updates preserve an active session without reinspection")
    @MainActor
    func stableMetadataUpdateDoesNotResetOrReinspect() async {
        let inspectedControls = markedControlStates(marker: "stable metadata")
        let fixture = makeFixture(standardResult: inspectedControls)
        let initial = verifiedPocket(registryID: 251, locationID: 0x72)
        let metadataUpdate = verifiedPocket(
            registryID: initial.registryID,
            locationID: 0x72,
            activeConfiguration: 2,
            enumerationState: 7
        )

        fixture.session.startPassiveDiscovery()
        fixture.monitorFactory.latestMonitor?.emit(initial)
        #expect(await waitForDevice(fixture.session, registryID: initial.registryID))

        fixture.session.refreshReadOnlyInspection()
        #expect(await waitForFakeInspectionToFinish(fixture.session, inspector: fixture.standardInspector))
        let operationsBeforeMetadata = await fixture.transport.operationSnapshot()

        fixture.monitorFactory.latestMonitor?.emit(metadataUpdate)
        await drainTasks()

        let standardInspectionCount = await fixture.standardInspector?.inspectionCount()
        let operationsAfterMetadata = await fixture.transport.operationSnapshot()
        #expect(fixture.session.device == metadataUpdate)
        #expect(fixture.session.standardControls == inspectedControls)
        #expect(standardInspectionCount == 1)
        #expect(operationsAfterMetadata == operationsBeforeMetadata)

        fixture.session.stopPassiveDiscovery()
    }

    @Test("Same-port re-enumeration invalidates before publishing replacement and discards stale inspection")
    @MainActor
    func samePortReenumerationCancelsStaleInspection() async {
        let inspectionGate = AsyncGate()
        let fixture = makeFixture(inspectionGate: inspectionGate)
        let oldDevice = verifiedPocket(registryID: 301, locationID: 0x7A)
        let replacement = verifiedPocket(registryID: 302, locationID: 0x7A)

        fixture.session.startPassiveDiscovery()
        fixture.monitorFactory.latestMonitor?.emit(oldDevice)
        #expect(await waitForDevice(fixture.session, registryID: oldDevice.registryID))

        fixture.session.refreshReadOnlyInspection()
        #expect(await waitForStandardInspectionStart(fixture.standardInspector))

        let replacementInvalidation = AsyncGate()
        await fixture.transport.blockInvalidations(with: replacementInvalidation)
        fixture.monitorFactory.latestMonitor?.emit(replacement)

        #expect(await waitForInvalidation(fixture.transport, minimumCount: 3))
        #expect(fixture.session.device == nil)
        #expect(!fixture.session.isInspecting)
        #expect(!fixture.session.isWriteModeEnabled)

        await replacementInvalidation.open()
        #expect(await waitForDevice(fixture.session, registryID: replacement.registryID))

        await inspectionGate.open()
        await drainTasks(128)

        let idleControls = UVCControlID.allCases.map { UVCStandardControlState.idle(control: $0) }
        let activatedConnections = await fixture.transport.activatedConnections()
        #expect(fixture.session.standardControls == idleControls)
        #expect(fixture.session.device?.registryID == replacement.registryID)
        #expect(!activatedConnections.contains(where: { $0.registryID == replacement.registryID }))
        #expect(fixture.preview.stopCount >= 2)

        fixture.session.stopPassiveDiscovery()
    }

    @Test("Stopping discovery performs an idempotent safe teardown")
    @MainActor
    func stoppingDiscoveryTearsDownPreviewAndTransport() async {
        let fixture = makeFixture(cameraAuthorization: .authorized)
        let device = verifiedPocket(registryID: 401)

        fixture.session.startPassiveDiscovery()
        fixture.monitorFactory.latestMonitor?.emit(device)
        #expect(await waitForDevice(fixture.session, registryID: device.registryID))

        fixture.session.requestPreviewStart()
        #expect(await waitForPreviewStart(fixture.preview))

        let operationsBeforeStop = await fixture.transport.operationSnapshot()
        fixture.session.stopPassiveDiscovery()
        await drainTasks()

        let operationsAfterStop = await fixture.transport.operationSnapshot()
        let teardownOperations = Array(operationsAfterStop.dropFirst(operationsBeforeStop.count))
        let hasTeardownInvalidation = teardownOperations.contains { $0.isInvalidation }
        #expect(fixture.monitorFactory.latestMonitor?.stopCount == 1)
        #expect(fixture.session.device == nil)
        #expect(!fixture.session.isPreviewRunning)
        #expect(!fixture.session.isWriteModeEnabled)
        #expect(fixture.preview.stopCount >= 2)
        #expect(hasTeardownInvalidation)

        fixture.session.stopPassiveDiscovery()
        await drainTasks()
        #expect(fixture.monitorFactory.latestMonitor?.stopCount == 1)
    }

    @Test("Re-enumeration cancels held selector, snapshot, and debounced write work")
    @MainActor
    func reenumerationCancelsHeldSelectorSnapshotAndWriteWork() async {
        let selectorGate = AsyncGate()
        let snapshotGate = AsyncGate()
        let writeGate = AsyncGate()
        let fixture = makeFixture(
            selectorRefreshGate: selectorGate,
            snapshotGate: snapshotGate,
            clockGate: writeGate
        )
        let oldDevice = verifiedPocket(registryID: 451, locationID: 0x7B)
        let replacement = verifiedPocket(registryID: 452, locationID: 0x7B)

        fixture.session.startPassiveDiscovery()
        fixture.monitorFactory.latestMonitor?.emit(oldDevice)
        #expect(await waitForDevice(fixture.session, registryID: oldDevice.registryID))

        fixture.session.standardControls = writeReadyControlStates()
        fixture.session.refreshExtensionSelector(1)
        fixture.session.captureSnapshotA()
        #expect(await waitForHeldExtensionWork(fixture.extensionInspector))

        fixture.session.unlockWrites()
        #expect(await waitForWriteModeActivation(fixture.transport))
        fixture.session.scheduleZoom(42)
        #expect(await waitForClockSleep(fixture.clock))

        fixture.monitorFactory.latestMonitor?.emit(replacement)
        #expect(await waitForDevice(fixture.session, registryID: replacement.registryID))
        #expect(!fixture.session.isCapturingSnapshot)
        #expect(!fixture.session.isWriteModeEnabled)
        #expect(fixture.session.snapshotA == nil)
        #expect(!(await fixture.transport.isWriteLatchEnabled()))

        await selectorGate.open()
        await snapshotGate.open()
        await writeGate.open()
        await drainTasks(256)

        let idleSelectors = (UInt8(1)...UInt8(3)).map { ExtensionUnitSelectorState.idle(selector: $0) }
        let writeCount = await fixture.standardInspector?.writeOperationCount()
        let requests = await fixture.transport.requestSnapshot()
        #expect(fixture.session.extensionUnitSelectors == idleSelectors)
        #expect(fixture.session.snapshotA == nil)
        #expect(writeCount == 0)
        #expect(!requests.contains(where: { $0.request == .setCurrent }))

        fixture.session.stopPassiveDiscovery()
    }

    @Test("Default session exports redact Extension Unit and identifying diagnostic details")
    @MainActor
    func redactedExportsHideSensitiveDetailsByDefault() {
        let fixture = makeFixture()
        fixture.session.logger.log("XU_GET_CUR selector=1", "DE AD BE EF")
        fixture.session.logger.log("AVCAPTURE_DEVICE_FOUND", "camera-id=private-camera-identifier")

        let export = fixture.session.logger.renderedText(
            includeRawExtensionUnitData: fixture.session.includeRawExtensionUnitDataInExports
        )

        #expect(!fixture.session.includeRawExtensionUnitDataInExports)
        #expect(export.contains("Raw Extension Unit data redacted."))
        #expect(export.contains("Potentially identifying diagnostic detail redacted."))
        #expect(!export.contains("DE AD BE EF"))
        #expect(!export.contains("private-camera-identifier"))
    }

    @Test("Verified Pocket 4 matching requires the known IDs and normalized product token")
    func pocketUSBProfileRequiresExactIDsAndNormalizedToken() {
        #expect(
            PocketUSBProfile.classify(
                vendorID: 0x2CA3,
                productID: 0x0023,
                manufacturer: "dJi",
                productIdentifier: "DJI—Osmo Pocket 4"
            ) == .confirmedPocket4VIDPID
        )
        #expect(
            PocketUSBProfile.classify(
                vendorID: 0x2CA3,
                productID: 0x0020,
                manufacturer: "DJI",
                productIdentifier: "Osmo Pocket 4"
            ) == .djiOsmoPocketFamily
        )
        #expect(
            PocketUSBProfile.classify(
                vendorID: 0x2CA3,
                productID: 0x0023,
                manufacturer: "DJI",
                productIdentifier: "Osmo Pocket 3"
            ) == .djiOsmoPocketFamily
        )
        #expect(
            PocketUSBProfile.classify(
                vendorID: 0x2CA3,
                productID: 0x0023,
                manufacturer: "DJI",
                productIdentifier: nil
            ) == nil
        )
    }

    @Test("Family-only devices cannot inspect, unlock, or write")
    @MainActor
    func familyOnlyDeviceCannotInspectUnlockOrWrite() async {
        let fixture = makeFixture()
        let device = unverifiedPocket(registryID: 501)

        fixture.session.startPassiveDiscovery()
        fixture.monitorFactory.latestMonitor?.emit(device)
        #expect(await waitForDevice(fixture.session, registryID: device.registryID))

        fixture.session.refreshReadOnlyInspection()
        fixture.session.unlockWrites()
        fixture.session.scheduleZoom(42)
        await drainTasks()

        let operations = await fixture.transport.operationSnapshot()
        let standardInspectionCount = await fixture.standardInspector?.inspectionCount()
        let extensionInspectionCount = await fixture.extensionInspector?.inspectionCount()
        let activated = operations.contains {
            if case .activate = $0 {
                return true
            }
            return false
        }

        #expect(!fixture.session.isWriteModeEnabled)
        #expect(!(await fixture.transport.isWriteLatchEnabled()))
        #expect(!activated)
        #expect(operations.compactMap { operation -> FakeTransport.RecordedRequest? in
            guard case let .request(request) = operation else {
                return nil
            }
            return request
        }.isEmpty)
        #expect(standardInspectionCount == 0)
        #expect(extensionInspectionCount == 0)

        fixture.session.stopPassiveDiscovery()
    }

    @Test("Direct transport requires an explicit write latch and current connection")
    func directTransportRequiresExplicitLatchAndCurrentConnection() async {
        let bridge = FakeDirectUVCBridge()
        let transport = DirectUVCTransport(bridge: bridge)
        let connection = syntheticConnection(registryID: 601, generation: 3)
        let staleGeneration = syntheticConnection(registryID: 601, generation: 2)
        let replacedIdentity = syntheticConnection(registryID: 602, generation: 3)
        let relocatedIdentity = syntheticConnection(
            registryID: 601,
            generation: 3,
            locationID: 0xA1
        )
        let authorizer = AllowingWriteAuthorizer(connection: connection)

        await transport.activate(connection)
        let lockedResult = await transport.perform(
            connection: connection,
            request: .setCurrent,
            selector: UVCControlID.zoom.selector,
            entityID: UVCRequestPolicy.cameraTerminalEntityID,
            expectedLength: UVCControlID.zoom.expectedPayloadLength,
            payload: [0x2A, 0x00],
            writeAuthorization: authorizer
        )

        #expect(!lockedResult.isSuccess)
        #expect(bridge.openCount == 0)
        #expect(bridge.requestSnapshot().isEmpty)

        await transport.setWritesEnabled(true, for: connection)
        let unauthorizedResult = await transport.perform(
            connection: connection,
            request: .setCurrent,
            selector: UVCControlID.zoom.selector,
            entityID: UVCRequestPolicy.cameraTerminalEntityID,
            expectedLength: UVCControlID.zoom.expectedPayloadLength,
            payload: [0x2A, 0x00],
            writeAuthorization: nil
        )

        #expect(!unauthorizedResult.isSuccess)
        #expect(bridge.openCount == 0)
        #expect(bridge.requestSnapshot().isEmpty)

        let unlockedResult = await transport.perform(
            connection: connection,
            request: .setCurrent,
            selector: UVCControlID.zoom.selector,
            entityID: UVCRequestPolicy.cameraTerminalEntityID,
            expectedLength: UVCControlID.zoom.expectedPayloadLength,
            payload: [0x2A, 0x00],
            writeAuthorization: authorizer
        )

        #expect(unlockedResult.isSuccess)
        #expect(bridge.openCount == 1)
        let bridgeRequests = bridge.requestSnapshot()
        #expect(bridgeRequests.count == 1)
        #expect(bridgeRequests.first?.interfaceNumber == ExpectedUVCPolicyContract.videoControlInterfaceNumber)

        for staleConnection in [staleGeneration, replacedIdentity, relocatedIdentity] {
            let staleResult = await transport.perform(
                connection: staleConnection,
                request: .setCurrent,
                selector: UVCControlID.zoom.selector,
                entityID: UVCRequestPolicy.cameraTerminalEntityID,
                expectedLength: UVCControlID.zoom.expectedPayloadLength,
                payload: [0x2A, 0x00],
                writeAuthorization: authorizer
            )

            #expect(!staleResult.isSuccess)
        }
        #expect(bridge.openCount == 1)
        #expect(bridge.requestSnapshot().count == 1)
    }

    @Test("UVC policy permits only the documented Camera Terminal and read-only XU requests")
    func uvcRequestPolicyAllowsOnlyDocumentedRequests() {
        #expect(UVCControlID.allCases == [.zoom, .panTilt, .roll])
        #expect(UVCRequestPolicy.videoControlInterfaceNumber == ExpectedUVCPolicyContract.videoControlInterfaceNumber)
        #expect(UVCRequestPolicy.cameraTerminalEntityID == ExpectedUVCPolicyContract.cameraTerminalEntityID)
        #expect(UVCRequestPolicy.extensionUnitEntityID == ExpectedUVCPolicyContract.extensionUnitEntityID)
        #expect(UVCRequestPolicy.maximumExtensionUnitReadLength == ExpectedUVCPolicyContract.maximumExtensionUnitReadLength)
        #expect(UVCControlID.zoom.selector == ExpectedUVCPolicyContract.zoomSelector)
        #expect(UVCControlID.zoom.expectedPayloadLength == ExpectedUVCPolicyContract.scalarPayloadLength)
        #expect(UVCControlID.panTilt.selector == ExpectedUVCPolicyContract.panTiltSelector)
        #expect(UVCControlID.panTilt.expectedPayloadLength == ExpectedUVCPolicyContract.panTiltPayloadLength)
        #expect(UVCControlID.roll.selector == ExpectedUVCPolicyContract.rollSelector)
        #expect(UVCControlID.roll.expectedPayloadLength == ExpectedUVCPolicyContract.scalarPayloadLength)

        let writableControls: [(selector: UInt8, length: Int)] = [
            (ExpectedUVCPolicyContract.zoomSelector, ExpectedUVCPolicyContract.scalarPayloadLength),
            (ExpectedUVCPolicyContract.panTiltSelector, ExpectedUVCPolicyContract.panTiltPayloadLength),
            (ExpectedUVCPolicyContract.rollSelector, ExpectedUVCPolicyContract.scalarPayloadLength),
        ]
        let forbiddenExtensionUnitRequests: [UVCRequest] = [
            .setCurrent,
            .getMinimum,
            .getMaximum,
            .getResolution,
            .getDefault,
        ]

        for control in writableControls {
            #expect(
                UVCRequestPolicy.allows(
                    request: .setCurrent,
                    selector: control.selector,
                    entityID: UVCRequestPolicy.cameraTerminalEntityID,
                    expectedLength: control.length
                )
            )
        }

        #expect(
            !UVCRequestPolicy.allows(
                request: .setCurrent,
                selector: 0x10,
                entityID: UVCRequestPolicy.cameraTerminalEntityID,
                expectedLength: 2
            )
        )
        #expect(
            !UVCRequestPolicy.allows(
                request: .setCurrent,
                selector: UVCControlID.zoom.selector,
                entityID: UVCRequestPolicy.extensionUnitEntityID,
                expectedLength: 2
            )
        )

        for selector in UInt8(1)...UInt8(3) {
            #expect(
                UVCRequestPolicy.allows(
                    request: .getInfo,
                    selector: selector,
                    entityID: UVCRequestPolicy.extensionUnitEntityID,
                    expectedLength: 1
                )
            )
            #expect(
                UVCRequestPolicy.allows(
                    request: .getLength,
                    selector: selector,
                    entityID: UVCRequestPolicy.extensionUnitEntityID,
                    expectedLength: 2
                )
            )
            #expect(
                UVCRequestPolicy.allows(
                    request: .getCurrent,
                    selector: selector,
                    entityID: UVCRequestPolicy.extensionUnitEntityID,
                    expectedLength: 1
                )
            )
            #expect(
                UVCRequestPolicy.allows(
                    request: .getCurrent,
                    selector: selector,
                    entityID: UVCRequestPolicy.extensionUnitEntityID,
                    expectedLength: ExpectedUVCPolicyContract.maximumExtensionUnitReadLength
                )
            )
            for request in forbiddenExtensionUnitRequests {
                #expect(
                    !UVCRequestPolicy.allows(
                        request: request,
                        selector: selector,
                        entityID: UVCRequestPolicy.extensionUnitEntityID,
                        expectedLength: 1
                    )
                )
            }
        }

        #expect(
            !UVCRequestPolicy.allows(
                request: .getCurrent,
                selector: 1,
                entityID: UVCRequestPolicy.extensionUnitEntityID,
                expectedLength: 0
            )
        )
        #expect(
            !UVCRequestPolicy.allows(
                request: .getCurrent,
                selector: 1,
                entityID: UVCRequestPolicy.extensionUnitEntityID,
                expectedLength: ExpectedUVCPolicyContract.maximumExtensionUnitReadLength + 1
            )
        )
        #expect(
            !UVCRequestPolicy.allows(
                request: .getInfo,
                selector: 4,
                entityID: UVCRequestPolicy.extensionUnitEntityID,
                expectedLength: 1
            )
        )
    }

    @Test("UVC policy has no additional permitted request tuples")
    func uvcRequestPolicyHasNoAdditionalPermittedTuples() {
        var observed: Set<UVCPolicyTuple> = []

        for entityID in [
            UVCRequestPolicy.cameraTerminalEntityID,
            UVCRequestPolicy.extensionUnitEntityID,
        ] {
            for selector in UInt8.min...UInt8.max {
                for request in UVCRequest.allCases {
                    for expectedLength in 0...(ExpectedUVCPolicyContract.maximumExtensionUnitReadLength + 1) {
                        guard UVCRequestPolicy.allows(
                            request: request,
                            selector: selector,
                            entityID: entityID,
                            expectedLength: expectedLength
                        ) else {
                            continue
                        }
                        observed.insert(
                            UVCPolicyTuple(
                                request: request.rawValue,
                                selector: selector,
                                entityID: entityID,
                                expectedLength: expectedLength
                            )
                        )
                    }
                }
            }
        }

        #expect(observed == expectedUVCPolicyTuples())

        let boundaryLengths = [
            0,
            1,
            2,
            ExpectedUVCPolicyContract.panTiltPayloadLength,
            ExpectedUVCPolicyContract.maximumExtensionUnitReadLength,
            ExpectedUVCPolicyContract.maximumExtensionUnitReadLength + 1,
        ]
        var unexpectedOtherEntityTuples: Set<UVCPolicyTuple> = []

        for entityID in UInt8.min...UInt8.max
        where entityID != UVCRequestPolicy.cameraTerminalEntityID
            && entityID != UVCRequestPolicy.extensionUnitEntityID
        {
            for tuple in expectedUVCPolicyTuples() {
                guard let request = UVCRequest(rawValue: tuple.request) else {
                    Issue.record("The test fixture contains an unknown UVC request.")
                    continue
                }
                if UVCRequestPolicy.allows(
                    request: request,
                    selector: tuple.selector,
                    entityID: entityID,
                    expectedLength: tuple.expectedLength
                ) {
                    unexpectedOtherEntityTuples.insert(
                        UVCPolicyTuple(
                            request: tuple.request,
                            selector: tuple.selector,
                            entityID: entityID,
                            expectedLength: tuple.expectedLength
                        )
                    )
                }
            }

            for selector in UInt8.min...UInt8.max {
                for request in UVCRequest.allCases {
                    for expectedLength in boundaryLengths where UVCRequestPolicy.allows(
                        request: request,
                        selector: selector,
                        entityID: entityID,
                        expectedLength: expectedLength
                    ) {
                        unexpectedOtherEntityTuples.insert(
                            UVCPolicyTuple(
                                request: request.rawValue,
                                selector: selector,
                                entityID: entityID,
                                expectedLength: expectedLength
                            )
                        )
                    }
                }
            }
        }

        #expect(unexpectedOtherEntityTuples.isEmpty)
    }

    @Test("Forbidden UVC tuples and malformed payloads never open the bridge")
    func forbiddenTuplesAndMalformedPayloadsNeverOpenBridge() async {
        let bridge = FakeDirectUVCBridge()
        let transport = DirectUVCTransport(bridge: bridge)
        let connection = syntheticConnection(registryID: 701, generation: 1)
        let authorizer = AllowingWriteAuthorizer(connection: connection)

        await transport.activate(connection)
        await transport.setWritesEnabled(true, for: connection)

        let invalidRequests: [UnsafeTransportRequest] = [
            UnsafeTransportRequest(
                request: .setCurrent,
                selector: 0x10,
                entityID: UVCRequestPolicy.cameraTerminalEntityID,
                expectedLength: 2,
                payload: [0x00, 0x00]
            ),
            UnsafeTransportRequest(
                request: .setCurrent,
                selector: UVCControlID.zoom.selector,
                entityID: UVCRequestPolicy.cameraTerminalEntityID,
                expectedLength: 1,
                payload: [0x00]
            ),
            UnsafeTransportRequest(
                request: .setCurrent,
                selector: UVCControlID.zoom.selector,
                entityID: UVCRequestPolicy.cameraTerminalEntityID,
                expectedLength: 2,
                payload: [0x00]
            ),
            UnsafeTransportRequest(
                request: .setCurrent,
                selector: UVCControlID.zoom.selector,
                entityID: UVCRequestPolicy.cameraTerminalEntityID,
                expectedLength: 2,
                payload: nil
            ),
            UnsafeTransportRequest(
                request: .setCurrent,
                selector: 1,
                entityID: UVCRequestPolicy.extensionUnitEntityID,
                expectedLength: 1,
                payload: [0x00]
            ),
            UnsafeTransportRequest(
                request: .getCurrent,
                selector: 1,
                entityID: UVCRequestPolicy.extensionUnitEntityID,
                expectedLength: 0,
                payload: nil
            ),
            UnsafeTransportRequest(
                request: .getCurrent,
                selector: 1,
                entityID: UVCRequestPolicy.extensionUnitEntityID,
                expectedLength: ExpectedUVCPolicyContract.maximumExtensionUnitReadLength + 1,
                payload: nil
            ),
        ]

        for invalidRequest in invalidRequests {
            let result = await transport.perform(
                connection: connection,
                request: invalidRequest.request,
                selector: invalidRequest.selector,
                entityID: invalidRequest.entityID,
                expectedLength: invalidRequest.expectedLength,
                payload: invalidRequest.payload,
                writeAuthorization: authorizer
            )
            #expect(!result.isSuccess)
        }

        #expect(bridge.openCount == 0)
        #expect(bridge.requestSnapshot().isEmpty)
    }

    @Test("Malformed UVC ranges and payloads cannot become write-ready")
    func malformedRangesAndPayloadsCannotBecomeWriteReady() {
        for control in UVCControlID.allCases {
            #expect(writeReadyControlState(for: control).isWriteReady)
        }

        var malformedInfo = writeReadyControlState(for: .zoom)
        malformedInfo.getInfo = successfulResult(.getInfo, bytes: [0x03, 0x00])
        #expect(!malformedInfo.isWriteReady)

        var malformedVectorInfo = writeReadyControlState(for: .panTilt)
        malformedVectorInfo.getInfo = successfulResult(.getInfo, bytes: [0x03, 0x00])
        #expect(!malformedVectorInfo.isWriteReady)

        let rangeResponseFields: [(keyPath: WritableKeyPath<UVCStandardControlState, UVCRequestResult>, request: UVCRequest)] = [
            (\.minimum, .getMinimum),
            (\.maximum, .getMaximum),
            (\.resolution, .getResolution),
            (\.defaultValue, .getDefault),
            (\.currentValue, .getCurrent),
        ]
        for field in rangeResponseFields {
            var malformedScalar = writeReadyControlState(for: .zoom)
            malformedScalar[keyPath: field.keyPath] = successfulResult(field.request, bytes: [0x00])
            #expect(!malformedScalar.isWriteReady)

            var malformedVector = writeReadyControlState(for: .panTilt)
            malformedVector[keyPath: field.keyPath] = successfulResult(
                field.request,
                bytes: [UInt8](repeating: 0, count: 7)
            )
            #expect(!malformedVector.isWriteReady)
        }

        var reversedScalar = writeReadyControlState(for: .zoom)
        reversedScalar.minimum = successfulResult(.getMinimum, bytes: scalarBytes(101, for: .zoom))
        #expect(!reversedScalar.isWriteReady)

        var zeroScalarResolution = writeReadyControlState(for: .roll)
        zeroScalarResolution.resolution = successfulResult(.getResolution, bytes: scalarBytes(0, for: .roll))
        #expect(!zeroScalarResolution.isWriteReady)

        var outOfRangeDefault = writeReadyControlState(for: .roll)
        outOfRangeDefault.defaultValue = successfulResult(.getDefault, bytes: scalarBytes(11, for: .roll))
        #expect(!outOfRangeDefault.isWriteReady)

        var invalidVectorResolution = writeReadyControlState(for: .panTilt)
        invalidVectorResolution.resolution = successfulResult(
            .getResolution,
            bytes: UVCValueCodec.encodePanTilt(UVCVector2(first: 0, second: 1))
        )
        #expect(!invalidVectorResolution.isWriteReady)

        var outOfRangeVectorCurrent = writeReadyControlState(for: .panTilt)
        outOfRangeVectorCurrent.currentValue = successfulResult(
            .getCurrent,
            bytes: UVCValueCodec.encodePanTilt(UVCVector2(first: 101, second: 0))
        )
        #expect(!outOfRangeVectorCurrent.isWriteReady)
    }

    @Test("Pan-only and Tilt-only writes preserve the untouched axis")
    func panTiltPartialWritesPreserveTheUntouchedAxis() async {
        let connection = syntheticConnection(registryID: 801, generation: 1)
        let transport = ScriptedTransport(
            panTiltCurrent: UVCValueCodec.encodePanTilt(UVCVector2(first: 10, second: -20))
        )
        let controls = UVCStandardControls(transport: transport)
        let authorizer = AllowingWriteAuthorizer(connection: connection)

        let panOutcome = await controls.setPanTilt(
            pan: 42,
            tilt: nil,
            connection: connection,
            writeAuthorization: authorizer
        )
        let tiltOutcome = await controls.setPanTilt(
            pan: nil,
            tilt: 7,
            connection: connection,
            writeAuthorization: authorizer
        )
        let setPayloads = await transport.setPayloadSnapshot()

        #expect(panOutcome.setResult?.isSuccess == true)
        #expect(tiltOutcome.setResult?.isSuccess == true)
        #expect(
            setPayloads == [
                UVCValueCodec.encodePanTilt(UVCVector2(first: 42, second: -20)),
                UVCValueCodec.encodePanTilt(UVCVector2(first: 42, second: 7)),
            ]
        )
    }

    @Test("Reset derives writes only from complete valid GET_DEF data")
    @MainActor
    func resetDerivesWritesOnlyFromValidDefaults() async {
        let zoomFixture = makeFixture()
        let zoomDevice = verifiedPocket(registryID: 901)
        zoomFixture.session.startPassiveDiscovery()
        zoomFixture.monitorFactory.latestMonitor?.emit(zoomDevice)
        #expect(await waitForDevice(zoomFixture.session, registryID: zoomDevice.registryID))
        zoomFixture.session.standardControls = controlStates([
            .zoom: writeReadyControlState(for: .zoom),
        ])
        zoomFixture.session.unlockWrites()
        #expect(await waitForWriteModeActivation(zoomFixture.transport))
        zoomFixture.session.resetZoom()
        #expect(await waitForScalarWrite(zoomFixture.standardInspector, count: 1))
        #expect(await zoomFixture.standardInspector?.scalarWriteSnapshot() == [
            ScalarWrite(control: .zoom, value: 10),
        ])
        zoomFixture.session.stopPassiveDiscovery()

        let panTiltFixture = makeFixture()
        let panTiltDevice = verifiedPocket(registryID: 902)
        panTiltFixture.session.startPassiveDiscovery()
        panTiltFixture.monitorFactory.latestMonitor?.emit(panTiltDevice)
        #expect(await waitForDevice(panTiltFixture.session, registryID: panTiltDevice.registryID))
        panTiltFixture.session.standardControls = controlStates([
            .panTilt: writeReadyControlState(for: .panTilt),
        ])
        panTiltFixture.session.unlockWrites()
        #expect(await waitForWriteModeActivation(panTiltFixture.transport))
        panTiltFixture.session.resetPanTilt()
        #expect(await waitForPanTiltWrite(panTiltFixture.standardInspector, count: 1))
        #expect(await panTiltFixture.standardInspector?.panTiltWriteSnapshot() == [
            PanTiltWrite(pan: 5, tilt: -5),
        ])
        panTiltFixture.session.stopPassiveDiscovery()

        let rollFixture = makeFixture()
        let rollDevice = verifiedPocket(registryID: 903)
        rollFixture.session.startPassiveDiscovery()
        rollFixture.monitorFactory.latestMonitor?.emit(rollDevice)
        #expect(await waitForDevice(rollFixture.session, registryID: rollDevice.registryID))
        rollFixture.session.standardControls = controlStates([
            .roll: writeReadyControlState(for: .roll),
        ])
        rollFixture.session.unlockWrites()
        #expect(await waitForWriteModeActivation(rollFixture.transport))
        rollFixture.session.resetRoll()
        #expect(await waitForScalarWrite(rollFixture.standardInspector, count: 1))
        #expect(await rollFixture.standardInspector?.scalarWriteSnapshot() == [
            ScalarWrite(control: .roll, value: 0),
        ])
        rollFixture.session.stopPassiveDiscovery()

        let invalidFixture = makeFixture()
        let invalidDevice = verifiedPocket(registryID: 904)
        invalidFixture.session.startPassiveDiscovery()
        invalidFixture.monitorFactory.latestMonitor?.emit(invalidDevice)
        #expect(await waitForDevice(invalidFixture.session, registryID: invalidDevice.registryID))
        var invalidZoom = writeReadyControlState(for: .zoom)
        invalidZoom.defaultValue = successfulResult(.getDefault, bytes: [0x0A])
        var failedRoll = writeReadyControlState(for: .roll)
        failedRoll.defaultValue = failedResult(.getDefault)
        invalidFixture.session.standardControls = controlStates([
            .zoom: invalidZoom,
            .roll: failedRoll,
            .panTilt: writeReadyControlState(for: .panTilt),
        ])
        invalidFixture.session.unlockWrites()
        #expect(await waitForWriteModeActivation(invalidFixture.transport))
        invalidFixture.session.resetZoom()
        invalidFixture.session.resetRoll()
        await drainTasks()

        #expect(await invalidFixture.clock.sleepCount() == 0)
        #expect(await invalidFixture.standardInspector?.writeOperationCount() == 0)
        invalidFixture.session.stopPassiveDiscovery()
    }

    @Test("Invalid Extension Unit GET_LEN responses never trigger GET_CUR")
    func invalidExtensionUnitLengthsNeverTriggerGetCurrent() async {
        let connection = syntheticConnection(registryID: 1001, generation: 1)

        for invalidLength in [
            [UInt8](),
            [0x01],
            [UInt8](repeating: 0, count: 2),
            [0x01, 0x00, 0x00],
            [0x01, 0x04],
        ] {
            let transport = ScriptedTransport(extensionLengthBytes: invalidLength)
            let inspector = DJIExtensionUnitInspector(transport: transport)
            let state = await inspector.refresh(selector: 1, connection: connection)
            let requests = await transport.requestSnapshot()

            #expect(requests.map(\.request) == [.getInfo, .getLength])
            #expect(!state.currentValue.isSuccess)
        }
    }
}

@MainActor
private final class SessionFixture {
    let session: DeviceSession
    let monitorFactory: FakeMonitorFactory
    let camera: FakeCameraAccess
    let preview: FakePreviewController
    let transport: FakeTransport
    let clock: FakeClock
    let standardInspector: FakeStandardControlInspector?
    let extensionInspector: FakeExtensionUnitInspector?

    init(
        session: DeviceSession,
        monitorFactory: FakeMonitorFactory,
        camera: FakeCameraAccess,
        preview: FakePreviewController,
        transport: FakeTransport,
        clock: FakeClock,
        standardInspector: FakeStandardControlInspector?,
        extensionInspector: FakeExtensionUnitInspector?
    ) {
        self.session = session
        self.monitorFactory = monitorFactory
        self.camera = camera
        self.preview = preview
        self.transport = transport
        self.clock = clock
        self.standardInspector = standardInspector
        self.extensionInspector = extensionInspector
    }
}

@MainActor
private func makeFixture(
    cameraAuthorization: CameraAuthorization = .notDetermined,
    hasPreviewSource: Bool = true,
    useProductionReadOnlyInspectors: Bool = false,
    inspectionGate: AsyncGate? = nil,
    selectorRefreshGate: AsyncGate? = nil,
    snapshotGate: AsyncGate? = nil,
    clockGate: AsyncGate? = nil,
    standardResult: [UVCStandardControlState]? = nil
) -> SessionFixture {
    let monitorFactory = FakeMonitorFactory()
    let camera = FakeCameraAccess(
        authorizationResponse: cameraAuthorization,
        previewSource: hasPreviewSource ? FakePreviewSource() : nil
    )
    let preview = FakePreviewController()
    let transport = FakeTransport()
    let clock = FakeClock(gate: clockGate)

    let standardInspector: FakeStandardControlInspector?
    let extensionInspector: FakeExtensionUnitInspector?
    let standardControls: any StandardControlInspecting
    let extensionUnit: any ExtensionUnitInspecting

    if useProductionReadOnlyInspectors {
        standardInspector = nil
        extensionInspector = nil
        standardControls = UVCStandardControls(transport: transport)
        extensionUnit = DJIExtensionUnitInspector(transport: transport)
    } else {
        let fakeStandardInspector = FakeStandardControlInspector(
            gate: inspectionGate,
            result: standardResult ?? UVCControlID.allCases.map { .idle(control: $0) },
            writeTransport: transport
        )
        let fakeExtensionInspector = FakeExtensionUnitInspector(
            inspectAllGate: snapshotGate,
            refreshGate: selectorRefreshGate
        )
        standardInspector = fakeStandardInspector
        extensionInspector = fakeExtensionInspector
        standardControls = fakeStandardInspector
        extensionUnit = fakeExtensionInspector
    }

    let session = DeviceSession(
        dependencies: DeviceSessionDependencies(
            makeMonitor: { onChange in
                monitorFactory.makeMonitor(onChange: onChange)
            },
            camera: camera,
            previewController: nil,
            preview: preview,
            transport: transport,
            standardControls: standardControls,
            extensionUnit: extensionUnit,
            clock: clock
        )
    )

    return SessionFixture(
        session: session,
        monitorFactory: monitorFactory,
        camera: camera,
        preview: preview,
        transport: transport,
        clock: clock,
        standardInspector: standardInspector,
        extensionInspector: extensionInspector
    )
}

@MainActor
private final class FakeMonitorFactory {
    private(set) var monitors: [FakeMonitor] = []

    var monitorCount: Int {
        monitors.count
    }

    var latestMonitor: FakeMonitor? {
        monitors.last
    }

    func makeMonitor(
        onChange: @escaping @MainActor (PocketDevice?) -> Void
    ) -> any DeviceMonitoring {
        let monitor = FakeMonitor(onChange: onChange)
        monitors.append(monitor)
        return monitor
    }
}

@MainActor
private final class FakeMonitor: DeviceMonitoring {
    private let onChange: @MainActor (PocketDevice?) -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(onChange: @escaping @MainActor (PocketDevice?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ device: PocketDevice?) {
        onChange(device)
    }
}

@MainActor
private final class FakeCameraAccess: CameraAccessing {
    private let authorizationResponse: CameraAuthorization
    private let configuredPreviewSource: (any CameraPreviewSource)?
    private let cmioObservations: [UVCControlID: CMIOControlObservation]

    private(set) var permissionRequestCount = 0
    private(set) var previewSourceRequestCount = 0
    private(set) var standardControlInspectionCount = 0

    init(
        authorizationResponse: CameraAuthorization,
        previewSource: (any CameraPreviewSource)?,
        cmioObservations: [UVCControlID: CMIOControlObservation] = [:]
    ) {
        self.authorizationResponse = authorizationResponse
        configuredPreviewSource = previewSource
        self.cmioObservations = cmioObservations
    }

    func requestVideoAccess() async -> CameraAuthorization {
        permissionRequestCount += 1
        return authorizationResponse
    }

    func previewSource(for pocket: PocketDevice) -> (any CameraPreviewSource)? {
        previewSourceRequestCount += 1
        return configuredPreviewSource
    }

    func inspectStandardControls(
        camera: CameraDeviceInfo?,
        pocket: PocketDevice
    ) -> [UVCControlID: CMIOControlObservation] {
        standardControlInspectionCount += 1
        return cmioObservations
    }
}

@MainActor
private final class FakePreviewSource: CameraPreviewSource {
    let cameraInfo = CameraDeviceInfo(
        localizedName: "Test Pocket Preview",
        uniqueID: "test-preview-source",
        modelID: "test-model",
        manufacturer: "Test Manufacturer",
        deviceType: "test-device-type",
        transportType: "test-transport",
        activeFormat: VideoFormatInfo(
            id: "test-format",
            mediaType: "vide",
            mediaSubType: "test",
            width: 1_920,
            height: 1_080,
            frameRateDescription: "30 fps"
        ),
        activeMinimumFrameDuration: "0.033 s",
        activeMaximumFrameDuration: "0.033 s",
        formats: []
    )
}

@MainActor
private final class FakePreviewController: PreviewControlling {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(source: any CameraPreviewSource) throws {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

private actor FakeTransport: UVCTransporting {
    enum Operation: Equatable, Sendable {
        case activate(UVCTransportConnection)
        case invalidate
        case invalidateThrough(UInt64)
        case setWritesEnabled(Bool, UVCTransportConnection)
        case disableWrites
        case request(RecordedRequest)
    }

    struct RecordedRequest: Equatable, Sendable {
        let connection: UVCTransportConnection
        let request: UVCRequest
        let selector: UInt8
        let entityID: UInt8
        let expectedLength: Int
        let payload: [UInt8]?
    }

    private var operations: [Operation] = []
    private var invalidationGate: AsyncGate?
    private var activeConnection: UVCTransportConnection?
    private var retiredThroughGeneration: UInt64 = 0
    private var writesEnabled = false

    func activate(_ connection: UVCTransportConnection) {
        operations.append(.activate(connection))
        guard connection.generation >= retiredThroughGeneration else {
            return
        }
        activeConnection = connection
        writesEnabled = false
    }

    func invalidate() async {
        operations.append(.invalidate)
        activeConnection = nil
        writesEnabled = false
        if let invalidationGate {
            await invalidationGate.wait()
        }
    }

    func invalidate(upTo generation: UInt64) async {
        operations.append(.invalidateThrough(generation))
        retiredThroughGeneration = max(retiredThroughGeneration, generation)
        if activeConnection?.generation ?? 0 <= generation {
            activeConnection = nil
            writesEnabled = false
        }
        if let invalidationGate {
            await invalidationGate.wait()
        }
    }

    func setWritesEnabled(_ enabled: Bool, for connection: UVCTransportConnection) {
        operations.append(.setWritesEnabled(enabled, connection))
        guard activeConnection == connection else {
            return
        }
        writesEnabled = enabled
    }

    func disableWrites() {
        operations.append(.disableWrites)
        writesEnabled = false
    }

    func perform(
        connection: UVCTransportConnection,
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int,
        payload: [UInt8]?,
        writeAuthorization: (any UVCWriteAuthorizing)?
    ) -> UVCRequestResult {
        operations.append(
            .request(
                RecordedRequest(
                    connection: connection,
                    request: request,
                    selector: selector,
                    entityID: entityID,
                    expectedLength: expectedLength,
                    payload: payload
                )
            )
        )

        return UVCRequestResult(
            request: request,
            bytes: responseBytes(for: request, expectedLength: expectedLength),
            outcome: .success
        )
    }

    func blockInvalidations(with gate: AsyncGate?) {
        invalidationGate = gate
    }

    func operationSnapshot() -> [Operation] {
        operations
    }

    func requestSnapshot() -> [RecordedRequest] {
        operations.compactMap {
            guard case let .request(request) = $0 else {
                return nil
            }
            return request
        }
    }

    func invalidationCount() -> Int {
        operations.reduce(into: 0) { count, operation in
            if case .invalidate = operation {
                count += 1
            }
            if case .invalidateThrough = operation {
                count += 1
            }
        }
    }

    func activatedConnections() -> [UVCTransportConnection] {
        operations.compactMap {
            guard case let .activate(connection) = $0 else {
                return nil
            }
            return connection
        }
    }

    func isWriteLatchEnabled() -> Bool {
        writesEnabled
    }

    private func responseBytes(for request: UVCRequest, expectedLength: Int) -> [UInt8] {
        switch request {
        case .getInfo:
            [0x03]
        case .getLength:
            [0x01, 0x00]
        case .setCurrent, .getCurrent, .getMinimum, .getMaximum, .getResolution, .getDefault:
            [UInt8](repeating: 0, count: expectedLength)
        }
    }
}

private extension FakeTransport.Operation {
    var isInvalidation: Bool {
        switch self {
        case .invalidate, .invalidateThrough:
            true
        default:
            false
        }
    }
}

private struct ScalarWrite: Equatable, Sendable {
    let control: UVCControlID
    let value: Int64
}

private struct PanTiltWrite: Equatable, Sendable {
    let pan: Int32?
    let tilt: Int32?
}

private actor FakeStandardControlInspector: StandardControlInspecting {
    private let gate: AsyncGate?
    private let result: [UVCStandardControlState]
    private let writeTransport: FakeTransport?
    private var inspectedConnections: [UVCTransportConnection] = []
    private var writeControls: [UVCControlID] = []
    private var scalarWrites: [ScalarWrite] = []
    private var panTiltWrites: [PanTiltWrite] = []

    init(
        gate: AsyncGate? = nil,
        result: [UVCStandardControlState] = UVCControlID.allCases.map { .idle(control: $0) },
        writeTransport: FakeTransport? = nil
    ) {
        self.gate = gate
        self.result = result
        self.writeTransport = writeTransport
    }

    func inspect(
        connection: UVCTransportConnection,
        cmioObservations: [UVCControlID: CMIOControlObservation]
    ) async -> [UVCStandardControlState] {
        inspectedConnections.append(connection)
        if let gate {
            await gate.wait()
        }
        return result
    }

    func setScalar(
        control: UVCControlID,
        value: Int64,
        connection: UVCTransportConnection,
        writeAuthorization: any UVCWriteAuthorizing
    ) async -> UVCWriteOutcome {
        writeControls.append(control)
        scalarWrites.append(ScalarWrite(control: control, value: value))
        let setResult = await writeTransport?.perform(
            connection: connection,
            request: .setCurrent,
            selector: control.selector,
            entityID: 1,
            expectedLength: control.expectedPayloadLength,
            payload: [UInt8](repeating: 0, count: control.expectedPayloadLength),
            writeAuthorization: writeAuthorization
        )
        return UVCWriteOutcome(
            control: control,
            oldValue: blockedCurrentValue(),
            requestedDescription: "test",
            setResult: setResult,
            resultingValue: nil
        )
    }

    func setPanTilt(
        pan: Int32?,
        tilt: Int32?,
        connection: UVCTransportConnection,
        writeAuthorization: any UVCWriteAuthorizing
    ) async -> UVCWriteOutcome {
        writeControls.append(.panTilt)
        panTiltWrites.append(PanTiltWrite(pan: pan, tilt: tilt))
        let setResult = await writeTransport?.perform(
            connection: connection,
            request: .setCurrent,
            selector: UVCControlID.panTilt.selector,
            entityID: 1,
            expectedLength: UVCControlID.panTilt.expectedPayloadLength,
            payload: [UInt8](repeating: 0, count: UVCControlID.panTilt.expectedPayloadLength),
            writeAuthorization: writeAuthorization
        )
        return UVCWriteOutcome(
            control: .panTilt,
            oldValue: blockedCurrentValue(),
            requestedDescription: "test",
            setResult: setResult,
            resultingValue: nil
        )
    }

    func inspectionCount() -> Int {
        inspectedConnections.count
    }

    func writeOperationCount() -> Int {
        writeControls.count
    }

    func scalarWriteSnapshot() -> [ScalarWrite] {
        scalarWrites
    }

    func panTiltWriteSnapshot() -> [PanTiltWrite] {
        panTiltWrites
    }
}

private actor FakeExtensionUnitInspector: ExtensionUnitInspecting {
    private let inspectAllGate: AsyncGate?
    private let refreshGate: AsyncGate?
    private var inspectedConnections: [UVCTransportConnection] = []
    private var refreshedSelectors: [UInt8] = []

    init(inspectAllGate: AsyncGate? = nil, refreshGate: AsyncGate? = nil) {
        self.inspectAllGate = inspectAllGate
        self.refreshGate = refreshGate
    }

    func inspectAll(connection: UVCTransportConnection) async -> [ExtensionUnitSelectorState] {
        inspectedConnections.append(connection)
        if let inspectAllGate {
            await inspectAllGate.wait()
        }
        return markedExtensionSelectors(marker: "stale snapshot")
    }

    func refresh(selector: UInt8, connection: UVCTransportConnection) async -> ExtensionUnitSelectorState {
        inspectedConnections.append(connection)
        refreshedSelectors.append(selector)
        if let refreshGate {
            await refreshGate.wait()
        }
        return markedExtensionSelector(selector: selector, marker: "stale selector")
    }

    func inspectionCount() -> Int {
        inspectedConnections.count
    }

    func refreshCount() -> Int {
        refreshedSelectors.count
    }

    func snapshotCount() -> Int {
        inspectedConnections.count - refreshedSelectors.count
    }
}

private actor FakeClock: SessionClock {
    private let gate: AsyncGate?
    private var requestedDelays: [UInt64] = []

    init(gate: AsyncGate? = nil) {
        self.gate = gate
    }

    func sleep(nanoseconds: UInt64) async throws {
        requestedDelays.append(nanoseconds)
        if let gate {
            await gate.wait()
        }
    }

    func sleepCount() -> Int {
        requestedDelays.count
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }

        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else {
            return
        }

        isOpen = true
        let suspendedWaiters = waiters
        waiters.removeAll()
        suspendedWaiters.forEach { $0.resume() }
    }
}

private struct UnsafeTransportRequest: Sendable {
    let request: UVCRequest
    let selector: UInt8
    let entityID: UInt8
    let expectedLength: Int
    let payload: [UInt8]?
}

private struct UVCPolicyTuple: Hashable {
    let request: UInt8
    let selector: UInt8
    let entityID: UInt8
    let expectedLength: Int
}

private struct AllowingWriteAuthorizer: UVCWriteAuthorizing {
    let connection: UVCTransportConnection

    func performIfPermitted(
        for candidate: UVCTransportConnection,
        operation: @Sendable () -> UVCRequestResult
    ) -> UVCRequestResult? {
        guard candidate == connection else {
            return nil
        }
        return operation()
    }
}

private final class FakeDirectUVCBridge: DirectUVCBridging, @unchecked Sendable {
    private let lock = NSLock()
    private let session = FakeDirectUVCBridgeSession()
    private var openedConnections: [UVCTransportConnection] = []

    func open(locationID: UInt32, registryID: UInt64) -> DirectUVCBridgeOpenResult {
        lock.lock()
        openedConnections.append(
            UVCTransportConnection(
                locationID: locationID,
                registryID: registryID,
                generation: 0
            )
        )
        lock.unlock()

        return DirectUVCBridgeOpenResult(
            session: session,
            status: 0,
            stage: .none
        )
    }

    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openedConnections.count
    }

    func requestSnapshot() -> [FakeDirectUVCBridgeSession.Request] {
        session.requestSnapshot()
    }
}

private final class FakeDirectUVCBridgeSession: DirectUVCBridgeSession, @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let request: UVCRequest
        let selector: UInt8
        let entityID: UInt8
        let interfaceNumber: UInt8
        let bytes: [UInt8]
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    func perform(
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        interfaceNumber: UInt8,
        bytes: inout [UInt8]
    ) -> DirectUVCBridgeResponse {
        lock.lock()
        requests.append(
            Request(
                request: request,
                selector: selector,
                entityID: entityID,
                interfaceNumber: interfaceNumber,
                bytes: bytes
            )
        )
        lock.unlock()

        return DirectUVCBridgeResponse(
            status: 0,
            stage: .controlRequest,
            bytesTransferred: bytes.count
        )
    }

    func requestSnapshot() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private actor ScriptedTransport: UVCTransporting {
    struct RecordedRequest: Equatable, Sendable {
        let request: UVCRequest
        let selector: UInt8
        let entityID: UInt8
        let expectedLength: Int
        let payload: [UInt8]?
    }

    private var panTiltCurrent: [UInt8]
    private let extensionLengthBytes: [UInt8]
    private var requests: [RecordedRequest] = []
    private var setPayloads: [[UInt8]] = []

    init(
        panTiltCurrent: [UInt8] = [UInt8](repeating: 0, count: UVCControlID.panTilt.expectedPayloadLength),
        extensionLengthBytes: [UInt8] = [0x01, 0x00]
    ) {
        self.panTiltCurrent = panTiltCurrent
        self.extensionLengthBytes = extensionLengthBytes
    }

    func activate(_ connection: UVCTransportConnection) {}

    func invalidate() {}

    func invalidate(upTo generation: UInt64) {}

    func setWritesEnabled(_ enabled: Bool, for connection: UVCTransportConnection) {}

    func disableWrites() {}

    func perform(
        connection: UVCTransportConnection,
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int,
        payload: [UInt8]?,
        writeAuthorization: (any UVCWriteAuthorizing)?
    ) -> UVCRequestResult {
        requests.append(
            RecordedRequest(
                request: request,
                selector: selector,
                entityID: entityID,
                expectedLength: expectedLength,
                payload: payload
            )
        )

        let bytes: [UInt8]
        if request == .getInfo {
            bytes = [0x03]
        } else if request == .getLength, entityID == UVCRequestPolicy.extensionUnitEntityID {
            bytes = extensionLengthBytes
        } else if request == .getCurrent,
                  entityID == UVCRequestPolicy.cameraTerminalEntityID,
                  selector == UVCControlID.panTilt.selector {
            bytes = panTiltCurrent
        } else if request == .setCurrent,
                  entityID == UVCRequestPolicy.cameraTerminalEntityID,
                  selector == UVCControlID.panTilt.selector,
                  let payload {
            panTiltCurrent = payload
            setPayloads.append(payload)
            bytes = payload
        } else {
            bytes = [UInt8](repeating: 0, count: expectedLength)
        }

        return UVCRequestResult(request: request, bytes: bytes, outcome: .success)
    }

    func requestSnapshot() -> [RecordedRequest] {
        requests
    }

    func setPayloadSnapshot() -> [[UInt8]] {
        setPayloads
    }
}

@MainActor
private func verifiedPocket(
    registryID: UInt64,
    locationID: UInt32 = 0x55,
    activeConfiguration: UInt64 = 1,
    enumerationState: UInt64 = 1
) -> PocketDevice {
    PocketDevice(
        registryID: registryID,
        vendorID: 0x2CA3,
        productID: 0x0023,
        manufacturer: "DJI",
        productIdentifier: "DJI Osmo Pocket 4",
        locationID: locationID,
        linkSpeed: USBLinkSpeed(bitsPerSecond: 480_000_000, rawSpeedCode: nil),
        activeConfiguration: activeConfiguration,
        enumerationState: enumerationState,
        identification: .confirmedPocket4VIDPID
    )
}

@MainActor
private func unverifiedPocket(registryID: UInt64, locationID: UInt32 = 0x66) -> PocketDevice {
    PocketDevice(
        registryID: registryID,
        vendorID: 0x2CA3,
        productID: 0x0020,
        manufacturer: "DJI",
        productIdentifier: "DJI Osmo Pocket 3",
        locationID: locationID,
        linkSpeed: USBLinkSpeed(bitsPerSecond: 480_000_000, rawSpeedCode: nil),
        activeConfiguration: 1,
        enumerationState: 1,
        identification: .djiOsmoPocketFamily
    )
}

private func blockedCurrentValue() -> UVCRequestResult {
    UVCRequestResult(
        request: .getCurrent,
        bytes: [],
        outcome: .blocked("The test fake does not perform writes.")
    )
}

private func successfulResult(_ request: UVCRequest, bytes: [UInt8]) -> UVCRequestResult {
    UVCRequestResult(request: request, bytes: bytes, outcome: .success)
}

private func failedResult(_ request: UVCRequest) -> UVCRequestResult {
    UVCRequestResult(
        request: request,
        bytes: [],
        outcome: .failed(
            status: -1,
            stage: .controlRequest,
            message: "Synthetic transport failure."
        )
    )
}

private func markedControlStates(marker: String) -> [UVCStandardControlState] {
    UVCControlID.allCases.map { control in
        var state = UVCStandardControlState.idle(control: control)
        state.capability = .detectedLive(marker)
        return state
    }
}

private func writeReadyControlStates() -> [UVCStandardControlState] {
    UVCControlID.allCases.map { control in
        var state = UVCStandardControlState.idle(control: control)
        guard control == .zoom else {
            return state
        }

        state.getInfo = successfulResult(.getInfo, bytes: [0x03])
        state.minimum = successfulResult(.getMinimum, bytes: [0x00, 0x00])
        state.maximum = successfulResult(.getMaximum, bytes: [0x64, 0x00])
        state.resolution = successfulResult(.getResolution, bytes: [0x01, 0x00])
        state.defaultValue = successfulResult(.getDefault, bytes: [0x0A, 0x00])
        state.currentValue = successfulResult(.getCurrent, bytes: [0x0A, 0x00])
        return state
    }
}

private func writeReadyControlState(for control: UVCControlID) -> UVCStandardControlState {
    var state = UVCStandardControlState.idle(control: control)
    state.getInfo = successfulResult(.getInfo, bytes: [0x03])

    switch control {
    case .zoom:
        state.minimum = successfulResult(.getMinimum, bytes: scalarBytes(0, for: .zoom))
        state.maximum = successfulResult(.getMaximum, bytes: scalarBytes(100, for: .zoom))
        state.resolution = successfulResult(.getResolution, bytes: scalarBytes(1, for: .zoom))
        state.defaultValue = successfulResult(.getDefault, bytes: scalarBytes(10, for: .zoom))
        state.currentValue = successfulResult(.getCurrent, bytes: scalarBytes(20, for: .zoom))
    case .roll:
        state.minimum = successfulResult(.getMinimum, bytes: scalarBytes(-10, for: .roll))
        state.maximum = successfulResult(.getMaximum, bytes: scalarBytes(10, for: .roll))
        state.resolution = successfulResult(.getResolution, bytes: scalarBytes(1, for: .roll))
        state.defaultValue = successfulResult(.getDefault, bytes: scalarBytes(0, for: .roll))
        state.currentValue = successfulResult(.getCurrent, bytes: scalarBytes(1, for: .roll))
    case .panTilt:
        state.minimum = successfulResult(
            .getMinimum,
            bytes: UVCValueCodec.encodePanTilt(UVCVector2(first: -100, second: -100))
        )
        state.maximum = successfulResult(
            .getMaximum,
            bytes: UVCValueCodec.encodePanTilt(UVCVector2(first: 100, second: 100))
        )
        state.resolution = successfulResult(
            .getResolution,
            bytes: UVCValueCodec.encodePanTilt(UVCVector2(first: 1, second: 1))
        )
        state.defaultValue = successfulResult(
            .getDefault,
            bytes: UVCValueCodec.encodePanTilt(UVCVector2(first: 5, second: -5))
        )
        state.currentValue = successfulResult(
            .getCurrent,
            bytes: UVCValueCodec.encodePanTilt(UVCVector2(first: 10, second: -20))
        )
    }

    return state
}

private func scalarBytes(_ value: Int64, for control: UVCControlID) -> [UInt8] {
    guard let bytes = UVCValueCodec.encodeScalar(value, for: control) else {
        fatalError("Scalar test fixture requires a scalar UVC control.")
    }
    return bytes
}

private func controlStates(
    _ overrides: [UVCControlID: UVCStandardControlState]
) -> [UVCStandardControlState] {
    UVCControlID.allCases.map { control in
        overrides[control] ?? UVCStandardControlState.idle(control: control)
    }
}

private func syntheticConnection(
    registryID: UInt64,
    generation: UInt64,
    locationID: UInt32 = 0xA0
) -> UVCTransportConnection {
    UVCTransportConnection(
        locationID: locationID,
        registryID: registryID,
        generation: generation
    )
}

private func expectedUVCPolicyTuples() -> Set<UVCPolicyTuple> {
    let cameraTerminalControls: [(selector: UInt8, length: Int)] = [
        (ExpectedUVCPolicyContract.zoomSelector, ExpectedUVCPolicyContract.scalarPayloadLength),
        (ExpectedUVCPolicyContract.panTiltSelector, ExpectedUVCPolicyContract.panTiltPayloadLength),
        (ExpectedUVCPolicyContract.rollSelector, ExpectedUVCPolicyContract.scalarPayloadLength),
    ]
    let cameraTerminalReadWriteRequests: [UVCRequest] = [
        .getCurrent,
        .getMinimum,
        .getMaximum,
        .getResolution,
        .getDefault,
        .setCurrent,
    ]
    var expected: Set<UVCPolicyTuple> = []

    for control in cameraTerminalControls {
        expected.insert(
            UVCPolicyTuple(
                request: UVCRequest.getInfo.rawValue,
                selector: control.selector,
                entityID: ExpectedUVCPolicyContract.cameraTerminalEntityID,
                expectedLength: 1
            )
        )
        for request in cameraTerminalReadWriteRequests {
            expected.insert(
                UVCPolicyTuple(
                    request: request.rawValue,
                    selector: control.selector,
                    entityID: ExpectedUVCPolicyContract.cameraTerminalEntityID,
                    expectedLength: control.length
                )
            )
        }
    }

    for selector in UInt8(1)...UInt8(3) {
        expected.insert(
            UVCPolicyTuple(
                request: UVCRequest.getInfo.rawValue,
                selector: selector,
                entityID: ExpectedUVCPolicyContract.extensionUnitEntityID,
                expectedLength: 1
            )
        )
        expected.insert(
            UVCPolicyTuple(
                request: UVCRequest.getLength.rawValue,
                selector: selector,
                entityID: ExpectedUVCPolicyContract.extensionUnitEntityID,
                expectedLength: 2
            )
        )
        for length in 1...ExpectedUVCPolicyContract.maximumExtensionUnitReadLength {
            expected.insert(
                UVCPolicyTuple(
                    request: UVCRequest.getCurrent.rawValue,
                    selector: selector,
                    entityID: ExpectedUVCPolicyContract.extensionUnitEntityID,
                    expectedLength: length
                )
            )
        }
    }

    return expected
}

private func markedExtensionSelectors(marker: String) -> [ExtensionUnitSelectorState] {
    (UInt8(1)...UInt8(3)).map { markedExtensionSelector(selector: $0, marker: marker) }
}

private func markedExtensionSelector(selector: UInt8, marker: String) -> ExtensionUnitSelectorState {
    var state = ExtensionUnitSelectorState.idle(selector: selector)
    state.capability = .detectedLive(marker)
    return state
}

@MainActor
private func drainTasks(_ count: Int = 64) async {
    for _ in 0..<count {
        await Task.yield()
    }
}

@MainActor
private func waitForDevice(_ session: DeviceSession, registryID: UInt64) async -> Bool {
    for _ in 0..<256 {
        if session.device?.registryID == registryID {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForCameraPermissionRequest(_ camera: FakeCameraAccess) async -> Bool {
    for _ in 0..<256 {
        if camera.permissionRequestCount == 1 {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForPreviewStart(_ preview: FakePreviewController) async -> Bool {
    for _ in 0..<256 {
        if preview.startCount == 1 {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForInspectionToFinish(_ session: DeviceSession, transport: FakeTransport) async -> Bool {
    for _ in 0..<1_024 {
        let requests = await transport.requestSnapshot()
        if !session.isInspecting, !requests.isEmpty {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForFakeInspectionToFinish(
    _ session: DeviceSession,
    inspector: FakeStandardControlInspector?
) async -> Bool {
    guard let inspector else {
        return false
    }

    for _ in 0..<1_024 {
        if !session.isInspecting, await inspector.inspectionCount() == 1 {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForStandardInspectionStart(_ inspector: FakeStandardControlInspector?) async -> Bool {
    guard let inspector else {
        return false
    }

    for _ in 0..<256 {
        if await inspector.inspectionCount() == 1 {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForInvalidation(_ transport: FakeTransport, minimumCount: Int) async -> Bool {
    for _ in 0..<256 {
        if await transport.invalidationCount() >= minimumCount {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForHeldExtensionWork(_ inspector: FakeExtensionUnitInspector?) async -> Bool {
    guard let inspector else {
        return false
    }

    for _ in 0..<512 {
        let refreshCount = await inspector.refreshCount()
        let snapshotCount = await inspector.snapshotCount()
        if refreshCount == 1, snapshotCount == 1 {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForWriteModeActivation(_ transport: FakeTransport) async -> Bool {
    for _ in 0..<512 {
        let operations = await transport.operationSnapshot()
        if operations.contains(where: {
            if case let .setWritesEnabled(enabled, _) = $0 {
                return enabled
            }
            return false
        }) {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForClockSleep(_ clock: FakeClock) async -> Bool {
    for _ in 0..<512 {
        if await clock.sleepCount() == 1 {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForScalarWrite(
    _ inspector: FakeStandardControlInspector?,
    count: Int
) async -> Bool {
    guard let inspector else {
        return false
    }

    for _ in 0..<512 {
        if await inspector.scalarWriteSnapshot().count == count {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForPanTiltWrite(
    _ inspector: FakeStandardControlInspector?,
    count: Int
) async -> Bool {
    guard let inspector else {
        return false
    }

    for _ in 0..<512 {
        if await inspector.panTiltWriteSnapshot().count == count {
            return true
        }
        await Task.yield()
    }
    return false
}
