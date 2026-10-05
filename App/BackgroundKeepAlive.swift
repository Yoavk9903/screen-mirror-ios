import AVFoundation

/// iOS suspends an app shortly after the user leaves it, which would close the connection
/// to the TV (and stop the WebRTC stream) as soon as the user switches to the app they want
/// to mirror. Playing silence through an audio session (with the "audio" background mode
/// enabled in project.yml) is the standard way to keep the process running in the
/// background. It mixes with other audio, so it never interrupts the user's own sound.
final class BackgroundKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let frames = AVAudioFrameCount(44100) // one second of silence, looped
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames // zero-filled = silence

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false
    }
}
