import Foundation
import CoreVideo

/// Wire format used ONLY on the local Unix-domain socket between the Broadcast Upload
/// Extension (which captures the screen via ReplayKit) and the main app (which does the
/// actual WebRTC encoding/sending). This never leaves the device.
///
/// Frame = [1 byte kind][4 byte big-endian payload length][payload]
///
/// Video payload   = [4B width][4B height][4B bytesPerRow][raw BGRA pixel bytes]
/// Audio payload   = [raw 16-bit PCM mono bytes, 48kHz — same format the Android sender
///                    and the TV receiver already use, so the TV side needs no changes]
enum FrameKind: UInt8 {
    case video = 1
    case audio = 2
}

enum FrameTransport {
    static func encodeHeader(kind: FrameKind, payloadLength: Int) -> Data {
        var header = Data(capacity: 5)
        header.append(kind.rawValue)
        var len = UInt32(payloadLength).bigEndian
        withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
        return header
    }

    /// Builds a complete framed video message from a BGRA CVPixelBuffer.
    /// Copies the pixel bytes once (unavoidable to cross the process boundary over a
    /// plain socket). Frames are downscaled by the caller beforehand if needed to keep
    /// this copy cheap — see SampleHandler.
    static func makeVideoFrame(pixelBuffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return Data() }

        let pixelByteCount = bytesPerRow * height
        var payload = Data(capacity: 12 + pixelByteCount)
        for value in [UInt32(width), UInt32(height), UInt32(bytesPerRow)] {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
        }
        payload.append(Data(bytes: base, count: pixelByteCount))

        var message = encodeHeader(kind: .video, payloadLength: payload.count)
        message.append(payload)
        return message
    }

    static func makeAudioFrame(pcm: Data) -> Data {
        var message = encodeHeader(kind: .audio, payloadLength: pcm.count)
        message.append(pcm)
        return message
    }
}

/// Decoded video payload, rebuilt on the main-app side into a CVPixelBuffer.
struct DecodedVideoFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelBytes: Data
}
