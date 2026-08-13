@preconcurrency import AppKit
import AudioCapture
import SpeechPipeline
import SwiftUI

struct RecordingWorkspaceView: View {
    @ObservedObject var recorder: MeetingRecorderViewModel
    @AppStorage(RecordingWorkspacePreferences.transcriptWidthKey)
    private var transcriptWidth =
        RecordingWorkspaceLayout.defaultTranscriptWidth
    @AppStorage(RecordingWorkspacePreferences.transcriptCollapsedKey)
    private var isCollapsed = false
    @State private var transcriptDragStartWidth: Double?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                notesPane
                    .frame(minWidth: RecordingWorkspaceLayout.minimumNotesWidth)

                if !isCollapsed {
                    railDivider(in: geometry.size.width)
                    transcriptRail
                        .frame(width: constrainedTranscriptWidth(
                            for: geometry.size.width
                        ))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var notesPane: some View {
        ZStack(alignment: .topLeading) {
            MarkdownNotesEditor(
                text: Binding(
                    get: { recorder.notesText },
                    set: { newValue in
                        recorder.updateNotes(newValue)
                    }
                ),
                isEditable: recorder.activeNotesURL != nil
            )

            if recorder.notesText.isEmpty {
                Text(ScribeCopy.Recording.emptyNotes)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if isCollapsed {
                HStack {
                    Spacer()
                    Button {
                        isCollapsed = false
                    } label: {
                        Label(
                            ScribeCopy.Recording.showTranscript,
                            systemImage: "sidebar.trailing"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .help(ScribeCopy.Recording.showTranscript)
                    .padding(12)
                }
            }
        }
    }

    private var transcriptRail: some View {
        VStack(spacing: 0) {
            HStack {
                Text(ScribeCopy.Recording.transcript)
                    .font(.headline.weight(.medium))
                Spacer()
                Button {
                    isCollapsed = true
                } label: {
                    Label(
                        ScribeCopy.Recording.hideTranscript,
                        systemImage: "sidebar.trailing"
                    )
                }
                .labelStyle(.iconOnly)
                .help(ScribeCopy.Recording.hideTranscript)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let notice = recorder.transcriptRailNotice {
                RecordingNoticeView(notice: notice)
                    .padding(14)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(recorder.recordingTranscriptRows) { row in
                        RecordingTranscriptRowView(row: row)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func railDivider(in totalWidth: Double) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let startWidth = transcriptDragStartWidth
                                    ?? transcriptWidth
                                transcriptDragStartWidth = startWidth
                                transcriptWidth = constrainedTranscriptWidth(
                                    startWidth - value.translation.width,
                                    totalWidth: totalWidth
                                )
                            }
                            .onEnded { _ in
                                transcriptDragStartWidth = nil
                            }
                    )
                    .accessibilityLabel(ScribeCopy.Recording.transcriptWidth)
                    .accessibilityAdjustableAction { direction in
                        let step = 40.0
                        switch direction {
                        case .increment:
                            transcriptWidth = constrainedTranscriptWidth(
                                transcriptWidth + step,
                                totalWidth: totalWidth
                            )
                        case .decrement:
                            transcriptWidth = constrainedTranscriptWidth(
                                transcriptWidth - step,
                                totalWidth: totalWidth
                            )
                        @unknown default:
                            break
                        }
                    }
            }
    }

    private func constrainedTranscriptWidth(for totalWidth: Double) -> Double {
        constrainedTranscriptWidth(transcriptWidth, totalWidth: totalWidth)
    }

    private func constrainedTranscriptWidth(
        _ proposed: Double,
        totalWidth: Double
    ) -> Double {
        RecordingWorkspaceLayout.constrainedTranscriptWidth(
            proposed,
            totalWidth: totalWidth
        )
    }

}

private struct RecordingNoticeView: View {
    let notice: RecordingStatusNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(notice.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            if case let .modelFailed(_, details) = notice {
                DisclosureGroup(ScribeCopy.Recording.details) {
                    Text(details)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RecordingTranscriptRowView: View {
    let row: RecordingTranscriptPresentationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(speakerLabel)
                    .font(ScribeTypography.transcriptSpeaker)
                    .foregroundStyle(speakerColor)

                Text(timestamp(row.paragraph.startTime))
                    .font(ScribeTypography.timestamp)
                    .foregroundStyle(.secondary)

                if row.isPartial {
                    Text(ScribeCopy.Recording.partial)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            RewritingTranscriptText(
                text: row.paragraph.text,
                isPartial: row.isPartial
            )
                .font(ScribeTypography.transcriptBody)
                .foregroundStyle(row.isPartial ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.2), value: row.isPartial)
    }

    private var speakerLabel: String {
        switch row.paragraph.source {
        case .microphone:
            ScribeCopy.Recording.you
        case .system:
            ScribeCopy.Recording.others
        case .imported:
            ""
        }
    }

    private var speakerColor: Color {
        let stableID = row.paragraph.speakerID
            ?? "source.\(row.paragraph.source.rawValue)"
        return ScribePalette.speaker(
            id: stableID,
            source: row.paragraph.source
        )
    }

    private func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct RewritingTranscriptText: View {
    let text: String
    let isPartial: Bool
    @State private var displayedText = AttributedString()
    @State private var highlightTask: Task<Void, Never>?

    private var value: Value {
        Value(text: text, isPartial: isPartial)
    }

    var body: some View {
        Text(displayedText)
            .onAppear {
                displayedText = AttributedString(text)
            }
            .onChange(of: value) { oldValue, newValue in
                highlightTask?.cancel()
                if oldValue.isPartial, !newValue.isPartial {
                    displayedText = highlightedRewrite(
                        from: oldValue.text,
                        to: newValue.text
                    )
                    highlightTask = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        displayedText = AttributedString(newValue.text)
                    }
                } else {
                    displayedText = AttributedString(newValue.text)
                }
            }
            .onDisappear {
                highlightTask?.cancel()
            }
    }

    private func highlightedRewrite(
        from oldValue: String,
        to newValue: String
    ) -> AttributedString {
        var commonCount = 0
        for (oldCharacter, newCharacter) in zip(oldValue, newValue) {
            guard oldCharacter == newCharacter else { break }
            commonCount += 1
        }
        var attributed = AttributedString(newValue)
        let suffix = String(newValue.dropFirst(commonCount))
        if !suffix.isEmpty,
            let range = attributed.range(of: suffix, options: .backwards)
        {
            attributed[range].backgroundColor = .yellow.opacity(0.35)
        }
        return attributed
    }

    private struct Value: Equatable {
        let text: String
        let isPartial: Bool
    }
}

struct MarkdownNotesEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        context.coordinator.observe(textView)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15, weight: .regular)
        textView.textColor = .labelColor
        textView.setAccessibilityLabel(ScribeCopy.Recording.notes)
        textView.string = text
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        context.coordinator.applyHighlighting(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if textView.string != text {
            let selections = textView.selectedRanges
            textView.string = text
            context.coordinator.applyHighlighting(to: textView)
            textView.selectedRanges = selections
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MarkdownNotesEditor
        private var isApplyingAttributes = false
        private weak var observedTextView: NSTextView?

        init(parent: MarkdownNotesEditor) {
            self.parent = parent
        }

        func observe(_ textView: NSTextView) {
            observedTextView = textView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidChange(_:)),
                name: NSText.didChangeNotification,
                object: textView
            )
        }

        @objc
        private func textDidChange(_ notification: Notification) {
            guard
                !isApplyingAttributes,
                let textView = notification.object as? NSTextView,
                textView === observedTextView
            else {
                return
            }
            parent.text = textView.string
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }

            let fullRange = NSRange(location: 0, length: storage.length)
            let regularFont = NSFont.systemFont(ofSize: 15, weight: .regular)
            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: regularFont,
                    .foregroundColor: NSColor.labelColor
                ],
                range: fullRange
            )
            highlight(
                pattern: #"(?m)^#{1,6}(?=\s).*$"#,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ],
                in: storage
            )
            highlight(
                pattern: #"`[^`\n]+`"#,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: 14,
                        weight: .regular
                    ),
                    .foregroundColor: NSColor.secondaryLabelColor
                ],
                in: storage
            )
            highlight(
                pattern: #"(?m)^\s*(?:[-*+] |\d+\. )"#,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor],
                in: storage
            )
            highlight(
                pattern: #"(?:\*\*|__|~~|(?<!\*)\*(?!\*))"#,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor],
                in: storage
            )
            storage.endEditing()
            textView.typingAttributes = [
                .font: regularFont,
                .foregroundColor: NSColor.labelColor
            ]
        }

        private func highlight(
            pattern: String,
            attributes: [NSAttributedString.Key: Any],
            in storage: NSTextStorage
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return
            }
            let range = NSRange(location: 0, length: storage.length)
            for match in regex.matches(in: storage.string, range: range) {
                storage.addAttributes(attributes, range: match.range)
            }
        }
    }
}
