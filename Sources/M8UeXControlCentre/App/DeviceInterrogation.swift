import Foundation
import CoreMIDI

// MARK: - Device interrogation

/// Asks the connected interfaces whether they implement any MIDI SysEx, and
/// reports what they say.
///
/// This answers one specific question, safely: **does the M8U eX / M4U eX have a
/// SysEx implementation at all?** A device that answers a MIDI Identity Request
/// has a SysEx engine and is worth investigating further for a configuration
/// protocol. A device that stays silent is strong evidence that its standalone
/// routing is fixed in firmware with no exposed programming path.
///
/// Everything here is **read-only**. It sends only the standard Universal
/// Non-Real Time Identity Request (`F0 7E <device> 06 01 F7`) and listens. It
/// never writes configuration, never sends a dump, and never guesses at a
/// protocol. That restraint is deliberate: an undocumented write command sent to
/// a device whose config format is unknown is how hardware ends up in a state
/// nobody can explain.
///
/// ### A physical caveat that matters
///
/// MIDI DIN cables are one-directional. An Identity Request leaves through an
/// **output** socket, so the interface can only answer if that signal somehow
/// arrives at one of its **input** sockets — which needs a cable loop
/// (out 1 → in 1) or an external device that forwards it. Silence therefore does
/// not by itself prove the device lacks SysEx; it may simply have nowhere to
/// reply to. The tool reports exactly this distinction instead of overclaiming.
///
/// Run as `M8U eX Control Centre --interrogate`.
enum DeviceInterrogation {

