import Foundation
import SwiftUI

struct UVCControlsView: View {
    @Bindable var lab: PocketLabModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("CONTROLS")
                        .font(.headline)

                    Spacer()

                    Toggle("Enable UVC writes", isOn: $lab.isWriteModeEnabled)
                        .toggleStyle(.switch)
                        .disabled(!lab.canEnableUVCWrites)
                        .accessibilityHint("Writes remain off by default and only validated standard Camera Terminal controls can be sent.")
                }

                Text(lab.writeAvailabilityDescription)
                    .font(.caption)
                    .foregroundStyle(lab.canEnableUVCWrites ? Color.secondary : Color.orange)

                ForEach(lab.standardControls) { state in
                    StandardControlDiscoveryView(state: state)

                    switch state.control {
                    case .zoom:
                        ZoomControlView(lab: lab, state: state)
                    case .panTilt:
                        PanTiltControlView(lab: lab, state: state)
                    case .roll:
                        RollControlView(lab: lab, state: state)
                    }

                    if state.control != .roll {
                        Divider()
                    }
                }

                HStack {
                    Button("Recenter UI") {
                        // No action: the DJI XU protocol is intentionally unknown.
                    }
                    .disabled(true)

                    Text("Disabled: a recenter command would require an unknown DJI protocol.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Safe UVC control lab", systemImage: "slider.horizontal.3")
        }
    }
}

private struct ZoomControlView: View {
    @Bindable var lab: PocketLabModel
    let state: UVCStandardControlState

    var body: some View {
        if case let .scalar(range)? = state.range, range.isValidForWrites {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zoom")
                        .font(.headline)
                    Spacer()
                    Text("\(Int64(zoomValue))")
                        .font(.body.monospacedDigit())
                }

                Slider(
                    value: Binding(
                        get: { zoomValue },
                        set: { lab.scheduleZoom($0) }
                    ),
                    in: Double(range.minimum)...Double(range.maximum),
                    step: Double(range.resolution)
                )
                .disabled(!isEnabled)

                Button("Reset Zoom") {
                    lab.resetZoom()
                }
                .disabled(!isEnabled)
            }
        } else {
            DisabledControlMessage(title: "Zoom", state: state)
        }
    }

    private var isEnabled: Bool {
        lab.isWriteModeEnabled && state.isWriteReady
    }

    private var zoomValue: Double {
        guard case let .scalar(range)? = state.range else {
            return 0
        }
        return lab.requestedZoom ?? Double(range.currentValue)
    }
}

private struct PanTiltControlView: View {
    @Bindable var lab: PocketLabModel
    let state: UVCStandardControlState

    var body: some View {
        if case let .vector(range)? = state.range, range.isValidForWrites {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pan / Tilt")
                    .font(.headline)

                AxisSlider(
                    label: "Pan",
                    value: Binding(
                        get: { lab.requestedPan ?? Double(range.currentValue.first) },
                        set: { lab.schedulePan($0) }
                    ),
                    range: Double(range.minimum.first)...Double(range.maximum.first),
                    step: Double(range.resolution.first),
                    enabled: isEnabled
                )

                AxisSlider(
                    label: "Tilt",
                    value: Binding(
                        get: { lab.requestedTilt ?? Double(range.currentValue.second) },
                        set: { lab.scheduleTilt($0) }
                    ),
                    range: Double(range.minimum.second)...Double(range.maximum.second),
                    step: Double(range.resolution.second),
                    enabled: isEnabled
                )

                Button("Reset Pan/Tilt") {
                    lab.resetPanTilt()
                }
                .disabled(!isEnabled)
            }
        } else {
            DisabledControlMessage(title: "Pan / Tilt", state: state)
        }
    }

    private var isEnabled: Bool {
        lab.isWriteModeEnabled && state.isWriteReady
    }
}

private struct RollControlView: View {
    @Bindable var lab: PocketLabModel
    let state: UVCStandardControlState

