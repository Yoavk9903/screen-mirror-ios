import Foundation
import WebRTC
import CoreVideo

/// The iOS mirror of WebRtcSenderClient.kt on Android: creates one PeerConnection acting
/// as the OFFERER, pushes locally-captured video frames into it, and sends system audio
/// out-of-band over the signaling WebSocket as raw PCM — exactly like the Android sender,
/// so receiver-tv doesn't need to know or care which platform it's talking to.
final class WebRTCSender: NSObject {
    private let signaling: SignalingClient
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoCapturerQueue = DispatchQueue(label: "com.screenmirror.sender.video-feed")

    init(signaling: SignalingClient) {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        self.signaling = signaling
        super.init()

        signaling.onAnswer = { [weak self] sdp in
            self?.handleAnswer(sdp: sdp)
        }
        signaling.onIce = { [weak self] ice in
            let candidate = RTCIceCandidate(sdp: ice.candidate, sdpMLineIndex: ice.sdpMLineIndex, sdpMid: ice.sdpMid)
            self?.peerConnection?.add(candidate) { _ in }
        }
    }

    func start() {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            return
        }
        peerConnection = pc

        let source = factory.videoSource()
        videoSource = source
        let videoTrack = factory.videoTrack(with: source, trackId: "video0")
        pc.add(videoTrack, streamIds: ["stream0"])

        pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            self.peerConnection?.setLocalDescription(sdp) { _ in }
            self.signaling.sendOffer(sdp: sdp.sdp)
        }
    }

    func stop() {
        peerConnection?.close()
        peerConnection = nil
        videoSource = nil
    }

    /// Called by FrameReceiver for every frame forwarded from the Broadcast Upload
    /// Extension. Wraps the raw BGRA bytes back into a CVPixelBuffer and pushes it into
    /// WebRTC's own video pipeline, which encodes it (hardware H.264, same as the
    /// Android sender's ScreenCapturerAndroid + WebRTC path) and sends it over the
    /// already-negotiated PeerConnection.
    func push(videoFrame frame: DecodedVideoFrame) {
        videoCapturerQueue.async { [weak self] in
            guard let self, let videoSource = self.videoSource else { return }
            guard let pixelBuffer = Self.makePixelBuffer(from: frame) else { return }

            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let timestampNs = Int64(DispatchTime.now().uptimeNanoseconds)
            let rtcFrame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timestampNs)
            videoSource.capturer(RTCVideoCapturer(), didCapture: rtcFrame)
        }
    }

    func push(audioFrame pcm: Data) {
        signaling.sendAudioFrame(pcm)
    }

    private static func makePixelBuffer(from frame: DecodedVideoFrame) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frame.width,
            frame.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dest = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        frame.pixelBytes.withUnsafeBytes { raw in
            memcpy(dest, raw.baseAddress, min(frame.pixelBytes.count, CVPixelBufferGetDataSize(buffer)))
        }
        return buffer
    }

    private func handleAnswer(sdp: String) {
        let description = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnection?.setRemoteDescription(description) { _ in }
    }
}

extension WebRTCSender: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        signaling.sendIceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
}
