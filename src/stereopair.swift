// Two Macs as one stereo pair, without snapcast.
//
//   stereopair --send [host]  [--peer-name <name>]   (finds the receiver if omitted)
//   stereopair --list [--target-ms 20] [--io-frames 128]
//   stereopair --recv          [--port 4711] [--target-ms 20] [--io-frames 128]
//
// The sender taps system audio, plays the left channel through its own output
// and ships the right channel to the receiver. Both sides hold the same target
// buffer before playing, so they stay aligned: the network adds well under a
// millisecond over a Thunderbolt link, which is nothing next to the target.
//
// Clock drift is corrected by resampling. The two machines' audio crystals
// differ — measured at 8.3 ppm here — so a receiver playing back at exactly its
// own rate walks its buffer to empty and glitches every 40 minutes or so.
// Playback runs at a ratio a few ppm off 1.0, adjusted by a slow loop on the
// buffer level, which holds latency at the target indefinitely.

import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Network
import Synchronization

let sampleRate = 48000

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("stereopair: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("stereopair: \(message)\n".utf8))
}

// MARK: - Core Audio plumbing

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() -> AudioObjectID {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    return device
}

func deviceUID(_ device: AudioObjectID) -> String {
    var out: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    var addr = address(kAudioDevicePropertyDeviceUID)
    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &out)
    return (out as String?) ?? ""
}

/// snapclient's ~100 ms output queue was the largest single term in the old
/// design's latency, and it was a software choice: the hardware goes to 15.
func setIOBufferFrames(_ device: AudioObjectID, _ frames: UInt32) -> UInt32 {
    var value = frames
    var addr = address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput)
    AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    var actual: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &actual)
    return actual
}

func processObject(for pid: pid_t) -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var input = pid
    var out = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                               UInt32(MemoryLayout<pid_t>.size), &input, &size, &out)
    return out
}

// MARK: - System volume

/// Read and write the output slider directly. Both machines run the same OS on
/// the same hardware, so the same scalar is the same loudness and no mapping
/// between volume curves is needed.
func systemVolume() -> Float? {
    let device = defaultOutputDevice()
    guard device != kAudioObjectUnknown else { return nil }
    for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { continue }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
            return value
        }
    }
    return nil
}

func setSystemVolume(_ level: Float) {
    let device = defaultOutputDevice()
    guard device != kAudioObjectUnknown else { return }
    var value = Float32(max(0, min(1, level)))
    for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { continue }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue
        else { continue }
        AudioObjectSetPropertyData(device, &addr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &value)
    }
}

// MARK: - Ring buffer

/// Four times the deepest buffer the adaptive delay can ask for. At 1 << 16 it
/// was 1365 ms against a worst case of 1300 — the ring sat pinned at capacity,
/// dropping every sample that would not fit, and the shortfall that caused
/// looked to the adaptive logic like a failing link, so it asked for yet more
/// delay. Headroom is what stops that from feeding itself.
let ringFrames = 1 << 18

final class Ring: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    let underruns = Atomic<Int>(0)
    let trimmed = Atomic<Int>(0)
    /// Audio that would not fit. Silently discarding it is how a saturated ring
    /// looks exactly like a healthy one from the outside.
    let dropped = Atomic<Int>(0)

    init(frames: Int) {
        capacity = frames
        mask = frames - 1
        storage = .allocate(capacity: frames)
        storage.initialize(repeating: 0, count: frames)
    }

    var fill: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }

    func write(_ source: UnsafePointer<Int16>, _ count: Int) {
        let h = head.load(ordering: .relaxed)
        let room = capacity - (h - tail.load(ordering: .acquiring))
        let n = min(count, room)
        if n < count { dropped.add(count - n, ordering: .relaxed) }
        for i in 0 ..< n { storage[(h + i) & mask] = source[i] }
        head.store(h + n, ordering: .releasing)
    }

    /// Without pulling the level back, any startup burst or accumulated drift
    /// becomes permanent latency.
    var tailPosition: Int { tail.load(ordering: .acquiring) }
    var headPosition: Int { head.load(ordering: .acquiring) }

    /// Jump straight to a position, clamped to what we actually hold.
    func seek(to position: Int) {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        let clamped = max(t, min(position, h))
        if clamped > t { trimmed.add(clamped - t, ordering: .relaxed) }
        tail.store(clamped, ordering: .releasing)
    }

    func clear() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
        underruns.store(0, ordering: .releasing)
        trimmed.store(0, ordering: .releasing)
    }

    func trim(to frames: Int) {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        guard h - t > frames else { return }
        trimmed.add((h - t) - frames, ordering: .relaxed)
        tail.store(h - frames, ordering: .releasing)
    }

    /// Reads `count` output samples while consuming `count * ratio` input
    /// samples, interpolating between neighbours. Holding the ratio a few ppm
    /// off 1.0 is what lets a receiver track a sender whose audio clock runs at
    /// a slightly different rate; without it the buffer walks to empty and
    /// glitches, measured here at 8.3 ppm, about once every 40 minutes.
    func readResampled(_ destination: UnsafeMutablePointer<Int16>, _ count: Int,
                       ratio: Double, phase: inout Double) -> Bool
    {
        let t = tail.load(ordering: .relaxed)
        let available = head.load(ordering: .acquiring) - t
        // One extra for the interpolation's right-hand neighbour.
        let needed = Int(phase + ratio * Double(count)) + 2
        guard available >= needed else {
            underruns.add(count, ordering: .relaxed)
            return false
        }

        var cursor = phase
        for i in 0 ..< count {
            let index = Int(cursor)
            let fraction = cursor - Double(index)
            let a = Double(storage[(t + index) & mask])
            let b = Double(storage[(t + index + 1) & mask])
            destination[i] = Int16((a + (b - a) * fraction).rounded())
            cursor += ratio
        }

        let consumed = Int(cursor)
        tail.store(t + consumed, ordering: .releasing)
        phase = cursor - Double(consumed)
        return true
    }

    func read(_ destination: UnsafeMutablePointer<Int16>, _ count: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let n = min(count, head.load(ordering: .acquiring) - t)
        for i in 0 ..< n { destination[i] = storage[(t + i) & mask] }
        tail.store(t + n, ordering: .releasing)
        if n < count { underruns.add(count - n, ordering: .relaxed) }
        return n
    }
}

/// Atomic is non-copyable, so a realtime callback cannot capture one directly.
final class AtomicUInt64: @unchecked Sendable {
    private let storage = Atomic<UInt64>(0)
    init(_ value: UInt64) { storage.store(value, ordering: .releasing) }
    var value: UInt64 {
        get { storage.load(ordering: .acquiring) }
        set { storage.store(newValue, ordering: .releasing) }
    }
}

final class AtomicBool: @unchecked Sendable {
    private let storage = Atomic<Bool>(false)
    init(_ value: Bool) { storage.store(value, ordering: .releasing) }
    var value: Bool {
        get { storage.load(ordering: .acquiring) }
        set { storage.store(newValue, ordering: .releasing) }
    }
}

final class AtomicInt: @unchecked Sendable {
    private let storage = Atomic<Int>(0)
    init(_ value: Int) { storage.store(value, ordering: .releasing) }
    var value: Int {
        get { storage.load(ordering: .acquiring) }
        set { storage.store(newValue, ordering: .releasing) }
    }
}

