import Foundation

/// Wires the pieces together for the life of the app's mirroring screen:
///  1. FrameReceiver   — listens locally for frames forwarded from the broadcast extension
///  2. SignalingClient — talks to the TV over the WebSocket (offer/answer/ice)
///  3. WebRTCSender    — encodes those frames and actually streams them to the TV
///
/// The TV is only contacted while a broadcast is actually running: pressing Start Broadcast
/// (extension connects) opens the connection, and Stop Broadcast / screen lock / the extension
/// dying (extension disconnects) closes it again, so the TV goes back to its waiting screen.
final class MirrorSession: ObservableObject {
    @Published private(set) var isConnected = false
    /// Short diagnostics line for TestFlight builds.
    @Published private(set) var stats = ""

    private let frameReceiver = FrameReceiver()
    private let keepAlive = BackgroundKeepAlive()
    private let lifecycle = DispatchQueue(label: "com.screenmirror.sender.session")
    private let lock = NSLock()

    private var tv: DiscoveredTv?
    private var signaling: SignalingClient?
    private var sender: WebRTCSender?
    private var started = false
    private var statsTimer: Timer?
    private var lastAudioBytes = 0

    init() {
        frameReceiver.onBroadcastStarted = { [weak self] in
            self?.lifecycle.async { self?.beginSession() }
        }
        frameReceiver.onBroadcastEnded = { [weak self] in
            self?.lifecycle.async { self?.endSession() }
        }
        frameReceiver.onVideoFrame = { [weak self] frame in
            self?.currentSender()?.push(videoFrame: frame)
        }
        frameReceiver.onAudioFrame = { [weak self] pcm in
            self?.currentSender()?.push(audioFrame: pcm)
        }
    }

    /// The user picked a TV. Nothing is sent to it until a broadcast starts.
    func connect(to tv: DiscoveredTv) {
        lifecycle.async {
            let changed = self.tv?.id != tv.id
            self.tv = tv
            if changed, self.sender != nil {
                self.endSession()
                self.beginSession()
            }
        }
        DispatchQueue.main.async { self.startIfNeeded() }
    }

    func disconnect() {
        lifecycle.async { self.endSession() }
        frameReceiver.stop()
        keepAlive.stop()
        statsTimer?.invalidate()
        statsTimer = nil
        started = false
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        keepAlive.start() // keep running after the user leaves the app to start mirroring
        frameReceiver.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let r = self.frameReceiver
            let kbPerSecond = (r.audioByteCount - self.lastAudioBytes) / 1024
            self.lastAudioBytes = r.audioByteCount
            self.stats = r.videoFrameCount == 0 && r.audioFrameCount == 0
                ? ""
                : "video \(r.videoFrameCount) (\(r.lastFrameSize))\naudio \(r.audioFrameCount) (\(kbPerSecond) KB/s)\n\(r.lastInfo)"
        }
    }

    private func currentSender() -> WebRTCSender? {
        lock.lock(); defer { lock.unlock() }
        return sender
    }

    // Both run on `lifecycle`.
    private func beginSession() {
        guard let tv, sender == nil else { return }
        let signaling = SignalingClient()
        let newSender = WebRTCSender(signaling: signaling)
        signaling.onConnected = { [weak newSender, weak self] in
            DispatchQueue.main.async { self?.isConnected = true }
            newSender?.start()
        }
        signaling.onDisconnected = { [weak self] in
            DispatchQueue.main.async { self?.isConnected = false }
        }
        self.signaling = signaling
        lock.lock(); sender = newSender; lock.unlock()
        signaling.connect(host: tv.host, port: tv.port)
    }

    private func endSession() {
        lock.lock()
        let oldSender = sender
        sender = nil
        lock.unlock()
        oldSender?.stop()
        signaling?.disconnect() // sends "bye" so the TV returns to its waiting screen
        signaling = nil
        DispatchQueue.main.async { self.isConnected = false }
    }
}
