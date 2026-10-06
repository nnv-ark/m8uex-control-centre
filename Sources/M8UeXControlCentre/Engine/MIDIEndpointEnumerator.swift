import Foundation
import CoreMIDI

// MARK: - CoreMIDI helpers

/// Thin, safe wrappers over the CoreMIDI property API.
enum MIDIObject {
    static func string(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func integer(_ object: MIDIObjectRef, _ property: CFString) -> Int32? {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(object, property, &value) == noErr else { return nil }
        return value
    }

    static func uniqueID(_ object: MIDIObjectRef) -> MIDIUniqueID? {
        integer(object, kMIDIPropertyUniqueID)
    }

    static func isOffline(_ object: MIDIObjectRef) -> Bool {
        (integer(object, kMIDIPropertyOffline) ?? 0) != 0
    }

    static func name(_ object: MIDIObjectRef) -> String {
        string(object, kMIDIPropertyName) ?? "Untitled"
    }

    static func displayName(_ object: MIDIObjectRef) -> String {
        string(object, kMIDIPropertyDisplayName) ?? name(object)
    }
}

// MARK: - M8U eX recognition

/// Identifies M8U eX hardware in the CoreMIDI object graph.
///
/// The M8U eX is class compliant, so macOS builds the device itself: one
/// `MIDIDeviceRef` named "ESI M8U eX" containing 16 entities named
/// "Port 1" … "Port 16", each owning exactly one source and one destination.
/// This type encodes that layout so port discovery stays in one place.
public enum M8UeXDiscovery {
    /// Substrings that identify the device across firmware revisions.
    /// The unit reports "ESI M8U eX"; "M4U eX" is the 8-port sibling and is
    /// matched deliberately so the app is useful on both.
    public static let deviceNameMarkers = ["M8U eX", "M8UeX", "M8UEX", "M4U eX", "M4UeX"]
    /// Also accept the bare model names in case a firmware revision drops the vendor prefix.
    public static let modelMarkers = ["M8U", "M4U"]

    /// The port counts each model exposes.
    public static func expectedPortCount(deviceName: String) -> Int {
        let lower = deviceName.lowercased()
        if lower.contains("m4u") { return 8 }
        return 16
    }

    /// True when the device name looks like an M8U/M4U eX.
    public static func matches(deviceName: String) -> Bool {
        let lower = deviceName.lowercased()
        if deviceNameMarkers.contains(where: { lower.contains($0.lowercased()) }) { return true }
        // Bare model marker, but avoid matching unrelated devices like "M8U XL"
        // that share the name yet use a driver-based architecture.
        return modelMarkers.contains { marker in
            lower.contains(marker.lowercased()) && (lower.contains("ex") || lower.contains("e x"))
        }
    }

    /// Parses "Port 12" into 12. Returns nil for anything else, which is how we
    /// tell M8U entities apart from the "DAW"/"MIDI" style entities other
    /// devices use.
    public static func portIndex(fromEntityName name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("port") else { return nil }
        let digits = lower.drop(while: { !$0.isNumber })
        guard let index = Int(digits), (1...64).contains(index) else { return nil }
        return index
    }
}

// MARK: - Enumerator

/// Walks the CoreMIDI graph and produces flat endpoint snapshots.
public enum MIDIEndpointEnumerator {

    /// Every source endpoint currently known to CoreMIDI, including those on
    /// offline (previously seen) devices.
    public static func allSources() -> [EndpointInfo] {
        (0..<MIDIGetNumberOfSources()).map { index in
            let endpoint = MIDIGetSource(index)
            return info(for: endpoint, isSource: true)
        }
    }

    /// Every destination endpoint currently known to CoreMIDI.
    public static func allDestinations() -> [EndpointInfo] {
        (0..<MIDIGetNumberOfDestinations()).map { index in
            let endpoint = MIDIGetDestination(index)
            return info(for: endpoint, isSource: false)
        }
    }

    /// Builds a snapshot for one endpoint, resolving its owning device and entity.
    public static func info(for endpoint: MIDIEndpointRef, isSource: Bool) -> EndpointInfo {
        let uniqueID = MIDIObject.uniqueID(endpoint) ?? 0
        let rawName = MIDIObject.name(endpoint)

        // Walk up to the entity and device so we know who owns this endpoint.
        var entityName: String?
        var deviceName: String?
        var deviceRef: MIDIDeviceRef?

        var entity = MIDIObjectRef(0)
        if MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0 {
            entityName = MIDIObject.name(entity)
            var owner = MIDIDeviceRef(0)
            // MIDIEntityGetDevice takes the entity ref by value, not by pointer.
            if MIDIEntityGetDevice(MIDIEntityRef(entity), &owner) == noErr, owner != 0 {
                deviceName = MIDIObject.name(owner)
                deviceRef = owner
            }
        }

        let kind = classify(deviceName: deviceName, deviceRef: deviceRef)

        // Endpoint names are frequently generic ("Port 1"), so prefer the
        // CoreMIDI display name, which prefixes the device name, when available.
        let display = MIDIObject.displayName(endpoint)

        return EndpointInfo(
            uniqueID: uniqueID,
            name: rawName,
            displayName: display,
            endpoint: endpoint,
            isSource: isSource,
            deviceName: deviceName,
            entityName: entityName,
            offline: MIDIObject.isOffline(endpoint) || (deviceRef.map { MIDIObject.isOffline($0) } ?? false),
            kind: kind
        )
    }

