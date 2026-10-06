import Foundation

// MARK: - Message

/// A single decoded MIDI message.
///
/// `timestamp` is a CoreMIDI host-time value (mach absolute time domain) when
/// the message arrived, or `0` for messages we synthesised.
public struct MIDIMessage: Hashable, Sendable {
    public var bytes: [UInt8]
    public var timestamp: UInt64

    public init(bytes: [UInt8], timestamp: UInt64 = 0) {
        self.bytes = bytes
        self.timestamp = timestamp
    }

    public var status: UInt8 { bytes.first ?? 0 }
    public var statusNibble: UInt8 { (bytes.first ?? 0) & 0xF0 }
    public var channel: UInt8 { (bytes.first ?? 0) & 0x0F }
    /// 1-based channel number, the way musicians count.
    public var channelNumber: Int { Int(channel) + 1 }
    public var data1: UInt8 { bytes.count > 1 ? bytes[1] : 0 }
    public var data2: UInt8 { bytes.count > 2 ? bytes[2] : 0 }

    public var isSystemExclusive: Bool { status == 0xF0 }
    public var isSystemRealTime: Bool { status >= 0xF8 }
    public var isSystemCommon: Bool { status >= 0xF0 && status < 0xF8 }

    /// `false` when the message carries no channel (system messages).
    public var isChannelMessage: Bool { status >= 0x80 && status < 0xF0 }

