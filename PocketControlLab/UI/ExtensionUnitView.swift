import SwiftUI

struct ExtensionUnitView: View {
    @Bindable var session: DeviceSession

    private var hasValidatedPocket4Profile: Bool {
        session.device?.supportsPocket4ControlProfile == true
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DJI Extension Unit")
                            .font(.headline)
                        Text("Unit 6 · GUID 41769EA2-04DE-E347-8B2B-F4341AFF003B")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button("Capture Snapshot A") {
                        session.captureSnapshotA()
                    }
                    .disabled(session.isCapturingSnapshot || !hasValidatedPocket4Profile)

                    Button("Capture Snapshot B") {
                        session.captureSnapshotB()
                    }
                    .disabled(session.isCapturingSnapshot || !hasValidatedPocket4Profile)
                }

                Text("The descriptor anomaly is intentionally retained: bNumControls = 2 while bmControls = 0x07. Selectors 1, 2, and 3 are candidates only. This build contains no Extension Unit SET_CUR path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if session.device != nil, !hasValidatedPocket4Profile {
                    Text("Disabled: the detected DJI Osmo Pocket does not have a validated Pocket 4 Extension Unit profile.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach(session.extensionUnitSelectors) { selector in
                    ExtensionUnitSelectorView(
                        selector: selector,
                        isRefreshAvailable: hasValidatedPocket4Profile,
                        refresh: { session.refreshExtensionSelector(selector.selector) }
                    )
                    Divider()
                }

                if let diff = session.extensionDiff {
                    ExtensionUnitDiffView(diff: diff)
                } else {
                    Text("Capture A, change something manually on the Pocket screen, then capture B to inspect byte-level changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Read-only Extension Unit inspector", systemImage: "magnifyingglass")
        }
    }
}

private struct ExtensionUnitSelectorView: View {
    let selector: ExtensionUnitSelectorState
    let isRefreshAvailable: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Selector \(selector.selector)")
                    .font(.headline)
                Spacer()
                Button("Refresh", action: refresh)
                    .disabled(!isRefreshAvailable)
            }

            Text(selector.capability.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                RequestGridRow(label: "GET_INFO", result: selector.getInfo)
                RequestGridRow(label: "GET_LEN", result: selector.getLength)
                RequestGridRow(label: "GET_CUR", result: selector.currentValue)

                if let length = selector.length {
                    GridRow {
                        Text("Length")
                            .foregroundStyle(.secondary)
                        Text("\(length)")
                    }
                }
            }
            .font(.caption.monospaced())
        }
    }
}

private struct ExtensionUnitDiffView: View {
    let diff: ExtensionUnitDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diff \(diff.sourceLabel) → \(diff.destinationLabel)")
                .font(.headline)

            ForEach(diff.selectorDiffs) { selectorDiff in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selector \(selectorDiff.selector)")
                        .font(.subheadline.weight(.semibold))

                    if let before = selectorDiff.before, let after = selectorDiff.after {
                        Text("A: \(hex(before))")
                        Text("B: \(hex(after))")

                        if selectorDiff.changes.isEmpty {
                            Text(before == after ? "Diff: no bytes changed" : "Diff: payload length changed")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(selectorDiff.changes) { change in
                                Text(change.description)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("No comparable GET_CUR payloads were captured.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.monospaced())
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }
}