// MARK: - Playback

/// Plays a mono ring through the default output, on every channel of the
/// device. Holds silence until the ring first reaches `targetFrames`, so the
/// two machines start from the same depth rather than whatever the first
/// callback happened to find.
/// Where a given ring position is meant to be heard, in the sender's clock.
/// Everything else is derived from this: playback follows the schedule, not the
/// arrival of packets, which is what keeps the two machines together when the
/// network delivers in bursts.
final class Schedule: @unchecked Sendable {
    private let lock = NSLock()
    private var position = 0
    private var playTime: UInt64 = 0
    private(set) var valid = false

    func set(position newPosition: Int, playTime newPlayTime: UInt64) {
        lock.lock()
        position = newPosition
        playTime = newPlayTime
        valid = true
        lock.unlock()
    }

    /// The position that should be playing at `time` (sender clock).
    func position(at time: UInt64) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { return nil }
        let delta = Int64(bitPattern: time) - Int64(bitPattern: playTime)
        return position + Int(delta * Int64(sampleRate) / 1_000_000_000)
    }
}

final class Player {
    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    let ring = Ring(frames: ringFrames)
    let schedule = Schedule()
    /// Sender clock minus ours. Zero when the sender is this machine.
    let clockOffset = AtomicInt(0)
    /// How far playback is from where the schedule says it should be. This, not
    /// the buffer level, is what tells you whether the two Macs agree.
    let timingErrorMicros = AtomicInt(0)
    /// Extra delay the receiver has taken on to stay ahead of a bursty link.
    /// Grows quickly when audio starts arriving late, shrinks slowly when it
    /// stops, so a single bad minute does not cost latency for the rest of the
    /// session and a worsening link does not cost dropouts.
    let extraDelayMicros = AtomicInt(0)
    /// The sender picks this once it knows which link it got, so the receiver
    /// has to be able to change it after the fact.
    let target = AtomicInt(0)
    private let primedFlag = AtomicBool(false)

    func setTarget(ms: Int) {
        target.value = ms * sampleRate / 1000
    }

    init(targetFrames: Int, ioFrames: UInt32) {
        target.value = targetFrames
        device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { die("no default output device") }
        let actual = setIOBufferFrames(device, ioFrames)
        log("output \(deviceUID(device)), io buffer \(actual) frames (\(String(format: "%.2f", Double(actual) / 48.0)) ms)")

        let ring = self.ring
        let target = self.target
        let primed = primedFlag
        // Playback rate, nudged towards whatever keeps the buffer at target.
        // Bounded well under a tenth of a percent, far below audible pitch
        // change, and the loop is deliberately slow so it tracks clock drift
        // rather than chasing normal jitter.
        nonisolated(unsafe) var ratio = 1.0
        nonisolated(unsafe) var phase = 0.0

        let schedule = self.schedule
        let offsetBox = self.clockOffset
        let errorBox = self.timingErrorMicros
        let extraBox = self.extraDelayMicros
        let lastSeek = AtomicUInt64(0)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, outputData, outputTime in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let first = buffers.first else { return }
            let frames = Int(first.mDataByteSize)
                / (MemoryLayout<Float>.size * max(Int(first.mNumberChannels), 1))

            let targetFrames = target.value

            // When this buffer will actually reach the speakers, expressed in
            // the sender's clock. Core Audio hands us that time; using it is
            // what makes playback independent of when packets turned up.
            let hostNanos = hostToNanos(outputTime.pointee.mHostTime)
            let senderNow = UInt64(bitPattern: Int64(bitPattern: hostNanos)
                + Int64(offsetBox.value) - Int64(extraBox.value) * 1_000)

            if !primed.value {
                if ring.fill >= targetFrames {
                    primed.value = true
                    // Start where the schedule says, not wherever the buffer
                    // happened to fill to. Otherwise playback begins tens of
                    // milliseconds out and spends a minute and a half slewing
                    // back at 0.08% — audible the whole way as the channels
                    // slowly converging.
                    if let wanted = schedule.position(at: senderNow) {
                        ring.seek(to: wanted)
                    }
                }
                for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
                return
            }

            var timingError = 0.0
            if let wanted = schedule.position(at: senderNow) {
                let drift = wanted - ring.tailPosition
                timingError = Double(drift) / Double(sampleRate)
                // A big gap means something jumped — a reconnect, a stall, a
                // machine waking. Step to the right place rather than crawling
                // there at 0.08%, which would take minutes and sound wrong the
                // whole way.
                // Only for real discontinuities — a reconnect, a stall, a
                // machine waking. Anything smaller is left to the rate loop,
                // because a step is audible and a slew is not. The cooldown
                // stops a wrong estimate turning into a stream of skips.
                // Ahead of schedule — which is what taking on extra delay looks
                // like from in here. Hold by playing silence rather than
                // skipping, and the schedule catches up on its own.
                if drift < -frames {
                    for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
                    return
                }
                let now = nowNanos()
                if drift > sampleRate / 10, now &- lastSeek.value > 2_000_000_000 {
                    ring.seek(to: wanted)
                    lastSeek.value = now
                    timingError = 0
                }
            }

            // Small errors are corrected by playing fractionally faster or
            // slower, which is inaudible, rather than by skipping samples.
            errorBox.value = Int(timingError * 1_000_000)
            let correction = max(-0.0008, min(0.0008, timingError * 0.02))
            ratio += (1.0 + correction - ratio) * 0.05

            let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
            defer { scratch.deallocate() }
            if !ring.readResampled(scratch, frames, ratio: ratio, phase: &phase) {
                scratch.update(repeating: 0, count: frames)
            }

            for buffer in buffers {
                guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                for frame in 0 ..< frames {
                    let value = Float(scratch[frame]) / 32767
                    for channel in 0 ..< channels {
                        base[frame * channels + channel] = value
                    }
                }
            }
        }
        guard status == noErr else { die("output IOProc: \(status)") }
        AudioDeviceStart(device, procID)
    }

    /// The receiver is a login item, so it outlives every sender session and
    /// keeps pulling from an empty ring in between. Without clearing that, the
    /// counters report the idle time as underruns and hide the real ones.
    func reset() {
        ring.clear()
        primedFlag.value = false
        // Extra delay belongs to a link, not to a machine. Carrying it into the
        // next session puts the receiver behind by whatever the last one needed
        // — the sender starts every session at zero, and only learns otherwise
        // when the receiver announces a *change*. Both sides clear here, so a
        // fresh session begins agreed and re-earns any delay it needs.
        extraDelayMicros.value = 0
    }

    func stop() {
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }
    }
}

nonisolated(unsafe) var tapLayoutReports = 0

// MARK: - Tap

/// A Schroeder reverb in the Freeverb arrangement: eight comb filters in
/// parallel feeding four allpasses in series, per channel, with the right
/// channel's delays offset so the two sides decorrelate. Room size is purely
/// how much each comb feeds back, so both rooms share one set of buffers and
/// switching between them allocates nothing.
///
/// Buffers are raw pointers allocated once. Nothing here may allocate, lock or
/// retain: it runs inside the tap's IOProc, where a missed deadline is a click.
final class Reverb: @unchecked Sendable {
    private struct Comb {
        var buffer: UnsafeMutablePointer<Float>
        var size: Int
        var index = 0
        var store: Float = 0

