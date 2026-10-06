// m4usysex.swift — decisive SysEx test for the ESI M4U eX / M8U eX.
//
// Question: does either interface implement a SysEx configuration protocol?
//
// Method: send unmistakable SysEx payloads to each DIN output and record exactly
// what arrives on the DIN inputs, with correct reassembly of messages that span
// several CoreMIDI packets. On the M8U eX an earlier probe split each reply across
// two packets, which made an echoed request look like a bare F7 terminator — so
// this version concatenates bytes properly before drawing any conclusion.
//
// Interpretation:
//   * A full exact echo of what we sent  → we are seeing our own signal via a
//     cable loop, not a reply. The device added nothing.
//   * A different SysEx message          → the device implemented a reply. That is
//     the only outcome that would justify pursuing a configuration protocol.
//   * Earlier-and-shorter than expected  → truncation; investigate.
//
// This program writes nothing to the device. It sends only Identity Request and a
// non-commercial-ID test payload, both of which are inert.

import Foundation
import CoreMIDI

// MARK: - Message assembly

/// Reassembles SysEx across packets, which is the whole point of this probe.
final class SysExAssembler {
    private var buffer: [UInt8] = []
    private var pending: [UInt8] = []
    private let lock = NSLock()

    /// Completed SysEx messages, in arrival order.
    private(set) var messages: [[UInt8]] = []

    /// Raw packets as delivered, for transparency.
    private(set) var packets: [[UInt8]] = []

    func feed(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        packets.append(bytes)
        for byte in bytes {
            if byte & 0x80 != 0 {
                if byte == 0xF0 {
                    buffer = [0xF0]
                } else if byte == 0xF7 {
                    if !buffer.isEmpty {
                        buffer.append(0xF7)
                        messages.append(buffer)
                        buffer = []
                    } else {
                        messages.append([0xF7])
                    }
                } else if !buffer.isEmpty {
                    // A non-realtime status byte aborts an unterminated SysEx.
                    buffer = []
                }
            } else if !buffer.isEmpty {
                buffer.append(byte)
            }
        }
    }

    func reset() {
        lock.lock()
        buffer = []
        messages = []
        packets = []
        lock.unlock()
    }

    var allMessages: [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    var allPackets: [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return packets
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

// MARK: - Setup

var client = MIDIClientRef(0)
MIDIClientCreateWithBlock("M4U SysEx Test" as CFString, &client, nil)

let capture = SysExAssembler()
var inputPort = MIDIPortRef(0)
MIDIInputPortCreateWithBlock(client, "test in" as CFString, &inputPort) { list, _ in
    // Every packet, including split continuations, goes to the assembler.
    for chunk in drainPackets(list) {
        capture.feed(chunk)
    }
}

var outputPort = MIDIPortRef(0)
MIDIOutputPortCreate(client, "test out" as CFString, &outputPort)

/// Copies packets out of a MIDIPacketList without the app's bridge, so this tool
/// has no dependency on the project being present.
func drainPackets(_ list: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
    var result: [[UInt8]] = []
    var packet = list.pointee.packet
    for _ in 0..<list.pointee.numPackets {
        let n = Int(packet.length)
        if n > 0 {
            let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(n)) }
            result.append(bytes)
        }
        packet = MIDIPacketNext(&packet).pointee
    }
    return result
}

func send(_ bytes: [UInt8], to destination: MIDIEndpointRef) {
    var storage = [UInt8](repeating: 0, count: 512)
    storage.withUnsafeMutableBytes { raw in
        let list = raw.bindMemory(to: MIDIPacketList.self).baseAddress!
        let first = MIDIPacketListInit(list)
        _ = bytes.withUnsafeBufferPointer { buf in
            MIDIPacketListAdd(list, 512, first, 0, bytes.count, buf.baseAddress!)
        }
        MIDISend(outputPort, destination, list)
    }
}

// MARK: - Find the interfaces

/// Device name, plus each entity's name, so we can group ports by interface.
func deviceName(_ endpoint: MIDIEndpointRef) -> (device: String, entity: String) {
    var entity = MIDIObjectRef(0)
    guard MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0 else { return ("?", "?") }
    var dev = MIDIDeviceRef(0)
    var device = "?"
    if MIDIEntityGetDevice(MIDIEntityRef(entity), &dev) == noErr, dev != 0 {
        var n: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(dev, kMIDIPropertyName, &n)
        device = n?.takeRetainedValue() as String? ?? "?"
    }
    var en: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(entity, kMIDIPropertyName, &en)
    return (device, en?.takeRetainedValue() as String? ?? "?")
}

var sourcesByDevice: [String: [MIDIEndpointRef]] = [:]
for i in 0..<MIDIGetNumberOfSources() {
    let s = MIDIGetSource(i)
    let (dev, _) = deviceName(s)
    guard dev.contains("M4U") || dev.contains("M8U") else { continue }
    sourcesByDevice[dev, default: []].append(s)
}
var destinationsByDevice: [String: [(Int, MIDIEndpointRef)]] = [:]
for i in 0..<MIDIGetNumberOfDestinations() {
    let d = MIDIGetDestination(i)
    let (dev, entity) = deviceName(d)
    guard dev.contains("M4U") || dev.contains("M8U") else { continue }
    let index = Int(entity.replacingOccurrences(of: "Port ", with: "")) ?? 0
    destinationsByDevice[dev, default: []].append((index, d))
}

print("ESI interfaces detected:")
for (dev, dests) in destinationsByDevice.sorted(by: { $0.key < $1.key }) {
    print("  \(dev): \(dests.count) outputs, \(sourcesByDevice[dev]?.count ?? 0) inputs")
}
print("")

// MARK: - Test payloads

let identityRequest: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]
let probeA: [UInt8] = [0xF0, 0x7D, 0x11, 0x22, 0x33, 0xF7]
let probeB: [UInt8] = [0xF0, 0x7D] + Array(UInt8(0x40)...UInt8(0x4F)) + [0xF7]
let tests: [(String, [UInt8])] = [
    ("identity request", identityRequest),
    ("6-byte probe", probeA),
    ("18-byte probe", probeB),
]

