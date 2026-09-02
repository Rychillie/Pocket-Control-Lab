import Foundation

enum UVCControlID: String, CaseIterable, Hashable, Identifiable, Sendable {
    case zoom
    case panTilt
    case roll

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .zoom:
            "Zoom Absolute"
        case .panTilt:
            "Pan/Tilt Absolute"
        case .roll:
            "Roll Absolute"
        }
    }

    var selector: UInt8 {
        switch self {
        case .zoom:
            0x0B
        case .panTilt:
            0x0D
        case .roll:
            0x0F
        }
    }

    var expectedPayloadLength: Int {
        switch self {
        case .zoom, .roll:
            2
        case .panTilt:
            8
        }
    }

    var descriptorEvidence: CapabilityEvidence {
        .knownPreviousDescriptor("Advertised by the prior Pocket 4 Camera Terminal descriptor")
    }
}

enum UVCRequest: UInt8, CaseIterable, Sendable {
    case setCurrent = 0x01
    case getCurrent = 0x81
    case getMinimum = 0x82
    case getMaximum = 0x83
    case getResolution = 0x84
    case getLength = 0x85
    case getInfo = 0x86
    case getDefault = 0x87

    var displayName: String {
        switch self {
        case .setCurrent:
            "SET_CUR"
        case .getCurrent:
            "GET_CUR"
        case .getMinimum:
            "GET_MIN"
        case .getMaximum:
            "GET_MAX"
        case .getResolution:
            "GET_RES"
        case .getLength:
            "GET_LEN"
        case .getInfo:
            "GET_INFO"
        case .getDefault:
            "GET_DEF"
        }
    }
}

enum DirectUVCStage: UInt32, Equatable, Sendable {
    case none = 0
    case deviceLookup = 1
    case pluginCreation = 2
    case interfaceQuery = 3
    case requestValidation = 4
    case controlRequest = 5
    case unknown = 999

    init(rawStage: UInt32) {
        self = DirectUVCStage(rawValue: rawStage) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .none:
            "none"
        case .deviceLookup:
            "device lookup"
        case .pluginCreation:
            "IOKit user-client creation"
        case .interfaceQuery:
            "IOUSBLib interface query"
        case .requestValidation:
            "safety validation"
        case .controlRequest:
            "UVC control request"
        case .unknown:
            "unknown stage"
        }
    }
}

struct UVCRequestResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case pending
        case success
        case blocked(String)
        case failed(status: Int32, stage: DirectUVCStage, message: String)
    }

    let request: UVCRequest
    let bytes: [UInt8]
    let outcome: Outcome

    static func pending(_ request: UVCRequest) -> UVCRequestResult {
        UVCRequestResult(request: request, bytes: [], outcome: .pending)
    }

    var isSuccess: Bool {
        if case .success = outcome {
            true
        } else {
            false
        }
    }

    var hexadecimal: String {
        guard !bytes.isEmpty else {
            return "—"
        }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var statusDescription: String {
        switch outcome {
        case .pending:
            "Not queried"
        case .success:
            hexadecimal
        case let .blocked(reason):
            "Blocked — \(reason)"
        case let .failed(status, stage, message):
            "\(stage.displayName): \(message) (0x\(String(format: "%08X", UInt32(bitPattern: status))))"
        }
    }
}

enum CapabilityEvidence: Equatable, Sendable {
    case detectedLive(String)
    case knownPreviousDescriptor(String)
    case unavailable(String)

    var label: String {
        switch self {
        case let .detectedLive(detail):
            "Detected live — \(detail)"
        case let .knownPreviousDescriptor(detail):
            "Known from previous descriptor — \(detail)"
        case let .unavailable(detail):
            "Not observed — \(detail)"
        }
    }

    var isLive: Bool {
        if case .detectedLive = self {
            true
        } else {
            false
        }
    }

    var statusLabel: String {
        switch self {
        case .detectedLive:
            "LIVE YES"
        case .knownPreviousDescriptor:
            "KNOWN"
        case .unavailable:
            "NO"
        }
    }
}

struct UVCVector2: Equatable, Sendable {
    var first: Int32
    var second: Int32

    var description: String {
        "\(first), \(second)"
    }
}

struct UVCScalarRange: Equatable, Sendable {
    let minimum: Int64
    let maximum: Int64
    let resolution: Int64
    let defaultValue: Int64
    let currentValue: Int64

