import SwiftUI

struct OnboardingView: View {
    @Bindable var session: DeviceSession
    @Bindable var completion: OnboardingCompletionState

    private var connection: OnboardingConnectionPresentation {
        OnboardingConnectionPresentation(
            connection: session.connectionPresentation,
            cameraMatchStatus: session.cameraMatchStatus
        )
    }

    var body: some View {
        let currentConnection = connection

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                guideSection(number: "1", title: "Welcome and privacy") {
                    Text("Connect a compatible DJI Osmo Pocket locally over USB-C in Webcam Mode.")
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No account, cloud service, analytics, or video upload.", systemImage: "checkmark.shield")
                        Label("The app does not read the camera’s USB serial number.", systemImage: "checkmark.shield")
                        Label("Camera access is needed only for local video preview.", systemImage: "video")
                    }
                    .foregroundStyle(.secondary)
                }

                guideSection(number: "2", title: "Connect the camera") {
                    Text("Connect the Pocket by USB-C and select Webcam Mode on the camera. USB detection continues independently of camera permission.")
                }

                guideSection(number: "3", title: "Current connection") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: currentConnection.systemImage)
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(currentConnection.title)
                                .font(.headline)
                            Text(currentConnection.detail)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(currentConnection.title). \(currentConnection.detail)")

                    if currentConnection.canRefreshDetection {
                        Button("Refresh Detection", systemImage: "arrow.clockwise") {
                            session.refreshPassiveDetection()
                        }
                        .accessibilityHint("Performs one passive USB detection scan.")
                    }
                }

                guideSection(number: "4", title: "Allow camera access") {
                    switch currentConnection.status {
                    case .cameraPermissionNeeded:
                        Text("macOS camera access is used only to show a local preview. The app does not record or upload video.")
                        Button("Allow Camera Access", systemImage: "camera") {
                            session.requestCameraPermission()
                        }
                        .accessibilityHint("Requests macOS camera permission. This does not start preview or inspect camera controls.")
                    case .cameraPermissionUnavailable:
                        Text("macOS does not show the permission prompt again after access is denied. Change the permission manually here:")
                        Text("System Settings → Privacy & Security → Camera")
                            .font(.body.weight(.semibold))
                            .accessibilityLabel("System Settings, Privacy and Security, Camera")
                    default:
                        Text("Camera permission is never requested when this window opens. It is requested only after you select Allow Camera Access when the verified Pocket 4 is detected.")
                            .foregroundStyle(.secondary)
                    }
                }

                guideSection(number: "5", title: "Finish and return any time") {
                    Text("Closing this window leaves the shared camera session running. Reopen Set Up Camera from the menu bar to see the current connection again.")
                        .foregroundStyle(.secondary)

                    if completion.hasCompletedOnboarding {
                        Label("You have completed this guide before. The connection result above is live.", systemImage: "checkmark.circle.fill")
                            .accessibilityElement(children: .combine)
                    } else {
                        Button("Finish Setup Guide", systemImage: "checkmark") {
                            completion.markCompleted()
                        }
                        .accessibilityHint("Stores only that you completed this guide. It does not record camera or permission state.")
                        Text("Finishing the guide does not mean a camera is connected or ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(minWidth: 600, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set Up Camera")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("A safe, local setup guide for connecting your Pocket in Webcam Mode.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func guideSection<Content: View>(
        number: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
