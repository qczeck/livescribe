import Foundation

// MARK: - JSON message types (Server → Swift)

private struct ServerMessage: Decodable {
    let type: String
    let text: String?
    let message: String?
    let is_final: Bool?
}

// MARK: - Client

/// Manages the WebSocket connection to the Python transcription server.
final class TranscriptionClient: NSObject {

    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    private let url: URL = {
        let port = ProcessInfo.processInfo.environment["LIVESCRIBE_PORT"] ?? "8765"
        return URL(string: "ws://127.0.0.1:\(port)")!
    }()

    // MARK: - Connect / disconnect

    func connect() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        task = session?.webSocketTask(with: url)
        task?.resume()
        listen()
        sendControl(type: "start")
    }

    func disconnect() {
        sendControl(type: "stop")
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session = nil
    }

    // MARK: - Send audio

    /// Send a chunk of raw float32 audio data to the Python server.
    func sendAudio(_ data: Data) {
        // Silently drop send errors — if the connection is down the WebSocket
        // delegate already surfaces the underlying error; repeating it for
        // every audio chunk would spam the user with redundant messages.
        task?.send(.data(data)) { _ in }
    }

    // MARK: - Private helpers

    private func sendControl(type: String) {
        let json = "{\"type\":\"\(type)\"}"
        task?.send(.string(json)) { _ in }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                self.handleMessage(msg)
                self.listen()   // re-arm
            case .failure(let error):
                // Ignore normal close errors
                let nsErr = error as NSError
                if nsErr.code != 57 && nsErr.code != 54 {   // ENOTCONN / ECONNRESET
                    self.onError?("WebSocket error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(ServerMessage.self, from: data)
        else { return }

        switch msg.type {
        case "ready":
            break   // server signalled ready via stdout; this is a belt-and-suspenders ack

        case "transcript":
            if let t = msg.text, !t.isEmpty {
                onTranscript?(t)
            }

        case "error":
            onError?(msg.message ?? "Unknown server error")

        default:
            break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension TranscriptionClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // Connection established
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        // Normal close — no action needed
    }
}
