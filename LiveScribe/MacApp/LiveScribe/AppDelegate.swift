import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?
    private var pythonProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
        launchPythonServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let proc = pythonProcess, proc.isRunning else { return }
        proc.terminate()  // SIGTERM — gives Python a chance to clean up
        // Block up to 3 s for a graceful exit before the OS reclaims resources
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Python subprocess

    private func launchPythonServer() {
        let process = Process()

        // Resolve the Python binary and server script paths.
        // In development: override with environment variables.
        // In release: look inside the app bundle.
        let pythonBin: String
        let serverScript: String

        if let envPython = ProcessInfo.processInfo.environment["LIVESCRIBE_PYTHON_BIN"] {
            pythonBin = envPython
        } else if let bundlePath = Bundle.main.path(forResource: "python3", ofType: nil,
                                                      inDirectory: "PythonServer/venv/bin") {
            pythonBin = bundlePath
        } else {
            // Last resort: system python3
            pythonBin = "/usr/bin/env"
        }

        if let envScript = ProcessInfo.processInfo.environment["LIVESCRIBE_SERVER_SCRIPT"] {
            serverScript = envScript
        } else if let bundlePath = Bundle.main.path(forResource: "server", ofType: "py",
                                                     inDirectory: "PythonServer") {
            serverScript = bundlePath
        } else {
            print("[AppDelegate] Cannot locate server.py — transcription unavailable.")
            statusBarController?.transitionTo(.error("Python server not found.\nSet LIVESCRIBE_SERVER_SCRIPT env var."))
            return
        }

        if pythonBin == "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", serverScript]
        } else {
            process.executableURL = URL(fileURLWithPath: pythonBin)
            process.arguments = [serverScript]
        }

        // Pipe stdout so we can detect the READY signal
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for rawLine in line.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "READY" {
                    DispatchQueue.main.async {
                        self?.statusBarController?.pythonServerIsReady()
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if proc.terminationStatus != 0 {
                    self.statusBarController?.transitionTo(
                        .error("Python server exited (code \(proc.terminationStatus)).")
                    )
                }
            }
        }

        // Clear any stale server process that may be holding port 8765
        // (e.g. from a previous Xcode run that wasn't killed cleanly)
        let port = ProcessInfo.processInfo.environment["LIVESCRIBE_PORT"] ?? "8765"
        let clear = Process()
        clear.executableURL = URL(fileURLWithPath: "/bin/sh")
        clear.arguments = ["-c", "lsof -ti:\(port) | xargs kill -9 2>/dev/null || true"]
        try? clear.run()
        clear.waitUntilExit()

        do {
            try process.run()
            pythonProcess = process
            print("[AppDelegate] Python server launched (pid \(process.processIdentifier))")
        } catch {
            print("[AppDelegate] Failed to launch Python server: \(error)")
            statusBarController?.transitionTo(.error("Could not start Python server:\n\(error.localizedDescription)"))
        }
    }
}
