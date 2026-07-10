#if canImport(SwiftUI)
import SwiftUI
import ForefrontModels

/// Renders one message. Branches on `MessageKind` for the four v1 shapes:
/// plain text, a question with quick-reply buttons, a link-to-web-card (opens
/// the existing WebView surface), and a reminder card. User messages align
/// trailing; agent/system align leading.
///
/// - `onQuickReply`: a tap on a quick-reply / reminder button — posts the label
///   back as a user message (contract §10).
/// - `onOpenWebCard`: a tap on a link-to-web-card — opens the WebView surface.
public struct MessageBubbleView: View {
    public let message: Message
    public let onQuickReply: (String) -> Void
    public let onOpenWebCard: (URL) -> Void

    public init(
        message: Message,
        onQuickReply: @escaping (String) -> Void,
        onOpenWebCard: @escaping (URL) -> Void
    ) {
        self.message = message
        self.onQuickReply = onQuickReply
        self.onOpenWebCard = onOpenWebCard
    }

    private var isUser: Bool { message.role == .user }

    public var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                content
                statusLine
            }
            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text, .question:
            textBubble
            if message.kind == .question || message.quickReplies != nil {
                quickReplyButtons
            }
        case .reminder:
            reminderCard
            quickReplyButtons
        case .linkToWebCard:
            webCardBubble
        }
    }

    // MARK: - Text / question

    private var textBubble: some View {
        Text(message.body)
            .font(.body)
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - Reminder

    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Reminder", systemImage: "bell.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message.body)
                .font(.body)
            if let due = message.reminder?.dueAt {
                Text("Due \(due.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Link to web card (drive-to-input)

    private var webCardBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.body)
                .font(.body)
            if let url = message.webCardURL {
                Button {
                    onOpenWebCard(url)
                } label: {
                    Label("Open form", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Quick replies

    @ViewBuilder
    private var quickReplyButtons: some View {
        if let replies = message.quickReplies, !replies.isEmpty {
            // Wrap buttons; keep them leading-aligned under an agent bubble.
            FlowLayout(spacing: 8) {
                ForEach(replies, id: \.self) { reply in
                    Button {
                        onQuickReply(reply)
                    } label: {
                        Text(reply)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status (client-authored only)

    @ViewBuilder
    private var statusLine: some View {
        if isUser {
            switch message.status {
            case .sending:
                Text("Sending…").font(.caption2).foregroundStyle(.secondary)
            case .failed:
                Label("Failed — will retry", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption2).foregroundStyle(.orange)
            case .sent:
                EmptyView()
            }
        }
    }
}

/// A minimal flow (wrapping) layout for quick-reply chips — avoids a hard
/// dependency and works on iOS 17 (`Layout` protocol). Places subviews left to
/// right, wrapping to a new row when the current one overflows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows = [[CGSize]]()
        var currentRow = [CGSize]()
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let projected = currentRowWidth + (currentRow.isEmpty ? 0 : spacing) + size.width
            if projected > maxWidth, !currentRow.isEmpty {
                rows.append(currentRow)
                totalHeight += rowHeight + spacing
                currentRow = []
                currentRowWidth = 0
                rowHeight = 0
            }
            currentRow.append(size)
            currentRowWidth += (currentRow.count == 1 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
            totalHeight += rowHeight
        }
        let width = min(maxWidth, rows.map { row in
            row.reduce(0) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * spacing
        }.max() ?? 0)
        return CGSize(width: width.isFinite ? width : 0, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
