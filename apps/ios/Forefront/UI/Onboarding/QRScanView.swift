#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI

public struct QRScanView: UIViewControllerRepresentable {
    public let onDecode: (String) -> Void
    public let onError: (String) -> Void

    public init(onDecode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onDecode = onDecode
        self.onError = onError
    }

    public func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onDecode = onDecode
        vc.onError = onError
        return vc
    }

    public func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}
#endif
