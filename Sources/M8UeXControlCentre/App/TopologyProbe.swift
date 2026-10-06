import Foundation
import CoreMIDI

// MARK: - Topology probe

/// Dumps the CoreMIDI object graph as text.
///
/// This is the diagnostic to run the moment the M8U eX is plugged in. It answers
/// the questions that decide how the app behaves:
///
///   * What device name does the interface report? (Drives M8U eX recognition.)
///   * How many entities does it have, and are they named "Port 1"…"Port 16"?
///   * Does each entity expose one source and one destination, as expected?
///   * Do the endpoints report as offline while no cable is attached?
///   * What are the unique IDs, so a rig can be pinned to them if ever needed?
///
/// Run as `M8U eX Control Centre --probe`, or `--dump-ports` to also see the
/// port table this app builds from the same data.
enum TopologyProbe {

    static func run(verbose: Bool) -> Int32 {
        let m8uPorts = MIDIEndpointEnumerator.m8uPorts()
        let allSources = MIDIEndpointEnumerator.allSources()
        let allDestinations = MIDIEndpointEnumerator.allDestinations()

        line("M8U eX Control Centre — CoreMIDI topology probe")
        line(String(repeating: "=", count: 72))
        line("CoreMIDI devices:       \(MIDIGetNumberOfDevices())")
        line("Global sources:         \(MIDIGetNumberOfSources())")
        line("Global destinations:    \(MIDIGetNumberOfDestinations())")
        line("")

        // MARK: Devices and entities

        line("DEVICES")
        line(String(repeating: "-", count: 72))
        for index in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(index)
            let name = MIDIObject.name(device)
            let offline = MIDIObject.isOffline(device)
            let isM8U = M8UeXDiscovery.matches(deviceName: name)
            var flags: [String] = []
            if offline { flags.append("offline") }
            if isM8U { flags.append("RECOGNISED AS M8U/M4U eX") }
            if let manufacturer = MIDIObject.string(device, kMIDIPropertyManufacturer) {
                flags.append("manufacturer=\"\(manufacturer)\"")
            }
            if let model = MIDIObject.string(device, kMIDIPropertyModel) {
                flags.append("model=\"\(model)\"")
            }

            line("[\(index)] \(name)\(flags.isEmpty ? "" : "   (" + flags.joined(separator: ", ") + ")")")

            let entityCount = MIDIDeviceGetNumberOfEntities(device)
            for entityIndex in 0..<entityCount {
                let entity = MIDIDeviceGetEntity(device, entityIndex)
                let entityName = MIDIObject.name(entity)
                let parsedIndex = M8UeXDiscovery.portIndex(fromEntityName: entityName)
                let socketNote = parsedIndex.map { "→ socket \($0)" } ?? "(not a numbered port)"
                line("     entity[\(entityIndex)] \"\(entityName)\" \(socketNote)")

                for sourceIndex in 0..<MIDIEntityGetNumberOfSources(entity) {
                    let source = MIDIEntityGetSource(entity, sourceIndex)
                    let uid = MIDIObject.uniqueID(source) ?? 0
                    let offlineNote = MIDIObject.isOffline(source) ? " [offline]" : ""
                    line("          source[\(sourceIndex)] \"\(MIDIObject.name(source))\" uid=\(uid)\(offlineNote)")
                }
                for destinationIndex in 0..<MIDIEntityGetNumberOfDestinations(entity) {
                    let destination = MIDIEntityGetDestination(entity, destinationIndex)
                    let uid = MIDIObject.uniqueID(destination) ?? 0
                    let offlineNote = MIDIObject.isOffline(destination) ? " [offline]" : ""
                    line("          dest[\(destinationIndex)]   \"\(MIDIObject.name(destination))\" uid=\(uid)\(offlineNote)")
                }
            }
        }
        line("")

        // MARK: What the app made of it

