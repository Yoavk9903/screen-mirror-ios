import Foundation

/// ReplayKit hands audio over in irregular bursts, but WebRTC wants a steady stream of 10 ms
/// pieces. This re-times the PCM: every 10 ms exactly one 10 ms piece goes out. If there is no
/// audio available at that moment, silence goes out instead, so the stream's clock never stops
/// (a stalled clock is what the listener hears as stutter). If the source gets too far ahead
/// (clock drift) the oldest audio is dropped to keep the delay low.
final class AudioPacer {
    private let bytesPerMs = 96 // 48 kHz * 2 bytes * mono
    private let chunkMs = 10
    private let maxBufferMs = 120
    private let trimToMs = 40

    private let queue = DispatchQueue(label: "com.screenmirror.sender.audio-pacer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var started = false
    private let deliver: (Data) -> Void

    private(set) var underruns = 0
    private(set) var drops = 0

    init(deliver: @escaping (Data) -> Void) {
        self.deliver = deliver
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(self.chunkMs), leeway: .microseconds(500))
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
            self.started = false
        }
    }

    func push(_ pcm: Data) {
        queue.async {
            self.buffer.append(pcm)
            if self.buffer.count > self.maxBufferMs * self.bytesPerMs {
                self.buffer = Data(self.buffer.suffix(self.trimToMs * self.bytesPerMs))
                self.drops += 1
            }
        }
    }

    private func tick() {
        let chunkBytes = chunkMs * bytesPerMs
        if buffer.count >= chunkBytes {
            started = true
            let chunk = Data(buffer.prefix(chunkBytes))
            buffer = Data(buffer.dropFirst(chunkBytes))
            deliver(chunk)
        } else {
            if started { underruns += 1 }
            deliver(Data(count: chunkBytes))
        }
    }
}
