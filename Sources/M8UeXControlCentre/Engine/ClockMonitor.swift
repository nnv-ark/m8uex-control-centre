import Foundation

// MARK: - Clock monitor

/// Derives tempo from the MIDI clock arriving on any port.
///
/// MIDI clock is 24 pulses per quarter note, so a steady 24 pulses per second is
/// 60 BPM. Timing comes from the pulse *timestamps* rather than from a count per
/// wall-clock second, which matters because CoreMIDI timestamps are sample-accurate
/// while our own observation points are not.
///
/// The average is over a fixed window (default 2 s) because a single pulse interval
/// is far too noisy to display: at 120 BPM the interval is about 20 ms, so one
/// jittery pulse would swing the reading by several BPM. Averaging across the window
/// gives a number that holds still long enough to read.
///
/// Thread-safety: `record` is called from the engine's MIDI worker queue, and
/// `averageBPM` is read from the main thread, so every access is locked.
public final class ClockMonitor {

    /// Pulses per quarter note, fixed by the MIDI specification.
    public static let pulsesPerQuarterNote = 24.0

    private struct Pulse {
        let hostTime: UInt64
        let portID: MIDIPort.ID
    }

    private let lock = NSLock()
    /// Recent pulses, oldest first, trimmed to the averaging window.
    ///
    /// Tracked **per port**, which is essential rather than tidy: a DAW commonly
    /// sends MIDI clock to every output at once. Merging all ports into one list
    /// would count the same clock N times and report N× the real tempo — measured
    /// at 317 BPM on a 60 BPM source across five ports before this was split out.
    private var pulsesByPort: [MIDIPort.ID: [Pulse]] = [:]
    /// The window length in seconds.
    private let window: Double
    /// Ignore a burst this much longer than expected after a gap, so a stopped and
    /// restarted sequencer does not produce a nonsense average across the gap.
    private let maxGap: Double

    public init(window: Double = 2.0) {
        self.window = window
        // A gap longer than the whole averaging window means the clock genuinely
        // stopped, not that a pulse was missed.
        self.maxGap = window
    }

    /// Registers one clock pulse on one port. Called from the MIDI worker queue.
    public func record(at hostTime: UInt64, portID: MIDIPort.ID) {
        lock.lock()
        defer { lock.unlock() }

        var pulses = pulsesByPort[portID] ?? []
        // A long silence means the previous tempo on this port is stale; start
        // again rather than averaging across the gap.
        if let last = pulses.last,
           MIDITime.seconds(hostTime &- last.hostTime) > maxGap {
            pulses.removeAll(keepingCapacity: true)
        }
        pulses.append(Pulse(hostTime: hostTime, portID: portID))
        pulsesByPort[portID] = pulses
        pruneLocked(portID: portID, now: hostTime)

        // Drop ports whose clock stopped, so a long session does not accumulate
        // dead histories.
        let cutoff = hostTime &- MIDITime.hostTicks(seconds: window)
        for (id, history) in pulsesByPort where id != portID {
            if history.last.map({ $0.hostTime < cutoff }) ?? true {
                pulsesByPort.removeValue(forKey: id)
            }
        }
    }

    /// A single port to trust for tempo, if one has been designated.
    ///
    /// Worth setting in practice. A DAW commonly receives clock on one input and
    /// broadcasts its own clock to every output; with the interface's own routing
    /// patched, that broadcast comes straight back in on other ports and the merged
    /// reading is inflated (measured: 317 BPM on a 60 BPM source). Naming the real
    /// clock source removes that feedback entirely.
    public var preferredPortID: MIDIPort.ID?

    /// The average tempo of the designated port, or of the busiest port when none
    /// is designated.
    ///
    /// Returns nil rather than 0 while stopped, so the UI can show a clear "no clock"
    /// state instead of a confident and wrong number.
    public func averageBPM(now: UInt64) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        pruneAllLocked(now: now)