    var isValidForWrites: Bool {
        minimum <= maximum
            && resolution > 0
            && defaultValue >= minimum
            && defaultValue <= maximum
            && currentValue >= minimum
            && currentValue <= maximum
    }
}

struct UVCVectorRange: Equatable, Sendable {
    let minimum: UVCVector2
    let maximum: UVCVector2
    let resolution: UVCVector2
    let defaultValue: UVCVector2
    let currentValue: UVCVector2

    var isValidForWrites: Bool {
        minimum.first <= maximum.first
            && minimum.second <= maximum.second
            && resolution.first > 0
            && resolution.second > 0
            && defaultValue.first >= minimum.first
            && defaultValue.first <= maximum.first
            && defaultValue.second >= minimum.second
            && defaultValue.second <= maximum.second
            && currentValue.first >= minimum.first
            && currentValue.first <= maximum.first
            && currentValue.second >= minimum.second
            && currentValue.second <= maximum.second
    }
}

enum UVCControlRange: Equatable, Sendable {
    case scalar(UVCScalarRange)
    case vector(UVCVectorRange)
}

struct UVCStandardControlState: Identifiable, Equatable, Sendable {
    let control: UVCControlID
    var capability: CapabilityEvidence
    var cmioObservation: CMIOControlObservation?
    var getInfo: UVCRequestResult
    var minimum: UVCRequestResult
    var maximum: UVCRequestResult
    var resolution: UVCRequestResult
    var defaultValue: UVCRequestResult
    var currentValue: UVCRequestResult

    var id: String {
        control.id
    }

    static func idle(control: UVCControlID) -> UVCStandardControlState {
        UVCStandardControlState(
            control: control,
            capability: control.descriptorEvidence,
            cmioObservation: nil,
            getInfo: .pending(.getInfo),
            minimum: .pending(.getMinimum),
            maximum: .pending(.getMaximum),
            resolution: .pending(.getResolution),
            defaultValue: .pending(.getDefault),
            currentValue: .pending(.getCurrent)
        )
    }

    static func unavailable(control: UVCControlID, reason: String) -> UVCStandardControlState {
        UVCStandardControlState(
            control: control,
            capability: .unavailable(reason),
            cmioObservation: nil,
            getInfo: .blocked(.getInfo, reason: reason),
            minimum: .blocked(.getMinimum, reason: reason),
            maximum: .blocked(.getMaximum, reason: reason),
            resolution: .blocked(.getResolution, reason: reason),
            defaultValue: .blocked(.getDefault, reason: reason),
            currentValue: .blocked(.getCurrent, reason: reason)
        )
    }

    var getInfoByte: UInt8? {
        getInfo.isSuccess && getInfo.bytes.count == 1 ? getInfo.bytes[0] : nil
    }

    var supportsGet: Bool {
        guard let getInfoByte else {
            return false
        }
        return getInfoByte & 0x01 != 0
    }

    var supportsSet: Bool {
        guard let getInfoByte else {
            return false
        }
        return getInfoByte & 0x02 != 0
    }

    var range: UVCControlRange? {
        UVCValueCodec.makeRange(
            control: control,
            minimum: minimum.bytes,
            maximum: maximum.bytes,
            resolution: resolution.bytes,
            defaultValue: defaultValue.bytes,
            currentValue: currentValue.bytes,
            allRequestsSucceeded: minimum.isSuccess
                && maximum.isSuccess
                && resolution.isSuccess
                && defaultValue.isSuccess
                && currentValue.isSuccess
        )
    }

    var isWriteReady: Bool {
        guard supportsGet, supportsSet else {
            return false
        }

        return switch range {
        case let .scalar(range):
            range.isValidForWrites
        case let .vector(range):
            range.isValidForWrites
        case nil:
            false
        }
    }
}

private extension UVCRequestResult {
    static func blocked(_ request: UVCRequest, reason: String) -> UVCRequestResult {
        UVCRequestResult(request: request, bytes: [], outcome: .blocked(reason))
    }
}

