import Foundation
import CoreMIDI

// MARK: - Self test

/// Headless verification of the CoreMIDI engine.
///
/// Run with `--selftest`. It builds a real virtual MIDI endpoint pair, injects
/// traffic through the engine's actual receive path, and asserts on what comes
/// out the far side — no M8U eX and no GUI required. This is how the engine is
/// verified on a machine with no hardware attached.
///
/// The process exits non-zero if any check fails, so this can gate a release.
enum SelfTest {

    // MARK: Harness

    final class Harness {
        private(set) var passed = 0
        private(set) var failed = 0
        private var lines: [String] = []

        /// Writes straight to standard error, unbuffered.
        ///
        /// `print` buffers when output is not a terminal, so a crash would
        /// swallow the evidence of where it happened. This is what makes the
        /// self test useful as a diagnostic.
        private static func emit(_ text: String) {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }

        func check(_ label: String, _ condition: Bool, detail: String = "") {
            if condition {
                passed += 1
                lines.append("  ✓ \(label)")
            } else {
                failed += 1
                let suffix = detail.isEmpty ? "" : "   [\(detail)]"
                lines.append("  ✗ \(label)\(suffix)")
            }
            // Stream each result as it is decided so progress is visible even if
            // something later in the run traps.
            Self.emit(lines[lines.count - 1])
        }

        func section(_ title: String) {
            lines.append("")
            lines.append(title.uppercased())
            Self.emit("")
            Self.emit(title.uppercased())
        }

        func note(_ text: String) {
            lines.append("  · \(text)")
            Self.emit("  · \(text)")
        }

        var report: String { lines.joined(separator: "\n") }
    }

    /// Collects what a test destination receives, written from the CoreMIDI
    /// callback thread and read from the test thread.
    final class Capture {
        static let shared = Capture()
        private let lock = NSLock()
        private var storage: [MIDIMessage] = []

