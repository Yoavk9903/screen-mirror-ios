import Foundation

/// Wires the three pieces together for the life of one mirroring session:
///  1. SignalingClient  — talks to the TV over the WebSocket (offer/answer/ice)
///  2. FrameReceiver     — listens locally for frames forwarded from the broadcast extension
///  3. WebRTCSender       — encodes those frames and actually streams them to the TV
///
/// The main app starts FrameReceiver + the signaling connection as soon as a TV is
/// picked; the user then taps the system broadcast-picker button (see
/// BroadcastPickerView) to actually start ReplayKit capture, which is what causes frames
/// to start flowing in.
final class MirrorSession: ObservableObject {
    @Published private(set) var isConnected = false

    private let signaling = SignalingClient()
    private let frameReceiver = FrameReceiver()
    private lazy var webRTCSender = WebRTCSender(signaling: signaling)

    func connect(to tv: DiscoveredTv) {
        signaling.onConnected = { [weak self] in
            DispatchQueue.main.async { self?.isConnected = true }
            self?.webRTCSender.start()
        }
        signaling.onDisconnected = { [weak self] in
            DispatchQueue.main.async { self?.isConnected = false }
        }

        frameReceiver.onVideoFrame = { [weak self] frame in
            self?.webRTCSender.push(videoFrame: frame)
        }
        frameReceiver.onAudioFrame = { [weak self] pcm in
            self?.webRTCSender.push(audioFrame: pcm)
        }

        frameReceiver.start()
        signaling.connect(host: tv.host, port: tv.port)
    }

    func disconnect() {
        webRTCSender.stop()
        frameReceiver.stop()
        signaling.disconnect()
    }
}