enum UVCValueCodec {
    static func makeRange(
        control: UVCControlID,
        minimum: [UInt8],
        maximum: [UInt8],
        resolution: [UInt8],
        defaultValue: [UInt8],
        currentValue: [UInt8],
        allRequestsSucceeded: Bool
    ) -> UVCControlRange? {
        guard allRequestsSucceeded else {
            return nil
        }

        switch control {
        case .zoom:
            guard let minimum = decodeUnsigned16(minimum),
                  let maximum = decodeUnsigned16(maximum),
                  let resolution = decodeUnsigned16(resolution),
                  let defaultValue = decodeUnsigned16(defaultValue),
                  let currentValue = decodeUnsigned16(currentValue)
            else {
                return nil
            }
            return .scalar(
                UVCScalarRange(
                    minimum: Int64(minimum),
                    maximum: Int64(maximum),
                    resolution: Int64(resolution),
                    defaultValue: Int64(defaultValue),
                    currentValue: Int64(currentValue)
                )
            )
        case .roll:
            guard let minimum = decodeSigned16(minimum),
                  let maximum = decodeSigned16(maximum),
                  let resolution = decodeSigned16(resolution),
                  let defaultValue = decodeSigned16(defaultValue),
                  let currentValue = decodeSigned16(currentValue)
            else {
                return nil
            }
            return .scalar(
                UVCScalarRange(
                    minimum: Int64(minimum),
                    maximum: Int64(maximum),
                    resolution: Int64(resolution),
                    defaultValue: Int64(defaultValue),
                    currentValue: Int64(currentValue)
                )
            )
        case .panTilt:
            guard let minimum = decodePanTilt(minimum),
                  let maximum = decodePanTilt(maximum),
                  let resolution = decodePanTilt(resolution),
                  let defaultValue = decodePanTilt(defaultValue),
                  let currentValue = decodePanTilt(currentValue)
            else {
                return nil
            }
            return .vector(
                UVCVectorRange(
                    minimum: minimum,
                    maximum: maximum,
                    resolution: resolution,
                    defaultValue: defaultValue,
                    currentValue: currentValue
                )
            )
        }
    }

    static func encodeScalar(_ value: Int64, for control: UVCControlID) -> [UInt8]? {
        switch control {
        case .zoom:
            guard let unsignedValue = UInt16(exactly: value) else {
                return nil
            }
            return [
                UInt8(truncatingIfNeeded: unsignedValue),
                UInt8(truncatingIfNeeded: unsignedValue >> 8),
            ]
        case .roll:
            guard let signedValue = Int16(exactly: value) else {
                return nil
            }
            let bits = UInt16(bitPattern: signedValue)
            return [
                UInt8(truncatingIfNeeded: bits),
                UInt8(truncatingIfNeeded: bits >> 8),
            ]
        case .panTilt:
            return nil
        }
    }

    static func encodePanTilt(_ value: UVCVector2) -> [UInt8] {
        encodeSigned32(value.first) + encodeSigned32(value.second)
    }

    static func decodePanTilt(_ bytes: [UInt8]) -> UVCVector2? {
        guard bytes.count == 8,
              let first = decodeSigned32(Array(bytes[0..<4])),
              let second = decodeSigned32(Array(bytes[4..<8]))
        else {
            return nil
        }
        return UVCVector2(first: first, second: second)
    }

    static func decodeScalar(_ bytes: [UInt8], for control: UVCControlID) -> Int64? {
        switch control {
        case .zoom:
            decodeUnsigned16(bytes).map(Int64.init)
        case .roll:
            decodeSigned16(bytes).map(Int64.init)
        case .panTilt:
            nil
        }
    }

    private static func decodeUnsigned16(_ bytes: [UInt8]) -> UInt16? {
        guard bytes.count == 2 else {
            return nil
        }
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    private static func decodeSigned16(_ bytes: [UInt8]) -> Int16? {
        guard let bits = decodeUnsigned16(bytes) else {
            return nil
        }
        return Int16(bitPattern: bits)
    }

    private static func decodeSigned32(_ bytes: [UInt8]) -> Int32? {
        guard bytes.count == 4 else {
            return nil
        }
        let bits = UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
        return Int32(bitPattern: bits)
    }

    private static func encodeSigned32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [
            UInt8(truncatingIfNeeded: bits),
            UInt8(truncatingIfNeeded: bits >> 8),
            UInt8(truncatingIfNeeded: bits >> 16),
            UInt8(truncatingIfNeeded: bits >> 24),
        ]
    }
}