    /// A M8U eX has its own device node and no driver owner; IAC buses and
    /// network sessions are system-provided; anything with an entity name we
    /// created is ours.
    private static func classify(deviceName: String?, deviceRef: MIDIDeviceRef?) -> EndpointKind {
        guard let deviceName else { return .virtual }
        if M8UeXDiscovery.matches(deviceName: deviceName) { return .m8uPhysical }
        return .system
    }

    /// Finds every M8U/M4U eX device and reports its ports in socket order.
    ///
    /// Multiple units are supported, including an M8U eX and an M4U eX at once.
    /// Each port's identity is the pair (device, socket), not a running counter,
    /// so connecting the two units in a different order — or adding a third —
    /// never re-points an existing route at the wrong socket.
    public static func m8uPorts() -> [MIDIPort] {
        var ports: [MIDIPort] = []

        for deviceIndex in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(deviceIndex)
            let deviceName = MIDIObject.name(device)
            guard M8UeXDiscovery.matches(deviceName: deviceName) else { continue }
            let deviceUID = MIDIObject.uniqueID(device) ?? 0

            let entityCount = MIDIDeviceGetNumberOfEntities(device)
            for entityIndex in 0..<entityCount {
                let entity = MIDIDeviceGetEntity(device, entityIndex)
                let entityName = MIDIObject.name(entity)

                // Prefer the number in the entity name, since that is the socket
                // printed on the hardware. If a firmware revision ever reports
                // unnumbered entity names, fall back to physical order so the app
                // degrades to "still works" rather than "shows nothing".
                let socketIndex = M8UeXDiscovery.portIndex(fromEntityName: entityName) ?? (entityIndex + 1)

                var source: EndpointInfo?
                if MIDIEntityGetNumberOfSources(entity) > 0 {
                    source = info(for: MIDIEntityGetSource(entity, 0), isSource: true)
                }
                var destination: EndpointInfo?
                if MIDIEntityGetNumberOfDestinations(entity) > 0 {
                    destination = info(for: MIDIEntityGetDestination(entity, 0), isSource: false)
                }

                ports.append(
                    MIDIPort(
                        id: .m8u(unitName: deviceName, deviceUID: deviceUID, index: socketIndex),
                        // The device name is offered as the label so that with two
                        // interfaces connected, "ESI M4U eX · Port 3" is never
                        // confused with "ESI M8U eX · Port 3".
                        label: "\(deviceName) · Port \(socketIndex)",
                        kind: .m8uPhysical,
                        source: source,
                        destination: destination
                    )
                )
            }
        }

        return ports.sorted { $0.sortKey < $1.sortKey }
    }

    /// All non-M8U endpoints, so the patchbay can route to IAC buses, other USB
    /// gear and network MIDI sessions as well as the interface itself.
    public static func otherPorts(excluding uniqueIDs: Set<MIDIUniqueID>) -> [MIDIPort] {
        var ports: [MIDIPort] = []
        var seen = Set<MIDIUniqueID>()

        // Pair up sources and destinations that belong to the same entity so one
        // row can act as both an input and an output where applicable.
        let sources = allSources().filter { $0.kind != .m8uPhysical && !uniqueIDs.contains($0.uniqueID) }
        let destinations = allDestinations().filter { $0.kind != .m8uPhysical && !uniqueIDs.contains($0.uniqueID) }

        for source in sources where !seen.contains(source.uniqueID) {
            // Try to find the matching destination on the same device+entity.
            let match = destinations.first {
                !seen.contains($0.uniqueID)
                    && $0.deviceName == source.deviceName
                    && $0.entityName == source.entityName
            }
            if let match { seen.insert(match.uniqueID) }
            seen.insert(source.uniqueID)

            let label = source.deviceName.map { "\($0) · \(source.name)" } ?? source.name
            ports.append(
                MIDIPort(
                    id: .virtual(name: "ext:\(source.uniqueID)"),
                    label: label,
                    kind: .system,
                    source: source,
                    destination: match
                )
            )
        }

        // Destinations with no matching source (output-only destinations).
        for destination in destinations where !seen.contains(destination.uniqueID) {
            seen.insert(destination.uniqueID)
            let label = destination.deviceName.map { "\($0) · \(destination.name)" } ?? destination.name
            ports.append(
                MIDIPort(
                    id: .virtual(name: "ext:\(destination.uniqueID)"),
                    label: label,
                    kind: .system,
                    source: nil,
                    destination: destination
                )
            )
        }

        return ports.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
