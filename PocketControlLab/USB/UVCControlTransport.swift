import Foundation
import IOKit

/// An in-memory capability token for one observed USB enumeration. The bridge
/// also receives the registry ID, so a delayed request cannot bind to a new
/// device that reappears at the same physical USB location.
struct UVCTransportConnection: Equatable, Sendable {
    let locationID: UInt32
    let registryID: UInt64
    let generation: UInt64
}

/// The Swift-side allowlist mirrors the C bridge so invalid requests never
/// cause the transport to create a legacy IOKit user client. The bridge keeps
/// its independent validation as defense in depth.
enum UVCRequestPolicy {
    static let videoControlInterfaceNumber: UInt8 = 0
    static let cameraTerminalEntityID: UInt8 = 1
    static let extensionUnitEntityID: UInt8 = 6
    static let maximumExtensionUnitReadLength = 1024

    enum Violation: Equatable, Sendable {
        case connectionChanged
        case requestNotAllowed
        case payloadLengthMismatch

        var message: String {
            switch self {
            case .connectionChanged:
                "The USB connection changed before this request could be sent."
            case .requestNotAllowed:
                "This request is outside the lab's validated UVC control policy."
            case .payloadLengthMismatch:
                "Payload size does not match the validated UVC control layout."
            }
        }
    }

    /// Returns whether a request has an exact, policy-approved UVC layout.
    /// This intentionally includes length, because a valid selector with a
    /// malformed buffer must be treated as a different, prohibited request.
    static func allows(
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int
    ) -> Bool {
        guard (1...maximumExtensionUnitReadLength).contains(expectedLength) else {
            return false
        }

        switch entityID {
        case cameraTerminalEntityID:
            return allowsCameraTerminalRequest(
                request: request,
                selector: selector,
                expectedLength: expectedLength
            )
        case extensionUnitEntityID:
            return allowsExtensionUnitRequest(
                request: request,
                selector: selector,
                expectedLength: expectedLength
            )
        default:
            return false
        }
    }

    /// Performs every validation that can be decided without opening a bridge
    /// session. Tests can exercise this pure policy without C/IOKit access.
    static func validate(
        connection: UVCTransportConnection,
        activeConnection: UVCTransportConnection?,
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int,
        payload: [UInt8]?
    ) -> Violation? {
        guard activeConnection == connection else {
            return .connectionChanged
        }

        guard allows(
            request: request,
            selector: selector,
            entityID: entityID,
            expectedLength: expectedLength
        ) else {
            return .requestNotAllowed
        }

        if request == .setCurrent, payload == nil {
            return .payloadLengthMismatch
        }

        guard payload?.count == expectedLength || payload == nil else {
            return .payloadLengthMismatch
        }

        return nil
    }

    private static func allowsCameraTerminalRequest(
        request: UVCRequest,
        selector: UInt8,
        expectedLength: Int
    ) -> Bool {
        let controlLength: Int
        switch selector {
        case 0x0B, 0x0F: // Zoom Absolute, Roll Absolute
            controlLength = 2
        case 0x0D: // Pan/Tilt Absolute
            controlLength = 8
        default:
            return false
        }

        switch request {
        case .getInfo:
            return expectedLength == 1
        case .getCurrent, .getMinimum, .getMaximum, .getResolution, .getDefault, .setCurrent:
            return expectedLength == controlLength
        case .getLength:
            return false
        }
    }

    private static func allowsExtensionUnitRequest(
        request: UVCRequest,
        selector: UInt8,
        expectedLength: Int
    ) -> Bool {
        guard (1...3).contains(Int(selector)) else {
            return false
        }

        switch request {
        case .getInfo:
            return expectedLength == 1
        case .getLength:
            return expectedLength == 2
        case .getCurrent:
            return (1...maximumExtensionUnitReadLength).contains(expectedLength)
        case .setCurrent, .getMinimum, .getMaximum, .getResolution, .getDefault:
            return false
        }
    }
}

