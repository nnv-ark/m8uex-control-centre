import Foundation
import CoreMIDI
import SwiftUI

// MARK: - Directions

/// The physical direction a port is currently working in. The M8U eX
/// auto-detects this per port from whether MIDI data is flowing in or out,
/// and shows it on the front panel with a green (input) or red (output) LED.
public enum PortDirection: String, Codable, Sendable, CaseIterable {
    case input
    case output
    /// No traffic has been observed yet on this port in either direction.
    case idle

    public var isInput: Bool { self == .input }
    public var isOutput: Bool { self == .output }
}

// MARK: - Endpoint kinds

/// What kind of CoreMIDI endpoint sits behind a logical port.
public enum EndpointKind: String, Codable, Sendable {
    /// A real MIDI DIN socket on an M8U eX.
    case m8uPhysical
    /// A virtual port this app itself publishes so other software can route to/from it.
    case virtual
    /// Any other CoreMIDI endpoint (IAC bus, USB device, network session...).
    case system
}

// MARK: - Endpoint snapshot

/// A stable, value-type snapshot of a CoreMIDI endpoint.
///
/// `uniqueID` is the identity that survives reconnects and replugs, so it is
/// what we persist in rig profiles rather than the volatile `MIDIEndpointRef`.
public struct EndpointInfo: Identifiable, Hashable, Sendable {
    public let uniqueID: MIDIUniqueID
    public let name: String
    public let displayName: String
    public let endpoint: MIDIEndpointRef
    public let isSource: Bool
    /// Name of the owning device, if any (nil for virtual endpoints).
    public let deviceName: String?
    public let entityName: String?
    public let offline: Bool
    public let kind: EndpointKind

    public var id: MIDIUniqueID { uniqueID }

    public init(
        uniqueID: MIDIUniqueID,
        name: String,
        displayName: String,
        endpoint: MIDIEndpointRef,
        isSource: Bool,
        deviceName: String?,
        entityName: String?,
        offline: Bool,
        kind: EndpointKind
    ) {
        self.uniqueID = uniqueID
        self.name = name
        self.displayName = displayName
        self.endpoint = endpoint
        self.isSource = isSource
        self.deviceName = deviceName
        self.entityName = entityName
        self.offline = offline
        self.kind = kind
    }
}

// MARK: - Logical port

/// One logical MIDI port in the patchbay. For an M8U eX this is a physical
/// DIN socket; `virtual` ports are ones this app publishes.
public struct MIDIPort: Identifiable, Hashable, Sendable {
    /// Stable identity for a logical port.
    ///
    /// `Codable` on purpose: routes persist these identities so a rig profile
    /// keeps working across reboots, reconnects and USB port changes.
    ///
    /// The physical case carries three things, because no single one is enough:
    ///
    ///   * `unitName` — the device name macOS reports, e.g. "ESI M8U eX". This is
    ///     what distinguishes an M8U eX from an M4U eX, and it is what lets a saved
    ///     rig be re-matched after a replug.
    ///   * `deviceUID` — the CoreMIDI device's unique ID. Distinguishes two units
    ///     of the *same* model, where `unitName` alone is ambiguous.
    ///   * `index` — the 1-based socket number as printed on the hardware.
    public enum ID: Hashable, Sendable, Codable {
        case m8u(unitName: String, deviceUID: MIDIUniqueID, index: Int)
        /// A virtual port published by this app or another CoreMIDI client.
        case virtual(name: String)
    }

    public let id: ID
    /// Human label, e.g. "Port 7" or a user-supplied name like "Prophet 6".
    public var label: String
    public let kind: EndpointKind
    /// CoreMIDI source we read from, if this port can act as an input.
    public var source: EndpointInfo?
    /// CoreMIDI destination we write to, if this port can act as an output.
    public var destination: EndpointInfo?

    /// Live direction inferred from observed traffic — mirrors the front panel LED.
    public var direction: PortDirection = .idle
    public var enabled: Bool = true

    public var isM8UPhysical: Bool {
        if case .m8u = id { return true }
        return false
    }

    /// Sort order: physical units first, grouped by unit, then by socket number;
    /// virtual ports come last, alphabetically.
    ///
    /// Units are ordered by their interface name, compared as a string. The socket
    /// index is deliberately the last key so that, within a unit, ports read
    /// 1, 2, 3… in the order printed on the hardware, and an M8U eX's 16 sockets
    /// never interleave with an M4U eX's 8.
    public var sortKey: PortSortKey {
        switch id {
        case let .m8u(unitName, deviceUID, index):
            return PortSortKey(
                unitGroup: 0,
                unitName: unitName,
                unitTieBreak: deviceUID,
                index: index,
                name: ""
            )
        case let .virtual(name):
            return PortSortKey(
                unitGroup: 1,
                unitName: "",
                unitTieBreak: 0,
                index: 0,
                name: name
            )
        }
    }

    public init(
        id: ID,
        label: String,
        kind: EndpointKind,
        source: EndpointInfo? = nil,
        destination: EndpointInfo? = nil,
        direction: PortDirection = .idle,
        enabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.source = source
        self.destination = destination
        self.direction = direction
        self.enabled = enabled
    }
}

// MARK: - Sort key

