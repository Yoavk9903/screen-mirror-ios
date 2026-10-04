import CoreMedia
import AVFoundation

/// Converts a ReplayKit audio CMSampleBuffer (whatever format the system hands us) into
/// 16-bit mono PCM at 48kHz — byte-for-byte the same format the Android sender produces
/// (see SystemAudioCapturer.kt) and the TV already expects (AudioPlayer.kt), so the TV
/// app needs no changes to accept audio from an iPhone.
enum PCMConverter {
    static func toMono16BitPCM(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        guard var blockBuffer: CMBlockBuffer? = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var audioBufferList = AudioBufferList()
        var data: Data?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let mData = audioBufferList.mBuffers.mData else { return nil }

        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        let sourceFormat = asbd.pointee

        // Fast path: already 16-bit int PCM. Just downmix to mono / resample if needed.
        let sourceData = Data(bytes: mData, count: byteCount)

        if sourceFormat.mFormatID == kAudioFormatLinearPCM,
           sourceFormat.mBitsPerChannel == 16,
           sourceFormat.mSampleRate == 48000,
           sourceFormat.mChannelsPerFrame == 1 {
            data = sourceData
        } else {
            data = resampleToMono48kHz16Bit(sourceData, format: sourceFormat)
        }

        return data
    }

    /// Minimal conversion for the common case ReplayKit actually hands us (Float32,
    /// interleaved stereo, device sample rate). Not a general-purpose resampler — if the
    /// sample rate differs from 48kHz this does simple nearest-neighbor resampling, which
    /// is good enough for mirrored system audio (see the matching note in
    /// SystemAudioCapturer.kt about why mono was chosen on Android too).
    private static func resampleToMono48kHz16Bit(_ data: Data, format: AudioStreamBasicDescription) -> Data? {
        guard format.mFormatID == kAudioFormatLinearPCM else { return nil }
        let channels = Int(format.mChannelsPerFrame)
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bytesPerSample = Int(format.mBitsPerChannel) / 8
        guard channels > 0, bytesPerSample > 0 else { return nil }

        let frameCount = data.count / (bytesPerSample * channels)
        var monoSamples = [Int16](repeating: 0, count: frameCount)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    let offset = (frame * channels + channel) * bytesPerSample
                    if isFloat, bytesPerSample == 4 {
                        let f = raw.loadUnaligned(fromByteOffset: offset, as: Float32.self)
                        sum += f
                    } else if bytesPerSample == 2 {
                        let s = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                        sum += Float(s) / Float(Int16.max)
                    }
                }
                let averaged = sum / Float(channels)
                monoSamples[frame] = Int16(max(-1.0, min(1.0, averaged)) * Float(Int16.max))
            }
        }

        let sourceRate = format.mSampleRate
        let targetRate: Double = 48000
        guard sourceRate > 0 else { return nil }

        if abs(sourceRate - targetRate) < 1 {
            return monoSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        let ratio = targetRate / sourceRate
        let outCount = Int(Double(monoSamples.count) * ratio)
        var resampled = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let sourceIndex = min(monoSamples.count - 1, Int(Double(i) / ratio))
            resampled[i] = monoSamples[sourceIndex]
        }
        return resampled.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
