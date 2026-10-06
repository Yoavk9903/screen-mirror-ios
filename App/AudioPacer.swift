import Foundation

/// ReplayKit hands audio over in irregular bursts (and it additionally queues behind big video
/// frames on the way from the broadcast extension), but the TV plays what it receives straight
/// away, so any gap in arrival is an audible stall and short fragments sound like chirping.
/// This re-times the PCM into a steady stream: it pre-buffers ~150 ms, then releases exactly
/// 20 ms of audio every 20 ms. If the sender falls behind it waits and re-buffers; if it gets
/// too far ahead (clock drift) it drops the oldest audio.
final class AudioPacer {
    private let bytesPerMs = 96 // 48 kHz * 2 bytes * mono
    private let chunkMs = 20
    private let prebufferMs = 150
    private let maxBufferMs = 500

    private let queue = DispatchQueue(label: "com.screenmirror.sender.audio-pacer")
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var playing = false
    private let send: (Data) -> Void

    init(send: @escaping (Data) -> Void) {
        self.send = send
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(self.chunkMs), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.buffer.removeAll()
            self.playing = false
        }
    }

    func push(_ pcm: Data) {
        queue.async {
            self.buffer.append(pcm)
            let maxBytes = self.maxBufferMs * self.bytesPerMs
            if self.buffer.count > maxBytes {
                // Drop the oldest audio, keeping the prebuffer amount.
                let keep = self.prebufferMs * self.bytesPerMs
                self.buffer = Data(self.buffer.suffix(keep))
            }
        }
    }

    private func tick() {
        let chunkBytes = chunkMs * bytesPerMs
        if !playing {
            if buffer.count >= prebufferMs * bytesPerMs { playing = true } else { return }
        }
        guard buffer.count >= chunkBytes else {
            playing = false // ran dry: wait until the prebuffer has refilled
            return
        }
        let chunk = buffer.prefix(chunkBytes)
        buffer = Data(buffer.dropFirst(chunkBytes))
        send(Data(chunk))
    }
}
