import CoreMedia
import AVFoundation

/// Converts a ReplayKit audio CMSampleBuffer (whatever format the system hands us) into
/// 16-bit little-endian mono PCM at 48kHz — the same format the Android sender produces
/// (see SystemAudioCapturer.kt) and the TV already expects (AudioPlayer.kt), so the TV
/// app needs no changes to accept audio from an iPhone.
///
/// ReplayKit's app audio is not guaranteed to be little-endian, interleaved, or 48kHz
/// (in practice it is often big-endian 16-bit stereo at 44.1kHz), so this handles int16 /
/// float32, either byte order, interleaved or planar, any channel count and sample rate.
enum PCMConverter {
    static func toMono16BitPCM(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        let format = asbdPtr.pointee
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate > 0 else { return nil }

        let channels = Int(format.mChannelsPerFrame)
        let bitsPerChannel = Int(format.mBitsPerChannel)
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isBigEndian = (format.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isPlanar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard channels > 0, (isFloat && bitsPerChannel == 32) || (!isFloat && bitsPerChannel == 16)
        else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        // Ask how big the AudioBufferList must be (planar audio needs one entry per channel).
        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, sizeNeeded > 0 else { return nil }

        let listMemory = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listMemory.deallocate() }
        let listPtr = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        guard buffers.count > 0 else { return nil }

        // Read one sample (as a -1...1 float) of a given channel at a given frame.
        func sample(frame: Int, channel: Int) -> Float? {
            let bytesPerSample = bitsPerChannel / 8
            let buffer: AudioBuffer
            let offset: Int
            if isPlanar {
                guard channel < buffers.count else { return nil }
                buffer = buffers[channel]
                offset = frame * bytesPerSample
            } else {
                buffer = buffers[0]
                offset = (frame * channels + channel) * bytesPerSample
            }
            guard let base = buffer.mData, offset + bytesPerSample <= Int(buffer.mDataByteSize) else { return nil }
            if isFloat {
                var bits = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                bits = isBigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits)
                return Float(bitPattern: bits)
            } else {
                var raw = base.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                raw = isBigEndian ? UInt16(bigEndian: raw) : UInt16(littleEndian: raw)
                return Float(Int16(bitPattern: raw)) / 32768.0
            }
        }

        // Downmix to mono.
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += sample(frame: frame, channel: channel) ?? 0
            }
            mono[frame] = sum / Float(channels)
        }

        // Resample to 48kHz (linear interpolation) if needed.
        let targetRate = 48000.0
        var output = mono
        if abs(format.mSampleRate - targetRate) >= 1 {
            let step = format.mSampleRate / targetRate
            let outCount = Int(Double(frameCount) / step)
            guard outCount > 0 else { return nil }
            output = [Float](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let position = Double(i) * step
                let index = Int(position)
                let fraction = Float(position - Double(index))
                let a = mono[min(index, frameCount - 1)]
                let b = mono[min(index + 1, frameCount - 1)]
                output[i] = a + (b - a) * fraction
            }
        }

        // To 16-bit little-endian (iOS devices are little-endian, so native == LE).
        var pcm = [Int16](repeating: 0, count: output.count)
        for i in 0..<output.count {
            pcm[i] = Int16(max(-1.0, min(1.0, output[i])) * Float(Int16.max))
        }
        return pcm.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
