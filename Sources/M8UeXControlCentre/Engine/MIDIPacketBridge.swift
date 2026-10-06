import Foundation
import CoreMIDI

// MARK: - Packet bridge

/// One packet's bytes and timestamp, lifted out of a CoreMIDI packet list.
struct MIDIPacketChunk {
    var bytes: [UInt8]
    var timestamp: UInt64
}

/// Swift-facing wrapper over the C packet-list bridge.
///
/// The C layer exists so that the deprecated `MIDIPacketList` API is confined to
/// Objective-C (see `MIDIPacketIO.h` for the reasoning); this enum is the only
/// place the rest of the app touches it.
enum MIDIPacketBridge {

    /// Copies every packet out of a read block's packet list.
    ///
    /// Must be called synchronously inside the read block: the packet list is
    /// invalid once the block returns.
    static func drain(packetList: UnsafePointer<MIDIPacketList>) -> [MIDIPacketChunk] {
        let count = Int(M8UPacketFrameCount(packetList))
        guard count > 0 else { return [] }

        var frames = [M8UPacketFrame](repeating: M8UPacketFrame(), count: count)
        let written = Int(M8UCopyPacketFrames(packetList, &frames))
        guard written > 0 else { return [] }

        return frames.prefix(written).map { frame in
            let length = Int(frame.length)
            guard length > 0 else { return MIDIPacketChunk(bytes: [], timestamp: frame.timestamp) }
            let bytes = withUnsafeBytes(of: frame.bytes) { raw in
                Array(raw.prefix(length))
            }
            return MIDIPacketChunk(bytes: bytes, timestamp: frame.timestamp)
        }
        .filter { !$0.bytes.isEmpty }
    }

    /// Sends one MIDI 1.0 message to a real destination.
    /// - Parameter timestamp: host time, or 0 to send immediately.
    @discardableResult
    static func send(
        bytes: [UInt8],
        to destination: MIDIEndpointRef,
        via outputPort: MIDIPortRef,
        timestamp: UInt64 = 0
    ) -> OSStatus {
        guard !bytes.isEmpty, outputPort != 0, destination != 0 else { return -1 }
        return bytes.withUnsafeBufferPointer { pointer in
            M8USendMIDI1(outputPort, destination, pointer.baseAddress!, UInt(bytes.count), timestamp)
        }
    }

    /// Publishes a message from one of our virtual sources.
    @discardableResult
    static func publish(bytes: [UInt8], from source: MIDIEndpointRef) -> OSStatus {
        guard !bytes.isEmpty, source != 0 else { return -1 }
        return bytes.withUnsafeBufferPointer { pointer in
            M8UReceiveMIDI1(source, pointer.baseAddress!, UInt(bytes.count))
        }
    }
}
