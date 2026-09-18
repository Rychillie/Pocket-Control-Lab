import SwiftUI

struct ContentView: View {
    @Bindable var session: DeviceSession

    var body: some View {
        VStack(spacing: 0) {
            LabHeaderView(
                presentation: session.connectionPresentation,
                isInspecting: session.isInspecting
            )

            VSplitView {
                HSplitView {
                    PreviewView(
                        controller: session.previewController,
                        status: session.previewStatus,
                        cameraInfo: session.cameraInfo,
                        isPreviewRunning: session.isPreviewRunning,
                        canStartPreview: session.device?.supportsPocket4ControlProfile == true
                            && session.cameraMatchStatus != .multiple,
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
                .disabled(
                    session.device?.supportsPocket4ControlProfile != true
                        || session.cameraMatchStatus == .multiple
                )
                .accessibilityLabel("Refresh safe device and UVC inspection")
                .accessibilityHint("Available only for the verified Pocket 4 USB control profile.")

                Text(session.isInspecting ? "Inspecting…" : "Manual read-only inspection")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LabHeaderView: View {
    let presentation: PocketConnectionPresentationState
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

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: presentation.systemImage)
                        .symbolRenderingMode(.hierarchical)

                    HeaderSeverityDot(severity: presentation.severity)

                    Text(presentation.title)
                        .font(.headline)
                }

                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.accessibilityLabel)

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
}

private struct HeaderSeverityDot: View {
    let severity: ConnectionSeverity

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch severity {
        case .neutral:
            .secondary
        case .attention:
            .blue
        case .warning:
            .orange
        case .ready:
            .green
        }
    }
}