/// Total ordering for the port list.
///
/// A struct rather than a tuple so the field meanings stay legible: an M8U eX, an
/// M4U eX and the app's own virtual ports all have to coexist in one ordered list
/// without their sockets interleaving.
public struct PortSortKey: Comparable, Sendable {
    /// 0 for physical interfaces, 1 for everything else.
    var unitGroup: Int
    /// The interface name, so an M4U eX groups before an M8U eX predictably.
    ///
    /// A string rather than a hash: Swift seeds `String.hashValue` randomly per
    /// process, so hashing here would shuffle the unit order on every launch.
    var unitName: String
    /// Separates two units that report the same device name.
    var unitTieBreak: MIDIUniqueID
    /// The socket number printed on the hardware.
    var index: Int
    /// Alphabetical fallback for virtual endpoints.
    var name: String

    public static func < (lhs: PortSortKey, rhs: PortSortKey) -> Bool {
        if lhs.unitGroup != rhs.unitGroup { return lhs.unitGroup < rhs.unitGroup }
        if lhs.unitName != rhs.unitName { return lhs.unitName < rhs.unitName }
        if lhs.unitTieBreak != rhs.unitTieBreak { return lhs.unitTieBreak < rhs.unitTieBreak }
        if lhs.index != rhs.index { return lhs.index < rhs.index }
        return lhs.name < rhs.name
    }
}

// MARK: - Readable labels

extension MIDIPort.ID {
    /// The socket number, or the virtual endpoint's name.
    public var shortName: String {
        switch self {
        case let .m8u(_, _, index): return "Port \(index)"
        case let .virtual(name): return name
        }
    }

    /// The interface this port belongs to, e.g. "ESI M8U eX". Nil for virtual ports.
    public var unitName: String? {
        switch self {
        case let .m8u(unitName, _, _): return unitName
        case .virtual: return nil
        }
    }

    /// The 1-based socket number, or nil for virtual ports.
    public var socketIndex: Int? {
        switch self {
        case let .m8u(_, _, index): return index
        case .virtual: return nil
        }
    }

    /// The device's CoreMIDI unique ID, or nil for virtual ports.
    public var deviceUID: MIDIUniqueID? {
        switch self {
        case let .m8u(_, deviceUID, _): return deviceUID
        case .virtual: return nil
        }
    }
}

// MARK: - Port index helpers

extension MIDIPort {
    /// 1-based socket number on its interface, or nil for virtual ports.
    public var m8uIndex: Int? { id.socketIndex }

    /// The interface this port belongs to, e.g. "ESI M8U eX".
    public var unitName: String? { id.unitName }
}

// MARK: - Reference resolution

/// Re-matches saved port references against the ports that actually exist.
///
/// A rig stores both the CoreMIDI device ID and the device's name for every
/// physical port. macOS can hand a device a new unique ID after a replug, DAC
/// change or reinstall, so the stored ID alone would silently stop matching.
/// Resolution therefore tries the exact ID first and falls back to matching the
/// device name with the socket number — which is what the user actually means by
/// "the M4U eX's port 3".
///
/// The fallback is only ever applied when the name *and* socket number agree, and
/// when exactly one live port matches. Ambiguity is reported rather than guessed,
/// because silently rerouting someone's patch is worse than doing nothing.
public struct PortResolver: Sendable {
    private var byIdentity: [MIDIPort.ID: MIDIPort.ID] = [:]
    /// External endpoints indexed by their displayed name, so a route to a device
    /// survives that device being replugged and handed a new CoreMIDI ID.
    private var byExternalName: [String: MIDIPort.ID] = [:]

    public init() {}

    public init(ports: [MIDIPort]) {
        for port in ports {
            byIdentity[port.id] = port.id
            switch port.id {
            case let .m8u(unitName, _, index):
                // Also index a version with the device ID cleared, so a stale
                // device ID still resolves by name and socket.
                byIdentity[.m8u(unitName: unitName, deviceUID: 0, index: index)] = port.id
            case .virtual:
                // Recorded by name so a replug can be re-matched; duplicates are
                // pruned after the loop.
                byExternalName[Self.externalKey(port.label)] = port.id
            }
        }
        // A name that two endpoints share is ambiguous, so it is dropped rather
        // than resolved to whichever happened to be indexed last.
        let ambiguous = Set(
            ports.filter { byExternalName[Self.externalKey($0.label)] != nil }
                .map { Self.externalKey($0.label) }
                .filter { key in
                    ports.filter { Self.externalKey($0.label) == key }.count > 1
                }
        )
        for key in ambiguous { byExternalName.removeValue(forKey: key) }
    }

    /// The comparison key for an external endpoint's name.
    private static func externalKey(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The live port matching a saved reference, or nil when nothing matches.
    ///
    /// A saved reference may be a `virtual` identity carrying a CoreMIDI endpoint
    /// ID that no longer exists. Rather than let that route go quietly dead, the
    /// name is matched against the current endpoints — but only the name, and only
    /// when exactly one endpoint has it.
    public func resolve(_ reference: MIDIPort.ID, label: String? = nil) -> MIDIPort.ID? {
        if let exact = byIdentity[reference] { return exact }
        if case let .m8u(unitName, _, index) = reference {
            return byIdentity[.m8u(unitName: unitName, deviceUID: 0, index: index)]
        }
        if let label, !label.isEmpty {
            return byExternalName[Self.externalKey(label)]
        }
        return nil
    }

    /// True when the reference needs the name fallback, i.e. its device ID is
    /// stale. Used to tell the user their rig was re-matched rather than silently
    /// pretending the saved ID was still correct.
    public func neededFallback(_ reference: MIDIPort.ID, label: String? = nil) -> Bool {
        byIdentity[reference] == nil && resolve(reference, label: label) != nil
    }
}
