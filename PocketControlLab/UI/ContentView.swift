import SwiftUI

struct ContentView: View {
    @Bindable var lab: PocketLabModel

    var body: some View {
        VStack(spacing: 0) {
            LabHeaderView(device: lab.device, isInspecting: lab.isInspecting)

            VSplitView {
                HSplitView {
                    PreviewView(
                        controller: lab.previewController,
                        status: lab.previewStatus,
                        cameraInfo: lab.cameraInfo
                    )
                    .frame(minWidth: 520, minHeight: 320)

                    DeviceInspectorView(
                        device: lab.device,
                        authorization: lab.cameraAuthorization,
                        cameraInfo: lab.cameraInfo,
                        controls: lab.standardControls,
                        extensionUnitSelectors: lab.extensionUnitSelectors
                    )
                    .frame(minWidth: 300, idealWidth: 360)
                }
                .frame(minHeight: 340)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        UVCControlsView(lab: lab)
                        ExtensionUnitView(lab: lab)
                    }
                    .padding()
                }
                .frame(minHeight: 300)

                LogView(lab: lab)
                    .frame(minHeight: 180)
            }
        }
        .frame(minWidth: 1_050, minHeight: 820)
        .task {
            lab.start()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh Investigation", systemImage: "arrow.clockwise") {
                    lab.refreshInspection()
                }
                .disabled(lab.device?.supportsPocket4ControlProfile != true)
                .accessibilityLabel("Refresh safe device and UVC inspection")
                .accessibilityHint("Available only for the verified Pocket 4 USB control profile.")

                Text(lab.isInspecting ? "Inspecting…" : "Read-only discovery")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LabHeaderView: View {
    let device: PocketDevice?
    let isInspecting: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pocket Control Lab")
                    .font(.title2.weight(.semibold))
                Text("DJI Osmo Pocket USB control and diagnostics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(device == nil ? .red : .green)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)

                Text(connectionStatus)
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(connectionStatus)

            if isInspecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Read-only UVC discovery in progress")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var connectionStatus: String {
        guard let device else {
            return "No Pocket Connected"
        }

        return device.supportsPocket4ControlProfile
            ? "Pocket 4 Connected"
            : "DJI Osmo Pocket Detected"
    }
}