/// An internal seam around the C bridge. It is deliberately synchronous:
/// `UVCWriteAuthorizing` must serialize the authorization lease and the
/// eventual bridge call without an `await` in between.
protocol DirectUVCBridgeSession: Sendable {
    func perform(
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        interfaceNumber: UInt8,
        bytes: inout [UInt8]
    ) -> DirectUVCBridgeResponse
}

struct DirectUVCBridgeResponse: Sendable {
    let status: Int32
    let stage: DirectUVCStage
    let bytesTransferred: Int
}

struct DirectUVCBridgeOpenResult: Sendable {
    let session: (any DirectUVCBridgeSession)?
    let status: Int32
    let stage: DirectUVCStage
}

protocol DirectUVCBridging: Sendable {
    func open(locationID: UInt32, registryID: UInt64) -> DirectUVCBridgeOpenResult
}

/// Holds the opaque legacy IOKit pointer for the lifetime of one transport
/// session. The C bridge itself is the only code that can use this pointer.
/// The unchecked conformance is intentionally limited to this private wrapper:
/// actor isolation still serializes all requests made by `DirectUVCTransport`.
private final class DirectUVCSessionHandle: DirectUVCBridgeSession, @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        PocketUVCSessionDestroy(pointer)
    }

    func perform(
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        interfaceNumber: UInt8,
        bytes: inout [UInt8]
    ) -> DirectUVCBridgeResponse {
        let length = bytes.count
        var transferred: UInt32 = 0
        var rawStage: UInt32 = 0
        let status: Int32 = bytes.withUnsafeMutableBufferPointer { buffer in
            PocketUVCSessionPerform(
                pointer,
                request.rawValue,
                selector,
                entityID,
                interfaceNumber,
                buffer.baseAddress,
                UInt16(length),
                &transferred,
                &rawStage
            )
        }

        return DirectUVCBridgeResponse(
            status: status,
            stage: DirectUVCStage(rawStage: rawStage),
            bytesTransferred: Int(transferred)
        )
    }
}

private struct DirectUVCBridge: DirectUVCBridging {
    func open(locationID: UInt32, registryID: UInt64) -> DirectUVCBridgeOpenResult {
        var status: Int32 = 0
        var rawStage: UInt32 = 0
        let pointer = PocketUVCSessionCreate(locationID, registryID, &status, &rawStage)

        guard let pointer else {
            return DirectUVCBridgeOpenResult(
                session: nil,
                status: status,
                stage: DirectUVCStage(rawStage: rawStage)
            )
        }

        return DirectUVCBridgeOpenResult(
            session: DirectUVCSessionHandle(pointer: pointer),
            status: status,
            stage: DirectUVCStage(rawStage: rawStage)
        )
    }
}

/// A session-owned lease that serializes an explicit lock with the bridge call
/// that could send SET_CUR. The authorized closure must remain synchronous:
/// holding the lease across an `await` would make the lock ordering ambiguous.
protocol UVCWriteAuthorizing: Sendable {
    func performIfPermitted(
        for connection: UVCTransportConnection,
        operation: @Sendable () -> UVCRequestResult
    ) -> UVCRequestResult?
}

/// The narrow async surface used by session orchestration and the two UVC
/// inspectors. Keeping this protocol small lets the M0 test target exercise
/// lifecycle behaviour without opening IOKit user clients or the C bridge.
protocol UVCTransporting: Sendable {
    func activate(_ connection: UVCTransportConnection) async
    func invalidate() async
    func invalidate(upTo generation: UInt64) async
    func setWritesEnabled(_ enabled: Bool, for connection: UVCTransportConnection) async
    func disableWrites() async
    func perform(
        connection: UVCTransportConnection,
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int,
        payload: [UInt8]?,
        writeAuthorization: (any UVCWriteAuthorizing)?
    ) async -> UVCRequestResult
}