    var body: some View {
        if case let .scalar(range)? = state.range, range.isValidForWrites {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Roll")
                        .font(.headline)
                    Spacer()
                    Text("\(Int64(rollValue))")
                        .font(.body.monospacedDigit())
                }

                Slider(
                    value: Binding(
                        get: { rollValue },
                        set: { lab.scheduleRoll($0) }
                    ),
                    in: Double(range.minimum)...Double(range.maximum),
                    step: Double(range.resolution)
                )
                .disabled(!isEnabled)

                Button("Reset Roll") {
                    lab.resetRoll()
                }
                .disabled(!isEnabled)
            }
        } else {
            DisabledControlMessage(title: "Roll", state: state)
        }
    }

    private var isEnabled: Bool {
        lab.isWriteModeEnabled && state.isWriteReady
    }

    private var rollValue: Double {
        guard case let .scalar(range)? = state.range else {
            return 0
        }
        return lab.requestedRoll ?? Double(range.currentValue)
    }
}

private struct AxisSlider: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let enabled: Bool

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 40, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .disabled(!enabled)
            Text("\(Int64(value.wrappedValue))")
                .font(.body.monospacedDigit())
                .frame(width: 100, alignment: .trailing)
        }
    }
}

private struct DisabledControlMessage: View {
    let title: String
    let state: UVCStandardControlState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
            Text("Slider disabled until direct UVC GET_INFO, GET_MIN, GET_MAX, GET_RES, GET_DEF, and GET_CUR validate this control.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StandardControlDiscoveryView: View {
    let state: UVCStandardControlState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.capability.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let cmioObservation = state.cmioObservation {
                Text("CoreMediaIO live: \(cmioObservation.controlName), \(cmioObservation.className), settable=\(cmioObservation.isSettable.map { String($0) } ?? "unknown")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if let nativeValue = cmioObservation.nativeValue {
                    Text("CMIO native value: \(hex(nativeValue))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                RequestGridRow(label: "GET_INFO", result: state.getInfo)
                RequestGridRow(label: "GET_MIN", result: state.minimum)
                RequestGridRow(label: "GET_MAX", result: state.maximum)
                RequestGridRow(label: "GET_RES", result: state.resolution)
                RequestGridRow(label: "GET_DEF", result: state.defaultValue)
                RequestGridRow(label: "GET_CUR", result: state.currentValue)
            }
            .font(.caption.monospaced())

            if let range = state.range {
                DecodedUVCControlRangeView(range: range)
            }
        }
    }
}

private struct DecodedUVCControlRangeView: View {
    let range: UVCControlRange

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Decoded live range")
                .font(.caption.weight(.semibold))

            switch range {
            case let .scalar(value):
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    DecodedValueRow(label: "Min", value: String(value.minimum))
                    DecodedValueRow(label: "Max", value: String(value.maximum))
                    DecodedValueRow(label: "Step", value: String(value.resolution))
                    DecodedValueRow(label: "Default", value: String(value.defaultValue))
                    DecodedValueRow(label: "Current", value: String(value.currentValue))
                }
            case let .vector(value):
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Axis")
                            .foregroundStyle(.secondary)
                        Text("Min")
                            .foregroundStyle(.secondary)
                        Text("Max")
                            .foregroundStyle(.secondary)
                        Text("Step")
                            .foregroundStyle(.secondary)
                        Text("Default")
                            .foregroundStyle(.secondary)
                        Text("Current")
                            .foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Pan")
                        Text(String(value.minimum.first))
                        Text(String(value.maximum.first))
                        Text(String(value.resolution.first))
                        Text(String(value.defaultValue.first))
                        Text(String(value.currentValue.first))
                    }
                    GridRow {
                        Text("Tilt")
                        Text(String(value.minimum.second))
                        Text(String(value.maximum.second))
                        Text(String(value.resolution.second))
                        Text(String(value.defaultValue.second))
                        Text(String(value.currentValue.second))
                    }
                }
            }
        }
        .font(.caption.monospaced())
    }
}

private struct DecodedValueRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}

struct RequestGridRow: View {
    let label: String
    let result: UVCRequestResult

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(result.statusDescription)
                .textSelection(.enabled)
        }
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}
