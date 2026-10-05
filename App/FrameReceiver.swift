import Foundation
import Network

/// Runs in the main app. Listens on the local Unix-domain socket the Broadcast Upload
/// Extension connects to (see Extension/SampleHandler.swift) and reassembles the framed
/// messages it sends back into video/audio frames for WebRTCSender to encode and ship
/// over the real network connection to the TV.
final class FrameReceiver {
    var onVideoFrame: ((DecodedVideoFrame) -> Void)?
    var onAudioFrame: ((Data) -> Void)?

    /// Diagnostics shown in the app UI (TestFlight builds): how much data has arrived
    /// from the broadcast extension. Written on the receiver queue, read loosely by the UI.
    private(set) var videoFrameCount = 0
    private(set) var audioFrameCount = 0
    private(set) var audioByteCount = 0
    private(set) var lastFrameSize = ""

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.screenmirror.sender.frame-receiver")

    func start() {
        let path = AppGroup.socketPath
        try? FileManager.default.removeItem(atPath: path) // stale socket from a previous run

        // A plain NWListener(using: .tcp) only listens on an ephemeral TCP port — it does
        // NOT bind to AppGroup.socketPath. The extension side (SampleHandler.swift) connects
        // via NWConnection(to: NWEndpoint.unix(path:), using: .tcp), so this side must bind
        // to that same Unix-domain path by setting requiredLocalEndpoint on the parameters;
        // the "using: .tcp" transport is otherwise ignored for a Unix-domain endpoint.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        guard let listener = try? NWListener(using: params) else { return }
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
            let length = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
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
                    self.videoFrameCount += 1
                    self.lastFrameSize = "\(frame.width)x\(frame.height) r\(frame.rotationDegrees)"
                    self.onVideoFrame?(frame)
                }
            case .audio:
                self.audioFrameCount += 1
                self.audioByteCount += data.count
                self.onAudioFrame?(data)
            }
            self.readHeader(connection)
        }
    }

    private func decodeVideo(_ payload: Data) -> DecodedVideoFrame? {
        let headerSize = FrameTransport.videoHeaderSize
        guard payload.count > headerSize else { return nil }
        func field(_ offset: Int) -> Int {
            Int(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian })
        }
        let width = field(0)
        let height = field(4)
        let isFullRange = field(8) != 0
        let rotation = field(12)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else { return nil }
        let expected = width * height + width * (height / 2)
        guard payload.count - headerSize == expected else { return nil }
        let pixelBytes = payload.subdata(in: (payload.startIndex + headerSize)..<payload.endIndex)
        return DecodedVideoFrame(width: width, height: height, isFullRange: isFullRange,
                                 rotationDegrees: rotation, pixelBytes: pixelBytes)
    }
}
