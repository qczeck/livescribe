import AppKit
import SwiftUI

// MARK: - SwiftUI view

struct PopoverView: View {
    let state: AppState
    let transcript: String
    let onStopAndSave: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            transcriptArea
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            Text(statusLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
            Text("LiveScribe")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .overlay(
                state == .listening
                    ? Circle().stroke(dotColor.opacity(0.4), lineWidth: 4)
                    : nil
            )
    }

    private var dotColor: Color {
        switch state {
        case .idle:      return .secondary
        case .starting:  return .orange
        case .listening: return .red
        case .saving:    return .orange
        case .saved:     return .green
        case .error:     return .red
        }
    }

    private var statusLabel: String {
        switch state {
        case .idle:          return "Ready"
        case .starting:      return "Starting…"
        case .listening:     return "Listening"
        case .saving:        return "Saving…"
        case .saved:         return "Saved"
        case .error:         return "Error"
        }
    }

    // MARK: - Transcript area

    @ViewBuilder
    private var transcriptArea: some View {
        switch state {
        case .idle:
            Text("Click the menu bar icon to start transcribing.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(minHeight: 80, alignment: .topLeading)

        case .starting:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Loading model…")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 80, alignment: .center)

        case .listening:
            ScrollViewReader { proxy in
                ScrollView {
                    Text(transcript.isEmpty ? "Listening for audio…" : transcript)
                        .font(.system(size: 13))
                        .foregroundColor(transcript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id("bottom")
                }
                .frame(minHeight: 80, maxHeight: 260)
                .onChange(of: transcript) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

        case .saving:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Saving transcript…")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 80, alignment: .center)

        case .saved(let path):
            VStack(alignment: .leading, spacing: 6) {
                Label("Transcript saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.green)
                Text(path)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .frame(minHeight: 80, alignment: .topLeading)

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if message.contains("Screen Recording") {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        )
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            }
            .frame(minHeight: 80, alignment: .topLeading)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if case .listening = state {
                Button(action: onStopAndSave) {
                    Label("Stop & Save", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            if case .error = state {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - NSHostingController wrapper

/// Bridges AppKit (NSPopover) and SwiftUI (PopoverView).
final class PopoverHostingController: NSHostingController<PopoverView> {

    var onStopAndSave: (() -> Void)?
    var onRetry: (() -> Void)?

    init() {
        super.init(rootView: PopoverView(
            state: .starting,
            transcript: "",
            onStopAndSave: {},
            onRetry: {}
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("not implemented")
    }

    func update(state: AppState, transcript: String) {
        rootView = PopoverView(
            state: state,
            transcript: transcript,
            onStopAndSave: { [weak self] in self?.onStopAndSave?() },
            onRetry:       { [weak self] in self?.onRetry?() }
        )
    }
}