        @inline(__always) mutating func process(_ input: Float, _ feedback: Float,
                                                _ damp: Float) -> Float
        {
            let output = buffer[index]
            store = output * (1 - damp) + store * damp
            buffer[index] = input + store * feedback
            index += 1
            if index >= size { index = 0 }
            return output
        }
    }

    private struct Allpass {
        var buffer: UnsafeMutablePointer<Float>
        var size: Int
        var index = 0

        @inline(__always) mutating func process(_ input: Float) -> Float {
            let held = buffer[index]
            buffer[index] = input + held * 0.5
            index += 1
            if index >= size { index = 0 }
            return -input + held
        }
    }

    // Freeverb's tunings, at its original 44.1 kHz. Scaled on the way in.
    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let spread = 23

    private var combs: [Comb] = []
    private var allpasses: [Allpass] = []

    private let sizeBits = AtomicInt(0)
    private let dampBits = AtomicInt(0)
    private let mixBits = AtomicInt(0)

    private var feedback: Float = 0
    private var damp: Float = 0
    private var wet: Float = 0
    private var dry: Float = 1

    init() {
        let scale = Double(sampleRate) / 44100
        for offset in [0, Reverb.spread] {
            for tuning in Reverb.combTunings {
                let size = Int(Double(tuning) * scale) + offset
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: size)
                buffer.initialize(repeating: 0, count: size)
                combs.append(Comb(buffer: buffer, size: size))
            }
            for tuning in Reverb.allpassTunings {
                let size = Int(Double(tuning) * scale) + offset
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: size)
                buffer.initialize(repeating: 0, count: size)
                allpasses.append(Allpass(buffer: buffer, size: size))
            }
        }
    }

    /// `size` and `damp` run 0…1; `mix` is how much of the result is heard.
    func set(size: Float, damp: Float, mix: Float) {
        sizeBits.value = Int(size.bitPattern)
        dampBits.value = Int(damp.bitPattern)
        mixBits.value = Int(mix.bitPattern)
    }

    /// Read the settings once per buffer rather than per sample, so a change
    /// landing mid-buffer cannot take effect halfway through one.
    func beginBuffer() {
        let size = Float(bitPattern: UInt32(sizeBits.value))
        feedback = size * 0.28 + 0.7
        damp = Float(bitPattern: UInt32(dampBits.value)) * 0.4
        let mix = Float(bitPattern: UInt32(mixBits.value))
        // Crossfade rather than add. The tail of a reverb can reach the level
        // of what fed it, so mixing it on top of an untouched dry signal is how
        // an effect ends up louder than the music.
        wet = mix * wetScale
        dry = 1 - mix
    }

    private let wetScale: Float = 1.0

    /// Reverb adds energy — that is what it is for — so unlike width and
    /// rotation it cannot promise never to raise the level. What it can promise
    /// is a hard bound. A comb filter resonates, and a note sustained on one of
    /// those resonances measured 7× the input before this: 17 dB, arriving
    /// gradually, which is exactly the shape of thing that hurts.
    ///
    /// Everything below the threshold passes untouched, so ordinary material is
    /// unaffected; above it the excess is bent smoothly into the last fifth,
    /// and the output cannot reach full scale however hard it is driven.
    @inline(__always) private func soften(_ x: Float) -> Float {
        let threshold: Float = 0.8
        let magnitude = abs(x)
        guard magnitude > threshold else { return x }
        let bent = threshold + (1 - threshold) * tanh((magnitude - threshold) / (1 - threshold))
        return x < 0 ? -bent : bent
    }

    @inline(__always) func process(_ a: inout Float, _ b: inout Float) {
        let input = (a + b) * 0.015
        var left: Float = 0
        var right: Float = 0
        for i in 0 ..< 8 { left += combs[i].process(input, feedback, damp) }
        for i in 8 ..< 16 { right += combs[i].process(input, feedback, damp) }
        for i in 0 ..< 4 { left = allpasses[i].process(left) }
        for i in 4 ..< 8 { right = allpasses[i].process(right) }
        a = soften(a * dry + left * wet)
        b = soften(b * dry + right * wet)
    }

    func clear() {
        for comb in combs { comb.buffer.update(repeating: 0, count: comb.size) }
        for allpass in allpasses { allpass.buffer.update(repeating: 0, count: allpass.size) }
    }
}

/// Off, a small room, and a hall. Nothing between: a reverb control with a
/// continuous size dial invites fiddling and this is a menu, not a plugin.
enum Room: Int {
    case off = 0, room = 1, hall = 2

    var size: Float { self == .hall ? 0.9 : 0.5 }
    var damp: Float { self == .hall ? 0.3 : 0.6 }
    /// Deliberately restrained. On two laptop speakers a wet mix reads as
    /// "broken" long before it reads as "concert".
    var mix: Float { self == .hall ? 0.28 : 0.16 }
    var name: String { self == .hall ? "Concert Hall" : self == .room ? "Room" : "Off" }
}

// MARK: - Effects

/// Effects run on the sender, before the channels are split, so both machines
/// receive material that has already been treated. Applying anything to one
/// side alone would be a channel offset by another name — the exact failure
/// this project spent days chasing.
///
/// No effect here may raise the output level. Both width and rotation have
/// gains bounded at unity for that reason: widening and reverb-like processing
/// both raise perceived loudness, and quiet listening is the point.
struct EffectPass {
    let midGain: Float
    let sideGain: Float
    let rotate: Bool
    let step: Double
    var phase: Double

    /// How far rotation is allowed to close one side down. Full travel silences
    /// a whole laptop once a cycle, which reads as a fault rather than an
    /// effect; a tenth left open keeps it obviously alive.
    private let depth: Float = 0.9

    @inline(__always) mutating func apply(_ a: inout Float, _ b: inout Float) {
        if midGain != 1 || sideGain != 1 {
            let mid = (a + b) * 0.5 * midGain
            let side = (a - b) * 0.5 * sideGain
            a = mid + side
            b = mid - side
        }
        if rotate {
            phase += step
            if phase > 2 * .pi { phase -= 2 * .pi }
            let c = Float(cos(phase))
            a *= 1 - depth * (1 - c) * 0.5
            b *= 1 - depth * (1 + c) * 0.5
        }
    }
}

final class Effects: @unchecked Sendable {
    /// Width as a percentage: 100 is untouched, below narrows towards mono,
    /// above pushes the sides out.
    private let widthPercent = AtomicInt(100)
    private let rotating = AtomicBool(false)
    private let room = AtomicInt(Room.off.rawValue)
    private let reverb = Reverb()
    /// Only the tap's IOProc touches this, and there is exactly one of those.
    private var phase: Double = 0

