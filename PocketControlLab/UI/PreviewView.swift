import SwiftUI

struct PreviewView: View {
    let controller: CameraPreviewController?
    let status: String
    let cameraInfo: CameraDeviceInfo?
    let isPreviewRunning: Bool
    let canStartPreview: Bool
    let requestPreviewStart: () -> Void
    let stopPreview: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                CameraPreviewView(controller: controller)

                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE PREVIEW")
                        .font(.caption.weight(.bold))
                    Text(status)
                        .font(.caption)

                    if let cameraInfo {
                        Text(cameraInfo.activeFormat.displayName)
                            .font(.caption.monospaced())
                    }
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.72), in: .rect(cornerRadius: 8))
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Button("Start Preview", systemImage: "play.fill", action: requestPreviewStart)
                    .disabled(!canStartPreview || isPreviewRunning)
                    .accessibilityHint("Requests camera access only after this explicit action, then starts preview for a verified Pocket 4.")

                Button("Stop Preview", systemImage: "stop.fill", action: stopPreview)
                    .disabled(!isPreviewRunning)

                Spacer()

                Text(isPreviewRunning ? "Preview running" : "Preview stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.bar)
        }
        .background(.black)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live preview. \(status)")
    }
}
