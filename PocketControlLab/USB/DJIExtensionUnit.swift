import Foundation
import IOKit

protocol ExtensionUnitInspecting: Sendable {
    func inspectAll(connection: UVCTransportConnection) async -> [ExtensionUnitSelectorState]
    func refresh(selector: UInt8, connection: UVCTransportConnection) async -> ExtensionUnitSelectorState
}

actor DJIExtensionUnitInspector: ExtensionUnitInspecting {
    private let transport: any UVCTransporting

    init(transport: any UVCTransporting) {
        self.transport = transport
    }

    func inspectAll(connection: UVCTransportConnection) async -> [ExtensionUnitSelectorState] {
        var selectors: [ExtensionUnitSelectorState] = []

        for selector in UInt8(1)...UInt8(3) {
            selectors.append(await refresh(selector: selector, connection: connection))
        }

        return selectors
    }

    func refresh(selector: UInt8, connection: UVCTransportConnection) async -> ExtensionUnitSelectorState {
        var state = ExtensionUnitSelectorState.idle(selector: selector)
        state.getInfo = await transport.perform(
            connection: connection,
            request: .getInfo,
            selector: selector,
            entityID: 6,
            expectedLength: 1
        )
        state.getLength = await transport.perform(
            connection: connection,
            request: .getLength,
            selector: selector,
            entityID: 6,
            expectedLength: 2
        )

        if state.getInfo.isSuccess {
            state.capability = .detectedLive("Direct UVC GET_INFO succeeded")
        }

        guard let length = state.length else {
            state.currentValue = UVCRequestResult(
                request: .getCurrent,
                bytes: [],
                outcome: .blocked("GET_CUR was not sent because GET_LEN did not return a valid length.")
            )
            return state
        }

        guard (1...1024).contains(length) else {
            state.currentValue = UVCRequestResult(
                request: .getCurrent,
                bytes: [],
                outcome: .blocked("GET_CUR was not sent because GET_LEN returned \(length), outside the safe 1…1024-byte bound.")
            )
            return state
        }

        state.currentValue = await transport.perform(
            connection: connection,
            request: .getCurrent,
            selector: selector,
            entityID: 6,
            expectedLength: length
        )
        return state
    }
}