    /// A file rather than a signal: the two usable ones already mean start and
    /// stop, and a file survives the sender being restarted between sessions.
    static var path: String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StereoPair")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("effects").path
    }

    static func write(widthPercent: Int, rotate: Bool, room: Room) {
        try? "width=\(widthPercent)\nrotate=\(rotate ? 1 : 0)\nroom=\(room.rawValue)\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func read() -> (widthPercent: Int, rotate: Bool, room: Room) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (100, false, .off)
        }
        var width = 100
        var rotate = false
        var room = Room.off
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "width": width = Int(parts[1]) ?? 100
            case "rotate": rotate = parts[1] == "1"
            case "room": room = Room(rawValue: Int(parts[1]) ?? 0) ?? .off
            default: break
            }
        }
        return (width, rotate, room)
    }

    /// Polled rather than watched: a quarter of a second is imperceptible for a
    /// menu toggle, and it costs one stat() per tick.
    func startWatching() {
        Thread {
            var last = ""
            while true {
                let current = (try? String(contentsOfFile: Effects.path, encoding: .utf8)) ?? ""
                if current != last {
                    last = current
                    let settings = Effects.read()
                    self.widthPercent.value = max(0, min(200, settings.widthPercent))
                    self.rotating.value = settings.rotate
                    // Clear before switching on, or the previous room's tail
                    // decays into the new one.
                    if self.room.value != settings.room.rawValue { self.reverb.clear() }
                    self.room.value = settings.room.rawValue
                    self.reverb.set(size: settings.room.size,
                                    damp: settings.room.damp,
                                    mix: settings.room == .off ? 0 : settings.room.mix)
                    log("effects: width \(settings.widthPercent)%"
                        + (settings.rotate ? ", rotating" : "")
                        + (settings.room == .off ? "" : ", \(settings.room.name.lowercased())"))
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }.start()
    }

    var isIdle: Bool {
        widthPercent.value == 100 && !rotating.value && room.value == Room.off.rawValue
    }

    /// nil when the reverb is off, so the hot loop pays nothing for it.
    var activeReverb: Reverb? {
        guard room.value != Room.off.rawValue else { return nil }
        reverb.beginBuffer()
        return reverb
    }

    func begin() -> EffectPass {
        // Widen by cutting the middle, never by boosting the sides. Since
        // |mid| + |side| is exactly the larger input sample, attenuating either
        // one guarantees the output cannot exceed what came in — whereas
        // boosting the sides and normalising afterwards lets out-of-phase
        // material through 23% louder, which a level test caught.
        let width = Float(widthPercent.value) / 100
        return EffectPass(midGain: width > 1 ? 1 / width : 1,
                          sideGain: width < 1 ? width : 1,
                          rotate: rotating.value,
                          step: 2 * .pi / (rotationSeconds * Double(sampleRate)),
                          phase: phase)
    }

    func end(_ pass: EffectPass) { phase = pass.phase }
}

/// One turn every twelve seconds. Faster reads as a tremolo, slower stops
/// registering as movement at all.
let rotationSeconds = 12.0

/// Taps everything except this process. Excluding ourselves matters twice: our
/// own left-channel playback would otherwise be captured straight back into the
/// stream, and `mutedWhenTapped` would silence it at the speakers.
final class Tap {
    let effects: Effects
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let uuid = UUID()

    init(left: Ring, right: Ring, muteBehavior: CATapMuteBehavior = .mutedWhenTapped) {
        // Held locally as well: the IOProc block below cannot reach through
        // self, which is not fully formed while init is still running.
        let effects = Effects()
        self.effects = effects

        let output = defaultOutputDevice()
        let outputUID = deviceUID(output)

        // Our output IOProc is already running, so this resolves.
        let ourselves = processObject(for: getpid())
        let excluded = ourselves == kAudioObjectUnknown ? [] : [ourselves]
        if excluded.isEmpty { log("warning: could not exclude self from the tap") }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Stereo Pair"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = muteBehavior

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            die("""
            could not create the audio tap.
              Run this as a signed .app via `open` and allow it under System
              Settings > Privacy & Security > Screen & System Audio Recording.
            """)
        }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stereo Pair Capture",
            kAudioAggregateDeviceUIDKey: "com.emre.stereopair.\(uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
            destroy()
            die("could not create the capture device")
        }
        aggregateID = device

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first, first.mDataByteSize > 0,
                  let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }

            if tapLayoutReports > 0 {
                tapLayoutReports -= 1
                var report = "tap input: \(buffers.count) buffer(s)"
                for (index, buffer) in buffers.enumerated() {
                    var peak: Float = 0
                    if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                        for i in 0 ..< Int(buffer.mDataByteSize) / 4 { peak = max(peak, abs(data[i])) }
                    }
                    report += " [\(index) ch=\(buffer.mNumberChannels) bytes=\(buffer.mDataByteSize) peak=\(peak)]"
                }
                log(report)
            }

            @inline(__always) func pcm(_ value: Float) -> Int16 {
                Int16(max(-1, min(1, value)) * 32767)
            }

            if buffers.count >= 2,
               let second = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let l = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
                let r = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
                defer { l.deallocate(); r.deallocate() }
                if effects.isIdle {
                    for i in 0 ..< frames { l[i] = pcm(base[i]); r[i] = pcm(second[i]) }
                } else {
                    var pass = effects.begin()
                    let reverb = effects.activeReverb
                    for i in 0 ..< frames {
                        var a = base[i], b = second[i]
                        pass.apply(&a, &b)
                        reverb?.process(&a, &b)
                        l[i] = pcm(a); r[i] = pcm(b)
                    }
                    effects.end(pass)
                }
                left.write(l, frames)
                right.write(r, frames)
            } else {
                let channels = Int(first.mNumberChannels)
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
                let l = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
                let r = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
                defer { l.deallocate(); r.deallocate() }
                let other = channels >= 2 ? 1 : 0
                var pass = effects.begin()
                let idle = effects.isIdle
                let reverb = idle ? nil : effects.activeReverb
                for i in 0 ..< frames {
                    var a = base[i * channels], b = base[i * channels + other]
                    if !idle {
                        pass.apply(&a, &b)
                        reverb?.process(&a, &b)
                    }
                    l[i] = pcm(a); r[i] = pcm(b)
                }
                if !idle { effects.end(pass) }
                left.write(l, frames)
                right.write(r, frames)
            }
        }
        guard status == noErr else { destroy(); die("tap IOProc: \(status)") }
    }

    /// Creating and destroying a tap per session is what wedges coreaudiod
    /// until it is killed. The tap is made once and kept; only capture starts
    /// and stops. `mutedWhenTapped` mutes apps only while the tap is being
    /// read, so a stopped tap leaves the machine's audio alone.
    func startCapture() {
        guard let procID, aggregateID != kAudioObjectUnknown else { return }
        AudioDeviceStart(aggregateID, procID)
    }

    func stopCapture() {
        guard let procID, aggregateID != kAudioObjectUnknown else { return }
        AudioDeviceStop(aggregateID, procID)
    }

    /// Taps and aggregate devices outlive the process unless destroyed. Leaked
    /// ones pile up inside coreaudiod until every AudioDeviceStart blocks
    /// forever and only `sudo killall coreaudiod` clears it.
    func destroy() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

// MARK: - Wire protocol

// One connection carries both audio and control, so volume can travel with the
// sound instead of needing a second channel or a shell on the other machine.
//   [type: UInt8][length: UInt32 big-endian][payload]
enum Frame: UInt8 {
    case audio = 0        // UInt64 play time (sender clock, ns) + Int16 mono PCM
    case volume = 1       // Float32 scalar, 0...1
    case target = 2       // UInt32 ms; the sender decides once it knows the link
    case timeRequest = 3  // UInt64 receiver clock
    case timeReply = 4    // UInt64 echo + UInt64 sender clock
    case delay = 5        // UInt32 ms of extra delay the receiver has taken on
}

