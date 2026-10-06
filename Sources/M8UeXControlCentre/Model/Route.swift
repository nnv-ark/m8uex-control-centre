import Foundation

// MARK: - Channel set

/// A set of MIDI channels, stored compactly as a 16-bit mask.
/// Bit 0 = channel 1, bit 15 = channel 16.
public struct ChannelMask: Codable, Hashable, Sendable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// All 16 channels.
    public static let all = ChannelMask(rawValue: 0xFFFF)
    public static let none = ChannelMask(rawValue: 0)

    public func contains(channelIndex: Int) -> Bool {
        guard (0..<16).contains(channelIndex) else { return false }
        return rawValue & (1 << UInt16(channelIndex)) != 0
    }

    /// 1-based channel numbers currently included, for display.
    public var channelNumbers: [Int] {
        (0..<16).filter { contains(channelIndex: $0) }.map { $0 + 1 }
    }

    public var isEmpty: Bool { rawValue == 0 }

    public mutating func set(channelIndex: Int, _ included: Bool) {
        guard (0..<16).contains(channelIndex) else { return }
        if included {
            rawValue |= (1 << UInt16(channelIndex))
        } else {
            rawValue &= ~(1 << UInt16(channelIndex))
        }
    }

    /// "All channels" / "Ch 1, 3, 5" / "No channels"
    public var label: String {
        let numbers = channelNumbers
        if numbers.count == 16 { return "All channels" }
        if numbers.isEmpty { return "No channels" }
        if numbers.count <= 4 { return "Ch " + numbers.map(String.init).joined(separator: ", ") }
        return "\(numbers.count) channels"
    }
}

// MARK: - Message kinds

/// Which MIDI message categories a route lets through.
public struct MessageKindFilter: Codable, Hashable, Sendable {
    public var note: Bool
    public var polyAftertouch: Bool
    public var controlChange: Bool
    public var programChange: Bool
    public var channelAftertouch: Bool
    public var pitchBend: Bool
    public var clock: Bool
    public var transport: Bool
    public var systemExclusive: Bool
    public var songPosition: Bool
    public var otherSystemCommon: Bool

    public init(
        note: Bool = true,
        polyAftertouch: Bool = true,
        controlChange: Bool = true,
        programChange: Bool = true,
        channelAftertouch: Bool = true,
        pitchBend: Bool = true,
        clock: Bool = true,
        transport: Bool = true,
        systemExclusive: Bool = true,
        songPosition: Bool = true,
        otherSystemCommon: Bool = true
    ) {
        self.note = note
        self.polyAftertouch = polyAftertouch
        self.controlChange = controlChange
        self.programChange = programChange
        self.channelAftertouch = channelAftertouch
        self.pitchBend = pitchBend
        self.clock = clock
        self.transport = transport
        self.systemExclusive = systemExclusive
        self.songPosition = songPosition
        self.otherSystemCommon = otherSystemCommon
    }

    public static let everything = MessageKindFilter()

    public func allows(bytes: [UInt8]) -> Bool {
        guard let status = bytes.first else { return false }
        if status >= 0xF0 {
            switch status {
            case 0xF0: return systemExclusive
            case 0xF2: return songPosition
            // Clock and transport are separate switchable categories even though
            // both are System Real-Time messages.
            case 0xF8: return clock
            case 0xFA, 0xFB, 0xFC: return transport
            case 0xFE: return clock || transport
            case 0xF1, 0xF3, 0xF6, 0xF7: return otherSystemCommon
            case 0xFF: return otherSystemCommon
            default: return otherSystemCommon
            }
        }
        switch status & 0xF0 {
        case 0x80, 0x90: return note
        case 0xA0: return polyAftertouch
        case 0xB0: return controlChange
        case 0xC0: return programChange
        case 0xD0: return channelAftertouch
        case 0xE0: return pitchBend
        default: return true
        }
    }
}

// MARK: - Transforms

/// Per-route processing applied to every message before it is sent onward.
public struct RouteTransform: Codable, Hashable, Sendable {
    /// Semitone offset applied to note numbers (-48...+48).
    public var transpose: Int
    /// Multiplier applied to note velocity (0...2). 1.0 = unchanged.
    public var velocityScale: Double
    /// Added to velocity after scaling.
    public var velocityOffset: Int
    /// Re-map every incoming channel to this 1-based channel. nil = keep original.
    public var forceChannel: Int?
    /// Drop CC messages whose controller number is in this set.
    public var blockedControllers: Set<UInt8>
    /// Only forward notes within this inclusive MIDI note range.
    public var noteRangeLow: UInt8
    public var noteRangeHigh: UInt8

    public init(
        transpose: Int = 0,
        velocityScale: Double = 1.0,
        velocityOffset: Int = 0,
        forceChannel: Int? = nil,
        blockedControllers: Set<UInt8> = [],
        noteRangeLow: UInt8 = 0,
        noteRangeHigh: UInt8 = 127
    ) {
        self.transpose = transpose
        self.velocityScale = velocityScale
        self.velocityOffset = velocityOffset
        self.forceChannel = forceChannel
        self.blockedControllers = blockedControllers
        self.noteRangeLow = noteRangeLow
        self.noteRangeHigh = noteRangeHigh
    }

    public static let identity = RouteTransform()

