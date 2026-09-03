import CoreMediaIO
import Foundation

struct UVCWriteOutcome: Sendable {
    let control: UVCControlID
    let oldValue: UVCRequestResult
    let requestedDescription: String
    let setResult: UVCRequestResult?
    let resultingValue: UVCRequestResult?
}

protocol StandardControlInspecting: Sendable {
    func inspect(
        connection: UVCTransportConnection,
        cmioObservations: [UVCControlID: CMIOControlObservation]
    ) async -> [UVCStandardControlState]
    func setScalar(
        control: UVCControlID,
        value: Int64,
        connection: UVCTransportConnection,
        writeAuthorization: any UVCWriteAuthorizing
    ) async -> UVCWriteOutcome
    func setPanTilt(
        pan: Int32?,
        tilt: Int32?,
        connection: UVCTransportConnection,
        writeAuthorization: any UVCWriteAuthorizing
    ) async -> UVCWriteOutcome
}

actor UVCStandardControls: StandardControlInspecting {
    private let transport: any UVCTransporting

    init(transport: any UVCTransporting) {
        self.transport = transport
    }

    func inspect(
        connection: UVCTransportConnection,
        cmioObservations: [UVCControlID: CMIOControlObservation]
    ) async -> [UVCStandardControlState] {
        var controls: [UVCStandardControlState] = []

        for control in UVCControlID.allCases {
            var state = UVCStandardControlState.idle(control: control)
            state.cmioObservation = cmioObservations[control]

            if let cmioObservation = state.cmioObservation {
                state.capability = .detectedLive(
                    "CoreMediaIO exposed \(cmioObservation.className) (object \(cmioObservation.id))"
                )
            }

            state.getInfo = await read(control: control, request: .getInfo, connection: connection)
            state.minimum = await read(control: control, request: .getMinimum, connection: connection)
            state.maximum = await read(control: control, request: .getMaximum, connection: connection)
            state.resolution = await read(control: control, request: .getResolution, connection: connection)
            state.defaultValue = await read(control: control, request: .getDefault, connection: connection)
            state.currentValue = await read(control: control, request: .getCurrent, connection: connection)

            if state.getInfo.isSuccess {
                state.capability = .detectedLive("Direct UVC GET_INFO succeeded")
            }

            controls.append(state)
        }

        return controls
    }

    func setScalar(
        control: UVCControlID,
        value: Int64,
        connection: UVCTransportConnection,
        writeAuthorization: any UVCWriteAuthorizing
    ) async -> UVCWriteOutcome {
        let oldValue = await read(control: control, request: .getCurrent, connection: connection)
        guard let payload = UVCValueCodec.encodeScalar(value, for: control) else {
            return UVCWriteOutcome(
                control: control,
                oldValue: oldValue,
                requestedDescription: "\(value)",
                setResult: UVCRequestResult(
                    request: .setCurrent,
                    bytes: [],
                    outcome: .failed(
                        status: Int32(kIOReturnBadArgument),
                        stage: .requestValidation,
                        message: "The requested value does not fit the validated UVC payload."
                    )
                ),
                resultingValue: nil
            )
        }

        let setResult = await transport.perform(
            connection: connection,
            request: .setCurrent,
            selector: control.selector,
            entityID: 1,
            expectedLength: control.expectedPayloadLength,
            payload: payload,
            writeAuthorization: writeAuthorization
        )
        let resultingValue = await read(control: control, request: .getCurrent, connection: connection)

        return UVCWriteOutcome(
            control: control,
            oldValue: oldValue,
            requestedDescription: "\(value)",
            setResult: setResult,
            resultingValue: resultingValue
        )
    }

    func setPanTilt(
        pan: Int32?,
        tilt: Int32?,
        connection: UVCTransportConnection,
        writeAuthorization: any UVCWriteAuthorizing
    ) async -> UVCWriteOutcome {
        let oldValue = await read(control: .panTilt, request: .getCurrent, connection: connection)
        guard let current = UVCValueCodec.decodePanTilt(oldValue.bytes) else {
            return UVCWriteOutcome(
                control: .panTilt,
                oldValue: oldValue,
                requestedDescription: "pan=\(pan.map { String($0) } ?? "unchanged"), tilt=\(tilt.map { String($0) } ?? "unchanged")",
                setResult: nil,
                resultingValue: nil
            )
        }

        let requested = UVCVector2(
            first: pan ?? current.first,
            second: tilt ?? current.second
        )
        let setResult = await transport.perform(
            connection: connection,
            request: .setCurrent,
            selector: UVCControlID.panTilt.selector,
            entityID: 1,
            expectedLength: UVCControlID.panTilt.expectedPayloadLength,
            payload: UVCValueCodec.encodePanTilt(requested),
            writeAuthorization: writeAuthorization
        )
        let resultingValue = await read(control: .panTilt, request: .getCurrent, connection: connection)

        return UVCWriteOutcome(
            control: .panTilt,
            oldValue: oldValue,
            requestedDescription: "pan=\(requested.first), tilt=\(requested.second)",
            setResult: setResult,
            resultingValue: resultingValue
        )
    }

    private func read(
        control: UVCControlID,
        request: UVCRequest,
        connection: UVCTransportConnection
    ) async -> UVCRequestResult {
        let expectedLength = request == .getInfo ? 1 : control.expectedPayloadLength
        return await transport.perform(
            connection: connection,
            request: request,
            selector: control.selector,
            entityID: 1,
            expectedLength: expectedLength
        )
    }
}