/// A monotonic clock in nanoseconds, shared by everything that has to agree on
/// when a sample should be heard.
func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Core Audio reports playback times in host ticks, which are the same units as
/// the monotonic clock only after scaling by the machine's timebase.
let hostTimebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(info.denom))
}()

func hostToNanos(_ hostTime: UInt64) -> UInt64 {
    hostTime / hostTimebase.denom &* hostTimebase.numer
        &+ (hostTime % hostTimebase.denom) &* hostTimebase.numer / hostTimebase.denom
}

/// The two machines' monotonic clocks start whenever each booted, so they share
/// no epoch. Round-trip a pair of readings and take the offset from the fastest
/// exchange seen: the quickest round trip is the one least distorted by
/// queueing, which is the whole difficulty on Wi-Fi.
final class ClockSync: @unchecked Sendable {
    private let lock = NSLock()
    private var window: [(roundTrip: UInt64, offset: Int64)] = []
    private var applied: Int64 = 0
    private var started = false

    /// One exchange is enough to have *an* estimate, not enough to trust it:
    /// the whole method rests on catching a round trip that queueing missed,
    /// which needs a few tries. Nothing that depends on the offset may run
    /// before this is true.
    var settled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return window.count >= 8
    }

    var offsetNanos: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return applied
    }

    func sample(sent: UInt64, remote: UInt64, received: UInt64) {
        let roundTrip = received &- sent
        let midpoint = sent &+ roundTrip / 2
        let offset = Int64(bitPattern: remote) - Int64(bitPattern: midpoint)

        lock.lock()
        defer { lock.unlock() }

        // Judge each exchange only against recent ones. Keeping the best sample
        // ever seen would pin the estimate to one lucky packet forever, and
        // letting it decay lets a badly queued sample take over — on Wi-Fi the
        // worst round trip is 86 ms, which is tens of milliseconds of error.
        window.append((roundTrip, offset))
        if window.count > 40 { window.removeFirst() }
        guard let best = window.min(by: { $0.roundTrip < $1.roundTrip }) else { return }

        if !started {
            applied = best.offset
            started = true
            return
        }
        // Slew rather than jump: a step in the offset moves the whole schedule
        // and shows up as a skip. 200 microseconds per exchange closes a
        // realistic error within seconds and is far below audibility.
        let limit: Int64 = 200_000
        applied += max(-limit, min(limit, best.offset - applied))
    }
}

func sendFrame(_ fd: Int32, _ kind: Frame, _ bytes: UnsafeRawPointer, _ count: Int,
               _ lock: NSLock) -> Bool
{
    lock.lock()
    defer { lock.unlock() }
    var header = [UInt8](repeating: 0, count: 5)
    header[0] = kind.rawValue
    let length = UInt32(count).bigEndian
    withUnsafeBytes(of: length) { raw in
        for i in 0 ..< 4 { header[1 + i] = raw[i] }
    }
    return writeAll(fd, header, 5) && (count == 0 || writeAll(fd, bytes, count))
}

func sendUInt64s(_ fd: Int32, _ kind: Frame, _ values: [UInt64], _ lock: NSLock) -> Bool {
    var bytes = [UInt8]()
    for value in values {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }
    return sendFrame(fd, kind, bytes, bytes.count, lock)
}

func readUInt64(_ bytes: [UInt8], _ index: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0 ..< 8 { value = (value << 8) | UInt64(bytes[index * 8 + i]) }
    return value
}

func sendVolume(_ fd: Int32, _ level: Float, _ lock: NSLock) -> Bool {
    var value = Float32(level)
    return withUnsafeBytes(of: &value) { raw in
        sendFrame(fd, .volume, raw.baseAddress!, raw.count, lock)
    }
}

/// Reads frames until the connection ends, handing each to the caller.
func readFrames(_ fd: Int32, onAudio: (UInt64, UnsafePointer<Int16>, Int) -> Void,
                onVolume: (Float) -> Void,
                onTarget: (Int) -> Void = { _ in },
                onTimeRequest: (UInt64) -> Void = { _ in },
                onTimeReply: (UInt64, UInt64) -> Void = { _, _ in },
                onDelay: (Int) -> Void = { _ in })
{
    var header = [UInt8](repeating: 0, count: 5)
    var payload = [UInt8](repeating: 0, count: 1 << 16)
    while readAll(fd, &header, 5) {
        let length = (UInt32(header[1]) << 24) | (UInt32(header[2]) << 16)
            | (UInt32(header[3]) << 8) | UInt32(header[4])
        guard Int(length) <= payload.count else { return }
        guard length == 0 || readAll(fd, &payload, Int(length)) else { return }

        switch Frame(rawValue: header[0]) {
        case .audio:
            guard length >= 8 else { return }
            let playTime = readUInt64(payload, 0)
            payload.withUnsafeBytes { raw in
                let samples = raw.baseAddress!.advanced(by: 8)
                    .assumingMemoryBound(to: Int16.self)
                onAudio(playTime, samples, (Int(length) - 8) / MemoryLayout<Int16>.size)
            }
        case .volume:
            let level = payload.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
            onVolume(level)
        case .target:
            let ms = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            onTarget(Int(UInt32(bigEndian: ms)))
        case .delay:
            guard length >= 4 else { return }
            let ms = (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16)
                | (UInt32(payload[2]) << 8) | UInt32(payload[3])
            onDelay(Int(ms))
        case .timeRequest:
            guard length >= 8 else { return }
            onTimeRequest(readUInt64(payload, 0))
        case .timeReply:
            guard length >= 16 else { return }
            onTimeReply(readUInt64(payload, 0), readUInt64(payload, 1))
        case nil:
            return          // unknown frame type: the stream is no longer trustworthy
        }
    }
}

/// Mirrors the system volume in both directions over the link. Whichever Mac
/// you change wins; the other follows. The quiet period after applying a remote
/// change stops the two bouncing a value back and forth forever.
final class VolumeSync {
    private let fd: Int32
    private let lock: NSLock
    private var lastSeen: Float
    private var quietUntil = Date.distantPast
    private let running = Atomic<Bool>(true)

    init(fd: Int32, lock: NSLock) {
        self.fd = fd
        self.lock = lock
        lastSeen = systemVolume() ?? 0
    }

    func applyRemote(_ level: Float) {
        guard abs(level - (systemVolume() ?? level)) > 0.01 else { return }
        setSystemVolume(level)
        lastSeen = level
        quietUntil = Date().addingTimeInterval(1.0)
    }

    func start() {
        Thread { [self] in
            _ = sendVolume(fd, lastSeen, lock)
            while running.load(ordering: .acquiring) {
                Thread.sleep(forTimeInterval: 0.3)
                guard Date() > quietUntil, let now = systemVolume() else { continue }
                if abs(now - lastSeen) > 0.01 {
                    lastSeen = now
                    _ = sendVolume(fd, now, lock)
                }
            }
        }.start()
    }

    /// The receiver takes a new connection each time the sender restarts, so a
    /// watcher left running would keep writing to a dead socket.
    func stop() { running.store(false, ordering: .releasing) }
}

// MARK: - Discovery

