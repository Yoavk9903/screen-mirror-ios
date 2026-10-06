import Foundation
import WebRTC
import CoreVideo
import Accelerate

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
    private var canvasPools: [Bool: CVPixelBufferPool] = [:] // by isFullRange; videoCapturerQueue only
    private lazy var audioPacer = AudioPacer { [weak self] chunk in self?.signaling.sendAudioFrame(chunk) }

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

        // Screen content, not a camera: tells WebRTC to keep the picture sharp and the
        // exact size/shape of the phone screen instead of treating it like camera video.
        let source = factory.videoSource(forScreenCast: true)
        videoSource = source
        let videoTrack = factory.videoTrack(with: source, trackId: "video0")
        pc.add(videoTrack, streamIds: ["stream0"])

        audioPacer.start()

        pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            self.peerConnection?.setLocalDescription(sdp) { _ in }
            self.signaling.sendOffer(sdp: sdp.sdp)
        }
    }

    func stop() {
        audioPacer.stop()
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
            // Always send a fixed 16:9 Full-HD frame with the phone screen fitted inside it
            // (black bars where needed), whatever the phone's shape or orientation. The TV then
            // always receives the same standard video shape, so nothing can be cropped or
            // stretched by any stage between here and the TV's screen.
            guard let canvas = self.composeCanvas(from: frame) else { return }

            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: canvas)
            let timestampNs = Int64(DispatchTime.now().uptimeNanoseconds)
            let rtcFrame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timestampNs)
            videoSource.capturer(RTCVideoCapturer(), didCapture: rtcFrame)
        }
    }

    func push(audioFrame pcm: Data) {
        audioPacer.push(pcm)
    }

    private static let canvasWidth = 1920
    private static let canvasHeight = 1080

    /// Rotates the packed NV12 planes by 90/180/270 degrees clockwise (ReplayKit delivers the
    /// buffer in portrait layout and only tags the real orientation).
    private static func rotated(_ frame: DecodedVideoFrame) -> (width: Int, height: Int, y: [UInt8], c: [UInt8])? {
        let w = frame.width, h = frame.height
        let degrees = frame.rotationDegrees
        let constant: UInt8
        switch degrees {
        case 90: constant = UInt8(kRotate90DegreesClockwise)
        case 180: constant = UInt8(kRotate180DegreesClockwise)
        case 270: constant = UInt8(kRotate270DegreesClockwise)
        default: return nil
        }
        let swap = degrees == 90 || degrees == 270
        let outW = swap ? h : w, outH = swap ? w : h
        var outY = [UInt8](repeating: 0, count: outW * outH)
        var outC = [UInt8](repeating: 0, count: outW * (outH / 2))
        let ok: Bool = frame.pixelBytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var srcY = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                     height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            var srcC = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base + w * h),
                                     height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2), rowBytes: w)
            return outY.withUnsafeMutableBytes { yRaw -> Bool in
                outC.withUnsafeMutableBytes { cRaw -> Bool in
                    var dstY = vImage_Buffer(data: yRaw.baseAddress, height: vImagePixelCount(outH),
                                             width: vImagePixelCount(outW), rowBytes: outW)
                    var dstC = vImage_Buffer(data: cRaw.baseAddress, height: vImagePixelCount(outH / 2),
                                             width: vImagePixelCount(outW / 2), rowBytes: outW)
                    let e1 = vImageRotate90_Planar8(&srcY, &dstY, constant, 0, vImage_Flags(kvImageNoFlags))
                    // The interleaved CbCr pairs are rotated as single 16-bit pixels.
                    let e2 = vImageRotate90_Planar16U(&srcC, &dstC, constant, 0, vImage_Flags(kvImageNoFlags))
                    return e1 == kvImageNoError && e2 == kvImageNoError
                }
            }
        }
        return ok ? (outW, outH, outY, outC) : nil
    }

    private func canvasPool(fullRange: Bool) -> CVPixelBufferPool? {
        if let pool = canvasPools[fullRange] { return pool }
        let format = fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: Self.canvasWidth,
            kCVPixelBufferHeightKey: Self.canvasHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess,
              let created = pool else { return nil }
        canvasPools[fullRange] = created
        return created
    }

    /// Builds the fixed-size 16:9 NV12 frame: black background, phone screen scaled to fit and
    /// centred.
    private func composeCanvas(from frame: DecodedVideoFrame) -> CVPixelBuffer? {
        guard let pool = canvasPool(fullRange: frame.isFullRange) else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let canvas = buffer else { return nil }

        CVPixelBufferLockBaseAddress(canvas, [])
        defer { CVPixelBufferUnlockBaseAddress(canvas, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(canvas, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(canvas, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(canvas, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(canvas, 1)
        let canvasW = Self.canvasWidth, canvasH = Self.canvasHeight

        memset(yBase, frame.isFullRange ? 0 : 16, yStride * canvasH)   // black
        memset(cBase, 128, cStride * (canvasH / 2))                      // neutral chroma

        var rotatedPlanes = Self.rotated(frame)
        if frame.rotationDegrees != 0 && rotatedPlanes == nil { return nil }
        let srcW = rotatedPlanes?.width ?? frame.width
        let srcH = rotatedPlanes?.height ?? frame.height

        let scale = min(Double(canvasW) / Double(srcW), Double(canvasH) / Double(srcH))
        let dw = max(2, Int(Double(srcW) * scale) & ~1)
        let dh = max(2, Int(Double(srcH) * scale) & ~1)
        let x0 = ((canvasW - dw) / 2) & ~1
        let y0 = ((canvasH - dh) / 2) & ~1

        func scalePlanes(srcYPtr: UnsafeMutableRawPointer, srcCPtr: UnsafeMutableRawPointer) -> Bool {
            var srcY = vImage_Buffer(data: srcYPtr, height: vImagePixelCount(srcH),
                                     width: vImagePixelCount(srcW), rowBytes: srcW)
            var dstY = vImage_Buffer(data: yBase + y0 * yStride + x0, height: vImagePixelCount(dh),
                                     width: vImagePixelCount(dw), rowBytes: yStride)
            var srcC = vImage_Buffer(data: srcCPtr, height: vImagePixelCount(srcH / 2),
                                     width: vImagePixelCount(srcW / 2), rowBytes: srcW)
            var dstC = vImage_Buffer(data: cBase + (y0 / 2) * cStride + x0, height: vImagePixelCount(dh / 2),
                                     width: vImagePixelCount(dw / 2), rowBytes: cStride)
            return vImageScale_Planar8(&srcY, &dstY, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                && vImageScale_CbCr8(&srcC, &dstC, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }

        let ok: Bool
        if var planes = rotatedPlanes {
            ok = planes.y.withUnsafeMutableBytes { yRaw -> Bool in
                planes.c.withUnsafeMutableBytes { cRaw -> Bool in
                    guard let yp = yRaw.baseAddress, let cp = cRaw.baseAddress else { return false }
                    return scalePlanes(srcYPtr: yp, srcCPtr: cp)
                }
            }
            rotatedPlanes = planes
        } else {
            ok = frame.pixelBytes.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                let p = UnsafeMutableRawPointer(mutating: base)
                return scalePlanes(srcYPtr: p, srcCPtr: p + frame.width * frame.height)
            }
        }
        return ok ? canvas : nil
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