@MainActor
enum CMIOStandardControlInspector {
    static func inspect(
        camera: CameraDeviceInfo?,
        pocket: PocketDevice
    ) -> [UVCControlID: CMIOControlObservation] {
        guard pocket.supportsPocket4ControlProfile else {
            return [:]
        }

        let candidateDevices = CMIOPropertyReader.objectIDs(
            objectID: CMIOObjectID(kCMIOObjectSystemObject),
            selector: UInt32(kCMIOHardwarePropertyDevices)
        )

        let pocketDevice = candidateDevices.first { deviceID in
            matchesPocketDevice(deviceID, camera: camera, pocket: pocket)
        }

        guard let pocketDevice else {
            return [:]
        }

        let ownedObjects = CMIOPropertyReader.objectIDs(
            objectID: pocketDevice,
            selector: UInt32(kCMIOObjectPropertyOwnedObjects)
        )

        var result: [UVCControlID: CMIOControlObservation] = [:]
        for objectID in ownedObjects {
            guard let classID = CMIOPropertyReader.uint32(
                objectID: objectID,
                selector: UInt32(kCMIOObjectPropertyClass)
            ),
            let control = control(for: classID)
            else {
                continue
            }

            result[control] = CMIOControlObservation(
                id: objectID,
                controlName: CMIOPropertyReader.string(
                    objectID: objectID,
                    selector: UInt32(kCMIOObjectPropertyName)
                ) ?? control.displayName,
                className: className(for: classID),
                isSettable: CMIOPropertyReader.isSettable(
                    objectID: objectID,
                    selector: UInt32(kCMIOFeatureControlPropertyNativeData)
                ) ?? CMIOPropertyReader.isSettable(
                    objectID: objectID,
                    selector: UInt32(kCMIOFeatureControlPropertyNativeValue)
                ),
                nativeValue: CMIOPropertyReader.data(
                    objectID: objectID,
                    selector: UInt32(kCMIOFeatureControlPropertyNativeData)
                ) ?? CMIOPropertyReader.data(
                    objectID: objectID,
                    selector: UInt32(kCMIOFeatureControlPropertyNativeValue)
                ),
                nativeRange: CMIOPropertyReader.data(
                    objectID: objectID,
                    selector: UInt32(kCMIOFeatureControlPropertyNativeDataRange)
                ) ?? CMIOPropertyReader.data(
                    objectID: objectID,
                    selector: UInt32(kCMIOFeatureControlPropertyNativeRange)
                ),
                absoluteValue: CMIOPropertyReader.float32(
                    objectID: objectID,
                    selector: UInt32(kCMIOFeatureControlPropertyAbsoluteValue)
                ),
                absoluteRange: CMIOPropertyReader.data(
                    objectID: objectID,
                    selector: UInt32(kCMIOFeatureControlPropertyAbsoluteRange)
                )
            )
        }

        return result
    }

