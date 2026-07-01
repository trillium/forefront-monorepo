#if canImport(SwiftUI)
import SwiftUI
import ForefrontModels
#if canImport(UIKit)
import UIKit
#endif

/// First-launch (and re-scan) flow: explain → scan → store → ready.
public struct OnboardingView: View {
    @Environment(\.forefrontEnvironment) private var env

    @State private var phase: Phase = .explain
    @State private var error: String?

    public var onComplete: () -> Void

    public init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    enum Phase {
        case explain
        case scanning
        case storing
        case done
    }

    public var body: some View {
        VStack(spacing: 24) {
            switch phase {
            case .explain:
                explainView
            case .scanning:
                scanningView
            case .storing:
                ProgressView("Storing credentials…")
            case .done:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("You're ready.")
                    .font(.title2)
            }
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }

    private var explainView: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
            Text("Pair Forefront")
                .font(.largeTitle.bold())
            Text("Scan the QR code from your Forefront server to begin.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: { phase = .scanning }) {
                Label("Scan QR code", systemImage: "camera")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
        }
    }

    @ViewBuilder
    private var scanningView: some View {
        #if canImport(UIKit) && canImport(AVFoundation)
        QRScanView(
            onDecode: { string in handleDecode(string) },
            onError: { msg in self.error = msg }
        )
        .ignoresSafeArea()
        #else
        Text("QR scanning requires iOS device hardware.")
        #endif
    }

    private func handleDecode(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            error = "QR contents are not valid UTF-8"
            return
        }
        do {
            let payload = try JSONDecoder().decode(QRPayload.self, from: data)
            phase = .storing
            // ISC-79: store token + endpoints in one transaction.
            try env.keychain.storeToken(payload.authToken)
            env.appConfig.adopt(payload)
            env.refreshBearerTokenCache()
            phase = .done
            // Brief moment to acknowledge before handing off.
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                onComplete()
            }
        } catch {
            self.error = "Invalid QR payload: \(error.localizedDescription)"
            phase = .explain
        }
    }
}
#endif