        var messages: [MIDIMessage] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func record(_ message: MIDIMessage) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            storage.removeAll()
            lock.unlock()
        }
    }

    // MARK: Entry point

    static func run() -> Int32 {
        let harness = Harness()

        print("M8U eX Control Centre — engine self test")
        print(String(repeating: "=", count: 56))

        testParser(harness)
        testFiltering(harness)
        testTransforms(harness)
        testMultiUnitIdentity(harness)
        testClockTempo(harness)
        testOfflineDevicesExcluded(harness)
        testProfilePersistence(harness)
        testLiveCoreMIDI(harness)

        print(harness.report)
        print("")
        print(String(repeating: "=", count: 56))
        print("\(harness.passed) passed, \(harness.failed) failed")
        return harness.failed == 0 ? 0 : 1
    }

    /// Runs the run loop until `condition` is true or `timeout` elapses.
    @discardableResult
    private static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: Parser

    private static func testParser(_ harness: Harness) {
        harness.section("MIDI byte stream parser")

        let basic = MIDIByteStreamParser()
        let single = basic.parse([0x90, 60, 100], timestamp: 1)
        harness.check("decodes a note on",
                      single.messages.count == 1 && single.messages.first?.bytes == [0x90, 60, 100])

        let multi = basic.parse([0x90, 60, 100, 0x80, 60, 0], timestamp: 2)
        harness.check("splits two messages in one packet", multi.messages.count == 2,
                      detail: "got \(multi.messages.count)")

        let splitter = MIDIByteStreamParser()
        let head = splitter.parse([0x90, 64], timestamp: 3)
        harness.check("holds back an incomplete message", head.messages.isEmpty)
        let tail = splitter.parse([100], timestamp: 4)
        harness.check("reassembles a message split across packets",
                      tail.messages.count == 1 && tail.messages.first?.bytes == [0x90, 64, 100])

        let running = MIDIByteStreamParser()
        _ = running.parse([0x90, 60, 100], timestamp: 5)
        let continued = running.parse([62, 100, 64, 100], timestamp: 6)
        harness.check("applies running status",
                      continued.messages.count == 2
                        && continued.messages[0].bytes == [0x90, 62, 100]
                        && continued.messages[1].bytes == [0x90, 64, 100],
                      detail: "got \(continued.messages.map(\.bytes))")

        let interleaved = MIDIByteStreamParser()
        let mixed = interleaved.parse([0x90, 60, 0xF8, 100], timestamp: 7)
        harness.check("lifts real-time clock out of a note message",
                      mixed.messages.count == 2
                        && mixed.messages.contains { $0.bytes == [0xF8] }
                        && mixed.messages.contains { $0.bytes == [0x90, 60, 100] },
                      detail: "got \(mixed.messages.map(\.bytes))")

        let sysEx = MIDIByteStreamParser()
        let sysExHead = sysEx.parse([0xF0, 0x7E, 0x00], timestamp: 8)
        harness.check("holds an incomplete SysEx", sysExHead.messages.isEmpty)
        let sysExTail = sysEx.parse([0x06, 0x01, 0xF7], timestamp: 9)
        harness.check("completes a SysEx spanning packets",
                      sysExTail.messages.count == 1
                        && sysExTail.messages.first?.bytes == [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7],
                      detail: "all=\(sysExTail.messages.map(\.bytes)) anomalies=\(sysExTail.anomalies.count)")

        let malformed = MIDIByteStreamParser()
        let garbage = malformed.parse([0x40, 0x50], timestamp: 10)
        harness.check("reports data bytes that have no status byte",
                      garbage.messages.isEmpty && garbage.anomalies.count == 2,
                      detail: "messages \(garbage.messages.count), anomalies \(garbage.anomalies.count)")

        let program = MIDIByteStreamParser()
        let programResult = program.parse([0xC0, 42], timestamp: 11)
        harness.check("treats program change as a two-byte message",
                      programResult.messages.count == 1
                        && programResult.messages.first?.bytes == [0xC0, 42])

        let aftertouch = MIDIByteStreamParser()
        let aftertouchResult = aftertouch.parse([0xD0, 80], timestamp: 12)
        harness.check("treats channel aftertouch as a two-byte message",
                      aftertouchResult.messages.count == 1)

        harness.check("names notes in scientific pitch",
                      MIDIMessage.noteName(60) == "C4" && MIDIMessage.noteName(69) == "A4",
                      detail: "60→\(MIDIMessage.noteName(60)) 69→\(MIDIMessage.noteName(69))")

        harness.check("decodes pitch bend around centre",
                      MIDIMessage(bytes: [0xE0, 0x00, 0x40]).summary.contains("0"),
                      detail: MIDIMessage(bytes: [0xE0, 0x00, 0x40]).summary)
    }

    // MARK: Filtering

    private static func testFiltering(_ harness: Harness) {
        harness.section("Route filtering")

        var route = Route(sourcePortID: .m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 1), destinationPortID: .m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 2))
        let noteOn = MIDIMessage(bytes: [0x90, 60, 100])

        harness.check("passes a note by default", route.process(noteOn).count == 1)

        route.channels = ChannelMask(rawValue: 1 << 0)
        harness.check("passes a message on an allowed channel", route.process(noteOn).count == 1)
        harness.check("blocks a message on a disallowed channel",
                      route.process(MIDIMessage(bytes: [0x94, 60, 100])).isEmpty)

        route.channels = .all
        route.messageKinds.clock = false
        harness.check("blocks clock when its kind is disabled",
                      route.process(MIDIMessage(bytes: [0xF8])).isEmpty)
        harness.check("still passes notes when clock is disabled", route.process(noteOn).count == 1)

        route.messageKinds.note = false
        harness.check("blocks notes when their kind is disabled", route.process(noteOn).isEmpty)

        route.messageKinds.note = true
        route.channels = ChannelMask(rawValue: 1 << 0)
        harness.check("lets SysEx bypass the channel filter",
                      route.process(MIDIMessage(bytes: [0xF0, 0x7D, 0x01, 0xF7])).count == 1)
        route.channels = .all

        route.isEnabled = false
        harness.check("drops everything when the route is switched off", route.process(noteOn).isEmpty)
        route.isEnabled = true

        route.transform.blockedControllers = [7]
        harness.check("blocks a listed controller",
                      route.process(MIDIMessage(bytes: [0xB0, 7, 100])).isEmpty)
        harness.check("passes an unlisted controller",
                      route.process(MIDIMessage(bytes: [0xB0, 1, 100])).count == 1)
        route.transform.blockedControllers = []

        route.transform.noteRangeLow = 60
        route.transform.noteRangeHigh = 72
        harness.check("blocks a note below the range",
                      route.process(MIDIMessage(bytes: [0x90, 59, 100])).isEmpty)
        harness.check("passes a note inside the range",
                      route.process(MIDIMessage(bytes: [0x90, 60, 100])).count == 1)
        harness.check("blocks a note above the range",
                      route.process(MIDIMessage(bytes: [0x90, 73, 100])).isEmpty)

        harness.check("labels all channels", ChannelMask.all.label == "All channels")
        harness.check("labels no channels", ChannelMask.none.label == "No channels")
    }

    // MARK: Transforms

    private static func testTransforms(_ harness: Harness) {
        harness.section("Route transforms")

        var route = Route(sourcePortID: .m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 1), destinationPortID: .m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 2))
        let noteOn = MIDIMessage(bytes: [0x90, 60, 100])

        route.transform.transpose = 12
        harness.check("transposes up an octave",
                      route.process(noteOn).first?.bytes == [0x90, 72, 100],
                      detail: "got \(route.process(noteOn).first?.bytes ?? [])")

        route.transform.transpose = -60
        harness.check("clamps a transposition below note 0",
                      route.process(MIDIMessage(bytes: [0x90, 10, 100])).first?.bytes[1] == 0)

        route.transform.transpose = 60
        harness.check("clamps a transposition above note 127",
                      route.process(MIDIMessage(bytes: [0x90, 100, 100])).first?.bytes[1] == 127)

        route.transform = .identity
        route.transform.velocityScale = 0.5
        harness.check("scales velocity",
                      route.process(noteOn).first?.bytes[2] == 50,
                      detail: "got \(route.process(noteOn).first?.bytes[2] ?? 255)")

        route.transform = .identity
        route.transform.velocityOffset = 20
        harness.check("clamps velocity at 127",
                      route.process(MIDIMessage(bytes: [0x90, 60, 120])).first?.bytes[2] == 127)

        route.transform = .identity
        route.transform.forceChannel = 10
        harness.check("forces the output channel",
                      route.process(noteOn).first?.bytes.first == 0x99,
                      detail: "status \(String(format: "%02X", route.process(noteOn).first?.bytes.first ?? 0))")

        route.transform = .identity
        route.transform.transpose = 5
        harness.check("leaves velocity untouched when transposing",
                      route.process(noteOn).first?.bytes[2] == 100)

        harness.check("identity transform reports no summary", RouteTransform.identity.summary == nil)
        harness.check("a real transform reports a summary", RouteTransform(transpose: 3).summary != nil)
    }

    // MARK: Offline devices

    /// CoreMIDI keeps a cached device entry for every interface it has ever seen and
    /// reports it offline. Those must never be presented as connected, or the app
    /// claims hardware that is not plugged in — which it did, showing a disconnected
    /// M4U eX alongside a connected M8U eX.
    private static func testOfflineDevicesExcluded(_ harness: Harness) {
        harness.section("Offline devices are not presented as connected")

        // The distinction macOS draws, and which the app must respect.
        let all = MIDIEndpointEnumerator.m8uPorts()
        let offline = all.filter { port in
            (port.source?.offline ?? true) && (port.destination?.offline ?? true)
        }
        harness.check("no enumerated socket has both endpoints offline",
                      offline.isEmpty,
                      detail: "\(offline.count) offline socket(s) leaked into the port list")

        // Count against what CoreMIDI itself says is online, so this cannot pass by
        // the port list simply being empty.
        var onlineSockets = 0
        for deviceIndex in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(deviceIndex)
            let name = MIDIObject.name(device)
            guard M8UeXDiscovery.matches(deviceName: name) else { continue }
            if MIDIObject.isOffline(device) { continue }
            for entityIndex in 0..<MIDIDeviceGetNumberOfEntities(device) {
                let entity = MIDIDeviceGetEntity(device, entityIndex)
                if M8UeXDiscovery.portIndex(fromEntityName: MIDIObject.name(entity)) != nil {
                    onlineSockets += 1
                }
            }
        }
        harness.check("enumerated socket count matches the online devices",
                      all.count == onlineSockets,
                      detail: "enumerated \(all.count), online \(onlineSockets)")

        // Every returned port must have at least one live endpoint.
        let allLive = all.allSatisfy { port in
            !(port.source?.offline ?? true) || !(port.destination?.offline ?? true)
        }
        harness.check("every returned socket has a live endpoint", allLive)

        // External endpoints are filtered by the same rule.
        let externals = MIDIEndpointEnumerator.otherPorts(excluding: [])
        let offlineExternals = externals.filter { $0.source?.offline ?? $0.destination?.offline ?? true }
        harness.check("no offline external endpoints are offered as routable",
                      offlineExternals.isEmpty,
                      detail: "\(offlineExternals.count) offline endpoint(s) leaked in")
    }

    // MARK: Clock and tempo

    /// Tempo is derived from MIDI clock pulse timestamps, 24 pulses per quarter
    /// note. A wrong number here would be actively misleading, so the maths is
    /// pinned: a known pulse rate must produce a known BPM, and silence must
    /// produce no reading at all rather than zero.
    private static func testClockTempo(_ harness: Harness) {
        harness.section("Clock and tempo")

        // 24 pulses per second = 60 BPM, the definition of MIDI clock.
        harness.check("24 pulses per quarter note",
                      ClockMonitor.pulsesPerQuarterNote == 24)

        let monitor = ClockMonitor(window: 2.0)
        let start = MIDITime.hostTime()
        let portID = MIDIPort.ID.m8u(unitName: "ESI M8U eX", deviceUID: 1, index: 1)

        // Feed 24 pulses at exactly 1/24 s spacing => 60 BPM.
        let interval = MIDITime.hostTicks(seconds: 1.0 / 24.0)
        for i in 0..<48 {
            monitor.record(at: start &+ UInt64(i) * interval, portID: portID)
        }
        let atEnd = start &+ UInt64(47) * interval
        let bpm60 = monitor.averageBPM(now: atEnd)
        harness.check("72 pulses at 1/24 s spacing reads 60 BPM",
                      bpm60.map { abs($0 - 60) < 2 } ?? false,
                      detail: "got \(bpm60.map { String(format: "%.2f", $0) } ?? "nil")")

        // Double the rate => 120 BPM.
        let fast = ClockMonitor(window: 2.0)
        let fastInterval = MIDITime.hostTicks(seconds: 1.0 / 48.0)
        for i in 0..<96 {
            fast.record(at: start &+ UInt64(i) * fastInterval, portID: portID)
        }
        let fastEnd = start &+ UInt64(95) * fastInterval
        let bpm120 = fast.averageBPM(now: fastEnd)
        harness.check("96 pulses at 1/48 s spacing reads 120 BPM",
                      bpm120.map { abs($0 - 120) < 3 } ?? false,
                      detail: "got \(bpm120.map { String(format: "%.2f", $0) } ?? "nil")")

        // No clock at all must be nil, not zero — "stopped" is not "0 BPM".
        let silent = ClockMonitor(window: 2.0)
        harness.check("silence reports no tempo rather than zero",
                      silent.averageBPM(now: start) == nil)
        harness.check("silence is not reported as running",
                      silent.isRunning(now: start) == false)

        // One pulse is not enough to measure a rate.
        let single = ClockMonitor(window: 2.0)
        single.record(at: start, portID: portID)
        harness.check("a single pulse yields no tempo",
                      single.averageBPM(now: start) == nil)

        // Clock that stopped a while ago must not keep reporting an old tempo.
        let stalled = ClockMonitor(window: 2.0)
        for i in 0..<48 {
            stalled.record(at: start &+ UInt64(i) * interval, portID: portID)
        }
        let longAfter = atEnd &+ MIDITime.hostTicks(seconds: 5)
        harness.check("a stalled clock stops reporting tempo",
                      stalled.averageBPM(now: longAfter) == nil,
                      detail: "got \(stalled.averageBPM(now: longAfter).map { String(format: "%.2f", $0) } ?? "nil")")
        harness.check("a stalled clock is not reported as running",
                      stalled.isRunning(now: longAfter) == false)

        // The bug this guards against was real and shipped for one build: a DAW
        // broadcasts clock to every output, and merging all ports into one pulse
        // list reported N x the true tempo (measured: 317 BPM for a 60 BPM source
        // across five ports). Tempo must be taken per port.
        let shared = ClockMonitor(window: 2.0)
        let ports = (1...5).map { MIDIPort.ID.m8u(unitName: "ESI M8U eX", deviceUID: 1, index: $0) }
        for i in 0..<48 {
            // The same clock pulse arriving on five ports at the same instant.
            for port in ports {
                shared.record(at: start &+ UInt64(i) * interval, portID: port)
            }
        }
        let sharedBPM = shared.averageBPM(now: atEnd)
        harness.check("clock broadcast to 5 ports still reads 60 BPM, not 5x",
                      sharedBPM.map { abs($0 - 60) < 2 } ?? false,
                      detail: "got \(sharedBPM.map { String(format: "%.2f", $0) } ?? "nil")")
        harness.check("pulse count reflects one port, not the sum",
                      shared.pulseCount(now: atEnd) <= 49,
                      detail: "counted \(shared.pulseCount(now: atEnd))")
        harness.check("all five clock ports are reported",
                      shared.activeClockPorts(now: atEnd).count == 5,
                      detail: "saw \(shared.activeClockPorts(now: atEnd).count)")
        harness.check("a single port's tempo can be read individually",
                      shared.bpm(forPort: ports[0], now: atEnd).map { abs($0 - 60) < 2 } ?? false)

        // Two ports at genuinely different tempos must not be blended.
        let mixed = ClockMonitor(window: 2.0)
        for i in 0..<24 { mixed.record(at: start &+ UInt64(i) * interval, portID: ports[0]) }
        for i in 0..<48 { mixed.record(at: start &+ UInt64(i) * fastInterval, portID: ports[1]) }
        let dominant = mixed.averageBPM(now: atEnd)
        harness.check("the busier port wins rather than the two being blended",
                      dominant.map { abs($0 - 120) < 4 } ?? false,
                      detail: "got \(dominant.map { String(format: "%.2f", $0) } ?? "nil")")

        // The window must actually bound how much history is kept.
        harness.check("pulses are pruned to the 2 s window",
                      monitor.pulseCount(now: atEnd) <= 49,
                      detail: "kept \(monitor.pulseCount(now: atEnd))")

        // A gap larger than the window discards stale history rather than
        // averaging across the silence.
        let restarted = ClockMonitor(window: 2.0)
        for i in 0..<24 {
            restarted.record(at: start &+ UInt64(i) * interval, portID: portID)
        }
        let resumed = atEnd &+ MIDITime.hostTicks(seconds: 10)
        for i in 0..<24 {
            restarted.record(at: resumed &+ UInt64(i) * interval, portID: portID)
        }
        let afterGap = restarted.averageBPM(now: resumed &+ UInt64(23) * interval)
        harness.check("a long gap is not averaged across",
                      afterGap.map { abs($0 - 60) < 3 } ?? false,
                      detail: "got \(afterGap.map { String(format: "%.2f", $0) } ?? "nil")")
    }

    // MARK: Multi-unit identity

    /// The M8U eX and the M4U eX both expose entities named "Port 1"…"Port N", so
    /// socket number alone does not identify a port once two units are connected.
    /// These checks pin down that two units never share a port identity, that the
    /// M8U's 16 sockets and the M4U's 8 stay separate, and that a saved rig still
    /// resolves after a device is handed a new CoreMIDI ID.
    private static func testMultiUnitIdentity(_ harness: Harness) {
        harness.section("Multi-unit identity (M8U eX + M4U eX)")

        // Two units of different models, each starting its sockets at 1. The old
        // scheme numbered units in discovery order, so both became "unit 1" and
        // their port 1 collided outright.
        let m8uUID: MIDIUniqueID = 1001
        let m4uUID: MIDIUniqueID = 2002
        let m8u = MIDIPort(
            id: .m8u(unitName: "ESI M8U eX", deviceUID: m8uUID, index: 1),
            label: "ESI M8U eX · Port 1", kind: .m8uPhysical
        )
        let m4u = MIDIPort(
            id: .m8u(unitName: "ESI M4U eX", deviceUID: m4uUID, index: 1),
            label: "ESI M4U eX · Port 1", kind: .m8uPhysical
        )
        harness.check("an M8U eX port and an M4U eX port with the same socket number are distinct",
                      m8u.id != m4u.id)

        // Both units' sockets must survive in a set — the real test of uniqueness.
        var ports: [MIDIPort] = []
        for index in 1...16 {
            ports.append(MIDIPort(
                id: .m8u(unitName: "ESI M8U eX", deviceUID: m8uUID, index: index),
                label: "ESI M8U eX · Port \(index)", kind: .m8uPhysical
            ))
        }
        for index in 1...8 {
            ports.append(MIDIPort(
                id: .m8u(unitName: "ESI M4U eX", deviceUID: m4uUID, index: index),
                label: "ESI M4U eX · Port \(index)", kind: .m8uPhysical
            ))
        }
        harness.check("all 24 sockets across two units have unique identities",
                      Set(ports.map(\.id)).count == 24,
                      detail: "unique \(Set(ports.map(\.id)).count) of \(ports.count)")

        // Ordering must group each unit's sockets rather than interleaving them by
        // socket number, which an arithmetic sort key would do (M8U has 16, M4U 8).
        let ordered = ports.sorted { $0.sortKey < $1.sortKey }
        let transitions = zip(ordered, ordered.dropFirst()).filter { $0.id.unitName != $1.id.unitName }.count
        harness.check("sorting groups each unit's sockets together",
                      transitions == 1,
                      detail: "\(transitions) unit changes in the list (expected 1)")

        for unitName in ["ESI M8U eX", "ESI M4U eX"] {
            let indices = ordered.filter { $0.id.unitName == unitName }.compactMap(\.m8uIndex)
            harness.check("\(unitName) sockets read in printed order",
                          indices == Array(1...indices.count),
                          detail: "got \(indices.prefix(6))…")
        }

        // A rig saved before a replug stores the old device ID. Resolution must
        // still find the socket by device name and socket number.
        let livePorts = ports
        let resolver = PortResolver(ports: livePorts)
        let staleM4U = MIDIPort.ID.m8u(unitName: "ESI M4U eX", deviceUID: 999_999, index: 3)
        harness.check("a stale device ID still resolves by name and socket",
                      resolver.resolve(staleM4U) == MIDIPort.ID.m8u(unitName: "ESI M4U eX", deviceUID: m4uUID, index: 3),
                      detail: "resolved to \(String(describing: resolver.resolve(staleM4U)))")
        harness.check("the fallback is reported, not hidden", resolver.neededFallback(staleM4U))

        // An exact match must not be treated as a fallback.
        let exact = MIDIPort.ID.m8u(unitName: "ESI M8U eX", deviceUID: m8uUID, index: 7)
        harness.check("an exact identity resolves without the fallback",
                      resolver.resolve(exact) == exact && !resolver.neededFallback(exact))

        // A socket that does not exist must stay unresolved rather than matching
        // some other unit's port by number.
        let absent = MIDIPort.ID.m8u(unitName: "ESI M4U eX", deviceUID: 0, index: 9)
        harness.check("a 9th socket on an 8-port M4U eX does not resolve",
                      resolver.resolve(absent) == nil)

        // Names must distinguish the units, since that is what the user reads.
        harness.check("port labels carry the interface name",
                      m4u.label.contains("M4U") && m8u.label.contains("M8U"),
                      detail: "\(m8u.label) / \(m4u.label)")

        // An unnumbered entity name must still yield a usable socket index rather
        // than dropping the port entirely.
        harness.check("unnumbered entity names are recognised as not-a-socket",
                      M8UeXDiscovery.portIndex(fromEntityName: "MIDI") == nil)
        harness.check("numbered entity names parse",
                      M8UeXDiscovery.portIndex(fromEntityName: "Port 12") == 12)
        harness.check("the M4U eX is recognised as an eX-series device",
                      M8UeXDiscovery.matches(deviceName: "ESI M4U eX"))
        harness.check("the M4U eX is expected to expose 8 sockets",
                      M8UeXDiscovery.expectedPortCount(deviceName: "ESI M4U eX") == 8)
        harness.check("the M8U eX is expected to expose 16 sockets",
                      M8UeXDiscovery.expectedPortCount(deviceName: "ESI M8U eX") == 16)
    }

    // MARK: Persistence

    /// Explains how a decoded profile differs from the original, field by field.
    /// Returns an empty string when they match.
    private static func roundTripDifference(_ original: RigProfile, _ restored: RigProfile) -> String {
        var differences: [String] = []
        if original.id != restored.id { differences.append("id") }
        if original.name != restored.name { differences.append("name") }
        if original.details != restored.details { differences.append("details") }
        if original.createdAt != restored.createdAt { differences.append("createdAt") }
        if original.updatedAt != restored.updatedAt { differences.append("updatedAt") }
        if original.portConfigs != restored.portConfigs { differences.append("portConfigs") }
        if original.routes != restored.routes {
            differences.append("routes")
            let originalIDs = original.routes.map(\.id)
            let restoredIDs = restored.routes.map(\.id)
            if originalIDs != restoredIDs { differences.append("route ids") }
            if original.routes.map(\.sourcePortID) != restored.routes.map(\.sourcePortID) {
                differences.append("route sources")
            }
            if original.routes.map(\.channels) != restored.routes.map(\.channels) {
                differences.append("route channels")
            }
            if original.routes.map(\.transform) != restored.routes.map(\.transform) {
                differences.append("route transforms")
            }
        }
        return differences.isEmpty ? "" : "differs in: " + differences.joined(separator: ", ")
    }

    private static func testProfilePersistence(_ harness: Harness) {
        harness.section("Rig profile persistence")

        // A route's `id` is generated fresh on decode, so a byte-for-byte equal
        // profile is only equal when the ids are pinned too. That is what makes
        // the comparison below meaningful.
        let fixedRouteID = UUID()
        let profile = RigProfile(
            name: "Test rig",
            details: "Round trip",
            portConfigs: [
                .m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 7): PortConfig(customLabel: "Prophet 6"),
                .m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 3): PortConfig(customLabel: "Clock out", hidden: true),
            ],
            routes: [
                Route(
                    id: fixedRouteID,
                    sourcePortID: .m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 7),
                    destinationPortID: .m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 3),
                    channels: ChannelMask(rawValue: 0x0003),
                    transform: RouteTransform(transpose: -12, blockedControllers: [7, 11])
                )
            ]
        )

        let encoder = RigCoding.makeEncoder()
        let decoder = RigCoding.makeDecoder()

        do {
            let data = try encoder.encode(profile)
            let restored = try decoder.decode(RigProfile.self, from: data)
            harness.check("a profile survives a JSON round trip", restored == profile,
                          detail: roundTripDifference(profile, restored))
            harness.check("port names survive",
                          restored.portConfigs[.m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 7)]?.customLabel == "Prophet 6")
            harness.check("channel masks survive",
                          restored.routes.first?.channels == ChannelMask(rawValue: 0x0003))
            harness.check("transforms survive",
                          restored.routes.first?.transform.transpose == -12
                            && restored.routes.first?.transform.blockedControllers == [7, 11])

            let text = String(data: data, encoding: .utf8) ?? ""
            harness.check("the profile file is human-readable",
                          text.contains("Prophet 6") && text.contains("m8u"))
        } catch {
            harness.check("profile round trip", false, detail: error.localizedDescription)
        }

        harness.check("port identity is encodable, so rigs survive a replug",
                      (try? encoder.encode(MIDIPort.ID.m8u(unitName: "ESI M8U eX", deviceUID: 0, index: 16))) != nil)
    }

    // MARK: Live CoreMIDI integration

    /// Exercises the engine exactly as CoreMIDI would, with a real virtual
    /// endpoint pair standing in for the interface.
    private static func testLiveCoreMIDI(_ harness: Harness) {
        harness.section("Engine integration over live CoreMIDI")

        let engine = MIDIEngine()
        engine.monitorCapacity = 200
        engine.start()

        waitUntil(3) { !engine.ports.isEmpty }
        harness.check("engine enumerated CoreMIDI endpoints", !engine.ports.isEmpty,
                      detail: "found \(engine.ports.count)")

        let m8uSockets = engine.ports.filter(\.isM8UPhysical).count
        if m8uSockets > 0 {
            harness.note("\(m8uSockets) M8U eX socket endpoints were found in the cached MIDI setup")
        } else {
            harness.note("no M8U eX endpoints present — testing against a virtual loopback instead")
        }

        // A matched source/destination pair to stand in for hardware.
        var client = MIDIClientRef(0)
        let clientStatus = MIDIClientCreateWithBlock("SelfTest Loopback" as CFString, &client, nil)
        harness.check("created a test CoreMIDI client", clientStatus == noErr,
                      detail: "status \(clientStatus)")
        guard clientStatus == noErr else {
            engine.stop()
            return
        }

        var testSource = MIDIEndpointRef(0)
        let sourceStatus = MIDISourceCreate(client, "M8U eX SelfTest Source" as CFString, &testSource)

        // The destination lives under a *second* client. CoreMIDI does not route
        // a virtual destination back to a port owned by the same client, so a
        // destination created on `client` would never receive anything the app
        // sends, no matter how correct the routing is. A separate client is also
        // exactly how a real synth at the far end behaves.
        var listener = MIDIClientRef(0)
        let listenerStatus = MIDIClientCreateWithBlock("SelfTest Listener" as CFString, &listener, nil)
        harness.check("created the listener client", listenerStatus == noErr,
                      detail: "status \(listenerStatus)")

        var testDestination = MIDIEndpointRef(0)
        let destinationStatus = MIDIDestinationCreateWithBlock(
            listener,
            "M8U eX SelfTest Destination" as CFString,
            &testDestination
        ) { packetList, _ in
            // This is the far end of the patch: whatever the engine routes here
            // is what a real synth would have received.
            let parser = MIDIByteStreamParser()
            for chunk in MIDIPacketBridge.drain(packetList: packetList) {
                for message in parser.parse(chunk.bytes, timestamp: chunk.timestamp).messages {
                    Capture.shared.record(message)
                }
            }
        }

        harness.check("created the test endpoints",
                      sourceStatus == noErr && destinationStatus == noErr,
                      detail: "source \(sourceStatus), destination \(destinationStatus)")

        guard sourceStatus == noErr, destinationStatus == noErr else {
            MIDIClientDispose(listener)
            MIDIClientDispose(client)
            engine.stop()
            return
        }

        guard let sourceID = MIDIObject.uniqueID(testSource),
              let destinationID = MIDIObject.uniqueID(testDestination) else {
            harness.check("test endpoints report unique ids", false)
            MIDIClientDispose(listener)
            MIDIClientDispose(client)
            engine.stop()
            return
        }

        let sourcePortID = MIDIPort.ID.virtual(name: "selftest-source")
        let destinationPortID = MIDIPort.ID.virtual(name: "selftest-destination")

        engine.registerTestPorts(
            source: MIDIPort(
                id: sourcePortID,
                label: "SelfTest Source",
                kind: .system,
                source: EndpointInfo(
                    uniqueID: sourceID,
                    name: "SelfTest Source",
                    displayName: "SelfTest Source",
                    endpoint: testSource,
                    isSource: true,
                    deviceName: "SelfTest",
                    entityName: "SelfTest",
                    offline: false,
                    kind: .system
                )
            ),
            destination: MIDIPort(
                id: destinationPortID,
                label: "SelfTest Destination",
                kind: .system,
                destination: EndpointInfo(
                    uniqueID: destinationID,
                    name: "SelfTest Destination",
                    displayName: "SelfTest Destination",
                    endpoint: testDestination,
                    isSource: false,
                    deviceName: "SelfTest",
                    entityName: "SelfTest",
                    offline: false,
                    kind: .system
                )
            )
        )

        // The route is the real proof that registration succeeded: the engine
        // only fans a message out to destinations it knows about. The published
        // `ports` array is updated on the main queue, so it is checked separately
        // with an explicit wait rather than assumed to be immediate.
        engine.addRoute(from: sourcePortID, to: destinationPortID)
        harness.check("route was created", engine.hasActiveRoute(from: sourcePortID, to: destinationPortID))
        harness.check("registered ports were published to the UI table",
                      waitUntil(1) { engine.ports.contains { $0.id == sourcePortID }
                          && engine.ports.contains { $0.id == destinationPortID } },
                      detail: "table has \(engine.ports.count) ports")

        // --- Plain routing ---
        Capture.shared.reset()
        engine.injectForTesting(bytes: [0x90, 60, 100], fromPort: sourcePortID)
        // Drain the work queue so every counter below reflects this message.
        engine.synchronizeForTesting()
        waitUntil(2) { !Capture.shared.messages.isEmpty }

        harness.check("a routed message reached the destination",
                      !Capture.shared.messages.isEmpty,
                      detail: Capture.shared.messages.isEmpty ? "nothing arrived" : "")
        harness.check("the routed message arrived intact",
                      Capture.shared.messages.first?.bytes == [0x90, 60, 100],
                      detail: "got \(Capture.shared.messages.first?.bytes ?? [])")

        waitUntil(0.5) { (engine.portStats[sourcePortID]?.messageCount ?? 0) >= 1 }
        harness.check("source statistics counted the traffic",
                      (engine.portStats[sourcePortID]?.messageCount ?? 0) >= 1,
                      detail: "count \(engine.portStats[sourcePortID]?.messageCount ?? 0)")

        // Read the authoritative counters rather than the 20 Hz UI snapshot, so
        // this measures the engine and not the publish timer's phase.
        let destinationStats = engine.liveStats(for: destinationPortID)
        harness.check("destination statistics counted the routed traffic",
                      destinationStats.messageCount >= 1,
                      detail: "count \(destinationStats.messageCount), "
                        + "direction \(destinationStats.noteOnCount) note-ons")

        // --- Channel filtering ---
        Capture.shared.reset()
        var strict = engine.route(from: sourcePortID, to: destinationPortID)!
        strict.channels = ChannelMask(rawValue: 1 << 15)   // channel 16 only
        engine.updateRoute(strict)
        engine.injectForTesting(bytes: [0x90, 62, 100], fromPort: sourcePortID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        harness.check("a channel-filtered route blocks the message",
                      Capture.shared.messages.isEmpty,
                      detail: "got \(Capture.shared.messages.map(\.bytes))")

        // --- Transform on the way out ---
        Capture.shared.reset()
        var transposing = engine.route(from: sourcePortID, to: destinationPortID)!
        transposing.channels = .all
        transposing.transform.transpose = 12
        engine.updateRoute(transposing)
        engine.injectForTesting(bytes: [0x90, 60, 100], fromPort: sourcePortID)
        waitUntil(2) { !Capture.shared.messages.isEmpty }
        harness.check("the transform was applied on the way out",
                      Capture.shared.messages.first?.bytes == [0x90, 72, 100],
                      detail: "got \(Capture.shared.messages.map(\.bytes))")

        // --- Monitor log ---
        waitUntil(0.5) { !engine.monitorEvents.isEmpty }
        harness.check("the monitor log captured events", !engine.monitorEvents.isEmpty,
                      detail: "\(engine.monitorEvents.count) events")

        // --- Removal ---
        Capture.shared.reset()
        engine.removeRoutes(from: sourcePortID, to: destinationPortID)
        engine.injectForTesting(bytes: [0x90, 60, 100], fromPort: sourcePortID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        harness.check("removing the route stops delivery",
                      Capture.shared.messages.isEmpty,
                      detail: "got \(Capture.shared.messages.map(\.bytes))")

        // --- The app's own published virtual endpoints ---
        harness.check("engine published its virtual output",
                      MIDIGetNumberOfSources() > 0)
        let publishedNames = (0..<MIDIGetNumberOfSources()).map {
            MIDIObject.name(MIDIGetSource($0))
        }
        harness.check("virtual output is visible to other applications",
                      publishedNames.contains { $0.contains("Control Centre") },
                      detail: "sources: \(publishedNames.filter { $0.contains("Control") })")

        // --- Malformed data must not crash or be counted as a message ---
        //
        // Running status is live at this point, because real messages have been
        // through this parser. A bare data byte would legitimately continue the
        // previous status, so the parser is reset first to test the genuinely
        // malformed case: data with no status byte at all.
        engine.resetParserForTesting(port: sourcePortID)
        engine.synchronizeForTesting()
        let before = engine.liveStats(for: sourcePortID)
        engine.injectForTesting(bytes: [0x40, 0x41, 0x42], fromPort: sourcePortID)
        engine.synchronizeForTesting()
        let afterStats = engine.liveStats(for: sourcePortID)
        harness.check("malformed data is counted as an anomaly, not a message",
                      afterStats.messageCount == before.messageCount,
                      detail: "before \(before.messageCount), after \(afterStats.messageCount)")
        harness.check("malformed data was recorded as an anomaly",
                      afterStats.anomalyCount > before.anomalyCount,
                      detail: "before \(before.anomalyCount), after \(afterStats.anomalyCount)")

        MIDIClientDispose(listener)
        MIDIClientDispose(client)
        engine.stop()
    }
}
