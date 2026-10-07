import Foundation

/// Speaks the exact same JSON-over-WebSocket protocol as the Android sender
/// (see sender-phone/.../WebRtcSenderClient.kt and receiver-tv/.../SignalingServer.kt):
///   {"type":"offer","sdp":"..."}
///   {"type":"answer","sdp":"..."}
///   {"type":"ice","candidate":"...","sdpMid":"...","sdpMLineIndex":0}
///   {"type":"bye"}
/// plus raw binary WebSocket frames for 16-bit PCM audio.
///
/// Because this matches the existing protocol exactly, the TV (receiver-tv) app needs
/// ZERO changes to accept an iPhone as the sender instead of an Android phone.
final class SignalingClient: NSObject, URLSessionWebSocketDelegate {
    struct IceMessage {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: Int32
    }

    var onAnswer: ((String) -> Void)?
    var onIce: ((IceMessage) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    /// Why the last connection ended (shown in the test stats).
    private(set) var lastEvent = ""

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!

    func connect(host: String, port: Int) {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let hostPart = host.contains(":") ? "[\(host)]" : host // IPv6 literals need brackets
        guard let url = URL(string: "ws://\(hostPart):\(port)") else {
            onDisconnected?()
            return
        }
        task = session.webSocketTask(with: url)
        task?.resume()
        listen()
    }

    func disconnect() {
        // Cancel only after the "bye" has actually been written, otherwise it is lost.
        let closing = task
        task = nil
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "bye"]),
           let text = String(data: data, encoding: .utf8) {
            closing?.send(.string(text)) { _ in closing?.cancel(with: .goingAway, reason: nil) }
        } else {
            closing?.cancel(with: .goingAway, reason: nil)
        }
    }

    func sendOffer(sdp: String) {
        sendJSON(["type": "offer", "sdp": sdp])
    }

    func sendIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        sendJSON([
            "type": "ice",
            "candidate": candidate,
            "sdpMid": sdpMid ?? NSNull(),
            "sdpMLineIndex": sdpMLineIndex
        ])
    }

    func sendAudioFrame(_ pcm: Data) {
        task?.send(.data(pcm)) { _ in }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lastEvent = "recv: \((error as NSError).domain) \((error as NSError).code)"
                self.onDisconnected?()
                return
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handle(text: text)
                case .data:
                    break // the TV never sends us binary frames in this protocol
                @unknown default:
                    break
                }
            }
            self.listen()
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "answer":
            if let sdp = json["sdp"] as? String { onAnswer?(sdp) }
        case "ice":
            if let candidate = json["candidate"] as? String {
                let sdpMid = json["sdpMid"] as? String
                let sdpMLineIndex = Int32(json["sdpMLineIndex"] as? Int ?? 0)
                onIce?(IceMessage(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex))
            }
        default:
            break
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onConnected?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lastEvent = "closed code \(closeCode.rawValue)"
        onDisconnected?()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lastEvent = "failed: \((error as NSError).domain) \((error as NSError).code)"
        }
        onDisconnected?()
    }
}
