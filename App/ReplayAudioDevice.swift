import Foundation
import WebRTC
import AudioToolbox

/// A "virtual microphone" for WebRTC: instead of recording from the iPhone's microphone, it
/// hands WebRTC the system audio captured by the broadcast extension. WebRTC then does what
/// it does best — Opus-encodes it and sends it to the TV with proper timing, so the TV plays
/// it through its normal jitter buffer, in sync with the video (no hand-made PCM-over-WebSocket
/// pacing, which was the cause of the chirping/stalling).
final class ReplayAudioDevice: NSObject, RTCAudioDevice {
    private var delegate: RTCAudioDeviceDelegate?
    private var sampleTime: Float64 = 0
    private let lock = NSLock()

    var deviceInputSampleRate: Double { 48000 }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { 48000 }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }

    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.delegate = delegate
        isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        lock.lock(); defer { lock.unlock() }
        delegate = nil
        isInitialized = false
        isRecording = false
        isPlaying = false
        return true
    }

    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func startPlayout() -> Bool { isPlaying = true; return true }
    func stopPlayout() -> Bool { isPlaying = false; return true }
    func initializeRecording() -> Bool { isRecordingInitialized = true; return true }
    func startRecording() -> Bool { isRecording = true; return true }
    func stopRecording() -> Bool { isRecording = false; return true }

    /// Feed exactly one chunk (normally 10 ms = 480 samples) of 48 kHz mono 16-bit PCM.
    func deliver(_ pcm: Data) {
        lock.lock()
        let delegate = self.delegate
        let active = isRecording
        let time = sampleTime
        sampleTime += Float64(pcm.count / 2)
        lock.unlock()
        guard let delegate, active, pcm.count >= 2 else { return }

        var bytes = pcm
        bytes.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: UInt32(raw.count),
                                      mData: raw.baseAddress))
            var flags = AudioUnitRenderActionFlags()
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = time
            stamp.mFlags = .sampleTimeValid
            _ = delegate.deliverRecordedData(&flags, &stamp, 1, UInt32(raw.count / 2), &list, nil, nil)
        }
    }
}