let serviceType = "_stereopair._tcp."

/// The receiver publishes itself so the sender never needs a hostname, an IP or
/// ssh just to find it.
final class Advertiser: NSObject, NetServiceDelegate {
    private var service: NetService?

    func start(port: UInt16) {
        let name = Host.current().localizedName ?? "Mac"
        let thread = Thread { [self] in
            let published = NetService(domain: "local.", type: serviceType,
                                       name: name, port: Int32(port))
            published.delegate = self
            published.publish()
            service = published
            RunLoop.current.run()
        }
        thread.name = "advertise"
        thread.start()
    }

    func netServiceDidPublish(_ sender: NetService) {
        log("advertising as \"\(sender.name)\"")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        log("could not advertise: \(errorDict)")
    }
}

struct Peer {
    let name: String
    let addresses: [String]
    let port: Int
}

func ipv4(_ data: Data) -> String? {
    data.withUnsafeBytes { raw -> String? in
        guard let base = raw.baseAddress,
              raw.count >= MemoryLayout<sockaddr>.size,
              base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family == sa_family_t(AF_INET)
        else { return nil }
        var sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        return String(cString: text)
    }
}

/// NetService hands back only the address for the interface it happened to be
/// discovered on, but mDNS publishes one per interface. Resolving the advertised
/// hostname instead returns all of them, which is the only way to see the
/// Thunderbolt address when the service was found over Wi-Fi.
func addresses(ofHost host: String) -> [String] {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                         ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                         ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
    defer { freeaddrinfo(head) }

    var found: [String] = []
    var node: UnsafeMutablePointer<addrinfo>? = head
    while let current = node {
        if let raw = current.pointee.ai_addr {
            var sin = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            let address = String(cString: text)
            if address != "0.0.0.0" { found.append(address) }
        }
        node = current.pointee.ai_next
    }
    return found
}

final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    func search(timeout: TimeInterval) -> [Peer] {
        browser.delegate = self
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
        RunLoop.current.run(until: Date().addingTimeInterval(timeout))
        browser.stop()

        // Read the addresses at the end rather than in the resolve callback. A
        // Mac on both Wi-Fi and a Thunderbolt bridge has an address per
        // interface, they arrive separately, and the callback fires before they
        // are all in — which loses exactly the link worth having.
        let ours = localAddresses()
        return resolving.compactMap { service in
            var found = (service.addresses ?? []).compactMap(ipv4)
            if let host = service.hostName {
                found += addresses(ofHost: host)
            }
            found = Array(Set(found))
            guard !found.isEmpty, found.allSatisfy({ !ours.contains($0) }) else { return nil }
            return Peer(name: service.name, addresses: found, port: service.port)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool)
    {
        service.delegate = self
        resolving.append(service)      // must outlive the resolve
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {}
}

/// A direct Thunderbolt link self-assigns 169.254.x addresses because there is
/// no DHCP on it, and that link is the one worth having: two orders of
/// magnitude less jitter than Wi-Fi. So try those first and fall back.
func preferredOrder(_ addresses: [String]) -> [String] {
    addresses.sorted { a, b in
        a.hasPrefix("169.254.") && !b.hasPrefix("169.254.")
    }
}

/// Every address this Mac has, used to keep ourselves out of the peer list:
/// we advertise too, so a browse always finds this machine as well.
func localAddresses() -> Set<String> {
    var found: Set<String> = ["127.0.0.1"]
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let head = list else { return found }
    defer { freeifaddrs(head) }

    var node: UnsafeMutablePointer<ifaddrs>? = head
    while let current = node {
        defer { node = current.pointee.ifa_next }
        guard let raw = current.pointee.ifa_addr,
              raw.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var sin = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        found.insert(String(cString: text))
    }
    return found
}

/// Our own address on the Thunderbolt bridge, if the cable is attached.
func bridgeAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let head = list else { return nil }
    defer { freeifaddrs(head) }

    var node: UnsafeMutablePointer<ifaddrs>? = head
    while let current = node {
        defer { node = current.pointee.ifa_next }
        guard String(cString: current.pointee.ifa_name).hasPrefix("bridge"),
              let raw = current.pointee.ifa_addr,
              raw.pointee.sa_family == sa_family_t(AF_INET)
        else { continue }
        var sin = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        return String(cString: text)
    }
    return nil
}

/// Which of our addresses a connected socket is actually using. Two link-local
/// addresses can both accept a connection while only one of them is the cable,
/// and this is the only way to tell them apart from the outside.
func localAddress(of fd: Int32) -> String? {
    var addr = sockaddr_in()
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    guard ok == 0 else { return nil }
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
    return String(cString: text)
}

/// A browser that keeps running, rather than a snapshot taken when the menu
/// opens. Resolving a service takes longer than a menu click is willing to
/// wait, and a short window returns peers with no addresses yet — which look
/// like no peers at all.
final class LiveDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var cached: [Peer] = []
    private let lock = NSLock()

    var peers: [Peer] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func start() {
        let thread = Thread { [self] in
            browser.delegate = self
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
            RunLoop.current.run()
        }
        thread.name = "discovery"
        thread.start()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool)
    {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService,
                           moreComing: Bool)
    {
        services.removeAll { $0.name == service.name }
        rebuild()
    }

    func netServiceDidResolveAddress(_ sender: NetService) { rebuild() }

    private func rebuild() {
        let ours = localAddresses()
        var list: [Peer] = []
        for service in services {
            var found = (service.addresses ?? []).compactMap(ipv4)
            if let host = service.hostName { found += addresses(ofHost: host) }
            found = Array(Set(found))
            // Every copy advertises, so a browse always finds this Mac too.
            guard !found.isEmpty, found.allSatisfy({ !ours.contains($0) }) else { continue }
            list.append(Peer(name: service.name, addresses: found, port: service.port))
        }
        lock.lock()
        cached = list
        lock.unlock()
    }
}

// MARK: - Sockets

func readAll(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ bytes: Int) -> Bool {
    var offset = 0
    while offset < bytes {
        let n = recv(fd, buffer.advanced(by: offset), bytes - offset, 0)
        if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
    }
    return true
}

func writeAll(_ fd: Int32, _ buffer: UnsafeRawPointer, _ bytes: Int) -> Bool {
    var offset = 0
    while offset < bytes {
        let n = send(fd, buffer.advanced(by: offset), bytes - offset, 0)
        if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
    }
    return true
}

func disableNagle(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
}

// MARK: - Teardown

nonisolated(unsafe) var liveTap: Tap?
nonisolated(unsafe) var livePlayer: Player?

func teardown() {
    liveTap?.destroy()
    liveTap = nil
    livePlayer?.stop()
    livePlayer = nil
}

func installTeardownHandlers() {
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { teardown(); exit(0) }
        source.resume()
        _ = Unmanaged.passRetained(source as AnyObject)
    }
    atexit { teardown() }
}

func startStatsThread(_ label: String, _ player: Player) {
    let ring = player.ring
    Thread {
        while true {
            Thread.sleep(forTimeInterval: 10)
            let extra = player.extraDelayMicros.value / 1000
            let dropped = ring.dropped.load(ordering: .relaxed)
            var line = "\(label) buffer \(ring.fill * 1000 / sampleRate) ms"
            line += ", offset \(player.timingErrorMicros.value / 1000) ms"
            if extra > 0 { line += ", extra \(extra) ms" }
            line += ", underruns \(ring.underruns.load(ordering: .relaxed))"
            if dropped > 0 { line += ", dropped \(dropped)" }
            line += ", trimmed \(ring.trimmed.load(ordering: .relaxed))"
            log(line)
        }
    }.start()
}

