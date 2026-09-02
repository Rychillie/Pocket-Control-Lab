import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class CameraPreviewController {
    enum PreviewError: LocalizedError {
        case cannotAddInput

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:
                "AVCaptureSession refused the selected external camera input."
            }
        }
    }

    let session = AVCaptureSession()
    private var input: AVCaptureDeviceInput?
    private(set) var activeDeviceID: String?

    func start(device: AVCaptureDevice) throws {
        guard activeDeviceID != device.uniqueID else {
            if !session.isRunning {
                session.startRunning()
            }
            return
        }

        let newInput = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        do {
            defer {
                session.commitConfiguration()
            }

            if let input {
                session.removeInput(input)
                self.input = nil
                activeDeviceID = nil
            }

            guard session.canAddInput(newInput) else {
                throw PreviewError.cannotAddInput
            }

            session.addInput(newInput)
            input = newInput
            activeDeviceID = device.uniqueID
        }

        // AVCaptureSession rejects startRunning while a configuration is open.
        // The scoped configuration above has committed before this call.
        if !session.isRunning {
            session.startRunning()
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        activeDeviceID = nil
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let controller: CameraPreviewController

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = controller.session
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.previewLayer.session = controller.session
    }
}

final class PreviewHostView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