    /// `true` when this transform cannot alter any message.
    public var isIdentity: Bool {
        self == RouteTransform.identity
    }

    /// A one-line description for list rows, or nil when the transform is a no-op.
    public var summary: String? {
        var parts: [String] = []
        if transpose != 0 { parts.append("transpose \(transpose > 0 ? "+" : "")\(transpose)") }
        if velocityScale != 1.0 { parts.append(String(format: "velocity ×%.2f", velocityScale)) }
        if velocityOffset != 0 { parts.append("velocity \(velocityOffset > 0 ? "+" : "")\(velocityOffset)") }
        if let forceChannel { parts.append("force ch \(forceChannel)") }
        if !blockedControllers.isEmpty {
            let list = blockedControllers.sorted().map(String.init).joined(separator: ",")
            parts.append("block CC \(list)")
        }
        if noteRangeLow != 0 || noteRangeHigh != 127 {
            parts.append("notes \(MIDIMessage.noteName(noteRangeLow))–\(MIDIMessage.noteName(noteRangeHigh))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Route

/// A single connection in the patchbay: one source port to one destination port,
/// with its own filter and transform pipeline.
///
/// Identity: `id` is a `UUID` used for change tracking within a session, and it
/// is persisted with the rig. The *semantic* identity of a route is the
/// `sourcePortID` → `destinationPortID` pair, which is why two routes with
/// different ids can still describe the same connection — the engine treats the
/// pair as unique and will not create duplicates.
public struct Route: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourcePortID: MIDIPort.ID
    public var destinationPortID: MIDIPort.ID
    public var isEnabled: Bool
    public var channels: ChannelMask
    public var messageKinds: MessageKindFilter
    public var transform: RouteTransform
    /// When true, this route only runs while the app window is frontmost — handy
    /// for performance rigs where a merge should not fight another one.
    public var note: String

    public init(
        id: UUID = UUID(),
        sourcePortID: MIDIPort.ID,
        destinationPortID: MIDIPort.ID,
        isEnabled: Bool = true,
        channels: ChannelMask = .all,
        messageKinds: MessageKindFilter = .everything,
        transform: RouteTransform = .identity,
        note: String = ""
    ) {
        self.id = id
        self.sourcePortID = sourcePortID
        self.destinationPortID = destinationPortID
        self.isEnabled = isEnabled
        self.channels = channels
        self.messageKinds = messageKinds
        self.transform = transform
        self.note = note
    }
}

// MARK: - Applying a route

extension Route {
    /// Runs one message through this route's filter and transform pipeline.
    /// Returns the messages to emit — usually 0 or 1, but an empty array means
    /// "filtered out", which is distinct from a passthrough.
    public func process(_ message: MIDIMessage) -> [MIDIMessage] {
        guard isEnabled else { return [] }

        // Message-type gate first: it needs the original status byte.
        guard messageKinds.allows(bytes: message.bytes) else { return [] }

        // Channel gate. System messages have no channel and bypass it.
        if message.isChannelMessage {
            guard channels.contains(channelIndex: Int(message.channel)) else { return [] }
        }

        var out = message.bytes

        if message.isChannelMessage {
            let statusNibble = message.statusNibble

            // Note range gate (applies to note on/off only).
            if statusNibble == 0x80 || statusNibble == 0x90 {
                guard out.count >= 3 else { return [message] }
                let note = out[1]
                guard note >= transform.noteRangeLow, note <= transform.noteRangeHigh else { return [] }
                if transform.transpose != 0 {
                    // MIDI notes are 7-bit. Note that `UInt8(clamping:)` would
                    // allow 0...255 and silently emit an invalid data byte, so the
                    // musical range is applied explicitly.
                    out[1] = UInt8(min(max(Int(note) + transform.transpose, 0), 127))
                }
            }

            // Velocity shaping for note on/off.
            if statusNibble == 0x80 || statusNibble == 0x90 {
                if transform.velocityScale != 1.0 || transform.velocityOffset != 0 {
                    guard out.count >= 3 else { return [message] }
                    let shaped = Double(out[2]) * transform.velocityScale + Double(transform.velocityOffset)
                    out[2] = UInt8(min(max(Int(shaped.rounded()), 0), 127))
                }
            }

            // CC blocking.
            if statusNibble == 0xB0, out.count >= 3, !transform.blockedControllers.isEmpty {
                if transform.blockedControllers.contains(out[1]) { return [] }
            }

            // Channel forcing.
            if let forced = transform.forceChannel, (1...16).contains(forced) {
                out[0] = (out[0] & 0xF0) | UInt8(forced - 1)
            }
        }

        var result = message
        result.bytes = out
        return [result]
    }
}

// MARK: - Port configuration

/// Per-port cosmetics and metadata, persisted with a rig.
public struct PortConfig: Codable, Hashable, Sendable {
    /// User-supplied name, e.g. "Prophet 6". Empty means use the default label.
    public var customLabel: String
    /// Optional role note, shown in tooltips.
    public var note: String
    /// Hide from the matrix to reduce clutter.
    public var hidden: Bool

    public init(customLabel: String = "", note: String = "", hidden: Bool = false) {
        self.customLabel = customLabel
        self.note = note
        self.hidden = hidden
    }
}