/// Watches how much time each chunk has left before it is due, and buys more
/// delay when that margin runs out. Growing is prompt because the alternative
/// is a dropout; shrinking is slow because reclaiming latency is worth nothing
/// if it costs a dropout to find out the link is still bad.
final class Margin: @unchecked Sendable {
    private let lock = NSLock()
    private var worst = Int64.max
    private var lastGrow = nowNanos()
    private var lastShrink = nowNanos()

    /// Never let audio arrive with less than this to spare.
    private let floorNanos: Int64 = 40_000_000
    /// Only give delay back when there is this much slack to lose.
    private let comfortableNanos: Int64 = 200_000_000
    /// Bounded by the ring, not chosen freely: a delay the buffer cannot hold
    /// is not a delay, it is dropped audio wearing one.
    private let ceilingMicros = min(1_000_000, ringFrames * 1_000_000 / sampleRate / 4)
    private let maxGrowthMicros = 150_000

    /// Extra delay has to be applied on both machines or it becomes a channel
    /// offset: the receiver would hold back while the sender kept playing, and
    /// the very sync this exists to protect would be broken by protecting it.
    func observe(marginNanos: Int64, player: Player, announce: (Int) -> Void) {
        lock.lock()
        worst = min(worst, marginNanos)
        let now = nowNanos()

        if worst < floorNanos, now &- lastGrow > 1_000_000_000 {
            let shortfall = floorNanos - worst
            // Step, don't leap. A single wrong reading that asks for a second
            // of delay gets it if it keeps asking, but not on the strength of
            // one sample — and latency is far cheaper to add than to give back.
            let step = min(Int(shortfall / 1_000) + 20_000, maxGrowthMicros)
            player.extraDelayMicros.value = min(player.extraDelayMicros.value + step,
                                                ceilingMicros)
            lastGrow = now
            lastShrink = now
            worst = .max
            let ms = player.extraDelayMicros.value / 1000
            lock.unlock()
            announce(ms)
            log("link got worse; holding \(ms) ms extra")
            return
        }

        if worst > comfortableNanos, player.extraDelayMicros.value > 0,
           now &- lastShrink > 20_000_000_000
        {
            player.extraDelayMicros.value = max(0, player.extraDelayMicros.value - 10_000)
            lastShrink = now
            worst = .max
            let ms = player.extraDelayMicros.value / 1000
            lock.unlock()
            announce(ms)
            lock.lock()
        }

        // Forget slowly, so one quiet stretch cannot mask a link that is bad
        // most of the time.
        if now &- lastGrow > 10_000_000_000, now &- lastShrink > 10_000_000_000 {
            worst = .max
            lastShrink = now
        }
        lock.unlock()
    }
}

// MARK: - Modes

func connectTo(_ host: String, _ port: UInt16) -> Int32? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connected == 0 { return fd }
    log("  \(host): \(String(cString: strerror(errno)))")
    close(fd)
    return nil
}

/// Set by SIGUSR2 (play) and SIGUSR1 (stop). The process stays alive across
/// both so the tap it owns is created once, not once per session.
nonisolated(unsafe) let senderActive = AtomicBool(false)

func runSender(host: String, port: UInt16, targetMs: Int, ioFrames: UInt32,
               peerName: String?, startIdle: Bool) -> Never
{
    installTeardownHandlers()

    for (number, wanted) in [(SIGUSR1, false), (SIGUSR2, true)] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { senderActive.value = wanted }
        source.resume()
        _ = Unmanaged.passRetained(source as AnyObject)
    }
    senderActive.value = !startIdle

    // Output first, tap second: the tap can only exclude this process once it
    // has an output device open, and being excluded is what keeps our own
    // playback out of the capture.
    let player = Player(targetFrames: targetMs > 0 ? targetMs * sampleRate / 1000
                                                   : 20 * sampleRate / 1000,
                        ioFrames: ioFrames)
    livePlayer = player
    let outbound = Ring(frames: ringFrames)
    let tap = Tap(left: player.ring, right: outbound)
    liveTap = tap
    tap.effects.startWatching()
    log("ready" + (startIdle ? " (idle)" : ""))
    startStatsThread("left", player)

    let chunk = 256
    let chunkNanos = UInt64(chunk) * 1_000_000_000 / UInt64(sampleRate)
    let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)

    while true {
        while !senderActive.value { usleep(100_000) }

        var candidates: [(String, UInt16)] = []
        if host.isEmpty || host == "auto" {
            let peers = Discovery().search(timeout: 4)
            let chosen = peerName.map { wanted in peers.filter { $0.name == wanted } } ?? peers
            guard let peer = chosen.first else {
                log("no receiver found; waiting")
                senderActive.value = false
                continue
            }
            log("found \"\(peer.name)\"")
            candidates = preferredOrder(peer.addresses).map { ($0, UInt16(peer.port)) }
        } else {
            candidates = [(host, port)]
        }

        // Prefer whichever candidate actually routes over the Thunderbolt
        // bridge, keeping the first that connects as the fallback.
        let ourBridge = bridgeAddress()
        var connection: Int32?
        var reached = ""
        for (address, candidatePort) in candidates {
            guard let fd = connectTo(address, candidatePort) else { continue }
            if let bridge = ourBridge, localAddress(of: fd) == bridge {
                connection.map { close($0) }
                connection = fd
                reached = address
                break
            }
            if connection == nil {
                connection = fd
                reached = address
            } else {
                close(fd)
            }
        }
        guard let fd = connection else {
            log("could not reach the receiver; waiting")
            senderActive.value = false
            continue
        }
        disableNagle(fd)

        let wired = ourBridge != nil && localAddress(of: fd) == ourBridge
        // Measured: at 150 ms over Wi-Fi the schedule regularly came due before the
        // audio had arrived — sync was right but the sound broke up. The cable
        // needs almost nothing; Wi-Fi delivers in bursts and needs real margin.
        let negotiated = targetMs > 0 ? targetMs : (wired ? 20 : 300)
        log("connected to \(reached) over \(wired ? "thunderbolt" : "network"), "
            + "target \(negotiated) ms")

        player.setTarget(ms: negotiated)
        player.reset()

        let writeLock = NSLock()
        var announced = UInt32(negotiated).bigEndian
        _ = withUnsafeBytes(of: &announced) {
            sendFrame(fd, .target, $0.baseAddress!, $0.count, writeLock)
        }

        let volumes = VolumeSync(fd: fd, lock: writeLock)
        volumes.start()

        let alive = AtomicBool(true)
        Thread {
            readFrames(fd,
                       onAudio: { _, _, _ in },
                       onVolume: { volumes.applyRemote($0) },
                       onTarget: { _ in },
                       onTimeRequest: { asked in
                           // Reply with our clock so the receiver can work out
                           // the offset between the two machines.
                           _ = sendUInt64s(fd, .timeReply, [asked, nowNanos()], writeLock)
                       },
                       onTimeReply: { _, _ in },
                       onDelay: { ms in
                           // Match the receiver's extra delay exactly, or the
                           // two channels drift apart by however much it took.
                           player.extraDelayMicros.value = ms * 1000
                           log("matching receiver's extra delay: \(ms) ms")
                       })
            alive.value = false
        }.start()

        tap.startCapture()

        // One timeline for both machines: sample N is heard at start + N/48000.
        // The local player follows the same schedule with a zero offset, so the
        // two channels line up by construction instead of by luck.
        var sent = 0
        var start: UInt64 = 0
        player.clockOffset.value = 0

        var deadline = DispatchTime.now().uptimeNanoseconds

        // Send exactly one chunk per chunk-period, against a monotonic
        // deadline. Waiting for a full chunk would stop the stream whenever
        // nothing is playing — the tap produces nothing during silence — and
        // the receiver would drain, then take a burst when audio resumed.
        // Padding without the deadline is the opposite mistake: a chunk per gap
        // *and* a chunk per capture is twice real time.
        while alive.value, senderActive.value {
            deadline &+= chunkNanos
            let position = outbound.tailPosition
            let got = outbound.read(buffer, chunk)
            if got < chunk {
                buffer.advanced(by: got).update(repeating: 0, count: chunk - got)
            }
            // Nothing captured yet: hold the schedule until the tap produces.
            if sent == 0, got == 0 {
                let now = DispatchTime.now().uptimeNanoseconds
                if deadline > now { usleep(useconds_t((deadline - now) / 1000)) }
                continue
            }
            // Anchor on the first chunk that actually contains captured audio,
            // not on the moment the session opened. The tap needs a moment to
            // start producing, and anchoring before then leaves the schedule
            // running ahead of any data — which reads as a permanent underrun.
            if sent == 0 {
                start = nowNanos() &+ UInt64(negotiated) &* 1_000_000
                // Both rings are written by the same tap callback, so a
                // position in one is the same instant in the other.
                player.schedule.set(position: position, playTime: start)
            }
            let playTime = start &+ UInt64(sent) &* 1_000_000_000 / UInt64(sampleRate)
            var stamped = [UInt8]()
            withUnsafeBytes(of: playTime.bigEndian) { stamped.append(contentsOf: $0) }
            buffer.withMemoryRebound(to: UInt8.self, capacity: chunk * 2) { raw in
                stamped.append(contentsOf: UnsafeBufferPointer(start: raw, count: chunk * 2))
            }
            guard sendFrame(fd, .audio, stamped, stamped.count, writeLock) else { break }
            sent += chunk
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                usleep(useconds_t((deadline - now) / 1000))
            } else {
                deadline = now
            }
        }

        tap.stopCapture()
        volumes.stop()
        close(fd)
        player.reset()
        log(senderActive.value ? "receiver gone" : "stopped")
    }
}

