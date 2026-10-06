import Foundation
import CoreVideo
import Accelerate

/// Wire format used ONLY on the local Unix-domain socket between the Broadcast Upload
/// Extension (which captures the screen via ReplayKit) and the main app (which does the
/// actual WebRTC encoding/sending). This never leaves the device.
///
/// Frame = [1 byte kind][4 byte big-endian payload length][payload]
///
/// Video payload = [4B width][4B height][4B isFullRange (0/1)][4B rotation degrees][8B capture time, microseconds]
///                 [Y plane: width*height bytes][CbCr plane: width*(height/2) bytes]
///   i.e. tightly packed NV12 (420 bi-planar) — ReplayKit delivers NV12, NOT BGRA, and it is
///   half the bytes of BGRA. Width/height are always even and already downscaled in the
///   extension (see makeVideoFrame) to keep the extension under its ~50MB memory limit.
/// Audio payload = [raw 16-bit PCM mono bytes, 48kHz — same format the Android sender
///                  and the TV receiver already use, so the TV side needs no changes]
enum FrameKind: UInt8 {
    case video = 1
    case audio = 2
    /// UTF-8 diagnostic text from the extension (audio format etc.), shown in the app.
    case info = 3
}

enum FrameTransport {
    static let videoHeaderSize = 24

    /// Longest side of the frames sent to the TV. 1920 matches a full-HD TV on the long side while
    /// cutting the per-frame copy from ~9MB to ~3MB.
    static let maxDimension = 1920

    static func encodeHeader(kind: FrameKind, payloadLength: Int) -> Data {
        var header = Data(capacity: 5)
        header.append(kind.rawValue)
        var len = UInt32(payloadLength).bigEndian
        withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
        return header
    }

    /// Builds a complete framed video message from a ReplayKit NV12 CVPixelBuffer,
    /// downscaled so its longest side is at most `maxDimension`. Returns empty Data if the
    /// buffer isn't a format we understand (the caller then just skips the frame).
    static func makeVideoFrame(pixelBuffer: CVPixelBuffer, rotationDegrees: Int, captureTime: Double) -> Data {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isFullRange: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: isFullRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: isFullRange = false
        default: return Data()
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return Data() }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let srcW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard srcW > 1, srcH > 1,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return Data() }

        // The main app fits every frame into a 1920x1080 canvas, so there is no point sending
        // more pixels than that box can show (after rotation). A portrait phone then costs
        // ~0.8MB per frame instead of ~2.5MB, which keeps audio and video flowing smoothly.
        let swapped = rotationDegrees == 90 || rotationDegrees == 270
        let shownW = Double(swapped ? srcH : srcW)
        let shownH = Double(swapped ? srcW : srcH)
        let scale = min(1.0, 1920.0 / shownW, 1080.0 / shownH)
        let outW = max(2, (Int(Double(srcW) * scale) / 2) * 2)
        let outH = max(2, (Int(Double(srcH) * scale) / 2) * 2)

        let ySize = outW * outH
        let cSize = outW * (outH / 2)
        let payloadSize = videoHeaderSize + ySize + cSize

        var message = encodeHeader(kind: .video, payloadLength: payloadSize)
        message.reserveCapacity(5 + payloadSize)
        for value in [UInt32(outW), UInt32(outH), isFullRange ? 1 : 0, UInt32(rotationDegrees)] {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { message.append(contentsOf: $0) }
        }
        var timeBE = UInt64(max(0, captureTime) * 1_000_000).bigEndian
        withUnsafeBytes(of: &timeBE) { message.append(contentsOf: $0) }

        var planes = Data(count: ySize + cSize)
        let ok: Bool = planes.withUnsafeMutableBytes { raw -> Bool in
            guard let dest = raw.baseAddress else { return false }

            var srcY = vImage_Buffer(data: yBase,
                                     height: vImagePixelCount(srcH),
                                     width: vImagePixelCount(srcW),
                                     rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
            var dstY = vImage_Buffer(data: dest,
                                     height: vImagePixelCount(outH),
                                     width: vImagePixelCount(outW),
                                     rowBytes: outW)
            guard vImageScale_Planar8(&srcY, &dstY, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            else { return false }

            // The interleaved CbCr plane has half the pixels in each direction, with 2
            // bytes (Cb, Cr) per pixel.
            var srcC = vImage_Buffer(data: cBase,
                                     height: vImagePixelCount(srcH / 2),
                                     width: vImagePixelCount(srcW / 2),
                                     rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
            var dstC = vImage_Buffer(data: dest + ySize,
                                     height: vImagePixelCount(outH / 2),
                                     width: vImagePixelCount(outW / 2),
                                     rowBytes: outW)
            return vImageScale_CbCr8(&srcC, &dstC, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok else { return Data() }

        message.append(planes)
        return message
    }

    static func makeInfoFrame(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        var message = encodeHeader(kind: .info, payloadLength: bytes.count)
        message.append(bytes)
        return message
    }

    static func makeAudioFrame(pcm: Data) -> Data {
        var message = encodeHeader(kind: .audio, payloadLength: pcm.count)
        message.append(pcm)
        return message
    }
}

/// Decoded video payload, rebuilt on the main-app side into an NV12 CVPixelBuffer.
struct DecodedVideoFrame {
    let width: Int
    let height: Int
    let isFullRange: Bool
    let rotationDegrees: Int
    /// Capture time (CACurrentMediaTime seconds, same clock in both processes).
    let captureTime: Double
    /// Tightly packed: Y plane (width*height) followed by CbCr plane (width*height/2).
    let pixelBytes: Data
}
