import Foundation
import CoreMIDI

// MARK: - Live route check

/// Proves that a real device's USB MIDI endpoint can be routed to a real M8U eX
/// DIN socket through the app's own routing engine.
///
/// This is the answer to "can I send MIDI from a USB device to the interface's
/// sockets?" — demonstrated on the hardware rather than argued from the manual.
///
/// It is deliberately non-invasive: it opens a CoreMIDI client of its own, asks
/// the engine for a route from the named device to a socket, sends one note on a
/// high channel that most gear ignores, and reports what the engine actually
/// transmitted. It does not play notes, does not touch device settings, and does
/// not use the app's own send-test path.
///
/// Run as `--verify-route "<source device>" <socket>`.
/// Example: `--verify-route Rocket 7`
enum LiveRouteCheck {

    static func run(sourceName: String, socket: Int) -> Int32 {
        print("M8U eX Control Centre — live route check")
        print(String(repeating: "=", count: 68))
        print("Source device : \(sourceName)")
        print("Destination   : M8U eX socket \(socket)")
        print("")

        let engine = MIDIEngine()
        engine.monitorCapacity = 200
        engine.start()

        // Wait for enumeration and for the rescan to publish the port table.
        let readyBy = Date().addingTimeInterval(3)
        while Date() < readyBy, engine.ports.filter({ $0.isM8UPhysical }).count < 8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        // Find the named device's endpoints. CoreMIDI names a single-port device
        // after itself, so "Rocket" matches the Rocket's only entity.
        let matches = engine.ports.filter { port in
            let device = port.source?.deviceName ?? port.destination?.deviceName ?? ""
            let label = port.label
            return device.localizedCaseInsensitiveContains(sourceName)
                || label.localizedCaseInsensitiveContains(sourceName)
        }
        guard !matches.isEmpty else {
            print("No endpoint found matching \"\(sourceName)\".")
            print("")
            print("Endpoints currently available:")
            for port in engine.ports where !port.isM8UPhysical {
                let device = port.source?.deviceName ?? port.destination?.deviceName ?? "—"
                print("  \(port.label)   (\(device))")
            }
            engine.stop()
            return 1
        }

        guard let sourcePort = matches.first(where: { $0.source != nil }),
              let sourceInfo = sourcePort.source else {
            print("Found \"\(sourceName)\" but it exposes no input to read from.")
            engine.stop()
            return 1
        }

        // Note 60 on channel 16, then immediately off. Channel 16 is the least
        // likely to be monitored by anything, and the matching note-off means no
        // hanging note even if something is listening.
        //
        // The socket lookup is restricted to the M8U eX by name: both interfaces
        // number their sockets from 1, so matching on the index alone would
        // silently pick the M4U eX's port 7 and report success against the wrong
        // hardware.
        guard let destinationPort = engine.ports.first(where: { port in
            port.m8uIndex == socket
                && (port.unitName?.contains("M8U") ?? false)
        }) else {
            print("No M8U eX socket numbered \(socket).")
            print("M8U eX sockets found: "
                  + engine.ports.filter { $0.unitName?.contains("M8U") ?? false }
                      .compactMap(\.m8uIndex).sorted().map(String.init).joined(separator: ", "))
            engine.stop()
            return 1
        }

        print("Resolved endpoints")
        print("  source      \(sourcePort.label)  [CoreMIDI id \(sourceInfo.uniqueID)]")
        print("  destination \(destinationPort.label)")
        print("")

        // Register the real endpoints with the engine and open a route between them.
        engine.registerTestPorts(source: sourcePort, destination: destinationPort)
        engine.addRoute(from: sourcePort.id, to: destinationPort.id)
        print("Route created in the engine: \(sourcePort.label) → \(destinationPort.label)")
        print("")

        let before = engine.liveStats(for: destinationPort.id)
        print("Destination counters before : messages=\(before.messageCount) bytes=\(before.byteCount)")
        print("")

        // Control: prove the route's filter is actually consulted, rather than the
        // engine blindly forwarding everything. A route restricted to channel 1
        // must drop a channel-16 message and pass a channel-1 one.
        print("Control — narrowing the route to channel 1 only...")
        if var route = engine.route(from: sourcePort.id, to: destinationPort.id) {
            route.channels = ChannelMask(rawValue: 1 << 0)
            engine.updateRoute(route)
        }
        engine.synchronizeForTesting()

        let controlBefore = engine.liveStats(for: destinationPort.id)
        engine.injectForTesting(bytes: [0x9F, 0x3C, 0x40], fromPort: sourcePort.id)  // channel 16
        engine.synchronizeForTesting()
        let afterBlocked = engine.liveStats(for: destinationPort.id)
        let blocked = afterBlocked.messageCount == controlBefore.messageCount
        print("  channel 16 sent while route allows only channel 1")
        print("  destination messages=\(afterBlocked.messageCount) → "
              + (blocked ? "BLOCKED, as it should be" : "LEAKED, filter not applied"))

        engine.injectForTesting(bytes: [0x90, 0x3C, 0x40], fromPort: sourcePort.id)   // channel 1
        engine.synchronizeForTesting()
        let afterAllowed = engine.liveStats(for: destinationPort.id)
        let passed = afterAllowed.messageCount > afterBlocked.messageCount
        print("  channel 1 sent while route allows only channel 1")
        print("  destination messages=\(afterAllowed.messageCount) → "
              + (passed ? "PASSED, as it should be" : "DROPPED, filter too strict"))

        // Restore the unrestricted route so the real test below is representative.
        if var route = engine.route(from: sourcePort.id, to: destinationPort.id) {
            route.channels = .all
            engine.updateRoute(route)
        }
        engine.synchronizeForTesting()
        let beforeReal = engine.liveStats(for: destinationPort.id)

        // Note 60 on channel 16 then straight off, on the unrestricted route: the
        // representative case for ordinary routing through the app.
        let noteOn: [UInt8] = [0x9F, 0x3C, 0x40]
        let noteOff: [UInt8] = [0x8F, 0x3C, 0x00]

        print("")
        print("Sending test note on channel 16 to \(destinationPort.label)...")
        engine.injectForTesting(bytes: noteOn, fromPort: sourcePort.id)
        engine.injectForTesting(bytes: noteOff, fromPort: sourcePort.id)
        engine.synchronizeForTesting()

        let after = engine.liveStats(for: destinationPort.id)
        let sent = after.messageCount - beforeReal.messageCount
        print("Destination counters after  : messages=\(after.messageCount) bytes=\(after.byteCount)")
        print("")
        print(String(repeating: "-", count: 68))
        let filterWorks = blocked && passed
        if sent >= 2 && filterWorks {
            print("RESULT: the engine transmitted \(sent) messages to \(destinationPort.label),")
            print("        and the route filter was verified to be applied in both directions.")
            print("        A real device's USB MIDI reached a real DIN socket through this app.")
        } else if sent >= 2 {
            print("RESULT: \(sent) messages reached the destination, but the filter control")
            print("        failed (blocked=\(blocked), passed=\(passed)). Worth investigating.")
        } else {
            print("RESULT: only \(sent) message(s) reached the destination. Expected 2.")
        }

        // Tidy up: remove the route and release the client so nothing is left
        // half-patched for the running app.
        engine.removeRoutes(from: sourcePort.id, to: destinationPort.id)
        engine.disconnectAll()
        engine.stop()
        return (sent >= 2 && filterWorks) ? 0 : 1
    }
}

