#if canImport(SwiftUI)
import SwiftUI
import ForefrontModels

/// The message composer: a text field, a voice-dictation (mic) button, and a
/// send button. Voice input is the on-brand entry point (scope §5). The mic is
/// hidden gracefully when dictation is unavailable, so the composer always works
/// as a plain text field.
public struct ChatComposerView: View {
    @Binding public var text: String
    public let onSend: (String) -> Void

    @State private var dictation = VoiceDictation()

    public init(text: Binding<String>, onSend: @escaping (String) -> Void) {
        self._text = text
        self.onSend = onSend
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        VStack(spacing: 4) {
            if let reason = dictation.unavailableReason, dictation.isRecording == false {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if dictation.isAvailable {
                    micButton
                }
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Stream the live transcript into the field while recording.
        .onChange(of: dictation.transcript) { _, newValue in
            if dictation.isRecording, !newValue.isEmpty {
                text = newValue
            }
        }
    }

    private var micButton: some View {
        Button {
            Task {
                if dictation.isRecording {
                    dictation.stop()
                } else {
                    dictation.reset()
                    await dictation.start()
                }
            }
        } label: {
            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(dictation.isRecording ? Color.red : Color.accentColor)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
        }
        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Start dictation")
    }

    private var sendButton: some View {
        Button {
            let toSend = trimmed
            guard !toSend.isEmpty else { return }
            if dictation.isRecording { dictation.stop() }
            onSend(toSend)
            text = ""
            dictation.reset()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(trimmed.isEmpty ? Color.secondary : Color.accentColor)
        }
        .disabled(trimmed.isEmpty)
        .accessibilityLabel("Send message")
    }
}
#endif
