import AppKit
import Combine

// MARK: - App state

enum AppState: Equatable {
    case idle
    case starting          // Python not ready yet
    case listening         // capturing + transcribing
    case saving
    case saved(String)     // associated value = file path
    case error(String)     // associated value = message

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.starting, .starting),
             (.listening, .listening), (.saving, .saving):
            return true
        case (.saved(let a), .saved(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Controller

@MainActor
final class StatusBarController: NSObject {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverVC: PopoverHostingController!
    private var eventMonitor: EventMonitor?

    private var transcriptionClient: TranscriptionClient?
    private var audioCaptureManager: AudioCaptureManager?

    private(set) var state: AppState = .starting {
        didSet { applyState() }
    }

    // Full transcript accumulated during a session
    private var sessionTranscript = ""

    override init() {
        super.init()
        buildStatusItem()
        buildPopover()
        applyState()
    }

    // MARK: - Build UI

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = icon(for: state)
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func buildPopover() {
        popoverVC = PopoverHostingController()
        popoverVC.onStopAndSave = { [weak self] in self?.stopAndSave() }
        popoverVC.onRetry      = { [weak self] in self?.retry() }

        popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true
    }

    // MARK: - State transitions

    func transitionTo(_ newState: AppState) {
        state = newState
    }

    /// Called by AppDelegate when the Python process prints READY
    func pythonServerIsReady() {
        guard state == .starting else { return }
        state = .idle
    }

    private func applyState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem.button?.image = self.icon(for: self.state)
            self.popoverVC.update(state: self.state, transcript: self.sessionTranscript)
        }

        if case .saved = state {
            // Auto-clear back to idle after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard case .saved = self?.state else { return }
                self?.state = .idle
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }

        // Start listening when opening if idle
        if state == .idle {
            startListening()
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
        eventMonitor?.start()
    }

    private func closePopover() {
        popover.performClose(nil)
        eventMonitor?.stop()
        eventMonitor = nil
    }

    private func startListening() {
        sessionTranscript = ""
        state = .listening

        // Set up transcription client
        transcriptionClient = TranscriptionClient()
        transcriptionClient?.onTranscript = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.state == .listening else { return }
                self.sessionTranscript += (self.sessionTranscript.isEmpty ? "" : " ") + text
                self.popoverVC.update(state: self.state, transcript: self.sessionTranscript)
            }
        }
        transcriptionClient?.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.state = .error(message)
            }
        }
        transcriptionClient?.connect()

        // Set up audio capture
        audioCaptureManager = AudioCaptureManager()
        audioCaptureManager?.onAudioChunk = { [weak self] data in
            self?.transcriptionClient?.sendAudio(data)
        }
        audioCaptureManager?.onError = { [weak self] message in
            DispatchQueue.main.async { self?.state = .error(message) }
        }
        audioCaptureManager?.startCapture()
    }

    private func stopAndSave() {
        audioCaptureManager?.stopCapture()
        transcriptionClient?.disconnect()
        audioCaptureManager = nil
        transcriptionClient = nil

        state = .saving
        saveTranscript()
    }

    private func saveTranscript() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = docs.appendingPathComponent("LiveScribe", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            state = .error("Could not create folder:\n\(error.localizedDescription)")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = formatter.string(from: Date()) + ".txt"
        let fileURL = folder.appendingPathComponent(filename)

        do {
            try sessionTranscript.write(to: fileURL, atomically: true, encoding: .utf8)
            state = .saved(fileURL.path)
        } catch {
            state = .error("Save failed:\n\(error.localizedDescription)")
        }
    }

    private func retry() {
        state = .idle
    }

    // MARK: - Icons

    private func icon(for state: AppState) -> NSImage? {
        let name: String
        let tint: NSColor?

        switch state {
        case .idle:
            name = "waveform"
            tint = nil
        case .starting:
            name = "ellipsis.circle"
            tint = .secondaryLabelColor
        case .listening:
            name = "waveform.badge.mic"
            tint = .systemRed
        case .saving:
            name = "arrow.down.circle"
            tint = .systemOrange
        case .saved:
            name = "checkmark.circle"
            tint = .systemGreen
        case .error:
            name = "exclamationmark.triangle"
            tint = .systemRed
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        var image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        if let color = tint {
            image = image?.tinted(with: color)
        }

        image?.isTemplate = (tint == nil)
        return image
    }
}

// MARK: - EventMonitor

/// Detects clicks outside the popover to dismiss it.
final class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

// MARK: - NSImage tint helper

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let tinted = self.copy() as! NSImage
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}
