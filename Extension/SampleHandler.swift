import ReplayKit
import Network
import CoreMedia
import ImageIO
import QuartzCore

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

    // The extension is capped at ~50MB, so never let video frames pile up: at most 2 frames
    // may be waiting to be written to the socket, and we cap the rate at ~30fps. Excess
    // frames are simply dropped (the TV just sees a slightly lower frame rate).
    private let inFlightVideo = DispatchSemaphore(value: 2)
    // Scaling a full-screen frame takes a few ms; doing it on ReplayKit's callback thread would
    // delay (and make ReplayKit drop) audio buffers. So video work runs on its own queue, one
    // frame at a time, and frames that arrive while it is busy are skipped.
    private let videoWork = DispatchSemaphore(value: 1)
    private let videoQueue = DispatchQueue(label: "com.screenmirror.sender.video-work", qos: .userInitiated)
    private var audioBufferCount = 0
    private var lastVideoTime: CFTimeInterval = 0
    private let minVideoInterval: CFTimeInterval = 1.0 / 30.0

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
            let now = CACurrentMediaTime()
            guard now - lastVideoTime >= minVideoInterval else { return }
            guard videoWork.wait(timeout: .now()) == .success else { return } // still busy: skip
            guard inFlightVideo.wait(timeout: .now()) == .success else { // socket backed up: skip
                videoWork.signal()
                return
            }
            lastVideoTime = now
            let rotation = Self.rotationDegrees(for: sampleBuffer)
            videoQueue.async { [inFlightVideo, videoWork] in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    inFlightVideo.signal(); videoWork.signal(); return
                }
                let frame = FrameTransport.makeVideoFrame(pixelBuffer: pixelBuffer, rotationDegrees: rotation)
                videoWork.signal()
                guard !frame.isEmpty else { inFlightVideo.signal(); return }
                connection.send(content: frame, completion: .contentProcessed { _ in
                    inFlightVideo.signal()
                })
            }

        case .audioApp:
            // System/app audio only (matches the Android sender, which also captures
            // playback audio, not the microphone) — converted to 16-bit PCM mono 48kHz
            // to exactly match SystemAudioCapturer.kt / AudioPlayer.kt on the other end.
            guard let pcm = PCMConverter.toMono16BitPCM(sampleBuffer: sampleBuffer) else { return }
            audioBufferCount += 1
            if audioBufferCount % 50 == 1 { // now and then, tell the app what format we are getting
                connection.send(content: FrameTransport.makeInfoFrame(PCMConverter.lastDescription),
                                completion: .contentProcessed { _ in })
            }
            let frame = FrameTransport.makeAudioFrame(pcm: pcm)
            connection.send(content: frame, completion: .contentProcessed { _ in })

        case .audioMic:
            break // not mirrored, same as the Android sender

        @unknown default:
            break
        }
    }

    /// ReplayKit always delivers the buffer in the phone's native portrait layout and tags
    /// the real orientation on the sample; this maps it to the rotation WebRTC needs (and
    /// that the TV's renderer then applies). Mapping still to be verified on a real device.
    private static func rotationDegrees(for sampleBuffer: CMSampleBuffer) -> Int {
        guard let raw = CMGetAttachment(sampleBuffer,
                                        key: RPVideoSampleOrientationKey as CFString,
                                        attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value)
        else { return 0 }
        switch orientation {
        case .left, .leftMirrored: return 90
        case .down, .downMirrored: return 180
        case .right, .rightMirrored: return 270
        default: return 0
        }
    }
}
