#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Observation
#if canImport(Speech) && canImport(AVFoundation)
import Speech
import AVFoundation
#endif

/// Voice-first is on-brand and strengthens the App Store 4.2 "not a web wrapper"
/// argument (scope §5). This is the composer's dictation entry point: a small
/// `SFSpeechRecognizer` + `AVAudioEngine` transcriber that streams partial
/// results into a bound text field.
///
/// It degrades gracefully: on a platform without `Speech`/`AVFoundation`, or when
/// permission is denied, `isAvailable` is false and `start()` is a no-op — the
/// composer simply hides the mic button. No hard dependency blocks the build.
@MainActor
@Observable
public final class VoiceDictation {
    /// The live (partial or final) transcript. The composer binds this into its
    /// text field while `isRecording`.
    public private(set) var transcript: String = ""
    public private(set) var isRecording: Bool = false
    /// A human-readable reason dictation is unavailable, for a subtle hint.
    public private(set) var unavailableReason: String?

    #if canImport(Speech) && canImport(AVFoundation)
    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    #endif

    public init() {}

    /// True when on-device dictation can be attempted. False on unsupported
    /// platforms — the composer hides the mic.
    public var isAvailable: Bool {
        #if canImport(Speech) && canImport(AVFoundation)
        return recognizer?.isAvailable ?? false
        #else
        return false
        #endif
    }

    /// Request permission and begin streaming transcription. No-op (sets
    /// `unavailableReason`) if unsupported or denied.
    public func start() async {
        #if canImport(Speech) && canImport(AVFoundation)
        guard let recognizer, recognizer.isAvailable else {
            unavailableReason = "Speech recognition is unavailable on this device."
            return
        }
        let authorized = await Self.requestSpeechAuthorization()
        guard authorized else {
            unavailableReason = "Enable Speech Recognition in Settings to dictate."
            return
        }
        do {
            try beginStreaming(recognizer: recognizer)
            isRecording = true
            unavailableReason = nil
        } catch {
            unavailableReason = "Couldn't start the microphone."
            stop()
        }
        #else
        unavailableReason = "Dictation isn't supported in this build."
        #endif
    }

    /// Stop streaming and finalize. Safe to call when not recording.
    public func stop() {
        #if canImport(Speech) && canImport(AVFoundation)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isRecording = false
    }

    /// Clear the transcript (after the composer consumes it).
    public func reset() {
        transcript = ""
    }

    #if canImport(Speech) && canImport(AVFoundation)
    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func beginStreaming(recognizer: SFSpeechRecognizer) throws {
        // Tear down any prior session.
        task?.cancel()
        task = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.stop() }
            }
        }
    }
    #endif
}
#endif
