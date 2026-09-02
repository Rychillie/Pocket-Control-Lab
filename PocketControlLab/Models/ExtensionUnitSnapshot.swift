import Foundation

struct ExtensionUnitSelectorState: Identifiable, Equatable, Sendable {
    let selector: UInt8
    var capability: CapabilityEvidence
    var getInfo: UVCRequestResult
    var getLength: UVCRequestResult
    var currentValue: UVCRequestResult

    var id: UInt8 {
        selector
    }

    static func idle(selector: UInt8) -> ExtensionUnitSelectorState {
        ExtensionUnitSelectorState(
            selector: selector,
            capability: .knownPreviousDescriptor("Candidate from bmControls 0x07; bNumControls reports 2"),
            getInfo: .pending(.getInfo),
            getLength: .pending(.getLength),
            currentValue: .pending(.getCurrent)
        )
    }

    static func unavailable(selector: UInt8, reason: String) -> ExtensionUnitSelectorState {
        ExtensionUnitSelectorState(
            selector: selector,
            capability: .unavailable(reason),
            getInfo: UVCRequestResult(request: .getInfo, bytes: [], outcome: .blocked(reason)),
            getLength: UVCRequestResult(request: .getLength, bytes: [], outcome: .blocked(reason)),
            currentValue: UVCRequestResult(request: .getCurrent, bytes: [], outcome: .blocked(reason))
        )
    }

    var length: Int? {
        guard getLength.isSuccess, getLength.bytes.count == 2 else {
            return nil
        }
        return Int(UInt16(getLength.bytes[0]) | UInt16(getLength.bytes[1]) << 8)
    }
}

struct ExtensionUnitSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let capturedAt: Date
    let selectors: [ExtensionUnitSelectorState]

    init(label: String, selectors: [ExtensionUnitSelectorState], capturedAt: Date = .now) {
        id = UUID()
        self.label = label
        self.selectors = selectors
        self.capturedAt = capturedAt
    }
}

struct ExtensionUnitByteChange: Identifiable, Equatable, Sendable {
    let index: Int
    let before: UInt8
    let after: UInt8

    var id: Int {
        index
    }

    var description: String {
        "byte \(index): 0x\(String(format: "%02X", before)) → 0x\(String(format: "%02X", after))"
    }
}

struct ExtensionUnitSelectorDiff: Identifiable, Equatable, Sendable {
    let selector: UInt8
    let before: [UInt8]?
    let after: [UInt8]?
    let changes: [ExtensionUnitByteChange]

    var id: UInt8 {
        selector
    }

    var hasComparableValues: Bool {
        before != nil && after != nil
    }
}

struct ExtensionUnitDiff: Equatable, Sendable {
    let sourceLabel: String
    let destinationLabel: String
    let selectorDiffs: [ExtensionUnitSelectorDiff]
}