        line("INTERFACE SUMMARY")
        line(String(repeating: "-", count: 72))
        if m8uPorts.isEmpty {
            line("No M8U/M4U eX device found. If it is plugged in, check that the cable is in the")
            line("USB HOST socket on the back and that DIP switch 3 is in the ON position for")
            line("USB 3.0 high-performance mode, which current macOS prefers.")
        } else {
            // Group by CoreMIDI device ID so each connected interface is reported
            // separately — this is where an M4U eX shows up alongside an M8U eX.
            var unitOrder: [MIDIUniqueID] = []
            var socketsByUnit: [MIDIUniqueID: [MIDIPort]] = [:]
            for port in m8uPorts {
                guard let uid = port.id.deviceUID else { continue }
                if socketsByUnit[uid] == nil { unitOrder.append(uid) }
                socketsByUnit[uid, default: []].append(port)
            }

            line("Units found:            \(unitOrder.count)")
            line("Sockets found:          \(m8uPorts.count)")

            let online = m8uPorts.filter { port in
                let sourceOnline = port.source.map { !$0.offline } ?? false
                let destinationOnline = port.destination.map { !$0.offline } ?? false
                return sourceOnline || destinationOnline
            }
            line("Sockets online:         \(online.count)")

            for uid in unitOrder {
                guard let sockets = socketsByUnit[uid] else { continue }
                let name = sockets.first?.id.unitName ?? "unknown"
                line("")
                line("UNIT  \(name)   deviceUID=\(uid)   sockets=\(sockets.count)")

                line("SOCKET MAP")
                for port in sockets.sorted(by: { ($0.m8uIndex ?? 0) < ($1.m8uIndex ?? 0) }) {
                    let indexLabel = port.m8uIndex.map { String(format: "%2d", $0) } ?? "--"
                    let sourceState = port.source.map { $0.offline ? "offline" : "online " } ?? "absent "
                    let destinationState = port.destination.map { $0.offline ? "offline" : "online " } ?? "absent "
                    line("  socket \(indexLabel)   source \(sourceState)   destination \(destinationState)   "
                         + "uid s=\(port.source?.uniqueID ?? 0) d=\(port.destination?.uniqueID ?? 0)")
                }
            }
        }
        line("")

        // MARK: Everything else

        line("ALL GLOBAL SOURCES (\(allSources.count))")
        line(String(repeating: "-", count: 72))
        for source in allSources {
            let device = source.deviceName ?? "—"
            let offline = source.offline ? " [offline]" : ""
            line("  \(source.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(device)\(offline)")
        }
        line("")

        line("ALL GLOBAL DESTINATIONS (\(allDestinations.count))")
        line(String(repeating: "-", count: 72))
        for destination in allDestinations {
            let device = destination.deviceName ?? "—"
            let offline = destination.offline ? " [offline]" : ""
            line("  \(destination.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(device)\(offline)")
        }

        if verbose {
            line("")
            line("PORT TABLE THE APP BUILDS (\(m8uPorts.count) M8U sockets)")
            line(String(repeating: "-", count: 72))
            for port in m8uPorts {
                line("  id=\(port.id)  label=\"\(port.label)\"  kind=\(port.kind.rawValue)")
                line("      source:      \(port.source.map { "\($0.name) uid=\($0.uniqueID) offline=\($0.offline)" } ?? "none")")
                line("      destination: \(port.destination.map { "\($0.name) uid=\($0.uniqueID) offline=\($0.offline)" } ?? "none")")
            }

            let endpointIDs = Set(m8uPorts.flatMap { [$0.source?.uniqueID, $0.destination?.uniqueID].compactMap { $0 } })
            let others = MIDIEndpointEnumerator.otherPorts(excluding: endpointIDs)
            line("")
            line("OTHER ROUTABLE ENDPOINTS (\(others.count))")
            line(String(repeating: "-", count: 72))
            for port in others {
                let canIn = port.source != nil ? "in" : "  "
                let canOut = port.destination != nil ? "out" : "   "
                line("  [\(canIn) \(canOut)] \(port.label)")
            }
        }

        line("")
        line(String(repeating: "=", count: 72))
        return 0
    }

    private static func line(_ text: String) {
        print(text)
    }
}