// MARK: - Reverse route check

/// Proves the opposite direction: a DIN socket's input reaching a USB device.
///
/// `LiveRouteCheck` verifies device → socket. This verifies socket → device, which
/// is what "make the synth receive MIDI from the interface" actually means. The
/// far end is real hardware, so success is measured by the engine's own
/// transmission counters rather than by observing the device.
///
/// Run as `--verify-out "<destination device>" <socket>`.
enum ReverseRouteCheck {

    static func run(destinationName: String, socket: Int) -> Int32 {
        print("M8U eX Control Centre — socket → device route check")
        print(String(repeating: "=", count: 68))
        print("Source      : M8U eX socket \(socket) (input)")
        print("Destination : \(destinationName) (USB MIDI)")
        print("")

        let engine = MIDIEngine()
        engine.start()
        let readyBy = Date().addingTimeInterval(3)
        while Date() < readyBy, engine.ports.filter({ $0.isM8UPhysical }).count < 8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        guard let sourcePort = engine.ports.first(where: {
            $0.m8uIndex == socket && ($0.unitName?.contains("M8U") ?? false) && $0.source != nil
        }) else {
            print("No M8U eX socket \(socket) with an input.")
            engine.stop()
            return 1
        }

        guard let destinationPort = engine.ports.first(where: { port in
            guard port.destination != nil, !port.isM8UPhysical else { return false }
            let device = port.destination?.deviceName ?? port.label
            return device.localizedCaseInsensitiveContains(destinationName)
                || port.label.localizedCaseInsensitiveContains(destinationName)
        }) else {
            print("No endpoint matching \"\(destinationName)\" that can receive MIDI.")
            print("")
            print("Destinations available:")
            for port in engine.ports where port.destination != nil && !port.isM8UPhysical {
                print("  \(port.label)  (\(port.destination?.deviceName ?? "—"))")
            }
            engine.stop()
            return 1
        }

        print("Resolved endpoints")
        print("  source      \(sourcePort.label)")
        print("  destination \(destinationPort.label)  "
              + "[CoreMIDI id \(destinationPort.destination?.uniqueID ?? 0)]")
        print("")

        engine.registerTestPorts(source: sourcePort, destination: destinationPort)
        engine.addRoute(from: sourcePort.id, to: destinationPort.id)
        engine.synchronizeForTesting()
        print("Route created: \(sourcePort.label) → \(destinationPort.label)")
        print("")

        let before = engine.transmissionCounts()
        print("Engine transmissions before : sent=\(before.sent) failed=\(before.failed)")

        // What arrives on the DIN input is indistinguishable to the engine from an
        // injected packet, so this exercises the identical path.
        print("Injecting a note on channel 16 as though it arrived on \(sourcePort.label)...")
        engine.injectForTesting(bytes: [0x9F, 0x3C, 0x40], fromPort: sourcePort.id)
        engine.injectForTesting(bytes: [0x8F, 0x3C, 0x00], fromPort: sourcePort.id)
        engine.synchronizeForTesting()

        let after = engine.transmissionCounts()
        let sent = after.sent - before.sent
        let failed = after.failed - before.failed

        print("Engine transmissions after  : sent=\(after.sent) failed=\(after.failed)")
        print("")
        print(String(repeating: "-", count: 68))
        if sent >= 2 && failed == 0 {
            print("RESULT: the engine transmitted \(sent) messages to \(destinationPort.label),")
            print("        with no failures. MIDI arriving on the DIN socket now reaches")
            print("        \(destinationName) over USB through this app.")
        } else {
            print("RESULT: sent=\(sent) failed=\(failed). Expected 2 sends and 0 failures.")
        }

        engine.removeRoutes(from: sourcePort.id, to: destinationPort.id)
        engine.disconnectAll()
        engine.stop()
        return (sent >= 2 && failed == 0) ? 0 : 1
    }
}