extension UVCTransporting {
    func perform(
        connection: UVCTransportConnection,
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int
    ) async -> UVCRequestResult {
        await perform(
            connection: connection,
            request: request,
            selector: selector,
            entityID: entityID,
            expectedLength: expectedLength,
            payload: nil,
            writeAuthorization: nil
        )
    }

    func perform(
        connection: UVCTransportConnection,
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int,
        payload: [UInt8]?
    ) async -> UVCRequestResult {
        await perform(
            connection: connection,
            request: request,
            selector: selector,
            entityID: entityID,
            expectedLength: expectedLength,
            payload: payload,
            writeAuthorization: nil
        )
    }
}

actor DirectUVCTransport: UVCTransporting {
    private let bridge: any DirectUVCBridging
    private var session: (any DirectUVCBridgeSession)?
    private var sessionConnection: UVCTransportConnection?
    private var activeConnection: UVCTransportConnection?
    private var blockedConnection: UVCTransportConnection?
    private var blockedReason: String?
    private var writesEnabled = false
    private var retiredThroughGeneration: UInt64 = 0

    init(bridge: any DirectUVCBridging = DirectUVCBridge()) {
        self.bridge = bridge
    }

    func activate(_ connection: UVCTransportConnection) {
        guard connection.generation >= retiredThroughGeneration else {
            return
        }

        session = nil
        sessionConnection = nil
        activeConnection = connection
        blockedConnection = nil
        blockedReason = nil
        writesEnabled = false
    }

    func invalidate() {
        session = nil
        sessionConnection = nil
        activeConnection = nil
        blockedConnection = nil
        blockedReason = nil
        writesEnabled = false
    }

    /// Retires every older session lease before clearing transport state. A
    /// canceled task that awakens later cannot reactivate its old connection.
    func invalidate(upTo generation: UInt64) {
        retiredThroughGeneration = max(retiredThroughGeneration, generation)

        // A delayed teardown from an older session may arrive after a newer
        // connection has been activated. It can retire its own lease but must
        // not clear the newer session or its write latch.
        guard activeConnection?.generation ?? 0 <= generation else {
            return
        }

        invalidate()
    }

    /// This is deliberately separate from whether a raw user client is
    /// available. A SET_CUR cannot reach the bridge until the UI has enabled
    /// this latch after discovery completed.
    func setWritesEnabled(_ enabled: Bool, for connection: UVCTransportConnection) {
        guard activeConnection == connection else {
            return
        }
        writesEnabled = enabled
    }

    func disableWrites() {
        writesEnabled = false
    }

    func perform(
        connection: UVCTransportConnection,
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int,
        payload: [UInt8]? = nil,
        writeAuthorization: (any UVCWriteAuthorizing)? = nil
    ) async -> UVCRequestResult {
        if let violation = UVCRequestPolicy.validate(
            connection: connection,
            activeConnection: activeConnection,
            request: request,
            selector: selector,
            entityID: entityID,
            expectedLength: expectedLength,
            payload: payload
        ) {
            switch violation {
            case .connectionChanged:
                return UVCRequestResult(
                    request: request,
                    bytes: [],
                    outcome: .blocked(violation.message)
                )
            case .requestNotAllowed, .payloadLengthMismatch:
                return UVCRequestResult(
                    request: request,
                    bytes: [],
                    outcome: .failed(
                        status: Int32(kIOReturnBadArgument),
                        stage: .requestValidation,
                        message: violation.message
                    )
                )
            }
        }

        if request == .setCurrent {
            guard writesEnabled else {
                return UVCRequestResult(
                    request: request,
                    bytes: [],
                    outcome: .blocked("UVC writes are disabled. SET_CUR is blocked by the transport safety latch.")
                )
            }

            guard writeAuthorization != nil else {
                return UVCRequestResult(
                    request: request,
                    bytes: [],
                    outcome: .blocked("UVC writes are no longer authorized for this session. SET_CUR was not sent.")
                )
            }
        }

        if blockedConnection == connection, let blockedReason {
            return UVCRequestResult(request: request, bytes: [], outcome: .blocked(blockedReason))
        }

        guard ensureSession(for: connection) else {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .blocked(blockedReason ?? "Direct UVC transport is unavailable.")
            )
        }

        let bytes = payload ?? [UInt8](repeating: 0, count: expectedLength)

        guard let session else {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .blocked("Direct UVC transport is unavailable.")
            )
        }

        let bridgeOperation = { @Sendable [session, bytes] in
            Self.performBridgeRequest(
                session: session,
                request: request,
                selector: selector,
                entityID: entityID,
                expectedLength: expectedLength,
                bytes: bytes
            )
        }

        guard request == .setCurrent else {
            return bridgeOperation()
        }

        guard let result = writeAuthorization?.performIfPermitted(
            for: connection,
            operation: bridgeOperation
        ) else {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .blocked("UVC writes are no longer authorized for this session. SET_CUR was not sent.")
            )
        }

        return result
    }

    /// Called only by the direct transport after it has validated the request
    /// and obtained a live bridge session. SET_CUR invokes this inside the
    /// session write lease so an explicit lock and the bridge call are
    /// linearly ordered.
    private nonisolated static func performBridgeRequest(
        session: any DirectUVCBridgeSession,
        request: UVCRequest,
        selector: UInt8,
        entityID: UInt8,
        expectedLength: Int,
        bytes: [UInt8]
    ) -> UVCRequestResult {
        var mutableBytes = bytes
        let response = session.perform(
            request: request,
            selector: selector,
            entityID: entityID,
            interfaceNumber: UVCRequestPolicy.videoControlInterfaceNumber,
            bytes: &mutableBytes
        )

        guard response.status == Int32(kIOReturnSuccess) else {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .failed(
                    status: response.status,
                    stage: response.stage,
                    message: statusMessage(for: response.status)
                )
            )
        }

        guard response.bytesTransferred == expectedLength else {
            let receivedLength = min(max(response.bytesTransferred, 0), mutableBytes.count)
            return UVCRequestResult(
                request: request,
                bytes: Array(mutableBytes.prefix(receivedLength)),
                outcome: .failed(
                    status: response.status,
                    stage: response.stage,
                    message: "Short transfer: expected \(expectedLength) byte(s), received \(response.bytesTransferred)."
                )
            )
        }

        return UVCRequestResult(request: request, bytes: mutableBytes, outcome: .success)
    }

    private func ensureSession(for connection: UVCTransportConnection) -> Bool {
        guard activeConnection == connection else {
            return false
        }

        if session != nil, sessionConnection == connection {
            return true
        }

        session = nil
        sessionConnection = nil

        let openResult = bridge.open(
            locationID: connection.locationID,
            registryID: connection.registryID
        )
        guard let newSession = openResult.session else {
            let reason = "\(openResult.stage.displayName) failed: \(Self.statusMessage(for: openResult.status)) (0x\(String(format: "%08X", UInt32(bitPattern: openResult.status))))."

            if openResult.stage == .pluginCreation || openResult.stage == .interfaceQuery {
                blockedConnection = connection
                blockedReason = "\(reason) The app will not open, seize, or otherwise take over the UVC interface."
            } else {
                blockedConnection = connection
                blockedReason = reason
            }
            return false
        }

        session = newSession
        sessionConnection = connection
        return true
    }

    private nonisolated static func statusMessage(for status: Int32) -> String {
        switch UInt32(bitPattern: status) {
        case 0xE00002BE:
            "kIOReturnNoResources"
        case 0xE00002C0:
            "kIOReturnNotOpen"
        case 0xE00002C1:
            "kIOReturnUnsupported"
        case 0xE00002C2:
            "kIOReturnBadArgument"
        case 0xE00002C7:
            "kIOReturnNotFound"
        case 0xE00002C8:
            "kIOReturnNotReady"
        case 0xE00002C9:
            "kIOReturnNotAttached"
        case 0xE00002D4:
            "kIOReturnExclusiveAccess"
        default:
            "IOReturn"
        }
    }
}