func runReceiver(port: UInt16, targetMs: Int, ioFrames: UInt32) -> Never {
    installTeardownHandlers()

    let targetFrames = targetMs * sampleRate / 1000
    let player = Player(targetFrames: targetFrames, ioFrames: ioFrames)
    livePlayer = player
    startStatsThread("right", player)

    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { die("bind: \(String(cString: strerror(errno)))") }
    listen(listener, 1)
    log("listening on \(port), target \(targetMs) ms")

    let advertiser = Advertiser()
    advertiser.start(port: port)

    while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { continue }
        disableNagle(client)
        log("sender connected")
        player.reset()

        let writeLock = NSLock()
        let volumes = VolumeSync(fd: client, lock: writeLock)
        volumes.start()

        let clock = ClockSync()
        let margin = Margin()
        let stop = AtomicBool(false)
        Thread {
            // Keep re-measuring: the estimate improves whenever a round trip
            // happens to be quick, and a machine that sleeps needs it redone.
            while !stop.value {
                _ = sendUInt64s(client, .timeRequest, [nowNanos()], writeLock)
                // Fast at first so playback can start, then often enough to
                // keep the window fresh without flooding the link.
                Thread.sleep(forTimeInterval: clock.settled ? 1 : 0.05)
            }
        }.start()

        readFrames(client,
                   onAudio: { playTime, samples, count in
                       // Until the clock offset is measured it reads zero, and
                       // every calculation below compares the sender's raw
                       // clock against ours — a meaningless difference that
                       // looks like an enormous shortfall. Dropping the first
                       // fraction of a second costs nothing: playback has not
                       // primed yet, so these frames would be silence anyway.
                       guard clock.settled else { return }

                       let position = player.ring.headPosition
                       player.ring.write(samples, count)
                       player.clockOffset.value = Int(clock.offsetNanos)
                       player.schedule.set(position: position, playTime: playTime)

                       // How long this chunk has before it is due to be heard.
                       // Negative means it arrived too late to be of use.
                       let dueLocally = Int64(bitPattern: playTime) - clock.offsetNanos
                           + Int64(player.extraDelayMicros.value) * 1_000
                       margin.observe(marginNanos: dueLocally - Int64(bitPattern: nowNanos()),
                                      player: player,
                                      announce: { ms in
                                          var value = UInt32(ms).bigEndian
                                          _ = withUnsafeBytes(of: &value) {
                                              sendFrame(client, .delay, $0.baseAddress!,
                                                        $0.count, writeLock)
                                          }
                                      })
                   },
                   onVolume: { volumes.applyRemote($0) },
                   onTarget: { ms in
                       log("target set to \(ms) ms by the sender")
                       player.setTarget(ms: ms)
                   },
                   onTimeRequest: { _ in },
                   onTimeReply: { sentAt, remote in
                       clock.sample(sent: sentAt, remote: remote, received: nowNanos())
                   })
        stop.value = true

        volumes.stop()
        // Go silent the moment the sender leaves. Without this the buffer keeps
        // being played out and then replayed, which on the receiving Mac is a
        // loop of noise that outlives the app you pressed stop in — and that
        // machine may not be the one you are sitting at.
        player.reset()
        log("sender disconnected")
        close(client)
    }
}

/// Creating a tap succeeds even when the permission is denied — it just returns
/// silence — so the only honest check is to capture and look at the samples.
func runSelfTest(seconds: Double) -> Never {
    installTeardownHandlers()
    let left = Ring(frames: ringFrames)
    let right = Ring(frames: ringFrames)
    let tap = Tap(left: left, right: right, muteBehavior: .unmuted)
    liveTap = tap
    tap.startCapture()
    Thread.sleep(forTimeInterval: seconds)
    tap.stopCapture()

    var peak = 0
    let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 4096)
    defer { scratch.deallocate() }
    for ring in [left, right] {
        while true {
            let got = ring.read(scratch, 4096)
            if got == 0 { break }
            for i in 0 ..< got { peak = max(peak, abs(Int(scratch[i]))) }
        }
    }
    teardown()
    log("captured peak \(peak)")
    exit(0)
}

func runList() -> Never {
    let peers = Discovery().search(timeout: 4)
    // log(), not print(): launched via `open` there is nowhere for stdout to go.
    if peers.isEmpty {
        log("no receivers found")
    }
    for peer in peers {
        log("\(peer.name)  \(preferredOrder(peer.addresses).joined(separator: " "))  port \(peer.port)")
    }
    exit(0)
}
