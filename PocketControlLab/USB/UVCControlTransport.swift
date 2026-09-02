import Foundation
import IOKit

/// Holds the opaque legacy IOKit pointer for the lifetime of one transport
/// session. The C bridge itself is the only code that can use this pointer.
/// The unchecked conformance is intentionally limited to this private wrapper:
/// actor isolation still serializes all requests made by `DirectUVCTransport`.
private final class DirectUVCSessionHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        PocketUVCSessionDestroy(pointer)
    }
}

/// An in-memory capability token for one observed USB enumeration. The bridge
/// also receives the registry ID, so a delayed request cannot bind to a new
/// device that reappears at the same physical USB location.
struct UVCTransportConnection: Equatable, Sendable {
    let locationID: UInt32
    let registryID: UInt64
    let generation: UInt64
}

actor DirectUVCTransport {
    private var session: DirectUVCSessionHandle?
    private var sessionConnection: UVCTransportConnection?
    private var activeConnection: UVCTransportConnection?
    private var blockedConnection: UVCTransportConnection?
    private var blockedReason: String?
    private var writesEnabled = false

    func activate(_ connection: UVCTransportConnection) {
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
        payload: [UInt8]? = nil
    ) -> UVCRequestResult {
        guard activeConnection == connection else {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .blocked("The USB connection changed before this request could be sent.")
            )
        }

        guard expectedLength > 0, expectedLength <= 1024 else {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .failed(
                    status: Int32(kIOReturnBadArgument),
                    stage: .requestValidation,
                    message: "The requested buffer length is outside this lab's safe bound."
                )
            )
        }

        if request == .setCurrent, !writesEnabled {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .blocked("UVC writes are disabled. SET_CUR is blocked by the transport safety latch.")
            )
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

        var bytes = payload ?? [UInt8](repeating: 0, count: expectedLength)
        guard bytes.count == expectedLength else {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .failed(
                    status: Int32(kIOReturnBadArgument),
                    stage: .requestValidation,
                    message: "Payload size does not match the validated UVC control layout."
                )
            )
        }

        var transferred: UInt32 = 0
        var rawStage: UInt32 = 0
        let status: Int32 = bytes.withUnsafeMutableBufferPointer { buffer in
            PocketUVCSessionPerform(
                session?.pointer,
                request.rawValue,
                selector,
                entityID,
                0,
                buffer.baseAddress,
                UInt16(expectedLength),
                &transferred,
                &rawStage
            )
        }

        let stage = DirectUVCStage(rawStage: rawStage)
        guard status == Int32(kIOReturnSuccess) else {
            return UVCRequestResult(
                request: request,
                bytes: [],
                outcome: .failed(status: status, stage: stage, message: statusMessage(for: status))
            )
        }

        guard transferred == UInt32(expectedLength) else {
            return UVCRequestResult(
                request: request,
                bytes: Array(bytes.prefix(Int(transferred))),
                outcome: .failed(
                    status: status,
                    stage: stage,
                    message: "Short transfer: expected \(expectedLength) byte(s), received \(transferred)."
                )
            )
        }

        return UVCRequestResult(request: request, bytes: bytes, outcome: .success)
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

        var status: Int32 = 0
        var rawStage: UInt32 = 0
        let newSession = PocketUVCSessionCreate(
            connection.locationID,
            connection.registryID,
            &status,
            &rawStage
        )
        guard let newSession else {
            let stage = DirectUVCStage(rawStage: rawStage)
            let reason = "\(stage.displayName) failed: \(statusMessage(for: status)) (0x\(String(format: "%08X", UInt32(bitPattern: status))))."

            if stage == .pluginCreation || stage == .interfaceQuery {
                blockedConnection = connection
                blockedReason = "\(reason) The app will not open, seize, or otherwise take over the UVC interface."
            } else {
                blockedConnection = connection
                blockedReason = reason
            }
            return false
        }

        session = DirectUVCSessionHandle(pointer: newSession)
        sessionConnection = connection
        return true
    }

    private func statusMessage(for status: Int32) -> String {
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