        if let preferred = preferredPortID {
            // Only that port counts. No clock there means no tempo, even if other
            // ports are busy — otherwise feedback would still show through.
            guard let pulses = pulsesByPort[preferred], pulses.count >= 2,
                  let first = pulses.first, let last = pulses.last else { return nil }
            return Self.bpm(from: first.hostTime, to: last.hostTime, pulses: pulses.count)
        }

        // No designation: use the port with the most pulses rather than merging,
        // because clock is normally broadcast to several outputs at once and merging
        // would multiply the reading by the number of ports.
        let best = pulsesByPort.values.max { $0.count < $1.count }
        guard let pulses = best, pulses.count >= 2,
              let first = pulses.first, let last = pulses.last else { return nil }
        return Self.bpm(from: first.hostTime, to: last.hostTime, pulses: pulses.count)
    }

    /// Tempo for one specific port, for the per-port breakdown.
    public func bpm(forPort portID: MIDIPort.ID, now: UInt64) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        pruneAllLocked(now: now)
        guard let pulses = pulsesByPort[portID], pulses.count >= 2,
              let first = pulses.first, let last = pulses.last else { return nil }
        return Self.bpm(from: first.hostTime, to: last.hostTime, pulses: pulses.count)
    }

    /// The shared tempo calculation. `count - 1` intervals span `count` pulses.
    private static func bpm(from first: UInt64, to last: UInt64, pulses count: Int) -> Double? {
        let span = MIDITime.seconds(last &- first)
        guard span > 0 else { return nil }
        let intervals = Double(count - 1)
        let bpm = (intervals / pulsesPerQuarterNote) / span * 60.0
        // Reject values outside anything musically plausible.
        guard bpm >= 10, bpm <= 400 else { return nil }
        return bpm
    }

    /// True when a pulse has arrived recently enough to call the clock running.
    public func isRunning(now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now &- MIDITime.hostTicks(seconds: 0.5)
        if let preferred = preferredPortID {
            return pulsesByPort[preferred]?.last.map { $0.hostTime >= cutoff } ?? false
        }
        return pulsesByPort.values.contains { $0.last.map { $0.hostTime >= cutoff } ?? false }
    }

    /// Pulses inside the window on the measured port, for display and diagnosis.
    public func pulseCount(now: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pruneAllLocked(now: now)
        if let preferred = preferredPortID {
            return pulsesByPort[preferred]?.count ?? 0
        }
        return pulsesByPort.values.map(\.count).max() ?? 0
    }

    /// Ports currently carrying clock, most pulses first.
    public func activeClockPorts(now: UInt64) -> [(portID: MIDIPort.ID, pulses: Int)] {
        lock.lock()
        defer { lock.unlock() }
        pruneAllLocked(now: now)
        return pulsesByPort
            .map { (portID: $0.key, pulses: $0.value.count) }
            .filter { $0.pulses > 1 }
            .sorted { $0.pulses > $1.pulses }
    }

    public func reset() {
        lock.lock()
        pulsesByPort.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Must be called with the lock held.
    private func pruneLocked(portID: MIDIPort.ID, now: UInt64) {
        guard var history = pulsesByPort[portID] else { return }
        let cutoff = now &- MIDITime.hostTicks(seconds: window)
        // `hostTime` is monotonic, so a threshold comparison is safe.
        if let index = history.firstIndex(where: { $0.hostTime >= cutoff }) {
            if index > 0 { history.removeFirst(index) }
        } else {
            history.removeAll(keepingCapacity: true)
        }
        pulsesByPort[portID] = history
    }

    /// Must be called with the lock held.
    private func pruneAllLocked(now: UInt64) {
        let cutoff = now &- MIDITime.hostTicks(seconds: window)
        for (portID, history) in pulsesByPort {
            if let index = history.firstIndex(where: { $0.hostTime >= cutoff }) {
                if index > 0 { pulsesByPort[portID] = Array(history.dropFirst(index)) }
            } else {
                pulsesByPort.removeValue(forKey: portID)
            }
        }
    }
}