    /// A short human-readable summary, e.g. "Note On C4 vel 100 ch 1".
    public var summary: String {
        guard !bytes.isEmpty else { return "<empty>" }
        switch statusNibble {
        case 0x80:
            return "Note Off \(MIDIMessage.noteName(data1)) vel \(data2) ch \(channelNumber)"
        case 0x90:
            return data2 == 0
                ? "Note Off \(MIDIMessage.noteName(data1)) vel 0 ch \(channelNumber)"
                : "Note On \(MIDIMessage.noteName(data1)) vel \(data2) ch \(channelNumber)"
        case 0xA0:
            return "Poly Aftertouch \(MIDIMessage.noteName(data1)) \(data2) ch \(channelNumber)"
        case 0xB0:
            return "CC \(data1) \(data2) ch \(channelNumber)"
        case 0xC0:
            return "Program \(data1) ch \(channelNumber)"
        case 0xD0:
            return "Aftertouch \(data1) ch \(channelNumber)"
        case 0xE0:
            let value = Int(data1) | (Int(data2) << 7)
            return "Pitch Bend \((value - 8192).signum() >= 0 ? "+" : "")\(value - 8192) ch \(channelNumber)"
        case 0xF0:
            switch status {
            case 0xF0:
                let payload = bytes.dropFirst().dropLast(bytes.last == 0xF7 ? 1 : 0)
                let hex = payload.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
                let suffix = payload.count > 12 ? " … (\(payload.count) bytes)" : ""
                return "SysEx \(hex)\(suffix)"
            case 0xF1: return "MTC Quarter Frame \(data1)"
            case 0xF2: return "Song Position \(Int(data1) | (Int(data2) << 7))"
            case 0xF3: return "Song Select \(data1)"
            case 0xF6: return "Tune Request"
            case 0xF8: return "Clock"
            case 0xFA: return "Start"
            case 0xFB: return "Continue"
            case 0xFC: return "Stop"
            case 0xFE: return "Active Sensing"
            case 0xFF: return "System Reset"
            default: return "System \(String(format: "%02X", status))"
            }
        default:
            return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    /// Scientific pitch notation for a MIDI note number (60 = C4).
    public static func noteName(_ note: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let n = Int(note)
        return "\(names[((n % 12) + 12) % 12])\(n / 12 - 1)"
    }
}

// MARK: - Parser

/// An incremental MIDI byte-stream parser.
///
/// CoreMIDI hands us `MIDIPacket`s, and a single logical MIDI message can be
/// split across packet boundaries — and worse, a packet can contain a partial
/// message, several messages, or a SysEx continuation. This type accepts
/// arbitrary byte runs and emits whole messages, so the rest of the app never
/// has to think about framing.
///
/// Handles:
///   * running status (a data byte stream continuing the previous status)
///   * system real-time bytes interleaved inside other messages
///   * SysEx spanning many packets
///   * oversized/malformed data, reported rather than silently dropped
public final class MIDIByteStreamParser {
    /// Set when we see something the MIDI spec does not allow.
    public struct Anomaly: Sendable {
        public enum Kind: Sendable {
            /// A data byte arrived with no preceding status byte.
            case dataWithoutStatus
            /// SysEx exceeded `maxSysExBytes` and was abandoned.
            case sysExOverflow(limit: Int)
            /// A SysEx message ended with something other than 0xF7.
            case sysExAbandoned
        }
        public let kind: Kind
        public let timestamp: UInt64
    }

    private var runningStatus: UInt8 = 0
    private var buffer: [UInt8] = []
    private var expectedLength = 0
    private var inSysEx = false

    /// Guard against a stuck SysEx stream eating all memory.
    public let maxSysExBytes: Int

    public init(maxSysExBytes: Int = 1 << 20) {
        self.maxSysExBytes = maxSysExBytes
    }

    /// Number of bytes currently held back waiting for more data.
    public var pendingByteCount: Int { buffer.count }

    public func reset() {
        runningStatus = 0
        buffer.removeAll(keepingCapacity: true)
        expectedLength = 0
        inSysEx = false
    }

    /// Feed a chunk of raw MIDI bytes and receive every complete message it contains.
    public func parse(_ data: some Sequence<UInt8>, timestamp: UInt64) -> (messages: [MIDIMessage], anomalies: [Anomaly]) {
        var messages: [MIDIMessage] = []
        var anomalies: [Anomaly] = []

        for byte in data {
            if byte & 0x80 != 0 {
                // ---- Status byte ----
                if byte >= 0xF8 {
                    // System real-time may appear anywhere, including mid-message,
                    // and never disturbs running status or the pending buffer.
                    messages.append(MIDIMessage(bytes: [byte], timestamp: timestamp))
                    continue
                }

                if byte == 0xF7 {
                    // End of Exclusive. The terminator is part of the message, so
                    // it is appended to whatever is already buffered rather than
                    // starting a new message.
                    if buffer.first == 0xF0, inSysEx {
                        buffer.append(byte)
                        messages.append(MIDIMessage(bytes: buffer, timestamp: timestamp))
                    } else {
                        messages.append(MIDIMessage(bytes: [byte], timestamp: timestamp))
                    }
                    buffer.removeAll(keepingCapacity: true)
                    expectedLength = 0
                    inSysEx = false
                    runningStatus = 0
                    continue
                }

                if inSysEx {
                    // Any other status byte terminates a SysEx that was never
                    // closed, which is a real protocol error worth reporting.
                    anomalies.append(Anomaly(kind: .sysExAbandoned, timestamp: timestamp))
                    messages.append(MIDIMessage(bytes: buffer, timestamp: timestamp))
                    inSysEx = false
                }

                // A new status byte discards any partially collected message.
                buffer.removeAll(keepingCapacity: true)
                expectedLength = 0

                switch byte {
                case 0xF0:
                    inSysEx = true
                    buffer.append(byte)
                case 0xF1, 0xF3:
                    runningStatus = 0
                    buffer.append(byte)
                    expectedLength = 2
                case 0xF2:
                    runningStatus = 0
                    buffer.append(byte)
                    expectedLength = 3
                case 0xF4, 0xF5, 0xF6:
                    // Undefined system common (F4, F5) and Tune Request (F6):
                    // no data bytes, passed through as-is.
                    runningStatus = 0
                    messages.append(MIDIMessage(bytes: [byte], timestamp: timestamp))
                default:
                    // Channel voice message: becomes the new running status.
                    runningStatus = byte
                    buffer.append(byte)
                    expectedLength = Self.length(forStatus: byte)
                }
                continue
            }

            // ---- Data byte (bit 7 clear) ----
            if inSysEx {
                buffer.append(byte)
                if buffer.count > maxSysExBytes {
                    anomalies.append(Anomaly(kind: .sysExOverflow(limit: maxSysExBytes), timestamp: timestamp))
                    buffer.removeAll(keepingCapacity: true)
                    inSysEx = false
                }
                continue
            }

            if buffer.isEmpty {
                // Running status: reuse the previous channel status byte.
                guard runningStatus != 0 else {
                    anomalies.append(Anomaly(kind: .dataWithoutStatus, timestamp: timestamp))
                    continue
                }
                buffer.append(runningStatus)
                expectedLength = Self.length(forStatus: runningStatus)
            }

            buffer.append(byte)
            // `expectedLength` is 0 while a SysEx is in progress; that stream is
            // terminated only by 0xF7, never by a byte count.
            if expectedLength > 0, buffer.count >= expectedLength {
                messages.append(MIDIMessage(bytes: buffer, timestamp: timestamp))
                let status = buffer[0]
                buffer.removeAll(keepingCapacity: true)
                expectedLength = 0
                // Running status persists after a complete channel message.
                runningStatus = status
            }
        }

        return (messages, anomalies)
    }

    /// Total byte length of a channel voice message including its status byte.
    private static func length(forStatus status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 2   // Program Change, Channel Aftertouch
        default: return 3           // Note On/Off, Poly AT, CC, Pitch Bend
        }
    }
}
