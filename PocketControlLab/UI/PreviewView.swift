import SwiftUI

struct PreviewView: View {
    let controller: CameraPreviewController
    let status: String
    let cameraInfo: CameraDeviceInfo?

    var body: some View {
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
        .background(.black)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live preview. \(status)")
    }
}