    private static func matchesPocketDevice(
        _ objectID: CMIOObjectID,
        camera: CameraDeviceInfo?,
        pocket: PocketDevice
    ) -> Bool {
        let deviceUID = CMIOPropertyReader.string(
            objectID: objectID,
            selector: UInt32(kCMIODevicePropertyDeviceUID)
        )

        // The driver-owned UID is the strongest available correlation between
        // AVCapture and CoreMediaIO. It also avoids inspecting a different DJI
        // camera that happens to be attached at the same time.
        if let camera, let deviceUID,
           deviceUID.caseInsensitiveCompare(camera.uniqueID) == .orderedSame {
            return true
        }

        let values = [
            CMIOPropertyReader.string(objectID: objectID, selector: UInt32(kCMIOObjectPropertyName)),
            CMIOPropertyReader.string(objectID: objectID, selector: UInt32(kCMIOObjectPropertyManufacturer)),
            deviceUID,
            camera?.localizedName,
            camera?.manufacturer,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        return values.contains(pocket.cameraMatchingToken)
    }

    private static func control(for classID: UInt32) -> UVCControlID? {
        switch classID {
        case UInt32(kCMIOZoomControlClassID):
            .zoom
        case UInt32(kCMIOPanTiltAbsoluteControlClassID):
            .panTilt
        case UInt32(kCMIORollAbsoluteControlClassID):
            .roll
        default:
            nil
        }
    }

    private static func className(for classID: UInt32) -> String {
        switch classID {
        case UInt32(kCMIOZoomControlClassID):
            "kCMIOZoomControlClassID"
        case UInt32(kCMIOPanTiltAbsoluteControlClassID):
            "kCMIOPanTiltAbsoluteControlClassID"
        case UInt32(kCMIORollAbsoluteControlClassID):
            "kCMIORollAbsoluteControlClassID"
        default:
            "Unknown CMIO control class"
        }
    }
}

private enum CMIOPropertyReader {
    static func data(objectID: CMIOObjectID, selector: UInt32) -> [UInt8]? {
        var address = address(selector)
        guard CMIOObjectHasProperty(objectID, &address) else {
            return nil
        }

        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else {
            return nil
        }

        guard size > 0 else {
            return []
        }

        var bytes = [UInt8](repeating: 0, count: Int(size))
        var used: UInt32 = 0
        let result = bytes.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                size,
                &used,
                buffer.baseAddress
            )
        }

        guard result == noErr else {
            return nil
        }
        return Array(bytes.prefix(Int(used)))
    }

    static func uint32(objectID: CMIOObjectID, selector: UInt32) -> UInt32? {
        guard let bytes = data(objectID: objectID, selector: selector),
              bytes.count == MemoryLayout<UInt32>.size
        else {
            return nil
        }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    static func float32(objectID: CMIOObjectID, selector: UInt32) -> Float? {
        guard let bytes = data(objectID: objectID, selector: selector),
              bytes.count == MemoryLayout<Float>.size
        else {
            return nil
        }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    static func objectIDs(objectID: CMIOObjectID, selector: UInt32) -> [CMIOObjectID] {
        guard let bytes = data(objectID: objectID, selector: selector),
              bytes.count.isMultiple(of: MemoryLayout<CMIOObjectID>.size)
        else {
            return []
        }

        return stride(from: 0, to: bytes.count, by: MemoryLayout<CMIOObjectID>.size).map { offset in
            bytes.withUnsafeBytes { buffer in
                buffer.loadUnaligned(fromByteOffset: offset, as: CMIOObjectID.self)
            }
        }
    }

    static func string(objectID: CMIOObjectID, selector: UInt32) -> String? {
        guard let bytes = data(objectID: objectID, selector: selector),
              bytes.count == MemoryLayout<UnsafeRawPointer?>.size
        else {
            return nil
        }

        guard let pointer = bytes.withUnsafeBytes({
            $0.loadUnaligned(as: UnsafeRawPointer?.self)
        }) else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue() as String
    }

    static func isSettable(objectID: CMIOObjectID, selector: UInt32) -> Bool? {
        var address = address(selector)
        guard CMIOObjectHasProperty(objectID, &address) else {
            return nil
        }

        var settable = DarwinBoolean(false)
        guard CMIOObjectIsPropertySettable(objectID, &address, &settable) == noErr else {
            return nil
        }
        return settable.boolValue
    }

    private static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
    }
}
