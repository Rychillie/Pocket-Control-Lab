import AVFoundation
import AppKit
import SwiftUI

/// A preview-capable camera selected by the discovery adapter. Keeping the
/// AVFoundation device behind this small reference lets session tests exercise
/// the preview intent without constructing a capture device or session.
@MainActor
protocol CameraPreviewSource: AnyObject {
    var cameraInfo: CameraDeviceInfo { get }
}

@MainActor
final class AVFoundationCameraPreviewSource: CameraPreviewSource {
    let device: AVCaptureDevice
    let cameraInfo: CameraDeviceInfo

    init(device: AVCaptureDevice, cameraInfo: CameraDeviceInfo) {
        self.device = device
        self.cameraInfo = cameraInfo
    }
}

@MainActor
final class CameraPreviewController {
    enum PreviewError: LocalizedError {
        case cannotAddInput
        case unsupportedPreviewSource

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:
                "AVCaptureSession refused the selected external camera input."
            case .unsupportedPreviewSource:
                "The selected camera cannot be used by the AVFoundation preview controller."
            }
        }
    }

    /// The controller may be retained for the lifetime of the process, but
    /// the actual AVCaptureSession is deliberately created only after the
    /// user explicitly starts preview. That keeps passive USB discovery free
    /// of preview-session construction as well as camera permission work.
    private var captureSession: AVCaptureSession?
    private var input: AVCaptureDeviceInput?
    private(set) var activeDeviceID: String?

    var session: AVCaptureSession? {
        captureSession
    }

    var isRunning: Bool {
        captureSession?.isRunning == true
    }

    func start(source: any CameraPreviewSource) throws {
        guard let source = source as? AVFoundationCameraPreviewSource else {
            throw PreviewError.unsupportedPreviewSource
        }

        try start(device: source.device)
    }

    func start(device: AVCaptureDevice) throws {
        let session: AVCaptureSession
        if let captureSession {
            session = captureSession
        } else {
            let newSession = AVCaptureSession()
            captureSession = newSession
            session = newSession
        }

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
        if captureSession?.isRunning == true {
            captureSession?.stopRunning()
        }
        activeDeviceID = nil
    }
}

/// The DeviceSession owns one preview controller, while tests can substitute
/// this narrow control surface without configuring an AVCaptureSession.
@MainActor
protocol PreviewControlling: AnyObject {
    var isRunning: Bool { get }
    func start(source: any CameraPreviewSource) throws
    func stop()
}

extension CameraPreviewController: PreviewControlling {}

struct CameraPreviewView: NSViewRepresentable {
    let controller: CameraPreviewController?

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = controller?.session
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.previewLayer.session = controller?.session
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
