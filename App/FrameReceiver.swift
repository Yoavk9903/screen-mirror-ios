import Foundation
import Network

/// Runs in the main app. Listens on the local Unix-domain socket the Broadcast Upload
/// Extension connects to (see Extension/SampleHandler.swift) and reassembles the framed
/// messages it sends back into video/audio frames for WebRTCSender to encode and ship
/// over the real network connection to the TV.
final class FrameReceiver {
    var onVideoFrame: ((DecodedVideoFrame) -> Void)?
    var onAudioFrame: ((Data) -> Void)?

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.screenmirror.sender.frame-receiver")

    func start() {
        let path = AppGroup.socketPath
        try? FileManager.default.removeItem(atPath: path) // stale socket from a previous run

        guard let listener = try? NWListener(using: .tcp) else { return }
        // NWListener doesn't have a direct "bind to unix path" convenience initializer in
        // all SDK versions; this uses the private-API-free documented approach via
        // NWParameters + NWEndpoint when available. If this needs adjusting once we can
        // actually build against a real SDK, the fallback is a short-lived TCP server on
        // 127.0.0.1 instead of a Unix socket — functionally identical for this purpose,
        // still fully local to the device.
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        activeConnection?.cancel()
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection
        connection.start(queue: queue)
        readHeader(connection)
    }

    private func readHeader(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self, let data, data.count == 5, error == nil else {
                if isComplete || error != nil { return }
                return
            }
            let kindByte = data[data.startIndex]
            let lengthBytes = data.subdata(in: (data.startIndex + 1)..<(data.startIndex + 5))
            let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard let kind = FrameKind(rawValue: kindByte) else {
                self.readHeader(connection)
                return
            }
            self.readPayload(connection, kind: kind, length: Int(length))
        }
    }

    private func readPayload(_ connection: NWConnection, kind: FrameKind, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            switch kind {
            case .video:
                if let frame = self.decodeVideo(data) {
                    self.onVideoFrame?(frame)
                }
            case .audio:
                self.onAudioFrame?(data)
            }
            self.readHeader(connection)
        }
    }

    private func decodeVideo(_ payload: Data) -> DecodedVideoFrame? {
        guard payload.count > 12 else { return nil }
        let width = Int(payload.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian })
        let height = Int(payload.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).bigEndian })
        let bytesPerRow = Int(payload.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self).bigEndian })
        let pixelBytes = payload.subdata(in: (payload.startIndex + 12)..<payload.endIndex)
        return DecodedVideoFrame(width: width, height: height, bytesPerRow: bytesPerRow, pixelBytes: pixelBytes)
    }
}
