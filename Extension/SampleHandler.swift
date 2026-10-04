import ReplayKit
import Network
import CoreMedia

/// Runs inside the system's Broadcast Upload Extension process, which iOS limits to
/// ~50MB of memory — too tight for a full WebRTC stack. So this file does the minimum
/// possible: grab each captured video/audio sample and forward it immediately, as raw
/// bytes, to the main app over a local Unix-domain socket (inside the shared App Group
/// container, the only thing both the app and the extension — separately sandboxed —
/// are both allowed to touch). All the actual WebRTC encoding/sending happens in the
/// main app process (see App/WebRTCSender.swift), which has normal memory limits.
final class SampleHandler: RPBroadcastSampleHandler {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.screenmirror.sender.broadcast-forwarder")

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let endpoint = NWEndpoint.unix(path: AppGroup.socketPath)
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finishBroadcastWithError(error)
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard let connection, connection.state == .ready else { return }

        switch sampleBufferType {
        case .video:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let frame = FrameTransport.makeVideoFrame(pixelBuffer: pixelBuffer)
            guard !frame.isEmpty else { return }
            connection.send(content: frame, completion: .contentProcessed { _ in })

        case .audioApp:
            // System/app audio only (matches the Android sender, which also captures
            // playback audio, not the microphone) — converted to 16-bit PCM mono 48kHz
            // to exactly match SystemAudioCapturer.kt / AudioPlayer.kt on the other end.
            guard let pcm = PCMConverter.toMono16BitPCM(sampleBuffer: sampleBuffer) else { return }
            let frame = FrameTransport.makeAudioFrame(pcm: pcm)
            connection.send(content: frame, completion: .contentProcessed { _ in })

        case .audioMic:
            break // not mirrored, same as the Android sender

        @unknown default:
            break
        }
    }
}