    /// Universal Non-Real Time SysEx: Identity Request, to all devices.
    private static let identityRequest: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]

    static func run() -> Int32 {
        print("M8U eX Control Centre — device interrogation")
        print(String(repeating: "=", count: 70))
        print("Read-only. Sends only the standard MIDI Identity Request; writes nothing.")
        print("")

        let ports = MIDIEndpointEnumerator.m8uPorts()
        guard !ports.isEmpty else {
            print("No M8U/M4U eX interface found. Connect one and try again.")
            return 1
        }

        // Group by interface so the output reads per unit.
        var byUnit: [MIDIUniqueID: [MIDIPort]] = [:]
        var unitOrder: [MIDIUniqueID] = []
        for port in ports {
            guard let uid = port.id.deviceUID else { continue }
            if byUnit[uid] == nil { unitOrder.append(uid) }
            byUnit[uid, default: []].append(port)
        }

        for uid in unitOrder {
            guard let sockets = byUnit[uid] else { continue }
            let name = sockets.first?.id.unitName ?? "unknown"
            let destinations = sockets.filter { $0.destination != nil }
            let sources = sockets.filter { $0.source != nil }

            print("INTERFACE  \(name)")
            print("  deviceUID           \(uid)")
            print("  sockets with output \(destinations.count)")
            print("  sockets with input  \(sources.count)")
            print("")

            if destinations.isEmpty {
                print("  This interface exposes no outputs, so nothing can be asked of it.")
                print("")
                continue
            }

            interrogate(name: name, destinations: destinations, sources: sources)
        }

        print(String(repeating: "=", count: 70))
        print("")
        print("HOW TO READ THIS")
        print("  A reply means the interface has a SysEx engine, and is worth pursuing")
        print("  for a configuration protocol.")
        print("")
        print("  Silence means one of two things, and this tool cannot tell them apart")
        print("  on its own, because MIDI DIN cables only carry data one way:")
        print("    1. The interface has no SysEx implementation.")
        print("    2. It replied, but there was no path back to the computer.")
        print("")
        print("  To distinguish them, patch a MIDI cable from an output socket back to an")
        print("  input socket on the same unit (for example out 1 -> in 1) and run this")
        print("  again. If a reply appears, path 2 was the answer and the device does")
        print("  implement SysEx. If it is still silent with a loop in place, the device")
        print("  almost certainly has no configuration protocol at all.")
        print("")
        return 0
    }

    // MARK: Interrogation of one interface

    private static func interrogate(
        name: String,
        destinations: [MIDIPort],
        sources: [MIDIPort]
    ) {
        // A client of our own, so this does not disturb the running app's state.
        var client = MIDIClientRef(0)
        let clientStatus = MIDIClientCreateWithBlock("M8U eX Interrogation" as CFString, &client, nil)
        guard clientStatus == noErr else {
            print("  Could not create a CoreMIDI client (error \(clientStatus)).")
            return
        }
        defer { MIDIClientDispose(client) }

        var inputPort = MIDIPortRef(0)
        let inputStatus = MIDIInputPortCreateWithBlock(client, "Interrogation Input" as CFString, &inputPort) {
            packetList, _ in
            // Anything arriving while we listen is potentially a reply.
            let parser = MIDIByteStreamParser()
            for chunk in MIDIPacketBridge.drain(packetList: packetList) {
                for message in parser.parse(chunk.bytes, timestamp: chunk.timestamp).messages {
                    ReplyLog.shared.record(message)
                }
            }
        }
        guard inputStatus == noErr else {
            print("  Could not create an input port (error \(inputStatus)).")
            return
        }

        var outputPort = MIDIPortRef(0)
        let outputStatus = MIDIOutputPortCreate(client, "Interrogation Output" as CFString, &outputPort)
        guard outputStatus == noErr else {
            print("  Could not create an output port (error \(outputStatus)).")
            return
        }

        // Listen to every input socket of this interface.
        for port in sources {
            guard let source = port.source else { continue }
            MIDIPortConnectSource(inputPort, source.endpoint, nil)
        }

        print("  Listening on \(sources.count) input sockets.")
        print("  Sending Identity Request to each output socket...")
        print("")

        let requestHex = identityRequest.map { String(format: "%02X", $0) }.joined(separator: " ")
        var anyReply = false
        var anyBusy = false

        for port in destinations {
            guard let destination = port.destination else { continue }
            ReplyLog.shared.reset()
            // Repeat the request: a single identity request is easy to miss if the
            // unit is busy, and repetition costs nothing.
            for _ in 0..<3 {
                MIDIPacketBridge.send(bytes: identityRequest, to: destination.endpoint, via: outputPort)
                Thread.sleep(forTimeInterval: 0.25)
            }

            // Give the device time to answer, and the reply time to travel.
            Thread.sleep(forTimeInterval: 0.75)

            let captured = ReplyLog.shared.messages
            // Only a SysEx message can be an Identity Reply. Anything else on the
            // wire is ordinary traffic from whatever is patched to that socket,
            // and must not be mistaken for the interface answering.
            let sysEx = captured.filter { $0.isSystemExclusive }
            let other = captured.count - sysEx.count
            let socketLabel = (port.m8uIndex.map { "socket \($0)" } ?? port.label)
                .padding(toLength: 12, withPad: " ", startingAt: 0)

            if !sysEx.isEmpty {
                anyReply = true
                print("  \(socketLabel) SYSEX REPLY")
                for message in sysEx {
                    let hex = message.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("        \(hex)")
                    if let decoded = decodeIdentityReply(message.bytes) {
                        print("        → IDENTITY REPLY: \(decoded)")
                    } else if message.bytes == identityRequest {
                        print("        → this is our own request echoed back by a cable loop,")
                        print("          not a reply from the interface")
                    } else {
                        print("        → SysEx, but not a standard Identity Reply")
                    }
                }
                if other > 0 {
                    print("        (\(other) non-SysEx messages also seen on this socket)")
                }
            } else if other > 0 {
                anyBusy = true
                print("  \(socketLabel) no SysEx  —  \(other) other MIDI messages (\(summarise(captured)))")
                // Always show the raw bytes. A single unexplained message is the
                // most informative thing this tool can produce, and hiding it
                // behind a category label is how a real clue gets missed.
                for message in captured.prefix(8) {
                    let hex = message.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("        \(hex)   [\(describeStatus(message))]")
                }
                if captured.count > 8 {
                    print("        … and \(captured.count - 8) more")
                }
            } else {
                print("  \(socketLabel) silent")
            }
        }

        print("")
        print("  Request sent: \(requestHex)")
        print("")

        // Report a conclusion scoped to what this test can actually establish.
        if anyReply {
            print("  RESULT: the interface returned SysEx that is NOT merely our own request")
            print("          echoed back. It has a SysEx implementation, so a configuration")
            print("          protocol is worth pursuing — and a dump/restore tool becomes viable.")
        } else {
            if anyBusy {
                print("  RESULT: no SysEx reply. Some sockets carried ordinary MIDI traffic,")
                print("          which is other equipment, not the interface answering.")
            } else {
                print("  RESULT: no SysEx reply and no other traffic on any socket.")
            }
            print("")
            print("          This is NOT yet proof that the interface lacks SysEx, because an")
            print("          Identity Request leaves through an output socket and MIDI DIN")
            print("          cables only carry data one way. Patch a cable from output 1 back")
            print("          to input 1 on the same unit and run this again: if a reply")
            print("          appears, the interface does implement SysEx. If it is still")
            print("          silent with a loop in place, it almost certainly has none.")
        }
        print("")

        MIDIPortDisconnectSource(inputPort, 0)
    }

    /// A precise description of a message's status byte.
    ///
    /// Deliberately more granular than the summary, because the difference
    /// between "System Reset", "something system-common" and "an undefined
    /// status byte" is exactly what matters when diagnosing an unknown reply.
    private static func describeStatus(_ message: MIDIMessage) -> String {
        guard let status = message.bytes.first else { return "empty" }
        if status < 0x80 {
            return String(format: "data byte 0x%02X with no status (malformed)", status)
        }
        switch status {
        case 0xF0: return "SysEx"
        case 0xF1: return "MTC quarter frame"
        case 0xF2: return "song position"
        case 0xF3: return "song select"
        case 0xF4: return "undefined system common 0xF4"
        case 0xF5: return "undefined system common 0xF5"
        case 0xF6: return "tune request"
        case 0xF7: return "end of exclusive"
        case 0xF8: return "timing clock"
        case 0xF9: return "undefined system realtime 0xF9"
        case 0xFA: return "start"
        case 0xFB: return "continue"
        case 0xFC: return "stop"
        case 0xFD: return "undefined system realtime 0xFD"
        case 0xFE: return "active sensing"
        case 0xFF: return "system reset"
        default:
            switch status & 0xF0 {
            case 0x80: return "note off ch \(message.channelNumber)"
            case 0x90: return "note on ch \(message.channelNumber)"
            case 0xA0: return "poly aftertouch ch \(message.channelNumber)"
            case 0xB0: return "control change ch \(message.channelNumber)"
            case 0xC0: return "program change ch \(message.channelNumber)"
            case 0xD0: return "channel aftertouch ch \(message.channelNumber)"
            case 0xE0: return "pitch bend ch \(message.channelNumber)"
            default: return String(format: "unknown status 0x%02X", status)
            }
        }
    }

    /// A short description of what kinds of message were seen, so busy sockets are
    /// reported as "this is your sequencer" rather than implying a reply.
    private static func summarise(_ messages: [MIDIMessage]) -> String {
        var clock = 0
        var notes = 0
        var controlChanges = 0
        var other = 0
        for message in messages {
            switch message.status {
            case 0xF8, 0xFA, 0xFB, 0xFC, 0xFE: clock += 1
            case let status where status & 0xF0 == 0x90 || status & 0xF0 == 0x80: notes += 1
            case let status where status & 0xF0 == 0xB0: controlChanges += 1
            default: other += 1
            }
        }
        var parts: [String] = []
        if clock > 0 { parts.append("\(clock) clock/transport") }
        if notes > 0 { parts.append("\(notes) notes") }
        if controlChanges > 0 { parts.append("\(controlChanges) CC") }
        if other > 0 { parts.append("\(other) other") }
        return parts.joined(separator: ", ")
    }

    // MARK: Identity Reply decoding

    /// Decodes a Universal Identity Reply (`F0 7E <dev> 06 02 ... F7`).
    ///
    /// The payload is: manufacturer ID (1 or 3 bytes), family, member, and four
    /// version bytes. Reading it tells us the vendor, model family and firmware
    /// revision the device reports — useful context if we later go looking for a
    /// programming protocol.
    private static func decodeIdentityReply(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 15,
              bytes[0] == 0xF0,
              bytes[1] == 0x7E,
              bytes[3] == 0x06,
              bytes[4] == 0x02 else { return nil }

        var index = 5
        var manufacturer: String
        if bytes[index] == 0x00 {
            guard bytes.count > index + 2 else { return nil }
            manufacturer = String(format: "0x%02X 0x%02X 0x%02X",
                                  bytes[index], bytes[index + 1], bytes[index + 2])
            index += 3
        } else {
            manufacturer = String(format: "0x%02X", bytes[index])
            index += 1
        }

        guard bytes.count >= index + 8 else { return nil }
        let family = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
        let member = UInt16(bytes[index + 2]) << 8 | UInt16(bytes[index + 3])
        let version = bytes[(index + 4)...(index + 7)]
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")

        return "manufacturer \(manufacturer), family 0x\(String(format: "%04X", family)), "
            + "member 0x\(String(format: "%04X", member)), version \(version)"
    }

    /// Collects replies seen while listening.
    final class ReplyLog {
        static let shared = ReplyLog()
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
}