for (dev, dests) in destinationsByDevice.sorted(by: { $0.key < $1.key }) {
    print(String(repeating: "=", count: 66))
    print("TESTING \(dev)")
    print(String(repeating: "=", count: 66))

    // Listen to this device's inputs.
    var connected = 0
    for s in sourcesByDevice[dev] ?? [] {
        if MIDIPortConnectSource(inputPort, s, nil) == noErr { connected += 1 }
    }
    print("listening on \(connected) inputs\n")

    var sawReply = false
    var sawEcho = false

    for (_, payload) in tests {
        for (index, dest) in dests.sorted(by: { $0.0 < $1.0 }) {
            capture.reset()
            send(payload, to: dest)
            Thread.sleep(forTimeInterval: 0.4)

            let got = capture.allMessages
            guard !got.isEmpty else { continue }

            print("send \(hex(payload))  to port \(index)")

            // Reassemble everything received in this window into one byte string,
            // because a single logical message may span several packets.
            let joined = got.flatMap { $0 }
            print("  received (reassembled): \(hex(joined))")
            for p in capture.allPackets { print("    packet: \(hex(p))") }

            if joined == payload {
                print("  → EXACT ECHO of what was sent. This is our own signal looping")
                print("    back through a cable, not a reply from the interface.")
                sawEcho = true
            } else if joined.contains(0x7E) && joined.count > 6 && joined[3] == 0x06 && joined[4] == 0x02 {
                print("  → *** IDENTITY REPLY ***  the interface implements SysEx!")
                sawReply = true
            } else if joined == [0xF7] {
                print("  → bare F7 only. Payload stripped: not a reply.")
            } else {
                print("  → different from what was sent, but not a standard reply.")
                sawReply = true
            }
            print("")
        }
    }

    if !sawReply && !sawEcho {
        print("RESULT: \(dev) returned nothing for any payload on any output.")
    } else if sawReply {
        print("RESULT: \(dev) produced a non-echo response — investigate further.")
    } else {
        print("RESULT: \(dev) only ever echoed what was sent. No SysEx implementation")
        print("        is in evidence: the interface adds nothing of its own.")
    }
    print("")
}

MIDIClientDispose(client)
