#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
import AVFoundation
import ForefrontModels

/// AVFoundation-based QR scanner (D-04 in DECISIONS.md). Halts on first
/// successful decode (ISC-77).
public final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    public var onDecode: ((String) -> Void)?
    public var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            Task.detached { [weak session] in
                session?.startRunning()
            }
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            Task.detached { [weak session] in
                session?.stopRunning()
            }
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            EventLog.shared.error("scan", "No camera available")
            onError?("No camera available")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            EventLog.shared.error("scan", "Camera could not be opened", detail: error.localizedDescription)
            onError?(error.localizedDescription)
            return
        }
        guard session.canAddInput(input) else {
            EventLog.shared.error("scan", "Cannot add camera input")
            onError?("Cannot add camera input")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?("Cannot add metadata output")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]   // ISC-76

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
        EventLog.shared.success("scan", "Camera ready — point at the QR code")
    }

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            object.type == .qr,
            let string = object.stringValue
        else { return }
        // ISC-77: halt on first decode.
        EventLog.shared.info("scan", "QR code detected in frame")
        session.stopRunning()
        onDecode?(string)
    }
}
#endif
