import SwiftUI

struct ContentView: View {
    @Bindable var session: DeviceSession

    var body: some View {
        VStack(spacing: 0) {
            LabHeaderView(device: session.device, isInspecting: session.isInspecting)

            VSplitView {
                HSplitView {
                    PreviewView(
                        controller: session.previewController,
                        status: session.previewStatus,
                        cameraInfo: session.cameraInfo,
                        isPreviewRunning: session.isPreviewRunning,
                        canStartPreview: session.device?.supportsPocket4ControlProfile == true,
                        requestPreviewStart: session.requestPreviewStart,
                        stopPreview: session.stopPreview
                    )
                    .frame(minWidth: 520, minHeight: 320)

                    DeviceInspectorView(
                        device: session.device,
                        authorization: session.cameraAuthorization,
                        cameraInfo: session.cameraInfo,
                        controls: session.standardControls,
                        extensionUnitSelectors: session.extensionUnitSelectors
                    )
                    .frame(minWidth: 300, idealWidth: 360)
                }
                .frame(minHeight: 340)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        UVCControlsView(session: session)
                        ExtensionUnitView(session: session)
                    }
                    .padding()
                }
                .frame(minHeight: 300)

                LogView(session: session)
                    .frame(minHeight: 180)
            }
        }
        .frame(minWidth: 1_050, minHeight: 820)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh Read-Only Inspection", systemImage: "arrow.clockwise") {
                    session.refreshReadOnlyInspection()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session.device?.supportsPocket4ControlProfile != true)
                .accessibilityLabel("Refresh safe device and UVC inspection")
                .accessibilityHint("Available only for the verified Pocket 4 USB control profile.")

                Text(session.isInspecting ? "Inspecting…" : "Manual read-only inspection")
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
